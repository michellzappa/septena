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
  /// Stamped server-side on every write. Used as a watermark by the
  /// delta-sync path (`/api/tasks/changes?since=…`). Nil only on legacy
  /// records that haven't been touched since the server was upgraded.
  var updatedAt: String?
  /// Tombstone marker. When set, the row is logically deleted; the local
  /// store keeps it briefly so other clients (or this client on next
  /// pull) can purge accordingly. The Septena views filter rows where
  /// `deletedAt != nil` out of every read.
  var deletedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, title, status, created, scheduled, due, today
    case todaySetOn = "today_set_on"
    case completedAt = "completed_at"
    case area, project, notes, recurrence
    case updatedAt = "updated_at"
    case deletedAt = "deleted_at"
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
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
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
  var updatedAt: String?
  var deletedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, title, status, area, created, notes, context
    case completedAt = "completed_at"
    case githubRepo = "github_repo"
    case updatedAt = "updated_at"
    case deletedAt = "deleted_at"
  }

  init(id: String, title: String, status: ProjectStatus = .active,
       area: String? = nil, created: String? = nil, completedAt: String? = nil,
       notes: String? = nil, context: String? = nil, githubRepo: String? = nil,
       updatedAt: String? = nil, deletedAt: String? = nil) {
    self.id = id; self.title = title; self.status = status
    self.area = area; self.created = created; self.completedAt = completedAt
    self.notes = notes; self.context = context; self.githubRepo = githubRepo
    self.updatedAt = updatedAt; self.deletedAt = deletedAt
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
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
  }
}

// MARK: - Area (Septena)

struct Area: Identifiable, Codable, Hashable {
  let id: String
  var title: String
  var context: String?
  var updatedAt: String?
  // Areas are stored on the server as a single wholesale-replace array,
  // so there's no per-row tombstone. Removed areas just stop appearing
  // in /changes — we delete-by-omission for areas, tombstone for tasks
  // and projects. No `deletedAt` field by design.

  init(id: String, title: String, context: String? = nil, updatedAt: String? = nil) {
    self.id = id; self.title = title; self.context = context
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
    context = try c.decodeIfPresent(String.self, forKey: .context)
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
  }

  enum CodingKeys: String, CodingKey {
    case id, title, context
    case updatedAt = "updated_at"
  }
}

// MARK: - List response shapes

struct TasksListResponse: Codable {
  var view: String
  var today: String
  var items: [SeptenaTask]
  var review: [SeptenaTask]?    // present only on view=today
  var done: [SeptenaTask]?      // present only on view=today
}

/// Response from `GET /api/tasks/changes?since=<iso8601>` — the delta-sync
/// endpoint. `tasks` and `projects` include tombstones (deletedAt set);
/// `areas` are wholesale (deletion is by-omission since the server stores
/// them as a single replace-on-write array). Persist `serverTime` as the
/// next `since` value.
struct ChangesResponse: Codable {
  var serverTime: String
  var since: String?
  var tasks: [SeptenaTask]
  var projects: [Project]
  var areas: [Area]

  enum CodingKeys: String, CodingKey {
    case serverTime = "server_time"
    case since, tasks, projects, areas
  }
}

// MARK: - Tasks history (per-day event aggregation)

struct TasksHistoryDay: Codable, Hashable {
  let date: String
  let made: Int
  let done: Int
  let deferred: Int
  let cancelled: Int
}

struct TasksHistory: Codable {
  let daily: [TasksHistoryDay]
  let today: String
  let windowDays: Int

  enum CodingKeys: String, CodingKey {
    case daily, today
    case windowDays = "window_days"
  }
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
  var lastCompletedTime: String? // HH:MM — time-of-day, when the
                                 // server logged a per-event timestamp.
                                 // Used by DayTimelineView to place a dot
                                 // at the moment the chore was checked off.
  var daysOverdue: Int           // negative = future, 0 = today, positive = late
  var cadenceDays: Int?          // recurrence in days (from chore definition)

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
    emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
    dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate)
    lastCompleted = try c.decodeIfPresent(String.self, forKey: .lastCompleted)
    lastCompletedTime = try c.decodeIfPresent(String.self, forKey: .lastCompletedTime)
    daysOverdue = (try? c.decode(Int.self, forKey: .daysOverdue)) ?? 0
    cadenceDays = try? c.decodeIfPresent(Int.self, forKey: .cadenceDays)
  }

  enum CodingKeys: String, CodingKey {
    case id, name, emoji
    case dueDate = "due_date"
    case lastCompleted = "last_completed"
    case lastCompletedTime = "last_completed_time"
    case daysOverdue = "days_overdue"
    case cadenceDays = "cadence_days"
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

/// One point on the per-exercise progression series. Numeric fields may be
/// absent depending on the exercise type (strength vs cardio vs mobility).
struct ProgressionPoint: Codable, Hashable {
  let date: String
  var weight: Double?
  var sets: String?
  var reps: String?
  var durationMin: Double?
  var distanceM: Double?
  var level: Double?
  var difficulty: String?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    date = try c.decode(String.self, forKey: .date)
    weight = try c.decodeIfPresent(Double.self, forKey: .weight)
    if let i = try? c.decodeIfPresent(Int.self, forKey: .sets) { sets = String(i) }
    else { sets = try c.decodeIfPresent(String.self, forKey: .sets) }
    if let i = try? c.decodeIfPresent(Int.self, forKey: .reps) { reps = String(i) }
    else { reps = try c.decodeIfPresent(String.self, forKey: .reps) }
    durationMin = try c.decodeIfPresent(Double.self, forKey: .durationMin)
    distanceM = try c.decodeIfPresent(Double.self, forKey: .distanceM)
    level = try c.decodeIfPresent(Double.self, forKey: .level)
    difficulty = try c.decodeIfPresent(String.self, forKey: .difficulty)
  }

  enum CodingKeys: String, CodingKey {
    case date, weight, sets, reps, level, difficulty
    case durationMin = "duration_min"
    case distanceM = "distance_m"
  }
}

struct ProgressionResponse: Codable {
  let exercise: String
  let data: [ProgressionPoint]
}

/// One row from `/api/training/summary` — per-exercise rollup.
struct ExerciseSummary: Codable, Hashable {
  let name: String
  let count: Int
  let latestWeight: Double?
  let latestDate: String?
  let trend: String?

  enum CodingKeys: String, CodingKey {
    case name, count, trend
    case latestWeight = "latest_weight"
    case latestDate = "latest_date"
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

// MARK: - Health / Sleep (Oura subset)
//
// Septena's sleep data flows through `/api/health/*` — Oura is the
// primary source. We only decode the fields the Sleep mini-app actually
// renders today; the response includes many more (steps, recovery,
// activity score, etc) which other modules can opt into later.

struct OuraNight: Codable, Identifiable, Hashable {
  let date: String           // YYYY-MM-DD
  var sleepScore: Int?
  var readinessScore: Int?
  var totalH: Double?
  var deepH: Double?
  var remH: Double?
  var lightH: Double?
  var awakeH: Double?
  var efficiency: Int?
  var hrv: Int?
  var restingHr: Int?
  var bedtime: String?
  var wakeTime: String?
  var stressHighMin: Int?
  var recoveryHighMin: Int?
  var stressSummary: String?   // "stressful" | "normal" | "restored" | "restorative"

  var id: String { date }

  enum CodingKeys: String, CodingKey {
    case date
    case sleepScore       = "sleep_score"
    case readinessScore   = "readiness_score"
    case totalH           = "total_h"
    case deepH            = "deep_h"
    case remH             = "rem_h"
    case lightH           = "light_h"
    case awakeH           = "awake_h"
    case efficiency
    case hrv
    case restingHr        = "resting_hr"
    case bedtime
    case wakeTime         = "wake_time"
    case stressHighMin    = "stress_high_min"
    case recoveryHighMin  = "recovery_high_min"
    case stressSummary    = "stress_summary"
  }
}

struct OuraHistoryResponse: Codable {
  let oura: [OuraNight]
}

// MARK: - Nutrition

/// One logged meal/snack. From `/api/nutrition/entries`.
struct NutritionEntry: Codable, Identifiable, Hashable {
  let date: String
  let time: String
  var emoji: String?
  var proteinG: Double
  var fatG: Double
  var carbsG: Double
  var fiberG: Double?
  var kcal: Double
  var foods: [String]
  var ingredients: [String]?
  let file: String

  var id: String { file }

  enum CodingKeys: String, CodingKey {
    case date, time, emoji, kcal, foods, ingredients, file
    case proteinG = "protein_g"
    case fatG     = "fat_g"
    case carbsG   = "carbs_g"
    case fiberG   = "fiber_g"
  }
}

/// One day's macro totals. From `NutritionStats.daily`.
struct NutritionDailyPoint: Codable, Hashable {
  let date: String
  let proteinG: Double
  let fatG: Double
  let carbsG: Double
  var fiberG: Double?
  let kcal: Double

  enum CodingKeys: String, CodingKey {
    case date, kcal
    case proteinG = "protein_g"
    case fatG     = "fat_g"
    case carbsG   = "carbs_g"
    case fiberG   = "fiber_g"
  }
}

/// One day's fasting window — from prior day's last meal to today's first.
/// `hours` is nil when logs were too sparse to anchor the window honestly.
struct FastingWindow: Codable, Hashable, Identifiable {
  let date: String
  var hours: Double?
  var lastMeal: String?
  var firstMeal: String?
  var note: String?   // "gap" when value suppressed
  var id: String { date }

  enum CodingKeys: String, CodingKey {
    case date, hours, note
    case lastMeal  = "last_meal"
    case firstMeal = "first_meal"
  }
}

struct NutritionStatsResponse: Codable {
  let daily: [NutritionDailyPoint]
  var fasting: [FastingWindow]?
  let todayMealCount: Int?
  let todayLatestMeal: String?
  var yesterdayLastMeal: String?
  var avgFastH: Double?

  enum CodingKeys: String, CodingKey {
    case daily, fasting
    case todayMealCount    = "today_meal_count"
    case todayLatestMeal   = "today_latest_meal"
    case yesterdayLastMeal = "yesterday_last_meal"
    case avgFastH          = "avg_fast_h"
  }
}

/// User-configured macro targets. From `/api/nutrition/macros-config`.
struct MacroRange: Codable, Hashable {
  let min: Double
  let max: Double
  var unit: String?
}

struct MacrosConfig: Codable, Hashable {
  let protein: MacroRange
  let fat: MacroRange
  let carbs: MacroRange
  let kcal: MacroRange
  var fiber: MacroRange?
  var fasting: MacroRange?
}

// MARK: - Air

struct AirReading: Codable, Identifiable, Hashable {
  let date: String
  let time: String
  var id_: String?
  var co2Ppm: Double?
  var tempC: Double?
  var humidityPct: Double?

  var id: String { id_ ?? "\(date) \(time)" }

  enum CodingKeys: String, CodingKey {
    case date, time
    case id_ = "id"
    case co2Ppm      = "co2_ppm"
    case tempC       = "temp_c"
    case humidityPct = "humidity_pct"
  }
}

struct AirDayStats: Codable, Hashable {
  let readings: Int
  var co2Avg: Double?
  var co2Max: Double?
  var tempAvg: Double?
  var humidityAvg: Double?
  var minutesOver1000: Int

  enum CodingKeys: String, CodingKey {
    case readings
    case co2Avg          = "co2_avg"
    case co2Max          = "co2_max"
    case tempAvg         = "temp_avg"
    case humidityAvg     = "humidity_avg"
    case minutesOver1000 = "minutes_over_1000"
  }
}

struct AirSummary: Codable, Hashable {
  let latest: AirReading?
  let co2Band: String?     // "good" | "ok" | "poor" | "bad"
  let today: AirDayStats
  let last24h: AirDayStats

  enum CodingKeys: String, CodingKey {
    case latest, today
    case co2Band = "co2_band"
    case last24h = "last_24h"
  }
}

struct AirHistoryPoint: Codable, Hashable {
  let date: String
  let readings: Int
  var co2Avg: Double?
  var co2Max: Double?
  var minutesOver1000: Int

  enum CodingKeys: String, CodingKey {
    case date, readings
    case co2Avg          = "co2_avg"
    case co2Max          = "co2_max"
    case minutesOver1000 = "minutes_over_1000"
  }
}

struct AirHistoryResponse: Codable {
  let daily: [AirHistoryPoint]
}

// MARK: - Groceries

struct GroceryItem: Codable, Identifiable, Hashable {
  let id: String
  var name: String
  var category: String
  var emoji: String
  var low: Bool
  var lastBought: String?

  enum CodingKeys: String, CodingKey {
    case id, name, category, emoji, low
    case lastBought = "last_bought"
  }
}

struct GroceryCategory: Codable, Identifiable, Hashable {
  let id: String
  var name: String
}

struct GroceriesResponse: Codable {
  let items: [GroceryItem]
  let categories: [GroceryCategory]?
}

/// Default fallback used when the backend response omits `categories` (older
/// server) or returns an empty list. Matches the server-side defaults.
let DEFAULT_GROCERY_CATEGORIES: [GroceryCategory] = [
  GroceryCategory(id: "produce",   name: "Produce"),
  GroceryCategory(id: "dairy",     name: "Dairy"),
  GroceryCategory(id: "grains",    name: "Grains"),
  GroceryCategory(id: "meat",      name: "Meat"),
  GroceryCategory(id: "frozen",    name: "Frozen"),
  GroceryCategory(id: "household", name: "Household"),
  GroceryCategory(id: "other",     name: "Other"),
]

// MARK: - Caffeine

struct CaffeineEntry: Codable, Identifiable, Hashable {
  let id: String
  let time: String
  var method: String        // "v60" | "matcha" | "other"
  var beans: String?
  var grams: Double?
  var note: String?
}

struct CaffeineDayResponse: Codable {
  let date: String
  let entries: [CaffeineEntry]
  let sessionCount: Int
  var totalG: Double?

  enum CodingKeys: String, CodingKey {
    case date, entries
    case sessionCount = "session_count"
    case totalG       = "total_g"
  }
}

struct CaffeineHistoryPoint: Codable, Hashable {
  let date: String
  let sessions: Int
  var totalG: Double?

  enum CodingKeys: String, CodingKey {
    case date, sessions
    case totalG = "total_g"
  }
}

struct CaffeineHistoryResponse: Codable {
  let daily: [CaffeineHistoryPoint]
}

struct CaffeineTimePoint: Codable, Hashable {
  let date: String
  let time: String
  let hour: Double
  let method: String
  var beans: String?
  var grams: Double?
}

struct CaffeineEntriesResponse: Codable {
  let entries: [CaffeineTimePoint]
}

// MARK: - Cannabis

struct CannabisEntry: Codable, Identifiable, Hashable {
  let id: String
  let time: String
  var method: String        // "vape" | "edible"
  var strain: String?
  var hit: Int?
  var grams: Double?
  var note: String?
  var effect: String?
}

struct CannabisDayResponse: Codable {
  let date: String
  let entries: [CannabisEntry]
  let sessionCount: Int
  var totalG: Double?

  enum CodingKeys: String, CodingKey {
    case date, entries
    case sessionCount = "session_count"
    case totalG       = "total_g"
  }
}

struct CannabisHistoryPoint: Codable, Hashable {
  let date: String
  let sessions: Int
  var totalG: Double?

  enum CodingKeys: String, CodingKey {
    case date, sessions
    case totalG = "total_g"
  }
}

struct CannabisHistoryResponse: Codable {
  let daily: [CannabisHistoryPoint]
}

// MARK: - Body (Withings)

/// One Withings weigh-in. From `/api/health/withings`.
struct WithingsRow: Codable, Identifiable, Hashable {
  let date: String           // YYYY-MM-DD
  var weightKg: Double?
  var fatPct: Double?
  var fatMassKg: Double?
  var fatFreeMassKg: Double?
  var muscleMassKg: Double?
  var hydrationKg: Double?
  var boneMassKg: Double?

  var id: String { date }

  enum CodingKeys: String, CodingKey {
    case date
    case weightKg      = "weight_kg"
    case fatPct        = "fat_pct"
    case fatMassKg     = "fat_mass_kg"
    case fatFreeMassKg = "fat_free_mass_kg"
    case muscleMassKg  = "muscle_mass_kg"
    case hydrationKg   = "hydration_kg"
    case boneMassKg    = "bone_mass_kg"
  }
}

struct WithingsResponse: Codable {
  let withings: [WithingsRow]
}

// MARK: - Gut

struct GutEntry: Codable, Identifiable, Hashable {
  let id: String
  let date: String
  let time: String
  var bristol: Int           // 1–7
  var blood: Int             // 0–N severity
  var volume: String?        // "small" | "medium" | "large"
  var discomfortLevel: String?     // "low" | "med" | "high"
  var discomfortHours: Double?
  var note: String?

  enum CodingKeys: String, CodingKey {
    case id, date, time, bristol, blood, volume, note
    case discomfortLevel = "discomfort_level"
    case discomfortHours = "discomfort_hours"
  }
}

struct GutDayResponse: Codable {
  let date: String
  let entries: [GutEntry]
  let movementCount: Int
  var maxBlood: Int
  var totalDiscomfortH: Double

  enum CodingKeys: String, CodingKey {
    case date, entries
    case movementCount    = "movement_count"
    case maxBlood         = "max_blood"
    case totalDiscomfortH = "total_discomfort_h"
  }
}

struct GutHistoryPoint: Codable, Hashable {
  let date: String
  let movements: Int
  var avgBristol: Double?
  var maxBlood: Int
  var discomfortH: Double

  enum CodingKeys: String, CodingKey {
    case date, movements
    case avgBristol  = "avg_bristol"
    case maxBlood    = "max_blood"
    case discomfortH = "discomfort_h"
  }
}

struct GutHistoryResponse: Codable {
  let daily: [GutHistoryPoint]
}

// MARK: - Settings
//
// Mirror of the webapp's AppSettings shape but trimmed to the fields the
// iOS client actually reads today. Anything we don't decode just gets
// ignored — the server stays authoritative; we don't round-trip writes
// for sections we haven't built UIs for yet.

struct AppTargets: Codable, Hashable {
  let proteinMinG: Double?
  let proteinMaxG: Double?
  let fatMinG: Double?
  let fatMaxG: Double?
  let carbsMinG: Double?
  let carbsMaxG: Double?
  let kcalMin: Double?
  let kcalMax: Double?
  let z2WeeklyMin: Int?
  let sleepTargetH: Double?
  let fastingMinH: Double?
  let fastingMaxH: Double?
  let weightMinKg: Double?
  let weightMaxKg: Double?
  let fatMinPct: Double?
  let fatMaxPct: Double?

  enum CodingKeys: String, CodingKey {
    case proteinMinG  = "protein_min_g"
    case proteinMaxG  = "protein_max_g"
    case fatMinG      = "fat_min_g"
    case fatMaxG      = "fat_max_g"
    case carbsMinG    = "carbs_min_g"
    case carbsMaxG    = "carbs_max_g"
    case kcalMin      = "kcal_min"
    case kcalMax      = "kcal_max"
    case z2WeeklyMin  = "z2_weekly_min"
    case sleepTargetH = "sleep_target_h"
    case fastingMinH  = "fasting_min_h"
    case fastingMaxH  = "fasting_max_h"
    case weightMinKg  = "weight_min_kg"
    case weightMaxKg  = "weight_max_kg"
    case fatMinPct    = "fat_min_pct"
    case fatMaxPct    = "fat_max_pct"
  }
}

struct AppUnits: Codable, Hashable {
  let weight: String        // "kg" | "lb"
  let distance: String      // "km" | "mi"
}

struct AppTimeSettings: Codable, Hashable {
  let homeTimezone: String
  let travelMode: String?
  let travelTimezone: String?

  enum CodingKeys: String, CodingKey {
    case homeTimezone   = "home_timezone"
    case travelMode     = "travel_mode"
    case travelTimezone = "travel_timezone"
  }
}

struct MacroColors: Codable, Hashable {
  let protein: String?
  let fat: String?
  let carbs: String?
  let fiber: String?
  let kcal: String?
  let fasting: String?
}

struct NutritionSettings: Codable, Hashable {
  let macroColors: MacroColors?

  enum CodingKeys: String, CodingKey {
    case macroColors = "macro_colors"
  }
}

struct AppSettings: Codable {
  let sectionOrder: [String]?
  let targets: AppTargets?
  let units: AppUnits?
  let time: AppTimeSettings?
  let theme: String?        // "system" | "light" | "dark"
  let eink: Bool?
  let nutrition: NutritionSettings?

  enum CodingKeys: String, CodingKey {
    case sectionOrder = "section_order"
    case targets, units, time, theme, eink, nutrition
  }
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

// MARK: - Add Info: config DTOs (caffeine / cannabis / training)

/// One preset bean from `/api/caffeine/config`.
struct CaffeineBean: Codable, Identifiable, Hashable {
  let id: String
  var name: String

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
  }

  enum CodingKeys: String, CodingKey { case id, name }
}

struct CaffeineConfig: Codable, Hashable {
  var beans: [CaffeineBean]
  var methods: [String]?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    beans = (try? c.decode([CaffeineBean].self, forKey: .beans)) ?? []
    methods = try c.decodeIfPresent([String].self, forKey: .methods)
  }

  enum CodingKeys: String, CodingKey { case beans, methods }
}

struct CannabisStrain: Codable, Identifiable, Hashable {
  let id: String
  var name: String

  init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
  }

  enum CodingKeys: String, CodingKey { case id, name }
}

struct CannabisConfig: Codable, Hashable {
  var strains: [CannabisStrain]
  var usesPerCapsule: Int

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    strains = (try? c.decode([CannabisStrain].self, forKey: .strains)) ?? []
    usesPerCapsule = (try? c.decode(Int.self, forKey: .usesPerCapsule)) ?? 3
  }

  enum CodingKeys: String, CodingKey {
    case strains
    case usesPerCapsule = "uses_per_capsule"
  }
}

struct SuggestedWorkout: Codable, Hashable {
  let type: String
  var reason: String?
}

struct SuggestedWorkoutResponse: Codable, Hashable {
  var suggested: SuggestedWorkout?
  var daysAgo: [String: Int]

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    suggested = try c.decodeIfPresent(SuggestedWorkout.self, forKey: .suggested)
    if let raw = try c.decodeIfPresent([String: Int?].self, forKey: .daysAgo) {
      daysAgo = raw.compactMapValues { $0 }
    } else {
      daysAgo = [:]
    }
  }

  enum CodingKeys: String, CodingKey {
    case suggested
    case daysAgo = "days_ago"
  }
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

// MARK: - Training: session types + draft
//
// Mirrors the FastAPI shapes that power the webapp's ⌘K training launcher
// and active-session logger. Lives at the end of the file so the existing
// model section above stays untouched.

/// One configured session type from `GET /api/training/session-types`.
/// The server owns the list so users can rename, reorder, or add custom
/// splits without an app update. `exercises` is the canonical template;
/// empty for free-form types where exercises are picked per-session.
struct SessionTypeConfig: Codable, Hashable, Identifiable {
  let id: String           // "upper", "lower", "cardio", "yoga", ...
  let label: String        // "Upper"
  let emoji: String?       // "💪"
  let exercises: [String]  // canonical exercise list (may be empty)

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    label = try c.decodeIfPresent(String.self, forKey: .label) ?? id.capitalized
    emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
    exercises = (try? c.decodeIfPresent([String].self, forKey: .exercises)) ?? []
  }

  enum CodingKeys: String, CodingKey { case id, label, emoji, exercises }
}

struct SessionTypesResponse: Codable {
  let sessionTypes: [SessionTypeConfig]
  enum CodingKeys: String, CodingKey { case sessionTypes = "session_types" }
}

/// Last-entry prefill values for an exercise — drives the logger's default
/// weight/sets/reps/duration so the user just confirms or tweaks. From
/// `POST /api/training/last-entries` with `{ exercises: [...] }`.
struct LastEntryValues: Codable, Hashable {
  var date: String?
  var weight: Double?
  var sets: String?           // server returns int or string ("AMRAP")
  var reps: String?
  var difficulty: String?
  var durationMin: Double?
  var distanceM: Double?
  var level: Double?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    date = try c.decodeIfPresent(String.self, forKey: .date)
    weight = try c.decodeIfPresent(Double.self, forKey: .weight)
    sets = Self.decodeIntOrString(c, key: .sets)
    reps = Self.decodeIntOrString(c, key: .reps)
    difficulty = try c.decodeIfPresent(String.self, forKey: .difficulty)
    durationMin = try c.decodeIfPresent(Double.self, forKey: .durationMin)
    distanceM = try c.decodeIfPresent(Double.self, forKey: .distanceM)
    level = try c.decodeIfPresent(Double.self, forKey: .level)
  }

  private static func decodeIntOrString(_ c: KeyedDecodingContainer<CodingKeys>,
                                        key: CodingKeys) -> String? {
    if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
    return try? c.decodeIfPresent(String.self, forKey: key)
  }

  enum CodingKeys: String, CodingKey {
    case date, weight, sets, reps, difficulty, level
    case durationMin = "duration_min"
    case distanceM = "distance_m"
  }

  /// True when last entry recorded cardio-only fields. Lets the logger
  /// pick the right input row without needing an exercise taxonomy.
  var isCardio: Bool {
    (durationMin ?? 0) > 0 || (distanceM ?? 0) > 0 || (level ?? 0) > 0
  }
}

/// Per-exercise entry inside an in-progress draft session. Persisted to
/// UserDefaults as JSON so a crash or background-kill mid-workout doesn't
/// lose progress — same role as the webapp's IndexedDB draft.
struct DraftEntry: Codable, Hashable, Identifiable {
  enum Status: String, Codable { case pending, saving, done, failed, skipped }

  var id: String { exercise }
  var exercise: String
  var weight: Double?
  var sets: Int?
  var reps: String?
  var difficulty: String      // "easy" | "medium" | "hard" | ""
  var durationMin: Double?
  var distanceM: Double?
  var level: Int?
  var isCardio: Bool
  var status: Status
  var savedFile: String?      // backend filename, used on re-edit
  var note: String

  static func from(exercise: String, last: LastEntryValues?) -> DraftEntry {
    let cardio = last?.isCardio ?? false
    return DraftEntry(
      exercise: exercise,
      weight: last?.weight,
      sets: last?.sets.flatMap { Int($0) } ?? (cardio ? nil : 3),
      reps: last?.reps ?? (cardio ? nil : "12"),
      difficulty: last?.difficulty ?? "medium",
      durationMin: last?.durationMin,
      distanceM: last?.distanceM,
      level: last?.level.flatMap { Int($0) },
      isCardio: cardio,
      status: .pending,
      savedFile: nil,
      note: ""
    )
  }
}

/// In-progress training session. One per app; cleared on Finish. Shape
/// mirrors the webapp's `DraftSession` so behavior — pre-fills, partial
/// saves, resume after crash — matches across platforms.
struct DraftSession: Codable, Hashable {
  var date: String           // YYYY-MM-DD
  var time: String           // HH:MM (local)
  var sessionType: String    // "upper" etc.
  var emoji: String?
  var label: String          // "Upper"
  var entries: [DraftEntry]
  var startedAt: String      // ISO8601
  var updatedAt: String

  /// Index of the next pending entry, or nil if everything's done/skipped.
  var nextPendingIndex: Int? {
    entries.firstIndex { $0.status == .pending }
  }

  var doneCount: Int { entries.filter { $0.status == .done }.count }
  var totalCount: Int { entries.filter { $0.status != .skipped }.count }
}
