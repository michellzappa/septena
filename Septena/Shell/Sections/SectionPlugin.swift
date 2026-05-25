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
  static func onboarding(complete: @escaping () -> Void) -> AnyView?

  /// MCP / agent contract for this section. Declares the read/write
  /// tools an LLM uses to manipulate this section's data, plus a
  /// human-readable brief on conventions and examples. Tightly bound
  /// to the plugin so the tool catalog can never drift out of sync
  /// with the section's actual behavior — they live in the same file.
  /// Return `nil` for sections that haven't migrated their skill yet
  /// (still in `SectionSkill.all`); `SectionSkill.byKey` falls through.
  static var mcpSkill: SectionSkill? { get }
}

// MARK: - SectionSkill resolution
//
// Sections that have migrated to the plugin model declare their MCP
// skill inline; sections that haven't migrated still live in the
// legacy `SectionSkill.all` list. These helpers give consumers one
// answer regardless of where the skill is declared.

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
    MoodPlugin.self,
    CaffeinePlugin.self,
    CannabisPlugin.self,
    GutPlugin.self,
    TrainingPlugin.self,
    TestPlugin.self,
  ]

  static var byKey: [String: any SectionPlugin.Type] {
    Dictionary(uniqueKeysWithValues: all.map { ($0.manifest.key, $0) })
  }

  static func plugin(forKey key: String) -> (any SectionPlugin.Type)? {
    byKey[key]
  }
}
