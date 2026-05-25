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
}

extension SectionPlugin {
  /// Default: no onboarding. Sections that need a setup flow override
  /// this; everything else inherits the no-op.
  static func onboarding(complete: @escaping () -> Void) -> AnyView? { nil }
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
    TestPlugin.self,
  ]

  static var byKey: [String: any SectionPlugin.Type] {
    Dictionary(uniqueKeysWithValues: all.map { ($0.manifest.key, $0) })
  }

  static func plugin(forKey key: String) -> (any SectionPlugin.Type)? {
    byKey[key]
  }
}
