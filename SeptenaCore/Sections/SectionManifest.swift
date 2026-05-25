import SwiftUI

// SectionManifest — the local, hard-coded catalog of every Septena
// section ("mini-app"). One row per section, with the metadata needed
// to render the Settings sidebar and to drive a future App-Store-style
// install/uninstall flow.
//
// What's here (catalog-level facts about the section itself):
//   key, defaultLabel, shortDescription, activation, onboarding,
//   supportsTab, supportsDashboard, settingsEditor
//
// What's NOT here:
//   • color   — a per-account preference. Lives in the CloudKit-backed
//               `SectionEntity` (mirrored to SwiftData via CKEngine).
//               There is no catalog "default color"; sections with no
//               preference render neutral.
//   • icon    — Septena has no per-section icon vocabulary yet. When
//               we design one, it'll be a separate concern (asset
//               catalog + design system), not a guessed SF Symbol per
//               row baked into a Swift file.
//
// Resolution order at runtime:
//   1. `SectionManifest.byKey[key]`        — catalog facts
//   2. `SectionEntity` row, if installed   — user label override + color
//   3. Manifest defaultLabel               — fallback
//
// Visibility on the dashboard / Settings sidebar gates on whether the
// user has a `SectionEntity` for the key. Until proper install UX
// lands, newly-shipped sections (e.g. `mood`) are backfilled by
// `SettingsMirror.seedManifestSectionIfMissing` at `SeptenaServices.start`.

public struct SectionManifest: Sendable, Hashable, Identifiable {
  /// Stable key. Matches the webapp's `sections/manifest.json` and the
  /// `SectionEntity.id` value, so the same string addresses a section
  /// across iOS, web, and CloudKit.
  public let key: String

  /// Default display label. The user's `SectionEntity.title` (when
  /// installed) overrides this at render time so renames stick; the
  /// manifest value is the catalog default and the fallback when no
  /// SectionEntity exists yet.
  public let defaultLabel: String

  /// One-line catalog blurb shown in the future Browse Sections screen
  /// when a section isn't yet installed. Kept short — sentence case, no
  /// trailing period (matches iOS Settings app descriptions).
  public let shortDescription: String

  /// How the section is activated for a new account.
  public let activation: Activation

  /// Whether the section is shown in the default catalog. `.hidden`
  /// keeps it routable but out of the picker (legacy / dev sections).
  public let onboarding: Onboarding

  /// Surfaces this section can appear on. Informational today; will
  /// drive per-section visibility toggles in the per-section page.
  public let supportsTab: Bool
  public let supportsDashboard: Bool

  /// What kind of per-section settings page this section shows. Mirrors
  /// the webapp's `settings_editor` field. Drives whether the page is
  /// identity-only or includes an editable list.
  public let settingsEditor: SettingsEditor

  public var id: String { key }

  /// Whether the user can turn this section off. `.always` sections are
  /// locked on; everything else can be disabled from Settings.
  public var canDisable: Bool { activation != .always }

  /// Sections that contribute events to the Today log. Source of truth
  /// for whether a "Show in Today" toggle is offered in Settings. Kept
  /// as a static set here (rather than a per-entry init field) so that
  /// the manifest entries stay terse — `TodayLogView` is the consumer.
  public static let todayCapableKeys: Set<String> = [
    "tasks", "habits", "supplements", "chores",
    "training", "nutrition",
    "caffeine", "cannabis", "gut", "mood",
  ]

  /// Whether this section has any presence on the Today timeline.
  public var appearsInToday: Bool {
    SectionManifest.todayCapableKeys.contains(key)
  }

  /// Default `isEnabled` for a freshly-seeded `SectionEntity`. `.always`
  /// is always on. `.core`-onboarding sections start on; `.optional`
  /// and `.hidden` start off. `.integration` sections wait for the
  /// integration to be authorized before turning on.
  public var defaultEnabled: Bool {
    switch activation {
    case .always: return true
    case .integration: return false
    case .optional:
      switch onboarding {
      case .core: return true
      case .optional, .hidden: return false
      }
    }
  }

  public enum Activation: String, Sendable, Hashable {
    /// Always installed; the user cannot uninstall.
    case always
    /// User installs from the catalog.
    case optional
    /// Requires an external grant (EventKit, HealthKit) before it works.
    case integration
  }

  public enum Onboarding: String, Sendable, Hashable {
    /// Suggested as installed by default for a new account.
    case core
    /// Shown in the catalog, off by default.
    case optional
    /// Not shown in the catalog (still routable if installed manually).
    case hidden
  }

  public enum SettingsEditor: String, Sendable, Hashable {
    /// Identity-only page (color, label).
    case none
    /// Identity + visibility toggles.
    case appearance
    /// Identity + editable list of catalog items (strains, beans, …).
    case sectionConfig
  }
}

public extension SectionManifest {
  /// The full predetermined catalog. Order here is the *catalog*
  /// display order (and the eventual fallback for sidebar order when
  /// no server `section_order` is available). The Settings sidebar
  /// today still orders rows by the server's `section_order`.
  static let all: [SectionManifest] = [
    .init(
      key: "tasks",
      defaultLabel: "Tasks",
      shortDescription: "Inbox, projects, areas, today and upcoming",
      // Tasks is .optional like every other section: disabling never
      // deletes data, and the architecture's data-preservation
      // guarantees make a hard lock unnecessary. .always remains in
      // the enum for future hypothetical "infrastructure" sections.
      activation: .optional,
      onboarding: .core,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .none
    ),
    .init(
      key: "training",
      defaultLabel: "Training",
      shortDescription: "Sessions, exercises, weekly Z2",
      activation: .optional,
      onboarding: .core,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "nutrition",
      defaultLabel: "Nutrition",
      shortDescription: "Macros and calorie ranges",
      activation: .optional,
      onboarding: .core,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "sleep",
      defaultLabel: "Sleep",
      shortDescription: "Bed and wake times, nightly duration",
      activation: .optional,
      onboarding: .core,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .appearance
    ),
    .init(
      key: "habits",
      defaultLabel: "Habits",
      shortDescription: "Daily routines and streaks",
      activation: .optional,
      onboarding: .core,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "chores",
      defaultLabel: "Chores",
      shortDescription: "Recurring household tasks",
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "supplements",
      defaultLabel: "Supplements",
      shortDescription: "Daily supplements log",
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "groceries",
      defaultLabel: "Groceries",
      shortDescription: "Shopping list and pantry",
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "caffeine",
      defaultLabel: "Caffeine",
      shortDescription: "Coffee, beans, brewing methods",
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "cannabis",
      defaultLabel: "Cannabis",
      shortDescription: "Strain log and dosing",
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "body",
      defaultLabel: "Body",
      shortDescription: "Weight, body fat, measurements",
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .appearance
    ),
    .init(
      key: "gut",
      defaultLabel: "Gut",
      shortDescription: "Digestion log",
      activation: .optional,
      onboarding: .optional,
      supportsTab: false,
      supportsDashboard: true,
      settingsEditor: .none
    ),
    .init(
      key: "mood",
      defaultLabel: "Mood",
      shortDescription: "Three-times-a-day affect check-ins",
      activation: .optional,
      onboarding: .optional,
      supportsTab: false,
      supportsDashboard: true,
      settingsEditor: .none
    ),
    .init(
      key: "air",
      defaultLabel: "Air",
      shortDescription: "Indoor and outdoor air quality",
      activation: .optional,
      onboarding: .optional,
      supportsTab: false,
      supportsDashboard: true,
      settingsEditor: .none
    ),
    .init(
      key: "activity",
      defaultLabel: "Activity",
      shortDescription: "Steps and movement (HealthKit)",
      activation: .integration,
      onboarding: .optional,
      supportsTab: false,
      supportsDashboard: true,
      settingsEditor: .appearance
    ),
    // Sandbox section used to exercise the SectionPlugin + onboarding
    // wiring without touching real user data. Hidden from Today and
    // dashboard; only visible in Settings → Manage Sections. Delete
    // this entry (and TestPlugin) before shipping to TestFlight /
    // App Store.
    .init(
      key: "test",
      defaultLabel: "Sandbox",
      shortDescription: "Internal sandbox for trying out section flows",
      activation: .optional,
      onboarding: .optional,
      supportsTab: false,
      supportsDashboard: false,
      settingsEditor: .none
    ),
  ]

  /// Constant-time lookup by key. Built once at type init; reads are
  /// the hot path (sidebar render, section detail header, etc.).
  static let byKey: [String: SectionManifest] = Dictionary(
    uniqueKeysWithValues: SectionManifest.all.map { ($0.key, $0) }
  )
}
// SectionSkill — the canonical "what a model needs to know" briefing for
// each section, presented to the user inside the app's Settings → Skills
// surface. Parallels SectionManifest:
//
//   SectionManifest  → catalog facts about the section (label, activation)
//   SectionSkill     → AI/MCP facts about the section (tools, conventions, examples)
//
// The same content is mirrored in the Claude Code skill at
// `~/.claude/skills/septena/SKILL.md` so models that don't read the in-app
// page still get the brief. When MCP tools change, update both.
//
// Sections without MCP tools yet (sleep, groceries, body, air, activity,
// calendar) deliberately have no entry. The UI will render a "no skill yet"
// placeholder for them rather than fabricate content.

public struct SectionSkill: Sendable, Hashable, Identifiable {
  public let key: String
  /// One-sentence summary of what an AI can do for this section.
  public let summary: String
  /// MCP tool names exposed for this section (in display order).
  public let tools: [Tool]
  /// Markdown body — conventions, examples, gotchas. Rendered as `Text(.init(...))`.
  public let body: String

  public var id: String { key }

  public init(key: String, summary: String, tools: [Tool], body: String) {
    self.key = key
    self.summary = summary
    self.tools = tools
    self.body = body
  }

  public struct Tool: Sendable, Hashable {
    public let name: String
    public let blurb: String
    /// Compact parameter listing, formatted: `required: a, b · optional: c, d (enum: x|y|z)`.
    /// Pass `nil` for tools that take no parameters.
    public let inputs: String?
    public init(_ name: String, _ blurb: String, inputs: String? = nil) {
      self.name = name
      self.blurb = blurb
      self.inputs = inputs
    }
  }
}

public extension SectionSkill {
  /// Connection-wide preamble that applies to every section. Shown at the
  /// top of the Skills page and prepended when a user copies any single
  /// skill to clipboard.
  static let preamble: String = """
  ## Septena MCP

  Connect: `https://mcp.septena.app/mcp` (OAuth via Apple sign-in)

  Tools operate on your private iCloud CloudKit data (zone `septena-v1`). \
  The available tool list is dynamic — only sections you have enabled \
  (visible in this Settings sidebar) expose tools. Adding or removing a \
  section here updates what the model sees on its next `tools/list` call.

  ### Universal conventions
  - **Dates**: `YYYY-MM-DD` (local time). Omit `date` to mean today.
  - **Ranges**: pass `from`/`to` (inclusive). Neither + no `date` → last 7 days.
  - **Times**: `HH:MM:SS` for health events; `HH:MM` for habits/supplements.
  - **IDs**: opaque short strings. Always list, then act — never fabricate.
  - **Catalog → event**: `*_beans_list` / `*_strains_list` first, then log.
  - **Definition → state**: list returns definitions with today's state \
    merged. `*_toggle` writes the state. Don't create a new definition \
    just to mark today done.
  """

  /// All section skills. Order here is the canonical display order on the
  /// Skills page. Sections without MCP tools yet are omitted.
  static let all: [SectionSkill] = [
    .init(
      key: "tasks",
      summary: "Manage tasks, projects, and areas. Always available.",
      tools: [
        .init("tasks_list",          "List by view. Inbox = unscheduled, untoday; today = pinned; upcoming = future-scheduled; anytime EXCLUDES inbox-only tasks",
              inputs: "optional: view (today|inbox|upcoming|anytime|someday|completed), limit"),
        .init("tasks_create",        "New task. Without today/scheduled/due it lands in INBOX ONLY — invisible in today/anytime/upcoming. Set a routing field if the user expects to see it",
              inputs: "required: title · optional: today (boolean — pins to Today), scheduled (YYYY-MM-DD — puts in upcoming), due (YYYY-MM-DD — deadline only, does NOT route into views), area (id, not a routing field), project (id, not a routing field)"),
        .init("tasks_update",        "Patch any subset. Pass null to clear scheduled/due/area/project",
              inputs: "required: id · optional: title, today, scheduled (YYYY-MM-DD or null), due (YYYY-MM-DD or null), area (id or null), project (id or null), status (open|cancelled)"),
        .init("tasks_complete",      "Mark done. ERRORS on recurring — those must be done in-app so the next occurrence spawns",
              inputs: "required: id"),
        .init("tasks_defer",         "Set scheduled date, clear today",
              inputs: "required: id, until (YYYY-MM-DD)"),
        .init("tasks_move_to_today", "Pin to Today (today=true, clear scheduled)",
              inputs: "required: id"),
        .init("tasks_list_projects", "Resolve project name → id",
              inputs: "optional: status (active|done|cancelled|all), limit"),
        .init("tasks_list_areas",    "Resolve area name → id",
              inputs: "optional: limit"),
      ],
      body: """
      ### View routing — important
      A task's visibility depends entirely on three fields: `today`, `scheduled`, `due`.

      | Set on create        | Appears in view(s)            |
      |----------------------|-------------------------------|
      | `today: true`        | `today`, `anytime`            |
      | `scheduled: <date>`  | `upcoming`, `anytime`         |
      | `due: <date>` only   | `anytime` (deadline; no route)|
      | None of the above    | **`inbox` only**              |

      Notes:
      - `anytime` does NOT mean "all tasks." It excludes inbox-only tasks.
      - `area` / `project` are NOT routing fields. They tag a task for filtering inside views, but a task pinned to no view stays in inbox even if it has an area.
      - `tasks_create` returns success for any schema-valid write — it does not tell you which view the task will land in. Reason about routing yourself.

      ### Footgun
      A bare `tasks_create(title: "X")` lands in `inbox` and stays invisible to anyone listing `today`/`anytime`/`upcoming`. Models have lost track of created tasks because of this — the write succeeded, but neither model nor user noticed it ended up in inbox.

      **Default behavior to adopt**: if the user doesn't specify a date or "today," either:
      1. Ask: "Do you want this on today's list, scheduled, or just in your inbox?"
      2. Or proceed with no flags AND explicitly tell them "I put it in your inbox" so they know where to look.

      Never claim a freshly created task is "added" without indicating where it lives.

      ### Examples
      **"Add 'pick up groceries' to today"**
      ```
      tasks_create(title: "pick up groceries", today: true)
      ```

      **"Add 'pick up groceries' for tomorrow"**
      ```
      tasks_create(title: "pick up groceries", scheduled: "<tomorrow YYYY-MM-DD>")
      ```

      **"Just add 'pick up groceries' to my list"**
      ```
      tasks_create(title: "pick up groceries")
      → reply: "Added to your inbox."
      ```

      **"Move my errands to Saturday"**
      ```
      tasks_list(view: "today")                  → find ids
      tasks_defer(id, until: "<next saturday>")  → for each
      ```

      **"Show me everything I haven't scheduled"**
      ```
      tasks_list(view: "inbox")
      ```

      ### Verification habit
      If you're about to tell the user "I added/moved/scheduled X," and routing matters, list the destination view first to confirm X is actually there. `tasks_create` and `tasks_update` return success on any schema-valid write — they don't validate that the result matches user intent.

      ### Don't
      - Don't try to `tasks_complete` a recurring task. Tell the user to do it in the app.
      - Don't reference area/project by name. Always resolve to id first via `tasks_list_areas` / `tasks_list_projects`.
      - Don't assume `anytime` shows all tasks. It excludes inbox-only items.
      - Don't claim a task is "added" without mentioning which view/list it landed in.
      """
    ),
    .init(
      key: "goals",
      summary: "Free-text intentions tagged with section keys. Always available.",
      tools: [
        .init("goals_list",   "All goals"),
        .init("goals_create", "New goal, optionally tagged with section keys",
              inputs: "required: text · optional: sections (array of section keys)"),
        .init("goals_update", "Update text and/or tags. `sections` REPLACES existing tags",
              inputs: "required: id · optional: text, sections (replaces)"),
        .init("goals_delete", "Remove",
              inputs: "required: id"),
      ],
      body: """
      Goals are short text intentions (e.g. "swim twice a week") tagged \
      with section keys so they surface in the right section view. \
      `goals_update.sections` replaces — fetch first if you want to add.
      """
    ),
    .init(
      key: "habits",
      summary: "Daily routines with done/skipped state per date.",
      tools: [
        .init("habits_list",   "Definitions with today's state merged",
              inputs: "optional: date (YYYY-MM-DD, default today)"),
        .init("habits_create", "New definition",
              inputs: "required: title, bucket (morning|evening|anytime) · optional: emoji"),
        .init("habits_update", "Update fields",
              inputs: "required: id · optional: title, bucket (morning|evening|anytime), emoji"),
        .init("habits_delete", "Delete definition and all its events",
              inputs: "required: id"),
        .init("habits_toggle", "Mark done/skipped/unmarked for a date. Idempotent",
              inputs: "required: id, done · optional: date, skipped"),
      ],
      body: """
      Habits separate **definitions** (the thing) from **events** (per-date state).

      ### Examples
      **"Mark my morning habits done"**
      ```
      habits_list()                         → filter bucket == "morning"
      habits_toggle(id, done: true)         → for each
      ```

      **"I'm taking a rest day from exercise"**
      ```
      habits_toggle(id, done: false, skipped: true)
      ```

      ### Don't
      - Don't create a new definition to log today's completion.
      """
    ),
    .init(
      key: "supplements",
      summary: "Daily supplement log — same shape as habits.",
      tools: [
        .init("supplements_list",   "Definitions with today's state merged",
              inputs: "optional: date (default today)"),
        .init("supplements_create", "New definition",
              inputs: "required: title · optional: emoji"),
        .init("supplements_update", "Update fields",
              inputs: "required: id · optional: title, emoji"),
        .init("supplements_delete", "Delete definition and events",
              inputs: "required: id"),
        .init("supplements_toggle", "Mark taken/untaken for a date",
              inputs: "required: id, done · optional: date"),
      ],
      body: """
      Same definition+state shape as habits. \
      `supplements_toggle(id, done: false)` removes today's mark.
      """
    ),
    .init(
      key: "chores",
      summary: "Recurring household tasks with computed due dates.",
      tools: [
        .init("chores_list",       "Definitions + computed due/last-completed (replays 180d)"),
        .init("chores_create",     "New chore",
              inputs: "required: title, cadenceDays · optional: emoji"),
        .init("chores_update",     "Update fields",
              inputs: "required: id · optional: title, cadenceDays (min 1), emoji"),
        .init("chores_delete",     "Delete definition and events",
              inputs: "required: id"),
        .init("chores_complete",   "Log completion for today or a given date",
              inputs: "required: id · optional: date (default today)"),
        .init("chores_defer",      "Defer to 'day' (tomorrow) or 'weekend' (next Saturday)",
              inputs: "required: id, mode (day|weekend) · optional: date"),
        .init("chores_uncomplete", "Remove most recent completion",
              inputs: "required: id · optional: date"),
      ],
      body: """
      `chores_list` replays the last 180 days of events to compute when each \
      chore is next due. Surface overdue items first.
      """
    ),
    // caffeine migrated to CaffeinePlugin (Septena target). See
    // SectionSkill.resolve(_:) — registry lookup wins over this list.
    .init(
      key: "cannabis",
      summary: "Log cannabis intake with strain and effect.",
      tools: [
        .init("cannabis_events_list",  "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        .init("cannabis_event_log",    "Log an intake",
              inputs: "required: method (vape|edible) · optional: date (default today), time (HH:MM:SS), strain (CannabisStrain id), hit (count for vape), grams (for edibles), effect (free-form, e.g. relaxed/creative), note"),
        .init("cannabis_event_delete", "Remove an event",
              inputs: "required: id"),
        .init("cannabis_strains_list", "Strain catalog"),
        .init("cannabis_strain_create", "Add a strain",
              inputs: "required: name"),
        .init("cannabis_strain_delete", "Remove a strain",
              inputs: "required: id"),
      ],
      body: """
      `effect` is subjective free-form: "relaxed", "creative", "couch-locked".
      """
    ),
    .init(
      key: "gut",
      summary: "Digestive event log.",
      tools: [
        .init("gut_events_list",  "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        .init("gut_event_log",    "Log an event",
              inputs: "required: bristol (1-7) · optional: date (default today), time (HH:MM:SS), blood (boolean), volume (small|medium|large), discomfortLevel (free-form), discomfortStart (HH:MM), discomfortEnd (HH:MM), note"),
        .init("gut_event_delete", "Remove an event",
              inputs: "required: id"),
      ],
      body: """
      `bristol` is the Bristol Stool Scale (1 = hard pellets, 7 = watery) and \
      is required. Log `discomfortStart`/`discomfortEnd` as `HH:MM` when the \
      user describes cramping or pain.
      """
    ),
    .init(
      key: "training",
      summary: "Log exercise sets, manage exercise catalog, define session-type templates.",
      tools: [
        .init("training_entries_list",   "List exercise entries by day or range",
              inputs: "optional: date, from, to, exercise (filter to one canonical name), limit"),
        .init("training_entry_log",      "Log a set. Strength: weight/sets/reps. Cardio: durationMin/distanceM. Difficulty/note optional",
              inputs: "required: sessionType (id e.g. 'upper'), exercise (canonical NAME — e.g. 'Chest press') · optional: date (default today), time (HH:MM), weight (kg), sets (int or 'AMRAP'), reps, difficulty, durationMin, distanceM, level, note, concludedAt (ISO8601)"),
        .init("training_entry_update",   "Patch an entry",
              inputs: "required: id · optional: date, time, sessionType, exercise, weight, sets, reps, difficulty, durationMin, distanceM, level, note, concludedAt"),
        .init("training_entry_delete",   "Remove an entry",
              inputs: "required: id"),
        .init("training_exercises_list", "Exercise catalog (definitions)",
              inputs: "optional: type (strength|cardio|mobility|core), archived (default false), limit"),
        .init("training_exercise_create", "Add an exercise definition. id defaults to slugified name",
              inputs: "required: name, type (strength|cardio|mobility|core) · optional: id (slug), subgroup (e.g. push/pull), aliases (array), primaryMuscle, secondaryMuscles (array)"),
        .init("training_exercise_update", "Update an exercise definition",
              inputs: "required: id · optional: name, type, subgroup, aliases, primaryMuscle, secondaryMuscles, archived"),
        .init("training_exercise_delete", "Delete from catalog",
              inputs: "required: id"),
        .init("training_sessions_list",  "Session-type templates (e.g. 'upper', 'lower', 'cardio')",
              inputs: "optional: archived (default false), limit"),
        .init("training_session_create", "Create a session template. id is the canonical key",
              inputs: "required: id (e.g. 'upper'), label · optional: emoji, exercises (array of canonical names), kind"),
        .init("training_session_update", "Update a session template",
              inputs: "required: id · optional: label, emoji, exercises, kind, archived"),
        .init("training_session_delete", "Remove a session template",
              inputs: "required: id"),
      ],
      body: """
      ### Model
      Training has three record types that work together:
      - **ExerciseDefinition** — the catalog. Each has a stable slug `id` ('chest-press'), `name` ('Chest press'), `type` (strength/cardio/...), optional muscle tags.
      - **SessionType** — a routine template. id is the key ('upper', 'lower', 'cardio'). Lists which exercises belong to that session.
      - **ExerciseEntry** — one logged set or block. References `sessionType` by id and `exercise` by canonical NAME (not id).

      ### Logging workflow
      1. `training_sessions_list()` → find the sessionType id matching what the user did ('upper', 'cardio', etc.)
      2. `training_exercises_list({type: "strength"})` → find the canonical exercise name
      3. `training_entry_log({sessionType, exercise, weight, sets, reps})` → log it

      ### Examples
      **"I just did 3 sets of 8 chest press at 80kg"**
      ```
      training_entry_log(
        sessionType: "upper",
        exercise: "Chest press",
        weight: 80,
        sets: "3",
        reps: "8"
      )
      ```

      **"Ran 5k in 24 minutes"**
      ```
      training_entry_log(
        sessionType: "cardio",
        exercise: "Run",
        durationMin: 24,
        distanceM: 5000
      )
      ```

      **"What did I do this week?"**
      ```
      training_entries_list({ from: "<monday>", to: "<sunday>" })
      ```

      ### Don't
      - Don't pass an exercise id where `exercise` is expected — it's the **canonical name** (e.g. 'Chest press'), not the slug.
      - Don't pass arbitrary strings for `sessionType` — resolve to an existing SessionType id first.
      - Don't `training_exercise_delete` something that has historical entries unless the user is sure. Entries keep a denormalised exercise name, but the catalog reference is lost.
      """
    ),
    .init(
      key: "groceries",
      summary: "Shopping list and pantry. Mark items low; clear when restocked.",
      tools: [
        .init("grocery_items_list",       "Items, with low-stock flag",
              inputs: "optional: low (filter to running-low), category (id), limit"),
        .init("grocery_item_create",      "Add an item",
              inputs: "required: name, category (GroceryCategory id) · optional: emoji"),
        .init("grocery_item_update",      "Patch an item",
              inputs: "required: id · optional: name, category, emoji, low (boolean), lastBought (YYYY-MM-DD or null)"),
        .init("grocery_item_set_low",     "Mark low / restocked. The daily workflow: low=true when running out, low=false when bought (auto-stamps lastBought=today)",
              inputs: "required: id, low (boolean)"),
        .init("grocery_item_delete",      "Remove an item",
              inputs: "required: id"),
        .init("grocery_categories_list",  "Categories"),
        .init("grocery_category_create",  "Add a category",
              inputs: "required: name"),
        .init("grocery_category_delete",  "Remove a category",
              inputs: "required: id"),
      ],
      body: """
      ### Two record types
      - **GroceryItem** — a pantry/shopping-list entry. Has a `low` flag (running out) and `lastBought` date.
      - **GroceryCategory** — section header for items ('Produce', 'Dairy', etc.).

      ### Most common workflow: marking items low
      Day-to-day, users say "I'm out of milk" or "we need eggs." Use `grocery_item_set_low(id, low: true)`. When they restock, `grocery_item_set_low(id, low: false)` — it auto-stamps `lastBought=today`.

      ### Examples
      **"I'm out of milk"**
      ```
      grocery_items_list({})                  → find milk's id
      grocery_item_set_low(id, low: true)
      ```

      **"What do I need to buy?"**
      ```
      grocery_items_list({ low: true })
      ```

      **"I bought milk"**
      ```
      grocery_item_set_low(id, low: false)    → clears low, stamps lastBought=today
      ```

      **"Add quinoa to my staples"**
      ```
      grocery_categories_list()                            → find category id
      grocery_item_create(name: "Quinoa", category: <id>)
      ```

      ### Don't
      - Don't use `grocery_item_update` for the low/restock workflow when `grocery_item_set_low` exists — the convenience tool handles the lastBought stamping.
      - Don't reference categories by name; always resolve to id first.
      """
    ),
    .init(
      key: "nutrition",
      summary: "Meal + macro log with auto-computed daily totals.",
      tools: [
        .init("nutrition_entries_list", "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        .init("nutrition_entry_log",    "Log a meal. foods is newline-separated; macros default to 0; kcal auto-computed if omitted; source auto-tagged 'mcp'",
              inputs: """
                required: foods · \
                optional: loggedAt (ISO8601), emoji, note, mealType (breakfast|lunch|dinner|snack), \
                proteinG, fatG, carbsG, \
                fiberG, sugarG, saturatedFatG, alcoholG, \
                kcal (override; else 4P+9F+4C+7A), \
                sodiumMg, cholesterolMg, potassiumMg, waterMl
                """),
        .init("nutrition_entry_update", "Patch any subset of fields",
              inputs: """
                required: id · \
                optional: loggedAt (ISO8601), foods, emoji, note, mealType (breakfast|lunch|dinner|snack), \
                proteinG, fatG, carbsG, \
                fiberG, sugarG, saturatedFatG, alcoholG, kcal, \
                sodiumMg, cholesterolMg, potassiumMg, waterMl
                """),
        .init("nutrition_entry_delete", "Remove an entry",
              inputs: "required: id"),
        .init("nutrition_day_summary",  "Read-only daily rollup (kcal + macros + micros + entryCount + first/last loggedAt)",
              inputs: "optional: date (default today)"),
      ],
      body: """
      `foods` is a newline-separated list. \
      **Estimate macros from food names** — the user expects the model to do \
      the math, not ask back. `kcal` is computed `4P + 9F + 4C + 7A` if not \
      overridden.

      ### Example
      **"Log lunch: chicken salad, rice, olive oil"**
      ```
      nutrition_entry_log(
        foods: "chicken salad\\nrice\\nolive oil",
        mealType: "lunch",
        proteinG: 40, fatG: 20, carbsG: 50
      )
      ```

      ### Don't
      - Don't bundle multiple meals into one entry — separate `loggedAt` timestamps.
      - Don't try to write a day summary — the app computes it automatically.
      """
    ),
  ]

  static let byKey: [String: SectionSkill] = Dictionary(
    uniqueKeysWithValues: SectionSkill.all.map { ($0.key, $0) }
  )

  /// Render this skill as a self-contained Markdown document. The preamble
  /// is prepended so a model receiving only this string still has full
  /// context. Used by the "Copy" button.
  var fullMarkdown: String {
    let toolList = tools.map { tool -> String in
      // Two-line entry: blurb, then a sub-bullet with inputs (when present).
      // Inputs go on their own indented line so the model can scan params
      // independently of the prose blurb.
      if let inputs = tool.inputs {
        return "- `\(tool.name)` — \(tool.blurb)\n  - \(inputs)"
      } else {
        return "- `\(tool.name)` — \(tool.blurb)"
      }
    }.joined(separator: "\n")
    return """
    \(SectionSkill.preamble)

    # \(key.capitalized) — Septena MCP skill

    \(summary)

    ### Tools
    \(toolList)

    \(body)
    """
  }
}
