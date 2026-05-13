import Foundation

// Mirror of Septena api/routers/tasks.py — tasks/projects/areas only.

// MARK: - Task

enum TaskStatus: String, Codable, Hashable {
  case open
  case done
  case cancelled
  case someday
}

struct EngageTask: Identifiable, Codable, Hashable {
  let id: String
  var title: String
  var status: TaskStatus
  var created: String?         // YYYY-MM-DD
  var scheduled: String?       // YYYY-MM-DD
  var due: String?             // YYYY-MM-DD
  var today: Bool
  var todaySetOn: String?      // YYYY-MM-DD
  var completedAt: String?     // YYYY-MM-DDTHH:MM:SS
  var area: String?
  var project: String?
  var notes: String?
  var recurrence: Recurrence?

  enum CodingKeys: String, CodingKey {
    case id, title, status, created, scheduled, due, today
    case todaySetOn = "today_set_on"
    case completedAt = "completed_at"
    case area, project, notes, recurrence
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .open
    created = try c.decodeIfPresent(String.self, forKey: .created)
    scheduled = try c.decodeIfPresent(String.self, forKey: .scheduled)
    due = try c.decodeIfPresent(String.self, forKey: .due)
    today = (try? c.decode(Bool.self, forKey: .today)) ?? false
    todaySetOn = try c.decodeIfPresent(String.self, forKey: .todaySetOn)
    completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
    area = try c.decodeIfPresent(String.self, forKey: .area)
    project = try c.decodeIfPresent(String.self, forKey: .project)
    notes = try c.decodeIfPresent(String.self, forKey: .notes)
    recurrence = try c.decodeIfPresent(Recurrence.self, forKey: .recurrence)
  }
}

// MARK: - Recurrence

/// A recurring task spawns a new instance when completed. `afterCompletion`
/// = true advances from today (e.g. "every 3 days after completion");
/// false advances from the prior scheduled date (e.g. "every Friday").
struct Recurrence: Codable, Hashable {
  enum Unit: String, Codable, Hashable { case day, week, month }
  var unit: Unit
  var interval: Int        // 1+
  var afterCompletion: Bool

  enum CodingKeys: String, CodingKey {
    case unit, interval
    case afterCompletion = "after_completion"
  }

  init(unit: Unit, interval: Int = 1, afterCompletion: Bool = true) {
    self.unit = unit
    self.interval = max(1, interval)
    self.afterCompletion = afterCompletion
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    unit = try c.decode(Unit.self, forKey: .unit)
    interval = max(1, (try? c.decode(Int.self, forKey: .interval)) ?? 1)
    afterCompletion = (try? c.decode(Bool.self, forKey: .afterCompletion)) ?? true
  }

  /// Short human-readable summary for the pill label ("Daily", "Weekly", "Every 3 days").
  var shortLabel: String {
    if interval == 1 {
      switch unit {
      case .day: return "Daily"
      case .week: return "Weekly"
      case .month: return "Monthly"
      }
    }
    return "Every \(interval) \(unit.rawValue)s"
  }
}

// MARK: - Project (Septena)

enum ProjectStatus: String, Codable, Hashable {
  case active
  case done
  case cancelled
}

struct Project: Identifiable, Codable, Hashable {
  let id: String
  var title: String
  var status: ProjectStatus
  var area: String?
  var created: String?
  var completedAt: String?
  var notes: String?
  var context: String?

  enum CodingKeys: String, CodingKey {
    case id, title, status, area, created, notes, context
    case completedAt = "completed_at"
  }

  init(id: String, title: String, status: ProjectStatus = .active,
       area: String? = nil, created: String? = nil, completedAt: String? = nil,
       notes: String? = nil, context: String? = nil) {
    self.id = id; self.title = title; self.status = status
    self.area = area; self.created = created; self.completedAt = completedAt
    self.notes = notes; self.context = context
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
    status = (try? c.decode(ProjectStatus.self, forKey: .status)) ?? .active
    area = try c.decodeIfPresent(String.self, forKey: .area)
    created = try c.decodeIfPresent(String.self, forKey: .created)
    completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
    notes = try c.decodeIfPresent(String.self, forKey: .notes)
    context = try c.decodeIfPresent(String.self, forKey: .context)
  }
}

// MARK: - Area (Septena)

struct Area: Identifiable, Codable, Hashable {
  let id: String
  var title: String
  var context: String?

  init(id: String, title: String, context: String? = nil) {
    self.id = id; self.title = title; self.context = context
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
    context = try c.decodeIfPresent(String.self, forKey: .context)
  }

  enum CodingKeys: String, CodingKey { case id, title, context }
}

// MARK: - List response shapes

struct TasksListResponse: Codable {
  var view: String
  var today: String
  var items: [EngageTask]
  var review: [EngageTask]?    // present only on view=today
  var done: [EngageTask]?      // present only on view=today
}

struct TasksCounts: Codable {
  var today: String
  var todayCount: Int
  var reviewCount: Int
  var inboxCount: Int
  var upcomingCount: Int
  var unscheduledCount: Int
  var openCount: Int

  enum CodingKeys: String, CodingKey {
    case today
    case todayCount = "today_count"
    case reviewCount = "review_count"
    case inboxCount = "inbox_count"
    case upcomingCount = "upcoming_count"
    case unscheduledCount = "unscheduled_count"
    case openCount = "open_count"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    today = try c.decodeIfPresent(String.self, forKey: .today) ?? SeptenaDate.today
    todayCount = (try? c.decode(Int.self, forKey: .todayCount)) ?? 0
    reviewCount = (try? c.decode(Int.self, forKey: .reviewCount)) ?? 0
    inboxCount = (try? c.decode(Int.self, forKey: .inboxCount)) ?? 0
    upcomingCount = (try? c.decode(Int.self, forKey: .upcomingCount)) ?? 0
    unscheduledCount = (try? c.decode(Int.self, forKey: .unscheduledCount)) ?? 0
    openCount = (try? c.decode(Int.self, forKey: .openCount)) ?? 0
  }
}

// MARK: - UI filter (maps to server `view` param + optional area/project scope)

enum TaskFilter: Equatable, Hashable {
  case today
  case inbox
  case upcoming
  case unscheduled
  case logbook
  case project(String)
  case area(String)

  var serverView: String {
    switch self {
    case .today: return "today"
    case .inbox: return "inbox"
    case .upcoming: return "upcoming"
    case .unscheduled: return "unscheduled"
    case .logbook: return "logbook"
    case .project, .area: return "all"
    }
  }

  var title: String {
    switch self {
    case .today: return "Today"
    case .inbox: return "Inbox"
    case .upcoming: return "Upcoming"
    case .unscheduled: return "Unscheduled"
    case .logbook: return "Logbook"
    case .project: return "Project"
    case .area: return "Area"
    }
  }
}

// MARK: - Other Septena sections (toggleable on Today screen)

/// Single habit instance for a given day. From `/api/habits/day/{date}`.
struct HabitDayItem: Codable, Identifiable, Hashable {
  let id: String
  var name: String
  var emoji: String?
  var bucket: String         // "morning" | "afternoon" | "evening"
  var done: Bool
  var skipped: Bool
  var note: String?
  var time: String?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
    emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
    bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? "morning"
    done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    skipped = (try? c.decode(Bool.self, forKey: .skipped)) ?? false
    note = try c.decodeIfPresent(String.self, forKey: .note)
    time = try c.decodeIfPresent(String.self, forKey: .time)
  }

  enum CodingKeys: String, CodingKey { case id, name, emoji, bucket, done, skipped, note, time }
}

struct HabitsDayResponse: Codable {
  var date: String
  var buckets: [String]
  var grouped: [String: [HabitDayItem]]
}

/// Single supplement instance for a given day. From `/api/supplements/day/{date}`.
struct SupplementDayItem: Codable, Identifiable, Hashable {
  let id: String
  var name: String
  var emoji: String?
  var done: Bool
  var note: String?
  var time: String?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
    emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
    done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    note = try c.decodeIfPresent(String.self, forKey: .note)
    time = try c.decodeIfPresent(String.self, forKey: .time)
  }

  enum CodingKeys: String, CodingKey { case id, name, emoji, done, note, time }
}

struct SupplementsDayResponse: Codable {
  var date: String
  var items: [SupplementDayItem]
}

/// Recurring chore. From `/api/chores/list`.
struct ChoreItem: Codable, Identifiable, Hashable {
  let id: String
  var name: String
  var emoji: String?
  var dueDate: String?           // YYYY-MM-DD
  var lastCompleted: String?     // YYYY-MM-DD
  var daysOverdue: Int           // negative = future, 0 = today, positive = late

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
    emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
    dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate)
    lastCompleted = try c.decodeIfPresent(String.self, forKey: .lastCompleted)
    daysOverdue = (try? c.decode(Int.self, forKey: .daysOverdue)) ?? 0
  }

  enum CodingKeys: String, CodingKey {
    case id, name, emoji
    case dueDate = "due_date"
    case lastCompleted = "last_completed"
    case daysOverdue = "days_overdue"
  }
}

struct ChoresListResponse: Codable {
  var chores: [ChoreItem]
}

// MARK: - Date helpers (Septena uses YYYY-MM-DD strings)

enum SeptenaDate {
  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
  }()

  static func parse(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    return formatter.date(from: String(s.prefix(10)))
  }

  static func format(_ d: Date?) -> String? {
    guard let d else { return nil }
    return formatter.string(from: d)
  }

  static var today: String { formatter.string(from: Date()) }
}
