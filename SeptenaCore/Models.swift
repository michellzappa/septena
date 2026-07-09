import Foundation

// Mirror of Septena api/routers/tasks.py — tasks/projects/areas only.

// MARK: - Task

enum TaskStatus: String, Codable, Hashable {
  case open
  case done
  case cancelled
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
  /// Imported from Cultured Code Things.
  public static let things = "things"
}

/// Values stamped on a task row's `kind` field — what *shape* of row it is.
/// A heading is a `TaskEntity` (so it inherits sync/order/drag for free) that
/// renders as a section divider inside a project and NEVER appears in any
/// task feed, list, count, or badge (see `TaskEntity.isHeading` and the
/// exclusion filters). Absent/`""` = an ordinary task.
public enum TaskKind {
  /// An ordinary to-do. The default; stored as `""`/absent.
  public static let task = ""
  /// A section divider inside a project. Members point back via `heading`.
  public static let heading = "heading"
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
  /// Row shape (`TaskKind`). `""`/absent = task, `"heading"` = a project
  /// section divider. Rides alongside the entity, not the wire. Read `isHeading`.
  var kind: String = ""
  /// FK to the owning heading's id when this task is filed under one; else nil.
  /// Rides alongside the entity, not the wire.
  var heading: String? = nil

  /// True when this DTO is a project section divider, not a to-do — the mirror
  /// of `TaskEntity.isHeading`. Headings are excluded from every feed/count.
  var isHeading: Bool { kind == TaskKind.heading }

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

  /// True while this row arrived in Today *on its own* — its scheduled ("When")
  /// or deadline date is today and it was created on an earlier day, so it
  /// surfaced at the day rollover rather than being captured by hand today. A
  /// quiet "this landed this morning" cue (Things-style), distinct from the
  /// agent cue. Self-clearing with NO stored state: tomorrow the date no longer
  /// equals today, so it evaporates on its own — no field, no migration, no
  /// CloudKit deploy. Agent rows are excluded; they carry their own cue and the
  /// row never shows two dots.
  func showsArrivedToday() -> Bool {
    guard status == .open, source != TaskSource.mcp,
          let created, created < SeptenaDate.today else { return false }
    let today = SeptenaDate.today
    return scheduled == today || deadline == today
  }

  /// "Carry-age": how many whole days this open task has sat on the Today list
  /// without being completed — the *self-deferral* signal, deliberately
  /// distinct from `isOverdue` (which is the world's deadline pressure). The
  /// landing day is the earliest of the signals currently keeping it on Today —
  ///   • `todaySetOn` (an explicit pin's stamp), or
  ///   • `scheduled` once it has arrived (≤ today), or
  ///   • `deadline` once it has arrived (≤ today).
  /// Age = whole days from that landing day to today. `0` = arrived today
  /// (already carried by the amber checkbox / `showsArrivedToday`); a positive
  /// value means it survived that many day-rollovers undone. Derived, with NO
  /// stored state (mirrors `showsArrivedToday`): it resets the moment a task
  /// leaves Today and is re-committed, because re-committing is a fresh promise.
  /// Returns `0` when the task is done, off Today, an unratified agent row
  /// (it carries its own cue), or a legacy pin with no `todaySetOn` to date it.
  func daysOnToday(today: String = SeptenaDate.today) -> Int {
    guard status == .open, source != TaskSource.mcp, isOnToday else { return 0 }
    var landed: [String] = []
    if self.today, let t = todaySetOn { landed.append(t) }
    if let s = scheduled, s <= today { landed.append(s) }
    if let d = deadline, d <= today { landed.append(d) }
    guard let earliest = landed.min(),
          let from = SeptenaDate.parse(earliest),
          let to = SeptenaDate.parse(today) else { return 0 }
    let cal = Calendar.current
    let days = cal.dateComponents([.day],
                                  from: cal.startOfDay(for: from),
                                  to: cal.startOfDay(for: to)).day ?? 0
    return max(0, days)
  }

  /// Tenure strength (0…1) for the **Today checkbox fill** — the single temporal
  /// device that unifies what used to be two: the amber "arrived today" *box*
  /// (day 0) and the gold carry-age *ring* (day 1+). They were the same axis
  /// ("how long on Today") drawn in two positions/shapes; this folds them into
  /// one in-place treatment where only the box's *fill opacity* changes, never
  /// its shape. The arrival day is transparent (silent — a fresh task shouldn't
  /// shout); each carried-over day adds one seventh, deepening the gold until it
  /// tops out (the renderer caps the opacity at ~90% so it never reads as a
  /// solid/done box). Returns `nil` until the task has carried over at least once
  /// (`daysOnToday ≥ 1`); hand-added / pinned / just-arrived today all stay
  /// transparent. Derived, no stored state; self-clears when the task leaves
  /// Today or is completed.
  func todayTenureFill(today: String = SeptenaDate.today) -> Double? {
    guard status == .open, source != TaskSource.mcp, isOnToday else { return nil }
    let carried = daysOnToday(today: today)
    guard carried >= 1 else { return nil }
    return min(1, Double(carried) / 7.0)
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
    guard status == .open, !isHeading else { return false }
    if today { return true }
    if let s = scheduled, s <= SeptenaDate.today { return true }
    if let d = deadline, d <= SeptenaDate.today { return true }
    return false
  }

  /// Sort rank for Today-surface lists (Next ▸ Tasks Today, Tasks tab Today).
  /// Mirrors what the row trailing actually shows on Next — deadline drives
  /// the red Today / flag labels; past When dates are hidden there, so they
  /// must not sort as due-today. Groups: deadline today/overdue → tomorrow →
  /// later → visually undated (pins + rolled-in When with no deadline).
  func nextPageOrderRank(todayISO: String = SeptenaDate.today) -> (tier: Int, date: String) {
    let tomorrow = SeptenaDate.offsetDays(1, from: todayISO)

    if let d = deadline, d <= todayISO { return (0, d) }

    if let d = deadline, let tomorrow, d == tomorrow { return (1, d) }
    if deadline == nil, let s = scheduled, let tomorrow, s == tomorrow { return (1, s) }

    if let d = deadline, d > todayISO { return (2, d) }
    if deadline == nil, let s = scheduled, s > todayISO { return (2, s) }

    return (3, todaySetOn ?? created ?? todayISO)
  }

  /// Sort comparator for Today-surface task lists on Next and the Tasks tab.
  static func compareNextPageOrder(_ a: SeptenaTask, _ b: SeptenaTask) -> Bool {
    let ta = a.nextPageOrderRank()
    let tb = b.nextPageOrderRank()
    if ta.tier != tb.tier { return ta.tier < tb.tier }
    if ta.date != tb.date { return ta.date < tb.date }
    if a.position != b.position { return a.position < b.position }
    return a.id < b.id
  }

  /// Whether this open task sits in the **triage band** — the *unratified*
  /// layer that renders above Today (see `docs/TRIAGE_BAND_SPEC.md`). The
  /// divider is ratification, not date: two captured-but-not-committed
  /// populations belong here —
  ///   • an unacknowledged agent proposal still inside its freshness window
  ///     (`showsAgentCue`), regardless of any date/project it carries; and
  ///   • a loose human capture with no disposition at all (the classic Inbox).
  /// A row leaves the band the instant it is ratified (any disposition, or
  /// `acknowledge` for agent rows) — and for agent rows also when the cue
  /// decays (ratification-by-timeout, so a long-ignored proposal ages into
  /// its natural bucket rather than living in limbo). DTO mirror of
  /// `TaskEntity.isInTriageBand` — keep the two in lockstep.
  var isInTriageBand: Bool {
    guard status == .open, !isHeading else { return false }
    if source == TaskSource.mcp { return showsAgentCue() }
    return scheduled == nil && deadline == nil
        && project == nil && area == nil && !today
  }

  /// Native projection used by the SwiftData mirror. Keeping this typed avoids
  /// serializing every row through the retired HTTP payload shape merely to
  /// construct a value for the UI.
  init(
    id: String,
    title: String,
    status: TaskStatus,
    created: String?,
    scheduled: String?,
    deadline: String?,
    today: Bool,
    todaySetOn: String?,
    completedAt: String?,
    area: String?,
    project: String?,
    notes: String?,
    recurrence: Recurrence?,
    nextOccurrence: String? = nil,
    updatedAt: String?,
    deletedAt: String?,
    source: String? = nil,
    sourceClient: String? = nil,
    acknowledgedAt: Date? = nil,
    createdAt: Date = .distantPast,
    position: Double = 0,
    kind: String = "",
    heading: String? = nil,
    conversation: TaskConvo = TaskConvo()
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.created = created
    self.scheduled = scheduled
    self.deadline = deadline
    self.today = today
    self.todaySetOn = todaySetOn
    self.completedAt = completedAt
    self.area = area
    self.project = project
    self.notes = notes
    self.recurrence = recurrence
    self.nextOccurrence = nextOccurrence
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.source = source
    self.sourceClient = sourceClient
    self.acknowledgedAt = acknowledgedAt
    self.createdAt = createdAt
    self.position = position
    self.kind = kind
    self.heading = heading
    self.conversation = conversation
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
  /// The one read-only context feed (repo / calendar / feed). See
  /// [AreaAttachment.swift]. Carries the legacy `githubRepo` as a `.git`
  /// attachment via the entity-level read-fallback.
  var attachment: AreaAttachment?
  /// Sidebar sort order (synced, from `ProjectEntity.position`). Populated by
  /// the entity init only — intentionally NOT a `CodingKey`, so the MCP/wire
  /// JSON stays unchanged. See `docs/DRAG_AND_DROP.md` §5 gap #2.
  var position: Int
  var updatedAt: String?
  var deletedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, title, status, area, created, notes, context, attachment
    case completedAt = "completed_at"
    case githubRepo = "github_repo"
    case updatedAt = "updated_at"
    case deletedAt = "deleted_at"
  }

  init(id: String, title: String, status: ProjectStatus = .active,
       area: String? = nil, created: String? = nil, completedAt: String? = nil,
       notes: String? = nil, context: String? = nil, githubRepo: String? = nil,
       attachment: AreaAttachment? = nil, position: Int = 0,
       updatedAt: String? = nil, deletedAt: String? = nil) {
    self.id = id; self.title = title; self.status = status
    self.area = area; self.created = created; self.completedAt = completedAt
    self.notes = notes; self.context = context; self.githubRepo = githubRepo
    self.attachment = attachment; self.position = position
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
    attachment = try c.decodeIfPresent(AreaAttachment.self, forKey: .attachment)
    position = 0   // not on the wire; set via ProjectEntity init
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
  }
}

// MARK: - Area (Septena)

struct Area: Identifiable, Codable, Hashable {
  let id: String
  var title: String
  var context: String?
  /// Optional user-assigned glyph; nil ⇒ the area renders its filler dot.
  var emoji: String?
  /// The one read-only context feed (repo / calendar / feed). See
  /// [AreaAttachment.swift].
  var attachment: AreaAttachment?
  /// Sidebar sort order (synced, from `AreaEntity.position`). Populated by the
  /// entity init only — intentionally NOT a `CodingKey`, so the MCP/wire JSON
  /// stays unchanged. See `docs/DRAG_AND_DROP.md` §5 gap #2.
  var position: Int
  var updatedAt: String?
  // Removed areas tombstone per-record via CloudKit like tasks/projects; the
  // "wholesale-replace array" note here is FastAPI-era history. No `deletedAt`
  // field by design (delete-by-omission from the local mirror).

  init(id: String, title: String, context: String? = nil, emoji: String? = nil,
       attachment: AreaAttachment? = nil, position: Int = 0,
       updatedAt: String? = nil) {
    self.id = id; self.title = title; self.context = context; self.emoji = emoji
    self.attachment = attachment; self.position = position
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
    context = try c.decodeIfPresent(String.self, forKey: .context)
    emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
    attachment = try c.decodeIfPresent(AreaAttachment.self, forKey: .attachment)
    position = 0   // not on the wire; set via AreaEntity init
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
  }

  enum CodingKeys: String, CodingKey {
    case id, title, context, emoji, attachment
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
  /// Unratified "to sort" pile — the triage band's size (agent proposals +
  /// loose captures). Superset of `inboxCount`; see `docs/TRIAGE_BAND_SPEC.md`.
  var triageCount: Int
  var upcomingCount: Int
  var unscheduledCount: Int
  var openCount: Int

  enum CodingKeys: String, CodingKey {
    case today
    case todayCount = "today_count"
    case reviewCount = "review_count"
    case inboxCount = "inbox_count"
    case triageCount = "triage_count"
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
    triageCount = (try? c.decode(Int.self, forKey: .triageCount)) ?? 0
    upcomingCount = (try? c.decode(Int.self, forKey: .upcomingCount)) ?? 0
    unscheduledCount = (try? c.decode(Int.self, forKey: .unscheduledCount)) ?? 0
    openCount = (try? c.decode(Int.self, forKey: .openCount)) ?? 0
  }

  init(today: String, todayCount: Int, reviewCount: Int,
       inboxCount: Int, triageCount: Int = 0, upcomingCount: Int,
       unscheduledCount: Int, openCount: Int) {
    self.today = today
    self.todayCount = todayCount
    self.reviewCount = reviewCount
    self.inboxCount = inboxCount
    self.triageCount = triageCount
    self.upcomingCount = upcomingCount
    self.unscheduledCount = unscheduledCount
    self.openCount = openCount
  }
}

// MARK: - UI filter (maps to server `view` param + optional area/project scope)

enum TaskFilter: Equatable, Hashable {
  case today
  /// Unratified layer rendered above Today — agent proposals + loose human
  /// captures (see `SeptenaTask.isInTriageBand`, `docs/TRIAGE_BAND_SPEC.md`).
  /// This is the only home for loose captures; the standalone Inbox page was
  /// retired when the triage band absorbed it.
  case triage
  case upcoming
  case unscheduled
  case logbook
  case recentlyDeleted
  case project(String)
  case area(String)

  var serverView: String {
    switch self {
    case .today: return "today"
    case .triage: return "triage"
    case .upcoming: return "upcoming"
    case .unscheduled: return "unscheduled"
    case .logbook: return "logbook"
    case .recentlyDeleted: return "all"
    case .project, .area: return "all"
    }
  }

  // User-facing label. "Anytime" is the single home for open, dateless tasks
  // (it absorbed the former "Someday" bucket). The serverView key stays
  // `unscheduled` so the API contract is unchanged.
  var title: String {
    switch self {
    case .today: return String(localized: "Today", comment: "Task filter")
    case .triage: return String(localized: "Inbox", comment: "Task filter")
    case .upcoming: return String(localized: "Upcoming", comment: "Task filter")
    case .unscheduled: return String(localized: "Anytime", comment: "Task filter")
    case .logbook: return String(localized: "Logbook", comment: "Task filter")
    case .recentlyDeleted: return String(localized: "Recently Deleted", comment: "Task filter")
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
  var skipped: Bool
  var note: String?
  var time: String?

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
    emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
    bucket = try c.decodeIfPresent(String.self, forKey: .bucket)
    done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    skipped = (try? c.decode(Bool.self, forKey: .skipped)) ?? false
    note = try c.decodeIfPresent(String.self, forKey: .note)
    time = try c.decodeIfPresent(String.self, forKey: .time)
  }

  enum CodingKeys: String, CodingKey { case id, name, emoji, bucket, done, skipped, note, time }

  init(id: String,
       name: String,
       emoji: String?,
       bucket: String? = nil,
       done: Bool,
       skipped: Bool = false,
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
  /// Free-text note. Used as a per-session note (stored on the session's
  /// concluding entry), surfaced in the session view and practitioner reports.
  var note: String?

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
    note = try c.decodeIfPresent(String.self, forKey: .note)
  }

  private static func decodeIntOrString(_ c: KeyedDecodingContainer<CodingKeys>,
                                        key: CodingKeys) -> String? {
    if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
    return try? c.decodeIfPresent(String.self, forKey: key)
  }

  enum CodingKeys: String, CodingKey {
    case date, session, exercise, weight, sets, reps, difficulty, level, file, note
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
       loggedAt: String?,
       note: String? = nil) {
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
    self.note = note
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
  // Optionals default to nil so the memberwise init can be called with just the
  // fields a caller cares about (e.g. date + wakeTime). Decoding is unaffected —
  // synthesized Decodable already treats a missing key for an optional as nil.
  var sleepScore: Int? = nil
  var readinessScore: Int? = nil
  var totalH: Double? = nil
  var deepH: Double? = nil
  var remH: Double? = nil
  var lightH: Double? = nil
  var awakeH: Double? = nil
  var efficiency: Int? = nil
  var hrv: Int? = nil
  var restingHr: Int? = nil
  var bedtime: String? = nil
  var wakeTime: String? = nil
  var stressHighMin: Int? = nil
  var recoveryHighMin: Int? = nil
  var stressSummary: String? = nil   // "stressful" | "normal" | "restored" | "restorative"

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
/// Local macro-configuration payload shared by the nutrition surfaces.
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
  /// Whether the user tracks fasting (the Nutrition tile's live timer + the
  /// wrist macro-complication morph). Synced so every device agrees — the
  /// device-local `@AppStorage` mirror (`SettingsKey.nutritionTrackFasting`)
  /// used by display surfaces stays in lockstep. Nil for legacy payloads →
  /// consumers fall back to the local mirror (or `false`).
  var trackFasting: Bool?

  enum CodingKeys: String, CodingKey {
    case macroColors  = "macro_colors"
    case macroTiles   = "macro_tiles"
    case trackFasting = "track_fasting"
  }
}

struct AppSettings: Codable {
  /// INVARIANT — `sectionOrder` is ORDERING ONLY, never membership. Whether a
  /// section is active is `SectionEntity.isEnabled` (see
  /// `SeptenaServices.enabledSectionKeys()`); this array only ranks the active
  /// ones for display. A key absent from here is NOT hidden — rank it last and
  /// move on; an unknown key is ignored. Filtering membership through this
  /// array (`order.filter { enabled… }`) silently drops sections enabled after
  /// the order was last saved — the exact bug that hid `symptoms`/`medications`
  /// from MCP. Resolve order+membership via `SettingsMirror.loadSections`
  /// (ordered, complete) rather than re-deriving from this field.
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
  /// Cosmetic supporter state ("Support Septena" purchase), synced so the
  /// badge/foil follow the account into Septask — StoreKit entitlements are
  /// per-app, so the sibling can't read the purchase itself. Gates nothing,
  /// by product rule. Authoritative writer: the app hosting StoreKit
  /// (Septena); tasks-only shells adopt inbound values only.
  var supporter: Bool? = nil

  /// User-configured boundary hours for the morning/afternoon/evening day
  /// buckets (Settings ▸ Time of Day). Synced across devices; mirrored into
  /// the shared App Group suite that `DayBucket` reads. Nil → historical
  /// defaults (12 / 17). Defaulted so memberwise-init call sites stay stable.
  var morningCutoffHour: Int? = nil
  var afternoonCutoffHour: Int? = nil

  /// When the first-run welcome (section picker + chained onboarding) was
  /// completed. The durable, cross-device "this account has been welcomed"
  /// marker: synced so a returning user's *new* device never re-shows the
  /// welcome once their data syncs in. Mirrored into the device-local
  /// `SettingsKey.welcomeCompleted` @AppStorage key that the welcome gate
  /// reads for an instant, offline-safe decision. Nil → not yet onboarded.
  /// Defaulted so the existing memberwise-init call sites stay source-stable.
  var onboardedAt: Date? = nil

  /// Saved practitioner-report definitions, synced across the user's devices
  /// via the settings blob (no separate CloudKit record type). Defaulted so
  /// existing settings payloads decode cleanly. See [[project_practitioner_reports]].
  var reports: [ReportBundle]? = nil

  /// Next suggestion IDs dismissed by the user, keyed by ISO date string.
  /// Synced so a skip on one device propagates to others via union merge.
  /// Only today's key is live; past dates are pruned on write and ignored on read.
  var nextSkips: [String: [String]]? = nil

  /// Graded analytics privacy level (`TelemetryClient.TelemetryLevel` raw value:
  /// "none" | "minimal" | "balanced" | "full"). Synced so the user's privacy
  /// choice follows them across their own devices; also mirrored into the
  /// `septena.privacy.telemetryLevel` @AppStorage key that `TelemetryClient`
  /// reads synchronously to gate what it sends. Nil → not yet chosen (the
  /// device falls back to its local mirror / legacy flag / `.balanced` default).
  /// Defaulted so existing settings payloads decode cleanly. See [[project_versioning_changelog]].
  var telemetryLevel: String? = nil

  /// Calendars the user has hidden from the day timeline / Next feed, stored by
  /// `EKCalendar.title` (NOT `calendarIdentifier`, which EventKit assigns
  /// per-store and is not stable across devices — see [[project_tasks_calendar_events]]).
  /// Title-based matching is what makes "set it up once, applies everywhere"
  /// work: the same iCloud calendar resolves by name on every device. Synced so
  /// the selection follows the user; mirrored into `CalendarBridge`'s local
  /// UserDefaults cache (the offline-safe authority EventKit fetches filter on).
  /// Nil → nothing hidden yet. Defaulted so existing payloads decode cleanly.
  var calendarHiddenTitles: [String]? = nil

  enum CodingKeys: String, CodingKey {
    case sectionOrder = "section_order"
    case targets, units, time, theme, eink, nutrition
    case hkSync = "hk_sync"
    case welcomeName = "welcome_name"
    case morningCutoffHour = "morning_cutoff_hour"
    case afternoonCutoffHour = "afternoon_cutoff_hour"
    case onboardedAt = "onboarded_at"
    case reports
    case nextSkips = "next_skips"
    case telemetryLevel = "telemetry_level"
    case calendarHiddenTitles = "calendar_hidden_titles"
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

// MARK: - Add Info: config DTOs (training)

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
  /// Pinned to the top of the Week dashboard. Defaulted so existing decoders
  /// and call sites (and any cached JSON without the key) stay valid.
  var pinned: Bool = false
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

  /// Start of the calendar day for an ISO `yyyy-MM-dd` string in the current time zone.
  static func startOfDay(for today: String) -> Date? {
    parse(today).map { Calendar.current.startOfDay(for: $0) }
  }

  static func format(_ d: Date?) -> String? {
    guard let d else { return nil }
    return formatter.string(from: d)
  }

  /// The absolute wall-clock instant of an event from its stored `date`
  /// ("yyyy-MM-dd") and `time` ("HH:mm" or "HH:mm:ss") in the current calendar /
  /// time zone. Used to anchor the fasting window for the watch, which then
  /// reasons about elapsed time from this instant. Nil if either part is malformed.
  static func instant(date: String, time: String) -> Date? {
    let d = date.split(separator: "-").compactMap { Int($0) }
    let t = time.split(separator: ":").compactMap { Int($0) }
    guard d.count == 3, t.count >= 2 else { return nil }
    var c = DateComponents()
    c.year = d[0]; c.month = d[1]; c.day = d[2]
    c.hour = t[0]; c.minute = t[1]; c.second = t.count >= 3 ? t[2] : 0
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    return cal.date(from: c)
  }

  static var today: String { formatter.string(from: Date()) }

  /// ISO date `n` calendar days after `iso` (negative = before).
  static func offsetDays(_ n: Int, from iso: String) -> String? {
    guard let d = parse(iso),
          let shifted = Calendar.current.date(byAdding: .day, value: n, to: d) else { return nil }
    return format(shifted)
  }

  /// Wall-clock "HH:mm" right now.
  static var nowHHMM: String { timeFormatter.string(from: Date()) }

  /// Wall-clock "HH:mm:ss" right now. Used where sub-minute ordering matters
  /// (e.g. several events logged in the same minute) and to match the hosted
  /// gateway, which defaults event times to second precision.
  static var nowHHMMSS: String { secondsTimeFormatter.string(from: Date()) }

  /// Human label for a future scheduled day — "Today", "Tomorrow", weekday
  /// within the next week, else a short date. Used by task defer toasts and
  /// upcoming group headers.
  static func scheduleHeaderLabel(for date: Date) -> String {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let target = cal.startOfDay(for: date)
    let days = cal.dateComponents([.day], from: today, to: target).day ?? 0
    if days == 0 { return String(localized: "Today", comment: "Relative date") }
    if days == 1 { return String(localized: "Tomorrow", comment: "Relative date") }
    let df = DateFormatter()
    df.locale = .current
    df.dateFormat = (days < 7) ? "EEEE" : "EEE, MMM d"
    return df.string(from: date)
  }

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
/// The 16-group muscle taxonomy. `rawValue` is permanent — stored in CloudKit
/// (free-string field) and emitted in the MCP `primaryMuscle`/`secondaryMuscles`
/// enums. `allCases` order is anatomical (push → pull → legs → core) and drives
/// the grouped exercise picker and the per-muscle "sets this week" card.
/// See docs/MUSCLE_TAXONOMY_16.md.
enum Muscle: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
  // Push
  case chest, frontDelts, sideDelts, rearDelts, triceps
  // Pull
  case lats, upperBack, biceps, forearms
  // Legs
  case quads, hamstrings, glutes, calves, adductors
  // Core
  case abs, lowerBack

  var id: String { rawValue }

  var label: String {
    switch self {
    case .chest:      return String(localized: "Chest", comment: "Muscle group")
    case .frontDelts: return String(localized: "Front Delts", comment: "Muscle group")
    case .sideDelts:  return String(localized: "Side Delts", comment: "Muscle group")
    case .rearDelts:  return String(localized: "Rear Delts", comment: "Muscle group")
    case .triceps:    return String(localized: "Triceps", comment: "Muscle group")
    case .lats:       return String(localized: "Lats", comment: "Muscle group")
    case .upperBack:  return String(localized: "Upper Back", comment: "Muscle group")
    case .biceps:     return String(localized: "Biceps", comment: "Muscle group")
    case .forearms:   return String(localized: "Forearms", comment: "Muscle group")
    case .quads:      return String(localized: "Quads", comment: "Muscle group")
    case .hamstrings: return String(localized: "Hamstrings", comment: "Muscle group")
    case .glutes:     return String(localized: "Glutes", comment: "Muscle group")
    case .calves:     return String(localized: "Calves", comment: "Muscle group")
    case .adductors:  return String(localized: "Adductors", comment: "Muscle group")
    case .abs:        return String(localized: "Abs", comment: "Muscle group")
    case .lowerBack:  return String(localized: "Lower Back", comment: "Muscle group")
    }
  }

  /// Nil-safe lookup of a stored string into a `Muscle` (empty → nil). No
  /// legacy coarse-10 fallback: existing data is migrated to the 16-group raw
  /// values directly (per-exercise backfill), so stored values are always
  /// current. See docs/MUSCLE_TAXONOMY_16.md.
  static func resolve(_ raw: String?) -> Muscle? {
    guard let raw, !raw.isEmpty else { return nil }
    return Muscle(rawValue: raw)
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
  /// Exercise slugs in the order they were first marked done — drives the
  /// active-session list so the first completed set stays at the top even
  /// when the user works out of routine order or moves slots.
  var doneOrder: [String] = []

  /// Index of the next pending entry, or nil if everything's done/skipped.
  var nextPendingIndex: Int? {
    entries.firstIndex { $0.status == .pending }
  }

  var doneCount: Int { entries.filter { $0.status == .done }.count }
  var totalCount: Int { entries.filter { $0.status != .skipped }.count }

  /// Session-level category, derived from its entries' per-exercise flags
  /// (set by `backfillDraftFromHistory` from the routine kind + each
  /// exercise's definition). Drives the glyph the tab-bar accessory and
  /// the Live Activity both show, so the icon reflects *this* workout —
  /// run for cardio, yoga for mobility — instead of a generic dumbbell.
  /// Falls back to the id-based default for an empty/ambiguous draft.
  var sessionKind: SessionKind {
    let active = entries.filter { $0.status != .skipped }
    guard !active.isEmpty else { return .defaulted(for: sessionType) }
    if active.allSatisfy({ $0.isMobility }) { return .mobility }
    if active.allSatisfy({ $0.isCardio })   { return .cardio }
    let anyCardio   = active.contains { $0.isCardio }
    let anyStrength = active.contains { !$0.isCardio && !$0.isMobility }
    return (anyCardio && anyStrength) ? .mixed : .strength
  }

  /// Record the first completion of `exercise` for active-list ordering.
  mutating func noteExerciseCompleted(_ exercise: String) {
    guard !doneOrder.contains(exercise) else { return }
    doneOrder.append(exercise)
  }

  /// Entries ordered for the active-session logger: finished sets at the top
  /// in completion order (first logged first), pending/skipped below in
  /// routine order.
  var entriesForActiveList: [DraftEntry] {
    func settled(_ s: DraftEntry.Status) -> Bool { s == .done || s == .saving }
    let completionRank = Dictionary(
      uniqueKeysWithValues: doneOrder.enumerated().map { ($0.element, $0.offset) })
    return entries.enumerated().sorted { a, b in
      let sa = settled(a.element.status), sb = settled(b.element.status)
      if sa != sb { return sa }
      if sa {
        let ra = completionRank[a.element.exercise] ?? Int.max
        let rb = completionRank[b.element.exercise] ?? Int.max
        if ra != rb { return ra < rb }
      }
      return a.offset < b.offset
    }.map(\.element)
  }
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

/// One logged check-in. Mirrors the intake event shape so the
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
