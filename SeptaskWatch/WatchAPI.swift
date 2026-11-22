import Foundation
import Security

// The watch's backend client (docs/WATCH.md). It holds the watch's OWN
// session, minted by the phone (`WatchSessionHandoff`), and owns its refresh
// rotation from then on. Reads ready-made views (`GET /v1/tasks?view=`) and
// sends verbs (`POST /v1/tasks/:id/:verb`), so the wrist needs no task model.

enum WatchAPIError: Error, Equatable {
  /// No session on the watch, or the server refused it: ask the phone.
  case notConnected
  /// The server answered 404 for this task: it's gone, drop the change.
  case notFound
  /// The server refused the change for good (422 / 400).
  case rejected(String)
  case server(Int)
  case network(String)
  case badResponse

  var isRetryable: Bool {
    switch self {
    case .network, .server: return true
    default: return false
    }
  }
}

actor WatchAPI {
  static let shared = WatchAPI()

  static let baseURL = URL(string: "https://api.septena.app")!
  static let clientName = "septask-watch"

  private let session: URLSession
  private var accessToken: String?
  private var accessExpiry: Date = .distantPast
  /// One refresh at a time: the token is single-use.
  private var refreshTask: Task<String, Error>?

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 40
    config.waitsForConnectivity = false
    session = URLSession(configuration: config)
  }

  // MARK: - Session

  nonisolated static var hasSession: Bool { WatchKeychain.load() != nil }

  func adopt(_ handoff: WatchSessionHandoff) {
    WatchKeychain.store(handoff.refreshToken)
    UserDefaults.standard.set(handoff.userId, forKey: "septena.watch.userId")
    accessToken = nil
    accessExpiry = .distantPast
  }

  /// Drops the session. Best effort revokes it on the server first.
  func signOut() async {
    if let token = WatchKeychain.load(),
       let body = try? JSONEncoder().encode(["refreshToken": token]) {
      _ = try? await perform(path: "/v1/auth/signout", method: "POST", body: body, auth: nil)
    }
    clear()
  }

  private func clear() {
    WatchKeychain.delete()
    UserDefaults.standard.removeObject(forKey: "septena.watch.userId")
    accessToken = nil
    accessExpiry = .distantPast
  }

  private struct Session: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
  }

  private func validAccessToken(forceRefresh: Bool) async throws -> String {
    if !forceRefresh, let accessToken, Date() < accessExpiry { return accessToken }
    if let refreshTask { return try await refreshTask.value }
    let task = Task<String, Error> { try await self.refresh() }
    refreshTask = task
    defer { refreshTask = nil }
    return try await task.value
  }

  private func refresh() async throws -> String {
    guard let token = WatchKeychain.load() else { throw WatchAPIError.notConnected }
    let body = try JSONEncoder().encode(["refreshToken": token])
    let (data, status) = try await perform(path: "/v1/auth/refresh", method: "POST", body: body, auth: nil)
    if status == 401 {
      clear()
      throw WatchAPIError.notConnected
    }
    guard status == 200, let s = try? JSONDecoder().decode(Session.self, from: data) else {
      throw WatchAPIError.server(status)
    }
    // Store the rotated token first: the old one is already spent.
    WatchKeychain.store(s.refreshToken)
    accessToken = s.accessToken
    accessExpiry = Date().addingTimeInterval(TimeInterval(max(s.expiresIn - 60, 0)))
    return s.accessToken
  }

  // MARK: - Tasks

  func list(_ view: WatchTaskList.View) async throws -> WatchTaskList {
    let (data, status) = try await authed(path: "/v1/tasks?view=\(view.rawValue)", method: "GET", body: nil)
    try Self.check(status, data)
    guard var list = try? JSONDecoder.watchWire.decode(WatchTaskList.self, from: data) else {
      throw WatchAPIError.badResponse
    }
    list.fetchedAt = .now
    return list
  }

  func send(_ op: WatchOp) async throws {
    switch op.action {
    case .create(let title, let when):
      let body = try JSONEncoder().encode(["title": title, "when": when.rawValue])
      let (data, status) = try await authed(path: "/v1/tasks", method: "POST", body: body)
      try Self.check(status, data)
    default:
      guard let id = op.action.taskID, let verb = op.action.verb else { return }
      let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
      let (data, status) = try await authed(path: "/v1/tasks/\(encoded)/\(verb)", method: "POST", body: Data("{}".utf8))
      try Self.check(status, data)
    }
  }

  private static func check(_ status: Int, _ data: Data) throws {
    switch status {
    case 200, 201: return
    case 401: throw WatchAPIError.notConnected
    case 404: throw WatchAPIError.notFound
    case 400, 402, 422:
      struct Body: Decodable { let error: String?; let message: String? }
      let b = try? JSONDecoder().decode(Body.self, from: data)
      throw WatchAPIError.rejected(b?.message ?? b?.error ?? "HTTP \(status)")
    default: throw WatchAPIError.server(status)
    }
  }

  // MARK: - HTTP

  private func authed(path: String, method: String, body: Data?) async throws -> (Data, Int) {
    var forceRefresh = false
    while true {
      let token = try await validAccessToken(forceRefresh: forceRefresh)
      let (data, status) = try await perform(path: path, method: method, body: body, auth: token)
      if status == 401, !forceRefresh { forceRefresh = true; continue }
      return (data, status)
    }
  }

  private func perform(path: String, method: String, body: Data?, auth: String?) async throws -> (Data, Int) {
    guard let url = URL(string: path, relativeTo: Self.baseURL) else { throw WatchAPIError.badResponse }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(Self.clientName, forHTTPHeaderField: "X-Septena-Client")
    request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Septena-TimeZone")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let auth { request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw WatchAPIError.badResponse }
      return (data, http.statusCode)
    } catch let error as WatchAPIError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw WatchAPIError.network(error.localizedDescription)
    }
  }
}

/// The refresh token, in the watch's own Keychain (device-only).
enum WatchKeychain {
  private static let service = "com.septena.watch"
  private static let account = "refreshToken"

  private static var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }

  static func load() -> String? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
          let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func store(_ token: String) {
    let data = Data(token.utf8)
    let update: [String: Any] = [kSecValueData as String: data]
    if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(add as CFDictionary, nil)
    }
  }

  static func delete() {
    SecItemDelete(query as CFDictionary)
  }
}
