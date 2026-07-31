import Foundation
import Network
import Observation

// In-process MCP server for the Mac app. Binds a loopback-only HTTP listener
// that a local Claude Code instance connects to as a streamable-HTTP MCP
// server:
//
//   claude mcp add --transport http septena-local \
//     http://127.0.0.1:7717/mcp --header "Authorization: Bearer <token>"
//
// Why in-process instead of a stdio shim: SeptenaServices is a @MainActor
// singleton living in the running GUI app, already authenticated to CloudKit
// as the signed-in user. Serving here means tool calls go straight through the
// app's own mutators — no web token, no Cloudflare hop, works offline.
//
// SECURITY: bound to 127.0.0.1 ONLY (requiredInterfaceType = .loopback) and
// gated behind a bearer token, because any local process can reach a loopback
// port. The token is generated in Settings and required on every request.

/// UserDefaults keys for the local MCP server, defined in SeptenaCore so both
/// the server (here) and the app's `SettingsKey` facade read the same strings.
public enum MCPDefaultsKey {
  /// Bool — master switch for the loopback server (macOS only).
  public static let enabled = "septena.dev.localMcpEnabled"
  /// Legacy UserDefaults location for the bearer token. Read once and migrated
  /// into Keychain; new tokens are never persisted here.
  public static let token = "septena.dev.localMcpToken"
  /// String — `MCPAccessScope` raw value (which networks may connect).
  public static let scope = "septena.dev.localMcpScope"
  /// Bool — when the server is on, keep the app alive after ⌘Q (soft-quit to
  /// the menu bar) so it keeps serving. Off by default: ⌘Q quits normally.
  public static let keepAlive = "septena.dev.localMcpKeepAlive"
}

/// Observable live state for the local MCP server, so menu-bar / Settings UI
/// can reflect "listening" and recent activity without polling. Kept separate
/// from `LocalMCPServer` (which isn't `@Observable` and runs its socket work
/// off the main actor) — the server pokes this on the main actor whenever its
/// state changes or an authorized request lands.
@MainActor
@Observable
public final class LocalMCPStatus {
  public static let shared = LocalMCPStatus()
  private init() {}

  /// True while the loopback listener is bound.
  public private(set) var isRunning = false
  /// When the server last served an authorized request. Drives the
  /// "active recently" indicator; nil until the first call lands (and reset
  /// whenever the server stops).
  public private(set) var lastActivity: Date?

  func setRunning(_ running: Bool) {
    isRunning = running
    if !running { lastActivity = nil }
  }

  func markActivity() { lastActivity = Date() }

  /// True when a request landed within `seconds` — the "green dot" window.
  public func isActive(within seconds: TimeInterval = 120) -> Bool {
    guard let lastActivity else { return false }
    return Date().timeIntervalSince(lastActivity) < seconds
  }
}

@MainActor
final class LocalMCPServer {
  static let shared = LocalMCPServer()

  /// Fixed loopback port. Stable so the `claude mcp add` command in Settings
  /// never changes out from under an existing registration.
  let port: UInt16 = 7717

  private var listener: NWListener?
  var isRunning: Bool { listener != nil }

  /// Dedicated network queue. The listener and every connection run here —
  /// NOT on `.main` — so HTTP receive/parse/send never contend with the app's
  /// SwiftUI rendering on the main thread. (Running on main caused callbacks to
  /// stall under load: connections piled up in CLOSE_WAIT and the server
  /// wedged after a handful of requests.) Only the actual data access hops to
  /// the main actor, inside `MCPDispatch.handle`.
  private let netQueue = DispatchQueue(label: "cloud.septena.localmcp", qos: .userInitiated, attributes: .concurrent)

  private init() {}

  // MARK: - Lifecycle

  func start() throws {
    guard listener == nil else { return }
    // Mutators must be bound before we can serve a write. start() is
    // idempotent; callers (Settings toggle, launch) may race harmlessly.
    Task { await SeptenaServices.shared.start() }

    // Bind all interfaces; access is gated per-connection by source IP
    // (`MCPAddressGuard`) against the active scope, plus the bearer token.
    // Interface-restriction can't express "tailnet" (Tailscale is an
    // anonymous utun), so the allowlist lives at accept time.
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true

    let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    l.stateUpdateHandler = { state in
      if case .failed(let err) = state {
        SeptenaLog.error("[LocalMCP] listener failed: \(err)")
      }
    }
    l.newConnectionHandler = { [weak self] conn in
      // Drop connections whose source address isn't allowed by the scope
      // before they send a byte — token check never even runs for them.
      let scope = MCPAccessScope.current
      if case let .hostPort(host, _) = conn.endpoint,
         let bytes = NWHostBytes(host),
         MCPAddressGuard.allows(host: bytes, scope: scope) {
        conn.start(queue: self?.netQueue ?? .global())
        self?.receive(on: conn, buffer: Data())
      } else {
        conn.cancel()
      }
    }
    l.start(queue: netQueue)
    listener = l
    LocalMCPStatus.shared.setRunning(true)
    SeptenaLog.info("[LocalMCP] listening on :\(port) scope=\(MCPAccessScope.current.rawValue)")
  }

  func stop() {
    listener?.cancel()
    listener = nil
    LocalMCPStatus.shared.setRunning(false)
    SeptenaLog.info("[LocalMCP] stopped")
  }

  // MARK: - HTTP framing
  //
  // Minimal HTTP/1.1: read until we have full headers + Content-Length bytes,
  // dispatch one JSON-RPC request, write one response, close. No keep-alive —
  // one request per connection keeps the parser trivial and is plenty for
  // Claude Code's request cadence.

  nonisolated private func receive(on conn: NWConnection, buffer: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
      guard let self else { return }
      var buf = buffer
      if let chunk { buf.append(chunk) }

      if let (headers, body, complete) = Self.parse(buf) {
        if complete {
          // Run off-main; only the data access inside MCPDispatch.handle hops
          // to the main actor. Keeps the netQueue free to accept/close sockets.
          Task { await self.handle(headers: headers, body: body, conn: conn) }
          return
        }
      }
      if error != nil || isComplete {
        conn.cancel()
        return
      }
      self.receive(on: conn, buffer: buf)   // need more bytes
    }
  }

  /// Returns (headerLines, body, isBodyComplete) once the header terminator is
  /// seen; nil while headers are still partial.
  nonisolated private static func parse(_ data: Data) -> (lines: [String], body: Data, complete: Bool)? {
    let sep = Data("\r\n\r\n".utf8)
    guard let r = data.range(of: sep) else { return nil }
    let headerData = data.subdata(in: data.startIndex..<r.lowerBound)
    let body = data.subdata(in: r.upperBound..<data.endIndex)
    let lines = (String(data: headerData, encoding: .utf8) ?? "")
      .components(separatedBy: "\r\n")
    let contentLength = lines
      .first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
    return (lines, body, body.count >= contentLength)
  }

  /// Case-insensitive lookup over the raw header lines. Header *names* are
  /// case-insensitive per RFC 9110 and clients vary (`Mcp-Method` vs
  /// `MCP-Method`), so every read goes through here.
  nonisolated private static func headerValue(_ name: String, in headers: [String]) -> String? {
    let needle = name.lowercased() + ":"
    guard let line = headers.first(where: { $0.lowercased().hasPrefix(needle) }),
          let separator = line.firstIndex(of: ":") else { return nil }
    let value = line[line.index(after: separator)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  nonisolated private func handle(headers: [String], body: Data, conn: NWConnection) async {
    // --- Transport preconditions (MCP 2026-07-28 Streamable HTTP) ---------
    //
    // Origin validation is a spec MUST and a real hole for this server: it
    // binds all interfaces (the tailnet scope can't be expressed as an
    // interface restriction), so without this a web page the user visits
    // could DNS-rebind to 127.0.0.1:7717 and drive their whole life database.
    // No legitimate caller sends Origin — Claude Code's MCP client is not a
    // browser — so any Origin at all is rejected.
    if let origin = Self.headerValue("Origin", in: headers) {
      SeptenaLog.error("[LocalMCP] rejected cross-origin request from \(origin)")
      respond(conn, status: "403 Forbidden", json: ["error": "cross-origin requests are not allowed"])
      return
    }

    // The GET stream and session-terminating DELETE were removed in
    // 2026-07-28. Answer 405 rather than falling through to a JSON-RPC parse
    // error, so an older client fails fast and falls back.
    let requestLine = headers.first ?? ""
    let verb = requestLine.split(separator: " ").first.map(String.init)?.uppercased() ?? ""
    if verb == "GET" || verb == "DELETE" {
      respond(conn, status: "405 Method Not Allowed", json: ["error": "use POST"])
      return
    }

    // --- Auth: require the configured bearer token on every request. ---
    guard let token = LocalMCPServer.token, !token.isEmpty else {
      respond(conn, status: "503 Service Unavailable",
              json: ["error": "local MCP token not configured"])
      return
    }
    guard let header = headers.first(where: {
      $0.lowercased().hasPrefix("authorization:")
    }), Self.isAuthorized(header: header, token: token) else {
      respond(conn, status: "401 Unauthorized", json: ["error": "invalid or missing bearer token"])
      return
    }
    // An authenticated request landed — light up the menu-bar "active" dot.
    await MainActor.run { LocalMCPStatus.shared.markActivity() }

    // --- Decode the JSON-RPC request. ---
    guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
          obj["jsonrpc"] as? String == "2.0",
          let method = obj["method"] as? String else {
      respond(conn, status: "200 OK", json: JSONRPC.error(id: nil, code: -32600, "Invalid Request"))
      return
    }
    let id = obj["id"]
    let params = obj["params"] as? [String: Any]

    let response = await MCPDispatch.handle(
      method: method, id: id, params: params,
      header: { Self.headerValue($0, in: headers) })
    respond(conn, status: response.statusLine, json: response.body)
  }

  nonisolated private func respond(_ conn: NWConnection, status: String, json: [String: Any]?) {
    var bodyData = Data()
    if let json {
      // Guard against the uncatchable Obj-C exception JSONSerialization raises
      // on an invalid object (e.g. a stray NaN). Validate first; on the off
      // chance it's still invalid, emit a JSON error rather than wedging.
      if JSONSerialization.isValidJSONObject(json),
         let d = try? JSONSerialization.data(withJSONObject: json) {
        bodyData = d
      } else {
        bodyData = Data(#"{"error":"response serialization failed"}"#.utf8)
      }
    }
    var head = "HTTP/1.1 \(status)\r\n"
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: \(bodyData.count)\r\n"
    head += "Connection: close\r\n\r\n"
    var out = Data(head.utf8)
    out.append(bodyData)
    conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
  }

  // MARK: - Token

  private nonisolated static let tokenKeychainAccount = "septena.dev.localMcpToken"

  /// Bearer token shared with Claude Code. It is device-local because it
  /// authorizes a listener on this specific Mac; the old UserDefaults value is
  /// migrated once so existing Claude Code registrations keep working.
  nonisolated static var token: String? {
    if let secured = KeychainStore.load(account: tokenKeychainAccount), !secured.isEmpty {
      return secured
    }
    guard let legacy = UserDefaults.standard.string(forKey: MCPDefaultsKey.token),
          !legacy.isEmpty else { return nil }
    KeychainStore.store(legacy, account: tokenKeychainAccount, synchronizable: false)
    UserDefaults.standard.removeObject(forKey: MCPDefaultsKey.token)
    return legacy
  }

  /// Generate and persist a fresh token. Called from Settings on first enable
  /// or when the user rotates it.
  @discardableResult
  nonisolated static func regenerateToken() -> String {
    let t = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    KeychainStore.store(t, account: tokenKeychainAccount, synchronizable: false)
    UserDefaults.standard.removeObject(forKey: MCPDefaultsKey.token)
    return t
  }

  /// Parse a single Authorization header exactly. Substring matching would
  /// accept a valid token followed by arbitrary bytes, which is not a bearer
  /// credential comparison.
  nonisolated private static func isAuthorized(header: String, token: String) -> Bool {
    guard let separator = header.firstIndex(of: ":") else { return false }
    let name = header[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
    guard name.caseInsensitiveCompare("Authorization") == .orderedSame else { return false }
    let parts = header[header.index(after: separator)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count == 2,
          String(parts[0]).caseInsensitiveCompare("Bearer") == .orderedSame else { return false }
    return constantTimeEquals(String(parts[1]), token)
  }

  nonisolated private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    var mismatch: UInt8 = 0
    for (left, right) in zip(a, b) { mismatch |= left ^ right }
    return mismatch == 0
  }
}
