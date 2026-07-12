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
       heading: String? = nil) {
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
  }

  /// True when this row is a project section divider, not a to-do. The single
  /// read point — every feed/count/list gates on this so headings never leak
  /// out of a project's detail view (see `TaskKind`).
  var isHeading: Bool { kind == TaskKind.heading }

  var status: TaskStatus {
    get { TaskStatus(rawValue: statusRaw) ?? .open }
    set { statusRaw = newValue.rawValue }
  }

  /// Single definition of "is this open task on the Today list."
  ///
  /// Today is currently a *union* of three signals: an explicit `today` pin,
  /// a scheduled ("When") date that has arrived, or a deadline that has
  /// arrived. Step 4 of the due/when simplification will collapse this to
  /// just `scheduled == today` and retire the `today` flag — at which point
  /// only the body of this one property changes. Centralized here so the
  /// `.today` filter (and anything else) reads from a single source.
  var isOnToday: Bool {
    guard status == .open, !isHeading else { return false }
    if today { return true }
    if let s = scheduled, s <= SeptenaDate.today { return true }
    if let d = deadline, d <= SeptenaDate.today { return true }
    return false
  }

  /// Single definition of "is this open task in the triage band" — the
  /// *unratified* layer rendered above Today (see `docs/TRIAGE_BAND_SPEC.md`).
  /// The divider is ratification, not date: an unacknowledged agent proposal
  /// still inside its freshness window (regardless of any date/project it
  /// carries), or a loose human capture with no disposition at all (the
  /// classic Inbox). A row leaves the band on any ratification — a disposition,
  /// an `acknowledge`, or (agent rows only) cue decay. Mirror of
  /// `SeptenaTask.isInTriageBand`; keep the two in lockstep. The agent arm
  /// reuses the same predicate as `showsAgentCue` so band == cue for agent rows.
  var isInTriageBand: Bool {
    guard status == .open, !isHeading else { return false }
    if source == TaskSource.mcp {
      guard acknowledgedAt == nil, createdAt != .distantPast else { return false }
      return Date().timeIntervalSince(createdAt) < AgentCue.decayWindow
    }
    return scheduled == nil && deadline == nil
        && project == nil && area == nil && !today
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

@Model
final class HabitDefinitionEntity {
  @Attribute(.unique) var id: String
  var title: String
  var emoji: String?
  var bucket: String
  var sortIndex: Int
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as tasks/projects/areas.
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       emoji: String? = nil,
       bucket: String,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.emoji = emoji
    self.bucket = bucket
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class HabitDayStateEntity {
  @Attribute(.unique) var id: String
  /// Canonical UTC instant of the event. Derived from `date`/`time` via
  /// `EventTimestamp` on write; `.distantPast` only on pre-migration rows.
  var occurredAt: Date = Date.distantPast
  var date: String
  var habitID: String
  var done: Bool
  var skipped: Bool
  var note: String?
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as tasks/projects/areas.
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       habitID: String,
       done: Bool,
       skipped: Bool,
       note: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.habitID = habitID
    self.done = done
    self.skipped = skipped
    self.note = note
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class SupplementDefinitionEntity {
  @Attribute(.unique) var id: String
  var title: String
  var emoji: String?
  /// Optional time-of-day bucket ("morning" / "afternoon" / "evening").
  /// `nil` means "anytime" — the supplement isn't tied to a slot and shows
  /// all day on the Next feed (the default, and the pre-bucketing behavior).
  /// A set bucket scopes it to that window onward. Lightweight migration:
  /// existing rows read back as `nil`.
  var bucket: String?
  var sortIndex: Int
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as tasks/projects/areas.
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       emoji: String? = nil,
       bucket: String? = nil,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.emoji = emoji
    self.bucket = bucket
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class SupplementDayStateEntity {
  @Attribute(.unique) var id: String
  /// Canonical UTC instant of the event. Derived from `date`/`time` via
  /// `EventTimestamp` on write; `.distantPast` only on pre-migration rows.
  var occurredAt: Date = Date.distantPast
  var date: String
  var supplementID: String
  var done: Bool
  /// User explicitly marked the supplement not-needed today (mirrors habits).
  /// Default keeps SwiftData lightweight migration safe — existing rows read
  /// back as `false`. A skipped row is `done == false && skipped == true`.
  var skipped: Bool = false
  var note: String?
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as tasks/projects/areas.
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       supplementID: String,
       done: Bool,
       skipped: Bool = false,
       note: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.supplementID = supplementID
    self.done = done
    self.skipped = skipped
    self.note = note
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class GoalEntity {
  @Attribute(.unique) var id: String
  var text: String
  var sections: [String]
  var created: String      // YYYY-MM-DD
  var sortIndex: Int
  var updatedAt: Date
  /// CKRecord system-fields blob. Same contract as tasks/projects/areas.
  var cloudKitSystemFields: Data?

  // Optional measurement attachment. When all four are non-nil, the goal
  // becomes measurable: its UI renders progress against a target derived
  // from data the user already logs in other sections. nil on every
  // existing row (free-text goals stay free-text).
  var metricKey: String?           // e.g. "training.session_count"
  var metricWindow: String?        // e.g. "calendarWeek"
  var metricComparator: String?    // "gte" | "lte" | "eq" | "range"
  var metricTarget: Double?
  /// Upper bound for a `range` ("between") comparator — `metricTarget` is the
  /// lower bound, this the upper, and the goal is met when the current value
  /// sits inside [target, upper]. Nil for one-sided comparators (unchanged
  /// behavior). Additive, like `metricBaseline`.
  var metricTargetUpper: Double?
  /// Optional starting value the user entered when the goal was created.
  /// Used for "latest"-window metrics (body weight, body fat, muscle %) so
  /// the progress bar can show distance-traveled from baseline toward
  /// target rather than empty-until-crossed. nil for count/sum metrics
  /// whose natural starting point is 0 (the window itself defines a
  /// baseline).
  var metricBaseline: Double?

  /// Pinned to the top of the Week dashboard as a full-width tile. Default
  /// `false` (every existing row stays off the dashboard) — MUST have a
  /// default so SwiftData's lightweight migration can backfill on-disk rows
  /// without a store-migration crash. Stored in CloudKit `reservedInt1`.
  var pinned: Bool = false
  /// Optional dashboard accent override. Nil inherits the attached section's
  /// color. Stored in CloudKit's reservedString1 slot.
  var color: String? = nil

  init(id: String,
       text: String,
       sections: [String] = [],
       created: String,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil,
       metricKey: String? = nil,
       metricWindow: String? = nil,
       metricComparator: String? = nil,
       metricTarget: Double? = nil,
       metricBaseline: Double? = nil,
       metricTargetUpper: Double? = nil,
       pinned: Bool = false,
       color: String? = nil) {
    self.id = id
    self.text = text
    self.sections = sections
    self.created = created
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
    self.metricKey = metricKey
    self.metricWindow = metricWindow
    self.metricComparator = metricComparator
    self.metricTarget = metricTarget
    self.metricBaseline = metricBaseline
    self.metricTargetUpper = metricTargetUpper
    self.pinned = pinned
    self.color = color
  }
}

/// A latched achievement event — a goal rung crossed, a training PR, a streak
/// milestone. Rows are written exactly once per (scope, rungKey) and never
/// revoked: the deterministic `id` ("\(scope)|\(rungKey)") makes detection
/// idempotent across devices, re-syncs, and re-evaluation, regardless of how
/// often the underlying data is rewritten. `celebrated == false` rows are
/// silent grants (grandfathered history / skipped intermediate rungs); only
/// rows detected as a live crossing celebrate, and only on the device that
/// detected them — CloudKit-fetched rows fold in quietly.
@Model
final class GoalMilestoneEntity {
  @Attribute(.unique) var id: String   // deterministic: "<scope>|<rungKey>"
  var goalID: String?                  // owning goal, nil for goal-less scopes (PR/XP/streak)
  var scope: String                    // "goal:<id>" | "exercise:<slug>" | "habit:<id>" | "training.volume"
  var kind: String                     // "rung" | "pr" | "xp" | "streak"
  var rungKey: String                  // "kg:78" | "pr:100" | "xp:25000" | "streak:30" | "halfway" | "target" | "held30"
  var label: String                    // user-facing, resolved at detection time
  var value: Double                    // the crossed value (smoothed kg, PR kg, streak days…)
  var unit: String = ""                // unit discriminator for `value`: "kg" | "%" | "tonnes" | "days" | "" — drives display-time unit rendering (kg→lb) so labels aren't frozen. Stored in CloudKit reservedString1. MUST have a default so lightweight migration can backfill existing on-disk rows (else 134110 store-migration crash).
  var occurredAt: Date                 // when the crossing was detected
  var celebrated: Bool                 // false = granted silently, never animates
  var presentedAt: Date?               // when the celebration was shown (queued path); syncs so one device's showing silences the rest
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       goalID: String? = nil,
       scope: String,
       kind: String,
       rungKey: String,
       label: String,
       value: Double,
       unit: String = "",
       occurredAt: Date,
       celebrated: Bool,
       presentedAt: Date? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.goalID = goalID
    self.scope = scope
    self.kind = kind
    self.rungKey = rungKey
    self.label = label
    self.value = value
    self.unit = unit
    self.occurredAt = occurredAt
    self.celebrated = celebrated
    self.presentedAt = presentedAt
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

/// Per-coach voice settings — the user's tone dials for one coach. `id` is the
/// coach key (CoachDomain rawValue); one row per coach. Dial values are stored
/// as raw strings so SeptenaCore stays free of the app-side voice enums. Syncs
/// via CKSyncEngine like every other entity (record type "CoachVoice").
@Model
final class CoachVoiceEntity {
  @Attribute(.unique) var id: String   // coach key, e.g. "training"
  var warmth: String
  var brevity: String
  var challenge: String
  var formality: String
  var note: String
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       warmth: String,
       brevity: String,
       challenge: String,
       formality: String,
       note: String = "",
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.warmth = warmth
    self.brevity = brevity
    self.challenge = challenge
    self.formality = formality
    self.note = note
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

/// One line of a coach conversation. Flat per-message rows keyed by coach
/// (`coachKey` = CoachDomain rawValue), ordered by `sortIndex`; the whole
/// transcript is the rows for a coach. Syncs via CKSyncEngine (record type
/// "CoachMessage") so the relationship persists across launches and devices.
@Model
final class CoachMessageEntity {
  @Attribute(.unique) var id: String
  var coachKey: String
  var role: String      // "coach" | "user"
  var text: String
  var createdAt: Date
  var sortIndex: Int
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       coachKey: String,
       role: String,
       text: String,
       createdAt: Date = .now,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.coachKey = coachKey
    self.role = role
    self.text = text
    self.createdAt = createdAt
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class ChoreSnapshotEntity {
  @Attribute(.unique) var id: String
  var title: String
  var emoji: String?
  var dueDate: String?
  var lastCompleted: String?
  var lastCompletedTime: String?
  var daysOverdue: Int
  var cadenceDays: Int?
  var sortIndex: Int
  var updatedAt: Date

  init(id: String,
       title: String,
       emoji: String? = nil,
       dueDate: String? = nil,
       lastCompleted: String? = nil,
       lastCompletedTime: String? = nil,
       daysOverdue: Int = 0,
       cadenceDays: Int? = nil,
       sortIndex: Int = 0,
       updatedAt: Date = .now) {
    self.id = id
    self.title = title
    self.emoji = emoji
    self.dueDate = dueDate
    self.lastCompleted = lastCompleted
    self.lastCompletedTime = lastCompletedTime
    self.daysOverdue = daysOverdue
    self.cadenceDays = cadenceDays
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
  }
}

@Model
final class ChoreDefinitionEntity {
  @Attribute(.unique) var id: String
  var title: String
  var emoji: String?
  var cadenceDays: Int
  var sortIndex: Int
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       emoji: String? = nil,
       cadenceDays: Int,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.emoji = emoji
    self.cadenceDays = cadenceDays
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class ChoreEventEntity {
  @Attribute(.unique) var id: String
  /// Canonical UTC instant of the event. Derived from `date`/`time` via
  /// `EventTimestamp` on write; `.distantPast` only on pre-migration rows.
  var occurredAt: Date = Date.distantPast
  var choreID: String
  var action: String
  var date: String
  var newDueDate: String?
  var reason: String?
  var note: String?
  var sortKey: String
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       choreID: String,
       action: String,
       date: String,
       newDueDate: String? = nil,
       reason: String? = nil,
       note: String? = nil,
       sortKey: String,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.choreID = choreID
    self.action = action
    self.date = date
    self.newDueDate = newDueDate
    self.reason = reason
    self.note = note
    self.sortKey = sortKey
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class GutEventEntity {
  @Attribute(.unique) var id: String
  /// Canonical UTC instant of the event. Derived from `date`/`time` via
  /// `EventTimestamp` on write; `.distantPast` only on pre-migration rows.
  var occurredAt: Date = Date.distantPast
  var date: String
  var bristol: Int
  var blood: Int
  var volume: String?
  var discomfortLevel: String?
  var discomfortStart: String?
  var discomfortEnd: String?
  var note: String?
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       bristol: Int,
       blood: Int = 0,
       volume: String? = nil,
       discomfortLevel: String? = nil,
       discomfortStart: String? = nil,
       discomfortEnd: String? = nil,
       note: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.bristol = bristol
    self.blood = blood
    self.volume = volume
    self.discomfortLevel = discomfortLevel
    self.discomfortStart = discomfortStart
    self.discomfortEnd = discomfortEnd
    self.note = note
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class MoodEventEntity {
  @Attribute(.unique) var id: String
  /// Canonical UTC instant of the event. Derived from `date`/`time` via
  /// `EventTimestamp` on write; `.distantPast` only on pre-migration rows.
  var occurredAt: Date = Date.distantPast
  /// `YYYY-MM-DD` of the logged moment, in local time. Indexed for fast
  /// day-scoped queries — mirrors the other logged-event entities.
  var date: String
  /// Bucket derived from `occurredAt` at write: morning (<12), afternoon (12–17),
  /// evening (≥17). Stored so dashboard heatmaps can slice without re-parsing.
  var bucket: String
  /// One of `hap | han | lan | lap` — the Russell circumplex quadrant.
  var quadrant: String
  /// Sub-position within the quadrant, 1...3. Higher = more activated.
  var arousal: Int
  /// Sub-position within the quadrant, 1...3. Higher = more pleasant.
  var valence: Int
  /// The specific emotion label from `MoodCatalog` (e.g. "Upbeat").
  /// Stored as a string so renaming words later doesn't migrate the DB —
  /// the (quadrant, arousal, valence) triple is the canonical identity.
  var emotion: String
  var note: String?
  var updatedAt: Date
  var cloudKitSystemFields: Data?
  /// UUID string of the HKStateOfMind sample written to HealthKit when this
  /// entry was logged. Nil for entries created before this field existed or
  /// when HK is unavailable. Used to delete / replace the sample on
  /// updateEntry / deleteEntry so Health.app doesn't accumulate orphans.
  var hkSampleID: String?

  init(id: String,
       date: String,
       bucket: String,
       quadrant: String,
       arousal: Int,
       valence: Int,
       emotion: String,
       note: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.bucket = bucket
    self.quadrant = quadrant
    self.arousal = arousal
    self.valence = valence
    self.emotion = emotion
    self.note = note
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class SymptomDefinitionEntity {
  @Attribute(.unique) var id: String
  var title: String
  var emoji: String?
  var bodySystem: String?
  var defaultBodyRegion: String?
  var sortIndex: Int
  var archived: Bool
  var createdAt: Date
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       emoji: String? = nil,
       bodySystem: String? = nil,
       defaultBodyRegion: String? = nil,
       sortIndex: Int = 0,
       archived: Bool = false,
       createdAt: Date = .now,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.emoji = emoji
    self.bodySystem = bodySystem
    self.defaultBodyRegion = defaultBodyRegion
    self.sortIndex = sortIndex
    self.archived = archived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class SymptomEventEntity {
  @Attribute(.unique) var id: String
  var occurredAt: Date = Date.distantPast
  var date: String
  var symptomID: String
  var severity: Int
  var durationMinutes: Int?
  var bodyRegion: String?
  var side: String?
  var quality: String?
  var triggerNote: String?
  var reliefNote: String?
  var note: String?
  var source: String?
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       symptomID: String,
       severity: Int,
       durationMinutes: Int? = nil,
       bodyRegion: String? = nil,
       side: String? = nil,
       quality: String? = nil,
       triggerNote: String? = nil,
       reliefNote: String? = nil,
       note: String? = nil,
       source: String? = "manual",
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.symptomID = symptomID
    self.severity = severity
    self.durationMinutes = durationMinutes
    self.bodyRegion = bodyRegion
    self.side = side
    self.quality = quality
    self.triggerNote = triggerNote
    self.reliefNote = reliefNote
    self.note = note
    self.source = source
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class MedicationDefinitionEntity {
  @Attribute(.unique) var id: String
  var title: String
  var genericName: String?
  var form: String?
  var route: String?
  var strengthValue: Double?
  var strengthUnit: String?
  var defaultDoseValue: Double?
  var defaultDoseUnit: String?
  var bucket: String?
  var scheduleKind: String?
  var targetDosesPerDay: Int?
  var instructions: String?
  var sortIndex: Int
  var archived: Bool
  var createdAt: Date
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       title: String,
       genericName: String? = nil,
       form: String? = nil,
       route: String? = nil,
       strengthValue: Double? = nil,
       strengthUnit: String? = nil,
       defaultDoseValue: Double? = nil,
       defaultDoseUnit: String? = nil,
       bucket: String? = nil,
       scheduleKind: String? = "daily",
       targetDosesPerDay: Int? = 1,
       instructions: String? = nil,
       sortIndex: Int = 0,
       archived: Bool = false,
       createdAt: Date = .now,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.title = title
    self.genericName = genericName
    self.form = form
    self.route = route
    self.strengthValue = strengthValue
    self.strengthUnit = strengthUnit
    self.defaultDoseValue = defaultDoseValue
    self.defaultDoseUnit = defaultDoseUnit
    self.bucket = bucket
    self.scheduleKind = scheduleKind
    self.targetDosesPerDay = targetDosesPerDay
    self.instructions = instructions
    self.sortIndex = sortIndex
    self.archived = archived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class MedicationDoseEventEntity {
  @Attribute(.unique) var id: String
  var occurredAt: Date = Date.distantPast
  var date: String
  var medicationID: String
  var status: String
  var doseValue: Double?
  var doseUnit: String?
  var reason: String?
  var effectNote: String?
  var sideEffectNote: String?
  var source: String?
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       medicationID: String,
       status: String = "taken",
       doseValue: Double? = nil,
       doseUnit: String? = nil,
       reason: String? = nil,
       effectNote: String? = nil,
       sideEffectNote: String? = nil,
       source: String? = "manual",
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.medicationID = medicationID
    self.status = status
    self.doseValue = doseValue
    self.doseUnit = doseUnit
    self.reason = reason
    self.effectNote = effectNote
    self.sideEffectNote = sideEffectNote
    self.source = source
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

// MARK: - Intake (consumables generalization)
//
// The substance-free successor to the per-substance consumable entities: one host
// section (`intake`) with user-defined `IntakeKindEntity` rows, each its own
// item catalog (`IntakeItemEntity`) and event stream (`IntakeEventEntity`).
// CloudKit record types are additive, so these coexist with the legacy types
// until phase 4. `IntakeMethodRow` + the pure migration logic live in the
// Foundation-only IntakeModel.swift. See docs/CONSUMABLES_PLAN.md.

@Model
final class IntakeKindEntity {
  @Attribute(.unique) var id: String   // opaque "ik-<uuid>", never the name
  var name: String
  var symbol: String                   // SF Symbol — the kind/type always carries one
  var color: String                    // hex/hsl token (per-kind, not SectionTheme)
  var sortIndex: Int
  var unit: String?                    // "g" | "mg" | "ml" | nil
  var doseStyle: String                // "amount" | "count" | "both" | "none"
  var countNoun: String?               // "hit" | "cup" | "puff"
  var containerNoun: String?           // "capsule" | "pack" | nil
  var containerCap: Int?               // nil = no container model
  var catalogNoun: String?             // "Beans" | "Strains" | nil
  var flourish: String                 // motion token ("bloom" | "ripple" | …)
  var metricMode: String               // "countEvents" | "sumAmount"
  // Property-level default (not just the init default) so SwiftData lightweight
  // migration can backfill existing IntakeKind rows when this field is added —
  // same reason `occurredAt` carries one. Without it, adding a non-optional
  // property to an entity that already has rows fails ModelContainer init.
  var objective: String = "log"        // "log" | "limit" | "reduce" | "quit"
  var methodsJSON: String              // encoded [IntakeMethodRow]
  var templateID: String?
  var archivedAt: Date?                // hide-don't-delete, mirrors sections
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       name: String,
       symbol: String = "circle",
       color: String = "",
       sortIndex: Int = 0,
       unit: String? = nil,
       doseStyle: String = "none",
       countNoun: String? = nil,
       containerNoun: String? = nil,
       containerCap: Int? = nil,
       catalogNoun: String? = nil,
       flourish: String = "bloom",
       metricMode: String = "countEvents",
       objective: String = "log",
       methodsJSON: String = "[]",
       templateID: String? = nil,
       archivedAt: Date? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.color = color
    self.sortIndex = sortIndex
    self.unit = unit
    self.doseStyle = doseStyle
    self.countNoun = countNoun
    self.containerNoun = containerNoun
    self.containerCap = containerCap
    self.catalogNoun = catalogNoun
    self.flourish = flourish
    self.metricMode = metricMode
    self.objective = objective
    self.methodsJSON = methodsJSON
    self.templateID = templateID
    self.archivedAt = archivedAt
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class IntakeItemEntity {
  @Attribute(.unique) var id: String
  var kindID: String
  var name: String
  /// Optional Tier-3 user glyph (DesignSpec §2) — a bean/strain/variety can
  /// carry its own emoji. Nil ⇒ no glyph (text only). Mirrors `Area.emoji`.
  var emoji: String?
  var sortIndex: Int
  var archivedAt: Date?
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       kindID: String,
       name: String,
       emoji: String? = nil,
       sortIndex: Int = 0,
       archivedAt: Date? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.kindID = kindID
    self.name = name
    self.emoji = emoji
    self.sortIndex = sortIndex
    self.archivedAt = archivedAt
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class IntakeEventEntity {
  @Attribute(.unique) var id: String
  /// Canonical UTC instant. Derived from `date`/`time` via `EventTimestamp` on
  /// write; `.distantPast` only on pre-migration rows.
  var occurredAt: Date = Date.distantPast
  var kindID: String
  var date: String
  var method: String   // stable token from the kind's method rows
  var itemID: String?  // → IntakeItemEntity
  var amount: Double?  // in kind.unit
  var count: Int?      // hits/uses; container math reads this
  var note: String?
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       kindID: String,
       date: String,
       method: String,
       itemID: String? = nil,
       amount: Double? = nil,
       count: Int? = nil,
       note: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.kindID = kindID
    self.date = date
    self.method = method
    self.itemID = itemID
    self.amount = amount
    self.count = count
    self.note = note
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

extension IntakeKindEntity {
  /// The method rows, decoded from / encoded to `methodsJSON`. SwiftData ignores
  /// this computed accessor (only `methodsJSON` is the stored column).
  var methods: [IntakeMethodRow] {
    get { (try? JSONDecoder().decode([IntakeMethodRow].self, from: Data(methodsJSON.utf8))) ?? [] }
    set {
      methodsJSON = (try? JSONEncoder().encode(newValue))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
  }
}

@Model
final class GroceryItemEntity {
  @Attribute(.unique) var id: String
  var name: String
  var category: String
  var emoji: String
  var low: Bool
  var lastBought: String?
  var sortIndex: Int
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       name: String,
       category: String,
       emoji: String = "",
       low: Bool = false,
       lastBought: String? = nil,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.name = name
    self.category = category
    self.emoji = emoji
    self.low = low
    self.lastBought = lastBought
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class GroceryCategoryEntity {
  @Attribute(.unique) var id: String
  var name: String
  var sortIndex: Int
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       name: String,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.name = name
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class ExerciseEntryEntity {
  @Attribute(.unique) var id: String
  /// Canonical UTC instant of the event. Derived from `date`/`time` via
  /// `EventTimestamp` on write; `.distantPast` only on pre-migration rows.
  var occurredAt: Date = Date.distantPast
  var date: String           // YYYY-MM-DD
  var sessionType: String    // upper|lower|cardio|yoga|...
  var exercise: String       // canonical exercise name
  var weight: Double?
  var sets: String?          // int or "AMRAP"
  var reps: String?          // int or string
  var difficulty: String?
  var durationMin: Double?
  var distanceM: Double?
  var level: Double?
  var note: String?
  var concludedAt: String?   // ISO8601
  var loggedAt: String?      // ISO8601
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       sessionType: String,
       exercise: String,
       weight: Double? = nil,
       sets: String? = nil,
       reps: String? = nil,
       difficulty: String? = nil,
       durationMin: Double? = nil,
       distanceM: Double? = nil,
       level: Double? = nil,
       note: String? = nil,
       concludedAt: String? = nil,
       loggedAt: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.sessionType = sessionType
    self.exercise = exercise
    self.weight = weight
    self.sets = sets
    self.reps = reps
    self.difficulty = difficulty
    self.durationMin = durationMin
    self.distanceM = distanceM
    self.level = level
    self.note = note
    self.concludedAt = concludedAt
    self.loggedAt = loggedAt
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class ExerciseDefinitionEntity {
  @Attribute(.unique) var id: String   // slug, e.g. "chest-press"
  var name: String
  var type: String                     // strength|cardio|mobility|core
  var subgroup: String?                // free-form: "push", "pull", "upper"
  var aliases: [String]
  var primaryMuscle: String?           // Muscle.rawValue, nil until backfill
  // SwiftData lightweight migration reads the property initializer here as
  // the storage-level default for existing rows; without it the new
  // mandatory attribute trips a 134110 store-load failure.
  var secondaryMuscles: [String] = []
  var archived: Bool = false
  var sortIndex: Int
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       name: String,
       type: String,
       subgroup: String? = nil,
       aliases: [String] = [],
       primaryMuscle: String? = nil,
       secondaryMuscles: [String] = [],
       archived: Bool = false,
       sortIndex: Int = 0,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.name = name
    self.type = type
    self.subgroup = subgroup
    self.aliases = aliases
    self.primaryMuscle = primaryMuscle
    self.secondaryMuscles = secondaryMuscles
    self.archived = archived
    self.sortIndex = sortIndex
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class SessionTypeEntity {
  @Attribute(.unique) var id: String   // "upper", "lower", "cardio", ...
  var label: String
  var emoji: String?
  var exercises: [String]              // canonical exercise list
  var archived: Bool = false
  var sortIndex: Int
  /// Routine category — drives the draft session's input UI and the
  /// quickadd-menu icon. Stored as `SessionKind.rawValue`. Optional so
  /// legacy records (from before this field existed) continue to load;
  /// they fall back to `SessionKind.defaulted(for: id)` at read time.
  var kindRaw: String?
  var updatedAt: Date
  var cloudKitSystemFields: Data?

  init(id: String,
       label: String,
       emoji: String? = nil,
       exercises: [String] = [],
       archived: Bool = false,
       sortIndex: Int = 0,
       kindRaw: String? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.label = label
    self.emoji = emoji
    self.exercises = exercises
    self.archived = archived
    self.sortIndex = sortIndex
    self.kindRaw = kindRaw
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

// MARK: - Nutrition entities

@Model
final class NutritionEntryEntity {
  @Attribute(.unique) var id: String
  var loggedAt: Date
  var updatedAt: Date
  var emoji: String?
  var foods: String         // \n-joined list
  var ingredients: String?  // \n-joined list; nil when empty
  var note: String?
  var mealType: String?     // breakfast|lunch|dinner|snack
  var source: String?       // manual|import|barcode|mcp

  // Macros (g) — protein/fat/carbs are always present; rest are optional
  var proteinG: Double
  var fatG: Double
  var carbsG: Double
  var fiberG: Double?
  var sugarG: Double?
  var saturatedFatG: Double?
  var alcoholG: Double?

  // Other nutrients
  var kcal: Double?         // user override; falls back to 4P+9F+4C+7A on read
  var sodiumMg: Double?
  var cholesterolMg: Double?
  var potassiumMg: Double?
  var waterMl: Double?

  /// PHAsset.localIdentifier for an attached photo from the user's Photos
  /// library. Reference-only — image bytes stay in Photos. Local identifiers
  /// are device-local, so the photo resolves only on the device that picked
  /// it; cross-device resolution would require also storing PHCloudIdentifier.
  var photoAssetID: String?

  var cloudKitSystemFields: Data?

  init(id: String,
       loggedAt: Date = .now,
       updatedAt: Date = .now,
       emoji: String? = nil,
       foods: String = "",
       ingredients: String? = nil,
       note: String? = nil,
       mealType: String? = nil,
       source: String? = nil,
       proteinG: Double = 0,
       fatG: Double = 0,
       carbsG: Double = 0,
       fiberG: Double? = nil,
       sugarG: Double? = nil,
       saturatedFatG: Double? = nil,
       alcoholG: Double? = nil,
       kcal: Double? = nil,
       sodiumMg: Double? = nil,
       cholesterolMg: Double? = nil,
       potassiumMg: Double? = nil,
       waterMl: Double? = nil,
       photoAssetID: String? = nil,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.loggedAt = loggedAt
    self.updatedAt = updatedAt
    self.emoji = emoji
    self.foods = foods
    self.ingredients = ingredients
    self.note = note
    self.mealType = mealType
    self.source = source
    self.proteinG = proteinG
    self.fatG = fatG
    self.carbsG = carbsG
    self.fiberG = fiberG
    self.sugarG = sugarG
    self.saturatedFatG = saturatedFatG
    self.alcoholG = alcoholG
    self.kcal = kcal
    self.sodiumMg = sodiumMg
    self.cholesterolMg = cholesterolMg
    self.potassiumMg = potassiumMg
    self.waterMl = waterMl
    self.photoAssetID = photoAssetID
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

@Model
final class NutritionDailySummaryEntity {
  @Attribute(.unique) var id: String    // YYYY-MM-DD in user TZ at compute time
  var date: String                       // same
  var entryCount: Int
  var firstLoggedAt: Date?               // earliest entry that day — fasting window anchor
  var lastLoggedAt: Date?                // latest entry that day
  var computedAt: Date

  // Totals — nil when no entry that day reported the field
  var kcal: Double?
  var proteinG: Double?
  var fatG: Double?
  var carbsG: Double?
  var fiberG: Double?
  var sugarG: Double?
  var saturatedFatG: Double?
  var alcoholG: Double?
  var sodiumMg: Double?
  var cholesterolMg: Double?
  var potassiumMg: Double?
  var waterMl: Double?

  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       entryCount: Int = 0,
       firstLoggedAt: Date? = nil,
       lastLoggedAt: Date? = nil,
       computedAt: Date = .now,
       kcal: Double? = nil,
       proteinG: Double? = nil,
       fatG: Double? = nil,
       carbsG: Double? = nil,
       fiberG: Double? = nil,
       sugarG: Double? = nil,
       saturatedFatG: Double? = nil,
       alcoholG: Double? = nil,
       sodiumMg: Double? = nil,
       cholesterolMg: Double? = nil,
       potassiumMg: Double? = nil,
       waterMl: Double? = nil,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.entryCount = entryCount
    self.firstLoggedAt = firstLoggedAt
    self.lastLoggedAt = lastLoggedAt
    self.computedAt = computedAt
    self.kcal = kcal
    self.proteinG = proteinG
    self.fatG = fatG
    self.carbsG = carbsG
    self.fiberG = fiberG
    self.sugarG = sugarG
    self.saturatedFatG = saturatedFatG
    self.alcoholG = alcoholG
    self.sodiumMg = sodiumMg
    self.cholesterolMg = cholesterolMg
    self.potassiumMg = potassiumMg
    self.waterMl = waterMl
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

/// One read-once daily summary of HealthKit movement (steps / active energy /
/// exercise minutes). The day string IS the identity, so the iPhone and iPad
/// (both fed by the same iCloud Health sync) converge on one record per day
/// rather than duplicating. Past days are effectively immutable, which is what
/// makes this worth persisting + syncing: ingest each day from HealthKit once
/// and every surface — including macOS, which has no HealthKit — reads it back.
@Model
final class ActivityDayEntity {
  @Attribute(.unique) var id: String   // yyyy-MM-dd in the device TZ at ingest
  var date: String                      // same string, kept for symmetry/query
  var stepCount: Int?                   // nil when HealthKit had no step data
  var activeKcal: Double?
  var exerciseMinutes: Int?
  var updatedAt: Date                   // only moves when a value actually changed
  var cloudKitSystemFields: Data?

  init(id: String,
       date: String,
       stepCount: Int? = nil,
       activeKcal: Double? = nil,
       exerciseMinutes: Int? = nil,
       updatedAt: Date = .now,
       cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.date = date
    self.stepCount = stepCount
    self.activeKcal = activeKcal
    self.exerciseMinutes = exerciseMinutes
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
      updatedAt: e.updatedAt,
      deletedAt: e.deletedAt,
      source: e.source,
      sourceClient: e.sourceClient,
      acknowledgedAt: e.acknowledgedAt,
      createdAt: e.createdAt,
      position: e.position,
      kind: e.kind,
      heading: e.heading,
      conversation: e.conversation
    )
  }

  /// Manual-order sort key — see `TaskOrder.key`.
  var orderKey: Double { TaskOrder.key(position: position, createdAt: createdAt) }
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

  /// A position that sorts above every live task, so a freshly created task
  /// lands at the top of the list (matching the existing insert-at-top feel).
  @MainActor
  static func topPosition(in context: ModelContext) -> Double {
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
    let minKey = rows
      .filter { !$0.pendingDeletion && $0.deletedAt == nil }
      .map { key($0) }
      .min()
    return (minKey ?? 0) - gap
  }

  /// A position that sorts below every live task — used by the foot-of-list
  /// quick-add line so a capture lands where the user typed, not at the top.
  @MainActor
  static func bottomPosition(in context: ModelContext) -> Double {
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
    let maxKey = rows
      .filter { !$0.pendingDeletion && $0.deletedAt == nil }
      .map { key($0) }
      .max()
    return (maxKey ?? 0) + gap
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

extension Goal {
  init(_ e: GoalEntity) {
    // Format updatedAt Date → YYYY-MM-DD string for the wire DTO.
    let fmt = DateFormatter()
    fmt.calendar = Calendar(identifier: .gregorian)
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd"
    self.init(id: e.id,
              text: e.text,
              sections: e.sections,
              created: e.created,
              updated: fmt.string(from: e.updatedAt),
              metricKey: e.metricKey,
              metricWindow: e.metricWindow,
              metricComparator: e.metricComparator,
              metricTarget: e.metricTarget,
              metricBaseline: e.metricBaseline,
              metricTargetUpper: e.metricTargetUpper,
              pinned: e.pinned,
              color: e.color)
  }
}

// MARK: - Checklist CloudKit mapping

private func optionalChecklistString(_ value: CKRecordValue?) -> String? {
  guard let string = value as? String else { return nil }
  return string.isEmpty ? nil : string
}

enum HabitDefinitionCloudKitSchema {
  static let recordType = "HabitDefinition"

  enum Field {
    static let title = "title"
    static let emoji = "emoji"
    static let bucket = "bucket"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "habit-def:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("habit-def:".count))
  }
}

enum HabitEventCloudKitSchema {
  static let recordType = "HabitEvent"

  enum Field {
    static let date = "date"
    static let habitID = "habitID"
    static let done = "done"
    static let skipped = "skipped"
    static let note = "note"
    static let time = "time"
    static let occurredAt = "occurredAt"
  }

  static func recordName(for id: String) -> String { "habit-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("habit-event:".count))
  }
}

enum SupplementDefinitionCloudKitSchema {
  static let recordType = "SupplementDefinition"

  enum Field {
    static let title = "title"
    static let emoji = "emoji"
    static let bucket = "bucket"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "supplement-def:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("supplement-def:".count))
  }
}

enum SupplementEventCloudKitSchema {
  static let recordType = "SupplementEvent"

  enum Field {
    static let date = "date"
    static let supplementID = "supplementID"
    static let done = "done"
    static let skipped = "skipped"
    static let note = "note"
    static let time = "time"
    static let occurredAt = "occurredAt"
  }

  static func recordName(for id: String) -> String { "supplement-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("supplement-event:".count))
  }
}

enum ChoreDefinitionCloudKitSchema {
  static let recordType = "ChoreDefinition"

  enum Field {
    static let title = "title"
    static let emoji = "emoji"
    static let cadenceDays = "cadenceDays"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "chore-def:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("chore-def:".count))
  }
}

enum ChoreEventCloudKitSchema {
  static let recordType = "ChoreEvent"

  enum Field {
    static let choreID = "choreID"
    static let action = "action"
    static let date = "date"
    static let newDueDate = "newDueDate"
    static let reason = "reason"
    static let note = "note"
    static let time = "time"
    static let sortKey = "sortKey"
    static let occurredAt = "occurredAt"
  }

  static func recordName(for id: String) -> String { "chore-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("chore-event:".count))
  }
}

enum GutEventCloudKitSchema {
  static let recordType = "GutEvent"

  enum Field {
    static let date = "date"
    static let time = "time"
    static let bristol = "bristol"
    static let blood = "blood"
    static let volume = "volume"
    static let discomfortLevel = "discomfortLevel"
    static let discomfortStart = "discomfortStart"
    static let discomfortEnd = "discomfortEnd"
    static let note = "note"
    static let occurredAt = "occurredAt"
  }

  static func recordName(for id: String) -> String { "gut-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("gut-event:".count))
  }
}

enum MoodEventCloudKitSchema {
  static let recordType = "MoodEvent"

  enum Field {
    static let date = "date"
    static let time = "time"
    static let bucket = "bucket"
    static let quadrant = "quadrant"
    static let arousal = "arousal"
    static let valence = "valence"
    static let emotion = "emotion"
    static let note = "note"
    static let occurredAt = "occurredAt"
  }

  static func recordName(for id: String) -> String { "mood-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("mood-event:".count))
  }
}

enum SymptomDefinitionCloudKitSchema {
  static let recordType = "SymptomDefinition"

  enum Field {
    static let title = "title"
    static let emoji = "emoji"
    static let bodySystem = "bodySystem"
    static let defaultBodyRegion = "defaultBodyRegion"
    static let sortIndex = "sortIndex"
    static let archived = "archived"
    static let createdAt = "createdAt"
  }

  static func recordName(for id: String) -> String { "symptom-definition:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("symptom-definition:".count))
  }
}

enum SymptomEventCloudKitSchema {
  static let recordType = "SymptomEvent"

  enum Field {
    static let date = "date"
    static let symptomID = "symptomID"
    static let severity = "severity"
    static let durationMinutes = "durationMinutes"
    static let bodyRegion = "bodyRegion"
    static let side = "side"
    static let quality = "quality"
    static let triggerNote = "triggerNote"
    static let reliefNote = "reliefNote"
    static let note = "note"
    static let source = "source"
    static let occurredAt = "occurredAt"
  }

  static func recordName(for id: String) -> String { "symptom-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("symptom-event:".count))
  }
}

enum MedicationDefinitionCloudKitSchema {
  static let recordType = "MedicationDefinition"

  enum Field {
    static let title = "title"
    static let genericName = "genericName"
    static let form = "form"
    static let route = "route"
    static let strengthValue = "strengthValue"
    static let strengthUnit = "strengthUnit"
    static let defaultDoseValue = "defaultDoseValue"
    static let defaultDoseUnit = "defaultDoseUnit"
    static let bucket = "bucket"
    static let scheduleKind = "scheduleKind"
    static let targetDosesPerDay = "targetDosesPerDay"
    static let instructions = "instructions"
    static let sortIndex = "sortIndex"
    static let archived = "archived"
    static let createdAt = "createdAt"
  }

  static func recordName(for id: String) -> String { "medication-definition:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("medication-definition:".count))
  }
}

enum MedicationDoseEventCloudKitSchema {
  static let recordType = "MedicationDoseEvent"

  enum Field {
    static let date = "date"
    static let medicationID = "medicationID"
    static let status = "status"
    static let doseValue = "doseValue"
    static let doseUnit = "doseUnit"
    static let reason = "reason"
    static let effectNote = "effectNote"
    static let sideEffectNote = "sideEffectNote"
    static let source = "source"
    static let occurredAt = "occurredAt"
  }

  static func recordName(for id: String) -> String { "medication-dose-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("medication-dose-event:".count))
  }
}

enum OuraNightCloudKitSchema {
  /// One CKRecord per night. recordName is `oura-night:<yyyy-MM-dd>`
  /// so the date doubles as both the unique entity ID and the natural
  /// identifier — upserts are idempotent across devices.
  static let recordType = "OuraNight"

  enum Field {
    static let sleepScore      = "sleepScore"
    static let readinessScore  = "readinessScore"
    static let totalH          = "totalH"
    static let deepH           = "deepH"
    static let remH            = "remH"
    static let lightH          = "lightH"
    static let awakeH          = "awakeH"
    static let efficiency      = "efficiency"
    static let hrv             = "hrv"
    static let restingHr       = "restingHr"
    static let bedtime         = "bedtime"
    static let wakeTime        = "wakeTime"
    static let stressHighMin   = "stressHighMin"
    static let recoveryHighMin = "recoveryHighMin"
    static let stressSummary   = "stressSummary"
  }

  static func recordName(for id: String) -> String { "oura-night:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("oura-night:".count))
  }
}

enum QuoteCloudKitSchema {
  /// One CKRecord per stored daily-message quote — a user-added line or a
  /// Readwise-imported highlight. recordName is `quote:<id>`, where the id is
  /// itself prefixed (`user:<uuid>` / `readwise:<highlightId>`), so upserts
  /// are idempotent across devices. Feeds the optional dashboard footer line.
  static let recordType = "Quote"

  enum Field {
    static let text        = "text"
    static let attribution = "attribution"
    static let origin       = "origin"
    static let addedAt      = "addedAt"
  }

  static func recordName(for id: String) -> String { "quote:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("quote:".count))
  }
}

enum WithingsRowCloudKitSchema {
  /// One CKRecord per day. recordName is `withings-row:<yyyy-MM-dd>`;
  /// date doubles as the unique entity ID so upserts are idempotent
  /// across devices.
  static let recordType = "WithingsRow"

  enum Field {
    static let weightKg      = "weightKg"
    static let fatPct        = "fatPct"
    static let fatMassKg     = "fatMassKg"
    static let fatFreeMassKg = "fatFreeMassKg"
    static let muscleMassKg  = "muscleMassKg"
    static let hydrationKg   = "hydrationKg"
    static let boneMassKg    = "boneMassKg"
  }

  static func recordName(for id: String) -> String { "withings-row:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("withings-row:".count))
  }
}

enum IntakeKindCloudKitSchema {
  static let recordType = "IntakeKind"

  enum Field {
    static let name = "name"
    static let symbol = "symbol"
    static let color = "color"
    static let sortIndex = "sortIndex"
    static let unit = "unit"
    static let doseStyle = "doseStyle"
    static let countNoun = "countNoun"
    static let containerNoun = "containerNoun"
    static let containerCap = "containerCap"
    static let catalogNoun = "catalogNoun"
    static let flourish = "flourish"
    static let metricMode = "metricMode"
    static let objective = "objective"
    static let methods = "methods"
    static let templateID = "templateID"
    static let archivedAt = "archivedAt"
  }

  static func recordName(for id: String) -> String { "intake-kind:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("intake-kind:".count))
  }
}

enum IntakeItemCloudKitSchema {
  static let recordType = "IntakeItem"

  enum Field {
    static let kindID = "kindID"
    static let name = "name"
    static let emoji = "emoji"
    static let sortIndex = "sortIndex"
    static let archivedAt = "archivedAt"
  }

  static func recordName(for id: String) -> String { "intake-item:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("intake-item:".count))
  }
}

enum IntakeEventCloudKitSchema {
  static let recordType = "IntakeEvent"

  enum Field {
    static let kindID = "kindID"
    static let date = "date"
    static let method = "method"
    static let itemID = "itemID"
    static let amount = "amount"
    static let count = "count"
    static let note = "note"
    static let occurredAt = "occurredAt"
  }

  static func recordName(for id: String) -> String { "intake-event:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("intake-event:".count))
  }
}

enum GroceryItemCloudKitSchema {
  static let recordType = "GroceryItem"

  enum Field {
    static let name = "name"
    static let category = "category"
    static let emoji = "emoji"
    static let low = "low"
    static let lastBought = "lastBought"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "grocery-item:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("grocery-item:".count))
  }
}

enum GroceryCategoryCloudKitSchema {
  static let recordType = "GroceryCategory"

  enum Field {
    static let name = "name"
    static let sortIndex = "sortIndex"
  }

  static func recordName(for id: String) -> String { "grocery-cat:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("grocery-cat:".count))
  }
}

enum ExerciseEntryCloudKitSchema {
  static let recordType = "ExerciseEntry"

  enum Field {
    static let date = "date"
    static let time = "time"
    static let sessionType = "sessionType"
    static let exercise = "exercise"
    static let weight = "weight"
    static let sets = "sets"
    static let reps = "reps"
    static let difficulty = "difficulty"
    static let durationMin = "durationMin"
    static let distanceM = "distanceM"
    static let level = "level"
    static let note = "note"
    static let concludedAt = "concludedAt"
    static let loggedAt = "loggedAt"
    static let occurredAt = "occurredAt"
  }

  static func recordName(for id: String) -> String { "exercise-entry:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("exercise-entry:".count))
  }
}

enum ExerciseDefinitionCloudKitSchema {
  static let recordType = "ExerciseDefinition"

  enum Field {
    static let name = "name"
    static let type = "type"
    static let subgroup = "subgroup"
    static let aliases = "aliases"
    static let sortIndex = "sortIndex"
    static let primaryMuscle = "primaryMuscle"
    static let secondaryMuscles = "secondaryMuscles"
    static let archived = "archived"
  }

  static func recordName(for id: String) -> String { "exercise-def:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("exercise-def:".count))
  }
}

enum SessionTypeCloudKitSchema {
  static let recordType = "SessionType"

  enum Field {
    static let label = "label"
    static let emoji = "emoji"
    static let exercises = "exercises"
    static let sortIndex = "sortIndex"
    static let archived = "archived"
    /// Routine category — `SessionKind.rawValue`. Optional in CloudKit;
    /// records written before this field existed read back as nil and
    /// the read site falls back to `SessionKind.defaulted(for: id)`.
    static let kind = "kind"
  }

  static func recordName(for id: String) -> String { "session-type:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("session-type:".count))
  }
}

enum NutritionEntryCloudKitSchema {
  static let recordType = "NutritionEntry"

  enum Field {
    static let loggedAt       = "loggedAt"
    static let emoji          = "emoji"
    static let foods          = "foods"
    static let ingredients    = "ingredients"
    static let note           = "note"
    static let mealType       = "mealType"
    static let source         = "source"
    static let proteinG       = "proteinG"
    static let fatG           = "fatG"
    static let carbsG         = "carbsG"
    static let fiberG         = "fiberG"
    static let sugarG         = "sugarG"
    static let saturatedFatG  = "saturatedFatG"
    static let alcoholG       = "alcoholG"
    static let kcal           = "kcal"
    static let sodiumMg       = "sodiumMg"
    static let cholesterolMg  = "cholesterolMg"
    static let potassiumMg    = "potassiumMg"
    static let waterMl        = "waterMl"
    static let photoAssetID   = "photoAssetID"
  }

  static func recordName(for id: String) -> String { "nutrition-entry:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("nutrition-entry:".count))
  }
}

enum NutritionDailySummaryCloudKitSchema {
  static let recordType = "NutritionDaySum"

  enum Field {
    static let date          = "date"
    static let entryCount    = "entryCount"
    static let firstLoggedAt = "firstLoggedAt"
    static let lastLoggedAt  = "lastLoggedAt"
    static let computedAt    = "computedAt"
    static let kcal          = "kcal"
    static let proteinG      = "proteinG"
    static let fatG          = "fatG"
    static let carbsG        = "carbsG"
    static let fiberG        = "fiberG"
    static let sugarG        = "sugarG"
    static let saturatedFatG = "saturatedFatG"
    static let alcoholG      = "alcoholG"
    static let sodiumMg      = "sodiumMg"
    static let cholesterolMg = "cholesterolMg"
    static let potassiumMg   = "potassiumMg"
    static let waterMl       = "waterMl"
  }

  static func recordName(for id: String) -> String { "nutrition-day:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("nutrition-day:".count))
  }
}

enum ActivityDayCloudKitSchema {
  static let recordType = "ActivityDaySum"

  enum Field {
    static let date            = "date"
    static let stepCount       = "stepCount"
    static let activeKcal      = "activeKcal"
    static let exerciseMinutes = "exerciseMinutes"
  }

  static func recordName(for id: String) -> String { "activity-day:\(id)" }
  static func entityID(from recordName: String) -> String {
    String(recordName.dropFirst("activity-day:".count))
  }
}

/// Shared CloudKit system-fields plumbing for every CK-backed `@Model`.
/// A conformer only needs the `cloudKitSystemFields` blob; the archive/
/// unarchive of the record's system fields (recordID + change tag) is
/// identical for every record type, so it lives here once instead of being
/// re-implemented per entity. Used by the checklist/section entities below and
/// by the task-stack entities in `CloudKit/*Record.swift`.
protocol CloudKitSystemFieldsBacked: AnyObject {
  var cloudKitSystemFields: Data? { get set }
}

extension CloudKitSystemFieldsBacked {
  func decodedCloudKitRecord() -> CKRecord? {
    guard let data = cloudKitSystemFields else { return nil }
    let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
    unarchiver?.requiresSecureCoding = true
    return unarchiver.flatMap { CKRecord(coder: $0) }
  }

  func captureCloudKitSystemFields(from record: CKRecord) {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    cloudKitSystemFields = archiver.encodedData
  }
}

extension HabitDefinitionEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: HabitDefinitionCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: HabitDefinitionCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[HabitDefinitionCloudKitSchema.Field.title] = title
    record[HabitDefinitionCloudKitSchema.Field.emoji] = emoji
    record[HabitDefinitionCloudKitSchema.Field.bucket] = bucket
    record[HabitDefinitionCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[HabitDefinitionCloudKitSchema.Field.title] as? String { title = value }
    emoji = optionalChecklistString(record[HabitDefinitionCloudKitSchema.Field.emoji])
    if let value = record[HabitDefinitionCloudKitSchema.Field.bucket] as? String { bucket = value }
    if let value = record[HabitDefinitionCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: HabitDefinitionCloudKitSchema.entityID(from: record.recordID.recordName),
              title: "",
              bucket: "morning")
    apply(record)
  }
}

extension HabitDayStateEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: HabitEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: HabitEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[HabitEventCloudKitSchema.Field.date] = date
    record[HabitEventCloudKitSchema.Field.habitID] = habitID
    record[HabitEventCloudKitSchema.Field.done] = done ? 1 : 0
    record[HabitEventCloudKitSchema.Field.skipped] = skipped ? 1 : 0
    record[HabitEventCloudKitSchema.Field.note] = note
    record[HabitEventCloudKitSchema.Field.occurredAt] = occurredAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[HabitEventCloudKitSchema.Field.date] as? String { date = value }
    if let value = record[HabitEventCloudKitSchema.Field.habitID] as? String { habitID = value }
    if let value = record[HabitEventCloudKitSchema.Field.done] as? Int { done = value != 0 }
    if let value = record[HabitEventCloudKitSchema.Field.skipped] as? Int { skipped = value != 0 }
    note = optionalChecklistString(record[HabitEventCloudKitSchema.Field.note])
    if let v = record[HabitEventCloudKitSchema.Field.occurredAt] as? Date { occurredAt = v }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: HabitEventCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "",
              habitID: "",
              done: false,
              skipped: false)
    apply(record)
  }
}

extension SupplementDefinitionEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: SupplementDefinitionCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: SupplementDefinitionCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[SupplementDefinitionCloudKitSchema.Field.title] = title
    record[SupplementDefinitionCloudKitSchema.Field.emoji] = emoji
    record[SupplementDefinitionCloudKitSchema.Field.bucket] = bucket
    record[SupplementDefinitionCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[SupplementDefinitionCloudKitSchema.Field.title] as? String { title = value }
    emoji = optionalChecklistString(record[SupplementDefinitionCloudKitSchema.Field.emoji])
    bucket = optionalChecklistString(record[SupplementDefinitionCloudKitSchema.Field.bucket])
    if let value = record[SupplementDefinitionCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: SupplementDefinitionCloudKitSchema.entityID(from: record.recordID.recordName),
              title: "")
    apply(record)
  }
}

extension SupplementDayStateEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: SupplementEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: SupplementEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[SupplementEventCloudKitSchema.Field.date] = date
    record[SupplementEventCloudKitSchema.Field.supplementID] = supplementID
    record[SupplementEventCloudKitSchema.Field.done] = done ? 1 : 0
    record[SupplementEventCloudKitSchema.Field.skipped] = skipped ? 1 : 0
    record[SupplementEventCloudKitSchema.Field.note] = note
    record[SupplementEventCloudKitSchema.Field.occurredAt] = occurredAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[SupplementEventCloudKitSchema.Field.date] as? String { date = value }
    if let value = record[SupplementEventCloudKitSchema.Field.supplementID] as? String { supplementID = value }
    if let value = record[SupplementEventCloudKitSchema.Field.done] as? Int { done = value != 0 }
    if let value = record[SupplementEventCloudKitSchema.Field.skipped] as? Int { skipped = value != 0 }
    note = optionalChecklistString(record[SupplementEventCloudKitSchema.Field.note])
    if let v = record[SupplementEventCloudKitSchema.Field.occurredAt] as? Date { occurredAt = v }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: SupplementEventCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "",
              supplementID: "",
              done: false)
    apply(record)
  }
}

extension ChoreDefinitionEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: ChoreDefinitionCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: ChoreDefinitionCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[ChoreDefinitionCloudKitSchema.Field.title] = title
    record[ChoreDefinitionCloudKitSchema.Field.emoji] = emoji
    record[ChoreDefinitionCloudKitSchema.Field.cadenceDays] = cadenceDays
    record[ChoreDefinitionCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[ChoreDefinitionCloudKitSchema.Field.title] as? String { title = value }
    emoji = optionalChecklistString(record[ChoreDefinitionCloudKitSchema.Field.emoji])
    if let value = record[ChoreDefinitionCloudKitSchema.Field.cadenceDays] as? Int { cadenceDays = value }
    if let value = record[ChoreDefinitionCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: ChoreDefinitionCloudKitSchema.entityID(from: record.recordID.recordName),
              title: "",
              cadenceDays: 1)
    apply(record)
  }
}

extension ChoreEventEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: ChoreEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: ChoreEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[ChoreEventCloudKitSchema.Field.choreID] = choreID
    record[ChoreEventCloudKitSchema.Field.action] = action
    record[ChoreEventCloudKitSchema.Field.date] = date
    record[ChoreEventCloudKitSchema.Field.newDueDate] = newDueDate
    record[ChoreEventCloudKitSchema.Field.reason] = reason
    record[ChoreEventCloudKitSchema.Field.note] = note
    record[ChoreEventCloudKitSchema.Field.sortKey] = sortKey
    record[ChoreEventCloudKitSchema.Field.occurredAt] = occurredAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[ChoreEventCloudKitSchema.Field.choreID] as? String { choreID = value }
    if let value = record[ChoreEventCloudKitSchema.Field.action] as? String { action = value }
    if let value = record[ChoreEventCloudKitSchema.Field.date] as? String { date = value }
    newDueDate = optionalChecklistString(record[ChoreEventCloudKitSchema.Field.newDueDate])
    reason = optionalChecklistString(record[ChoreEventCloudKitSchema.Field.reason])
    note = optionalChecklistString(record[ChoreEventCloudKitSchema.Field.note])
    if let value = record[ChoreEventCloudKitSchema.Field.sortKey] as? String { sortKey = value }
    if let v = record[ChoreEventCloudKitSchema.Field.occurredAt] as? Date { occurredAt = v }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: ChoreEventCloudKitSchema.entityID(from: record.recordID.recordName),
              choreID: "",
              action: "complete",
              date: "",
              sortKey: "")
    apply(record)
  }
}

extension GutEventEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: GutEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: GutEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[GutEventCloudKitSchema.Field.date] = date
    record[GutEventCloudKitSchema.Field.bristol] = bristol
    record[GutEventCloudKitSchema.Field.volume] = volume
    // Symptom-shaped fields (blood, discomfort*) are NOT written — they moved to
    // Symptoms. Omitting them keeps the fields out of the CloudKit GutEvent
    // schema (a field is registered only when a record is saved with it), so a
    // clean prod deploy never gains those columns. The local SwiftData columns
    // stay as the migrator's dormant source; `apply(_:)` still *reads* any
    // legacy values present on historical records (a read can't create schema).
    record[GutEventCloudKitSchema.Field.note] = note
    record[GutEventCloudKitSchema.Field.occurredAt] = occurredAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[GutEventCloudKitSchema.Field.date] as? String { date = value }
    if let value = record[GutEventCloudKitSchema.Field.bristol] as? Int { bristol = value }
    if let value = record[GutEventCloudKitSchema.Field.blood] as? Int { blood = value }
    volume = optionalChecklistString(record[GutEventCloudKitSchema.Field.volume])
    discomfortLevel = optionalChecklistString(record[GutEventCloudKitSchema.Field.discomfortLevel])
    discomfortStart = optionalChecklistString(record[GutEventCloudKitSchema.Field.discomfortStart])
    discomfortEnd = optionalChecklistString(record[GutEventCloudKitSchema.Field.discomfortEnd])
    note = optionalChecklistString(record[GutEventCloudKitSchema.Field.note])
    if let v = record[GutEventCloudKitSchema.Field.occurredAt] as? Date { occurredAt = v }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: GutEventCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "", bristol: 4)
    apply(record)
  }
}

extension MoodEventEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: MoodEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: MoodEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[MoodEventCloudKitSchema.Field.date] = date
    record[MoodEventCloudKitSchema.Field.bucket] = bucket
    record[MoodEventCloudKitSchema.Field.quadrant] = quadrant
    record[MoodEventCloudKitSchema.Field.arousal] = arousal
    record[MoodEventCloudKitSchema.Field.valence] = valence
    record[MoodEventCloudKitSchema.Field.emotion] = emotion
    record[MoodEventCloudKitSchema.Field.note] = note
    record[MoodEventCloudKitSchema.Field.occurredAt] = occurredAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[MoodEventCloudKitSchema.Field.date] as? String { date = value }
    if let value = record[MoodEventCloudKitSchema.Field.bucket] as? String { bucket = value }
    if let value = record[MoodEventCloudKitSchema.Field.quadrant] as? String { quadrant = value }
    if let value = record[MoodEventCloudKitSchema.Field.arousal] as? Int { arousal = value }
    if let value = record[MoodEventCloudKitSchema.Field.valence] as? Int { valence = value }
    if let value = record[MoodEventCloudKitSchema.Field.emotion] as? String { emotion = value }
    note = optionalChecklistString(record[MoodEventCloudKitSchema.Field.note])
    if let v = record[MoodEventCloudKitSchema.Field.occurredAt] as? Date { occurredAt = v }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: MoodEventCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "", bucket: "morning",
              quadrant: "lap", arousal: 2, valence: 2, emotion: "")
    apply(record)
  }
}

extension SymptomDefinitionEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: SymptomDefinitionCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: SymptomDefinitionCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[SymptomDefinitionCloudKitSchema.Field.title] = title
    record[SymptomDefinitionCloudKitSchema.Field.emoji] = emoji
    record[SymptomDefinitionCloudKitSchema.Field.bodySystem] = bodySystem
    record[SymptomDefinitionCloudKitSchema.Field.defaultBodyRegion] = defaultBodyRegion
    record[SymptomDefinitionCloudKitSchema.Field.sortIndex] = sortIndex
    record[SymptomDefinitionCloudKitSchema.Field.archived] = archived ? 1 : 0
    record[SymptomDefinitionCloudKitSchema.Field.createdAt] = createdAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[SymptomDefinitionCloudKitSchema.Field.title] as? String { title = value }
    emoji = optionalChecklistString(record[SymptomDefinitionCloudKitSchema.Field.emoji])
    bodySystem = optionalChecklistString(record[SymptomDefinitionCloudKitSchema.Field.bodySystem])
    defaultBodyRegion = optionalChecklistString(record[SymptomDefinitionCloudKitSchema.Field.defaultBodyRegion])
    if let value = record[SymptomDefinitionCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    if let value = record[SymptomDefinitionCloudKitSchema.Field.archived] as? Int { archived = value != 0 }
    if let value = record[SymptomDefinitionCloudKitSchema.Field.createdAt] as? Date { createdAt = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: SymptomDefinitionCloudKitSchema.entityID(from: record.recordID.recordName),
              title: "")
    apply(record)
  }
}

extension SymptomEventEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: SymptomEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: SymptomEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[SymptomEventCloudKitSchema.Field.date] = date
    record[SymptomEventCloudKitSchema.Field.symptomID] = symptomID
    record[SymptomEventCloudKitSchema.Field.severity] = severity
    record[SymptomEventCloudKitSchema.Field.durationMinutes] = durationMinutes
    record[SymptomEventCloudKitSchema.Field.bodyRegion] = bodyRegion
    record[SymptomEventCloudKitSchema.Field.side] = side
    record[SymptomEventCloudKitSchema.Field.quality] = quality
    record[SymptomEventCloudKitSchema.Field.triggerNote] = triggerNote
    record[SymptomEventCloudKitSchema.Field.reliefNote] = reliefNote
    record[SymptomEventCloudKitSchema.Field.note] = note
    record[SymptomEventCloudKitSchema.Field.source] = source
    record[SymptomEventCloudKitSchema.Field.occurredAt] = occurredAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[SymptomEventCloudKitSchema.Field.date] as? String { date = value }
    if let value = record[SymptomEventCloudKitSchema.Field.symptomID] as? String { symptomID = value }
    if let value = record[SymptomEventCloudKitSchema.Field.severity] as? Int { severity = value }
    durationMinutes = record[SymptomEventCloudKitSchema.Field.durationMinutes] as? Int
    bodyRegion = optionalChecklistString(record[SymptomEventCloudKitSchema.Field.bodyRegion])
    side = optionalChecklistString(record[SymptomEventCloudKitSchema.Field.side])
    quality = optionalChecklistString(record[SymptomEventCloudKitSchema.Field.quality])
    triggerNote = optionalChecklistString(record[SymptomEventCloudKitSchema.Field.triggerNote])
    reliefNote = optionalChecklistString(record[SymptomEventCloudKitSchema.Field.reliefNote])
    note = optionalChecklistString(record[SymptomEventCloudKitSchema.Field.note])
    source = optionalChecklistString(record[SymptomEventCloudKitSchema.Field.source])
    if let v = record[SymptomEventCloudKitSchema.Field.occurredAt] as? Date { occurredAt = v }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: SymptomEventCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "", symptomID: "", severity: 0)
    apply(record)
  }
}

extension MedicationDefinitionEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: MedicationDefinitionCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: MedicationDefinitionCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[MedicationDefinitionCloudKitSchema.Field.title] = title
    record[MedicationDefinitionCloudKitSchema.Field.genericName] = genericName
    record[MedicationDefinitionCloudKitSchema.Field.form] = form
    record[MedicationDefinitionCloudKitSchema.Field.route] = route
    record[MedicationDefinitionCloudKitSchema.Field.strengthValue] = strengthValue
    record[MedicationDefinitionCloudKitSchema.Field.strengthUnit] = strengthUnit
    record[MedicationDefinitionCloudKitSchema.Field.defaultDoseValue] = defaultDoseValue
    record[MedicationDefinitionCloudKitSchema.Field.defaultDoseUnit] = defaultDoseUnit
    record[MedicationDefinitionCloudKitSchema.Field.bucket] = bucket
    record[MedicationDefinitionCloudKitSchema.Field.scheduleKind] = scheduleKind
    record[MedicationDefinitionCloudKitSchema.Field.targetDosesPerDay] = targetDosesPerDay
    record[MedicationDefinitionCloudKitSchema.Field.instructions] = instructions
    record[MedicationDefinitionCloudKitSchema.Field.sortIndex] = sortIndex
    record[MedicationDefinitionCloudKitSchema.Field.archived] = archived ? 1 : 0
    record[MedicationDefinitionCloudKitSchema.Field.createdAt] = createdAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[MedicationDefinitionCloudKitSchema.Field.title] as? String { title = value }
    genericName = optionalChecklistString(record[MedicationDefinitionCloudKitSchema.Field.genericName])
    form = optionalChecklistString(record[MedicationDefinitionCloudKitSchema.Field.form])
    route = optionalChecklistString(record[MedicationDefinitionCloudKitSchema.Field.route])
    strengthValue = record[MedicationDefinitionCloudKitSchema.Field.strengthValue] as? Double
    strengthUnit = optionalChecklistString(record[MedicationDefinitionCloudKitSchema.Field.strengthUnit])
    defaultDoseValue = record[MedicationDefinitionCloudKitSchema.Field.defaultDoseValue] as? Double
    defaultDoseUnit = optionalChecklistString(record[MedicationDefinitionCloudKitSchema.Field.defaultDoseUnit])
    bucket = optionalChecklistString(record[MedicationDefinitionCloudKitSchema.Field.bucket])
    scheduleKind = optionalChecklistString(record[MedicationDefinitionCloudKitSchema.Field.scheduleKind]) ?? scheduleKind
    if let value = record[MedicationDefinitionCloudKitSchema.Field.targetDosesPerDay] as? Int { targetDosesPerDay = value }
    instructions = optionalChecklistString(record[MedicationDefinitionCloudKitSchema.Field.instructions])
    if let value = record[MedicationDefinitionCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    if let value = record[MedicationDefinitionCloudKitSchema.Field.archived] as? Int { archived = value != 0 }
    if let value = record[MedicationDefinitionCloudKitSchema.Field.createdAt] as? Date { createdAt = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: MedicationDefinitionCloudKitSchema.entityID(from: record.recordID.recordName),
              title: "")
    apply(record)
  }
}

extension MedicationDoseEventEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: MedicationDoseEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: MedicationDoseEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[MedicationDoseEventCloudKitSchema.Field.date] = date
    record[MedicationDoseEventCloudKitSchema.Field.medicationID] = medicationID
    record[MedicationDoseEventCloudKitSchema.Field.status] = status
    record[MedicationDoseEventCloudKitSchema.Field.doseValue] = doseValue
    record[MedicationDoseEventCloudKitSchema.Field.doseUnit] = doseUnit
    record[MedicationDoseEventCloudKitSchema.Field.reason] = reason
    record[MedicationDoseEventCloudKitSchema.Field.effectNote] = effectNote
    record[MedicationDoseEventCloudKitSchema.Field.sideEffectNote] = sideEffectNote
    record[MedicationDoseEventCloudKitSchema.Field.source] = source
    record[MedicationDoseEventCloudKitSchema.Field.occurredAt] = occurredAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[MedicationDoseEventCloudKitSchema.Field.date] as? String { date = value }
    if let value = record[MedicationDoseEventCloudKitSchema.Field.medicationID] as? String { medicationID = value }
    if let value = record[MedicationDoseEventCloudKitSchema.Field.status] as? String { status = value }
    doseValue = record[MedicationDoseEventCloudKitSchema.Field.doseValue] as? Double
    doseUnit = optionalChecklistString(record[MedicationDoseEventCloudKitSchema.Field.doseUnit])
    reason = optionalChecklistString(record[MedicationDoseEventCloudKitSchema.Field.reason])
    effectNote = optionalChecklistString(record[MedicationDoseEventCloudKitSchema.Field.effectNote])
    sideEffectNote = optionalChecklistString(record[MedicationDoseEventCloudKitSchema.Field.sideEffectNote])
    source = optionalChecklistString(record[MedicationDoseEventCloudKitSchema.Field.source])
    if let v = record[MedicationDoseEventCloudKitSchema.Field.occurredAt] as? Date { occurredAt = v }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: MedicationDoseEventCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "", medicationID: "", status: "taken")
    apply(record)
  }
}

extension OuraNightEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: OuraNightCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: OuraNightCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[OuraNightCloudKitSchema.Field.sleepScore]      = sleepScore.map { Int64($0) }
    record[OuraNightCloudKitSchema.Field.readinessScore]  = readinessScore.map { Int64($0) }
    record[OuraNightCloudKitSchema.Field.totalH]          = totalH
    record[OuraNightCloudKitSchema.Field.deepH]           = deepH
    record[OuraNightCloudKitSchema.Field.remH]            = remH
    record[OuraNightCloudKitSchema.Field.lightH]          = lightH
    record[OuraNightCloudKitSchema.Field.awakeH]          = awakeH
    record[OuraNightCloudKitSchema.Field.efficiency]      = efficiency.map { Int64($0) }
    record[OuraNightCloudKitSchema.Field.hrv]             = hrv.map { Int64($0) }
    record[OuraNightCloudKitSchema.Field.restingHr]       = restingHr.map { Int64($0) }
    record[OuraNightCloudKitSchema.Field.bedtime]         = bedtime
    record[OuraNightCloudKitSchema.Field.wakeTime]        = wakeTime
    record[OuraNightCloudKitSchema.Field.stressHighMin]   = stressHighMin.map { Int64($0) }
    record[OuraNightCloudKitSchema.Field.recoveryHighMin] = recoveryHighMin.map { Int64($0) }
    record[OuraNightCloudKitSchema.Field.stressSummary]   = stressSummary
    return record
  }

  func apply(_ record: CKRecord) {
    sleepScore      = (record[OuraNightCloudKitSchema.Field.sleepScore]      as? Int64).map(Int.init)
    readinessScore  = (record[OuraNightCloudKitSchema.Field.readinessScore]  as? Int64).map(Int.init)
    totalH          =  record[OuraNightCloudKitSchema.Field.totalH]          as? Double
    deepH           =  record[OuraNightCloudKitSchema.Field.deepH]           as? Double
    remH            =  record[OuraNightCloudKitSchema.Field.remH]            as? Double
    lightH          =  record[OuraNightCloudKitSchema.Field.lightH]          as? Double
    awakeH          =  record[OuraNightCloudKitSchema.Field.awakeH]          as? Double
    efficiency      = (record[OuraNightCloudKitSchema.Field.efficiency]      as? Int64).map(Int.init)
    hrv             = (record[OuraNightCloudKitSchema.Field.hrv]             as? Int64).map(Int.init)
    restingHr       = (record[OuraNightCloudKitSchema.Field.restingHr]       as? Int64).map(Int.init)
    bedtime         =  record[OuraNightCloudKitSchema.Field.bedtime]         as? String
    wakeTime        =  record[OuraNightCloudKitSchema.Field.wakeTime]        as? String
    stressHighMin   = (record[OuraNightCloudKitSchema.Field.stressHighMin]   as? Int64).map(Int.init)
    recoveryHighMin = (record[OuraNightCloudKitSchema.Field.recoveryHighMin] as? Int64).map(Int.init)
    stressSummary   =  record[OuraNightCloudKitSchema.Field.stressSummary]   as? String
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: OuraNightCloudKitSchema.entityID(from: record.recordID.recordName))
    apply(record)
  }
}

extension QuoteEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: QuoteCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: QuoteCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[QuoteCloudKitSchema.Field.text]        = text
    record[QuoteCloudKitSchema.Field.attribution] = attribution
    record[QuoteCloudKitSchema.Field.origin]      = origin
    record[QuoteCloudKitSchema.Field.addedAt]     = addedAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let v = record[QuoteCloudKitSchema.Field.text]        as? String { text = v }
    if let v = record[QuoteCloudKitSchema.Field.attribution] as? String { attribution = v }
    if let v = record[QuoteCloudKitSchema.Field.origin]      as? String { origin = v }
    if let v = record[QuoteCloudKitSchema.Field.addedAt]     as? Date   { addedAt = v }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: QuoteCloudKitSchema.entityID(from: record.recordID.recordName))
    apply(record)
  }
}

extension WithingsRowEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: WithingsRowCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: WithingsRowCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[WithingsRowCloudKitSchema.Field.weightKg]      = weightKg
    record[WithingsRowCloudKitSchema.Field.fatPct]        = fatPct
    record[WithingsRowCloudKitSchema.Field.fatMassKg]     = fatMassKg
    record[WithingsRowCloudKitSchema.Field.fatFreeMassKg] = fatFreeMassKg
    record[WithingsRowCloudKitSchema.Field.muscleMassKg]  = muscleMassKg
    record[WithingsRowCloudKitSchema.Field.hydrationKg]   = hydrationKg
    record[WithingsRowCloudKitSchema.Field.boneMassKg]    = boneMassKg
    return record
  }

  func apply(_ record: CKRecord) {
    weightKg      = record[WithingsRowCloudKitSchema.Field.weightKg]      as? Double
    fatPct        = record[WithingsRowCloudKitSchema.Field.fatPct]        as? Double
    fatMassKg     = record[WithingsRowCloudKitSchema.Field.fatMassKg]     as? Double
    fatFreeMassKg = record[WithingsRowCloudKitSchema.Field.fatFreeMassKg] as? Double
    muscleMassKg  = record[WithingsRowCloudKitSchema.Field.muscleMassKg]  as? Double
    hydrationKg   = record[WithingsRowCloudKitSchema.Field.hydrationKg]   as? Double
    boneMassKg    = record[WithingsRowCloudKitSchema.Field.boneMassKg]    as? Double
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: WithingsRowCloudKitSchema.entityID(from: record.recordID.recordName))
    apply(record)
  }
}

extension IntakeKindEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: IntakeKindCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: IntakeKindCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[IntakeKindCloudKitSchema.Field.name] = name
    record[IntakeKindCloudKitSchema.Field.symbol] = symbol
    record[IntakeKindCloudKitSchema.Field.color] = color
    record[IntakeKindCloudKitSchema.Field.sortIndex] = sortIndex
    record[IntakeKindCloudKitSchema.Field.unit] = unit
    record[IntakeKindCloudKitSchema.Field.doseStyle] = doseStyle
    record[IntakeKindCloudKitSchema.Field.countNoun] = countNoun
    record[IntakeKindCloudKitSchema.Field.containerNoun] = containerNoun
    record[IntakeKindCloudKitSchema.Field.containerCap] = containerCap
    record[IntakeKindCloudKitSchema.Field.catalogNoun] = catalogNoun
    record[IntakeKindCloudKitSchema.Field.flourish] = flourish
    record[IntakeKindCloudKitSchema.Field.metricMode] = metricMode
    record[IntakeKindCloudKitSchema.Field.objective] = objective
    record[IntakeKindCloudKitSchema.Field.methods] = methodsJSON
    record[IntakeKindCloudKitSchema.Field.templateID] = templateID
    record[IntakeKindCloudKitSchema.Field.archivedAt] = archivedAt as NSDate?
    return record
  }

  func apply(_ record: CKRecord) {
    if let v = record[IntakeKindCloudKitSchema.Field.name] as? String { name = v }
    if let v = record[IntakeKindCloudKitSchema.Field.symbol] as? String { symbol = v }
    if let v = record[IntakeKindCloudKitSchema.Field.color] as? String { color = v }
    if let v = record[IntakeKindCloudKitSchema.Field.sortIndex] as? Int { sortIndex = v }
    unit = optionalChecklistString(record[IntakeKindCloudKitSchema.Field.unit])
    if let v = record[IntakeKindCloudKitSchema.Field.doseStyle] as? String { doseStyle = v }
    countNoun = optionalChecklistString(record[IntakeKindCloudKitSchema.Field.countNoun])
    containerNoun = optionalChecklistString(record[IntakeKindCloudKitSchema.Field.containerNoun])
    containerCap = record[IntakeKindCloudKitSchema.Field.containerCap] as? Int
    catalogNoun = optionalChecklistString(record[IntakeKindCloudKitSchema.Field.catalogNoun])
    if let v = record[IntakeKindCloudKitSchema.Field.flourish] as? String { flourish = v }
    if let v = record[IntakeKindCloudKitSchema.Field.metricMode] as? String { metricMode = v }
    if let v = record[IntakeKindCloudKitSchema.Field.objective] as? String { objective = v }
    if let v = record[IntakeKindCloudKitSchema.Field.methods] as? String { methodsJSON = v }
    templateID = optionalChecklistString(record[IntakeKindCloudKitSchema.Field.templateID])
    archivedAt = record[IntakeKindCloudKitSchema.Field.archivedAt] as? Date
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: IntakeKindCloudKitSchema.entityID(from: record.recordID.recordName), name: "")
    apply(record)
  }
}

extension IntakeItemEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: IntakeItemCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: IntakeItemCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[IntakeItemCloudKitSchema.Field.kindID] = kindID
    record[IntakeItemCloudKitSchema.Field.name] = name
    record[IntakeItemCloudKitSchema.Field.emoji] = emoji
    record[IntakeItemCloudKitSchema.Field.sortIndex] = sortIndex
    record[IntakeItemCloudKitSchema.Field.archivedAt] = archivedAt as NSDate?
    return record
  }

  func apply(_ record: CKRecord) {
    if let v = record[IntakeItemCloudKitSchema.Field.kindID] as? String { kindID = v }
    if let v = record[IntakeItemCloudKitSchema.Field.name] as? String { name = v }
    emoji = optionalChecklistString(record[IntakeItemCloudKitSchema.Field.emoji])
    if let v = record[IntakeItemCloudKitSchema.Field.sortIndex] as? Int { sortIndex = v }
    archivedAt = record[IntakeItemCloudKitSchema.Field.archivedAt] as? Date
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: IntakeItemCloudKitSchema.entityID(from: record.recordID.recordName),
              kindID: "", name: "")
    apply(record)
  }
}

extension IntakeEventEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: IntakeEventCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: IntakeEventCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[IntakeEventCloudKitSchema.Field.kindID] = kindID
    record[IntakeEventCloudKitSchema.Field.date] = date
    record[IntakeEventCloudKitSchema.Field.method] = method
    record[IntakeEventCloudKitSchema.Field.itemID] = itemID
    record[IntakeEventCloudKitSchema.Field.amount] = amount
    record[IntakeEventCloudKitSchema.Field.count] = count
    record[IntakeEventCloudKitSchema.Field.note] = note
    record[IntakeEventCloudKitSchema.Field.occurredAt] = occurredAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let v = record[IntakeEventCloudKitSchema.Field.kindID] as? String { kindID = v }
    if let v = record[IntakeEventCloudKitSchema.Field.date] as? String { date = v }
    if let v = record[IntakeEventCloudKitSchema.Field.method] as? String { method = v }
    itemID = optionalChecklistString(record[IntakeEventCloudKitSchema.Field.itemID])
    amount = record[IntakeEventCloudKitSchema.Field.amount] as? Double
    count = record[IntakeEventCloudKitSchema.Field.count] as? Int
    note = optionalChecklistString(record[IntakeEventCloudKitSchema.Field.note])
    if let v = record[IntakeEventCloudKitSchema.Field.occurredAt] as? Date { occurredAt = v }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: IntakeEventCloudKitSchema.entityID(from: record.recordID.recordName),
              kindID: "", date: "", method: "")
    apply(record)
  }
}

extension GroceryItemEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: GroceryItemCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: GroceryItemCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[GroceryItemCloudKitSchema.Field.name] = name
    record[GroceryItemCloudKitSchema.Field.category] = category
    record[GroceryItemCloudKitSchema.Field.emoji] = emoji
    record[GroceryItemCloudKitSchema.Field.low] = low ? 1 : 0
    record[GroceryItemCloudKitSchema.Field.lastBought] = lastBought
    record[GroceryItemCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[GroceryItemCloudKitSchema.Field.name] as? String { name = value }
    if let value = record[GroceryItemCloudKitSchema.Field.category] as? String { category = value }
    if let value = record[GroceryItemCloudKitSchema.Field.emoji] as? String { emoji = value }
    if let value = record[GroceryItemCloudKitSchema.Field.low] as? Int { low = value != 0 }
    lastBought = optionalChecklistString(record[GroceryItemCloudKitSchema.Field.lastBought])
    if let value = record[GroceryItemCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: GroceryItemCloudKitSchema.entityID(from: record.recordID.recordName),
              name: "", category: "other")
    apply(record)
  }
}

extension GroceryCategoryEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: GroceryCategoryCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: GroceryCategoryCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[GroceryCategoryCloudKitSchema.Field.name] = name
    record[GroceryCategoryCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[GroceryCategoryCloudKitSchema.Field.name] as? String { name = value }
    if let value = record[GroceryCategoryCloudKitSchema.Field.sortIndex] as? Int { sortIndex = value }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: GroceryCategoryCloudKitSchema.entityID(from: record.recordID.recordName), name: "")
    apply(record)
  }
}

extension ExerciseEntryEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: ExerciseEntryCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: ExerciseEntryCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[ExerciseEntryCloudKitSchema.Field.date] = date
    record[ExerciseEntryCloudKitSchema.Field.sessionType] = sessionType
    record[ExerciseEntryCloudKitSchema.Field.exercise] = exercise
    record[ExerciseEntryCloudKitSchema.Field.weight] = weight
    record[ExerciseEntryCloudKitSchema.Field.sets] = sets
    record[ExerciseEntryCloudKitSchema.Field.reps] = reps
    record[ExerciseEntryCloudKitSchema.Field.difficulty] = difficulty
    record[ExerciseEntryCloudKitSchema.Field.durationMin] = durationMin
    record[ExerciseEntryCloudKitSchema.Field.distanceM] = distanceM
    record[ExerciseEntryCloudKitSchema.Field.level] = level
    record[ExerciseEntryCloudKitSchema.Field.note] = note
    record[ExerciseEntryCloudKitSchema.Field.concludedAt] = concludedAt
    record[ExerciseEntryCloudKitSchema.Field.loggedAt] = loggedAt
    record[ExerciseEntryCloudKitSchema.Field.occurredAt] = occurredAt as NSDate
    return record
  }

  func apply(_ record: CKRecord) {
    if let v = record[ExerciseEntryCloudKitSchema.Field.date] as? String { date = v }
    if let v = record[ExerciseEntryCloudKitSchema.Field.sessionType] as? String { sessionType = v }
    if let v = record[ExerciseEntryCloudKitSchema.Field.exercise] as? String { exercise = v }
    weight = record[ExerciseEntryCloudKitSchema.Field.weight] as? Double
    sets = optionalChecklistString(record[ExerciseEntryCloudKitSchema.Field.sets])
    reps = optionalChecklistString(record[ExerciseEntryCloudKitSchema.Field.reps])
    difficulty = optionalChecklistString(record[ExerciseEntryCloudKitSchema.Field.difficulty])
    durationMin = record[ExerciseEntryCloudKitSchema.Field.durationMin] as? Double
    distanceM = record[ExerciseEntryCloudKitSchema.Field.distanceM] as? Double
    level = record[ExerciseEntryCloudKitSchema.Field.level] as? Double
    note = optionalChecklistString(record[ExerciseEntryCloudKitSchema.Field.note])
    concludedAt = optionalChecklistString(record[ExerciseEntryCloudKitSchema.Field.concludedAt])
    loggedAt = optionalChecklistString(record[ExerciseEntryCloudKitSchema.Field.loggedAt])
    if let v = record[ExerciseEntryCloudKitSchema.Field.occurredAt] as? Date { occurredAt = v }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: ExerciseEntryCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "", sessionType: "", exercise: "")
    apply(record)
  }
}

extension ExerciseDefinitionEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: ExerciseDefinitionCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: ExerciseDefinitionCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[ExerciseDefinitionCloudKitSchema.Field.name] = name
    record[ExerciseDefinitionCloudKitSchema.Field.type] = type
    record[ExerciseDefinitionCloudKitSchema.Field.subgroup] = subgroup
    record[ExerciseDefinitionCloudKitSchema.Field.aliases] = aliases as NSArray
    record[ExerciseDefinitionCloudKitSchema.Field.sortIndex] = sortIndex
    record[ExerciseDefinitionCloudKitSchema.Field.primaryMuscle] = primaryMuscle
    record[ExerciseDefinitionCloudKitSchema.Field.secondaryMuscles] = secondaryMuscles as NSArray
    record[ExerciseDefinitionCloudKitSchema.Field.archived] = Int64(archived ? 1 : 0)
    return record
  }

  func apply(_ record: CKRecord) {
    if let v = record[ExerciseDefinitionCloudKitSchema.Field.name] as? String { name = v }
    if let v = record[ExerciseDefinitionCloudKitSchema.Field.type] as? String { type = v }
    subgroup = optionalChecklistString(record[ExerciseDefinitionCloudKitSchema.Field.subgroup])
    aliases = (record[ExerciseDefinitionCloudKitSchema.Field.aliases] as? [String]) ?? []
    if let v = record[ExerciseDefinitionCloudKitSchema.Field.sortIndex] as? Int { sortIndex = v }
    primaryMuscle = optionalChecklistString(record[ExerciseDefinitionCloudKitSchema.Field.primaryMuscle])
    secondaryMuscles = (record[ExerciseDefinitionCloudKitSchema.Field.secondaryMuscles] as? [String]) ?? []
    archived = (record[ExerciseDefinitionCloudKitSchema.Field.archived] as? Int64).map { $0 != 0 } ?? false
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: ExerciseDefinitionCloudKitSchema.entityID(from: record.recordID.recordName),
              name: "", type: "strength")
    apply(record)
  }
}

extension SessionTypeEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: SessionTypeCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: SessionTypeCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[SessionTypeCloudKitSchema.Field.label] = label
    record[SessionTypeCloudKitSchema.Field.emoji] = emoji
    record[SessionTypeCloudKitSchema.Field.exercises] = exercises as NSArray
    record[SessionTypeCloudKitSchema.Field.sortIndex] = sortIndex
    record[SessionTypeCloudKitSchema.Field.archived] = Int64(archived ? 1 : 0)
    // Only write `kind` when we have one — keeps records written by
    // an older client minimal until the user (or migration) sets it.
    if let kindRaw { record[SessionTypeCloudKitSchema.Field.kind] = kindRaw }
    return record
  }

  func apply(_ record: CKRecord) {
    if let v = record[SessionTypeCloudKitSchema.Field.label] as? String { label = v }
    emoji = optionalChecklistString(record[SessionTypeCloudKitSchema.Field.emoji])
    exercises = (record[SessionTypeCloudKitSchema.Field.exercises] as? [String]) ?? []
    if let v = record[SessionTypeCloudKitSchema.Field.sortIndex] as? Int { sortIndex = v }
    archived = (record[SessionTypeCloudKitSchema.Field.archived] as? Int64).map { $0 != 0 } ?? false
    // Missing kind in the CK record (legacy) leaves `kindRaw` nil; the
    // entity→config bridge fills in `SessionKind.defaulted(for: id)`.
    kindRaw = optionalChecklistString(record[SessionTypeCloudKitSchema.Field.kind])
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: SessionTypeCloudKitSchema.entityID(from: record.recordID.recordName), label: "")
    apply(record)
  }
}

extension NutritionEntryEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: NutritionEntryCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: NutritionEntryCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[NutritionEntryCloudKitSchema.Field.loggedAt]      = loggedAt as NSDate
    record[NutritionEntryCloudKitSchema.Field.emoji]         = emoji
    record[NutritionEntryCloudKitSchema.Field.foods]         = foods
    record[NutritionEntryCloudKitSchema.Field.ingredients]   = ingredients
    record[NutritionEntryCloudKitSchema.Field.note]          = note
    record[NutritionEntryCloudKitSchema.Field.mealType]      = mealType
    record[NutritionEntryCloudKitSchema.Field.source]        = source
    record[NutritionEntryCloudKitSchema.Field.proteinG]      = proteinG
    record[NutritionEntryCloudKitSchema.Field.fatG]          = fatG
    record[NutritionEntryCloudKitSchema.Field.carbsG]        = carbsG
    record[NutritionEntryCloudKitSchema.Field.fiberG]        = fiberG
    record[NutritionEntryCloudKitSchema.Field.sugarG]        = sugarG
    record[NutritionEntryCloudKitSchema.Field.saturatedFatG] = saturatedFatG
    record[NutritionEntryCloudKitSchema.Field.alcoholG]      = alcoholG
    record[NutritionEntryCloudKitSchema.Field.kcal]          = kcal
    record[NutritionEntryCloudKitSchema.Field.sodiumMg]      = sodiumMg
    record[NutritionEntryCloudKitSchema.Field.cholesterolMg] = cholesterolMg
    record[NutritionEntryCloudKitSchema.Field.potassiumMg]   = potassiumMg
    record[NutritionEntryCloudKitSchema.Field.waterMl]       = waterMl
    record[NutritionEntryCloudKitSchema.Field.photoAssetID]  = photoAssetID
    return record
  }

  func apply(_ record: CKRecord) {
    if let v = record[NutritionEntryCloudKitSchema.Field.loggedAt] as? Date { loggedAt = v }
    emoji         = optionalChecklistString(record[NutritionEntryCloudKitSchema.Field.emoji])
    if let v = record[NutritionEntryCloudKitSchema.Field.foods] as? String { foods = v }
    ingredients   = optionalChecklistString(record[NutritionEntryCloudKitSchema.Field.ingredients])
    note          = optionalChecklistString(record[NutritionEntryCloudKitSchema.Field.note])
    mealType      = optionalChecklistString(record[NutritionEntryCloudKitSchema.Field.mealType])
    source        = optionalChecklistString(record[NutritionEntryCloudKitSchema.Field.source])
    if let v = record[NutritionEntryCloudKitSchema.Field.proteinG] as? Double { proteinG = v }
    if let v = record[NutritionEntryCloudKitSchema.Field.fatG]     as? Double { fatG     = v }
    if let v = record[NutritionEntryCloudKitSchema.Field.carbsG]   as? Double { carbsG   = v }
    fiberG        = record[NutritionEntryCloudKitSchema.Field.fiberG]        as? Double
    sugarG        = record[NutritionEntryCloudKitSchema.Field.sugarG]        as? Double
    saturatedFatG = record[NutritionEntryCloudKitSchema.Field.saturatedFatG] as? Double
    alcoholG      = record[NutritionEntryCloudKitSchema.Field.alcoholG]      as? Double
    kcal          = record[NutritionEntryCloudKitSchema.Field.kcal]          as? Double
    sodiumMg      = record[NutritionEntryCloudKitSchema.Field.sodiumMg]      as? Double
    cholesterolMg = record[NutritionEntryCloudKitSchema.Field.cholesterolMg] as? Double
    potassiumMg   = record[NutritionEntryCloudKitSchema.Field.potassiumMg]   as? Double
    waterMl       = record[NutritionEntryCloudKitSchema.Field.waterMl]       as? Double
    photoAssetID  = optionalChecklistString(record[NutritionEntryCloudKitSchema.Field.photoAssetID])
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: NutritionEntryCloudKitSchema.entityID(from: record.recordID.recordName))
    apply(record)
  }
}

extension NutritionDailySummaryEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: NutritionDailySummaryCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: NutritionDailySummaryCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[NutritionDailySummaryCloudKitSchema.Field.date]          = date
    record[NutritionDailySummaryCloudKitSchema.Field.entryCount]    = entryCount
    record[NutritionDailySummaryCloudKitSchema.Field.computedAt]    = computedAt as NSDate
    record[NutritionDailySummaryCloudKitSchema.Field.firstLoggedAt] = firstLoggedAt.map { $0 as NSDate }
    record[NutritionDailySummaryCloudKitSchema.Field.lastLoggedAt]  = lastLoggedAt.map  { $0 as NSDate }
    record[NutritionDailySummaryCloudKitSchema.Field.kcal]          = kcal
    record[NutritionDailySummaryCloudKitSchema.Field.proteinG]      = proteinG
    record[NutritionDailySummaryCloudKitSchema.Field.fatG]          = fatG
    record[NutritionDailySummaryCloudKitSchema.Field.carbsG]        = carbsG
    record[NutritionDailySummaryCloudKitSchema.Field.fiberG]        = fiberG
    record[NutritionDailySummaryCloudKitSchema.Field.sugarG]        = sugarG
    record[NutritionDailySummaryCloudKitSchema.Field.saturatedFatG] = saturatedFatG
    record[NutritionDailySummaryCloudKitSchema.Field.alcoholG]      = alcoholG
    record[NutritionDailySummaryCloudKitSchema.Field.sodiumMg]      = sodiumMg
    record[NutritionDailySummaryCloudKitSchema.Field.cholesterolMg] = cholesterolMg
    record[NutritionDailySummaryCloudKitSchema.Field.potassiumMg]   = potassiumMg
    record[NutritionDailySummaryCloudKitSchema.Field.waterMl]       = waterMl
    return record
  }

  func apply(_ record: CKRecord) {
    if let v = record[NutritionDailySummaryCloudKitSchema.Field.date] as? String { date = v }
    if let v = record[NutritionDailySummaryCloudKitSchema.Field.entryCount] as? Int { entryCount = v }
    if let v = record[NutritionDailySummaryCloudKitSchema.Field.computedAt]    as? Date { computedAt    = v }
    firstLoggedAt = record[NutritionDailySummaryCloudKitSchema.Field.firstLoggedAt] as? Date
    lastLoggedAt  = record[NutritionDailySummaryCloudKitSchema.Field.lastLoggedAt]  as? Date
    kcal          = record[NutritionDailySummaryCloudKitSchema.Field.kcal]          as? Double
    proteinG      = record[NutritionDailySummaryCloudKitSchema.Field.proteinG]      as? Double
    fatG          = record[NutritionDailySummaryCloudKitSchema.Field.fatG]          as? Double
    carbsG        = record[NutritionDailySummaryCloudKitSchema.Field.carbsG]        as? Double
    fiberG        = record[NutritionDailySummaryCloudKitSchema.Field.fiberG]        as? Double
    sugarG        = record[NutritionDailySummaryCloudKitSchema.Field.sugarG]        as? Double
    saturatedFatG = record[NutritionDailySummaryCloudKitSchema.Field.saturatedFatG] as? Double
    alcoholG      = record[NutritionDailySummaryCloudKitSchema.Field.alcoholG]      as? Double
    sodiumMg      = record[NutritionDailySummaryCloudKitSchema.Field.sodiumMg]      as? Double
    cholesterolMg = record[NutritionDailySummaryCloudKitSchema.Field.cholesterolMg] as? Double
    potassiumMg   = record[NutritionDailySummaryCloudKitSchema.Field.potassiumMg]   as? Double
    waterMl       = record[NutritionDailySummaryCloudKitSchema.Field.waterMl]       as? Double
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: NutritionDailySummaryCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "")
    apply(record)
  }
}

extension ActivityDayEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: ActivityDayCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: ActivityDayCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[ActivityDayCloudKitSchema.Field.date]            = date
    record[ActivityDayCloudKitSchema.Field.stepCount]       = stepCount
    record[ActivityDayCloudKitSchema.Field.activeKcal]      = activeKcal
    record[ActivityDayCloudKitSchema.Field.exerciseMinutes] = exerciseMinutes
    return record
  }

  func apply(_ record: CKRecord) {
    if let v = record[ActivityDayCloudKitSchema.Field.date] as? String { date = v }
    stepCount       = record[ActivityDayCloudKitSchema.Field.stepCount]       as? Int
    activeKcal      = record[ActivityDayCloudKitSchema.Field.activeKcal]      as? Double
    exerciseMinutes = record[ActivityDayCloudKitSchema.Field.exerciseMinutes] as? Int
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: ActivityDayCloudKitSchema.entityID(from: record.recordID.recordName),
              date: "")
    apply(record)
  }
}

// MARK: - LocalStore

@MainActor
final class LocalStore {
  static let shared = LocalStore()

  let container: ModelContainer

  private init() {
    let schema = Schema([TaskEntity.self, ProjectEntity.self, AreaEntity.self,
                         SettingsEntity.self, SectionEntity.self,
                         HabitDefinitionEntity.self, HabitDayStateEntity.self,
                         SupplementDefinitionEntity.self, SupplementDayStateEntity.self,
                         ChoreDefinitionEntity.self, ChoreEventEntity.self,
                         ChoreSnapshotEntity.self,
                         GoalEntity.self,
                         GoalMilestoneEntity.self,
                         CoachVoiceEntity.self,
                         CoachMessageEntity.self,
                         GutEventEntity.self,
                         MoodEventEntity.self,
                         SymptomDefinitionEntity.self, SymptomEventEntity.self,
                         MedicationDefinitionEntity.self, MedicationDoseEventEntity.self,
                         IntakeKindEntity.self, IntakeItemEntity.self,
                         IntakeEventEntity.self,
                         GroceryItemEntity.self, GroceryCategoryEntity.self,
                         ExerciseEntryEntity.self, ExerciseDefinitionEntity.self,
                         SessionTypeEntity.self,
                         NutritionEntryEntity.self, NutritionDailySummaryEntity.self,
                         ActivityDayEntity.self,
                         OuraNightEntity.self,
                         WithingsRowEntity.self,
                         QuoteEntity.self])
    // Explicitly opt OUT of NSPersistentCloudKitContainer mirroring. Having
    // CloudKit in the target entitlements would otherwise switch SwiftData
    // into auto-mirror mode, which requires all-optional attributes and
    // disallows @Attribute(.unique) — neither of which our model honors.
    // We sync via CKSyncEngine instead (see CKEngine.swift); SwiftData is
    // strictly a local cache. `.none` is the disable switch.
    // Screenshot / UI-test builds (`-SeptenaSeed`) run against a throwaway
    // in-memory store so the app boots offline with seeded demo data and never
    // touches the real on-disk store. Release builds force `isOn` false.
    let config = DemoSeedMode.isOn
      ? ModelConfiguration("Septena", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      : ModelConfiguration("Septena", schema: schema, cloudKitDatabase: .none)
    do {
      container = try ModelContainer(for: schema, configurations: [config])
    } catch let error {
      // Never erase a local-first store as a recovery mechanism. It can
      // contain writes that have not reached CloudKit yet (offline work,
      // failed sends, or a first launch after a device restore). Preserve the
      // files for a migration/repair build instead of silently discarding data.
      Log.persistence.fault("ModelContainer init failed; local store preserved: \(error.localizedDescription, privacy: .public)")
      fatalError("Local database could not be opened. Its files were preserved; install a compatible repair build rather than deleting Septena data. \(error)")
    }
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
    (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.deletedAt == nil }
    ))) ?? []
  }

  /// Every non-trashed task as a wire DTO — sidebar roll-ups, aggregates.
  /// Headings are dividers, not to-dos: excluded so they never inflate any
  /// count or aggregate (see `TaskEntity.isHeading`).
  @MainActor
  static func liveTasks(in context: ModelContext) -> [SeptenaTask] {
    liveEntities(in: context)
      .filter { !$0.pendingDeletion && !$0.isHeading }
      .map(SeptenaTask.init)
  }

  /// Assigned, non-cancelled tasks — the SuggestionEngine training corpus.
  /// Unassigned inbox/logbook rows don't teach filing targets.
  @MainActor
  static func trainingTasks(in context: ModelContext) -> [SeptenaTask] {
    let candidates = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { e in
        e.deletedAt == nil && !e.pendingDeletion && e.kind != "heading"
      },
      sortBy: [SortDescriptor(\.id)]
    ))) ?? []
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
    (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { e in
        e.deletedAt == nil && !e.pendingDeletion
          && e.project != nil && e.kind != "heading"
      }
    )))?.map(SeptenaTask.init) ?? []
  }

  /// Completion ratios for project headers. Keep this as an entity aggregate
  /// so a normal task-list refresh does not allocate one DTO per historical
  /// task merely to compute two integer counters.
  @MainActor
  static func projectCompletionRatios(in context: ModelContext) -> [String: Double] {
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { e in
        e.deletedAt == nil && !e.pendingDeletion
          && e.project != nil && e.kind != "heading"
      }
    ))) ?? []
    var done: [String: Int] = [:]
    var total: [String: Int] = [:]
    for row in rows {
      guard let project = row.project else { continue }
      switch row.status {
      case .done:
        done[project, default: 0] += 1
        total[project, default: 0] += 1
      case .open:
        total[project, default: 0] += 1
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
    (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { e in
        e.deletedAt == nil && !e.pendingDeletion
          && e.project == projectId && e.kind == "heading"
      }
    )))?
      .sorted { TaskOrder.key($0) != TaskOrder.key($1)
                  ? TaskOrder.key($0) < TaskOrder.key($1) : $0.id < $1.id }
      .map(SeptenaTask.init) ?? []
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
      return (try? context.fetch(FetchDescriptor<TaskEntity>(
        predicate: #Predicate { $0.deletedAt != nil }
      ))) ?? []
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
      return (try? context.fetch(descriptor)) ?? []
    case .project(let pid):
      let projectId = pid
      return (try? context.fetch(FetchDescriptor<TaskEntity>(
        predicate: #Predicate { e in
          e.deletedAt == nil && !e.pendingDeletion && e.project == projectId
        }
      ))) ?? []
    case .area(let aid):
      let areaId = aid
      return (try? context.fetch(FetchDescriptor<TaskEntity>(
        predicate: #Predicate { e in
          e.deletedAt == nil && !e.pendingDeletion && e.area == areaId
        }
      ))) ?? []
    case .today, .triage, .upcoming, .unscheduled:
      return (try? context.fetch(FetchDescriptor<TaskEntity>(
        predicate: #Predicate { e in
          e.deletedAt == nil && !e.pendingDeletion && e.statusRaw == "open"
        }
      ))) ?? []
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
    let result = rows
      .compactMap { e -> (key: Double, id: String, task: SeptenaTask)? in
        guard let task = convert(e, filter: filter, today: today) else { return nil }
        return (TaskOrder.key(e), e.id, task)
      }
      .sorted { a, b in a.key != b.key ? a.key < b.key : a.id < b.id }
      .map(\.task)
    // The Completed (logbook) view reads as an archive — most-recently-completed
    // first. Every other view keeps manual/creation order (TaskOrder.key).
    if case .logbook = filter {
      return result.sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
    }
    return result
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
    guard let entity = try? context.fetch(descriptor).first else { return false }
    let today = SeptenaDate.today
    if filter == .today {
      return convert(entity, filter: .today, today: today) != nil
        || convert(entity, filter: .triage, today: today) != nil
    }
    return convert(entity, filter: filter, today: today) != nil
  }

  /// One row through the filter: nil when the row doesn't belong to `filter`,
  /// the wire DTO when it does. Extracted from the inline closure above so
  /// the (key, id) decoration stays readable.
  @MainActor
  private static func convert(_ e: TaskEntity, filter: TaskFilter,
                              today: String) -> SeptenaTask? {
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
    case .upcoming:
      guard e.status == .open, !e.today else { return nil }
      if let s = e.scheduled, s > today { return SeptenaTask(e) }
      if let d = e.deadline, d > today { return SeptenaTask(e) }
      return nil
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
    case .recentlyDeleted:
      // Handled by the early-return above; unreachable here.
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
  static func completedIDs(among ids: Set<String>, in context: ModelContext) -> Set<String> {
    guard !ids.isEmpty else { return [] }
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
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
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
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
    let areas = (try? context.fetch(FetchDescriptor<AreaEntity>())) ?? []
    let projects = (try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? []
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
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
    return rows.reduce(0) { acc, e in
      guard e.deletedAt == nil, !e.pendingDeletion,
            e.status == .open, let d = e.deadline, d <= today else { return acc }
      return acc + 1
    }
  }

  @MainActor
  static func goals(in context: ModelContext) -> [Goal] {
    let descriptor = FetchDescriptor<GoalEntity>(
      sortBy: [SortDescriptor(\.sortIndex, order: .reverse),
               SortDescriptor(\.updatedAt, order: .reverse)]
    )
    let rows = (try? context.fetch(descriptor)) ?? []
    return rows.map(Goal.init)
  }

  @MainActor
  static func areas(in context: ModelContext) -> [Area] {
    let descriptor = FetchDescriptor<AreaEntity>(sortBy: [SortDescriptor(\.title)])
    let rows = (try? context.fetch(descriptor)) ?? []
    return rows.map(Area.init)
  }

  @MainActor
  static func projects(in context: ModelContext) -> [Project] {
    let descriptor = FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.title)])
    let rows = (try? context.fetch(descriptor)) ?? []
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
@MainActor
enum StructureCache {
  private static var cached: (areas: [Area], projects: [Project])?
  private static var observerInstalled = false

  static func snapshot(in context: ModelContext) -> (areas: [Area], projects: [Project]) {
    installObserverIfNeeded()
    if let cached { return cached }
    let snap = (areas: LocalCache.areas(in: context),
                projects: LocalCache.projects(in: context))
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

// MARK: - LoggedEvent (cross-section read abstraction)

/// Uniform read view over every logged "event" entity, keyed on the real
/// instant it happened — `occurredAt` for most sections, `loggedAt` for
/// nutrition/hydration (aliased below). Lets analysis, timelines, and the
/// gateway iterate all sections without per-type code. Read-only projection —
/// it does not change how rows are stored or written.
protocol LoggedEvent {
  var id: String { get }
  var occurredAt: Date { get }
  var sectionKey: String { get }
  /// Optional intrinsic "size" of the event, for proportional visualization
  /// (meal kcal on the rhythm wheel). `nil` = no magnitude; the consumer uses
  /// its default. Defaulted to `nil` so only sections that have one override it.
  var magnitude: Double? { get }
}

extension LoggedEvent {
  var magnitude: Double? { nil }
}

extension GutEventEntity: LoggedEvent { var sectionKey: String { "gut" } }
extension MoodEventEntity: LoggedEvent { var sectionKey: String { "mood" } }
extension SymptomEventEntity: LoggedEvent { var sectionKey: String { "symptoms" } }
extension MedicationDoseEventEntity: LoggedEvent { var sectionKey: String { "medications" } }
extension ChoreEventEntity: LoggedEvent { var sectionKey: String { "chores" } }
extension HabitDayStateEntity: LoggedEvent { var sectionKey: String { "habits" } }
extension SupplementDayStateEntity: LoggedEvent { var sectionKey: String { "supplements" } }
extension ExerciseEntryEntity: LoggedEvent { var sectionKey: String { "training" } }
extension IntakeEventEntity: LoggedEvent { var sectionKey: String { "intake" } }

/// Nutrition (and hydration, which rides on the same entity) stores its instant
/// as `loggedAt` — always populated, no `.distantPast` sentinel — rather than
/// `occurredAt`, and the CloudKit field name stays `loggedAt`. Aliasing it here
/// brings meals and water into the unified timeline and elapsed-time queries
/// without a schema change or data migration.
extension NutritionEntryEntity: LoggedEvent {
  var occurredAt: Date { loggedAt }
  var sectionKey: String { "nutrition" }
  /// Meal size = caloric energy, when present (>0) — the same kcal the meal
  /// detail row sizes its macro bar against. Drives the rhythm wheel's
  /// proportional meal dots; pure-hydration rows (water, no kcal) carry no
  /// magnitude and fall back to the default dot size.
  var magnitude: Double? { (kcal ?? 0) > 0 ? kcal : nil }
}

/// Cross-section event queries powered by `occurredAt` — the payoff of the
/// occurredAt migration: elapsed-time and unified-timeline questions the
/// per-section `date`/`time` strings couldn't answer. Fetches the full event
/// set and merges in memory; fine for personal-scale data (low thousands of
/// rows). Narrow via `sectionKey` for hot paths if it ever matters.
@MainActor
enum LoggedEvents {
  private static func all(in context: ModelContext) -> [any LoggedEvent] {
    var out: [any LoggedEvent] = []
    func add<E: PersistentModel & LoggedEvent>(_ type: E.Type) {
      let rows = (try? context.fetch(FetchDescriptor<E>())) ?? []
      out.append(contentsOf: rows.map { $0 as any LoggedEvent })
    }
    add(GutEventEntity.self)
    add(MoodEventEntity.self)
    add(SymptomEventEntity.self)
    add(MedicationDoseEventEntity.self)
    add(ChoreEventEntity.self)
    add(HabitDayStateEntity.self)
    add(SupplementDayStateEntity.self)
    add(ExerciseEntryEntity.self)
    add(IntakeEventEntity.self)
    add(NutritionEntryEntity.self)
    return out
  }

  /// Every logged event, newest first, capped at `limit`.
  static func recent(limit: Int = 50, in context: ModelContext) -> [any LoggedEvent] {
    Array(all(in: context).sorted { $0.occurredAt > $1.occurredAt }.prefix(limit))
  }

  /// Events at or after `date`, newest first; optionally scoped to one section.
  /// Predicates each fetch on the stored instant (like `timed`), so only the
  /// window is materialized regardless of how much total history exists.
  static func since(_ date: Date, sectionKey: String? = nil, in context: ModelContext) -> [any LoggedEvent] {
    var out: [any LoggedEvent] = []
    func add<E: PersistentModel & LoggedEvent>(_ desc: FetchDescriptor<E>) {
      let rows = (try? context.fetch(desc)) ?? []
      out.append(contentsOf: rows.map { $0 as any LoggedEvent })
    }
    add(FetchDescriptor<GutEventEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    add(FetchDescriptor<MoodEventEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    add(FetchDescriptor<SymptomEventEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    add(FetchDescriptor<MedicationDoseEventEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    add(FetchDescriptor<ChoreEventEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    add(FetchDescriptor<HabitDayStateEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    add(FetchDescriptor<SupplementDayStateEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    add(FetchDescriptor<ExerciseEntryEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    add(FetchDescriptor<IntakeEventEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    // Nutrition stores its instant as `loggedAt` (occurredAt is a computed alias).
    add(FetchDescriptor<NutritionEntryEntity>(predicate: #Predicate { $0.loggedAt >= date }))
    return out
      .filter { sectionKey == nil || $0.sectionKey == sectionKey }
      .sorted { $0.occurredAt > $1.occurredAt }
  }

  /// The most recent event in a section (e.g. last coffee), or nil.
  static func mostRecent(sectionKey: String, in context: ModelContext) -> (any LoggedEvent)? {
    all(in: context).filter { $0.sectionKey == sectionKey }.max { $0.occurredAt < $1.occurredAt }
  }

  /// Seconds since the last event in a section — the "how long since my last
  /// coffee" primitive. nil if nothing is logged in that section.
  static func timeSinceLast(sectionKey: String, in context: ModelContext, now: Date = Date()) -> TimeInterval? {
    mostRecent(sectionKey: sectionKey, in: context).map { now.timeIntervalSince($0.occurredAt) }
  }

  /// Public, `Sendable` projection of every timestamped event at/after `date`,
  /// newest first. The cross-module entry point for time-of-day visualization
  /// (the homepage rhythm wheel) — keeps the `any LoggedEvent` protocol
  /// internal while handing the app module only flat, value-type rows.
  ///
  /// Unlike `since` (which scans *all* history then filters), this predicates
  /// each fetch on the stored instant, so it touches only the window — a
  /// 7-day window stays fast regardless of how much total history exists.
  ///
  /// `nonisolated` (the rest of `LoggedEvents` is `@MainActor`): it takes its
  /// `ModelContext` as a parameter, touches no main-actor state, and returns
  /// only `Sendable` value rows — so the rhythm dial can run it on a background
  /// context off the main thread. Still callable from the main actor as before.
  public nonisolated static func timed(since date: Date, in context: ModelContext) -> [TimedEvent] {
    var out: [TimedEvent] = []
    func grab<E: PersistentModel & LoggedEvent>(_ desc: FetchDescriptor<E>) {
      let rows = (try? context.fetch(desc)) ?? []
      out.append(contentsOf: rows.map {
        TimedEvent(id: $0.id, sectionKey: $0.sectionKey, occurredAt: $0.occurredAt,
                   magnitude: $0.magnitude)
      })
    }
    grab(FetchDescriptor<GutEventEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    grab(FetchDescriptor<MoodEventEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    grab(FetchDescriptor<ChoreEventEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    grab(FetchDescriptor<HabitDayStateEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    grab(FetchDescriptor<SupplementDayStateEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    grab(FetchDescriptor<ExerciseEntryEntity>(predicate: #Predicate { $0.occurredAt >= date }))
    // Intake is intentionally omitted here — the rhythm wheel plots it via a
    // custom path that colors each dot by its *kind* (per-kind color), which
    // this section-keyed projection can't carry. It stays in `all`/`since`
    // for the section-level "time since last" queries.
    // Nutrition stores its instant as `loggedAt` (occurredAt is a computed alias).
    grab(FetchDescriptor<NutritionEntryEntity>(predicate: #Predicate { $0.loggedAt >= date }))
    return out.sorted { $0.occurredAt > $1.occurredAt }
  }
}

/// A flattened, `Sendable` logged event for cross-module viz — the section it
/// belongs to and the instant it happened. Carries only what a time-of-day
/// plot needs, so the storage entities and the `LoggedEvent` protocol stay
/// inside SeptenaCore.
public struct TimedEvent: Sendable, Identifiable {
  public let id: String
  public let sectionKey: String
  public let occurredAt: Date
  /// Optional intrinsic size (meal kcal) for proportional plotting; `nil` for
  /// sections with no magnitude. Defaulted so existing call sites are unaffected.
  public var magnitude: Double? = nil
}
