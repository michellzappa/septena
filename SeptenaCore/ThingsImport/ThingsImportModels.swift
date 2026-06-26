import Foundation

// Intermediate model produced by parsing a Things SQLite export. UI-free so
// mapper + parser are testable without SwiftData.

// MARK: - Parsed snapshot

struct ThingsDatabaseSnapshot: Sendable {
  var areas: [ThingsAreaRecord]
  var projects: [ThingsProjectRecord]
  var tasks: [ThingsTaskRecord]
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

struct ThingsTaskRecord: Sendable, Identifiable, Hashable {
  var id: String
  var title: String
  var notes: String?
  var areaID: String?
  var projectID: String?
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

// MARK: - Import options

struct ThingsImportOptions: Sendable, Hashable {
  var includeCompleted = false
  var includeCancelled = false
  var includeTrashed = false
  var mergeMatchingTitles = true
  var appendTagsToNotes = true
  var appendChecklistToNotes = true
  /// Re-create tasks whose Septena row was deleted since the last import.
  var reimportDeleted = false
}

// MARK: - Collision resolution

enum ThingsCollisionKind: String, Sendable, Hashable {
  case area
  case project
}

enum ThingsCollisionAction: String, Sendable, Hashable, CaseIterable {
  case merge
  case createNew
  case skip
}

struct ThingsCollision: Sendable, Identifiable, Hashable {
  var id: String { thingsID }
  let kind: ThingsCollisionKind
  let thingsID: String
  let thingsTitle: String
  let existingSeptenaID: String?
  let existingSeptenaTitle: String?
  var action: ThingsCollisionAction
}

// MARK: - Import plan (mapper output)

struct ThingsImportPlan: Sendable {
  var areasToCreate: [ThingsPlannedArea]
  var projectsToCreate: [ThingsPlannedProject]
  var tasksToImport: [ThingsPlannedTask]
  var collisions: [ThingsCollision]
  var skippedDuplicates: Int
  var viewCounts: ThingsSeptenaViewCounts
  /// Every Things area uuid → resolved Septena id (includes merges).
  var areaIDByThingsID: [String: String]
  /// Every Things project uuid → resolved Septena id (includes merges).
  var projectIDByThingsID: [String: String]
}

struct ThingsPlannedArea: Sendable, Hashable {
  let thingsID: String
  let title: String
  let septenaID: String
  let isMerge: Bool
}

struct ThingsPlannedProject: Sendable, Hashable {
  let thingsID: String
  let title: String
  let septenaID: String
  let areaSeptenaID: String?
  let notes: String?
  let status: ThingsMappedProjectStatus
  let isMerge: Bool
}

struct ThingsPlannedTask: Sendable, Hashable {
  let thingsID: String
  let title: String
  let notes: String?
  let areaSeptenaID: String?
  let projectSeptenaID: String?
  let today: Bool
  let scheduled: Date?
  let deadline: Date?
  let position: Double
  let status: ThingsMappedTaskStatus
  let trashed: Bool
  let skipBecauseMapped: Bool
}

enum ThingsMappedProjectStatus: Sendable, Hashable {
  case active
  case done
  case cancelled
}

enum ThingsMappedTaskStatus: Sendable, Hashable {
  case open
  case done
  case cancelled
}

struct ThingsSeptenaViewCounts: Sendable, Hashable {
  var inbox = 0
  var today = 0
  var upcoming = 0
  var anytime = 0
  var logbook = 0
  var recentlyDeleted = 0
}

// MARK: - Apply result

struct ThingsImportApplyResult: Sendable {
  var areasCreated = 0
  var areasMerged = 0
  var projectsCreated = 0
  var projectsMerged = 0
  var tasksImported = 0
  var tasksSkipped = 0
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
