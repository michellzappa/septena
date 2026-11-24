import Foundation

// The internal API of the import engine (ADR 0021, docs/MOVING_IN_SPEC.md §2).
// Every source adapter produces one `ImportBundle`; the engine accepts nothing
// else. The Codable shape IS the wire shape: plain JSON, camelCase, versioned,
// so a bundle written by one client (or a future TypeScript port) decodes in
// another. Add fields as optionals; a breaking change is a new `version`.

struct ImportBundle: Codable, Sendable, Hashable {
  static let formatName = "septena.import"
  static let currentVersion = 1

  var format: String = ImportBundle.formatName
  var version: Int = ImportBundle.currentVersion
  var source: ImportBundleSource
  var areas: [ImportArea] = []
  var projects: [ImportProject] = []
  var headings: [ImportHeading] = []
  var tasks: [ImportTask] = []
  /// Data the adapter saw but could not put into the bundle at all.
  var unsupported: [ImportUnsupported] = []

  var isEmpty: Bool { areas.isEmpty && projects.isEmpty && tasks.isEmpty }

  /// Refuses a bundle this engine cannot read, and one whose source ids
  /// collide (the engine keys lineage on them).
  func validate() throws {
    guard format == ImportBundle.formatName else { throw ImportError.notABundle }
    guard version == ImportBundle.currentVersion else { throw ImportError.unknownVersion(version) }
    for (entity, ids) in [
      ("area", areas.map(\.sourceId)), ("project", projects.map(\.sourceId)),
      ("heading", headings.map(\.sourceId)), ("task", tasks.map(\.sourceId)),
    ] where Set(ids).count != ids.count {
      throw ImportError.duplicateSourceIDs(entity: entity)
    }
  }
}

struct ImportBundleSource: Codable, Sendable, Hashable {
  /// `ImportSourceDescriptor.id`, e.g. `things`, `microsoft-todo`.
  var app: String
  /// `name@version` of the adapter that wrote the bundle.
  var adapter: String
  /// A label the user recognises (an account email, a file name). Never a secret.
  var account: String?
  var exportedAt: Date
}

/// The source's record as JSON, kept in the batch ledger for recovery.
typealias ImportOriginal = [String: ImportJSON]

struct ImportArea: Codable, Sendable, Hashable {
  var sourceId: String
  var title: String
  var notes: String?
  var emoji: String?
  var position: Double?
  var original: ImportOriginal?
}

enum ImportProjectStatus: String, Codable, Sendable, Hashable {
  case active, done, cancelled
}

struct ImportProject: Codable, Sendable, Hashable {
  var sourceId: String
  var title: String
  /// Owning area, as its `sourceId` in this bundle.
  var area: String?
  var notes: String?
  var status: ImportProjectStatus = .active
  var completedAt: Date?
  var position: Double?
  var original: ImportOriginal?
}

struct ImportHeading: Codable, Sendable, Hashable {
  var sourceId: String
  var title: String
  /// Owning project, as its `sourceId` in this bundle.
  var project: String
  var position: Double?
  var original: ImportOriginal?
}

enum ImportTaskStatus: String, Codable, Sendable, Hashable {
  case open, done, cancelled
}

struct ImportChecklistItem: Codable, Sendable, Hashable {
  var title: String
  var done: Bool
}

/// A reference to what the task is about or came from
/// (docs/TASK_REFERENCES_SPEC.md §9).
struct ImportTaskRef: Codable, Sendable, Hashable {
  /// A reference key, a web URL or a `message://` link.
  var key: String
  /// Nil means `about`.
  var role: TaskRefRole?
  var snapshot: TaskRefSnapshot?
}

struct ImportReminder: Codable, Sendable, Hashable {
  /// Same two shapes as `TaskReminder.fireAt`: wall-clock `YYYY-MM-DDTHH:MM`
  /// (floating) or UTC `YYYY-MM-DDTHH:MM:SSZ` (fixed).
  var fireAt: String
  var mode: TaskReminderMode = .floating
}

struct ImportRecurrence: Codable, Sendable, Hashable {
  var unit: Recurrence.Unit
  var interval: Int = 1
  var afterCompletion: Bool = false
  var weekdays: [Int]?
  var monthDay: Int?
  var ordinalWeekday: RecurrenceOrdinalWeekday?

  var recurrence: Recurrence {
    Recurrence(unit: unit, interval: interval, afterCompletion: afterCompletion,
               weekdays: weekdays, monthDay: monthDay, ordinalWeekday: ordinalWeekday)
  }
}

struct ImportTask: Codable, Sendable, Hashable {
  var sourceId: String
  var title: String
  var notes: String?
  /// Owning containers, as `sourceId`s in this bundle.
  var area: String?
  var project: String?
  var heading: String?
  var status: ImportTaskStatus = .open
  var trashed: Bool = false
  var today: Bool = false
  /// `YYYY-MM-DD`: the day the user plans to work on it.
  var scheduled: String?
  /// `YYYY-MM-DD`: the day it is owed.
  var deadline: String?
  var completedAt: Date?
  var createdAt: Date?
  var position: Double?
  var reminder: ImportReminder?
  var recurrence: ImportRecurrence?
  var checklist: [ImportChecklistItem]?
  var tags: [String]?
  var starred: Bool?
  var sourceURL: String?
  var refs: [ImportTaskRef]?
  var original: ImportOriginal?
}

struct ImportUnsupported: Codable, Sendable, Hashable {
  var entity: String
  var field: String
  var count: Int
  var note: String?
}

/// Untyped JSON for `original`, so any source record survives a round trip.
enum ImportJSON: Codable, Sendable, Hashable {
  case string(String), number(Double), bool(Bool), null
  case array([ImportJSON]), object([String: ImportJSON])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Double.self) { self = .number(v) }
    else if let v = try? c.decode(String.self) { self = .string(v) }
    else if let v = try? c.decode([ImportJSON].self) { self = .array(v) }
    else { self = .object(try c.decode([String: ImportJSON].self)) }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
}

enum ImportError: LocalizedError, Equatable {
  case notABundle
  case unknownVersion(Int)
  case duplicateSourceIDs(entity: String)
  case emptySource
  case batchNotFound
  case legacyBatchNotUndoable

  var errorDescription: String? {
    switch self {
    case .notABundle:
      return String(localized: "This file is not a Septena import.")
    case .unknownVersion(let v):
      return String(localized: "This import was made by a newer version of Septena (format \(v)). Update the app and try again.")
    case .duplicateSourceIDs(let entity):
      return String(localized: "The import contains the same \(entity) twice.")
    case .emptySource:
      return String(localized: "There is nothing to import.")
    case .batchNotFound:
      return String(localized: "That import could not be found on this device.")
    case .legacyBatchNotUndoable:
      return String(localized: "This import ran before Septena kept a record of imports, so it cannot be undone.")
    }
  }
}

extension ImportBundle {
  /// Encoder/decoder pair for the wire shape (ISO-8601 dates, sorted keys so a
  /// bundle diffs cleanly).
  static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.sortedKeys]
    return e
  }()

  static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()
}
