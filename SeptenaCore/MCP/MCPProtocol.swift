import Foundation

// JSON-RPC 2.0 / MCP envelope plumbing for the in-process local server.
//
// This is the on-the-wire contract Claude Code speaks when it connects to
// `http://127.0.0.1:7717/mcp`. It is deliberately a tiny mirror of the hosted
// gateway's `src/mcp.ts` handshake (initialize / ping / tools/list /
// tools/call) so the local server and the cloud connector are
// indistinguishable to the client — same protocol version, same result shapes.
//
// MIRROR: ../septena-mcp-gateway/src/mcp.ts (handler switch). Keep the method
// names and result envelopes in sync when the gateway's handshake evolves.

// MARK: - Tool declaration

/// One MCP tool: name, human description, and a JSON-Schema input contract.
/// `inputSchema` is a raw JSON object (the `[String: Any]` that serializes to
/// the schema literal) — mirrored by hand from the gateway's `*JsonSchema`
/// consts so `tools/list` is byte-compatible with the cloud connector.
struct MCPTool {
  let name: String
  let description: String
  let inputSchema: [String: Any]

  var listEntry: [String: Any] {
    ["name": name, "description": description, "inputSchema": inputSchema]
  }
}

// MARK: - Errors

enum MCPError: Error {
  /// A tool name that isn't in the catalog (or whose section is disabled).
  case unknownTool(String)
  /// Bad / missing arguments — surfaced to the model as an `isError` tool
  /// result so it can correct itself, never as a transport-level failure.
  case badArgument(String)
  /// A write the underlying mutator rejected (e.g. recurring-task complete).
  case rejected(String)

  var message: String {
    switch self {
    case .unknownTool(let n):  return "Unknown tool: \(n)"
    case .badArgument(let m):  return "Invalid argument: \(m)"
    case .rejected(let m):     return m
    }
  }
}

// MARK: - Argument reader

/// Thin typed accessor over a `tools/call` `arguments` object. Mirrors the
/// coercions the gateway does in TypeScript (string dates stay strings; we
/// convert to `Date` only at the mutator boundary).
struct MCPArgs {
  let raw: [String: Any]

  init(_ raw: [String: Any]?) { self.raw = raw ?? [:] }

  func string(_ key: String) -> String? {
    (raw[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Required string — throws `badArgument` when absent, so the model gets a
  /// precise correction instead of a silent no-op.
  func requireString(_ key: String) throws -> String {
    guard let v = string(key) else { throw MCPError.badArgument("missing '\(key)'") }
    return v
  }

  func bool(_ key: String) -> Bool? {
    if let b = raw[key] as? Bool { return b }
    if let n = raw[key] as? NSNumber { return n.boolValue }
    return nil
  }

  func int(_ key: String) -> Int? {
    if let n = raw[key] as? NSNumber { return n.intValue }
    if let s = raw[key] as? String { return Int(s) }
    return nil
  }

  func double(_ key: String) -> Double? {
    if let n = raw[key] as? NSNumber { return n.doubleValue }
    if let s = raw[key] as? String { return Double(s) }
    return nil
  }

  func stringArray(_ key: String) -> [String]? {
    (raw[key] as? [Any])?.compactMap { $0 as? String }
  }

  func object(_ key: String) -> [String: Any]? { raw[key] as? [String: Any] }

  /// True when the caller explicitly sent the key (even as JSON `null`). Lets
  /// update-style tools distinguish "leave unchanged" from "clear to nil",
  /// matching the gateway's `input.x !== undefined` checks.
  func present(_ key: String) -> Bool { raw.keys.contains(key) }

  /// A `YYYY-MM-DD` string parsed to a `Date` via the app's canonical
  /// formatter. Returns nil for absent/empty/`null`; throws on a malformed
  /// non-empty value so typos surface instead of silently dropping the date.
  func date(_ key: String) throws -> Date? {
    guard let s = string(key) else { return nil }
    guard let d = SeptenaDate.parse(s) else {
      throw MCPError.badArgument("'\(key)' must be YYYY-MM-DD, got '\(s)'")
    }
    return d
  }
}

// MARK: - JSON-RPC response builders

enum JSONRPC {
  /// A successful result envelope for the given request id.
  static func result(id: Any?, _ result: Any) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
  }

  /// A protocol-level error (bad request, method not found). Distinct from a
  /// *tool* error, which rides inside a successful `result` as `isError`.
  static func error(id: Any?, code: Int, _ message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(),
     "error": ["code": code, "message": message]]
  }

  /// Wrap a tool's output as an MCP `tools/call` result. `payload` is encoded
  /// to a JSON string inside a single text content block — the shape Claude
  /// expects and the gateway also emits.
  static func toolResult(_ payload: Any, isError: Bool = false) -> [String: Any] {
    let text: String
    if let data = try? JSONSerialization.data(withJSONObject: payload,
                                               options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
      text = s
    } else {
      text = String(describing: payload)
    }
    return ["content": [["type": "text", "text": text]], "isError": isError]
  }
}
