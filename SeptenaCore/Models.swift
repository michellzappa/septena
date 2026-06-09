import Foundation

// Mirror of Septena api/routers/tasks.py — tasks/projects/areas only.

// MARK: - Task

enum TaskStatus: String, Codable, Hashable {
  case open
  case done
  case cancelled
  case someday
}

/// Provenance values stamped on a row's `source` field — what authored it.
/// Permanent / immutable; an audit trail, never cleared. Legacy rows predate
/// the field and read as nil (treated as human-authored, no cue). Writing an
/// explicit value on every native app create also means the app self-registers
/// the `source`/`sourceClient` CloudKit fields in dev — the gateway's Web
/// Services writes can't (they get rejected, not auto-extended).
public enum TaskSource {
  /// Authored in the Septena app on one of the user's devices.
  public static let app = "app"
  /// Authored by the MCP gateway (Claude).
  public static let mcp = "mcp"
}

/// Tunables for the "agent created this" freshness cue. Provenance is
/// permanent; the cue is transient and decays so a long-ignored agent row
/// stops glowing even if never explicitly acknowledged.
public enum AgentCue {
  /// How long after `createdAt` an unacknowledged agent row keeps glowing.
  public static let decayWindow: TimeInterval = 7 * 24 * 60 * 60   // 7 days
}

struct SeptenaTask: Identifiable, Codable, Hashable {
  let id: String
  var title: String
  var status: TaskStatus
  var created: String?         // YYYY-MM-DD
  var scheduled: String?       // YYYY-MM-DD
  /// Hard date the task is owed by. Things-style: rendering only — the
  /// server unions deadline-today rows into Today.items at view time, no
  /// mutation. Reschedule the deadline forward and the task drops out of
  /// Today on the next view load. The previous `due` field was the same
  /// data but with auto-pinning behavior baked in; the server still emits
  /// `due` as a mirror for the transition window, so we read either.
  var deadline: String?
  var today: Bool
  var todaySetOn: String?      // YYYY-MM-DD
  var completedAt: String?     // YYYY-MM-DDTHH:MM:SS
  var area: String?
  var project: String?
  var notes: String?
  var recurrence: Recurrence?
  /// For open recurring tasks: the date the next instance would land if
  /// completed today. Computed server-side per request; absent on non-
  /// recurring or already-completed tasks. Used to render
  /// "Repeats weekly · next May 26" in the row meta.
  var nextOccurrence: String?
  /// Stamped server-side on every write. Used as a watermark by the
  /// delta-sync path (`/api/tasks/changes?since=…`). Nil only on legacy
  /// records that haven't been touched since the server was upgraded.
  var updatedAt: String?
  /// Tombstone marker. When set, the row is logically deleted; the local
  /// store keeps it briefly so other clients (or this client on next
  /// pull) can purge accordingly. The Septena views filter rows where
  /// `deletedAt != nil` out of every read.
  var deletedAt: String?

  // MARK: Provenance + freshness cue
  // Populated from `TaskEntity` (not the wire — see `init(_:)`), so these
  // are intentionally excluded from `CodingKeys` and default to nil/.distantPast.
  /// `"mcp"` when authored by the MCP gateway (Claude); nil/"user"/"manual"
  /// for human-created. Permanent.
  var source: String? = nil
  /// Friendly label for `source` (e.g. "Claude"). Permanent.
  var sourceClient: String? = nil
  /// Set once the user engages an agent-created row; clears the cue. Transient.
  var acknowledgedAt: Date? = nil
  /// Canonical creation instant. Drives the cue decay window.
  var createdAt: Date = .distantPast
  /// User-controlled manual order (see `TaskEntity.position` / `TaskOrder`).
  /// Rides alongside the entity, not the wire — set in `init(_:)`. `0` = never
  /// dragged (order falls back to `createdAt`).
  var position: Double = 0

  /// The task's conversation (Task Conversations), decoded from the entity in
  /// `init(_:)`. Rides alongside, not the wire (excluded from CodingKeys), so the
  /// row badge and the editor card read it from the already-loaded task —
  /// NO second fetch-by-id per row. `TaskConvo()` (empty) for tasks without one.
  var conversation: TaskConvo = TaskConvo()

  /// True while this row should glow as a freshly agent-created item the
  /// user hasn't engaged yet. Provenance (`source`) is permanent; this cue
  /// is transient — it clears on `acknowledgedAt` and auto-decays after
  /// `AgentCue.decayWindow` so a long-ignored row stops glowing.
  func showsAgentCue(now: Date = Date()) -> Bool {
    guard source == TaskSource.mcp, acknowledgedAt == nil, createdAt != .distantPast else { return false }
    return now.timeIntervalSince(createdAt) < AgentCue.decayWindow
  }

  /// Transitional read-only alias so older call sites compile during the
  /// rename. Prefer `deadline` for new code; remove the alias once nothing
  /// else references it.
  var due: String? {
    get { deadline }
    set { deadline = newValue }
  }

  /// Canonical "overdue" test — Things-style: ONLY a hard `deadline` can make
  /// a task overdue. A scheduled ("When") date in the past is just a plan that
  /// rolled into Today; it never turns red. A deadline of *today or earlier*
  /// counts as overdue (red + badged). Shared by row styling and the
  /// badge/sidebar count so they never drift.
  var isOverdue: Bool {
    guard status == .open, let d = deadline else { return false }
    return d <= SeptenaDate.today
  }

  /// Whether this open task is on the Today list — the DTO mirror of
  /// `TaskEntity.isOnToday`. Today is a union of three signals: an explicit
  /// `today` pin, a scheduled ("When") date that has arrived, or a deadline
  /// that has arrived. UI surfaces (the Today toggle, indicators) must read
  /// this rather than the raw `today` flag, or a scheduled-today task looks
  /// like it isn't in Today. Keep in lockstep with `TaskEntity.isOnToday`.
  var isOnToday: Bool {
    guard status == .open else { return false }
    if today { return true }
    if let s = scheduled, s <= SeptenaDate.today { return true }
    if let d = deadline, d <= SeptenaDate.today { return true }
    return false
  }

  enum CodingKeys: String, CodingKey {
    case id, title, status, created, scheduled, deadline, today
    case todaySetOn = "today_set_on"
    case completedAt = "completed_at"
    case area, project, notes, recurrence
    case nextOccurrence = "next_occurrence"
    case updatedAt = "updated_at"
    case deletedAt = "deleted_at"
  }

  /// Legacy decode-only key — server still emits `due` as a mirror of
  /// `deadline` for the transition window. Kept separate from CodingKeys
  /// so the synthesized encoder doesn't try to round-trip it.
  private enum LegacyKeys: String, CodingKey { case due }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    // Tolerate unknown status values (e.g. legacy "someday" rows) by
    // falling back to open rather than failing the whole decode.
    status = (try? c.decode(TaskStatus.self, forKey: .status)) ?? .open
    created = try c.decodeIfPresent(String.self, forKey: .created)
    scheduled = try c.decodeIfPresent(String.self, forKey: .scheduled)
    // Prefer the canonical `deadline`; fall back to legacy `due` for old
    // payloads (cached responses, old server builds).
    if let dl = try c.decodeIfPresent(String.self, forKey: .deadline) {
      deadline = dl
    } else {
      let legacy = try decoder.container(keyedBy: LegacyKeys.self)
      deadline = try legacy.decodeIfPresent(String.self, forKey: .due)
    }
    today = (try? c.decode(Bool.self, forKey: .today)) ?? false
    todaySetOn = try c.decodeIfPresent(String.self, forKey: .todaySetOn)
    completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
    area = try c.decodeIfPresent(String.self, forKey: .area)
    project = try c.decodeIfPresent(String.self, forKey: .project)
    notes = try c.decodeIfPresent(String.self, forKey: .notes)
    recurrence = try c.decodeIfPresent(Recurrence.self, forKey: .recurrence)
    nextOccurrence = try c.decodeIfPresent(String.self, forKey: .nextOccurrence)
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
      case .day: return String(localized: "Daily", comment: "Recurrence cadence")
      case .week: return String(localized: "Weekly", comment: "Recurrence cadence")
      case .month: return String(localized: "Monthly", comment: "Recurrence cadence")
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
  var somedayCount: Int
  var openCount: Int

  enum CodingKeys: String, CodingKey {
    case today
    case todayCount = "today_count"
    case reviewCount = "review_count"
    case inboxCount = "inbox_count"
    case upcomingCount = "upcoming_count"
    case unscheduledCount = "unscheduled_count"
    case somedayCount = "someday_count"
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
    somedayCount = (try? c.decode(Int.self, forKey: .somedayCount)) ?? 0
    openCount = (try? c.decode(Int.self, forKey: .openCount)) ?? 0
  }

  init(today: String, todayCount: Int, reviewCount: Int,
       inboxCount: Int, upcomingCount: Int, unscheduledCount: Int,
       somedayCount: Int = 0, openCount: Int) {
    self.today = today
    self.todayCount = todayCount
    self.reviewCount = reviewCount
    self.inboxCount = inboxCount
    self.upcomingCount = upcomingCount
    self.unscheduledCount = unscheduledCount
    self.somedayCount = somedayCount
    self.openCount = openCount
  }
}

// MARK: - UI filter (maps to server `view` param + optional area/project scope)

enum TaskFilter: Equatable, Hashable {
  case today
  case inbox
  case upcoming
  case unscheduled
  case someday
  case logbook
  case project(String)
  case area(String)

  var serverView: String {
    switch self {
    case .today: return "today"
    case .inbox: return "inbox"
    case .upcoming: return "upcoming"
    case .unscheduled: return "unscheduled"
    case .someday: return "someday"
    case .logbook: return "logbook"
    case .project, .area: return "all"
    }
  }

  // User-facing label. We follow Things 3 vocabulary: "Anytime" for the
  // unscheduled-open pile and "Someday" for the deliberately-deferred one.
  // The serverView key stays `unscheduled` so the API contract is unchanged.
  var title: String {
    switch self {
    case .today: return String(localized: "Today", comment: "Task filter")
    case .inbox: return String(localized: "Inbox", comment: "Task filter")
    case .upcoming: return String(localized: "Upcoming", comment: "Task filter")
    case .unscheduled: return String(localized: "Anytime", comment: "Task filter")
    case .someday: return String(localized: "Someday", comment: "Task filter")
    case .logbook: return String(localized: "Logbook", comment: "Task filter")
    case .project: return String(localized: "Project", comment: "Task filter")
    case .area: return String(localized: "Area", comment: "Task filter")
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

  init(id: String,
       name: String,
       emoji: String?,
       bucket: String,
       done: Bool,
       skipped: Bool,
       note: String?,
       time: String?) {
    self.id = id
    self.name = name
    self.emoji = emoji
    self.bucket = bucket
    self.done = done
    self.skipped = skipped
    self.note = note
    self.time = time
  }
}

struct HabitsDayResponse: Codable {
  var date: String
  var buckets: [String]
  var grouped: [String: [HabitDayItem]]
}

struct HabitsRangeResponse: Codable {
  var days: [HabitsDayResponse]
}

/// Single supplement instance for a given day. From `/api/supplements/day/{date}`.
struct SupplementDayItem: Codable, Identifiable, Hashable {
  let id: String
  var name: String
  var emoji: String?
  /// Optional time-of-day bucket ("morning" | "afternoon" | "evening").
  /// `nil` = "anytime" (shows all day). Unlike habits, bucketing is optional.
  var bucket: String?
  var done: Bool
  var note: String?
  var time: String?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
    emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
    bucket = try c.decodeIfPresent(String.self, forKey: .bucket)
    done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    note = try c.decodeIfPresent(String.self, forKey: .note)
    time = try c.decodeIfPresent(String.self, forKey: .time)
  }

  enum CodingKeys: String, CodingKey { case id, name, emoji, bucket, done, note, time }

  init(id: String,
       name: String,
       emoji: String?,
       bucket: String? = nil,
       done: Bool,
       note: String?,
       time: String?) {
    self.id = id
    self.name = name
    self.emoji = emoji
    self.bucket = bucket
    self.done = done
    self.note = note
    self.time = time
  }
}

struct SupplementDefinition: Codable, Identifiable, Hashable {
  let id: String
  var name: String
  var emoji: String?
  /// Optional time-of-day bucket; `nil` = anytime. See `SupplementDayItem`.
  var bucket: String?

  init(id: String, name: String, emoji: String?, bucket: String? = nil) {
    self.id = id
    self.name = name
    self.emoji = emoji
    self.bucket = bucket
  }
}

struct SupplementsDayResponse: Codable {
  var date: String
  var items: [SupplementDayItem]
}

struct SupplementsRangeResponse: Codable {
  var days: [SupplementsDayResponse]
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

  init(fromFallbackID id: String,
       name: String,
       emoji: String?,
       dueDate: String?,
       lastCompleted: String?,
       lastCompletedTime: String?,
       daysOverdue: Int,
       cadenceDays: Int?) {
    self.id = id
    self.name = name
    self.emoji = emoji
    self.dueDate = dueDate
    self.lastCompleted = lastCompleted
    self.lastCompletedTime = lastCompletedTime
    self.daysOverdue = daysOverdue
    self.cadenceDays = cadenceDays
  }
}

struct ChoreDefinitionPayload: Codable, Hashable {
  let id: String
  var name: String
  var emoji: String?
  var cadenceDays: Int

  enum CodingKeys: String, CodingKey {
    case id, name, emoji
    case cadenceDays = "cadence_days"
  }
}

struct ChoreEventPayload: Codable, Hashable {
  let recordID: String
  let choreID: String
  let action: String
  let date: String
  var newDueDate: String?
  var reason: String?
  var note: String?
  var time: String?

  enum CodingKeys: String, CodingKey {
    case recordID = "record_id"
    case choreID = "chore_id"
    case action, date, reason, note, time
    case newDueDate = "new_due_date"
  }
}

struct ChoresExportResponse: Codable {
  var definitions: [ChoreDefinitionPayload]
  var events: [ChoreEventPayload]
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
  var session: String        // e.g. "upper", "cardio"
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

  /// Explicit init for CloudKit-backed code paths — the custom decoder above
  /// suppresses Swift's synthesized memberwise initializer.
  init(date: String,
       session: String,
       exercise: String?,
       weight: Double?,
       sets: String?,
       reps: String?,
       difficulty: String?,
       durationMin: Double?,
       distanceM: Double?,
       level: Double?,
       file: String?,
       concludedAt: String?,
       loggedAt: String?) {
    self.date = date
    self.session = session
    self.exercise = exercise
    self.weight = weight
    self.sets = sets
    self.reps = reps
    self.difficulty = difficulty
    self.durationMin = durationMin
    self.distanceM = distanceM
    self.level = level
    self.file = file
    self.concludedAt = concludedAt
    self.loggedAt = loggedAt
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

  init(date: String,
       weight: Double? = nil,
       sets: String? = nil,
       reps: String? = nil,
       difficulty: String? = nil,
       durationMin: Double? = nil,
       distanceM: Double? = nil,
       level: Double? = nil) {
    self.date = date
    self.weight = weight
    self.sets = sets
    self.reps = reps
    self.difficulty = difficulty
    self.durationMin = durationMin
    self.distanceM = distanceM
    self.level = level
  }
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

// MARK: - Nutrition

/// One logged meal/snack. From `/api/nutrition/entries`.
struct NutritionEntry: Codable, Identifiable, Hashable {
  let date: String
  let time: String
  var emoji: String?
  var proteinG: Double
  var fatG: Double
  var saturatedFatG: Double?
  var carbsG: Double
  var sugarG: Double?
  var fiberG: Double?
  var alcoholG: Double?
  var kcal: Double
  var sodiumMg: Double?
  var cholesterolMg: Double?
  var potassiumMg: Double?
  var waterMl: Double?
  var foods: [String]
  var ingredients: [String]?
  var photoAssetID: String?
  let file: String

  var id: String { file }

  enum CodingKeys: String, CodingKey {
    case date, time, emoji, kcal, foods, ingredients, file
    case proteinG      = "protein_g"
    case fatG          = "fat_g"
    case saturatedFatG = "saturated_fat_g"
    case carbsG        = "carbs_g"
    case sugarG        = "sugar_g"
    case fiberG        = "fiber_g"
    case alcoholG      = "alcohol_g"
    case sodiumMg      = "sodium_mg"
    case cholesterolMg = "cholesterol_mg"
    case potassiumMg   = "potassium_mg"
    case waterMl       = "water_ml"
    case photoAssetID  = "photo_asset_id"
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

/// Macro targets and fasting prefs, persisted in NSUbiquitousKeyValueStore.
/// Replaces the `GET /api/nutrition/macros-config` FastAPI endpoint.
enum NutritionPrefs {
  private static let kvsKey = "nutrition.macrosConfig"

  /// Reads from UserDefaults.standard first for fast local access, then
  /// falls back to NSUbiquitousKeyValueStore so macro targets can sync
  /// across signed-in Apple devices via the shared iCloud KVS store.
  static func loadMacrosConfig() -> MacrosConfig? {
    if let data = UserDefaults.standard.data(forKey: kvsKey),
       let config = try? JSONDecoder().decode(MacrosConfig.self, from: data) {
      return config
    }
    if let data = NSUbiquitousKeyValueStore.default.data(forKey: kvsKey),
       let config = try? JSONDecoder().decode(MacrosConfig.self, from: data) {
      return config
    }
    return nil
  }

  static func saveMacrosConfig(_ config: MacrosConfig) {
    guard let data = try? JSONEncoder().encode(config) else { return }
    UserDefaults.standard.set(data, forKey: kvsKey)
    NSUbiquitousKeyValueStore.default.set(data, forKey: kvsKey)
    NSUbiquitousKeyValueStore.default.synchronize()
  }
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

/// Default category list — seeded into a fresh user's GroceriesDestinationView
/// when no CloudKit categories have been created yet.
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

// MARK: - Cannabis

struct CannabisEntry: Codable, Identifiable, Hashable {
  let id: String
  let time: String
  var method: String        // "vape" | "edible"
  var strain: String?
  var hit: Int?
  var grams: Double?
  var note: String?
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

struct CannabisTimePoint: Codable, Hashable {
  let date: String
  let time: String
  let hour: Double
  let method: String
  var strain: String?
  var hit: Int?
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

// MARK: - Gut

struct GutEntry: Codable, Identifiable, Hashable {
  let id: String
  let date: String
  let time: String
  var bristol: Int           // 1–7
  var blood: Int             // 0–N severity
  var volume: String?        // "small" | "medium" | "large"
  var discomfortLevel: String?     // "low" | "med" | "high"
  var discomfortStart: String?     // ISO timestamp (export only)
  var discomfortEnd: String?       // ISO timestamp (export only)
  var discomfortHours: Double?
  var note: String?

  enum CodingKeys: String, CodingKey {
    case id, date, time, bristol, blood, volume, note
    case discomfortLevel = "discomfort_level"
    case discomfortStart = "discomfort_start"
    case discomfortEnd = "discomfort_end"
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

// MARK: - Export DTOs (one-shot CK bootstrap pull)

struct GutExportResponse: Codable {
  let entries: [GutEntry]
}

struct CaffeineExportEntry: Codable, Hashable {
  let id: String
  let date: String
  let time: String
  let method: String
  let beans: String?
  let grams: Double?
  let note: String?
}

struct CaffeineExportResponse: Codable {
  let entries: [CaffeineExportEntry]
  let beans: [CaffeineBean]
}

struct CannabisExportEntry: Codable, Hashable {
  let id: String
  let date: String
  let time: String
  let method: String
  let strain: String?
  let hit: Int?
  let grams: Double?
  let note: String?
}

struct CannabisExportResponse: Codable {
  let entries: [CannabisExportEntry]
}

/// One exercise in the user-editable catalog. Drives the logger's
/// "what fields does this exercise need" decision (strength = weight/sets/reps,
/// cardio = duration/distance/level, etc).
struct ExerciseDefinition: Codable, Identifiable, Hashable {
  let id: String           // slug, e.g. "chest-press"
  var name: String
  var type: String         // strength|cardio|mobility|core
  var subgroup: String?    // TODO: remove subgroup after primaryMuscle backfill ships
  var aliases: [String]?
  var primaryMuscle: Muscle?
  var secondaryMuscles: [Muscle]
  var archived: Bool

  init(id: String,
       name: String,
       type: String,
       subgroup: String? = nil,
       aliases: [String]? = nil,
       primaryMuscle: Muscle? = nil,
       secondaryMuscles: [Muscle] = [],
       archived: Bool = false) {
    self.id = id
    self.name = name
    self.type = type
    self.subgroup = subgroup
    self.aliases = aliases
    self.primaryMuscle = primaryMuscle
    self.secondaryMuscles = secondaryMuscles
    self.archived = archived
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    type = try c.decodeIfPresent(String.self, forKey: .type) ?? "strength"
    subgroup = try c.decodeIfPresent(String.self, forKey: .subgroup)
    aliases = try c.decodeIfPresent([String].self, forKey: .aliases)
    primaryMuscle = try c.decodeIfPresent(Muscle.self, forKey: .primaryMuscle)
    secondaryMuscles = (try? c.decodeIfPresent([Muscle].self, forKey: .secondaryMuscles)) ?? []
    archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(type, forKey: .type)
    try c.encodeIfPresent(subgroup, forKey: .subgroup)
    try c.encodeIfPresent(aliases, forKey: .aliases)
    try c.encodeIfPresent(primaryMuscle, forKey: .primaryMuscle)
    try c.encode(secondaryMuscles, forKey: .secondaryMuscles)
    try c.encode(archived, forKey: .archived)
  }

  enum CodingKeys: String, CodingKey {
    case id, name, type, subgroup, aliases
    case primaryMuscle = "primary_muscle"
    case secondaryMuscles = "secondary_muscles"
    case archived
  }
}

/// Full snapshot from `GET /api/training/export`. iOS bootstrap calls this
/// once to seed SwiftData with every historical entry plus both catalogs.
struct TrainingExportResponse: Codable {
  let entries: [ExerciseEntry]
  let sessionTypes: [SessionTypeConfig]
  let exercises: [ExerciseDefinition]

  enum CodingKeys: String, CodingKey {
    case entries, exercises
    case sessionTypes = "session_types"
  }
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

/// Per-macro tile preference. The id matches `MacroCatalog.Macro.id`.
/// `colorHex` overrides the catalog's default tint; `visible` toggles whether
/// the tile renders. Array position in `NutritionSettings.macroTiles` is the
/// authoritative display order.
struct MacroTilePref: Codable, Hashable, Identifiable {
  var id: String
  var colorHex: String?
  var visible: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case colorHex = "color_hex"
    case visible
  }
}

struct NutritionSettings: Codable, Hashable {
  var macroColors: MacroColors?
  /// Authoritative tile list. Nil for legacy payloads → consumers should
  /// fall back to `MacroCatalog.defaultTilePrefs()`.
  var macroTiles: [MacroTilePref]?

  enum CodingKeys: String, CodingKey {
    case macroColors = "macro_colors"
    case macroTiles  = "macro_tiles"
  }
}

struct AppSettings: Codable {
  var sectionOrder: [String]?
  var targets: AppTargets?
  var units: AppUnits?
  var time: AppTimeSettings?
  var theme: String?        // "system" | "light" | "dark"
  var eink: Bool?
  var nutrition: NutritionSettings?
  var hkSync: HKSyncSettings?
  /// Personalizes the dashboard welcome greeting. Synced so the user's name
  /// follows them across their own devices; also mirrored into the
  /// `welcomeName` @AppStorage key that `WelcomeHeader` reads locally.
  /// Defaulted so the existing memberwise-init call sites stay source-stable.
  var welcomeName: String? = nil

  /// User-configured boundary hours for the morning/afternoon/evening day
  /// buckets (Settings ▸ Time of Day). Synced across devices; mirrored into
  /// the shared App Group suite that `DayBucket` reads. Nil → historical
  /// defaults (12 / 17). Defaulted so memberwise-init call sites stay stable.
  var morningCutoffHour: Int? = nil
  var afternoonCutoffHour: Int? = nil

  enum CodingKeys: String, CodingKey {
    case sectionOrder = "section_order"
    case targets, units, time, theme, eink, nutrition
    case hkSync = "hk_sync"
    case welcomeName = "welcome_name"
    case morningCutoffHour = "morning_cutoff_hour"
    case afternoonCutoffHour = "afternoon_cutoff_hour"
  }
}

/// Per-section HealthKit write toggles. All default to `true` so existing
/// users get full sync on upgrade without extra friction; they can opt out
/// per-type in Settings → Integrations → Apple Health.
struct HKSyncSettings: Codable {
  var mood: Bool
  var nutrition: Bool

  init(mood: Bool = true, nutrition: Bool = true) {
    self.mood = mood
    self.nutrition = nutrition
  }
}

// `NextItem` / `NextItemsResponse` and the `itemsForBucket` helper now live in
// `SeptenaCore/NextWire.swift` (shared by the app, Mac, watch, and widget).

// MARK: - Add Info: config DTOs (caffeine / cannabis / training)

/// One preset bean from `/api/caffeine/config`.
struct CaffeineBean: Codable, Identifiable, Hashable {
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

struct CaffeineConfig: Codable, Hashable {
  var beans: [CaffeineBean]
  var methods: [String]?

  init(beans: [CaffeineBean], methods: [String]? = nil) {
    self.beans = beans
    self.methods = methods
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    beans = (try? c.decode([CaffeineBean].self, forKey: .beans)) ?? []
    methods = try c.decodeIfPresent([String].self, forKey: .methods)
  }

  enum CodingKeys: String, CodingKey { case beans, methods }
}

struct CannabisConfig: Codable, Hashable {
  var usesPerCapsule: Int

  init(usesPerCapsule: Int) {
    self.usesPerCapsule = usesPerCapsule
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    usesPerCapsule = (try? c.decode(Int.self, forKey: .usesPerCapsule)) ?? 3
  }

  enum CodingKeys: String, CodingKey {
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

  init(suggested: SuggestedWorkout?, daysAgo: [String: Int]) {
    self.suggested = suggested
    self.daysAgo = daysAgo
  }

  static func make(suggested: SuggestedWorkout?, daysAgo: [String: Int]) -> SuggestedWorkoutResponse {
    SuggestedWorkoutResponse(suggested: suggested, daysAgo: daysAgo)
  }
}

// MARK: - Goals

struct Goal: Identifiable, Codable, Hashable {
  let id: String
  var text: String
  var sections: [String]
  let created: String
  var updated: String
  // Optional measurement attachment — when all four are set the UI renders
  // progress against a target derived from logged data in other sections.
  var metricKey: String? = nil
  var metricWindow: String? = nil
  var metricComparator: String? = nil
  var metricTarget: Double? = nil
  var metricBaseline: Double? = nil
  /// Upper bound for a `range` comparator (`metricTarget` is the lower bound).
  var metricTargetUpper: Double? = nil
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

  /// Wall-clock "HH:mm" formatter. The one true source for the time-of-day
  /// stamp written on logged events; call sites used to each spin up their
  /// own `currentTimeString()` / `nowHHMM()` with the same config.
  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "HH:mm"
    return f
  }()

  private static let secondsTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  private static let weekdayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEEE"
    return f
  }()

  private static let monthDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
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

  /// Wall-clock "HH:mm" right now.
  static var nowHHMM: String { timeFormatter.string(from: Date()) }

  /// Wall-clock "HH:mm:ss" right now. Used where sub-minute ordering matters
  /// (e.g. several events logged in the same minute) and to match the hosted
  /// gateway, which defaults event times to second precision.
  static var nowHHMMSS: String { secondsTimeFormatter.string(from: Date()) }

  /// Human label for a "yyyy-MM-dd" string: "Today", "Yesterday", the
  /// weekday name within the last week, else "MMM d". Returns the raw
  /// string unchanged if it can't be parsed. Single home for the
  /// browse/backfill sheet titles that each carried a copy of this.
  static func friendlyLabel(_ iso: String) -> String {
    guard let d = parse(iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return String(localized: "Today", comment: "Relative date") }
    if cal.isDateInYesterday(d) { return String(localized: "Yesterday", comment: "Relative date") }
    let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 0
    if days < 7 { return weekdayFormatter.string(from: d) }
    return monthDayFormatter.string(from: d)
  }
}

// MARK: - Training: session types + draft
//
// Mirrors the FastAPI shapes that power the webapp's ⌘K training launcher
// and active-session logger. Lives at the end of the file so the existing
// model section above stays untouched.

/// Coarse muscle-group taxonomy. 10 fixed values — deliberate; adding fine
/// anatomy is Phase 3 scope. Used for filter chips in the catalog editor.
enum Muscle: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
  case chest, back, shoulders, biceps, triceps
  case quads, hamstrings, glutes, calves, core
  var id: String { rawValue }
  var label: String {
    switch self {
    case .chest:      return String(localized: "Chest", comment: "Muscle group")
    case .back:       return String(localized: "Back", comment: "Muscle group")
    case .shoulders:  return String(localized: "Shoulders", comment: "Muscle group")
    case .biceps:     return String(localized: "Biceps", comment: "Muscle group")
    case .triceps:    return String(localized: "Triceps", comment: "Muscle group")
    case .quads:      return String(localized: "Quads", comment: "Muscle group")
    case .hamstrings: return String(localized: "Hamstrings", comment: "Muscle group")
    case .glutes:     return String(localized: "Glutes", comment: "Muscle group")
    case .calves:     return String(localized: "Calves", comment: "Muscle group")
    case .core:       return String(localized: "Core", comment: "Muscle group")
    }
  }
}

/// One configured session type from `GET /api/training/session-types`.
/// The server owns the list so users can rename, reorder, or add custom
/// splits without an app update. `exercises` is the canonical template;
/// empty for free-form types where exercises are picked per-session.
/// The fundamental category of a training routine. Drives the draft
/// session's input UI (weight + reps vs. duration + distance) and the
/// per-routine SF Symbol shown in the quickadd menu.
///
/// Added to fix a bug where routines without a category fell back to
/// per-exercise inference (`DraftEntry.from(exercise:last:)` reading
/// `last?.isCardio`), so an Upper session could open in cardio mode if
/// any of its exercises had ever been logged with a duration field.
/// With `kind` declared on the routine itself, the category is locked
/// to the routine identity regardless of historical entry shapes.
///
/// `.mixed` is the safe migration default for legacy routines whose
/// id isn't recognised by the seed mapping in `SessionKind.defaulted(for:)`.
enum SessionKind: String, Codable, Hashable, CaseIterable {
  case strength
  case cardio
  case mobility    // yoga, stretching, mobility work
  case mixed       // multi-category sessions; treated like strength for input UI

  /// SF Symbol shown next to the routine row in the quickadd menu.
  var icon: String {
    switch self {
    case .strength: return "figure.strengthtraining.traditional"
    case .cardio:   return "figure.run"
    case .mobility: return "figure.yoga"
    case .mixed:    return "figure.mixed.cardio"
    }
  }

  /// Hard-coded migration default for known seed routine ids. Returns
  /// `.mixed` for anything unrecognised — those records keep the safe
  /// default until the user picks a kind in Settings (future).
  static func defaulted(for id: String) -> SessionKind {
    switch id.lowercased() {
    case "cardio", "run", "running", "bike", "cycling", "swim", "swimming",
         "row", "rowing", "z2", "zone2":
      return .cardio
    case "yoga", "mobility", "stretch", "stretching", "flexibility":
      return .mobility
    case "upper", "lower", "push", "pull", "legs", "chest", "back",
         "shoulders", "arms", "strength", "lifting", "full", "fullbody",
         "full-body", "full_body":
      return .strength
    default:
      return .mixed
    }
  }
}

struct SessionTypeConfig: Codable, Hashable, Identifiable {
  let id: String           // "upper", "lower", "cardio", "yoga", ...
  let label: String        // "Upper"
  let emoji: String?       // "💪"
  let exercises: [String]  // canonical exercise list (may be empty)
  let archived: Bool
  let kind: SessionKind    // strength / cardio / mobility / mixed

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    label = try c.decodeIfPresent(String.self, forKey: .label) ?? id.capitalized
    emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
    exercises = (try? c.decodeIfPresent([String].self, forKey: .exercises)) ?? []
    archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? false
    // Missing kind in legacy payloads → seed default by id, so an
    // old "upper" record decodes as `.strength` without a migration.
    let raw = try? c.decodeIfPresent(String.self, forKey: .kind)
    kind = raw.flatMap(SessionKind.init(rawValue:)) ?? SessionKind.defaulted(for: id)
  }

  enum CodingKeys: String, CodingKey { case id, label, emoji, exercises, archived, kind }

  init(id: String, label: String, emoji: String?, exercises: [String], archived: Bool = false, kind: SessionKind? = nil) {
    self.id = id
    self.label = label
    self.emoji = emoji
    self.exercises = exercises
    self.archived = archived
    self.kind = kind ?? SessionKind.defaulted(for: id)
  }

  static func make(id: String, label: String, emoji: String?, exercises: [String], archived: Bool = false, kind: SessionKind? = nil) -> SessionTypeConfig {
    SessionTypeConfig(id: id, label: label, emoji: emoji, exercises: exercises, archived: archived, kind: kind)
  }
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

  init(date: String? = nil,
       weight: Double? = nil,
       sets: String? = nil,
       reps: String? = nil,
       difficulty: String? = nil,
       durationMin: Double? = nil,
       distanceM: Double? = nil,
       level: Double? = nil) {
    self.date = date
    self.weight = weight
    self.sets = sets
    self.reps = reps
    self.difficulty = difficulty
    self.durationMin = durationMin
    self.distanceM = distanceM
    self.level = level
  }

  static let empty = LastEntryValues()
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
  var level: Double?
  var isCardio: Bool
  /// True for mobility/yoga entries — no weight/reps, no
  /// duration/distance, just a done/skip + optional difficulty + note.
  /// Added so a `SessionKind.mobility` routine renders as a checklist
  /// rather than borrowing cardio or strength input shapes.
  var isMobility: Bool
  var status: Status
  var savedFile: String?      // backend filename, used on re-edit
  var note: String

  enum CodingKeys: String, CodingKey {
    case exercise, weight, sets, reps, difficulty, durationMin, distanceM,
         level, isCardio, isMobility, status, savedFile, note
  }

  init(exercise: String,
       weight: Double? = nil,
       sets: Int? = nil,
       reps: String? = nil,
       difficulty: String = "",
       durationMin: Double? = nil,
       distanceM: Double? = nil,
       level: Double? = nil,
       isCardio: Bool = false,
       isMobility: Bool = false,
       status: Status = .pending,
       savedFile: String? = nil,
       note: String = "") {
    self.exercise = exercise
    self.weight = weight
    self.sets = sets
    self.reps = reps
    self.difficulty = difficulty
    self.durationMin = durationMin
    self.distanceM = distanceM
    self.level = level
    self.isCardio = isCardio
    self.isMobility = isMobility
    self.status = status
    self.savedFile = savedFile
    self.note = note
  }

  /// Custom decoder so on-disk drafts written before `isMobility`
  /// existed continue to load (the synthesised decoder would throw on
  /// a missing key for the non-optional Bool). Same pattern other
  /// model structs in this file use for forward-compatible additions.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    exercise = try c.decode(String.self, forKey: .exercise)
    weight = try c.decodeIfPresent(Double.self, forKey: .weight)
    sets = try c.decodeIfPresent(Int.self, forKey: .sets)
    reps = try c.decodeIfPresent(String.self, forKey: .reps)
    difficulty = try c.decodeIfPresent(String.self, forKey: .difficulty) ?? ""
    durationMin = try c.decodeIfPresent(Double.self, forKey: .durationMin)
    distanceM = try c.decodeIfPresent(Double.self, forKey: .distanceM)
    level = try c.decodeIfPresent(Double.self, forKey: .level)
    isCardio = try c.decodeIfPresent(Bool.self, forKey: .isCardio) ?? false
    isMobility = try c.decodeIfPresent(Bool.self, forKey: .isMobility) ?? false
    status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .pending
    savedFile = try c.decodeIfPresent(String.self, forKey: .savedFile)
    note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
  }

  /// Build a fresh draft entry. The override flags (when non-nil)
  /// take precedence over inferring from `last?.isCardio`, so a
  /// routine that knows its own kind can lock the entry's input shape
  /// regardless of stray historical entries that might have a
  /// duration field set on a normally-strength exercise. At most one
  /// override should be true — a mobility entry is neither cardio
  /// nor strength.
  static func from(exercise: String,
                   last: LastEntryValues?,
                   cardioOverride: Bool? = nil,
                   mobilityOverride: Bool? = nil) -> DraftEntry {
    let mobility = mobilityOverride ?? false
    // Mobility wins: if it's a yoga/mobility routine, force-disable cardio
    // even if the last entry for this exercise looked cardio-shaped.
    let cardio = mobility ? false : (cardioOverride ?? (last?.isCardio ?? false))
    return DraftEntry(
      exercise: exercise,
      weight: mobility ? nil : last?.weight,
      sets: mobility ? nil : (last?.sets.flatMap { Int($0) } ?? (cardio ? nil : 3)),
      reps: mobility ? nil : (last?.reps ?? (cardio ? nil : "12")),
      // Cardio entries have no difficulty UI, so don't seed a default
      // value or it gets persisted on Done. Strength and mobility both
      // collect difficulty, so they keep the "medium" fallback.
      difficulty: cardio ? (last?.difficulty ?? "") : (last?.difficulty ?? "medium"),
      // Mobility keeps duration (yoga = TIME) but not distance/level.
      durationMin: last?.durationMin,
      distanceM: mobility ? nil : last?.distanceM,
      level: mobility ? nil : last?.level,
      isCardio: cardio,
      isMobility: mobility,
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
  var label: String          // "Upper"
  var entries: [DraftEntry]
  var startedAt: String      // ISO8601
  var updatedAt: String
  /// Snapshot of "last time" values for each exercise in the session,
  /// captured at start() and stable for the whole workout so the
  /// progression hints don't shift mid-set. Keyed by lowercased name.
  var lastByExercise: [String: LastEntryValues] = [:]
  /// PR baselines captured at start() so the "PR" pill threshold
  /// stays put across the session even if the user logs a new PR
  /// on the first set.
  var prBaselines: [String: PRBaseline] = [:]
  /// Top N most-recent historical entries per exercise (newest first),
  /// captured at start() and frozen for the workout. Drives the compact
  /// "last 3" table inside each card's expanded editor.
  var recentByExercise: [String: [RecentExerciseEntry]] = [:]

  /// Index of the next pending entry, or nil if everything's done/skipped.
  var nextPendingIndex: Int? {
    entries.firstIndex { $0.status == .pending }
  }

  var doneCount: Int { entries.filter { $0.status == .done }.count }
  var totalCount: Int { entries.filter { $0.status != .skipped }.count }
}

// MARK: - Insights (client-side correlation engine)
//
// Computed locally in CorrelationEngine — no wire format. Kept here so
// the engine's output value type lives alongside the rest of the app's
// domain models. Only the (date, x, y) point shape is shared; the
// engine builds its richer Bucket / EvaluatedPair types on top.
public struct CorrelationPairPoint: Hashable {
  public let date: String
  public let x: Double
  public let y: Double
  public init(date: String, x: Double, y: Double) {
    self.date = date; self.x = x; self.y = y
  }
}

// MARK: - Mood

/// One logged check-in. Mirrors the Caffeine/Cannabis event shape so the
/// dashboard heatmap and section views can share the same patterns.
public struct MoodEntry: Codable, Identifiable, Hashable {
  public let id: String
  public let time: String        // HH:MM:SS
  public var bucket: String      // morning | afternoon | evening
  public var quadrant: String    // hap | han | lan | lap
  public var arousal: Int        // 1...3
  public var valence: Int        // 1...3
  public var emotion: String     // catalog word, e.g. "Upbeat"
  public var note: String?
  public init(id: String, time: String, bucket: String,
              quadrant: String, arousal: Int, valence: Int,
              emotion: String, note: String? = nil) {
    self.id = id; self.time = time; self.bucket = bucket
    self.quadrant = quadrant; self.arousal = arousal; self.valence = valence
    self.emotion = emotion; self.note = note
  }
}

public struct MoodDayResponse: Codable {
  public let date: String
  public let entries: [MoodEntry]
  public let logCount: Int
  /// Bucket → most recent entry for that bucket (nil if none yet today).
  public let byBucket: [String: MoodEntry]
  public init(date: String, entries: [MoodEntry],
              logCount: Int, byBucket: [String: MoodEntry]) {
    self.date = date; self.entries = entries
    self.logCount = logCount; self.byBucket = byBucket
  }
}

public struct MoodHistoryPoint: Codable, Hashable {
  public let date: String
  public let logs: Int
  /// Dominant quadrant for the day (`hap | han | lan | lap`), or nil if
  /// the day had no logs. "Dominant" = most-logged; ties broken by the
  /// circumplex order hap, lap, lan, han so colored cells stay stable.
  public var dominantQuadrant: String?
  /// Bucket (`morning | afternoon | evening`) → dominant quadrant for
  /// that bucket on this day. Only contains entries for buckets the
  /// user actually logged. Drives the 30-day per-bucket heatmap.
  public var bucketQuadrants: [String: String]
  public init(date: String,
              logs: Int,
              dominantQuadrant: String?,
              bucketQuadrants: [String: String] = [:]) {
    self.date = date
    self.logs = logs
    self.dominantQuadrant = dominantQuadrant
    self.bucketQuadrants = bucketQuadrants
  }
}

public struct MoodHistoryResponse: Codable {
  public let daily: [MoodHistoryPoint]
  public init(daily: [MoodHistoryPoint]) { self.daily = daily }
}
