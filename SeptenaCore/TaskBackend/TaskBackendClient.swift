import CryptoKit
import Foundation
import Security

// HTTP client for the task backend at api.septena.app
// (docs/SEPTASK_BACKEND.md; routes in ../septena-mcp-gateway/src/api/routes.ts).
//
// Auth: Sign in with Apple gives an identity token; POST /v1/auth/apple trades
// it (plus the raw nonce) for a 1-hour access token and a refresh token. The
// refresh token is single-use and rotates on every refresh, so the client
// stores the new one in the Keychain before it uses the new access token. It
// stays device-local (`synchronizable: false`): two devices sharing one
// rotating token would race and log each other out.
//
// UI-free. The Sign in with Apple sheet lives in the Mac settings pane.

enum TaskBackendError: LocalizedError, Equatable {
  case notSignedIn
  case http(status: Int, code: String)
  case badResponse(String)
  case network(String)

  var errorDescription: String? {
    switch self {
    case .notSignedIn: return "Not signed in to the task backend."
    case .http(let status, let code): return "The backend answered \(status) (\(code))."
    case .badResponse(let what): return "The backend sent a reply the app can't read (\(what))."
    case .network(let what): return "Network error: \(what)"
    }
  }
}

actor TaskBackendClient {
  static let shared = TaskBackendClient()

  static let baseURL = URL(string: "https://api.septena.app")!
  /// Sent as `X-Septena-Client`; the server logs writes as `app:<this>`.
  static let clientName = "septask-mac"
  private static let refreshAccount = "com.septena.taskBackend.refreshToken"

  private let session: URLSession
  private var accessToken: String?
  private var accessExpiry: Date = .distantPast
  /// One refresh at a time: refresh tokens are single-use, so two parallel
  /// refreshes with the same token would make the second fail and sign out.
  private var refreshTask: Task<String, Error>?

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 600
    config.waitsForConnectivity = false
    session = URLSession(configuration: config)
  }

  // MARK: - Session

  /// True when this device holds a refresh token. Reads the Keychain only.
  nonisolated static var hasSession: Bool {
    KeychainStore.load(account: refreshAccount) != nil
  }

  /// A one-time raw nonce and the value to hand Apple (`request.nonce`): the
  /// hex SHA-256 of the raw nonce. The server checks the token's nonce claim
  /// against the hash of the raw nonce we send it.
  nonisolated static func makeNonce() -> (raw: String, hashed: String) {
    var bytes = [UInt8](repeating: 0, count: 32)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
    }
    let raw = bytes.map { String(format: "%02x", $0) }.joined()
    let hashed = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    return (raw, hashed)
  }

  func signIn(identityToken: String, rawNonce: String) async throws {
    let body = try JSONEncoder().encode(["identityToken": identityToken, "nonce": rawNonce])
    let (data, status) = try await perform(path: "/v1/auth/apple", method: "POST", body: body, auth: nil)
    guard status == 200 else { throw Self.httpError(status, data) }
    try adopt(decode(BackendSession.self, from: data, what: "session"))
  }

  func signOut() async {
    if let token = KeychainStore.load(account: Self.refreshAccount),
       let body = try? JSONEncoder().encode(["refreshToken": token]) {
      // Best effort: the local session goes away even when the server call fails.
      _ = try? await perform(path: "/v1/auth/signout", method: "POST", body: body, auth: nil)
    }
    KeychainStore.delete(account: Self.refreshAccount)
    accessToken = nil
    accessExpiry = .distantPast
  }

  private func adopt(_ s: BackendSession) {
    // Store the rotated refresh token first: the old one is already spent.
    KeychainStore.store(s.refreshToken, account: Self.refreshAccount, synchronizable: false)
    accessToken = s.accessToken
    accessExpiry = Date().addingTimeInterval(TimeInterval(max(s.expiresIn - 60, 0)))
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
    guard let token = KeychainStore.load(account: Self.refreshAccount) else { throw TaskBackendError.notSignedIn }
    let body = try JSONEncoder().encode(["refreshToken": token])
    let (data, status) = try await perform(path: "/v1/auth/refresh", method: "POST", body: body, auth: nil)
    if status == 401 {
      // The token is spent or revoked. Keeping it would only fail again.
      KeychainStore.delete(account: Self.refreshAccount)
      accessToken = nil
      throw TaskBackendError.notSignedIn
    }
    guard status == 200 else { throw Self.httpError(status, data) }
    let s = try decode(BackendSession.self, from: data, what: "session")
    adopt(s)
    return s.accessToken
  }

  // MARK: - Sync

  enum PushOutcome: Sendable {
    case ok(BackendPushResponse)
    /// HTTP 400: the Worker's validation refused the whole batch.
    case refused(BackendErrorBody?)
  }

  func push(_ ops: [BackendOp]) async throws -> PushOutcome {
    let body = try JSONEncoder().encode(BackendPushBody(ops: ops.map(\.body)))
    let (data, status) = try await authed(path: "/v1/sync/push", method: "POST", body: body)
    if status == 400 { return .refused(try? JSONDecoder().decode(BackendErrorBody.self, from: data)) }
    guard status == 200 else { throw Self.httpError(status, data) }
    let result = try decode(BackendPushResponse.self, from: data, what: "push")
    guard result.results.map(\.clientOpId) == ops.map(\.clientOpId) else {
      throw TaskBackendError.badResponse("push results do not match the ops sent")
    }
    return .ok(result)
  }

  func pull(since: Int, limit: Int = 1_000) async throws -> BackendPullResponse {
    let (data, status) = try await authed(path: "/v1/sync/pull?since=\(since)&limit=\(limit)", method: "GET", body: nil)
    guard status == 200 else { throw Self.httpError(status, data) }
    return try decode(BackendPullResponse.self, from: data, what: "pull")
  }

  /// Uploads an attachment's bytes. The metadata row must exist first and its
  /// `byteCount` must equal the file size, or the server answers 404 / 409.
  func uploadAttachment(id: String, fileURL: URL, contentType: String) async throws {
    let data: Data
    do { data = try Data(contentsOf: fileURL) } catch { throw TaskBackendError.badResponse("file unreadable") }
    let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    let (body, status) = try await authed(path: "/v1/attachments/\(encodedID)", method: "PUT", body: data,
                                          contentType: contentType)
    guard status == 200 else { throw Self.httpError(status, body) }
  }

  // MARK: - HTTP

  /// Sends with a bearer token. On 401 it refreshes once and retries. A
  /// transport error or a 5xx / 429 is retried up to twice; every op carries a
  /// deterministic `clientOpId`, so a repeated push does not apply twice.
  private func authed(path: String, method: String, body: Data?,
                      contentType: String = "application/json") async throws -> (Data, Int) {
    var forceRefresh = false
    var attempt = 0
    while true {
      let token = try await validAccessToken(forceRefresh: forceRefresh)
      do {
        let (data, status) = try await perform(path: path, method: method, body: body, auth: token,
                                               contentType: contentType)
        if status == 401, !forceRefresh { forceRefresh = true; continue }
        if (status >= 500 || status == 429), attempt < 2 {
          attempt += 1
          try await Task.sleep(nanoseconds: UInt64(attempt * 2) * 1_000_000_000)
          continue
        }
        return (data, status)
      } catch let error as TaskBackendError {
        guard case .network = error, attempt < 2 else { throw error }
        attempt += 1
        try await Task.sleep(nanoseconds: UInt64(attempt * 2) * 1_000_000_000)
      }
    }
  }

  private func perform(path: String, method: String, body: Data?, auth: String?,
                       contentType: String = "application/json") async throws -> (Data, Int) {
    guard let url = URL(string: path, relativeTo: Self.baseURL) else { throw TaskBackendError.badResponse("bad path") }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(Self.clientName, forHTTPHeaderField: "X-Septena-Client")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let auth { request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
      request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    }
    do {
      let data: Data
      let response: URLResponse
      if let body {
        (data, response) = try await session.upload(for: request, from: body)
      } else {
        (data, response) = try await session.data(for: request)
      }
      guard let http = response as? HTTPURLResponse else { throw TaskBackendError.badResponse("not HTTP") }
      return (data, http.statusCode)
    } catch let error as TaskBackendError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw TaskBackendError.network(error.localizedDescription)
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) } catch { throw TaskBackendError.badResponse(what) }
  }

  private static func httpError(_ status: Int, _ data: Data) -> TaskBackendError {
    let code = (try? JSONDecoder().decode(BackendErrorBody.self, from: data))?.error ?? "no detail"
    return .http(status: status, code: code)
  }
}
