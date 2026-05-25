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
    // tasks migrated to TasksPlugin (Septena target).
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
    // habits migrated to HabitsPlugin (Septena target).
    // supplements migrated to SupplementsPlugin (Septena target).
    // chores migrated to ChoresPlugin (Septena target).
    // caffeine migrated to CaffeinePlugin (Septena target). See
    // SectionSkill.resolve(_:) — registry lookup wins over this list.
    // cannabis migrated to CannabisPlugin (Septena target).
    // gut migrated to GutPlugin (Septena target).
    // training migrated to TrainingPlugin (Septena target).
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
    // nutrition migrated to NutritionPlugin (Septena target).
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
