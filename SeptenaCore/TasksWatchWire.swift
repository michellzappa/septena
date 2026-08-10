import CloudKit
import Foundation

/// CloudKit snapshot identity — reuses the existing `WatchSnapshot` Production
/// schema (same fields as Septena's watch snapshot) with a distinct record name
/// so the two watch apps never clobber each other.
enum TasksWatchSnapshot {
  static let recordType = "WatchSnapshot"
  static let recordName = "septask-watch-snapshot"
}

struct TasksWatchTaskWire: Codable, Equatable, Sendable, Identifiable {
  var id: String
  var title: String
  var isOverdue: Bool
  var sortKey: Int
}

/// Today's open task list for the Septask watch app — the full Today list in
/// manual order (not capped like the iOS widget wire).
struct TasksWatchWire: Codable, Equatable, Sendable {
  var today: String
  var totalCount: Int
  var tasks: [TasksWatchTaskWire]
  /// The tasks section accent from the phone (`SectionEntity.color`), so the
  /// wrist can tint chrome without compiling `SectionTheme`.
  var accentColor: String?
  var updatedAt: Date

  static var sample: TasksWatchWire {
    TasksWatchWire(
      today: "2026-07-12",
      totalCount: 3,
      tasks: [
        .init(id: "1", title: "Reply to the landlord", isOverdue: true, sortKey: 0),
        .init(id: "2", title: "Book dentist", isOverdue: false, sortKey: 1),
        .init(id: "3", title: "Send invoice", isOverdue: false, sortKey: 2),
      ],
      accentColor: "#3b82f6",
      updatedAt: .now)
  }
}

/// Watch targets intentionally do not compile the full task model, but they DO
/// write completions straight to CloudKit — so the date and id rules must be
/// the phone's, byte for byte. These forward to `RecurrenceDateCalculator`
/// (`SeptenaCore/DateParser.swift`, compiled into both watch targets); this
/// used to be a hand-copied second implementation, which is exactly how the
/// two surfaces drift apart on the next fix.
enum TasksWatchRecurrence {
  static func nextDate(completedOn: String,
                       scheduled: String?,
                       unit: String,
                       interval: Int,
                       afterCompletion: Bool) -> String? {
    RecurrenceDateCalculator.nextDate(
      completedOn: completedOn,
      scheduled: scheduled,
      unit: unit,
      interval: interval,
      afterCompletion: afterCompletion
    )
  }

  static func occurrenceID(sourceTaskID: String, scheduled: String) -> String {
    RecurrenceDateCalculator.occurrenceID(sourceTaskID: sourceTaskID, scheduled: scheduled)
  }

  /// Copies the user-facing fields needed for a fresh Task occurrence. The
  /// completed row's deadline and conversation deliberately do not carry over.
  static func occurrenceRecord(from source: CKRecord,
                               recordID: CKRecord.ID,
                               scheduled: String,
                               created: String,
                               createdAt: Date) -> CKRecord {
    let next = CKRecord(recordType: "Task", recordID: recordID)
    next["title"] = source["title"]
    next["status"] = "open"
    next["created"] = created
    next["scheduled"] = scheduled
    next["deadline"] = nil
    next["today"] = 0
    next["todaySetOn"] = nil
    next["completedAt"] = nil
    next["area"] = source["area"]
    next["project"] = source["project"]
    next["notesText"] = source["notesText"]
    next["recurrenceUnit"] = source["recurrenceUnit"]
    next["recurrenceInterval"] = source["recurrenceInterval"]
    next["recurrenceAfterCompletion"] = source["recurrenceAfterCompletion"]
    next["source"] = source["source"]
    next["sourceClient"] = source["sourceClient"]
    if source["source"] as? String == "mcp" {
      next["acknowledgedAt"] = createdAt as NSDate
    } else {
      next["acknowledgedAt"] = source["acknowledgedAt"]
    }
    next["createdAt"] = createdAt as NSDate
    next["kind"] = source["kind"]
    next["heading"] = source["heading"]
    // Manual order. The phone puts a generated occurrence at the top of the
    // list (`TaskOrder.topPosition`), which needs the whole store — the wrist
    // only has this one record. Placing it one gap above its OWN source is the
    // closest local approximation and, critically, beats leaving `position`
    // unset: 0 means "sort by createdAt", which buried every watch-generated
    // occurrence at the BOTTOM while phone-generated ones went to the top.
    // `gap` mirrors `TaskOrder.gap`.
    let gap = 1024.0
    let sourceKey: Double = {
      if let p = source["position"] as? Double, p != 0 { return p }
      if let created = source["createdAt"] as? Date { return created.timeIntervalSinceReferenceDate }
      return 0
    }()
    next["position"] = sourceKey - gap
    return next
  }
}
