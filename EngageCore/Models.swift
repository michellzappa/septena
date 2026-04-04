import Foundation

// ─── Task ─────────────────────────────────────────────────────────────────────

enum TaskOrigin: String, Codable {
  case human
  case agent
}

enum TaskStatus: String, Codable {
  case open
  case completed
  case cancelled
}

enum TaskAgentStatus: String, Codable {
  case pending
  case inProgress = "in_progress"
  case blocked
  case done
}

struct EngageTask: Identifiable, Codable, Equatable, Hashable {
  let id: String
  var title: String
  var notes: String?
  var origin: TaskOrigin
  var status: TaskStatus
  var priority: Int // 0=none, 1=low, 2=medium, 3=high

  var area: String?
  var project: String?
  var tags: [String]

  var due: Date?
  var dueDateSetBy: String?
  var start: Date?
  var end: Date?

  var createdBy: String
  var owner: String

  var completedAt: Date?
  var completedBy: String?

  var repeatRule: String?
  var conclusionRule: String?
  var nextDue: Date?
  var nextDueSetBy: String?

  var agentStatus: TaskAgentStatus?
  var agentAssignedMe: Bool
  var agentContext: String?

  var checklist: [ChecklistItem]

  var isRecurring: Bool { repeatRule != nil }
  var hasConclusionRule: Bool { conclusionRule != nil }

  static func == (lhs: EngageTask, rhs: EngageTask) -> Bool {
    lhs.id == rhs.id
  }
}

struct ChecklistItem: Identifiable, Codable, Equatable, Hashable {
  let id: String
  var title: String
  var done: Bool
}

// ─── Area ─────────────────────────────────────────────────────────────────────

struct Area: Identifiable, Codable, Equatable, Hashable {
  let id: String
  var name: String
  var icon: String?
  var sortOrder: Int
  var color: String?
}

// ─── Project ─────────────────────────────────────────────────────────────────

enum ProjectStatus: String, Codable {
  case active
  case completed
  case dropped
}

struct Project: Identifiable, Codable, Equatable, Hashable {
  let id: String
  var name: String
  var area: String?
  var status: ProjectStatus
  var notes: String?
  var sortOrder: Int
}

// ─── Tag ─────────────────────────────────────────────────────────────────────

struct Tag: Identifiable, Codable, Equatable {
  let id: String
  var name: String
  var color: String
}

// ─── Agent ───────────────────────────────────────────────────────────────────

enum AgentType: String, Codable {
  case human
  case ai
}

struct Agent: Identifiable, Codable, Equatable {
  let id: String
  var name: String
  var avatar: String?
  var email: String
  var type: AgentType
  var active: Bool
}

// ─── AgentMemory ─────────────────────────────────────────────────────────────

struct AgentMemoryEntry: Identifiable, Codable, Equatable {
  let id: String
  var agentId: String
  var taskId: String?
  var content: String
  var pinned: Bool
  var updatedAt: Date
}

// ─── Comment ─────────────────────────────────────────────────────────────────

struct Comment: Identifiable, Codable, Equatable {
  let id: String
  var taskId: String
  var actor: String
  var body: String
  var createdAt: Date
}

// ─── CollaborationLog ────────────────────────────────────────────────────────

enum LogAction: String, Codable {
  case created
  case commented
  case reassigned
  case prioritized
  case completed
  case cancelled
  case blocked
  case unblocked
  case staleFlagged = "stale_flagged"
}

struct CollaborationLogEntry: Identifiable, Codable, Equatable {
  let id: String
  var taskId: String?
  var actor: String
  var action: LogAction
  var content: String?
  var createdAt: Date
}

// ─── View Filters ─────────────────────────────────────────────────────────────

enum TaskFilter: Equatable, Hashable {
  case inbox
  case today
  case upcoming(days: Int)
  case anytime
  case someday
  case project(String)
  case area(String)
  case review
  case logbook

  var title: String {
    switch self {
    case .inbox: return "Inbox"
    case .today: return "Today"
    case .upcoming: return "Upcoming"
    case .anytime: return "Anytime"
    case .someday: return "Someday"
    case .project: return "Project"
    case .area: return "Area"
    case .review: return "Review"
    case .logbook: return "Logbook"
    }
  }
}
