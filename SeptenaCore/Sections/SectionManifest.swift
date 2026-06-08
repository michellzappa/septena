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
//
// ─────────────────────────────────────────────────────────────────────
// A manifest row is only the FIRST of several surfaces a section spans.
// Adding a row here makes the section appear in Settings and (if
// `supportsDashboard`) reserves it a slot — but the dashboard TILE,
// quick-add, Today timeline, and time travel are each wired separately.
// See `docs/ADDING_A_SECTION.md` for the full surface checklist and the
// "is this section fully fleshed out?" audit grid. Quick map:
//
//   • Catalog row + icon ............ here (`SectionManifest.all`, `iconByKey`)
//   • Behaviour (view, skill, …) .... `Septena/Shell/Sections/Plugins/<X>Plugin.swift`
//                                     + register in `SectionRegistry.all`
//   • Dashboard tile ................ `HomepageDomain` case (+ `supportsDashboard`
//                                     here drives order/visibility),
//                                     then `WeekDashboardView` (tile, domainData,
//                                     quickAddMenu, state, cache, loadAll)
//   • Settings + ordering ........... automatic once the row is seeded
//   • Today timeline ................ opt in via `todayCapableKeys` (below)
//   • Time travel ................... opt in via `timeTravelCapableKeys` (below)
//                                     AND thread `SectionDrawer(currentDate:)`
//
// The classic gap: a row + destination but NO `HomepageDomain` case —
// the section is reachable from Settings yet never renders a tile.

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
    "training", "nutrition", "hydration",
    "caffeine", "cannabis", "gut", "mood",
  ]

  /// Whether this section has any presence on the Today timeline.
  public var appearsInToday: Bool {
    SectionManifest.todayCapableKeys.contains(key)
  }

  /// Sections whose destination supports "time travel" — i.e. a date
  /// strip in the SectionDrawer that lets the user browse logs/events
  /// on a past day. When the date strip is on a past day, the
  /// destination drops its "today" affordances (goals strip, summary
  /// tiles, heatmaps, infographics) and renders only that day's logs.
  ///
  /// Mirrors the `todayCapableKeys` pattern: kept as a static set so
  /// the manifest init blocks stay terse, and so a section opts in
  /// with a one-line edit here. The drawer + each opted-in destination
  /// share the convention; sections not in this set never instantiate
  /// the date strip.
  public static let timeTravelCapableKeys: Set<String> = [
    "caffeine", "cannabis", "gut", "nutrition",
    "habits", "supplements", "mood", "hydration",
  ]

  /// Whether this section's destination should render the date strip
  /// and time-travel UI. Read by destinations to decide whether to
  /// thread a `viewingDate` state through SectionDrawer.
  public var supportsTimeTravel: Bool {
    SectionManifest.timeTravelCapableKeys.contains(key)
  }

  /// SF Symbol used by every surface that renders the section as a row
  /// or tile (Settings sidebar, Dense / Heatmap homepage, dashboard
  /// chrome). Lookup-by-key keeps the manifest init blocks terse;
  /// `circle.fill` is the neutral fallback for any key without an
  /// explicit entry (e.g. legacy / dev-only sections).
  private static let iconByKey: [String: String] = [
    "tasks":       "checklist",
    "habits":      "repeat",
    "training":    "figure.strengthtraining.traditional",
    "chores":      "house",
    "supplements": "pills",
    "sleep":       "bed.double",
    "nutrition":   "fork.knife",
    "groceries":   "cart",
    "caffeine":    "cup.and.saucer",
    "cannabis":    "leaf",
    "body":        "scalemass",
    "gut":         "circle.bottomhalf.filled",
    "mood":        "face.smiling",
    "activity":    "figure.walk",
    "goals":       "bubble.left",
    "hydration":   "drop.fill",
    "github":      "chevron.left.forwardslash.chevron.right",
    "insights":    "chart.dots.scatter",
  ]

  public var iconSymbol: String {
    SectionManifest.iconByKey[key] ?? "circle.fill"
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
      defaultLabel: String(localized: "Tasks", comment: "Section name"),
      shortDescription: String(localized: "Inbox, projects, areas, today and upcoming", comment: "Section description"),
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
      defaultLabel: String(localized: "Training", comment: "Section name"),
      shortDescription: String(localized: "Sessions, exercises, weekly Z2", comment: "Section description"),
      activation: .optional,
      onboarding: .core,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "nutrition",
      defaultLabel: String(localized: "Nutrition", comment: "Section name"),
      shortDescription: String(localized: "Macros and calorie ranges", comment: "Section description"),
      activation: .optional,
      onboarding: .core,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "sleep",
      defaultLabel: String(localized: "Sleep", comment: "Section name"),
      shortDescription: String(localized: "Bed and wake times, nightly duration", comment: "Section description"),
      activation: .optional,
      onboarding: .core,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .appearance
    ),
    .init(
      key: "habits",
      defaultLabel: String(localized: "Habits", comment: "Section name"),
      shortDescription: String(localized: "Daily routines and streaks", comment: "Section description"),
      activation: .optional,
      onboarding: .core,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "chores",
      defaultLabel: String(localized: "Chores", comment: "Section name"),
      shortDescription: String(localized: "Recurring household tasks", comment: "Section description"),
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "supplements",
      defaultLabel: String(localized: "Supplements", comment: "Section name"),
      shortDescription: String(localized: "Daily supplements log", comment: "Section description"),
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "groceries",
      defaultLabel: String(localized: "Groceries", comment: "Section name"),
      shortDescription: String(localized: "Shopping list and pantry", comment: "Section description"),
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "caffeine",
      defaultLabel: String(localized: "Caffeine", comment: "Section name"),
      shortDescription: String(localized: "Coffee, beans, brewing methods", comment: "Section description"),
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "cannabis",
      defaultLabel: String(localized: "Cannabis", comment: "Section name"),
      shortDescription: String(localized: "Intake log and dosing", comment: "Section description"),
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .sectionConfig
    ),
    .init(
      key: "body",
      defaultLabel: String(localized: "Body", comment: "Section name"),
      shortDescription: String(localized: "Weight, body fat, measurements", comment: "Section description"),
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .appearance
    ),
    .init(
      key: "gut",
      defaultLabel: String(localized: "Gut", comment: "Section name"),
      shortDescription: String(localized: "Digestion log", comment: "Section description"),
      activation: .optional,
      onboarding: .optional,
      supportsTab: false,
      supportsDashboard: true,
      settingsEditor: .none
    ),
    .init(
      key: "mood",
      defaultLabel: String(localized: "Mood", comment: "Section name"),
      shortDescription: String(localized: "Three-times-a-day affect check-ins", comment: "Section description"),
      activation: .optional,
      onboarding: .optional,
      supportsTab: false,
      supportsDashboard: true,
      settingsEditor: .none
    ),
    .init(
      key: "activity",
      defaultLabel: String(localized: "Activity", comment: "Section name"),
      shortDescription: String(localized: "Steps and movement (HealthKit)", comment: "Section description"),
      activation: .integration,
      onboarding: .optional,
      supportsTab: false,
      supportsDashboard: true,
      settingsEditor: .appearance
    ),
    // GitHub — read-only mirror of the authenticated user's contribution
    // calendar (the commit heatmap), fetched from the GraphQL API with a
    // per-device token (Keychain, never CloudKit — GitHub is the source of
    // truth). Homepage tile (commit counts) + sidebar destination (year
    // heatmap + weekly sparkline). See GitHubPlugin / GitHubDestinationView
    // / GitHubProvider and the `.github` wiring in WeekDashboardView.
    .init(
      key: "github",
      defaultLabel: String(localized: "GitHub", comment: "Section name"),
      shortDescription: String(localized: "Commit activity as a contribution heatmap", comment: "Section description"),
      activation: .integration,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: true,
      settingsEditor: .appearance
    ),
    // Insights — read-only meta-section: cross-section correlation
    // discovery (CorrelationEngine). Graduated from a homepage layout mode
    // to its own destination. `supportsDashboard: false` deliberately — it
    // has NO per-day series of its own (it's an analysis *of* the other
    // sections), so it can't be a layout-rendered domain tile (a Sparkline/
    // Heatmap row would have nothing to plot). Its homepage presence is a
    // standalone hook card in WeekDashboardView (`insightsGlanceCard`),
    // outside the layout switcher. Gated behind Septena+ in the destination.
    // `.optional`/off-by-default — opt in from Manage Sections.
    .init(
      key: "insights",
      defaultLabel: String(localized: "Insights", comment: "Section name"),
      shortDescription: String(localized: "What moves your day — cross-section correlations", comment: "Section description"),
      activation: .optional,
      onboarding: .optional,
      supportsTab: true,
      supportsDashboard: false,
      settingsEditor: .none
    ),
    // Hydration — water-only log. UX over existing nutrition data:
    // every entry is a NutritionEntryEntity with `foods: ["Water"]`,
    // `waterMl > 0`, and macros at 0. Logged via the hydration quick-
    // add affordances; fully fleshed out across surfaces — dashboard
    // tile (today ml vs target + 7-day intake), tile context-menu
    // quick-add, time-travel destination, Today timeline. The same
    // waterMl field on a real meal entry still counts toward the daily
    // total without showing as a separate hydration row.
    .init(
      key: "hydration",
      defaultLabel: String(localized: "Hydration", comment: "Section name"),
      shortDescription: String(localized: "Water intake against a daily target", comment: "Section description"),
      activation: .optional,
      onboarding: .core,
      supportsTab: false,
      supportsDashboard: true,
      settingsEditor: .none
    ),
    // Goals — free-text intentions tagged with section keys. No
    // homepage tile and no Today presence; surfaces inside the
    // sections each goal is tagged with. Hidden from the future
    // browse-catalog picker (`onboarding: .hidden`) but still listed
    // in Manage Sections so the user can disable / re-enable it.
    .init(
      key: "goals",
      defaultLabel: String(localized: "Coach", comment: "Section name"),
      shortDescription: String(localized: "On-device coaches over your goals and logged data", comment: "Section description"),
      activation: .optional,
      onboarding: .hidden,
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

  /// User-facing section name. A genuine user rename is shown verbatim; the
  /// canonical English default is localized on display ("Tasks" → "Tarefas")
  /// while the stored `SectionEntity.title` stays English. Empty stored value
  /// falls through to the (already-localized) manifest default.
  static func displayLabel(key: String, stored: String) -> String {
    if !stored.isEmpty {
      return Bundle.main.localizedString(forKey: stored, value: stored, table: nil)
    }
    return byKey[key]?.defaultLabel ?? key.capitalized
  }
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
// Sections without MCP tools yet (sleep, groceries, body, activity,
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
  // Every section that ships a skill brief has been migrated to its
  // own SectionPlugin in the Septena target. This list is intentionally
  // empty — SectionSkill.resolve(_:) walks SectionRegistry first and
  // only falls back here for any future legacy entries. New sections
  // should declare `mcpSkill` inline in their plugin, never here.
  static let all: [SectionSkill] = []

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
