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

  /// True when the caller supplied this key at all (including an explicit JSON
  /// null) — distinct from a present-but-empty string, which `string` maps to
  /// nil.
  func has(_ key: String) -> Bool { raw[key] != nil }

  /// Partial-update accessors for NULLABLE fields. Absent key → `nil` (leave the
  /// field unchanged); present → `.some(value)`, where JSON null / empty /
  /// unparseable becomes `.some(nil)` (explicit clear). The double optional is
  /// what lets a patch touch only what the caller sent, instead of bare
  /// `string`/`double` (which a `T?`→`T??` promotion would turn into a silent
  /// `.some(nil)`, blanking every omitted field).
  func doubleField(_ key: String) -> Double?? { has(key) ? .some(double(key)) : nil }
  func stringField(_ key: String) -> String?? { has(key) ? .some(string(key)) : nil }

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

// MARK: - JSON sanitization

/// Coerces an arbitrary `Any` value tree into a guaranteed-valid JSON object.
/// The load-bearing case is non-finite `Double`s (NaN / ±Infinity), which
/// `JSONSerialization` rejects by raising an uncatchable Obj-C exception. Any
/// numeric field sourced from logged data (grams, macros, weight, distance…)
/// could be NaN, so every payload passes through here before serialization.
enum JSONSafe {
  static func coerce(_ value: Any) -> Any {
    switch value {
    case let dict as [String: Any]:
      return dict.mapValues(coerce)
    case let array as [Any]:
      return array.map(coerce)
    case let n as NSNumber:
      // Catches native Swift Bool/Int/Double AND JSONSerialization-parsed
      // numbers (e.g. a re-encoded TaskConvo read by tasks_thread_get).
      // Classify by CFType, NOT `as Bool`: a parsed integer 1/0 ALSO casts
      // `as Bool` via NSNumber bridging, which would emit `true`/`false` for
      // ints — the bug that turned Task-Conversations seq/inReplyTo of 1 into
      // `true`. Real booleans are CFBoolean; non-finite Doubles (NaN/±Inf) → null.
      if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
      return n.doubleValue.isFinite ? n : NSNull()
    case is String, is NSNull:
      return value
    default:
      return String(describing: value)
    }
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
  ///
  /// `data` carries the structured payload some spec-defined errors require —
  /// notably UnsupportedProtocolVersionError, whose `supported` list is how a
  /// client picks a version to retry on.
  static func error(id: Any?, code: Int, _ message: String, data: Any? = nil) -> [String: Any] {
    var error: [String: Any] = ["code": code, "message": message]
    if let data { error["data"] = data }
    return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error]
  }

  /// Wrap a tool's output as an MCP `tools/call` result. `payload` is encoded
  /// to a JSON string inside a single text content block — the shape Claude
  /// expects and the gateway also emits.
  static func toolResult(_ payload: Any, isError: Bool = false) -> [String: Any] {
    // CRITICAL: sanitize before serializing. JSONSerialization.data raises an
    // uncatchable Obj-C NSInvalidArgumentException on an invalid object (most
    // commonly a non-finite Double — NaN/±Inf — from logged numeric data),
    // which `try?` does NOT catch and which wedges the calling (main) actor
    // forever. `coerce` guarantees a valid tree; `isValidJSONObject` is the
    // belt-and-suspenders guard so we never call the throwing API blind.
    let safe = JSONSafe.coerce(payload)
    let text: String
    if JSONSerialization.isValidJSONObject(safe),
       let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
      text = s
    } else {
      text = String(describing: payload)
    }
    return ["content": [["type": "text", "text": text]], "isError": isError]
  }
}
