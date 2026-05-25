import SwiftUI
import EventKit

// Per-section "plugin" abstraction. Each section bundles its catalog
// facts (manifest), its Today event production, and — over time —
// its dashboard tile, settings detail pane, and onboarding flow into
// one declaration. Everything that iterates "the list of sections"
// goes through `SectionRegistry` instead of switch statements scattered
// across the UI.
//
// This is the *narrow* first version: only `manifest` + `todayEvents`
// are required. Other slots (`mcpSkill`, `dashboardTile`, `detailPane`,
// `onboarding`) will be added as concrete migrations land.
//
// Plugins live in the app target (not SeptenaCore) because they
// construct view-layer types (`TodayEvent`, eventually SwiftUI views).
// SeptenaCore stays UI-free.

@MainActor
protocol SectionPlugin {
  /// Catalog identity. Resolves to a row in `SectionManifest.all`.
  static var manifest: SectionManifest { get }

  /// Contribute events to the Today log for the given date. Return `[]`
  /// for sections that don't appear in Today (or implement only the
  /// manifest and let `appearsInToday` gate them out).
  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent]

  /// First-enable setup flow. Return a view to present as a sheet when
  /// the user flips this section from off → on for the first time
  /// (i.e. `SectionEntity.hasOnboarded == false`). Return `nil` to
  /// skip onboarding — the toggle enables immediately. The plugin
  /// MUST call `complete()` from its view to finish the flow.
  ///
  /// **Invariant: onboarding is additive only.** The view introduces
  /// the section and optionally seeds defaults; it must never delete,
  /// overwrite, or otherwise mutate existing user data. Concretely:
  /// if a starter-list picker offers items the user already has,
  /// those items are shown as "already added" and excluded from the
  /// write batch. Re-running onboarding (via the wand button) is a
  /// safe no-op for already-imported items.
  static func onboarding(complete: @escaping () -> Void) -> AnyView?

  /// The section's primary destination view — what shows when the
  /// user taps the section's homepage tile or its sidebar row. Plugins
  /// override this to return their own DestinationView wrapped in
  /// AnyView. Sections without a dedicated destination inherit the
  /// default-nil from the protocol extension.
  static func destinationView() -> AnyView?

  /// Section-specific content rendered inside `SectionDetailPane` (the
  /// per-section page in Settings). Used for read-only catalog
  /// displays (caffeine beans, chore definitions, …) and section-only
  /// preferences (nutrition macro tiles, fasting toggle). The
  /// returned view should be one or more `Section { ... }` blocks so
  /// it composes inside the enclosing `Form { ... }`. Default-nil for
  /// identity-only sections.
  static func detailPaneContent() -> AnyView?

  /// Import/Export contribution. Returns the per-section schema tables
  /// (what the LLM-prompt generator advertises) and a collect closure
  /// (what the actual export writes). Default-nil for sections that
  /// don't participate in import/export — they're simply skipped.
  static var exportContribution: SectionExportContribution? { get }

  /// MCP / agent contract for this section. Declares the read/write
  /// tools an LLM uses to manipulate this section's data, plus a
  /// human-readable brief on conventions and examples. Tightly bound
  /// to the plugin so the tool catalog can never drift out of sync
  /// with the section's actual behavior — they live in the same file.
  /// Return `nil` for sections that haven't migrated their skill yet
  /// (still in `SectionSkill.all`); `SectionSkill.byKey` falls through.
  static var mcpSkill: SectionSkill? { get }
}

// MARK: - Shared detail-pane chrome

/// Simple "label · trailing value" row used in plugin detail-pane
/// content. Mirrors the same shape as the existing private helper in
/// SectionDetailPane so the look is consistent across migrated and
/// inline sections.
@MainActor
@ViewBuilder
func sectionDetailRow(_ label: String, _ value: String) -> some View {
  HStack {
    Text(label)
    Spacer()
    Text(value)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.trailing)
  }
}

// MARK: - SectionSkill resolution
//
// Sections that have migrated to the plugin model declare their MCP
// skill inline; sections that haven't migrated still live in the
// legacy `SectionSkill.all` list. These helpers give consumers one
// answer regardless of where the skill is declared.

extension SectionRegistry {
  /// Single skill.md document covering every plugin-resident MCP brief.
  /// Designed to be pasted into the gateway repo's `skill.md` so the
  /// LLM-facing skill catalog can't drift from the app's plugin
  /// declarations.
  ///
  /// Structure:
  ///   - `SectionSkill.preamble` — connection + universal conventions
  ///   - One H1 per section, in registry order, with summary + tools +
  ///     body (markdown) drawn from the plugin's `mcpSkill`.
  /// Plugins without an `mcpSkill` (Sandbox, Sleep, Body, Air, Activity)
  /// are skipped.
  @MainActor
  static func fullSkillMarkdown() -> String {
    var out = SectionSkill.preamble + "\n\n"
    for plugin in SectionRegistry.all {
      guard let skill = plugin.mcpSkill else { continue }
      let toolList = skill.tools.map { tool -> String in
        if let inputs = tool.inputs {
          return "- `\(tool.name)` — \(tool.blurb)\n  - \(inputs)"
        }
        return "- `\(tool.name)` — \(tool.blurb)"
      }.joined(separator: "\n")
      out += """
      # \(skill.key.capitalized) — Septena MCP skill

      \(skill.summary)

      ### Tools
      \(toolList)

      \(skill.body)

      ---


      """
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
  }
}

extension SectionSkill {
  /// Resolve a section's MCP skill, preferring an inline plugin
  /// declaration over the legacy `SectionSkill.all` list.
  @MainActor
  static func resolve(_ key: String) -> SectionSkill? {
    if let skill = SectionRegistry.plugin(forKey: key)?.mcpSkill {
      return skill
    }
    return byKey[key]
  }

  /// Every section key that has an MCP skill declared anywhere — plugin
  /// or legacy. Used by the Skills pane to enumerate everything an
  /// agent can do via this app.
  @MainActor
  static var allKnownKeys: Set<String> {
    var keys = Set(byKey.keys)
    for plugin in SectionRegistry.all {
      if let skill = plugin.mcpSkill { keys.insert(skill.key) }
    }
    return keys
  }
}

extension SectionPlugin {
  /// The section's primary destination view — the screen the user
  /// lands on when they tap into the section from the dashboard tile
  /// or sidebar. Default returns nil for sections without a dedicated
  /// destination (e.g. utility plugins like Sandbox). Plugins that own
  /// their destination wrap it in AnyView and return it here.
  static func destinationView() -> AnyView? { nil }

  /// Default: no detail-pane content beyond the identity row +
  /// onboarding trigger that SectionDetailPane renders for every
  /// section. Plugins override to add catalog displays / per-section
  /// preferences (one or more `Section { ... }` blocks).
  static func detailPaneContent() -> AnyView? { nil }

  /// Default: no import/export participation. Plugins that own JSON
  /// schema + entity-to-dict mappers override this.
  static var exportContribution: SectionExportContribution? { nil }

  /// Default: no onboarding. Sections that need a setup flow override
  /// this; everything else inherits the no-op.
  static func onboarding(complete: @escaping () -> Void) -> AnyView? { nil }

  /// Default: onboarding shows once per user (gated on `hasOnboarded`).
  /// A plugin that overrides this to `true` re-presents the sheet on
  /// every off → on transition — useful for the Sandbox plugin which
  /// exists to exercise the flow, not commit to a real setup state.
  static var alwaysShowOnboarding: Bool { false }

  /// Default: no inline MCP brief — the section either has its entry
  /// in the legacy `SectionSkill.all` list (sections not yet migrated)
  /// or no agent contract at all (sandbox / utility sections).
  static var mcpSkill: SectionSkill? { nil }
}

/// Bag of pre-loaded data + helpers passed into `todayEvents`. Avoids
/// the alternative of every plugin re-fetching from SwiftData on each
/// build, and keeps the plugin signatures stable as new data arrays
/// are added.
@MainActor
struct TodayContext {
  let theme: SectionTheme
  let habits: [HabitDayItem]
  let supplements: [SupplementDayItem]
  let chores: [ChoreItem]
  let tasks: [SeptenaTask]
  let caffeine: [CaffeineEntry]
  let cannabis: [CannabisEntry]
  let gut: [GutEntry]
  let nutrition: [NutritionEntry]
  let training: [ExerciseEntry]
  let calendar: [EKEvent]
  let mood: [MoodEntry]
}

/// Single source of truth for which plugins exist. Sections not in this
/// list still work via their inline implementations in `TodayLogView`,
/// `WeekDashboardView`, etc. — the registry is additive during the
/// migration.
@MainActor
enum SectionRegistry {
  static let all: [any SectionPlugin.Type] = [
    TasksPlugin.self,
    GoalsPlugin.self,
    HabitsPlugin.self,
    SupplementsPlugin.self,
    ChoresPlugin.self,
    GroceriesPlugin.self,
    SleepPlugin.self,
    BodyPlugin.self,
    AirPlugin.self,
    ActivityPlugin.self,
    MoodPlugin.self,
    CaffeinePlugin.self,
    CannabisPlugin.self,
    GutPlugin.self,
    TrainingPlugin.self,
    NutritionPlugin.self,
    HydrationPlugin.self,
    TestPlugin.self,
  ]

  static var byKey: [String: any SectionPlugin.Type] {
    Dictionary(uniqueKeysWithValues: all.map { ($0.manifest.key, $0) })
  }

  static func plugin(forKey key: String) -> (any SectionPlugin.Type)? {
    byKey[key]
  }
}
