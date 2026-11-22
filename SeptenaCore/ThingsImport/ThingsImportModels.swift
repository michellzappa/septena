import Foundation

// Intermediate model produced by parsing a Things SQLite export. UI-free so
// the parser is testable without SwiftData. `ThingsImportSource` turns it into
// an `ImportBundle` for the import engine (docs/MOVING_IN_SPEC.md).

// MARK: - Parsed snapshot

struct ThingsDatabaseSnapshot: Sendable {
  var areas: [ThingsAreaRecord]
  var projects: [ThingsProjectRecord]
  var tasks: [ThingsTaskRecord]
  /// Things `type = 2` rows — section dividers inside a project. Map to Septena
  /// headings (`TaskEntity.kind == "heading"`). Defaulted so call sites (and
  /// tests) that predate heading support keep compiling.
  var headings: [ThingsHeadingRecord] = []
}

struct ThingsAreaRecord: Sendable, Identifiable, Hashable {
  var id: String       // Things uuid
  var title: String
  var trashed: Bool
}

struct ThingsProjectRecord: Sendable, Identifiable, Hashable {
  var id: String
  var title: String
  var areaID: String?
  var notes: String?
  var status: ThingsItemStatus
  var trashed: Bool
}

/// A Things `type = 2` section-divider row. Carries a project FK; member tasks
/// reference it via their `heading` column (see `ThingsTaskRecord.headingID`).
struct ThingsHeadingRecord: Sendable, Identifiable, Hashable {
  var id: String            // Things uuid
  var title: String
  var projectID: String?    // owning project (Things uuid)
  /// Things manual order (`index` column) — shared with tasks in the project.
  var sortIndex: Double
}

struct ThingsTaskRecord: Sendable, Identifiable, Hashable {
  var id: String
  var title: String
  var notes: String?
  var areaID: String?
  var projectID: String?
  /// Owning heading (Things `heading` column → a `type = 2` row's uuid), or nil.
  /// Defaulted so pre-heading call sites (and tests) keep compiling.
  var headingID: String? = nil
  var status: ThingsItemStatus
  var trashed: Bool
  /// Things manual order (`index` column).
  var sortIndex: Double
  var today: Bool
  var scheduled: Date?
  var deadline: Date?
  var created: Date?
  var completedAt: Date?
  var tags: [String]
  var checklistLines: [String]
}

enum ThingsItemStatus: Int, Sendable, Hashable {
  case open = 0
  case cancelled = 2
  case completed = 3
}

// MARK: - Parser options

struct ThingsImportOptions: Sendable, Hashable {
  var includeCompleted = false
  var includeCancelled = false
  var includeTrashed = false
}

// MARK: - Errors

enum ThingsImportError: LocalizedError, Equatable {
  case databaseNotFound
  case sqliteOpenFailed(String)
  case sqliteQueryFailed(String)
  case emptyDatabase
  case notThingsDatabase(foundTables: [String])

  var errorDescription: String? {
    switch self {
    case .databaseNotFound:
      return String(localized: "Could not find main.sqlite in the chosen file.")
    case .sqliteOpenFailed(let detail):
      return String(localized: "Could not open the Things database (\(detail)).")
    case .sqliteQueryFailed(let detail):
      return String(localized: "Could not read the Things database (\(detail)).")
    case .emptyDatabase:
      return String(localized: "The Things database contains no importable tasks.")
    case .notThingsDatabase(let tables):
      if tables.isEmpty {
        return String(localized: "This file is not a Things database (no tables found). Pick main.sqlite from inside Things Database.thingsdatabase, or the bundle itself.")
      }
      let sample = tables.prefix(8).joined(separator: ", ")
      return String(localized: "This file is not a Things database (TMTask table missing). Found: \(sample)\(tables.count > 8 ? ", …" : "").")
    }
  }
}
