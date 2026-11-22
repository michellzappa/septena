import CryptoKit
import Foundation

// Wire types for the task backend (docs/SEPTASK_BACKEND.md §5, §6), mirrored
// from `../septena-mcp-gateway/src/store/columns.ts` and `src/store/ops.ts`.
// Phase 1 only (the one-shot import). Response decoding is strict: an unknown
// status or entity fails the decode, and the import stops (fail closed).

// MARK: - JSON value

/// A JSON value. Row fields go out and come back in this shape, so the import
/// can compare what it sent with what the server stored, field by field.
enum BackendJSON: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([BackendJSON])
  case object([String: BackendJSON])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    if let v = try? c.decode(Bool.self) { self = .bool(v); return }
    if let v = try? c.decode(Int64.self) { self = .int(v); return }
    if let v = try? c.decode(Double.self) { self = .double(v); return }
    if let v = try? c.decode(String.self) { self = .string(v); return }
    if let v = try? c.decode([BackendJSON].self) { self = .array(v); return }
    if let v = try? c.decode([String: BackendJSON].self) { self = .object(v); return }
    throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .int(let v): try c.encode(v)
    case .double(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }

  static func from(_ s: String?) -> BackendJSON { s.map { .string($0) } ?? .null }
  static func from(_ i: Int?) -> BackendJSON { i.map { .int(Int64($0)) } ?? .null }
  static func from(_ d: Double?) -> BackendJSON { d.map { .double($0) } ?? .null }

  var stringValue: String? { if case .string(let s) = self { return s }; return nil }
  var isNull: Bool { self == .null }

  /// A stable text form: object keys sorted, and a number prints the same
  /// whether it arrived as `1` or `1.0`. Two values with equal canonical text
  /// are equal for the import's purposes.
  var canonical: String {
    switch self {
    case .null: return "null"
    case .bool(let v): return v ? "true" : "false"
    case .int(let v): return String(v)
    case .double(let v):
      if v.isFinite, v == v.rounded(), abs(v) < 9_007_199_254_740_992 { return String(Int64(v)) }
      return String(v)
    case .string(let v): return String(reflecting: v)
    case .array(let v): return "[" + v.map(\.canonical).joined(separator: ",") + "]"
    case .object(let v):
      return "{" + v.keys.sorted().map { "\(String(reflecting: $0)):\(v[$0]!.canonical)" }
        .joined(separator: ",") + "}"
    }
  }
}

// MARK: - Entities

enum BackendEntity: String, Codable, Sendable, CaseIterable {
  case task, area, project, attachment, checklistItem, tag, convo, turn
  /// Septask's synced settings, one row per key (TaskSyncSettings.swift).
  case setting
}

// MARK: - Push

/// One push op. Kept as a ready-made JSON object so the batch encodes exactly
/// what was validated.
struct BackendOp: Sendable {
  let clientOpId: String
  let body: BackendJSON
  /// What the op is about, for the report (`task 3F2A…`).
  let entity: BackendEntity
  let id: String

  static func upsert(_ entity: BackendEntity, id: String, fields: [String: BackendJSON]) -> BackendOp {
    let opId = clientOpID("upsert", entity.rawValue, id, BackendJSON.object(fields).canonical)
    return BackendOp(clientOpId: opId, body: .object([
      "clientOpId": .string(opId), "op": .string("upsert"),
      "entity": .string(entity.rawValue), "id": .string(id), "fields": .object(fields),
    ]), entity: entity, id: id)
  }

  static func delete(_ entity: BackendEntity, id: String) -> BackendOp {
    let opId = clientOpID("delete", entity.rawValue, id)
    return BackendOp(clientOpId: opId, body: .object([
      "clientOpId": .string(opId), "op": .string("delete"),
      "entity": .string(entity.rawValue), "id": .string(id),
    ]), entity: entity, id: id)
  }

  /// `index` is the turn's place in the task's local thread, so two identical
  /// turns on one task still get two different op ids.
  static func appendTurn(taskID: String, index: Int, turn: [String: BackendJSON]) -> BackendOp {
    let opId = clientOpID("appendTurn", taskID, String(index), BackendJSON.object(turn).canonical)
    return BackendOp(clientOpId: opId, body: .object([
      "clientOpId": .string(opId), "op": .string("appendTurn"),
      "taskId": .string(taskID), "turn": .object(turn),
    ]), entity: .turn, id: "\(taskID)#\(index + 1)")
  }

  /// Deterministic: the same op with the same content always gets the same
  /// id, so a retried batch dedupes on the server (`client_ops`, 30 days).
  /// Matches the server rule `^[A-Za-z0-9_-]{8,64}$`.
  private static func clientOpID(_ parts: String...) -> String {
    let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "imp1-" + hex.prefix(40)
  }
}

struct BackendPushBody: Encodable {
  let ops: [BackendJSON]
}

struct BackendOpResult: Decodable, Sendable {
  enum Status: String, Decodable, Sendable { case applied, noop, dropped, rejected }
  let clientOpId: String
  let status: Status
  let rev: Int?
  let seq: Int?
  let reason: String?
}

struct BackendPushResponse: Decodable, Sendable {
  let appliedThrough: Int
  let results: [BackendOpResult]
}

// MARK: - Pull

struct BackendPullChange: Decodable, Sendable {
  let entity: BackendEntity
  let row: [String: BackendJSON]
}

struct BackendPullResponse: Decodable, Sendable {
  let resetRequired: Bool?
  let changes: [BackendPullChange]
  let nextSince: Int
  let hasMore: Bool
}

// MARK: - Auth

struct BackendSession: Decodable, Sendable {
  let accessToken: String
  let refreshToken: String
  let expiresIn: Int
  let userId: String
}

// MARK: - iCal Feed (IC1)

enum BackendIcalScope: String, Codable, CaseIterable, Identifiable, Sendable {
  case all
  case timed

  var id: String { rawValue }
}

struct BackendIcalFeedSettings: Codable, Equatable, Sendable {
  let enabled: Bool
  let scope: BackendIcalScope
  let url: String?
  let webcalUrl: String?
  let createdAt: String?
}

// MARK: - Errors

/// The Worker's error body: `{ error, issues? }`. `issues` are Zod issues; the
/// import reads `path` to find which op in a refused batch was at fault.
struct BackendErrorBody: Decodable, Sendable {
  struct Issue: Decodable, Sendable {
    let path: [BackendJSON]?
    let message: String?
  }
  let error: String
  let issues: [Issue]?
}
