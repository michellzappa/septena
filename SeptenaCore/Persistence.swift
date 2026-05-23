import CloudKit
import Foundation
import SwiftData

// Local SwiftData mirror of the Septena server. Server stays authoritative;
// this is a cache so the UI can render and accept input without a round-trip.
// Wire DTOs in Models.swift remain unchanged — we convert at the boundary.
//
// ⚠️  When adding a new label-style entity (anything users will rename and
//     reference by name, like areas/projects/chores/habits/sections), use
//     the uniform `id + title` model documented in
//     [IDENTIFIERS.md](IDENTIFIERS.md). Tasks-style content entities are
//     exempt (id-only). Areas/Projects still carry legacy slug columns
//     until the SwiftData schema can drop them safely, but current code
//     does not read or write those fields.

// MARK: - Entities

@Model
final class TaskEntity {
  @Attribute(.unique) var id: String
  var title: String
  var statusRaw: String
  var created: String?
  var scheduled: String?
  var due: String?
  var today: Bool
  var todaySetOn: String?
  var completedAt: String?
  var area: String?
  var project: String?
  var notes: String?
  var recurrenceUnit: String?
  var recurrenceInterval: Int
  var recurrenceAfterCompletion: Bool
  /// Bumped every time we apply a server payload. Lets the syncer detect
  /// rows that the latest pull didn't touch (= server-side deletions).
  var lastSyncedAt: Date
  /// Position in the most recent server response. Cache reads sort by this
  /// so the painted-from-cache order matches what the network refresh will
  /// produce — otherwise rows visibly reshuffle on every cold open.
  var sortIndex: Int
  /// True while one or more `OutboxEntity` rows reference this task. The
  /// Syncer will not overwrite local fields on a row with `pendingSync ==
  /// true` — we don't want a server snapshot taken before the user's
  /// optimistic write to clobber the local state. Cleared by TaskMutator
  /// once the queue for this id is empty.
  var pendingSync: Bool = false
  /// True between the moment `TaskMutator.delete(id:)` is called and the
  /// drainer confirming the server-side delete. `LocalCache` filters rows
  /// with `pendingDeletion == true` so the UI hides them immediately. If
  /// the network call ultimately fails the flag is cleared and the row
  /// resurrects in the list.
  var pendingDeletion: Bool = false
  /// Server-stamped `updated_at` (mirrored from the DTO). Used by the
  /// delta-sync watermark — `Syncer.pullChanges()` sends the max
  /// updatedAt back as `since` on the next call.
  var updatedAt: String?
  /// Server-stamped tombstone. When set, the row is logically deleted
  /// — Syncer purges it locally during the next apply.
  var deletedAt: String?
  /// CKRecord system-fields blob (NSKeyedArchiver-encoded). Captured the
  /// first time we see a record from CloudKit (or after our own save is
  /// acked) so subsequent uploads preserve the recordChangeTag and avoid
  /// 409s. Nil for rows that haven't round-tripped through CloudKit yet
  /// (pre-migration FastAPI rows, or rows authored offline before the
  /// engine drained). The CloudKit path on `TaskRecord` reads / writes
  /// this transparently — call sites don't need to think about it.
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       statusRaw: String = TaskStatus.open.rawValue,
       created: String? = nil,
       scheduled: String? = nil,
       due: String? = nil,
       today: Bool = false,
       todaySetOn: String? = nil,
       completedAt: String? = nil,
       area: String? = nil,
       project: String? = nil,
       notes: String? = nil,
       recurrenceUnit: String? = nil,
       recurrenceInterval: Int = 1,
       recurrenceAfterCompletion: Bool = true,
       lastSyncedAt: Date = .distantPast,
       sortIndex: Int = 0,
       pendingSync: Bool = false,
       pendingDeletion: Bool = false,
       updatedAt: String? = nil,
       deletedAt: String? = nil,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.statusRaw = statusRaw
    self.created = created
    self.scheduled = scheduled
    self.due = due
    self.today = today
    self.todaySetOn = todaySetOn
    self.completedAt = completedAt
    self.area = area
    self.project = project
    self.notes = notes
    self.recurrenceUnit = recurrenceUnit
    self.recurrenceInterval = recurrenceInterval
    self.recurrenceAfterCompletion = recurrenceAfterCompletion
    self.lastSyncedAt = lastSyncedAt
    self.sortIndex = sortIndex
    self.pendingSync = pendingSync
    self.pendingDeletion = pendingDeletion
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }

  var status: TaskStatus {
    get { TaskStatus(rawValue: statusRaw) ?? .open }
    set { statusRaw = newValue.rawValue }
  }

  var recurrence: Recurrence? {
    get {
      guard let unit = recurrenceUnit.flatMap(Recurrence.Unit.init(rawValue:)) else { return nil }
      return Recurrence(unit: unit,
                        interval: recurrenceInterval,
                        afterCompletion: recurrenceAfterCompletion)
    }
    set {
      recurrenceUnit = newValue?.unit.rawValue
      recurrenceInterval = newValue?.interval ?? 1
      recurrenceAfterCompletion = newValue?.afterCompletion ?? true
    }
  }
}

@Model
final class ProjectEntity {
  @Attribute(.unique) var id: String
  var title: String
  var statusRaw: String
  var area: String?
  var created: String?
  var completedAt: String?
  var notes: String?
  var context: String?
  var githubRepo: String?
  var lastSyncedAt: Date
  var updatedAt: String?
  var deletedAt: String?
  /// CKRecord system-fields blob. See `TaskEntity.cloudKitSystemFields` for
  /// the same contract — captured on round-trip through CloudKit so the
  /// next save preserves recordChangeTag.
  var cloudKitSystemFields: Data?
  /// Legacy transition column from the removed slug model. Kept only to
  /// avoid a destructive SwiftData schema change during the CloudKit
  /// migration; current code leaves it nil and does not resolve by it.
  var slug: String?
  /// Legacy transition column from the removed slug model. Current code
  /// leaves it empty and does not resolve by it.
  var previousSlugs: [String] = []

  init(id: String,
       title: String,
       statusRaw: String = ProjectStatus.active.rawValue,
       area: String? = nil,
       created: String? = nil,
       completedAt: String? = nil,
       notes: String? = nil,
       context: String? = nil,
       githubRepo: String? = nil,
       lastSyncedAt: Date = .distantPast,
       updatedAt: String? = nil,
       deletedAt: String? = nil,
       cloudKitSystemFields: Data? = nil,
       slug: String? = nil,
       previousSlugs: [String] = []) {
    self.id = id
    self.title = title
    self.statusRaw = statusRaw
    self.area = area
    self.created = created
    self.completedAt = completedAt
    self.notes = notes
    self.context = context
    self.githubRepo = githubRepo
    self.lastSyncedAt = lastSyncedAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.cloudKitSystemFields = cloudKitSystemFields
    self.slug = slug
    self.previousSlugs = previousSlugs
  }

  var status: ProjectStatus {
    get { ProjectStatus(rawValue: statusRaw) ?? .active }
    set { statusRaw = newValue.rawValue }
  }
}

@Model
final class AreaEntity {
  @Attribute(.unique) var id: String
  var title: String
  var context: String?
  var lastSyncedAt: Date
  var updatedAt: String?
  /// CKRecord system-fields blob. See `TaskEntity.cloudKitSystemFields`.
  var cloudKitSystemFields: Data?
  /// Legacy transition column from the removed slug model. See
  /// ProjectEntity.slug.
  var slug: String?
  /// Legacy transition column from the removed slug model. See
  /// ProjectEntity.previousSlugs.
  var previousSlugs: [String] = []

  init(id: String, title: String, context: String? = nil,
       lastSyncedAt: Date = .distantPast, updatedAt: String? = nil,
       cloudKitSystemFields: Data? = nil,
       slug: String? = nil,
       previousSlugs: [String] = []) {
    self.id = id
    self.title = title
    self.context = context
    self.lastSyncedAt = lastSyncedAt
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
    self.slug = slug
    self.previousSlugs = previousSlugs
  }
}

@Model
final class SettingsEntity {
  @Attribute(.unique) var id: String
  var payloadData: Data
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as the other mirrored
  /// entities: preserves recordChangeTag across updates.
  var cloudKitSystemFields: Data?

  init(id: String = SettingsCloudKitSchema.singletonID,
       payloadData: Data,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.payloadData = payloadData
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class SectionEntity {
  @Attribute(.unique) var id: String
  var title: String
  var color: String
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as the other mirrored
  /// entities: preserves recordChangeTag across updates.
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       color: String,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.color = color
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class HabitDefinitionEntity {
  @Attribute(.unique) var id: String
  var title: String
  var emoji: String?
  var bucket: String
  var sortIndex: Int
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as tasks/projects/areas.
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       emoji: String? = nil,
       bucket: String,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.emoji = emoji
    self.bucket = bucket
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class HabitDayStateEntity {
  @Attribute(.unique) var id: String
  var date: String
  var habitID: String
  var done: Bool
  var skipped: Bool
  var note: String?
  var time: String?
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as tasks/projects/areas.
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       habitID: String,
       done: Bool,
       skipped: Bool,
       note: String? = nil,
       time: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.habitID = habitID
    self.done = done
    self.skipped = skipped
    self.note = note
    self.time = time
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class SupplementDefinitionEntity {
  @Attribute(.unique) var id: String
  var title: String
  var emoji: String?
  var sortIndex: Int
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as tasks/projects/areas.
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       emoji: String? = nil,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.emoji = emoji
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class SupplementDayStateEntity {
  @Attribute(.unique) var id: String
  var date: String
  var supplementID: String
  var done: Bool
  var note: String?
  var time: String?
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as tasks/projects/areas.
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       supplementID: String,
       done: Bool,
       note: String? = nil,
       time: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.supplementID = supplementID
    self.done = done
    self.note = note
    self.time = time
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class GoalEntity {
  @Attribute(.unique) var id: String
  var text: String
  var sections: [String]
  var created: String      // YYYY-MM-DD
  var sortIndex: Int
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as tasks/projects/areas.
  var cloudKitSystemFields: Data?

  init(id: String,
       text: String,
       sections: [String] = [],
       created: String,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.text = text
    self.sections = sections
    self.created = created
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class ChoreSnapshotEntity {
  @Attribute(.unique) var id: String
  var title: String
  var emoji: String?
  var dueDate: String?
  var lastCompleted: String?
  var lastCompletedTime: String?
  var daysOverdue: Int
  var cadenceDays: Int?
  var sortIndex: Int
  var updatedAt: Date

  init(id: String,
       title: String,
       emoji: String? = nil,
       dueDate: String? = nil,
       lastCompleted: String? = nil,
       lastCompletedTime: String? = nil,
       daysOverdue: Int = 0,
       cadenceDays: Int? = nil,
       sortIndex: Int = 0,
       updatedAt: Date = .now) {
    self.id = id
    self.title = title
    self.emoji = emoji
    self.dueDate = dueDate
    self.lastCompleted = lastCompleted
    self.lastCompletedTime = lastCompletedTime
    self.daysOverdue = daysOverdue
    self.cadenceDays = cadenceDays
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
  }
}

@Model
final class ChoreDefinitionEntity {
  @Attribute(.unique) var id: String
  var title: String
  var emoji: String?
  var cadenceDays: Int
  var sortIndex: Int
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       emoji: String? = nil,
       cadenceDays: Int,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.emoji = emoji
    self.cadenceDays = cadenceDays
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class ChoreEventEntity {
  @Attribute(.unique) var id: String
  var choreID: String
  var action: String
  var date: String
  var newDueDate: String?
  var reason: String?
  var note: String?
  var time: String?
  var sortKey: String
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       choreID: String,
       action: String,
       date: String,
       newDueDate: String? = nil,
       reason: String? = nil,
       note: String? = nil,
       time: String? = nil,
       sortKey: String,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.choreID = choreID
    self.action = action
    self.date = date
    self.newDueDate = newDueDate
    self.reason = reason
    self.note = note
    self.time = time
    self.sortKey = sortKey
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class GutEventEntity {
  @Attribute(.unique) var id: String
  var date: String
  var time: String
  var bristol: Int
  var blood: Int
  var volume: String?
  var discomfortLevel: String?
  var discomfortStart: String?
  var discomfortEnd: String?
  var note: String?
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       time: String,
       bristol: Int,
       blood: Int = 0,
       volume: String? = nil,
       discomfortLevel: String? = nil,
       discomfortStart: String? = nil,
       discomfortEnd: String? = nil,
       note: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.time = time
    self.bristol = bristol
    self.blood = blood
    self.volume = volume
    self.discomfortLevel = discomfortLevel
    self.discomfortStart = discomfortStart
    self.discomfortEnd = discomfortEnd
    self.note = note
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class CaffeineEventEntity {
  @Attribute(.unique) var id: String
  var date: String
  var time: String
  var method: String   // "v60" | "matcha" | "other"
  var beans: String?
  var grams: Double?
  var note: String?
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       time: String,
       method: String,
       beans: String? = nil,
       grams: Double? = nil,
       note: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.time = time
    self.method = method
    self.beans = beans
    self.grams = grams
    self.note = note
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class CaffeineBeanEntity {
  @Attribute(.unique) var id: String
  var name: String
  var sortIndex: Int
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       name: String,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.name = name
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class CannabisEventEntity {
  @Attribute(.unique) var id: String
  var date: String
  var time: String
  var method: String   // "vape" | "edible"
  var strain: String?
  var hit: Int?
  var grams: Double?
  var effect: String?
  var note: String?
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       time: String,
       method: String,
       strain: String? = nil,
       hit: Int? = nil,
       grams: Double? = nil,
       effect: String? = nil,
       note: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.time = time
    self.method = method
    self.strain = strain
    self.hit = hit
    self.grams = grams
    self.effect = effect
    self.note = note
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class GroceryItemEntity {
  @Attribute(.unique) var id: String
  var name: String
  var category: String
  var emoji: String
  var low: Bool
  var lastBought: String?
  var sortIndex: Int
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       name: String,
       category: String,
       emoji: String = "",
       low: Bool = false,
       lastBought: String? = nil,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.name = name
    self.category = category
    self.emoji = emoji
    self.low = low
    self.lastBought = lastBought
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class GroceryCategoryEntity {
  @Attribute(.unique) var id: String
  var name: String
  var sortIndex: Int
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       name: String,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.name = name
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class CannabisStrainEntity {
  @Attribute(.unique) var id: String
  var name: String
  var sortIndex: Int
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       name: String,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.name = name
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

// MARK: - DTO ↔ Entity bridging

extension SeptenaTask {
  init(_ e: TaskEntity) {
    // Decode through the existing decoder so we exercise the same code path
    // as the network layer. Cheaper than maintaining a second initializer.
    let payload: [String: Any?] = [
      "id": e.id,
      "title": e.title,
      "status": e.statusRaw,
      "created": e.created,
      "scheduled": e.scheduled,
      "due": e.due,
      "today": e.today,
      "today_set_on": e.todaySetOn,
      "completed_at": e.completedAt,
      "area": e.area,
      "project": e.project,
      "notes": e.notes,
      "recurrence": e.recurrenceUnit.map { unit -> [String: Any] in
        ["unit": unit,
         "interval": e.recurrenceInterval,
         "after_completion": e.recurrenceAfterCompletion]
      } as Any?,
      "updated_at": e.updatedAt,
      "deleted_at": e.deletedAt,
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
    self = try! JSONDecoder().decode(SeptenaTask.self, from: data)
  }
}

extension Project {
  init(_ e: ProjectEntity) {
    self.init(id: e.id,
              title: e.title,
              status: e.status,
              area: e.area,
              created: e.created,
              completedAt: e.completedAt,
              notes: e.notes,
              context: e.context,
              githubRepo: e.githubRepo,
              updatedAt: e.updatedAt,
              deletedAt: e.deletedAt)
  }
}

extension Area {
  init(_ e: AreaEntity) {
    self.init(id: e.id, title: e.title, context: e.context, updatedAt: e.updatedAt)
  }
}

extension SeptenaClient.SectionConfig {
  init(_ e: SectionEntity) {
    self.init(key: e.id, label: e.title, color: e.color)
  }
}

extension Goal {
  init(_ e: GoalEntity) {
    // Format updatedAt Date → YYYY-MM-DD string for the wire DTO.
    let fmt = DateFormatter()
    fmt.calendar = Calendar(identifier: .gregorian)
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd"
    self.init(id: e.id,
              text: e.text,
              sections: e.sections,
              created: e.created,
              updated: fmt.string(from: e.updatedAt))
  }
}

// MARK: - Checklist CloudKit mapping

private func optionalChecklistString(_ value: CKRecordValue?) -> String? {
  guard let string = value as? String else { return nil }
  return string.isEmpty ? nil : string
}

enum HabitDefinitionCloudKitSchema {
  static let recordType = "HabitDefinition"

  enum Field {
    static let title = "title"
    static let emoji = "emoji"
    static let bucket = "bucket"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "habit-def:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("habit-def:".count))
  }
}

enum HabitEventCloudKitSchema {
  static let recordType = "HabitEvent"

  enum Field {
    static let date = "date"
    static let habitID = "habitID"
    static let done = "done"
    static let skipped = "skipped"
    static let note = "note"
    static let time = "time"
  }

  static func recordName(for id: String) -> String { "habit-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("habit-event:".count))
  }
}

enum SupplementDefinitionCloudKitSchema {
  static let recordType = "SupplementDefinition"

  enum Field {
    static let title = "title"
    static let emoji = "emoji"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "supplement-def:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("supplement-def:".count))
  }
}

enum SupplementEventCloudKitSchema {
  static let recordType = "SupplementEvent"

  enum Field {
    static let date = "date"
    static let supplementID = "supplementID"
    static let done = "done"
    static let note = "note"
    static let time = "time"
  }

  static func recordName(for id: String) -> String { "supplement-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("supplement-event:".count))
  }
}

enum ChoreDefinitionCloudKitSchema {
  static let recordType = "ChoreDefinition"

  enum Field {
    static let title = "title"
    static let emoji = "emoji"
    static let cadenceDays = "cadenceDays"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "chore-def:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("chore-def:".count))
  }
}

enum ChoreEventCloudKitSchema {
  static let recordType = "ChoreEvent"

  enum Field {
    static let choreID = "choreID"
    static let action = "action"
    static let date = "date"
    static let newDueDate = "newDueDate"
    static let reason = "reason"
    static let note = "note"
    static let time = "time"
    static let sortKey = "sortKey"
  }

  static func recordName(for id: String) -> String { "chore-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("chore-event:".count))
  }
}

enum GutEventCloudKitSchema {
  static let recordType = "GutEvent"

  enum Field {
    static let date = "date"
    static let time = "time"
    static let bristol = "bristol"
    static let blood = "blood"
    static let volume = "volume"
    static let discomfortLevel = "discomfortLevel"
    static let discomfortStart = "discomfortStart"
    static let discomfortEnd = "discomfortEnd"
    static let note = "note"
  }

  static func recordName(for id: String) -> String { "gut-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("gut-event:".count))
  }
}

enum CaffeineEventCloudKitSchema {
  static let recordType = "CaffeineEvent"

  enum Field {
    static let date = "date"
    static let time = "time"
    static let method = "method"
    static let beans = "beans"
    static let grams = "grams"
    static let note = "note"
  }

  static func recordName(for id: String) -> String { "caffeine-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("caffeine-event:".count))
  }
}

enum CaffeineBeanCloudKitSchema {
  static let recordType = "CaffeineBean"

  enum Field {
    static let name = "name"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "caffeine-bean:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("caffeine-bean:".count))
  }
}

enum CannabisEventCloudKitSchema {
  static let recordType = "CannabisEvent"

  enum Field {
    static let date = "date"
    static let time = "time"
    static let method = "method"
    static let strain = "strain"
    static let hit = "hit"
    static let grams = "grams"
    static let effect = "effect"
    static let note = "note"
  }

  static func recordName(for id: String) -> String { "cannabis-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("cannabis-event:".count))
  }
}

enum GroceryItemCloudKitSchema {
  static let recordType = "GroceryItem"

  enum Field {
    static let name = "name"
    static let category = "category"
    static let emoji = "emoji"
    static let low = "low"
    static let lastBought = "lastBought"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "grocery-item:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("grocery-item:".count))
  }
}

enum GroceryCategoryCloudKitSchema {
  static let recordType = "GroceryCategory"

  enum Field {
    static let name = "name"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "grocery-cat:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("grocery-cat:".count))
  }
}

enum CannabisStrainCloudKitSchema {
  static let recordType = "CannabisStrain"

  enum Field {
    static let name = "name"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "cannabis-strain:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("cannabis-strain:".count))
  }
}

private protocol ChecklistCloudKitBackedEntity: AnyObject {
  var cloudKitSystemFields: Data? { get set }
}

extension ChecklistCloudKitBackedEntity {
  fileprivate func decodedCloudKitRecord() -> CKRecord? {
    guard let data = cloudKitSystemFields else { return nil }
    let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
    unarchiver?.requiresSecureCoding = true
    return unarchiver.flatMap { CKRecord(coder: $0) }
  }

  fileprivate func captureCloudKitSystemFields(from record: CKRecord) {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    cloudKitSystemFields = archiver.encodedData
  }
}

extension HabitDefinitionEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: HabitDefinitionCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: HabitDefinitionCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[HabitDefinitionCloudKitSchema.Field.title] = title
    record[HabitDefinitionCloudKitSchema.Field.emoji] = emoji
    record[HabitDefinitionCloudKitSchema.Field.bucket] = bucket
    record[HabitDefinitionCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[HabitDefinitionCloudKitSchema.Field.title] as? String { title = value }
    emoji = optionalChecklistString(record[HabitDefinitionCloudKitSchema.Field.emoji])
    if let value = record[HabitDefinitionCloudKitSchema.Field.bucket] as? String { bucket = value }
    if let value = record[HabitDefinitionCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: HabitDefinitionCloudKitSchema.entityID(from: record.recordID.recordName),
              title: "",
              bucket: "morning")
    apply(record)
  }
}

extension HabitDayStateEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: HabitEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: HabitEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[HabitEventCloudKitSchema.Field.date] = date
    record[HabitEventCloudKitSchema.Field.habitID] = habitID
    record[HabitEventCloudKitSchema.Field.done] = done ? 1 : 0
    record[HabitEventCloudKitSchema.Field.skipped] = skipped ? 1 : 0
    record[HabitEventCloudKitSchema.Field.note] = note
    record[HabitEventCloudKitSchema.Field.time] = time
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[HabitEventCloudKitSchema.Field.date] as? String { date = value }
    if let value = record[HabitEventCloudKitSchema.Field.habitID] as? String { habitID = value }
    if let value = record[HabitEventCloudKitSchema.Field.done] as? Int { done = value != 0 }
    if let value = record[HabitEventCloudKitSchema.Field.skipped] as? Int { skipped = value != 0 }
    note = optionalChecklistString(record[HabitEventCloudKitSchema.Field.note])
    time = optionalChecklistString(record[HabitEventCloudKitSchema.Field.time])
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: HabitEventCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "",
              habitID: "",
              done: false,
              skipped: false)
    apply(record)
  }
}

extension SupplementDefinitionEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: SupplementDefinitionCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: SupplementDefinitionCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[SupplementDefinitionCloudKitSchema.Field.title] = title
    record[SupplementDefinitionCloudKitSchema.Field.emoji] = emoji
    record[SupplementDefinitionCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[SupplementDefinitionCloudKitSchema.Field.title] as? String { title = value }
    emoji = optionalChecklistString(record[SupplementDefinitionCloudKitSchema.Field.emoji])
    if let value = record[SupplementDefinitionCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: SupplementDefinitionCloudKitSchema.entityID(from: record.recordID.recordName),
              title: "")
    apply(record)
  }
}

extension SupplementDayStateEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: SupplementEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: SupplementEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[SupplementEventCloudKitSchema.Field.date] = date
    record[SupplementEventCloudKitSchema.Field.supplementID] = supplementID
    record[SupplementEventCloudKitSchema.Field.done] = done ? 1 : 0
    record[SupplementEventCloudKitSchema.Field.note] = note
    record[SupplementEventCloudKitSchema.Field.time] = time
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[SupplementEventCloudKitSchema.Field.date] as? String { date = value }
    if let value = record[SupplementEventCloudKitSchema.Field.supplementID] as? String { supplementID = value }
    if let value = record[SupplementEventCloudKitSchema.Field.done] as? Int { done = value != 0 }
    note = optionalChecklistString(record[SupplementEventCloudKitSchema.Field.note])
    time = optionalChecklistString(record[SupplementEventCloudKitSchema.Field.time])
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: SupplementEventCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "",
              supplementID: "",
              done: false)
    apply(record)
  }
}

extension ChoreDefinitionEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: ChoreDefinitionCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: ChoreDefinitionCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[ChoreDefinitionCloudKitSchema.Field.title] = title
    record[ChoreDefinitionCloudKitSchema.Field.emoji] = emoji
    record[ChoreDefinitionCloudKitSchema.Field.cadenceDays] = cadenceDays
    record[ChoreDefinitionCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[ChoreDefinitionCloudKitSchema.Field.title] as? String { title = value }
    emoji = optionalChecklistString(record[ChoreDefinitionCloudKitSchema.Field.emoji])
    if let value = record[ChoreDefinitionCloudKitSchema.Field.cadenceDays] as? Int { cadenceDays = value }
    if let value = record[ChoreDefinitionCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: ChoreDefinitionCloudKitSchema.entityID(from: record.recordID.recordName),
              title: "",
              cadenceDays: 1)
    apply(record)
  }
}

extension ChoreEventEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: ChoreEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: ChoreEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[ChoreEventCloudKitSchema.Field.choreID] = choreID
    record[ChoreEventCloudKitSchema.Field.action] = action
    record[ChoreEventCloudKitSchema.Field.date] = date
    record[ChoreEventCloudKitSchema.Field.newDueDate] = newDueDate
    record[ChoreEventCloudKitSchema.Field.reason] = reason
    record[ChoreEventCloudKitSchema.Field.note] = note
    record[ChoreEventCloudKitSchema.Field.time] = time
    record[ChoreEventCloudKitSchema.Field.sortKey] = sortKey
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[ChoreEventCloudKitSchema.Field.choreID] as? String { choreID = value }
    if let value = record[ChoreEventCloudKitSchema.Field.action] as? String { action = value }
    if let value = record[ChoreEventCloudKitSchema.Field.date] as? String { date = value }
    newDueDate = optionalChecklistString(record[ChoreEventCloudKitSchema.Field.newDueDate])
    reason = optionalChecklistString(record[ChoreEventCloudKitSchema.Field.reason])
    note = optionalChecklistString(record[ChoreEventCloudKitSchema.Field.note])
    time = optionalChecklistString(record[ChoreEventCloudKitSchema.Field.time])
    if let value = record[ChoreEventCloudKitSchema.Field.sortKey] as? String { sortKey = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: ChoreEventCloudKitSchema.entityID(from: record.recordID.recordName),
              choreID: "",
              action: "complete",
              date: "",
              sortKey: "")
    apply(record)
  }
}

extension GutEventEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: GutEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: GutEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[GutEventCloudKitSchema.Field.date] = date
    record[GutEventCloudKitSchema.Field.time] = time
    record[GutEventCloudKitSchema.Field.bristol] = bristol
    record[GutEventCloudKitSchema.Field.blood] = blood
    record[GutEventCloudKitSchema.Field.volume] = volume
    record[GutEventCloudKitSchema.Field.discomfortLevel] = discomfortLevel
    record[GutEventCloudKitSchema.Field.discomfortStart] = discomfortStart
    record[GutEventCloudKitSchema.Field.discomfortEnd] = discomfortEnd
    record[GutEventCloudKitSchema.Field.note] = note
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[GutEventCloudKitSchema.Field.date] as? String { date = value }
    if let value = record[GutEventCloudKitSchema.Field.time] as? String { time = value }
    if let value = record[GutEventCloudKitSchema.Field.bristol] as? Int { bristol = value }
    if let value = record[GutEventCloudKitSchema.Field.blood] as? Int { blood = value }
    volume = optionalChecklistString(record[GutEventCloudKitSchema.Field.volume])
    discomfortLevel = optionalChecklistString(record[GutEventCloudKitSchema.Field.discomfortLevel])
    discomfortStart = optionalChecklistString(record[GutEventCloudKitSchema.Field.discomfortStart])
    discomfortEnd = optionalChecklistString(record[GutEventCloudKitSchema.Field.discomfortEnd])
    note = optionalChecklistString(record[GutEventCloudKitSchema.Field.note])
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: GutEventCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "", time: "", bristol: 4)
    apply(record)
  }
}

extension CaffeineEventEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: CaffeineEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: CaffeineEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[CaffeineEventCloudKitSchema.Field.date] = date
    record[CaffeineEventCloudKitSchema.Field.time] = time
    record[CaffeineEventCloudKitSchema.Field.method] = method
    record[CaffeineEventCloudKitSchema.Field.beans] = beans
    record[CaffeineEventCloudKitSchema.Field.grams] = grams
    record[CaffeineEventCloudKitSchema.Field.note] = note
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[CaffeineEventCloudKitSchema.Field.date] as? String { date = value }
    if let value = record[CaffeineEventCloudKitSchema.Field.time] as? String { time = value }
    if let value = record[CaffeineEventCloudKitSchema.Field.method] as? String { method = value }
    beans = optionalChecklistString(record[CaffeineEventCloudKitSchema.Field.beans])
    grams = record[CaffeineEventCloudKitSchema.Field.grams] as? Double
    note = optionalChecklistString(record[CaffeineEventCloudKitSchema.Field.note])
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: CaffeineEventCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "", time: "", method: "v60")
    apply(record)
  }
}

extension CaffeineBeanEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: CaffeineBeanCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: CaffeineBeanCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[CaffeineBeanCloudKitSchema.Field.name] = name
    record[CaffeineBeanCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[CaffeineBeanCloudKitSchema.Field.name] as? String { name = value }
    if let value = record[CaffeineBeanCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: CaffeineBeanCloudKitSchema.entityID(from: record.recordID.recordName), name: "")
    apply(record)
  }
}

extension CannabisEventEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: CannabisEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: CannabisEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[CannabisEventCloudKitSchema.Field.date] = date
    record[CannabisEventCloudKitSchema.Field.time] = time
    record[CannabisEventCloudKitSchema.Field.method] = method
    record[CannabisEventCloudKitSchema.Field.strain] = strain
    record[CannabisEventCloudKitSchema.Field.hit] = hit
    record[CannabisEventCloudKitSchema.Field.grams] = grams
    record[CannabisEventCloudKitSchema.Field.effect] = effect
    record[CannabisEventCloudKitSchema.Field.note] = note
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[CannabisEventCloudKitSchema.Field.date] as? String { date = value }
    if let value = record[CannabisEventCloudKitSchema.Field.time] as? String { time = value }
    if let value = record[CannabisEventCloudKitSchema.Field.method] as? String { method = value }
    strain = optionalChecklistString(record[CannabisEventCloudKitSchema.Field.strain])
    hit = record[CannabisEventCloudKitSchema.Field.hit] as? Int
    grams = record[CannabisEventCloudKitSchema.Field.grams] as? Double
    effect = optionalChecklistString(record[CannabisEventCloudKitSchema.Field.effect])
    note = optionalChecklistString(record[CannabisEventCloudKitSchema.Field.note])
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: CannabisEventCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "", time: "", method: "vape")
    apply(record)
  }
}

extension GroceryItemEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: GroceryItemCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: GroceryItemCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[GroceryItemCloudKitSchema.Field.name] = name
    record[GroceryItemCloudKitSchema.Field.category] = category
    record[GroceryItemCloudKitSchema.Field.emoji] = emoji
    record[GroceryItemCloudKitSchema.Field.low] = low ? 1 : 0
    record[GroceryItemCloudKitSchema.Field.lastBought] = lastBought
    record[GroceryItemCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[GroceryItemCloudKitSchema.Field.name] as? String { name = value }
    if let value = record[GroceryItemCloudKitSchema.Field.category] as? String { category = value }
    if let value = record[GroceryItemCloudKitSchema.Field.emoji] as? String { emoji = value }
    if let value = record[GroceryItemCloudKitSchema.Field.low] as? Int { low = value != 0 }
    lastBought = optionalChecklistString(record[GroceryItemCloudKitSchema.Field.lastBought])
    if let value = record[GroceryItemCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: GroceryItemCloudKitSchema.entityID(from: record.recordID.recordName),
              name: "", category: "other")
    apply(record)
  }
}

extension GroceryCategoryEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: GroceryCategoryCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: GroceryCategoryCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[GroceryCategoryCloudKitSchema.Field.name] = name
    record[GroceryCategoryCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[GroceryCategoryCloudKitSchema.Field.name] as? String { name = value }
    if let value = record[GroceryCategoryCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: GroceryCategoryCloudKitSchema.entityID(from: record.recordID.recordName), name: "")
    apply(record)
  }
}

extension CannabisStrainEntity: ChecklistCloudKitBackedEntity {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: CannabisStrainCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: CannabisStrainCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[CannabisStrainCloudKitSchema.Field.name] = name
    record[CannabisStrainCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[CannabisStrainCloudKitSchema.Field.name] as? String { name = value }
    if let value = record[CannabisStrainCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: CannabisStrainCloudKitSchema.entityID(from: record.recordID.recordName), name: "")
    apply(record)
  }
}

// MARK: - LocalStore

@MainActor
final class LocalStore {
  static let shared = LocalStore()

  let container: ModelContainer

  private init() {
    let schema = Schema([TaskEntity.self, ProjectEntity.self, AreaEntity.self,
                         SettingsEntity.self, SectionEntity.self,
                         HabitDefinitionEntity.self, HabitDayStateEntity.self,
                         SupplementDefinitionEntity.self, SupplementDayStateEntity.self,
                         ChoreDefinitionEntity.self, ChoreEventEntity.self,
                         ChoreSnapshotEntity.self,
                         GoalEntity.self,
                         GutEventEntity.self,
                         CaffeineEventEntity.self, CaffeineBeanEntity.self,
                         CannabisEventEntity.self, CannabisStrainEntity.self,
                         GroceryItemEntity.self, GroceryCategoryEntity.self,
                         OutboxEntity.self, HTTPOutboxEntity.self])
    // Explicitly opt OUT of NSPersistentCloudKitContainer mirroring. Having
    // CloudKit in the target entitlements would otherwise switch SwiftData
    // into auto-mirror mode, which requires all-optional attributes and
    // disallows @Attribute(.unique) — neither of which our model honors.
    // We sync via CKSyncEngine instead (see CKEngine.swift); SwiftData is
    // strictly a local cache. `.none` is the disable switch.
    let config = ModelConfiguration("Septena", schema: schema, cloudKitDatabase: .none)
    do {
      container = try ModelContainer(for: schema, configurations: [config])
    } catch let firstError {
      // Schema drift between releases: wipe and re-pull from the server.
      // Server is the source of truth so local data is safe to drop. We
      // print() unconditionally so the underlying error survives release
      // builds and shows up in Console.app / device logs — `try!` on the
      // recovery path would otherwise trap before any diagnostic emerges.
      Swift.print("[Septena] ❌ ModelContainer init failed (1/2): \(firstError)")
      Self.wipeAllKnownStores()
      do {
        container = try ModelContainer(for: schema, configurations: [config])
      } catch let secondError {
        Swift.print("[Septena] ❌ ModelContainer init failed (2/2) after wipe: \(secondError)")
        fatalError("LocalStore unrecoverable: \(secondError)")
      }
    }
  }

  /// Best-effort scrub of every location SwiftData might have left a store.
  /// SwiftData's actual on-disk path varies by OS version and configuration;
  /// brute-forcing every plausible location is cheaper than misdiagnosing a
  /// stale-store launch crash.
  private static func wipeAllKnownStores() {
    let fm = FileManager.default
    var dirs: [URL] = []
    if let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil, create: false) {
      dirs.append(appSupport)
    }
    if let docs = try? fm.url(for: .documentDirectory,
                              in: .userDomainMask,
                              appropriateFor: nil, create: false) {
      dirs.append(docs)
    }
    let bases = ["Septena", "default"]   // named + SwiftData default
    for dir in dirs {
      for base in bases {
        for suffix in ["store", "store-shm", "store-wal", "sqlite",
                       "sqlite-shm", "sqlite-wal"] {
          let f = dir.appendingPathComponent("\(base).\(suffix)")
          if fm.fileExists(atPath: f.path) {
            try? fm.removeItem(at: f)
            Swift.print("[Septena] wiped \(f.lastPathComponent)")
          }
        }
      }
    }
  }
}

// MARK: - LocalCache (synchronous reads for instant render)

/// Snapshot reads from the local store. Views call these at the top of
/// their `load()` to paint instantly, then kick off the network refresh.
/// Filter semantics roughly mirror the server's `view=` parameter; they're
/// approximations — the network response always wins on the next render.
enum LocalCache {
  @MainActor
  static func tasks(in context: ModelContext,
                    filter: TaskFilter) -> [SeptenaTask] {
    let descriptor = FetchDescriptor<TaskEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.id)]
    )
    guard let rows = try? context.fetch(descriptor) else { return [] }
    let today = SeptenaDate.today
    return rows.compactMap { e -> SeptenaTask? in
      // Hide rows the user has deleted locally; the outbox drainer will
      // either confirm the deletion (row removed) or resurrect them if
      // the server rejects.
      if e.pendingDeletion { return nil }
      switch filter {
      case .today:
        guard e.status == .open else { return nil }
        if e.today { return SeptenaTask(e) }
        if let s = e.scheduled, s <= today { return SeptenaTask(e) }
        if let d = e.due, d <= today { return SeptenaTask(e) }
        return nil
      case .inbox:
        guard e.status == .open,
              e.project == nil, e.area == nil,
              e.scheduled == nil, e.due == nil, !e.today else { return nil }
        return SeptenaTask(e)
      case .upcoming:
        guard e.status == .open, !e.today else { return nil }
        if let s = e.scheduled, s > today { return SeptenaTask(e) }
        if let d = e.due, d > today { return SeptenaTask(e) }
        return nil
      case .unscheduled:
        guard e.status == .open, !e.today,
              e.scheduled == nil, e.due == nil else { return nil }
        return SeptenaTask(e)
      case .someday:
        guard e.status == .someday else { return nil }
        return SeptenaTask(e)
      case .logbook:
        guard e.status == .done else { return nil }
        return SeptenaTask(e)
      case .project(let pid):
        guard e.project == pid else { return nil }
        return SeptenaTask(e)
      case .area(let aid):
        guard e.area == aid else { return nil }
        return SeptenaTask(e)
      }
    }
  }

  @MainActor
  static func allTasks(in context: ModelContext) -> [SeptenaTask] {
    (try? context.fetch(FetchDescriptor<TaskEntity>()))?.map(SeptenaTask.init) ?? []
  }

  /// One-line diagnostic of what the local task store currently looks
  /// like — counts by status, today flag, and date-relative buckets.
  /// Logged on app launch so a partial-migration / data-corruption
  /// situation surfaces in the console without needing a database
  /// inspector. Cheap; iterates entities once.
  @MainActor
  static func logTaskStateSummary(in context: ModelContext) {
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
    let today = SeptenaDate.today
    var open = 0, done = 0, cancelled = 0, someday = 0
    var todayFlag = 0, scheduledLE = 0, dueLE = 0
    var withArea = 0, withProject = 0, pendingDel = 0
    var withSystemFields = 0
    for e in rows {
      switch e.status {
      case .open: open += 1
      case .done: done += 1
      case .cancelled: cancelled += 1
      case .someday: someday += 1
      }
      if e.today { todayFlag += 1 }
      if let s = e.scheduled, s <= today { scheduledLE += 1 }
      if let d = e.due, d <= today { dueLE += 1 }
      if e.area != nil { withArea += 1 }
      if e.project != nil { withProject += 1 }
      if e.pendingDeletion { pendingDel += 1 }
      if e.cloudKitSystemFields != nil { withSystemFields += 1 }
    }
    SeptenaLog.info("[TaskState] total=\(rows.count) open=\(open) done=\(done) cancelled=\(cancelled) someday=\(someday)")
    SeptenaLog.info("[TaskState] today=\(todayFlag) scheduled<=today=\(scheduledLE) due<=today=\(dueLE) inArea=\(withArea) inProject=\(withProject) pendingDeletion=\(pendingDel) withCKSystemFields=\(withSystemFields)")

    let areas = (try? context.fetch(FetchDescriptor<AreaEntity>())) ?? []
    let projects = (try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? []
    let areasWithCK = areas.filter { $0.cloudKitSystemFields != nil }.count
    let projectsWithCK = projects.filter { $0.cloudKitSystemFields != nil }.count
    SeptenaLog.info("[AreaState] total=\(areas.count) withCKSystemFields=\(areasWithCK)")
    SeptenaLog.info("[ProjectState] total=\(projects.count) withCKSystemFields=\(projectsWithCK)")

    // One-shot crosswalk: are the project ids on tasks actually the same
    // strings as the ids on ProjectEntity? If task.project="signals" but
    // ProjectEntity.id="proj-abc", `filter: .project("proj-abc")` returns
    // nothing. Sample top 20 of each.
    let taskProjectIds = Set(rows.compactMap { $0.project })
    let projectIds = Set(projects.map { $0.id })
    let orphanedTaskProjectIds = taskProjectIds.subtracting(projectIds)
    let projectsWithNoTasks = projectIds.subtracting(taskProjectIds)
    SeptenaLog.info("[Crosswalk] taskProjectIds=\(taskProjectIds.sorted().prefix(20))")
    SeptenaLog.info("[Crosswalk] projectIds=\(projectIds.sorted().prefix(20))")
    SeptenaLog.info("[Crosswalk] orphaned (task references id not in ProjectEntity)=\(orphanedTaskProjectIds.sorted().prefix(20))")
    SeptenaLog.info("[Crosswalk] projects with no tasks=\(projectsWithNoTasks.sorted().prefix(20))")

    let taskAreaIds = Set(rows.compactMap { $0.area })
    let areaIds = Set(areas.map { $0.id })
    let orphanedTaskAreaIds = taskAreaIds.subtracting(areaIds)
    SeptenaLog.info("[Crosswalk] taskAreaIds=\(taskAreaIds.sorted().prefix(20))")
    SeptenaLog.info("[Crosswalk] areaIds=\(areaIds.sorted().prefix(20))")
    SeptenaLog.info("[Crosswalk] orphaned (task references area not in AreaEntity)=\(orphanedTaskAreaIds.sorted().prefix(20))")
  }

  /// Count of open tasks whose hard deadline is today or in the past.
  /// Drives the Today sidebar's red badge — matches the in-list red date
  /// treatment exactly (only `due ≤ today` counts as overdue; scheduled-past
  /// is residence, not lateness).
  @MainActor
  static func overdueCount(in context: ModelContext) -> Int {
    let today = SeptenaDate.today
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
    return rows.reduce(0) { acc, e in
      guard e.status == .open, let d = e.due, d <= today else { return acc }
      return acc + 1
    }
  }

  @MainActor
  static func goals(in context: ModelContext) -> [Goal] {
    let descriptor = FetchDescriptor<GoalEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse),
               SortDescriptor(\.updatedAt, order: .reverse)]
    )
    let rows = (try? context.fetch(descriptor)) ?? []
    return rows.map(Goal.init)
  }

  @MainActor
  static func areas(in context: ModelContext) -> [Area] {
    let descriptor = FetchDescriptor<AreaEntity>(sortBy: [SortDescriptor(\.title)])
    let rows = (try? context.fetch(descriptor)) ?? []
    return rows.map(Area.init)
  }

  @MainActor
  static func projects(in context: ModelContext) -> [Project] {
    let descriptor = FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.title)])
    let rows = (try? context.fetch(descriptor)) ?? []
    return rows.map(Project.init)
  }
}

// MARK: - Syncer

/// Pulls the authoritative state from the server and folds it into SwiftData.
/// Call `pullAll()` on app foreground and after mutations. The mutation
/// outbox (write path) is a separate slice — TaskMutator handles those.
///
/// Implementation: a single `GET /api/tasks/changes?since=<watermark>` call
/// returns everything (tasks, projects, areas) that changed since the last
/// successful sync, including tombstones. The watermark is the server's
/// `server_time` from the previous response, persisted in UserDefaults so
/// it survives relaunches. Shape mirrors `CKSyncEngine.fetchChanges`.
@MainActor
final class Syncer {
  private let client: SeptenaClient
  private let context: ModelContext

  /// Watermark key — the server-returned `serverTime` from the previous
  /// `/changes` call. Nil on first launch (or after a deliberate reset),
  /// which triggers a full snapshot from the server.
  private static let watermarkKey = "septena.sync.serverTime"

  init(client: SeptenaClient, context: ModelContext) {
    self.client = client
    self.context = context
  }

  func pullAll() async {
    do {
      let since = UserDefaults.standard.string(forKey: Self.watermarkKey)
      let response = try await client.changes(since: since)
      apply(response)
      try context.save()
      // Persist the server's clock — next call sends this back as `since`.
      UserDefaults.standard.set(response.serverTime, forKey: Self.watermarkKey)
      // Surfaced by the Sync pane as "Last sync: 2m ago".
      UserDefaults.standard.set(Date().timeIntervalSince1970,
                                forKey: "septena.sync.lastSucceededAt")
    } catch is CancellationError {
      // Foreground re-trigger; silent.
    } catch {
      SeptenaLog.error("Syncer.pullAll failed", error)
    }
  }

  /// Fold a `/changes` response into the local store. Tombstones (rows
  /// with `deletedAt` set) purge the local entity. Tasks are no longer
  /// pulled through this path — CloudKit owns them. Only the projects
  /// and areas slices of the response are consumed here.
  private func apply(_ response: ChangesResponse) {
    let now = Date()
    for dto in response.projects {
      if dto.deletedAt != nil {
        applyTombstoneProject(id: dto.id)
      } else {
        upsert(dto, syncedAt: now)
      }
    }
    // Areas use delete-by-omission on the server (wholesale-replace via
    // PUT, no per-row tombstone), so delta sync can't detect removals.
    // A removed area would only purge after a full resync (clear the
    // watermark). Acceptable: areas rarely change and the next cold
    // launch will trigger a fresh `/changes` with stale-but-non-nil
    // `since`, missing the deletion. To force reconciliation, clear
    // `septena.sync.serverTime` in Settings.
    for dto in response.areas {
      upsert(dto, syncedAt: now)
    }
  }

  private func applyTombstoneProject(id: String) {
    let descriptor = FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.id == id }
    )
    guard let entity = try? context.fetch(descriptor).first else { return }
    context.delete(entity)
  }

  // MARK: Apply (fold an already-fetched response back into the cache)

  func applyAreas(_ dtos: [Area]) {
    let now = Date()
    for dto in dtos { upsert(dto, syncedAt: now) }
    do {
      // Flush inserts BEFORE the predicate-based batch delete. SwiftData's
      // `context.delete(model:where:)` evaluates against the persistent
      // store, not unsaved context state — so freshly-inserted rows still
      // have lastSyncedAt at the @Model default (.distantPast) from the
      // delete's POV and would get wiped. Save first; then prune is safe.
      try context.save()
      try context.delete(model: AreaEntity.self,
                         where: #Predicate { $0.lastSyncedAt < now })
      try context.save()
    } catch {
      SeptenaLog.error("applyAreas save failed", error)
    }
  }

  func applyProjects(_ dtos: [Project]) {
    let now = Date()
    for dto in dtos { upsert(dto, syncedAt: now) }
    do {
      try context.save()
      try context.delete(model: ProjectEntity.self,
                         where: #Predicate { $0.lastSyncedAt < now })
      try context.save()
    } catch {
      SeptenaLog.error("applyProjects save failed", error)
    }
  }

  // MARK: Upserts

  private func upsert(_ dto: Project, syncedAt: Date) {
    let id = dto.id
    let existing = try? context.fetch(
      FetchDescriptor<ProjectEntity>(predicate: #Predicate { $0.id == id })
    ).first
    let entity = existing ?? ProjectEntity(id: id, title: dto.title)
    entity.title = dto.title
    entity.statusRaw = dto.status.rawValue
    entity.area = dto.area
    entity.created = dto.created
    entity.completedAt = dto.completedAt
    entity.notes = dto.notes
    entity.context = dto.context
    entity.githubRepo = dto.githubRepo
    entity.updatedAt = dto.updatedAt
    entity.deletedAt = dto.deletedAt
    entity.lastSyncedAt = syncedAt
    if existing == nil { context.insert(entity) }
  }

  private func upsert(_ dto: Area, syncedAt: Date) {
    let id = dto.id
    let existing = try? context.fetch(
      FetchDescriptor<AreaEntity>(predicate: #Predicate { $0.id == id })
    ).first
    let entity = existing ?? AreaEntity(id: id, title: dto.title)
    entity.title = dto.title
    entity.context = dto.context
    entity.updatedAt = dto.updatedAt
    entity.lastSyncedAt = syncedAt
    if existing == nil { context.insert(entity) }
  }
}
