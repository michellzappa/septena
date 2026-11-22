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
    case .notSignedIn: return "Not signed in to Septena sync."
    case .http(let status, let code): return "The server answered \(status) (\(code))."
    case .badResponse(let what): return "The server sent a reply the app couldn’t read (\(what))."
    case .network(let what): return "Network error: \(what)"
    }
  }
}

actor TaskBackendClient {
  static let shared = TaskBackendClient()

  static let baseURL = URL(string: "https://api.septena.app")!
  /// Sent as `X-Septena-Client`; the server logs writes as `app:<this>`.
  #if os(macOS)
  static let clientName = "septask-mac"
  #else
  static let clientName = "septask-ios"
  #endif
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

  /// Returns the backend user id of the new session.
  @discardableResult
  func signIn(identityToken: String, rawNonce: String) async throws -> String {
    let body = try JSONEncoder().encode(["identityToken": identityToken, "nonce": rawNonce])
    let (data, status) = try await perform(path: "/v1/auth/apple", method: "POST", body: body, auth: nil)
    guard status == 200 else { throw Self.httpError(status, data) }
    let session = try decode(BackendSession.self, from: data, what: "session")
    adopt(session)
    return session.userId
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

  /// Deletes the account on the backend (`DELETE /v1/account`): the server
  /// empties the user's task store (tasks, areas, projects, conversations,
  /// settings) and their attachment files (docs/SEPTASK_BACKEND.md §10).
  /// Then drops the local session. Throws, and keeps the session, when the
  /// server did not confirm.
  func deleteAccount() async throws {
    let (data, status) = try await authed(path: "/v1/account", method: "DELETE", body: nil)
    guard status == 204 || status == 200 else { throw Self.httpError(status, data) }
    // No sign-out call: the server's store is empty, so the refresh token
    // fails its next rotation anyway.
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

  func pull(since: Int, limit: Int = RegistryEntityLimits.maxPull) async throws -> BackendPullResponse {
    // `settings=1`, `checklists=1`, & `tags=1`: this client syncs those entities.
    // Without them the server omits those rows so older builds decode cleanly.
    let (data, status) = try await authed(path: "/v1/sync/pull?since=\(since)&limit=\(limit)&settings=1&checklists=1&tags=1",
                                          method: "GET", body: nil)
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

  /// Downloads an attachment's bytes (`GET /v1/attachments/:id`) and writes
  /// them atomically to `destination`. Returns the byte count.
  @discardableResult
  func downloadAttachment(id: String, to destination: URL) async throws -> Int {
    let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    let (data, status) = try await authed(path: "/v1/attachments/\(encodedID)", method: "GET", body: nil)
    guard status == 200 else { throw Self.httpError(status, data) }
    do { try data.write(to: destination, options: .atomic) } catch {
      throw TaskBackendError.badResponse("file not writable")
    }
    return data.count
  }

  /// The upgrade request for the live-nudge socket (`GET /v1/sync/ws`), with
  /// a fresh bearer token. The caller opens the socket; it carries `{ rev }`
  /// nudges only (docs/SEPTASK_BACKEND.md §6.3).
  func webSocketRequest() async throws -> URLRequest {
    let token = try await validAccessToken(forceRefresh: false)
    guard let https = URL(string: "/v1/sync/ws", relativeTo: Self.baseURL)?.absoluteURL,
          var parts = URLComponents(url: https, resolvingAgainstBaseURL: false) else {
      throw TaskBackendError.badResponse("bad path")
    }
    parts.scheme = "wss"
    guard let url = parts.url else { throw TaskBackendError.badResponse("bad path") }
    var request = URLRequest(url: url)
    request.setValue(Self.clientName, forHTTPHeaderField: "X-Septena-Client")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }

  // MARK: - History

  /// One task's change log, newest first (`GET /v1/changes?entity=task&id=`).
  /// Page back with `before`: the smallest `rev` already shown.
  /// The page also says when the plan's window hid older changes.
  func history(taskID: String, limit: Int = TaskHistory.pageSize, before: Int? = nil) async throws -> BackendChangesResponse {
    var parts = URLComponents()
    parts.path = "/v1/changes"
    parts.queryItems = [
      URLQueryItem(name: "entity", value: BackendEntity.task.rawValue),
      URLQueryItem(name: "id", value: taskID),
      URLQueryItem(name: "limit", value: String(min(max(limit, 1), 500))),
    ] + (before.map { [URLQueryItem(name: "before", value: String($0))] } ?? [])
    guard let path = parts.string else { throw TaskBackendError.badResponse("bad path") }
    let (data, status) = try await authed(path: path, method: "GET", body: nil)
    guard status == 200 else { throw Self.httpError(status, data) }
    return try decode(BackendChangesResponse.self, from: data, what: "history")
  }

  // MARK: - Sign-in approval (a new device, or the Claude connector)

  /// What a sign-in code asks for, read before the user approves it
  /// (`POST /v1/pair/inspect`). A "device" code gives a new device a full app
  /// session (ADR 0016); a "connector" code gives Claude MCP task access.
  func inspectPairing(code: String) async throws -> BackendPairingRequest {
    let body = try JSONEncoder().encode(["code": code])
    let (data, status) = try await authed(path: "/v1/pair/inspect", method: "POST", body: body)
    guard status == 200 else { throw Self.httpError(status, data) }
    return try decode(BackendPairingRequest.self, from: data, what: "sign-in request")
  }

  /// Approves a sign-in code. `kind` is the kind the user confirmed; the
  /// server approves nothing if the code is of another kind. Sends the device
  /// time zone, which decides what "today" means for the connector. Returns
  /// the client name.
  @discardableResult
  func approvePairing(code: String, kind: BackendPairingRequest.Kind? = nil) async throws -> String {
    struct Approval: Decodable { let client: String }
    var fields = ["code": code, "timeZone": TimeZone.current.identifier]
    if let kind { fields["kind"] = kind.rawValue }
    let body = try JSONEncoder().encode(fields)
    let (data, status) = try await authed(path: "/v1/pair/approve", method: "POST", body: body)
    guard status == 200 else { throw Self.httpError(status, data) }
    return try decode(Approval.self, from: data, what: "pairing").client
  }

  /// The caller's plan (`GET /v1/entitlement`, docs/SYNC_SUBSCRIPTION_SPEC.md
  /// §6). The server decides; the app only shows what it says.
  func entitlement() async throws -> BackendEntitlement {
    let (data, status) = try await authed(path: "/v1/entitlement", method: "GET", body: nil)
    guard status == 200 else { throw Self.httpError(status, data) }
    return try decode(BackendEntitlement.self, from: data, what: "entitlement")
  }

  /// Moves the free account's sync slot to this device
  /// (`POST /v1/entitlement/device`, spec §6.3). Free on every plan.
  func claimSyncDevice() async throws {
    let (data, status) = try await authed(path: "/v1/entitlement/device", method: "POST", body: Data("{}".utf8))
    guard status == 200 else { throw Self.httpError(status, data) }
  }

  /// Hands one StoreKit 2 transaction to the server
  /// (`POST /v1/entitlement/apple`, spec §5). Returns the HTTP status: 200
  /// means the server recorded it; 400 / 403 / 422 mean it never will (bad
  /// signature, another account's token, a product it does not sell). A
  /// network error throws, so the caller keeps the transaction and retries.
  func postAppleTransaction(signedTransaction: String) async throws -> Int {
    let body = try JSONEncoder().encode(["signedTransaction": signedTransaction])
    let (_, status) = try await authed(path: "/v1/entitlement/apple", method: "POST", body: body)
    return status
  }

  // MARK: - Companion device (Apple Watch)

  /// Mints a SEPARATE session for the paired watch (`POST /v1/auth/device`).
  /// Never adopted here: the refresh token rotates, so the phone and the
  /// watch must each own one. The caller hands it over WatchConnectivity.
  func mintDeviceSession() async throws -> BackendSession {
    let (data, status) = try await authed(path: "/v1/auth/device", method: "POST", body: Data("{}".utf8))
    guard status == 200 else { throw Self.httpError(status, data) }
    return try decode(BackendSession.self, from: data, what: "device session")
  }

  // MARK: - Private iCal Feed (IC1)

  func getIcalFeedSettings() async throws -> BackendIcalFeedSettings {
    let (data, status) = try await authed(path: "/v1/ical/settings", method: "GET", body: nil)
    guard status == 200 else { throw Self.httpError(status, data) }
    return try decode(BackendIcalFeedSettings.self, from: data, what: "iCal feed settings")
  }

  func updateIcalFeedSettings(
    enabled: Bool? = nil,
    scope: BackendIcalScope? = nil,
    rotate: Bool? = nil
  ) async throws -> BackendIcalFeedSettings {
    struct Payload: Encodable {
      let enabled: Bool?
      let scope: BackendIcalScope?
      let rotate: Bool?
    }
    let body = try JSONEncoder().encode(Payload(enabled: enabled, scope: scope, rotate: rotate))
    let (data, status) = try await authed(path: "/v1/ical/settings", method: "POST", body: body)
    guard status == 200 else { throw Self.httpError(status, data) }
    return try decode(BackendIcalFeedSettings.self, from: data, what: "iCal feed settings")
  }

  func disableIcalFeed() async throws {
    let (data, status) = try await authed(path: "/v1/ical/settings", method: "DELETE", body: nil)
    guard status == 204 || status == 200 else { throw Self.httpError(status, data) }
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

/// Wire shape of `POST /v1/pair/inspect` (backend/src/api/routes.ts): what a
/// sign-in code asks for, shown to the user before they approve it.
struct BackendPairingRequest: Decodable, Sendable, Equatable {
  enum Kind: String, Decodable, Sendable {
    /// A new device asks to sign in to this account (full app session).
    case device
    /// The Claude connector asks for task access (MCP tokens only).
    case connector
  }
  let kind: Kind
  /// The requester's own name: "Android SM-A175F", or "Claude".
  let client: String
  /// Seconds until the code expires.
  let expiresIn: Int?
}
