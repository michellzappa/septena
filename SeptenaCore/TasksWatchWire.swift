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

/// Watch targets intentionally do not compile the full task model. Keep the
/// small recurrence calculation here so direct watch CloudKit completion uses
/// the same date and id rules as the phone backend.
enum TasksWatchRecurrence {
  static func nextDate(completedOn: String,
                       scheduled: String?,
                       unit: String,
                       interval: Int,
                       afterCompletion: Bool) -> String? {
    let dateFormatter: DateFormatter = {
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd"
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = TimeZone.current
      return f
    }()
    guard let completedDate = dateFormatter.date(from: String(completedOn.prefix(10))) else {
      return nil
    }
    let anchor = afterCompletion
      ? completedDate
      : (scheduled.flatMap { dateFormatter.date(from: String($0.prefix(10))) } ?? completedDate)
    let component: Calendar.Component
    switch unit {
    case "day": component = .day
    case "week": component = .weekOfYear
    case "month": component = .month
    default: return nil
    }
    let calendar = Calendar.current
    guard var next = calendar.date(byAdding: component, value: max(1, interval), to: anchor) else {
      return nil
    }
    if !afterCompletion {
      while next <= completedDate {
        guard let advanced = calendar.date(byAdding: component, value: max(1, interval), to: next) else {
          return nil
        }
        next = advanced
      }
    }
    return dateFormatter.string(from: next)
  }

  static func occurrenceID(sourceTaskID: String, scheduled: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in "\(sourceTaskID)|\(scheduled)".utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1099511628211
    }
    return "recur-\(String(format: "%016llx", hash))"
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
    return next
  }
}
