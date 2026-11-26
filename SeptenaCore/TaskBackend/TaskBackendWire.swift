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
  /// The value as JSON text; nil for null.
  var jsonText: String? {
    guard !isNull, let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

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
  case task, area, project, attachment, checklistItem, taskRef, doSession, tag, convo, turn
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

/// `POST /v1/auth/device/start`: a new device's sign-in code (ADR 0016).
struct BackendDeviceCode: Decodable, Sendable, Equatable {
  /// The QR's modules, row by row, "1" dark and "0" light. The client adds
  /// the 4-module quiet zone.
  struct QR: Decodable, Sendable, Equatable {
    let size: Int
    let modules: String

    /// The dark flags, or nil when the matrix is malformed.
    var dark: [Bool]? {
      guard (21...177).contains(size), (size - 17) % 4 == 0, modules.utf8.count == size * size,
            modules.utf8.allSatisfy({ $0 == 0x30 || $0 == 0x31 }) else { return nil }
      return modules.utf8.map { $0 == 0x31 }
    }
  }

  let code: String
  let pollSecret: String
  let expiresIn: Int
  let interval: Int
  let qr: QR?

  var displayCode: String {
    code.count == 8 ? "\(code.prefix(4))-\(code.suffix(4))" : code
  }
}

enum BackendDevicePoll: Sendable {
  case pending
  case expired
  case approved(BackendSession)
}

/// `GET /v1/auth/methods`: the sign-in methods this server has on
/// (docs/SIGN_IN_SURFACES_SPEC.md §3). Ids this build does not know are kept
/// as strings; the screen shows only the ones it implements.
struct BackendAuthMethods: Decodable, Sendable {
  struct Method: Decodable, Sendable {
    let id: String
  }
  let methods: [Method]
}

/// `POST /v1/auth/email/start` answered 202: a code went to the address.
struct BackendEmailCodeSent: Decodable, Sendable, Equatable {
  let status: String
  let expiresInSeconds: Int
  let codeLength: Int

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    status = try c.decode(String.self, forKey: .status)
    expiresInSeconds = try c.decode(Int.self, forKey: .expiresInSeconds)
    codeLength = try c.decode(Int.self, forKey: .codeLength)
    guard status == "sent", expiresInSeconds > 0, (4...12).contains(codeLength) else {
      throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "unexpected email start reply")
    }
  }

  private enum CodingKeys: String, CodingKey { case status, expiresInSeconds, codeLength }
}

/// The refusals of `/v1/auth/email/start` and `/verify`, from their error
/// bodies (`{ error, attemptsLeft?, retryAfterSeconds? }`).
enum BackendEmailSignInError: Error, Equatable, Sendable {
  /// 400: the server did not accept the address or the code shape.
  case invalidRequest
  /// 401 `invalid_code`.
  case wrongCode(attemptsLeft: Int)
  /// 410 `expired_or_unknown`: no live code for this address.
  case expired
  /// 429 `too_many_attempts` on verify: the code is spent.
  case tooManyAttempts
  /// 429 `too_many_requests` on start.
  case rateLimited(retryAfterSeconds: Int?)
  /// 503 `email_signin_off` or `email_send_failed`.
  case unavailable
}

struct BackendEmailErrorBody: Decodable, Sendable {
  let error: String
  let attemptsLeft: Int?
  let retryAfterSeconds: Int?
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

// MARK: - Devices and agents

/// Wire shape of `GET /v1/access` (backend/src/store/TaskStore.ts
/// `AccessSummary`). Times are ms since 1970.
struct BackendAccess: Decodable, Sendable, Equatable {
  struct Device: Decodable, Sendable, Equatable, Identifiable {
    let sid: String
    /// The `X-Septena-Client` name the device sent (`septask-ios`, …); nil
    /// for a device that never named itself.
    let client: String?
    let firstSeen: Double
    let lastSeen: Double
    let current: Bool
    let syncing: Bool
    var id: String { sid }
  }
  /// One agent: an MCP connection (one token family), such as Claude or
  /// Claude Code on one machine.
  struct Connection: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    /// The name the user gave the agent, else `clientName`. Optional so an
    /// older server answer still decodes.
    let name: String?
    /// The name the app registered with (Claude, ChatGPT, …).
    let clientName: String
    let scope: String
    let createdAt: Double
    let lastUsed: Double
    /// What every surface shows for this agent.
    var displayName: String { name ?? clientName }
  }
  /// The agent count and the plan's `connectedAgents` limit (nil = no cap).
  /// The server only logs past the limit. Optional for an older server.
  struct AgentCount: Decodable, Sendable, Equatable {
    let count: Int
    let limit: Int?
  }
  let devices: [Device]
  /// The agents. The wire keeps the name `connections`.
  let connections: [Connection]
  let agents: AgentCount?
  /// The agent count: the server's, else the list length.
  var agentCount: Int { agents?.count ?? connections.count }
}

// MARK: - Project & area notes history (GET /v1/notes/history, #123)

struct BackendNoteRevision: Decodable, Identifiable, Hashable, Sendable {
  let rev: Int
  let actor: String
  let at: String
  let reason: String?
  let body: String?

  var id: Int { rev }
  var byAgent: Bool { actor.hasPrefix("mcp:") }
}

struct BackendNoteHistoryResponse: Decodable, Sendable {
  let container: String
  let id: String
  let noteRev: Int
  let revisions: [BackendNoteRevision]
}
