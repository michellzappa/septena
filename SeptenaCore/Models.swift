import Foundation
import os

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

/// Values stamped on a task's `dropReason` alongside status `cancelled`
/// (`docs/TASK_FADE_SPEC.md` §3, §5).
public enum TaskDropReason {
  /// Dropped by the weekly sweep after fading.
  public static let faded = "faded"
  /// Dropped manually by the user.
  public static let user = "user"
}

/// Tunables for the "agent created this" freshness cue. Provenance is
/// permanent; the cue is transient and decays so a long-ignored agent row
/// stops glowing even if never explicitly acknowledged.
public enum AgentCue {
  /// How long after `createdAt` an unacknowledged agent row keeps glowing.
  public static let decayWindow: TimeInterval = TimeInterval(RegistryRules.cueDecayDays) * 24 * 60 * 60
}

struct SeptenaTask: Identifiable, Codable, Hashable {
  let id: String
  var title: String
  var status: TaskStatus
  var created: String?         // YYYY-MM-DD
  var scheduled: String?       // YYYY-MM-DD
  /// Optional 24-hour wall-clock start time (`HH:MM`, docs/TASK_TIMES_AND_ICAL_SPEC.md).
  var startTime: String? = nil
  /// Optional duration in minutes (`5..1440`).
  var durationMinutes: Int? = nil
  /// Optional IANA time zone (nil = floating local time).
  var timeZone: String? = nil

  /// Quiet human-readable time range (`14:00–15:00` or `14:00`), nil when date-only.
  var timeSlotLabel: String? {
    TaskTimeSlot.format(startTime: startTime, durationMinutes: durationMinutes)
  }
  /// Hard date the task is owed by. Things-style: rendering only — the
  /// server unions deadline-today rows into Today.items at view time, no
  /// mutation. Reschedule the deadline forward and the task drops out of
  /// Today on the next view load. The previous `due` field was the same
  /// data but with auto-pinning behavior baked in; the server still emits
  /// `due` as a mirror for the transition window, so we read either.
  var deadline: String?
  var today: Bool
  var starred: Bool = false
  /// Canonical `TagEntity.id` values assigned to this task (max 20, flat tags, docs/TAGS_SPEC.md).
  var tags: [String] = []
  var todaySetOn: String?      // YYYY-MM-DD
  var completedAt: String?     // YYYY-MM-DDTHH:MM:SS
  var area: String?
  var project: String?
  var notes: String?
  var recurrence: Recurrence?
  /// True when the repeat rule is retained but temporarily stops generating
  /// future copies. This is local task state, not part of the HTTP recurrence
  /// payload, so old server responses continue to decode as false.
  var recurrencePaused: Bool = false
  var reminder: TaskReminder? = nil
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
  /// Today's own manual order (see `TaskEntity.todayPosition`). Rides
  /// alongside the entity, not the wire. nil = never ordered on Today.
  var todayPosition: Double? = nil
  /// Task fade fields (see `TaskEntity.touchedAt`). Ride alongside the
  /// entity, not the wire.
  var touchedAt: Date? = nil
  var deferCount: Int = 0
  var fadedAt: Date? = nil
  var dropReason: String? = nil
  var effort: String? = nil
  /// Row shape (`TaskKind`). `""`/absent = task, `"heading"` = a project
  /// section divider. Rides alongside the entity, not the wire. Read `isHeading`.
  var kind: String = ""
  /// FK to the owning heading's id when this task is filed under one; else nil.
  /// Rides alongside the entity, not the wire.
  var heading: String? = nil

  /// True when this DTO is a project section divider, not a to-do — the mirror
  /// of `TaskEntity.isHeading`. Headings are excluded from every feed/count.
  var isHeading: Bool { kind == TaskKind.heading }

  /// True when this open task has faded into the Faded pile
  /// (`docs/TASK_FADE_SPEC.md` §4). Faded tasks leave every other list, every
  /// count, Next, and the badge.
  var isFaded: Bool { status == .open && fadedAt != nil }

  /// Countdown progress (0…1) toward the 14-day fade window (`TaskFade.fadeFill`).
  /// Drives whole-row opacity in every open task list.
  func fadeFill(today: String = SeptenaDate.today, now: Date = Date()) -> Double? {
    TaskFade.fadeFill(
      isOpen: status == .open,
      isHeading: isHeading,
      isDeleted: deletedAt != nil,
      isFaded: isFaded,
      deadline: deadline,
      scheduled: scheduled,
      hasRecurrence: recurrence != nil,
      isAgentTurn: deriveConvo(conversation).badge == .working,
      isAssignedToClaude: conversation.assignee == .claude,
      isAwaitingHuman: conversation.awaitsHuman,
      showsAgentCue: showsAgentCue(now: now),
      touchedAt: touchedAt,
      createdAt: createdAt,
      created: created,
      now: now,
      today: today
    )
  }

  /// The task's conversation (Task Conversations), decoded from the entity in
  /// `init(_:)`. Rides alongside, not the wire (excluded from CodingKeys), so the
  /// row badge and the editor card read it from the already-loaded task —
  /// NO second fetch-by-id per row. `TaskConvo()` (empty) for tasks without one.
  var conversation: TaskConvo = TaskConvo()

  /// True when an agent added this task over MCP. Permanent: unlike
  /// `showsAgentCue()` it never clears, so the row glyph and the task page's
  /// "Added by" line (`taskPage.provenance`) always say who added the task.
  var isAgentAuthored: Bool { source == TaskSource.mcp }

  /// Who added the task, as the task page and the row's accessibility label
  /// name it: the agent's connector name (`sourceClient`, which the backend
  /// stamps from the connection), or the registry's "You" for every task a
  /// person added (app, watch, share, import, legacy rows with no source).
  var addedByName: String {
    guard isAgentAuthored else { return RegistrySurfaces.provenanceSelfLabel }
    let name = sourceClient?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? RegistrySurfaces.provenanceAgentFallbackName : name
  }

  /// When the task was added: the creation instant, else its creation day for
  /// rows that predate `createdAt`. nil when neither is known.
  var addedOn: Date? {
    if createdAt != .distantPast { return createdAt }
    return SeptenaDate.parse(created)
  }

  /// The task page's provenance value: "Claude · 24 Nov 2026 at 09:03", or
  /// the name alone when the date is unknown. Same words on every shell.
  var addedByDetail: String {
    guard let on = addedOn else { return addedByName }
    return "\(addedByName) · \(on.formatted(date: .abbreviated, time: .shortened))"
  }

  /// "Added by Claude" / "Added by You": the provenance label and the name,
  /// for the row glyph's accessibility label and tooltip.
  var addedByPhrase: String {
    let label = RegistrySurfaces.taskPageBlocks.first { $0.id == Self.provenanceBlockID }?.label ?? ""
    return "\(label) \(addedByName)"
  }

  /// The task page block that owns the provenance copy (`surfaces.json`).
  private static let provenanceBlockID = "taskPage.provenance"

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
  /// row never shows two dots. A pinned row was placed by hand, so it never
  /// counts.
  ///
  /// `docs/TASK_DATES_SPEC.md` R8 (decision Q7): this is the ONE "arrived on
  /// its own" rule. The row dot and the rolled-into-Today notice both read it.
  func showsArrivedToday() -> Bool {
    guard status == .open, !isHeading, fadedAt == nil, deletedAt == nil, !today,
          source != TaskSource.mcp,
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
  /// Floor: a task cannot have sat on Today before it existed (`created`).
  /// Without that, a duplicate (or any new capture that inherited a past When
  /// / deadline) would pick up the source's gold tenure fill on day zero.
  /// Age = whole days from that landing day to today. `0` = arrived today
  /// (already carried by the amber checkbox / `showsArrivedToday`); a positive
  /// value means it survived that many day-rollovers undone. Derived, with NO
  /// stored state (mirrors `showsArrivedToday`): it resets the moment a task
  /// leaves Today and is re-committed, because re-committing is a fresh promise.
  /// Returns `0` when the task is done, off Today, an unratified agent row
  /// (it carries its own cue), or a legacy pin with no `todaySetOn` to date it.
  func daysOnToday(today: String = SeptenaDate.today) -> Int {
    guard status == .open, !showsAgentCue(), isOnToday else { return 0 }
    var landed: [String] = []
    if self.today, let t = todaySetOn { landed.append(t) }
    if let s = scheduled, s <= today { landed.append(s) }
    if let d = deadline, d <= today { landed.append(d) }
    guard var earliest = landed.min() else { return 0 }
    if let created, created > earliest { earliest = created }
    guard let from = SeptenaDate.parse(earliest),
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
  /// tops out (the renderer caps the opacity at ~70% so it never reads as a
  /// solid/done box). Returns `nil` until the task has carried over at least once
  /// (`daysOnToday ≥ 1`); hand-added / pinned / just-arrived today all stay
  /// transparent. Derived, no stored state; self-clears when the task leaves
  /// Today or is completed.
  func todayTenureFill(today: String = SeptenaDate.today) -> Double? {
    guard status == .open, !showsAgentCue(), isOnToday else { return nil }
    let carried = daysOnToday(today: today)
    guard carried >= 1 else { return nil }
    return min(1, Double(carried) / 7.0)
  }

  /// Canonical "overdue" test — Things-style: ONLY a hard `deadline` can make
  /// a task overdue. A scheduled ("When") date in the past is just a plan that
  /// rolled into Today; it never turns red. A deadline of *today or earlier*
  /// counts as overdue (red + badged). Shared by row styling and the
  /// badge/sidebar count so they never drift.
  ///
  /// `docs/TASK_DATES_SPEC.md` R3 / R4 (decision Q4): a deadline of today is
  /// `dueToday` (red, labelled "Today"), an earlier one is `overdue` (red,
  /// labelled "Overdue"). Both render red, so `isOverdue` means "red".
  var isOverdue: Bool {
    switch deadlineState() {
    case .dueToday, .overdue: return true
    case .none, .later: return false
    }
  }

  /// R3: the one due-state rule. Only an active task (open, not a heading,
  /// not deleted, not faded) has one. Every row, badge, widget and watch
  /// label reads this instead of comparing dates itself.
  func deadlineState(today: String = SeptenaDate.today) -> DeadlineState {
    guard status == .open, !isHeading, deletedAt == nil, fadedAt == nil,
          let d = deadline.map({ String($0.prefix(10)) }), !d.isEmpty else { return .none }
    if d < today { return .overdue }
    if d == today { return .dueToday }
    return .later
  }

  /// Whether this open task is on the Today list — the DTO mirror of
  /// `TaskEntity.isOnToday`. Today is a union of three signals: an explicit
  /// `today` pin, a scheduled ("When") date that has arrived, or a deadline
  /// that has arrived. UI surfaces (the Today toggle, indicators) must read
  /// this rather than the raw `today` flag, or a scheduled-today task looks
  /// like it isn't in Today. Keep in lockstep with `TaskEntity.isOnToday`.
  var isOnToday: Bool {
    guard status == .open, !isHeading, fadedAt == nil else { return false }
    if today { return true }
    if let s = scheduled, s <= SeptenaDate.today { return true }
    if let d = deadline, d <= SeptenaDate.today { return true }
    return false
  }

  /// `docs/TASK_DATES_SPEC.md` R5: open, not on Today, and a When date or
  /// deadline after today. A task is never on Today and in Upcoming at once
  /// (decision Q3). Every Upcoming list and count reads this.
  var isUpcoming: Bool {
    guard status == .open, !isHeading, fadedAt == nil, !isOnToday else { return false }
    let today = SeptenaDate.today
    return (scheduled.map { $0 > today } ?? false) || (deadline.map { $0 > today } ?? false)
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

  /// Filed nowhere: no area and no project. Filing state only, any status.
  /// See `TaskInbox`.
  var isUnfiled: Bool { TaskInbox.isUnfiled(area: area, project: project) }

  /// Inbox member — see `TaskInbox.contains`. DTO mirror of
  /// `TaskEntity.isInInbox`.
  var isInInbox: Bool {
    TaskInbox.contains(status: status, isHeading: isHeading, isDeleted: deletedAt != nil,
                       isFaded: isFaded, area: area, project: project)
  }

  /// Whether this task sits in the **triage band**: the Inbox members not yet
  /// ratified (see `TaskInbox.isUnratified`, `docs/TRIAGE_BAND_SPEC.md`).
  /// DTO mirror of `TaskEntity.isInTriageBand`.
  var isInTriageBand: Bool {
    isInInbox && TaskInbox.isUnratified(source: source, createdAt: createdAt,
                                        acknowledgedAt: acknowledgedAt, today: today,
                                        scheduled: scheduled, deadline: deadline)
  }

  /// The row the Today page draws in its Inbox section — see
  /// `TaskInbox.showsInTodayInbox`.
  var isInTodayInbox: Bool {
    TaskInbox.showsInTodayInbox(isInInbox: isInInbox, isInTriageBand: isInTriageBand,
                                isOnToday: isOnToday)
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
    startTime: String? = nil,
    durationMinutes: Int? = nil,
    timeZone: String? = nil,
    deadline: String?,
    today: Bool,
    starred: Bool = false,
    tags: [String] = [],
    todaySetOn: String?,
    completedAt: String?,
    area: String?,
    project: String?,
    notes: String?,
    recurrence: Recurrence?,
    recurrencePaused: Bool = false,
    reminder: TaskReminder? = nil,
    nextOccurrence: String? = nil,
    updatedAt: String?,
    deletedAt: String?,
    source: String? = nil,
    sourceClient: String? = nil,
    acknowledgedAt: Date? = nil,
    createdAt: Date = .distantPast,
    position: Double = 0,
    todayPosition: Double? = nil,
    touchedAt: Date? = nil,
    deferCount: Int = 0,
    fadedAt: Date? = nil,
    dropReason: String? = nil,
    effort: String? = nil,
    kind: String = "",
    heading: String? = nil,
    conversation: TaskConvo = TaskConvo()
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.created = created
    self.scheduled = scheduled
    self.startTime = startTime
    self.durationMinutes = durationMinutes
    self.timeZone = timeZone
    self.deadline = deadline
    self.today = today
    self.starred = starred
    self.tags = tags
    self.todaySetOn = todaySetOn
    self.completedAt = completedAt
    self.area = area
    self.project = project
    self.notes = notes
    self.recurrence = recurrence
    self.recurrencePaused = recurrencePaused
    self.reminder = reminder
    self.nextOccurrence = nextOccurrence
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.source = source
    self.sourceClient = sourceClient
    self.acknowledgedAt = acknowledgedAt
    self.createdAt = createdAt
    self.position = position
    self.todayPosition = todayPosition
    self.touchedAt = touchedAt
    self.deferCount = deferCount
    self.fadedAt = fadedAt
    self.dropReason = dropReason
    self.effort = effort
    self.kind = kind
    self.heading = heading
    self.conversation = conversation
  }

  enum CodingKeys: String, CodingKey {
    case id, title, status, created, scheduled, startTime, durationMinutes, timeZone, deadline, today, starred, tags
    case todaySetOn = "today_set_on"
    case completedAt = "completed_at"
    case area, project, notes, recurrence, reminder
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
    startTime = try c.decodeIfPresent(String.self, forKey: .startTime)
    durationMinutes = try c.decodeIfPresent(Int.self, forKey: .durationMinutes)
    timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
    // Prefer the canonical `deadline`; fall back to legacy `due` for old
    // payloads (cached responses, old server builds).
    if let dl = try c.decodeIfPresent(String.self, forKey: .deadline) {
      deadline = dl
    } else {
      let legacy = try decoder.container(keyedBy: LegacyKeys.self)
      deadline = try legacy.decodeIfPresent(String.self, forKey: .due)
    }
    today = (try? c.decode(Bool.self, forKey: .today)) ?? false
    starred = (try? c.decode(Bool.self, forKey: .starred)) ?? false
    tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
    todaySetOn = try c.decodeIfPresent(String.self, forKey: .todaySetOn)
    completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
    area = try c.decodeIfPresent(String.self, forKey: .area)
    project = try c.decodeIfPresent(String.self, forKey: .project)
    notes = try c.decodeIfPresent(String.self, forKey: .notes)
    recurrence = try c.decodeIfPresent(Recurrence.self, forKey: .recurrence)
    reminder = try c.decodeIfPresent(TaskReminder.self, forKey: .reminder)
    nextOccurrence = try c.decodeIfPresent(String.self, forKey: .nextOccurrence)
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
  }
}

// MARK: - Optional task start/end time helper (docs/TASK_TIMES_AND_ICAL_SPEC.md)

enum TaskTimeSlot {
  /// Quick duration presets shown behind progressive disclosure.
  static let quickDurations: [(minutes: Int, label: String)] = [
    (15, "15m"),
    (30, "30m"),
    (60, "1h"),
    (120, "2h"),
  ]

  /// Parse `"HH:MM"` into `(hour, minute)`.
  static func parse(_ hhmm: String?) -> (hour: Int, minute: Int)? {
    guard let hhmm, hhmm.count == 5 else { return nil }
    let parts = hhmm.split(separator: ":")
    guard parts.count == 2,
          let h = Int(parts[0]), let m = Int(parts[1]),
          (0...23).contains(h), (0...59).contains(m) else { return nil }
    return (h, m)
  }

  /// Format `(hour, minute)` into canonical 24-hour `"HH:MM"`.
  static func hhmm(hour: Int, minute: Int) -> String {
    String(format: "%02d:%02d", max(0, min(23, hour)), max(0, min(59, minute)))
  }

  /// Format `Date`'s local wall-clock hour/minute into `"HH:MM"`.
  static func hhmm(from date: Date, calendar: Calendar = .current) -> String {
    let comps = calendar.dateComponents([.hour, .minute], from: date)
    return hhmm(hour: comps.hour ?? 9, minute: comps.minute ?? 0)
  }

  /// Convert `"HH:MM"` to a `Date` on today's calendar day for date pickers.
  static func pickerDate(from hhmm: String?, calendar: Calendar = .current) -> Date {
    let parsed = parse(hhmm) ?? (9, 0)
    var comps = calendar.dateComponents([.year, .month, .day], from: Date())
    comps.hour = parsed.hour
    comps.minute = parsed.minute
    comps.second = 0
    return calendar.date(from: comps) ?? Date()
  }

  /// Format quiet display range (`"14:00–15:00"` when duration present, else `"14:00"`).
  static func format(startTime: String?, durationMinutes: Int?) -> String? {
    guard let (h, m) = parse(startTime) else { return nil }
    let start = hhmm(hour: h, minute: m)
    guard let dur = durationMinutes, dur >= 5 else { return start }
    let total = (h * 60 + m + dur) % (24 * 60)
    let end = hhmm(hour: total / 60, minute: total % 60)
    return "\(start)–\(end)"
  }
}

// MARK: - Flat tags (docs/TAGS_SPEC.md)

struct TaskTag: Identifiable, Codable, Hashable, Sendable {
  let id: String
  var name: String
  var color: String?
  var position: Int?

  init(id: String, name: String, color: String? = nil, position: Int? = nil) {
    self.id = id
    self.name = name
    self.color = color
    self.position = position
  }
}

// MARK: - Checklist item (1-level subtask, docs/CHECKLISTS_SPEC.md)

struct ChecklistItem: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let taskId: String
  var title: String
  var checked: Bool
  var checkedAt: String?
  var position: Double
  var createdAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case taskId = "task_id"
    case title, checked
    case checkedAt = "checked_at"
    case position
    case createdAt = "created_at"
  }

  init(id: String,
       taskId: String,
       title: String,
       checked: Bool = false,
       checkedAt: String? = nil,
       position: Double = 0,
       createdAt: String? = nil) {
    self.id = id
    self.taskId = taskId
    self.title = title
    self.checked = checked
    self.checkedAt = checkedAt
    self.position = position
    self.createdAt = createdAt
  }

  /// Deterministic ID for a checklist item copied onto a spawned recurring
  /// occurrence: FNV-1a 64 over `"<newTaskID>|chk|<index>|<sourceItemID>"`
  /// (`chk-` + 16 hex), LOCKSTEP with `backend/src/recurrence.ts` `checklistOccurrenceID`.
  static func occurrenceItemID(newTaskID: String, index: Int, sourceItemID: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in "\(newTaskID)|chk|\(index)|\(sourceItemID)".utf8 {
      hash ^= UInt64(byte)
      hash &*= 1099511628211
    }
    return "chk-\(String(format: "%016llx", hash))"
  }
}

// MARK: - Recurrence

/// A recurring task spawns a new instance when completed. `afterCompletion`
/// = true advances from today (e.g. "every 3 days after completion");
/// false advances from the prior scheduled date (e.g. "every Friday").
struct Recurrence: Codable, Hashable {
  enum Unit: String, Codable, Hashable { case day, week, month, year }
  var unit: Unit
  var interval: Int        // 1+
  var afterCompletion: Bool
  /// Optional specific weekdays (1 = Sun ... 7 = Sat) for fixed weekly rules.
  var weekdays: [Int]?
  /// Optional day of month (1..31, or -1 for last day) for fixed monthly/yearly rules.
  var monthDay: Int?
  /// Optional ordinal weekday (e.g. last Friday) for fixed monthly/yearly rules.
  var ordinalWeekday: RecurrenceOrdinalWeekday?

  enum CodingKeys: String, CodingKey {
    case unit, interval, weekdays
    case afterCompletion = "after_completion"
    case monthDay = "month_day"
    case ordinalWeekday = "ordinal_weekday"
  }

  init(unit: Unit,
       interval: Int = 1,
       afterCompletion: Bool = true,
       weekdays: [Int]? = nil,
       monthDay: Int? = nil,
       ordinalWeekday: RecurrenceOrdinalWeekday? = nil) {
    self.unit = unit
    self.interval = max(1, interval)
    self.afterCompletion = afterCompletion
    if !afterCompletion && unit == .week, let w = weekdays {
      let clean = Array(Set(w.filter { (1...7).contains($0) })).sorted()
      self.weekdays = clean.isEmpty ? nil : clean
    } else {
      self.weekdays = nil
    }
    if !afterCompletion && (unit == .month || unit == .year) {
      if let ow = ordinalWeekday,
         (1...7).contains(ow.weekday),
         ow.ordinal == -1 || (1...4).contains(ow.ordinal) {
        self.ordinalWeekday = ow
        self.monthDay = nil
      } else if let md = monthDay, md == -1 || (1...31).contains(md) {
        self.monthDay = md
        self.ordinalWeekday = nil
      } else {
        self.monthDay = nil
        self.ordinalWeekday = nil
      }
    } else {
      self.monthDay = nil
      self.ordinalWeekday = nil
    }
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let unit = try c.decode(Unit.self, forKey: .unit)
    let interval = max(1, (try? c.decode(Int.self, forKey: .interval)) ?? 1)
    let afterCompletion = (try? c.decode(Bool.self, forKey: .afterCompletion)) ?? true
    let weekdays = try? c.decodeIfPresent([Int].self, forKey: .weekdays)
    let monthDay = try? c.decodeIfPresent(Int.self, forKey: .monthDay)
    let ordinalWeekday = try? c.decodeIfPresent(RecurrenceOrdinalWeekday.self, forKey: .ordinalWeekday)
    self.init(unit: unit,
              interval: interval,
              afterCompletion: afterCompletion,
              weekdays: weekdays,
              monthDay: monthDay,
              ordinalWeekday: ordinalWeekday)
  }

  /// Short human-readable summary for the pill label ("Daily", "Weekdays", "Last Friday", "Yearly").
  var shortLabel: String {
    if !afterCompletion && unit == .week, let w = weekdays, !w.isEmpty {
      let set = Set(w)
      if interval == 1 {
        if set == Set([2, 3, 4, 5, 6]) { return String(localized: "Weekdays", comment: "Recurrence cadence") }
        if set == Set([1, 7]) { return String(localized: "Weekends", comment: "Recurrence cadence") }
      }
      let shortNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
      let isoOrder = w.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
      let joined = isoOrder.map { shortNames[$0] }.joined(separator: ", ")
      return interval == 1 ? joined : "Every \(interval) wks (\(joined))"
    }
    if !afterCompletion && unit == .month {
      if let ow = ordinalWeekday {
        let ord = Self.ordinalName(ow.ordinal)
        let day = Self.weekdayName(ow.weekday)
        return interval == 1 ? "\(ord) \(day)" : "Every \(interval) mos (\(ord) \(day))"
      }
      if monthDay == -1 {
        return interval == 1
          ? String(localized: "Last day of month", comment: "Recurrence cadence")
          : "Every \(interval) mos (last day)"
      }
    }
    if interval == 1 {
      switch unit {
      case .day: return String(localized: "Daily", comment: "Recurrence cadence")
      case .week: return String(localized: "Weekly", comment: "Recurrence cadence")
      case .month: return String(localized: "Monthly", comment: "Recurrence cadence")
      case .year: return String(localized: "Yearly", comment: "Recurrence cadence")
      }
    }
    return "Every \(interval) \(unit.rawValue)s"
  }

  private static func ordinalName(_ ordinal: Int) -> String {
    switch ordinal {
    case 1: return "1st"
    case 2: return "2nd"
    case 3: return "3rd"
    case 4: return "4th"
    default: return "Last"
    }
  }

  private static func weekdayName(_ weekday: Int) -> String {
    let names = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    return (1...7).contains(weekday) ? names[weekday] : "Day"
  }

  /// Calculates the scheduled date for the next occurrence.
  func nextDate(completedOn: String, scheduled: String?) -> String? {
    nextDate(completedOn: completedOn, scheduled: scheduled, logicalScheduled: nil)
  }

  /// Calculates the next occurrence using the series' logical slot rather
  /// than necessarily the date currently shown on the task.
  func nextDate(completedOn: String,
                scheduled: String?,
                logicalScheduled: String?) -> String? {
    RecurrenceDateCalculator.nextDate(
      completedOn: completedOn,
      scheduled: scheduled,
      logicalScheduled: logicalScheduled,
      unit: unit.rawValue,
      interval: interval,
      afterCompletion: afterCompletion,
      weekdays: weekdays,
      monthDay: monthDay,
      ordinalWeekday: ordinalWeekday
    )
  }

  /// Stable record identity for an occurrence generated from a task/date
  /// pair. Keeping this deterministic makes completion idempotent across the
  /// phone, watch, and MCP paths.
  static func occurrenceID(sourceTaskID: String, scheduled: String) -> String {
    RecurrenceDateCalculator.occurrenceID(sourceTaskID: sourceTaskID, scheduled: scheduled)
  }
}

/// How a fixed-schedule repeating task responds when its visible date moves.
/// Completion-based repeats never need this choice; their next date is always
/// anchored to the completion date.
/// A task's deadline relative to today (`docs/TASK_DATES_SPEC.md` R3).
enum DeadlineState: Equatable {
  case none, later, dueToday, overdue
}

enum RecurrenceRescheduleMode: Hashable {
  /// Move only this occurrence. The series keeps its prior logical slot.
  case makeException
  /// Move this occurrence and rebase future occurrences from the new date.
  case updateRule
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
  /// Sidebar sort order (synced, from `ProjectEntity.position`). Populated by
  /// the entity init only — intentionally NOT a `CodingKey`, so the MCP/wire
  /// JSON stays unchanged. See `docs/DRAG_AND_DROP.md` §5 gap #2.
  var position: Int
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
       position: Int = 0,
       updatedAt: String? = nil, deletedAt: String? = nil) {
    self.id = id; self.title = title; self.status = status
    self.area = area; self.created = created; self.completedAt = completedAt
    self.notes = notes; self.context = context; self.githubRepo = githubRepo
    self.position = position
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
  /// Sidebar sort order (synced, from `AreaEntity.position`). Populated by the
  /// entity init only — intentionally NOT a `CodingKey`, so the MCP/wire JSON
  /// stays unchanged. See `docs/DRAG_AND_DROP.md` §5 gap #2.
  var position: Int
  var updatedAt: String?
  // Removed areas tombstone per-record via CloudKit like tasks/projects; the
  // "wholesale-replace array" note here is FastAPI-era history. No `deletedAt`
  // field by design (delete-by-omission from the local mirror).

  init(id: String, title: String, context: String? = nil, emoji: String? = nil,
       position: Int = 0,
       updatedAt: String? = nil) {
    self.id = id; self.title = title; self.context = context; self.emoji = emoji
    self.position = position
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
    context = try c.decodeIfPresent(String.self, forKey: .context)
    emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
    position = 0   // not on the wire; set via AreaEntity init
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
  }

  enum CodingKeys: String, CodingKey {
    case id, title, context, emoji
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
  /// Agent-worked tasks waiting for the human to verify and accept (`endState == .needsVerify`).
  case review
  /// Every open task an agent owns or worked, grouped by `AgentStage`
  /// (docs/TASK_FACTORY_SPEC.md §3).
  case agent
  case upcoming
  case repeating
  case unscheduled
  case starred
  case logbook
  /// Tasks that faded untouched (`docs/TASK_FADE_SPEC.md` §4).
  case faded
  case recentlyDeleted
  case project(String)
  case area(String)

  var serverView: String {
    switch self {
    case .today: return "today"
    case .triage: return "triage"
    case .review: return "all"
    case .agent: return "all"
    case .upcoming: return "upcoming"
    case .repeating: return "all"
    case .unscheduled: return "unscheduled"
    case .starred: return "all"
    case .logbook: return "logbook"
    case .faded: return "all"
    case .recentlyDeleted: return "all"
    case .project, .area: return "all"
    }
  }

  /// Stable local identity for navigation. `serverView` intentionally maps
  /// several local lists to `all`, so it must not be used as a sidebar key.
  var navigationKey: String {
    switch self {
    case .today: return "today"
    case .triage: return "triage"
    case .review: return "review"
    case .agent: return "agent"
    case .upcoming: return "upcoming"
    case .repeating: return "repeating"
    case .unscheduled: return "unscheduled"
    case .starred: return "starred"
    case .logbook: return "logbook"
    case .faded: return "faded"
    case .recentlyDeleted: return "recentlyDeleted"
    case .project(let id): return "project.\(id)"
    case .area(let id): return "area.\(id)"
    }
  }

  /// Canonical `registry/destinations.json` ID for smart-list filters, or nil
  /// for area/project/triage filters.
  var destinationID: String? {
    switch self {
    case .today: return "today"
    case .review: return "review"
    case .agent: return "agent"
    case .upcoming: return "upcoming"
    case .repeating: return "repeating"
    case .unscheduled: return "anytime"
    case .logbook: return "logbook"
    case .starred: return "starred"
    case .faded: return "faded"
    case .recentlyDeleted: return "recentlyDeleted"
    case .triage, .project, .area: return nil
    }
  }

  /// Maps a canonical `registry/destinations.json` ID back to its `TaskFilter`.
  init?(destinationID: String) {
    switch destinationID {
    case "today": self = .today
    case "review": self = .review
    case "agent": self = .agent
    case "upcoming": self = .upcoming
    case "repeating": self = .repeating
    case "anytime", "unscheduled": self = .unscheduled
    case "logbook": self = .logbook
    case "starred": self = .starred
    case "faded": self = .faded
    case "recentlyDeleted": self = .recentlyDeleted
    default: return nil
    }
  }

  /// The smart list's registry row (`registry/destinations.json`), joined by
  /// `navigationKey`. Nil for a project or an area.
  var registryDestination: RegistryDestination? {
    RegistryDestinations.byNavigationKey[navigationKey]
  }

  // User-facing label, from the registry. "Anytime" is the single home for
  // open, dateless tasks (it absorbed the former "Someday" bucket). The
  // serverView key stays `unscheduled` so the API contract is unchanged.
  var title: String {
    switch self {
    case .project: return RegistryL10n.t("Project")
    case .area: return RegistryL10n.t("Area")
    default: return registryDestination?.title ?? navigationKey
    }
  }

  /// Empty-state copy for this list: the destination's own, or the generic
  /// one (`genericEmptyState`) for a project or an area.
  var emptyTitle: String {
    registryDestination?.emptyTitle ?? RegistryDestinations.GenericEmpty.title
  }

  /// For a project or an area: how to add a task here. "Double-click" only
  /// exists with a pointer; on a touch screen the + is the way in.
  var emptyDetail: String {
    if let registryDestination { return registryDestination.emptyDetail }
    #if os(macOS)
    return RegistryDestinations.GenericEmpty.pointerDetail
    #else
    return RegistryDestinations.GenericEmpty.touchDetail
    #endif
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

  /// The day the "N rolled into today" banner was last dismissed, as an ISO
  /// `yyyy-MM-dd` string. Synced because the banner reports one fact about the
  /// ACCOUNT ("these tasks rolled over"), not about a device — dismissing it on
  /// the Mac and meeting it again on the phone is the same notice twice. The
  /// device-local `septena.newTodos.dismissedDate` UserDefaults key stays as
  /// the instant, offline-safe mirror; reads take the LATER of the two so a
  /// stale synced value can never un-dismiss today's banner. Nil → never
  /// dismissed. Defaulted so the existing memberwise-init call sites stay
  /// source-stable.
  var rolledInDismissedOn: String? = nil

  /// "Pause all agents" (docs/TASK_FACTORY_SPEC.md §10). While true the task
  /// backend refuses every agent claim. Account-wide, so a pause on one device
  /// holds on all of them. Nil → not paused.
  var agentsPaused: Bool? = nil

  /// "Get started" checklist (Septask): true once dismissed or every step is
  /// complete, synced so finishing onboarding on one device hides it on all
  /// other devices too. Nil → not dismissed.
  var getStartedDismissed: Bool? = nil

  /// "Get started" checklist steps completed (raw `TaskNoticeStep.ID` values),
  /// synced across devices so progress carries over. Nil → none recorded.
  var getStartedSteps: [String]? = nil

  /// Upsell moments (`registry/plans.json` `upsells` ids) this account has
  /// seen. Each one shows once per account; synced so a second device does
  /// not repeat it (docs/SYNC_SUBSCRIPTION_SPEC.md §7.1). Nil → none seen.
  var upsellsSeen: [String]? = nil

  /// Appearance customization (ADR 0019 / docs/CUSTOMIZATION_SPEC.md). Synced
  /// across devices when device-local `syncTheme` is enabled.
  var accentColor: String? = nil
  var canvasTexture: String? = nil
  var textureIntensity: Int? = nil
  var textureMotion: String? = nil

  /// Per-account special smart-list sidebar customization (registry/destinations.json).
  /// `smartListOrder` is ORDERING ONLY (never membership): any registry
  /// destination absent from here appends in canonical `sidebarOrder`.
  /// `smartListHidden` lists canonical destination IDs explicitly hidden by the
  /// user (destinations with `canHide == false`, e.g. `today`, are never hidden).
  var smartListOrder: [String]? = nil
  var smartListHidden: [String]? = nil
  /// Optional per-destination placement override ("top" | "bottom") keyed by
  /// canonical destination ID. Absent IDs fall back to `registry/destinations.json`.
  var smartListPlacement: [String: String]? = nil

  /// When the first-run welcome (section picker + chained onboarding) was
  /// completed. The durable, cross-device "this account has been welcomed"
  /// marker: synced so a returning user's *new* device never re-shows the
  /// welcome once their data syncs in. Mirrored into the device-local
  /// `SettingsKey.welcomeCompleted` @AppStorage key that the welcome gate
  /// reads for an instant, offline-safe decision. Nil → not yet onboarded.
  /// Defaulted so the existing memberwise-init call sites stay source-stable.
  var onboardedAt: Date? = nil

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
    case supporter
    case morningCutoffHour = "morning_cutoff_hour"
    case afternoonCutoffHour = "afternoon_cutoff_hour"
    case rolledInDismissedOn = "rolled_in_dismissed_on"
    case agentsPaused = "agents_paused"
    case getStartedDismissed = "get_started_dismissed"
    case getStartedSteps = "get_started_steps"
    case upsellsSeen = "upsells_seen"
    case onboardedAt = "onboarded_at"
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

  /// Today's `yyyy-MM-dd`. Row filters read this several times per task on
  /// every list repaint (`isOnToday`, triage, the row-object build), so the
  /// string is formatted once per day, not once per read. The memo holds the
  /// day's bounds in the formatter's own time zone, and a clock that moves
  /// outside them (midnight, a manual clock change) formats again.
  static var today: String {
    let now = Date()
    if let hit = todayMemo.withLock({ m in
      m.flatMap { now >= $0.start && now < $0.end ? $0.day : nil }
    }) { return hit }
    let day = formatter.string(from: now)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = formatter.timeZone
    let start = cal.startOfDay(for: now)
    let end = cal.date(byAdding: .day, value: 1, to: start) ?? now
    todayMemo.withLock { $0 = (day, start, end) }
    return day
  }

  private static let todayMemo =
    OSAllocatedUnfairLock<(day: String, start: Date, end: Date)?>(initialState: nil)

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
  /// Localized short month + day ("May 14"). One shared formatter: row date
  /// labels used to build a new `DateFormatter` on every render.
  static func monthDay(_ d: Date) -> String { monthDayFormatter.string(from: d) }

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

// MARK: - Inbox (the one rule)

/// THE Inbox rule. Every surface that asks "is this task in the Inbox?" —
/// both shells' Today Inbox section, sidebar counts, the triage band, the
/// in-app MCP `tasks_list view=inbox|triage`, the task backend's connector
/// (`backend/src/tools/taskShared.ts`, kept in lockstep) — reads it from
/// here, through the `TaskEntity` / `SeptenaTask` properties that delegate to
/// it. Do not spell `project == nil && area == nil` out at a call site again.
///
/// Inbox = open, not deleted, not a heading, no area, no project. Membership
/// is filing state, nothing else. A task gets INTO the Inbox only by being
/// created or moved there, or by being restored from Recently Deleted after
/// its area / project is gone (`CloudKitTasksBackend.restore`). Deleting an
/// area or a project never sends tasks to the Inbox: their tasks go to
/// Recently Deleted (`ProjectsMutator.delete`, `AreasMutator.delete`).
///
/// A task whose area / project was deleted on another device is NOT unfiled
/// while its own delete is still on the way: it keeps the dead id, the reads
/// hide it (`DeletedContainerLedger.hides`) and the post-pull sweep moves it
/// to Recently Deleted (`AreasMutator.sweepDeletedContainerOrphans`).
enum TaskInbox {
  /// Filing state alone, any status: no area, no project.
  static func isUnfiled(area: String?, project: String?) -> Bool {
    area == nil && project == nil
  }

  /// Inbox membership: open, not deleted, not faded, not a heading, unfiled.
  static func contains(status: TaskStatus, isHeading: Bool, isDeleted: Bool,
                       isFaded: Bool = false,
                       area: String?, project: String?) -> Bool {
    status == .open && !isHeading && !isDeleted && !isFaded && isUnfiled(area: area, project: project)
  }

  /// The triage band's ratification rule, applied to an Inbox member (the
  /// band is `contains && isUnratified`). Two unratified populations:
  ///   • an agent proposal still inside its freshness window, and
  ///   • a human capture with no disposition at all (no Today pin, no date).
  ///
  /// Agent rows leave the band when (a) filed, (b) given a when/today *and*
  /// acknowledged, or (c) the freshness window decays. Bare `acknowledge`
  /// alone must NOT yank an undated proposal into Anytime — that was the
  /// "click a dashed row and it vanishes" bug (peek/select used to ack).
  static func isUnratified(source: String?, createdAt: Date, acknowledgedAt: Date?,
                           today: Bool, scheduled: String?, deadline: String?) -> Bool {
    if source == TaskSource.mcp {
      guard createdAt != .distantPast else { return false }
      guard Date().timeIntervalSince(createdAt) < AgentCue.decayWindow else { return false }
      // Proposed with a when/today: stay until acknowledged (then it crosses
      // into Today/Upcoming). Undated: stay for the whole freshness window
      // even after ack — glow clears, row does not exile itself.
      if today || scheduled != nil || deadline != nil { return acknowledgedAt == nil }
      return true
    }
    return scheduled == nil && deadline == nil && !today
  }

  /// What the Today page draws in its Inbox section: the triage band, then
  /// the Inbox members that are on Today. An Inbox member dated for later
  /// waits in Upcoming until its date arrives. Both shells build that
  /// section from `LocalCache.tasks(filter: .triage)` plus the unfiled rows
  /// of `.today`; `LocalCache.todayInboxTasks` is the same set as one list.
  static func showsInTodayInbox(isInInbox: Bool, isInTriageBand: Bool, isOnToday: Bool) -> Bool {
    isInTriageBand || (isInInbox && isOnToday)
  }
}

extension SeptenaTask {
  /// Associated GitHub issue or PR for this task, if any.
  /// Single entry point so L0 (`extKey`/`extUrl`) can plug in ahead of `conversation`.
  var linkedIssue: ConvoIssueLink? { conversation.linkedIssue }
}

/// The text the row menu's Share… hands to the system share sheet
/// (`task.share`, docs/TASK_ROW_MENU_SPEC.md). One builder for both shells,
/// so iOS and the Mac share the same words.
///
/// One task: its title, then its notes after a blank line. Several tasks:
/// one title per line, the same shape ⌘C copies.
enum TaskShareText {
  static func text(for tasks: [SeptenaTask]) -> String {
    if tasks.count == 1, let task = tasks.first {
      let notes = task.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return notes.isEmpty ? task.title : "\(task.title)\n\n\(notes)"
    }
    return tasks.map(\.title).joined(separator: "\n")
  }
}
