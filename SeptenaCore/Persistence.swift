import CloudKit
import Foundation
import os
import SwiftData

// Local SwiftData mirror of the Septena server. Server stays authoritative;
// this is a cache so the UI can render and accept input without a round-trip.
// Wire DTOs in Models.swift remain unchanged — we convert at the boundary.
//
// ⚠️  When adding a new label-style entity (anything users will rename and
//     reference by name, like areas/projects/chores/habits/sections), use
//     the uniform `id + title` model documented in
//     [IDENTIFIERS.md](docs/IDENTIFIERS.md). Tasks-style content entities are
//     exempt (id-only).

// MARK: - Entities

@Model
final class TaskEntity {
  // Query-shape indexes. Every list read funnels through
  // `LocalCache.fetchEntities(for:)`, whose predicates are all built from these
  // columns — `deletedAt == nil && !pendingDeletion && statusRaw == "open"` for
  // the day feeds, plus `project` / `area` for the detail lists and
  // `completedAt` for the logbook's sort. Unindexed, each of those was a full
  // table scan of every task the account has ever held, on the main thread, on
  // every sidebar click and every sync pulse.
  #Index<TaskEntity>([\.deletedAt], [\.statusRaw], [\.project], [\.area], [\.completedAt])

  @Attribute(.unique) var id: String
  var title: String
  var statusRaw: String
  var created: String?
  var scheduled: String?
  @Attribute(originalName: "due") var deadline: String?
  var today: Bool
  var todaySetOn: String?
  var completedAt: String?
  var area: String?
  var project: String?
  var notes: String?
  /// Task Conversations state (`TaskConvo` as JSON). PLAINTEXT, gateway-readable.
  /// nil until the first turn. Written only via `TaskMutator`; decode/encode via
  /// the `conversation` accessor. See `TaskConvo.swift`.
  var conversationJSON: String?
  var recurrenceUnit: String?
  var recurrenceInterval: Int
  var recurrenceAfterCompletion: Bool
  /// Keeps the repeat rule while preventing completion from generating the
  /// next copy. Pause/resume is a series-level operation.
  /// The `= false` is REQUIRED, not style: a new non-optional attribute with
  /// no default has nothing to write into existing rows, so lightweight
  /// migration fails with "missing attribute values on mandatory destination
  /// attribute" and the store won't open. Every new non-optional property on
  /// a persisted entity needs a default (or must be optional).
  var recurrencePaused: Bool = false
  /// Stable identity shared by every generated occurrence in one repeating
  /// series. Legacy rows are nil and are promoted to their own id when a
  /// repeat rule is next edited.
  var recurrenceSeriesID: String?
  /// The occurrence's logical slot on a fixed schedule. This deliberately
  /// differs from `scheduled` when the user makes a one-off exception.
  var recurrenceAnchorDate: String?
  /// Bumped every time we apply a server payload. Lets the syncer detect
  /// rows that the latest pull didn't touch (= server-side deletions).
  var lastSyncedAt: Date
  /// Legacy server-response position. Superseded by `position` for ordering;
  /// kept so older code/migrations still compile. No longer drives list order.
  var sortIndex: Int
  /// User-controlled manual order (Things-style). The single source of truth
  /// for how tasks are arranged in every list — lists render strictly by this
  /// (ascending), so nothing re-sorts on its own. A `Double` so a drag can
  /// insert at the midpoint of its two neighbours without renumbering the
  /// rest; `TaskOrder.normalize` re-spaces and backfills (0 = unset) and is
  /// synced via CloudKit so the order matches across devices.
  var position: Double = 0
  /// Today's own manual order (#66), kept apart from `position` so reordering
  /// Today never moves the task in its area / project list (as in Things).
  /// nil = never ordered on Today; Today then falls back to `TaskOrder.key`
  /// (`TaskOrder.todayKey`). Written only by `TaskMutator.reorderToday`;
  /// cleared when an open task leaves Today (`TasksBackend.commitAndPush`).
  /// Optional, so the migration is lightweight. Synced through the task
  /// backend's `todayPosition` column only: no CloudKit field (Septena Life
  /// no longer shows tasks). Name checked: NSManagedObject has no
  /// `todayPosition` / `setTodayPosition:` selector.
  var todayPosition: Double?
  /// Task fade fields (docs/TASK_FADE_SPEC.md §3, ADR 0006). All have defaults,
  /// so the migration is lightweight. Local only for now: the task backend
  /// gets the matching columns at the cutover (docs/SEPTASK_BACKEND.md §5.2),
  /// and there is no CloudKit field. Names checked: NSManagedObject has none
  /// of these selectors.
  ///
  /// Last user gesture on the task. nil on legacy rows: read as `createdAt`
  /// (`fadeClock`). Written only by `TasksBackend.touch`, which the user
  /// gesture sites reach through `TaskMutator.touch` — never by a sync apply,
  /// recurrence spawn, purge, agent write or the fade pass.
  var touchedAt: Date?
  /// Times the user pushed the task to a later day. Resets to 0 on any other
  /// user gesture (`TasksBackend.touch`).
  var deferCount: Int = 0
  /// Set when the task fades (P2). Cleared when the user keeps it.
  var fadedAt: Date?
  /// `"faded"` when the sweep drops the task, `"user"` for a manual drop.
  var dropReason: String?
  /// `"light"` / `"heavy"`. nil = unknown.
  var effort: String?
  /// Legacy FastAPI-era optimistic-write guard; no longer consulted on the
  /// CloudKit path. Retained as a schema field pending Phase-2 cleanup.
  var pendingSync: Bool = false
  /// True between the moment `TaskMutator.delete(id:)` is called and the
  /// drainer confirming the server-side delete. `LocalCache` filters rows
  /// with `pendingDeletion == true` so the UI hides them immediately. If
  /// the network call ultimately fails the flag is cleared and the row
  /// resurrects in the list.
  var pendingDeletion: Bool = false
  /// Server-stamped `updated_at` (mirrored from the DTO). Used by the
  /// delta-sync watermark — `Syncer.pullChanges()` sends the max
  /// updatedAt back as `since` on the next call.
  var updatedAt: String?
  /// Server-stamped tombstone. When set, the row is logically deleted
  /// — Syncer purges it locally during the next apply.
  var deletedAt: String?
  /// CKRecord system-fields blob (NSKeyedArchiver-encoded). Captured the
  /// first time we see a record from CloudKit (or after our own save is
  /// acked) so subsequent uploads preserve the recordChangeTag and avoid
  /// 409s. Nil for rows that haven't round-tripped through CloudKit yet
  /// (pre-migration FastAPI rows, or rows authored offline before the
  /// engine drained). The CloudKit path on `TaskRecord` reads / writes
  /// this transparently — call sites don't need to think about it.
  var cloudKitSystemFields: Data?
  /// Provenance — what created this row. `nil`/`"user"`/`"manual"` = human;
  /// `"mcp"` = authored by the MCP gateway (Claude). PERMANENT: an audit
  /// trail, never cleared. Set by the gateway at create time; the app reads
  /// it off the fetched record and preserves it on re-save.
  var source: String?
  /// Friendly label for `source` (e.g. "Claude"). Permanent, optional.
  var sourceClient: String?
  /// Transient freshness cue. `nil` until the user engages with an
  /// agent-created row (open / complete / edit / "Mark seen"); stamped
  /// then so the cue clears and — being synced — stays cleared on every
  /// device. Distinct from `source`, which never clears.
  var acknowledgedAt: Date?
  /// Canonical creation instant. `Date` (UTC; NSDate in CloudKit) to match
  /// the app-wide convention (`occurredAt`, `loggedAt`). New rows stamp it on
  /// insert; `.distantPast` only on pre-migration rows. Drives the agent-cue
  /// decay window.
  var createdAt: Date = Date.distantPast
  /// Row *shape* (`TaskKind`). `""`/absent = an ordinary task; `"heading"` =
  /// a section divider inside a project. A heading is modelled as a task so it
  /// inherits sync / `position` order / drag for free, but it must be excluded
  /// from every task feed, list, count, and badge — read `isHeading`, never the
  /// raw string. Additive CloudKit field, conditional write.
  var kind: String = ""
  /// For a member task filed under a heading: the heading task's `id` (a FK).
  /// nil for un-headed tasks and for heading rows themselves. Dragging a
  /// heading moves only its own row; members render under it wherever it lands
  /// by construction. Additive CloudKit field, conditional write.
  var heading: String?

  init(id: String,
       title: String,
       statusRaw: String = TaskStatus.open.rawValue,
       created: String? = nil,
       scheduled: String? = nil,
       deadline: String? = nil,
       today: Bool = false,
       todaySetOn: String? = nil,
       completedAt: String? = nil,
       area: String? = nil,
       project: String? = nil,
       notes: String? = nil,
       conversationJSON: String? = nil,
       recurrenceUnit: String? = nil,
       recurrenceInterval: Int = 1,
       recurrenceAfterCompletion: Bool = true,
       recurrencePaused: Bool = false,
       recurrenceSeriesID: String? = nil,
       recurrenceAnchorDate: String? = nil,
       lastSyncedAt: Date = .distantPast,
       sortIndex: Int = 0,
       position: Double = 0,
       pendingSync: Bool = false,
       pendingDeletion: Bool = false,
       updatedAt: String? = nil,
       deletedAt: String? = nil,
       cloudKitSystemFields: Data? = nil,
       source: String? = nil,
       sourceClient: String? = nil,
       acknowledgedAt: Date? = nil,
       createdAt: Date = Date.distantPast,
       kind: String = "",
       heading: String? = nil,
       todayPosition: Double? = nil) {
    self.id = id
    self.title = title
    self.statusRaw = statusRaw
    self.created = created
    self.scheduled = scheduled
    self.deadline = deadline
    self.today = today
    self.todaySetOn = todaySetOn
    self.completedAt = completedAt
    self.area = area
    self.project = project
    self.notes = notes
    self.conversationJSON = conversationJSON
    self.recurrenceUnit = recurrenceUnit
    self.recurrenceInterval = recurrenceInterval
    self.recurrenceAfterCompletion = recurrenceAfterCompletion
    self.recurrencePaused = recurrencePaused
    self.recurrenceSeriesID = recurrenceSeriesID
    self.recurrenceAnchorDate = recurrenceAnchorDate
    self.lastSyncedAt = lastSyncedAt
    self.sortIndex = sortIndex
    self.position = position
    self.pendingSync = pendingSync
    self.pendingDeletion = pendingDeletion
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.cloudKitSystemFields = cloudKitSystemFields
    self.source = source
    self.sourceClient = sourceClient
    self.acknowledgedAt = acknowledgedAt
    self.createdAt = createdAt
    self.kind = kind
    self.heading = heading
    self.todayPosition = todayPosition
  }

  /// True when this row is a project section divider, not a to-do. The single
  /// read point — every feed/count/list gates on this so headings never leak
  /// out of a project's detail view (see `TaskKind`).
  var isHeading: Bool { kind == TaskKind.heading }

  var status: TaskStatus {
    get { TaskStatus(rawValue: statusRaw) ?? .open }
    set { statusRaw = newValue.rawValue }
  }

  /// Decoded conversation (empty if none yet). Assigning re-encodes to
  /// `conversationJSON`. Go through `TaskMutator` to persist + sync — this
  /// accessor only (de)serializes.
  var conversation: TaskConvo {
    get {
      guard let json = conversationJSON,
            let data = json.data(using: .utf8),
            let convo = try? JSONDecoder.taskConvo.decode(TaskConvo.self, from: data)
      else { return TaskConvo() }
      return convo
    }
    set {
      conversationJSON = (try? JSONEncoder.taskConvo.encode(newValue))
        .flatMap { String(data: $0, encoding: .utf8) }
    }
  }

  /// Single definition of "is this open task on the Today list."
  ///
  /// Today is currently a *union* of three signals: an explicit `today` pin,
  /// a scheduled ("When") date that has arrived, or a deadline that has
  /// arrived. Step 4 of the due/when simplification will collapse this to
  /// just `scheduled == today` and retire the `today` flag — at which point
  /// only the body of this one property changes. Centralized here so the
  /// `.today` filter (and anything else) reads from a single source.
  /// True when this open task has faded into the Faded pile
  /// (`docs/TASK_FADE_SPEC.md` §4). Faded tasks leave every other list, every
  /// count, Next, and the badge.
  var isFaded: Bool { status == .open && fadedAt != nil }

  var isOnToday: Bool {
    guard status == .open, !isHeading, fadedAt == nil else { return false }
    if today { return true }
    if let s = scheduled, s <= SeptenaDate.today { return true }
    if let d = deadline, d <= SeptenaDate.today { return true }
    return false
  }

  /// Filed nowhere: no area, no project. See `TaskInbox`.
  var isUnfiled: Bool { TaskInbox.isUnfiled(area: area, project: project) }

  /// Inbox member: open, not deleted, not faded, not a heading, unfiled. The
  /// one Inbox rule lives in `TaskInbox`; mirror of `SeptenaTask.isInInbox`.
  var isInInbox: Bool {
    TaskInbox.contains(status: status, isHeading: isHeading, isDeleted: deletedAt != nil,
                       isFaded: isFaded, area: area, project: project)
  }

  /// The triage band: Inbox members not yet ratified — the layer rendered
  /// above Today (`docs/TRIAGE_BAND_SPEC.md`, `TaskInbox.isUnratified`).
  /// Mirror of `SeptenaTask.isInTriageBand`.
  var isInTriageBand: Bool {
    isInInbox && TaskInbox.isUnratified(source: source, createdAt: createdAt,
                                        acknowledgedAt: acknowledgedAt, today: today,
                                        scheduled: scheduled, deadline: deadline)
  }

  var recurrence: Recurrence? {
    get {
      guard let unit = recurrenceUnit.flatMap(Recurrence.Unit.init(rawValue:)) else { return nil }
      return Recurrence(unit: unit,
                        interval: recurrenceInterval,
                        afterCompletion: recurrenceAfterCompletion)
    }
    set {
      recurrenceUnit = newValue?.unit.rawValue
      recurrenceInterval = newValue?.interval ?? 1
      recurrenceAfterCompletion = newValue?.afterCompletion ?? true
    }
  }
}

@Model
final class ProjectEntity {
  // Mirrors `TaskEntity` — the sidebar filters on both columns.
  #Index<ProjectEntity>([\.deletedAt], [\.area])

  @Attribute(.unique) var id: String
  var title: String
  var statusRaw: String
  var area: String?
  var created: String?
  var completedAt: String?
  var notes: String?
  var context: String?
  var githubRepo: String?
  /// JSON-encoded `AreaAttachment` (the one read-only context feed). Rides a
  /// reserved CloudKit string slot. See [AreaAttachment.swift].
  var attachmentJSON: String?
  /// Sidebar sort order (synced). `0` = unset (falls back to legacy device
  /// order / title); a reorder renumbers the whole group 1…N. Rides the
  /// reserved `reservedInt1` CK slot — additive in Prod, no record-type bump.
  /// See `docs/DRAG_AND_DROP.md` §5 gap #2.
  var position: Int = 0
  var lastSyncedAt: Date
  var updatedAt: String?
  var deletedAt: String?
  /// CKRecord system-fields blob. See `TaskEntity.cloudKitSystemFields` for
  /// the same contract — captured on round-trip through CloudKit so the
  /// next save preserves recordChangeTag.
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       statusRaw: String = ProjectStatus.active.rawValue,
       area: String? = nil,
       created: String? = nil,
       completedAt: String? = nil,
       notes: String? = nil,
       context: String? = nil,
       githubRepo: String? = nil,
       attachmentJSON: String? = nil,
       position: Int = 0,
       lastSyncedAt: Date = .distantPast,
       updatedAt: String? = nil,
       deletedAt: String? = nil,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.statusRaw = statusRaw
    self.area = area
    self.created = created
    self.completedAt = completedAt
    self.notes = notes
    self.context = context
    self.githubRepo = githubRepo
    self.attachmentJSON = attachmentJSON
    self.position = position
    self.lastSyncedAt = lastSyncedAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }

  var status: ProjectStatus {
    get { ProjectStatus(rawValue: statusRaw) ?? .active }
    set { statusRaw = newValue.rawValue }
  }

  /// The decoded attachment, with a read-fallback that coerces a legacy
  /// `githubRepo` pointer into a `.git` attachment so existing projects light
  /// up without a migration pass.
  var attachment: AreaAttachment? {
    if let a = AreaAttachment.decode(attachmentJSON) { return a }
    if let repo = githubRepo, !repo.isEmpty { return AreaAttachment(kind: .git, ref: repo) }
    return nil
  }
}

@Model
final class AreaEntity {
  @Attribute(.unique) var id: String
  var title: String
  var context: String?
  /// Optional user-assigned glyph. When set, it replaces the area's filler
  /// dot wherever the area appears (sidebar, headers, pickers) — a Tier-3
  /// emoji in design-system terms. Nil ⇒ fall back to the dot.
  var emoji: String?
  /// JSON-encoded `AreaAttachment` (the one read-only context feed). Rides a
  /// reserved CloudKit string slot. See [AreaAttachment.swift].
  var attachmentJSON: String?
  /// Sidebar sort order (synced). `0` = unset (falls back to legacy device
  /// order / title); a reorder renumbers the areas 1…N. Rides the reserved
  /// `reservedInt1` CK slot — additive in Prod, no record-type bump. See
  /// `docs/DRAG_AND_DROP.md` §5 gap #2.
  var position: Int = 0
  var lastSyncedAt: Date
  var updatedAt: String?
  /// CKRecord system-fields blob. See `TaskEntity.cloudKitSystemFields`.
  var cloudKitSystemFields: Data?

  init(id: String, title: String, context: String? = nil, emoji: String? = nil,
       attachmentJSON: String? = nil, position: Int = 0,
       lastSyncedAt: Date = .distantPast, updatedAt: String? = nil,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.context = context
    self.emoji = emoji
    self.attachmentJSON = attachmentJSON
    self.position = position
    self.lastSyncedAt = lastSyncedAt
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }

  /// The decoded attachment (no legacy fallback — areas never had `githubRepo`).
  var attachment: AreaAttachment? { AreaAttachment.decode(attachmentJSON) }
}

@Model
final class SettingsEntity {
  @Attribute(.unique) var id: String
  var payloadData: Data
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as the other mirrored
  /// entities: preserves recordChangeTag across updates.
  var cloudKitSystemFields: Data?

  init(id: String = SettingsCloudKitSchema.singletonID,
       payloadData: Data,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.payloadData = payloadData
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class SectionEntity {
  @Attribute(.unique) var id: String
  var title: String
  var color: String
  /// Whether the section is visible on the dashboard and Settings sidebar.
  /// Disabling never deletes the row or any per-section data; toggling
  /// back on restores the previous title/color customizations.
  var isEnabled: Bool = true
  /// Whether this section contributes events to the Today log. Only
  /// meaningful for sections the manifest marks as `appearsInToday`.
  /// Independent of `isEnabled` so a section can stay visible on the
  /// dashboard but be muted from the Today timeline (or vice versa).
  var showInToday: Bool = true
  /// Whether this section's entries are exposed to Spotlight / Siri / Apple
  /// Intelligence (the on-device semantic index). Default true — everything is
  /// discoverable unless the user opts the section out in Settings. Independent
  /// of `isEnabled` and `showInToday`. Absence in a CKRecord decodes as true, so
  /// existing rows are discoverable with no migration. See
  /// docs/SPOTLIGHT_READABILITY_PLAN.md.
  var showInSpotlight: Bool = true
  /// Set to true once the section's onboarding flow has completed (or
  /// been skipped) for this user. Distinguishes "first ever enable"
  /// (which should run onboarding) from a later toggle off → on. Stays
  /// true forever once set; data is never lost on disable.
  var hasOnboarded: Bool = false
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as the other mirrored
  /// entities: preserves recordChangeTag across updates.
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       color: String,
       isEnabled: Bool = true,
       showInToday: Bool = true,
       showInSpotlight: Bool = true,
       hasOnboarded: Bool = false,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.color = color
    self.isEnabled = isEnabled
    self.showInToday = showInToday
    self.showInSpotlight = showInSpotlight
    self.hasOnboarded = hasOnboarded
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

// MARK: - DTO ↔ Entity bridging

extension SeptenaTask {
  init(_ e: TaskEntity) {
    self.init(
      id: e.id,
      title: e.title,
      status: e.status,
      created: e.created,
      scheduled: e.scheduled,
      deadline: e.deadline,
      today: e.today,
      todaySetOn: e.todaySetOn,
      completedAt: e.completedAt,
      area: e.area,
      project: e.project,
      notes: e.notes,
      recurrence: e.recurrence,
      recurrencePaused: e.recurrencePaused,
      // Pass the series' LOGICAL slot, the way `complete` does — without it
      // the preview rebases on a one-off exception date and shows a next
      // occurrence the completion will not actually create. (`DayClock.appToday`
      // would match `complete` exactly, but this initializer is nonisolated;
      // the two differ only under time travel.)
      nextOccurrence: e.status == .open
        ? e.recurrence?.nextDate(completedOn: SeptenaDate.today,
                                 scheduled: e.scheduled,
                                 logicalScheduled: e.recurrenceAnchorDate)
        : nil,
      updatedAt: e.updatedAt,
      deletedAt: e.deletedAt,
      source: e.source,
      sourceClient: e.sourceClient,
      acknowledgedAt: e.acknowledgedAt,
      createdAt: e.createdAt,
      position: e.position,
      todayPosition: e.todayPosition,
      touchedAt: e.touchedAt,
      deferCount: e.deferCount,
      fadedAt: e.fadedAt,
      dropReason: e.dropReason,
      effort: e.effort,
      kind: e.kind,
      heading: e.heading,
      conversation: e.conversation
    )
  }

  /// Manual-order sort key — see `TaskOrder.key`.
  var orderKey: Double { TaskOrder.key(position: position, createdAt: createdAt) }

  /// The fade clock's start: the last user gesture, or `createdAt` on a row
  /// never touched (docs/TASK_FADE_SPEC.md §3).
  var fadeClock: Date { touchedAt ?? createdAt }

  /// Today's sort key — see `TaskOrder.todayKey`.
  var todayOrderKey: Double { todayPosition ?? orderKey }

  /// The sort key of `lane` — the one read every reorder path uses.
  func orderKey(in lane: TaskOrderLane) -> Double {
    switch lane {
    case .list: return orderKey
    case .today: return todayOrderKey
    }
  }
}

/// Which manual order a list shows and a reorder writes (#66). Today has its
/// own order (`todayPosition`); every other list uses `position`. A Today
/// reorder never touches `position`, so the task keeps its place in its own
/// area / project list.
enum TaskOrderLane {
  case list
  case today
}

/// Manual task ordering (Things-style). Lists render strictly by `key`, so a
/// task only moves when the user drags it. We deliberately avoid a synced
/// position backfill: an un-dragged task derives its key from `createdAt`,
/// which every device already agrees on, so the baseline order is consistent
/// without writing anything. Only an explicit drag (or a new task's top
/// placement) stores a `position`, which then syncs via CloudKit.
enum TaskOrder {
  /// Default spacing between manual positions. Large relative to nothing in
  /// particular — `Double` precision means midpoint inserts effectively never
  /// run out of room on the creation-instant scale these keys live on.
  static let gap: Double = 1024

  /// Order key: the explicit `position` once set (non-zero), otherwise the
  /// creation instant. `0` is the "never dragged" sentinel — no real task is
  /// created at the reference date, so this never collides with a live value.
  static func key(position: Double, createdAt: Date) -> Double {
    position != 0 ? position : createdAt.timeIntervalSinceReferenceDate
  }
  static func key(_ e: TaskEntity) -> Double {
    key(position: e.position, createdAt: e.createdAt)
  }

  /// Today's order key: `todayPosition` once the row was ordered on Today,
  /// otherwise its list key. A row that lands on Today therefore starts at
  /// its list position there, the same rule the task backend uses
  /// (`backend/src/shadow/writes.ts`), so a new task (top of its list) is at
  /// the top of Today.
  static func todayKey(_ e: TaskEntity) -> Double {
    e.todayPosition ?? key(e)
  }

  /// A position that sorts above every live task, so a freshly created task
  /// lands at the top of the list (matching the existing insert-at-top feel).
  @MainActor
  static func topPosition(in context: ModelContext) -> Double {
    (extremeKey(in: context, highest: false) ?? 0) - gap
  }

  /// A position that sorts below every live task — used by the foot-of-list
  /// quick-add line so a capture lands where the user typed, not at the top.
  @MainActor
  static func bottomPosition(in context: ModelContext) -> Double {
    (extremeKey(in: context, highest: true) ?? 0) + gap
  }

  /// The lowest (or highest) order key across live tasks.
  ///
  /// `key` mixes two stored columns — an explicit `position` once the row has
  /// been dragged, otherwise `createdAt` — so the extreme can't be expressed as
  /// one `SortDescriptor`. Taking the extreme of each column with a limit-1
  /// sorted fetch and combining them gets the same answer from two indexed
  /// seeks. This previously materialized EVERY `TaskEntity` in the store and
  /// mapped it, on every single task create.
  @MainActor
  private static func extremeKey(in context: ModelContext, highest: Bool) -> Double? {
    let order: SortOrder = highest ? .reverse : .forward

    var dragged = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { !$0.pendingDeletion && $0.deletedAt == nil && $0.position != 0 },
      sortBy: [SortDescriptor(\.position, order: order)]
    )
    dragged.fetchLimit = 1

    var undragged = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { !$0.pendingDeletion && $0.deletedAt == nil && $0.position == 0 },
      sortBy: [SortDescriptor(\.createdAt, order: order)]
    )
    undragged.fetchLimit = 1

    let candidates = [dragged, undragged]
      .compactMap { (try? context.fetch($0))?.first }
      .map { key($0) }
    return highest ? candidates.max() : candidates.min()
  }

  /// Evenly spaced keys for `count` tasks dropped between two neighbor keys
  /// (nil at a list edge). Guaranteed non-zero (0 is the "never dragged"
  /// sentinel): a batch that lands on 0 is shifted half a step, which stays
  /// strictly inside the neighbor interval. Callers must still treat a result
  /// that doesn't sort strictly between its neighbors (midpoint precision
  /// exhausted) as the renumber signal — see `TaskListView` drop handling.
  static func positions(count: Int, above: Double?, below: Double?) -> [Double] {
    guard count > 0 else { return [] }
    var slots: [Double]
    let nudge: Double
    switch (above, below) {
    case let (a?, b?):
      let step = (b - a) / Double(count + 1)
      slots = (1...count).map { a + step * Double($0) }
      nudge = step / 2
    case let (a?, nil):
      slots = (1...count).map { a + gap * Double($0) }
      nudge = gap / 2
    case let (nil, b?):
      slots = (1...count).map { b - gap * Double(count + 1 - $0) }
      nudge = -gap / 2
    case (nil, nil):
      slots = (1...count).map { gap * Double($0) }
      nudge = 0
    }
    if slots.contains(0) { slots = slots.map { $0 + nudge } }
    return slots
  }

  /// Single-task drop key between two neighbors — `positions` for one.
  static func between(above: Double?, below: Double?) -> Double {
    positions(count: 1, above: above, below: below)[0]
  }
}

extension Project {
  init(_ e: ProjectEntity) {
    self.init(id: e.id,
              title: e.title,
              status: e.status,
              area: e.area,
              created: e.created,
              completedAt: e.completedAt,
              notes: e.notes,
              context: e.context,
              githubRepo: e.githubRepo,
              attachment: e.attachment,
              position: e.position,
              updatedAt: e.updatedAt,
              deletedAt: e.deletedAt)
  }
}

extension Area {
  init(_ e: AreaEntity) {
    self.init(id: e.id, title: e.title, context: e.context, emoji: e.emoji,
              attachment: e.attachment,
              position: e.position,
              updatedAt: e.updatedAt)
  }
}

extension SectionConfig {
  init(_ e: SectionEntity) {
    self.init(key: e.id,
              label: e.title,
              color: e.color,
              isEnabled: e.isEnabled,
              showInToday: e.showInToday,
              showInSpotlight: e.showInSpotlight,
              hasOnboarded: e.hasOnboarded)
  }
}

// MARK: - LocalStore

/// Dedicated local SwiftData store for the Septena task app (`SeptenaTasks.store`,
/// ADR 0017 Pass 2). Splitting off the shared `Septena.store` lets the task app
/// drop the 27 Life-OS `@Model` entities cleanly via Core Data lightweight
/// migration without ever mutating a `Septena.store` file that Septena Life may
/// still open on the same device.
///
/// On macOS, `~/Library/Septena/` stays outside the TCC-guarded App Data roots
/// (`~/Library/Containers`, `~/Library/Group Containers`,
/// `~/Library/Application Support/<app>`) so un-sandboxed builds never raise
/// repeated App Data prompts.
///
/// On iOS, the store lives in the app's own `Application Support` container.
enum TaskStoreLocation {
  /// The three files SQLite keeps in WAL mode. All of them travel together or
  /// the store opens short of its most recent writes.
  private static let suffixes = ["", "-wal", "-shm"]

  static var url: URL? {
    #if os(macOS)
    guard let library = FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
    return library
      .appendingPathComponent("Septena", isDirectory: true)
      .appendingPathComponent("SeptenaTasks.store")
    #else
    guard let support = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    return support.appendingPathComponent("SeptenaTasks.store")
    #endif
  }

  /// Previous store homes, newest first. Resolved ONLY when `SeptenaTasks.store`
  /// is absent so macOS never touches TCC-guarded locations on normal launches.
  private static var legacyURLs: [URL] {
    var found: [URL] = []
    #if os(macOS)
    if let library = FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask).first {
      found.append(library
        .appendingPathComponent("Septena", isDirectory: true)
        .appendingPathComponent("Septena.store"))
    }
    if let support = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      found.append(support
        .appendingPathComponent("Septena", isDirectory: true)
        .appendingPathComponent("Septena.store"))
    }
    if let group = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: SeptenaAppGroup.suite) {
      found.append(group.appendingPathComponent("Library/Application Support/Septena.store"))
    }
    #else
    if let group = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: SeptenaAppGroup.suite) {
      found.append(group.appendingPathComponent("Library/Application Support/Septena.store"))
    }
    if let support = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      found.append(support.appendingPathComponent("Septena.store"))
    }
    #endif
    return found
  }

  /// Copy the previous shared store to `SeptenaTasks.store`, once, before it is
  /// opened. COPY (never move): the old `Septena.store` stays intact as a
  /// backstop and for Septena Life.
  static func migrateIfNeeded() {
    let fm = FileManager.default
    guard let destination = url else { return }
    guard !fm.fileExists(atPath: destination.path) else { return }
    guard let source = legacyURLs.first(where: { fm.fileExists(atPath: $0.path) }) else { return }

    do {
      try fm.createDirectory(at: destination.deletingLastPathComponent(),
                             withIntermediateDirectories: true)
      for suffix in suffixes {
        let from = URL(fileURLWithPath: source.path + suffix)
        let to = URL(fileURLWithPath: destination.path + suffix)
        guard fm.fileExists(atPath: from.path) else { continue }
        try fm.copyItem(at: from, to: to)
      }
      Log.persistence.notice("Copied legacy Septena.store to dedicated SeptenaTasks.store.")
    } catch {
      for suffix in suffixes {
        try? fm.removeItem(at: URL(fileURLWithPath: destination.path + suffix))
      }
      Log.persistence.error(
        "Local task store migration failed, keeping previous copy: \(error.localizedDescription, privacy: .public)")
    }
  }
}

@MainActor
final class LocalStore {
  static let shared = LocalStore()

  let container: ModelContainer

  private init() {
    let schema = Schema([TaskEntity.self,
                         TaskAttachmentEntity.self,
                         ProjectEntity.self,
                         AreaEntity.self,
                         SettingsEntity.self,
                         SectionEntity.self])
    let config: ModelConfiguration
    if DemoSeedMode.isOn {
      config = ModelConfiguration("SeptenaTasks", schema: schema, isStoredInMemoryOnly: true,
                                  cloudKitDatabase: .none)
    } else {
      TaskStoreLocation.migrateIfNeeded()
      if let url = TaskStoreLocation.url {
        config = ModelConfiguration("SeptenaTasks", schema: schema, url: url, cloudKitDatabase: .none)
      } else {
        config = ModelConfiguration("SeptenaTasks", schema: schema, cloudKitDatabase: .none)
      }
    }
    do {
      container = try LaunchTrace.spanSync("launch.localStoreOpen") {
        try ModelContainer(for: schema, configurations: [config])
      }
    } catch let error {
      Log.persistence.fault("ModelContainer init failed; local store preserved: \(error.localizedDescription, privacy: .public)")
      fatalError("Local database could not be opened. Its files were preserved; install a compatible repair build rather than deleting Septena data. \(error)")
    }
  }
}

// MARK: - StoreHealth (read/write failure accounting)

/// Every SwiftData read in this file used to be written `(try? fetch(…)) ?? []`,
/// which makes a THROWN fetch and an empty table the same value. When the main
/// context wedged, every count in the app painted 0, the sidebar memoized those
/// zeros, and the only recovery was a force quit — with nothing in the log to
/// say what happened, because the error was discarded at the `try?`.
///
/// This type is the single place reads and writes report failure. It does two
/// jobs:
///
/// 1. **Logs the real error.** SwiftData and Core Data put the actionable part
///    in the `NSError` `userInfo` (`NSDetailedErrors` for a multi-error save,
///    `NSValidationErrorKey` / `NSConstraintConflict` for a constraint hit).
///    `localizedDescription` alone says "The operation couldn't be completed."
/// 2. **Publishes a failure token** so a caller that runs several reads can ask
///    whether any of them failed, and keep its last good values instead of
///    caching zeros over them (see `SidebarRootView.load`).
///
/// It is accounting, not policy: nothing here decides what a caller does with a
/// failed read.
@MainActor
enum StoreHealth {
  /// Monotonic count of failed reads this process. Callers snapshot it before a
  /// read pass and compare after — a changed value means "at least one read in
  /// that pass threw, do not trust the result".
  private(set) static var readFailures = 0
  /// Monotonic count of failed saves this process.
  private(set) static var saveFailures = 0
  private(set) static var lastFailureSummary: String?

  /// Snapshot the read-failure counter before a multi-read pass.
  static func readToken() -> Int { readFailures }

  /// True when any read failed since `token` was taken.
  static func readsFailed(since token: Int) -> Bool { readFailures != token }

  /// One fetch, with the error kept instead of discarded. Returns `[]` on
  /// failure exactly like the old `try?` did, so call sites keep their shape —
  /// but the failure is now counted and logged.
  static func fetch<E: PersistentModel>(_ context: ModelContext,
                                        _ descriptor: FetchDescriptor<E>,
                                        _ site: StaticString = #function) -> [E] {
    do {
      return try context.fetch(descriptor)
    } catch {
      readFailures += 1
      let summary = "\(E.self) read failed at \(site): \(detail(error))"
      lastFailureSummary = summary
      Log.persistence.error("[StoreHealth] \(summary, privacy: .public)")
      return []
    }
  }

  /// Save, and un-wedge the context when the save fails.
  ///
  /// A failed `save()` leaves its pending changes in the context. Every later
  /// save retries them and fails the same way, so one bad write silently stops
  /// ALL later writes from persisting and can make subsequent fetches throw —
  /// the app-wide "everything reads 0 until I force quit" state. `rollback()`
  /// discards the one change that could not be written, which costs that single
  /// mutation and keeps every later one working. Losing one write beats losing
  /// every write after it.
  ///
  /// `nonisolated` because not every writer is on the main actor:
  /// `ChecklistMirror` and `CloudKitRecordRegistry` save background contexts on
  /// purpose. It touches only the context it was handed, so it is safe from any
  /// isolation; the shared failure counter is updated back on the main actor.
  @discardableResult
  nonisolated static func save(_ context: ModelContext, op: String) -> Bool {
    do {
      try context.save()
      return true
    } catch {
      let summary = "save failed (op=\(op)): \(detail(error))"
      Log.persistence.error("[StoreHealth] \(summary, privacy: .public)")
      context.rollback()
      Log.persistence.error("[StoreHealth] rolled back after op=\(op, privacy: .public) — that one change is lost, later writes keep working")
      Task { @MainActor in noteSaveFailure(summary) }
      return false
    }
  }

  /// The throwing variant, for writers whose `do`/`catch` already gates
  /// follow-up work (a CloudKit push, a notification) on the save succeeding.
  /// Control flow is unchanged — the error still reaches the existing `catch` —
  /// but the context is logged and rolled back on the way out, so the failed
  /// change cannot wedge every later save.
  nonisolated static func saveOrThrow(_ context: ModelContext, op: String) throws {
    do {
      try context.save()
    } catch {
      let summary = "save failed (op=\(op)): \(detail(error))"
      Log.persistence.error("[StoreHealth] \(summary, privacy: .public)")
      context.rollback()
      Task { @MainActor in noteSaveFailure(summary) }
      throw error
    }
  }

  private static func noteSaveFailure(_ summary: String) {
    saveFailures += 1
    lastFailureSummary = summary
    StoreHealthState.shared.noteSaveFailure(summary)
  }

  /// The parts of an `NSError` that actually name the problem. A SwiftData save
  /// error wraps its real causes in `NSDetailedErrors`; a constraint or
  /// validation failure names the entity and key in its own `userInfo`.
  /// `localizedDescription` on its own says only "The operation couldn't be
  /// completed", which is why the old logs were useless.
  nonisolated static func detail(_ error: Error) -> String {
    let ns = error as NSError
    var parts = ["\(ns.domain)/\(ns.code) \(ns.localizedDescription)"]
    if let detailed = ns.userInfo["NSDetailedErrors"] as? [NSError] {
      for sub in detailed.prefix(5) {
        parts.append("· \(sub.domain)/\(sub.code) \(sub.localizedDescription) \(keys(of: sub))")
      }
    } else {
      let k = keys(of: ns)
      if !k.isEmpty { parts.append(k) }
    }
    return parts.joined(separator: " ")
  }

  /// The non-sensitive keys of an error's `userInfo` — entity and attribute
  /// names and conflict descriptions, never a task title or note body.
  nonisolated private static func keys(of error: NSError) -> String {
    var out: [String] = []
    if let object = error.userInfo["NSValidationErrorObject"] as? NSObject {
      out.append("object=\(type(of: object))")
    }
    if let key = error.userInfo["NSValidationErrorKey"] as? String {
      out.append("key=\(key)")
    }
    if let conflicts = error.userInfo["conflictList"] {
      out.append("conflicts=\(String(describing: conflicts).prefix(400))")
    }
    return out.isEmpty ? "" : "[\(out.joined(separator: " "))]"
  }
}

// MARK: - LocalCache (synchronous reads for instant render)

/// Snapshot reads from the local store. Views call these at the top of
/// their `load()` to paint instantly, then kick off the network refresh.
/// Filter semantics roughly mirror the server's `view=` parameter; they're
/// approximations — the network response always wins on the next render.
enum LocalCache {
  /// Live mirror rows — excludes Recently Deleted (`deletedAt != nil`) but
  /// still includes `pendingDeletion` rows (openCount semantics count them).
  @MainActor
  static func liveEntities(in context: ModelContext) -> [TaskEntity] {
    StoreHealth.fetch(context, FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.deletedAt == nil }
    ))
  }

  /// Every non-trashed task as a wire DTO — sidebar roll-ups, aggregates.
  /// Headings are dividers, not to-dos: excluded so they never inflate any
  /// count or aggregate (see `TaskEntity.isHeading`).
  @MainActor
  static func liveTasks(in context: ModelContext) -> [SeptenaTask] {
    let dead = DeletedContainerLedger.snapshot()
    return liveEntities(in: context)
      .filter { !$0.pendingDeletion && !$0.isHeading
        && !DeletedContainerLedger.hides(area: $0.area, project: $0.project, in: dead) }
      .map(SeptenaTask.init)
  }

  /// The Today page's Inbox section as one list: the triage band first, then
  /// the Inbox members on Today (`TaskInbox.showsInTodayInbox`). The in-app
  /// MCP `tasks_list view=inbox` reads this; the backend connector's
  /// `inbox` view applies the same rule (`backend/src/tools/taskShared.ts`).
  @MainActor
  static func todayInboxTasks(in context: ModelContext) -> [SeptenaTask] {
    let band = tasks(in: context, filter: .triage)
    let bandIDs = Set(band.map(\.id))
    return band + tasks(in: context, filter: .today).filter { $0.isInInbox && !bandIDs.contains($0.id) }
  }

  /// Assigned, non-cancelled tasks — the SuggestionEngine training corpus.
  /// Unassigned inbox/logbook rows don't teach filing targets.
  @MainActor
  static func trainingTasks(in context: ModelContext) -> [SeptenaTask] {
    let candidates = StoreHealth.fetch(context, FetchDescriptor<TaskEntity>(
      predicate: #Predicate { e in
        e.deletedAt == nil && !e.pendingDeletion && e.kind != "heading"
      },
      sortBy: [SortDescriptor(\.id)]
    ))
    return candidates.compactMap { entity in
      guard entity.status != .cancelled,
            entity.area != nil || entity.project != nil else { return nil }
      return SeptenaTask(entity)
    }
  }

  /// Tasks filed in a project — project progress glyphs without scanning the
  /// full logbook. Excludes heading dividers so they don't count toward a
  /// project's done/total.
  @MainActor
  static func tasksWithProject(in context: ModelContext) -> [SeptenaTask] {
    StoreHealth.fetch(context, FetchDescriptor<TaskEntity>(
      predicate: #Predicate { e in
        e.deletedAt == nil && !e.pendingDeletion
          && e.project != nil && e.kind != "heading"
      }
    )).map(SeptenaTask.init)
  }

  /// Completion ratios for project headers. Keep this as an entity aggregate
  /// so a normal task-list refresh does not allocate one DTO per historical
  /// task merely to compute two integer counters.
  @MainActor
  static func projectCompletionRatios(in context: ModelContext) -> [String: Double] {
    let rows = StoreHealth.fetch(context, FetchDescriptor<TaskEntity>(
      predicate: #Predicate { e in
        e.deletedAt == nil && !e.pendingDeletion
          && e.project != nil && e.kind != "heading"
      }
    ))
    var done: [String: Int] = [:]
    var total: [String: Int] = [:]
    for row in rows {
      guard let project = row.project else { continue }
      switch row.status {
      case .done:
        done[project, default: 0] += 1
        total[project, default: 0] += 1
      case .open:
        if row.fadedAt == nil { total[project, default: 0] += 1 }
      case .cancelled:
        break
      }
    }
    return total.reduce(into: [:]) { result, pair in
      result[pair.key] = Double(done[pair.key] ?? 0) / Double(pair.value)
    }
  }

  /// The section-divider "heading" rows filed in a project, in manual order
  /// (`TaskOrder.key`). The ONE place headings are surfaced — the project
  /// detail view partitions its tasks under these. Every other read excludes
  /// them (see `convert`). Open rows only; a soft-deleted heading is gone.
  @MainActor
  static func headings(inProject projectId: String,
                       in context: ModelContext) -> [SeptenaTask] {
    StoreHealth.fetch(context, FetchDescriptor<TaskEntity>(
      predicate: #Predicate { e in
        e.deletedAt == nil && !e.pendingDeletion
          && e.project == projectId && e.kind == "heading"
      }
    ))
      .sorted { TaskOrder.key($0) != TaskOrder.key($1)
                  ? TaskOrder.key($0) < TaskOrder.key($1) : $0.id < $1.id }
      .map(SeptenaTask.init)
  }

  /// Predicate-narrowed fetch for each list filter. Open smart lists still
  /// post-filter in memory (`isOnToday`, triage-band decay) but start from
  /// ~open rows instead of the full logbook.
  @MainActor
  private static func fetchEntities(for filter: TaskFilter,
                                    limit: Int? = nil,
                                    in context: ModelContext) -> [TaskEntity] {
    switch filter {
    case .recentlyDeleted:
      return StoreHealth.fetch(context, FetchDescriptor<TaskEntity>(
        predicate: #Predicate { $0.deletedAt != nil }
      ))
    case .logbook:
      // The archive can be thousands of rows long. Sort and limit in
      // SwiftData before materializing DTOs; `TaskListView` grows this page on
      // demand instead of rebuilding the whole history on every sync pulse.
      var descriptor = FetchDescriptor<TaskEntity>(
        predicate: #Predicate { e in
          e.deletedAt == nil && !e.pendingDeletion &&
          (e.statusRaw == "done" || e.statusRaw == "cancelled")
        },
        sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
      )
      if let limit { descriptor.fetchLimit = limit }
      return StoreHealth.fetch(context, descriptor)
    case .project(let pid):
      let projectId = pid
      return StoreHealth.fetch(context, FetchDescriptor<TaskEntity>(
        predicate: #Predicate { e in
          e.deletedAt == nil && !e.pendingDeletion && e.project == projectId
        }
      ))
    case .area(let aid):
      let areaId = aid
      return StoreHealth.fetch(context, FetchDescriptor<TaskEntity>(
        predicate: #Predicate { e in
          e.deletedAt == nil && !e.pendingDeletion && e.area == areaId
        }
      ))
    case .today, .triage, .review, .upcoming, .repeating, .unscheduled, .faded:
      return StoreHealth.fetch(context, FetchDescriptor<TaskEntity>(
        predicate: #Predicate { e in
          e.deletedAt == nil && !e.pendingDeletion && e.statusRaw == "open"
        }
      ))
    }
  }

  @MainActor
  static func tasks(in context: ModelContext,
                    filter: TaskFilter,
                    limit: Int? = nil) -> [SeptenaTask] {
    // Manual order is the single source of truth (Things-style): order by
    // `TaskOrder.key` — the explicit `position` once a row has been dragged,
    // otherwise its creation instant. Nothing re-sorts by status, name, or
    // date, so a task stays exactly where the user put it. Sorted in memory
    // (not the FetchDescriptor) because the key is computed, and `id` is the
    // stable tie-break for rows that share a key.
    //
    // Filter BEFORE sorting, and capture each row's (key, id) once during
    // the filter pass. Reading `@Model` properties goes through SwiftData's
    // accessor machinery, so evaluating `TaskOrder.key` inside the sort
    // comparator cost ~4·n·log n model reads over the FULL table on every
    // call — this runs synchronously on the main thread on every sidebar
    // click (TaskListView's `items` getter + `load()`), which is where the
    // macOS click latency came from. Filtering first sorts only the rows
    // the view keeps, over plain tuple fields.
    let rows = fetchEntities(for: filter, limit: limit, in: context)
    let today = SeptenaDate.today
    let dead = DeletedContainerLedger.snapshot()
    let result = rows
      .compactMap { e -> (key: Double, id: String, task: SeptenaTask)? in
        guard let task = convert(e, filter: filter, today: today, dead: dead) else { return nil }
        // Today has its own manual order (#66); every other list uses `position`.
        return (filter == .today ? TaskOrder.todayKey(e) : TaskOrder.key(e), e.id, task)
      }
      .sorted { a, b in a.key != b.key ? a.key < b.key : a.id < b.id }
      .map(\.task)
    // The Completed (logbook) view reads as an archive — most-recently-completed
    // first. The Faded pile shows most-recently-faded first. Every other view
    // keeps manual/creation order (TaskOrder.key).
    if case .logbook = filter {
      return result.sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
    }
    if case .faded = filter {
      return result.sorted {
        let a = $0.fadedAt ?? .distantPast
        let b = $1.fadedAt ?? .distantPast
        return a != b ? a > b : $0.id < $1.id
      }
    }
    return result
  }

  /// One task by id, straight from the store. The by-id read a view needs when
  /// it must NOT depend on whichever list is currently rendered — deciding
  /// whether an inline-create placeholder is still empty, for instance, where
  /// reading a list that has already moved on would mistake "not in this list"
  /// for "has no title".
  @MainActor
  static func task(id: String, in context: ModelContext) -> SeptenaTask? {
    var descriptor = FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return StoreHealth.fetch(context, descriptor).first.map(SeptenaTask.init)
  }

  /// Point-read used to decide whether a scoped local mutation can affect an
  /// already-visible task list. The lookup is limited in SwiftData; matching
  /// reuses the same filter conversion as list rendering so a task moving into
  /// or out of a filter is never missed.
  @MainActor
  static func taskMatches(id: String, filter: TaskFilter,
                          in context: ModelContext) -> Bool {
    var descriptor = FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    guard let entity = StoreHealth.fetch(context, descriptor).first else { return false }
    let today = SeptenaDate.today
    let dead = DeletedContainerLedger.snapshot()
    if filter == .today {
      return convert(entity, filter: .today, today: today, dead: dead) != nil
        || convert(entity, filter: .triage, today: today, dead: dead) != nil
    }
    return convert(entity, filter: filter, today: today, dead: dead) != nil
  }

  /// One row through the filter: nil when the row doesn't belong to `filter`,
  /// the wire DTO when it does. Extracted from the inline closure above so
  /// the (key, id) decoration stays readable.
  @MainActor
  private static func convert(_ e: TaskEntity, filter: TaskFilter, today: String,
                              dead: (areas: Set<String>, projects: Set<String>)) -> SeptenaTask? {
    // Hide rows the user has deleted locally; the outbox drainer will
    // either confirm the deletion (row removed) or resurrect them if
    // the server rejects.
    if e.pendingDeletion { return nil }
    // Headings are project section dividers, not to-dos — they must never
    // surface in ANY task list, count, feed, or badge (only in a project's
    // grouped detail view, which reads them via `headings(inProject:)`). This
    // is the single shared exclusion the plan calls for; every filter funnels
    // through here. See `TaskKind` / `TaskEntity.isHeading`.
    if e.isHeading { return nil }
    // Recently Deleted view: show ONLY soft-deleted rows (the inverse of all
    // other filters). Return early before the `deletedAt != nil` guard below.
    if filter == .recentlyDeleted {
      return e.deletedAt != nil ? SeptenaTask(e) : nil
    }
    // Hide soft-deleted rows (Recently Deleted, docs/RECENTLY_DELETED_SPEC.md).
    // `delete(id:)` stamps `deletedAt` and the spec promises "every read path
    // filters `deletedAt != nil`" — this central list read (TaskListView, every
    // project/area view, and the MCP `tasks_list`) was the one path that didn't,
    // so a deleted task kept rendering and looked un-deletable.
    if e.deletedAt != nil { return nil }
    // Orphaned, awaiting delete: its area / project was deleted (here or on
    // another device) and its own delete has not landed yet. Not Inbox, not
    // any list — the post-pull sweep moves it to Recently Deleted
    // (`DeletedContainerLedger`, `TaskInbox`).
    if DeletedContainerLedger.hides(area: e.area, project: e.project, in: dead) { return nil }
    // Faded pile (`docs/TASK_FADE_SPEC.md` §4): faded open tasks show ONLY in
    // `.faded` and leave every other list (Today, Inbox, Upcoming, Repeating,
    // Anytime, projects, areas).
    if filter == .faded {
      return e.isFaded ? SeptenaTask(e) : nil
    }
    if e.isFaded { return nil }
    switch filter {
    case .today:
      // Today = ratified-and-due. An unratified row that happens to be due
      // today belongs in the triage band above Today, not in it — keep the
      // trusted list clean (see `TaskEntity.isInTriageBand`,
      // docs/TRIAGE_BAND_SPEC.md). The band is rendered from `.triage`.
      return (e.isOnToday && !e.isInTriageBand) ? SeptenaTask(e) : nil
    case .triage:
      // Unratified layer above Today — see `TaskEntity.isInTriageBand`.
      return e.isInTriageBand ? SeptenaTask(e) : nil
    case .review:
      // Agent-worked tasks awaiting the human's verification and acceptance (#87).
      guard e.status == .open, e.conversation.endState == .needsVerify else { return nil }
      return SeptenaTask(e)
    case .upcoming:
      guard e.status == .open, !e.today else { return nil }
      if let s = e.scheduled, s > today { return SeptenaTask(e) }
      if let d = e.deadline, d > today { return SeptenaTask(e) }
      return nil
    case .repeating:
      guard e.status == .open, e.recurrence != nil else { return nil }
      return SeptenaTask(e)
    case .unscheduled:
      guard e.status == .open, !e.today,
            e.scheduled == nil, e.deadline == nil else { return nil }
      return SeptenaTask(e)
    case .logbook:
      // The Logbook archives finished work — both completed and cancelled
      // tasks. Cancelled rows carry `completedAt` (set by the cancel mutator)
      // so they sort into the same most-recent-first archive as done rows.
      guard e.status == .done || e.status == .cancelled else { return nil }
      return SeptenaTask(e)
    case .project(let pid):
      guard e.project == pid else { return nil }
      return SeptenaTask(e)
    case .area(let aid):
      guard e.area == aid else { return nil }
      return SeptenaTask(e)
    case .faded, .recentlyDeleted:
      // Handled by the early-returns above; unreachable here.
      return nil
    }
  }

  @MainActor
  /// Every task except Recently-Deleted ones. Used by aggregates (sidebar
  /// counts, project progress glyphs) and the suggestion engine — none of
  /// which should see trashed rows. Honors the same `deletedAt`/`pendingDeletion`
  /// hiding as `tasks(in:filter:)`; the truly-exhaustive readers (diagnostics,
  /// export, migration) fetch `TaskEntity` directly instead.
  static func allTasks(in context: ModelContext) -> [SeptenaTask] {
    liveTasks(in: context)
  }

  /// Of `ids`, the ones whose local mirror row is now completed. Lets a view
  /// tell a *remote completion* (another device checked it — worth ghost-
  /// checking in place) apart from a row that left a list for some other
  /// reason (deleted, deferred, rescheduled off the filter). Cheap and only
  /// called when a visible open row actually vanished, so a full fetch is fine.
  @MainActor
  static func completedIDs(among ids: Set<String>, in context: ModelContext) -> Set<String> {
    guard !ids.isEmpty else { return [] }
    let rows = StoreHealth.fetch(context, FetchDescriptor<TaskEntity>())
    return Set(rows.compactMap { e in
      (ids.contains(e.id) && e.status == .done && !e.pendingDeletion && e.deletedAt == nil)
        ? e.id : nil
    })
  }

  /// One-line diagnostic of what the local task store currently looks
  /// like — counts by status, today flag, and date-relative buckets.
  /// Logged on app launch so a partial-migration / data-corruption
  /// situation surfaces in the console without needing a database
  /// inspector. Cheap; iterates entities once.
  @MainActor
  static func logTaskStateSummary(in context: ModelContext) {
    let rows = StoreHealth.fetch(context, FetchDescriptor<TaskEntity>())
    let today = SeptenaDate.today
    var open = 0, done = 0, cancelled = 0
    var todayFlag = 0, scheduledLE = 0, dueLE = 0
    var withArea = 0, withProject = 0, pendingDel = 0
    var withSystemFields = 0
    for e in rows {
      switch e.status {
      case .open: open += 1
      case .done: done += 1
      case .cancelled: cancelled += 1
      }
      if e.today { todayFlag += 1 }
      if let s = e.scheduled, s <= today { scheduledLE += 1 }
      if let d = e.deadline, d <= today { dueLE += 1 }
      if e.area != nil { withArea += 1 }
      if e.project != nil { withProject += 1 }
      if e.pendingDeletion { pendingDel += 1 }
      if e.cloudKitSystemFields != nil { withSystemFields += 1 }
    }
    let areas = StoreHealth.fetch(context, FetchDescriptor<AreaEntity>())
    let projects = StoreHealth.fetch(context, FetchDescriptor<ProjectEntity>())
    let areasWithCK = areas.filter { $0.cloudKitSystemFields != nil }.count
    let projectsWithCK = projects.filter { $0.cloudKitSystemFields != nil }.count

    // One-line summary covers the healthy case. Used to be a dozen lines
    // of [TaskState]/[AreaState]/[ProjectState] info; the per-bucket
    // detail wasn't actionable when everything was fine.
    SeptenaLog.info("tasks=\(rows.count) (open=\(open) today=\(todayFlag) overdue=\(dueLE) ck=\(withSystemFields)) areas=\(areas.count)/ck=\(areasWithCK) projects=\(projects.count)/ck=\(projectsWithCK)")

    if pendingDel > 0 {
      SeptenaLog.info("\(pendingDel) tasks pending deletion")
    }

    // Crosswalk is silent in the healthy case (everything resolves).
    // When tasks reference ids that aren't in ProjectEntity / AreaEntity,
    // or projects exist without any tasks, log just the orphans — those
    // are actionable problems to investigate.
    // Dangling project references and the stale empty `seed-project` artifact
    // are healed at startup by `SeptenaServices.reconcileProjectGraph()` (which
    // logs the action it takes), so they're intentionally not warned about
    // here — this diagnostic stays read-only and quiet in the steady state.
    // Area references have no remediation path yet, so a dangling area id is
    // still worth surfacing.
    let taskAreaIds = Set(rows.compactMap { $0.area })
    let areaIds = Set(areas.map { $0.id })
    let orphanedTaskAreaIds = taskAreaIds.subtracting(areaIds)

    if !orphanedTaskAreaIds.isEmpty {
      SeptenaLog.info("[Crosswalk] ⚠️ tasks reference area ids not in AreaEntity: \(orphanedTaskAreaIds.sorted())")
    }
  }

  /// Count of open tasks whose hard deadline is today or in the past.
  /// Drives the Today sidebar's red badge — matches the in-list red date
  /// treatment exactly (only `due ≤ today` counts as overdue; scheduled-past
  /// is residence, not lateness).
  @MainActor
  static func overdueCount(in context: ModelContext) -> Int {
    // Must match `SeptenaTask.isOverdue` exactly: open + deadline <= today
    // (a deadline of today counts as overdue), and scheduled dates never
    // count. Keep these two definitions in lockstep.
    let today = SeptenaDate.today
    let rows = StoreHealth.fetch(context, FetchDescriptor<TaskEntity>())
    return rows.reduce(0) { acc, e in
      guard e.deletedAt == nil, !e.pendingDeletion,
            e.status == .open, !e.isFaded, let d = e.deadline, d <= today else { return acc }
      return acc + 1
    }
  }

  @MainActor
  static func areas(in context: ModelContext) -> [Area] {
    let descriptor = FetchDescriptor<AreaEntity>(sortBy: [SortDescriptor(\.title)])
    let rows = StoreHealth.fetch(context, descriptor)
    return rows.map(Area.init)
  }

  @MainActor
  static func projects(in context: ModelContext) -> [Project] {
    let descriptor = FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.title)])
    let rows = StoreHealth.fetch(context, descriptor)
    return rows.map(Project.init)
  }
}

// MARK: - StructureCache (process-wide areas/projects memo)

/// Areas / projects are read eagerly by `SidebarRootView.init` and
/// `TaskListView.init` to seed first-paint @State — and SwiftUI re-runs those
/// inits on every parent render, discarding the fetched values for
/// already-installed views. This memo makes the repeat constructions free:
/// the first read per process fetches, later ones return the cached snapshot,
/// and any structure change (local mutation or CloudKit batch — both post
/// `.septenaStructureChanged`) drops the cache so the next read is fresh.
///
/// Snapshots are returned in sidebar order (`TaskStructureOrder`) so every
/// consumer — sidebar, move pickers, grouped list headers, MCP list endpoints —
/// shares one ordering without re-sorting at each call site.
@MainActor
enum StructureCache {
  private static var cached: (areas: [Area], projects: [Project])?
  private static var observerInstalled = false

  static func snapshot(in context: ModelContext) -> (areas: [Area], projects: [Project]) {
    installObserverIfNeeded()
    if let cached { return cached }
    let token = StoreHealth.readToken()
    let snap = (
      areas: TaskStructureOrder.orderedAreas(LocalCache.areas(in: context)),
      projects: TaskStructureOrder.orderedProjects(LocalCache.projects(in: context))
    )
    // A failed read looks exactly like an empty store. Memoizing THAT would
    // pin an empty sidebar for the rest of the process, because only a
    // structure change drops the cache — and no structure change is coming.
    // Return the empty snapshot for this render, keep the cache unset, and
    // let the next call try the store again.
    guard !StoreHealth.readsFailed(since: token) else { return snap }
    cached = snap
    return snap
  }

  private static func installObserverIfNeeded() {
    guard !observerInstalled else { return }
    observerInstalled = true
    NotificationCenter.default.addObserver(
      forName: .septenaStructureChanged, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { cached = nil }
    }
  }
}

