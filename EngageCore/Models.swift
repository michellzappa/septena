import Foundation

// ─── Task ─────────────────────────────────────────────────────────────────────

/// TaskStatus mirrors upstream atask domain.Status
enum TaskStatus: String, Codable, Hashable {
  case pending
  case completed
  case cancelled
}

/// TaskSchedule mirrors upstream atask domain.Schedule
enum TaskSchedule: Int, Codable, Hashable {
  case inbox = 0
  case anytime = 1
  case someday = 2

  var title: String {
    switch self {
    case .inbox: return "Inbox"
    case .anytime: return "Anytime"
    case .someday: return "Someday"
    }
  }
}

/// Task mirrors upstream atask domain.Task
struct EngageTask: Identifiable, Codable, Hashable {
  let id: String
  var title: String
  var notes: String?
  var status: TaskStatus
  var schedule: TaskSchedule

  /// YYYY-MM-DD format, stored as ISO8601 Date
  var startDate: Date?
  var deadline: Date?
  var completedAt: Date?

  /// Sort order within its list
  var index: Int
  /// Sort order within Today view
  var todayIndex: Int?

  var projectId: String?
  var sectionId: String?
  var areaId: String?
  var locationId: String?

  var repeatRule: RecurrenceRule?
  var timeSlot: String?

  var tags: [String]
  var linkedTaskIds: [String]

  var checklist: [ChecklistItem]

  var createdAt: Date
  var updatedAt: Date

  var isRecurring: Bool { repeatRule != nil }

  static func == (lhs: EngageTask, rhs: EngageTask) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

// ─── RecurrenceRule ────────────────────────────────────────────────────────────

/// RecurrenceRule mirrors upstream atask domain.RecurrenceRule
struct RecurrenceRule: Codable, Hashable {
  var type: RecurrenceMode  // "fixed" or "afterCompletion"
  var interval: Int
  var unit: RecurrenceUnit // "day", "week", "month"
  var end: RecurrenceEnd?
}

enum RecurrenceMode: String, Codable, Hashable {
  case fixed = "fixed"
  case afterCompletion = "afterCompletion"
}

enum RecurrenceUnit: String, Codable, Hashable {
  case day = "day"
  case week = "week"
  case month = "month"
}

struct RecurrenceEnd: Codable, Hashable {
  var date: String?
  var count: Int?
}

// ─── ChecklistItem ────────────────────────────────────────────────────────────

enum ChecklistItemStatus: Int, Codable, Hashable {
  case pending = 0
  case completed = 1
}

/// ChecklistItem mirrors upstream atask domain.ChecklistItem
struct ChecklistItem: Identifiable, Codable, Equatable, Hashable {
  let id: String
  var title: String
  var status: ChecklistItemStatus
  var taskId: String
  var index: Int
  var createdAt: Date
  var updatedAt: Date
}

// ─── Area ─────────────────────────────────────────────────────────────────────

/// Area mirrors upstream atask domain.Area
struct Area: Identifiable, Codable, Equatable, Hashable {
  let id: String
  var title: String
  var index: Int
  var archived: Bool
  var createdAt: Date
  var updatedAt: Date
}

// ─── Project ──────────────────────────────────────────────────────────────────

/// Project mirrors upstream atask domain.Project
struct Project: Identifiable, Codable, Equatable, Hashable {
  let id: String
  var title: String
  var notes: String?
  var status: TaskStatus
  var schedule: TaskSchedule

  var startDate: Date?
  var deadline: Date?
  var completedAt: Date?

  var index: Int
  var areaId: String?
  var tags: [String]
  var autoComplete: Bool
  var color: String?

  var createdAt: Date
  var updatedAt: Date
}

// ─── Section ──────────────────────────────────────────────────────────────────

/// Section mirrors upstream atask domain.Section
struct Section: Identifiable, Codable, Equatable, Hashable {
  let id: String
  var title: String
  var projectId: String
  var index: Int
  var archived: Bool
  var collapsed: Bool
  var createdAt: Date
  var updatedAt: Date
}

// ─── Tag ──────────────────────────────────────────────────────────────────────

/// Tag mirrors upstream atask domain.Tag
struct Tag: Identifiable, Codable, Equatable, Hashable {
  let id: String
  var title: String
  var parentId: String?
  var shortcut: String?
  var index: Int
  var createdAt: Date
  var updatedAt: Date
}

// ─── Location ─────────────────────────────────────────────────────────────────

/// Location mirrors upstream atask domain.Location
struct Location: Identifiable, Codable, Equatable, Hashable {
  let id: String
  var name: String
  var latitude: Double?
  var longitude: Double?
  var radius: Int?
  var address: String?
  var createdAt: Date
  var updatedAt: Date
}

// ─── Activity ─────────────────────────────────────────────────────────────────

/// Activity mirrors upstream atask domain.Activity
struct Activity: Identifiable, Codable, Equatable {
  let id: String
  var type: ActivityType
  var content: String?
  var taskId: String?
  var actorType: ActorType
  var actorId: String
  var createdAt: Date
}

enum ActivityType: String, Codable {
  case comment
  case contextRequest = "context_request"
  case reply
  case artifact
  case statusChange = "status_change"
  case decomposition
}

enum ActorType: String, Codable {
  case human
  case agent
}

// ─── User ─────────────────────────────────────────────────────────────────────

struct User: Identifiable, Codable {
  let id: String
  var email: String
  var name: String
}

// ─── APIKey ───────────────────────────────────────────────────────────────────

struct APIKey: Identifiable, Codable {
  let id: String
  var name: String
  var createdAt: Date
}

// ─── View Responses ────────────────────────────────────────────────────────────

/// InlineTask is the shape returned by /views/* endpoints (flat, no checklist)
struct InlineTask: Identifiable, Codable, Hashable {
  let id: String
  var title: String
  var notes: String?
  var status: TaskStatus
  var schedule: TaskSchedule
  var startDate: Date?
  var deadline: Date?
  var completedAt: Date?
  var index: Int
  var todayIndex: Int?
  var projectId: String?
  var sectionId: String?
  var areaId: String?
  var locationId: String?
  var repeatRule: RecurrenceRule?
  var timeSlot: String?
  var tags: [String]
  var linkedTaskIds: [String]
  var createdAt: Date
  var updatedAt: Date
}

// ─── Sync ─────────────────────────────────────────────────────────────────────

struct DeltaEvent: Identifiable, Codable {
  let id: Int64
  var type: String
  var entityType: String
  var entityId: String
  var payload: String?  // JSON string
  var createdAt: Date
}
