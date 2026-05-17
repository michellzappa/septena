import Foundation

// Mirror of Septena api/routers/tasks.py — tasks/projects/areas only.

// MARK: - Task

enum TaskStatus: String, Codable, Hashable {
  case open
  case done
  case cancelled
}

struct SeptenaTask: Identifiable, Codable, Hashable {
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
    // Tolerate unknown status values (e.g. legacy "someday" rows) by
    // falling back to open rather than failing the whole decode.
    status = (try? c.decode(TaskStatus.self, forKey: .status)) ?? .open
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
  /// Optional "owner/repo" pointer. Source of truth for agentic tooling that
  /// needs to know which GitHub repo a project's tasks live against.
  var githubRepo: String?

  enum CodingKeys: String, CodingKey {
    case id, title, status, area, created, notes, context
    case completedAt = "completed_at"
    case githubRepo = "github_repo"
  }

  init(id: String, title: String, status: ProjectStatus = .active,
       area: String? = nil, created: String? = nil, completedAt: String? = nil,
       notes: String? = nil, context: String? = nil, githubRepo: String? = nil) {
    self.id = id; self.title = title; self.status = status
    self.area = area; self.created = created; self.completedAt = completedAt
    self.notes = notes; self.context = context; self.githubRepo = githubRepo
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
    githubRepo = try c.decodeIfPresent(String.self, forKey: .githubRepo)
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
  var items: [SeptenaTask]
  var review: [SeptenaTask]?    // present only on view=today
  var done: [SeptenaTask]?      // present only on view=today
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

  init(today: String, todayCount: Int, reviewCount: Int,
       inboxCount: Int, upcomingCount: Int, unscheduledCount: Int,
       openCount: Int) {
    self.today = today
    self.todayCount = todayCount
    self.reviewCount = reviewCount
    self.inboxCount = inboxCount
    self.upcomingCount = upcomingCount
    self.unscheduledCount = unscheduledCount
    self.openCount = openCount
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

// MARK: - History (per-day adherence for the Week tile histograms)

/// One day in the habit history series. From `/api/habits/history?days=N`.
struct HabitHistoryPoint: Codable, Hashable {
  let date: String   // YYYY-MM-DD
  let done: Int
  let total: Int
  let percent: Int
}

struct HabitHistoryResponse: Codable {
  let daily: [HabitHistoryPoint]
  let total: Int
}

/// One day in the chore history series. From `/api/chores/history?days=N`.
struct ChoreHistoryPoint: Codable, Hashable {
  let date: String
  let completed: Int
  let total: Int
}

struct ChoreHistoryResponse: Codable {
  let daily: [ChoreHistoryPoint]
  let total: Int
}

// MARK: - Training

/// One logged exercise entry. From `/api/training/entries`. Sessions are
/// implicit — multiple entries share the same `date` + `session` string.
struct ExerciseEntry: Codable, Identifiable, Hashable {
  let date: String           // YYYY-MM-DD
  let session: String        // e.g. "upper", "cardio"
  var exercise: String?
  var weight: Double?
  var sets: String?          // server returns int OR string ("AMRAP")
  var reps: String?          // same — int or string
  var difficulty: String?
  var durationMin: Double?
  var distanceM: Double?
  var level: Double?
  var file: String?
  var concludedAt: String?
  var loggedAt: String?

  /// Identifier: server's `file` is unique per entry; fall back to a
  /// composite when missing (older logs).
  var id: String { file ?? "\(date)-\(session)-\(exercise ?? "?")-\(loggedAt ?? "")" }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    date = try c.decode(String.self, forKey: .date)
    session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
    exercise = try c.decodeIfPresent(String.self, forKey: .exercise)
    weight = try c.decodeIfPresent(Double.self, forKey: .weight)
    // sets / reps come back as Int or String depending on the row.
    sets = Self.decodeIntOrString(c, key: .sets)
    reps = Self.decodeIntOrString(c, key: .reps)
    difficulty = try c.decodeIfPresent(String.self, forKey: .difficulty)
    durationMin = try c.decodeIfPresent(Double.self, forKey: .durationMin)
    distanceM = try c.decodeIfPresent(Double.self, forKey: .distanceM)
    level = try c.decodeIfPresent(Double.self, forKey: .level)
    file = try c.decodeIfPresent(String.self, forKey: .file)
    concludedAt = try c.decodeIfPresent(String.self, forKey: .concludedAt)
    loggedAt = try c.decodeIfPresent(String.self, forKey: .loggedAt)
  }

  private static func decodeIntOrString(_ c: KeyedDecodingContainer<CodingKeys>,
                                        key: CodingKeys) -> String? {
    if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
    return try? c.decodeIfPresent(String.self, forKey: key)
  }

  enum CodingKeys: String, CodingKey {
    case date, session, exercise, weight, sets, reps, difficulty, level, file
    case durationMin = "duration_min"
    case distanceM = "distance_m"
    case concludedAt = "concluded_at"
    case loggedAt = "logged_at"
  }
}

/// One day of cardio minutes; from `/api/training/cardio-history`. Used by
/// the Week tile histogram and the destination's weekly Z2 progress.
struct CardioDay: Codable, Hashable {
  let date: String
  let minutes: Int
  let rolling7d: Double?

  enum CodingKeys: String, CodingKey {
    case date, minutes
    case rolling7d = "rolling_7d"
  }
}

struct CardioHistoryResponse: Codable {
  let daily: [CardioDay]
  let targetWeeklyMin: Int

  enum CodingKeys: String, CodingKey {
    case daily
    case targetWeeklyMin = "target_weekly_min"
  }
}

// MARK: - Supplements

/// One day in the supplement history series. From `/api/supplements/history`.
struct SupplementHistoryPoint: Codable, Hashable {
  let date: String
  let done: Int
  let total: Int
  let percent: Int
}

struct SupplementHistoryResponse: Codable {
  let daily: [SupplementHistoryPoint]
  let total: Int
}

struct NextItem: Codable, Identifiable, Hashable {
  var id: String
  var kind: String
  var title: String
  var subtitle: String?
  var trailing: String?
  var overdue: Bool
  var sortKey: Int

  enum CodingKeys: String, CodingKey {
    case id, kind, title, subtitle, trailing, overdue
    case sortKey = "sortKey"
  }
}

struct NextItemsResponse: Codable {
  var date: String
  var bucket: String
  var items: [NextItem]
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
