import SwiftUI
import EventKit
import SwiftData

// Per-section "plugin" abstraction. Each section bundles its catalog
// facts (manifest) and — over time — its dashboard tile, settings
// detail pane, and onboarding flow into one declaration. Everything
// that iterates "the list of sections" goes through `SectionRegistry`
// instead of switch statements scattered across the UI.
//
// This is the *narrow* first version: only `manifest` is required.
// Other slots (`mcpSkill`, `dashboardTile`, `detailPane`,
// `onboarding`) will be added as concrete migrations land.
//
// Plugins live in the app target (not SeptenaCore) because they
// construct view-layer types (SwiftUI views). SeptenaCore stays UI-free.

@MainActor
protocol SectionPlugin {
  /// Catalog identity. Resolves to a row in `SectionManifest.all`.
  static var manifest: SectionManifest { get }

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

  /// Goal-measurement metrics this section exposes. A `GoalMetric` is a
  /// queryable assertion over this section's logged data (e.g. "training
  /// sessions this week", "caffeine drinks today") that a user can attach
  /// to a Goal to turn it from a free-text intention into a measurable
  /// target. Declared on the plugin so the section owns its catalog —
  /// adding a section means adding its metrics in one place, not editing
  /// a central registry. Default: `[]` (section has nothing measurable).
  static var aimMetrics: [GoalMetric] { get }

  /// Runtime variant: metrics that depend on live data — e.g. the `intake`
  /// section exposes one metric set per user-defined kind, which only exist at
  /// runtime. The catalog calls THIS (passing the shared main context); the
  /// default returns the static `aimMetrics`, so a section with fixed metrics
  /// needs no change. Keys must embed a stable id (never a name) so renames
  /// don't orphan goals.
  static func aimMetrics(context: ModelContext) -> [GoalMetric]

  /// Compute the current value of one of this section's `aimMetrics`.
  /// Return `nil` for an unknown key — the dispatcher treats that as a
  /// 0 reading rather than crashing. Implementations should switch on
  /// the metric's key string.
  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double?

  /// Quick-log entries surfaced by the SectionDrawer's "+" toolbar
  /// button. Single action → tapping + fires it directly. Multiple →
  /// + opens a menu. Empty → no + button rendered. The destination
  /// view receives the tapped action's `id` via its drawer `onLog`
  /// handler and decides what to present (sheet, navigation, etc.).
  static var logActions: [LogAction] { get }

  /// How a *new* log in this section celebrates — the affect axis,
  /// declared here so the commit feel is manifest-driven (one place per
  /// section). `SectionLog.newLog` reads this. `nil` = no flourish
  /// (utility sections, or sections not yet migrated). Sections whose
  /// motion depends on the entry (e.g. caffeine time-of-day) declare a
  /// default here and pass an override at the call site.
  static var logFlourish: LogFlourish? { get }

  /// Local-notification nudges this section can raise. A `NotificationDescriptor`
  /// names one nudge (e.g. "overdue chore digest") and supplies its Settings
  /// toggle copy; `evaluateNotification` produces the live content + fire-time.
  /// Declared on the plugin so a section owns its nudges in one place — adding
  /// one is a one-file edit, and `LocalNotificationScheduler` enumerates them
  /// automatically. Default: `[]` (section has nothing to nudge about).
  static var notificationDescriptors: [NotificationDescriptor] { get }

  /// Evaluate one of this section's `notificationDescriptors` against the
  /// live data. Return a `NotificationPlan` to schedule it, or `nil` to
  /// suppress — already logged today, nothing pending, or not enough history
  /// to time it. `nil` is the auto-suppression mechanism: the scheduler
  /// withdraws any pending request whose descriptor returns nil. `now` is the
  /// evaluation instant (injected so the logic stays testable).
  static func evaluateNotification(_ descriptorID: String,
                                   context: ModelContext,
                                   now: Date) -> NotificationPlan?

  /// Daily numeric series this section contributes to correlation discovery.
  /// Each `CorrelationFeature` is one date→value series tagged with role
  /// (lever / outcome / neutral) + distribution, so the `CorrelationEngine`
  /// can auto-pair and gate it WITHOUT a hand-written relationship list.
  /// Default `[]` — a section contributes nothing until it opts in (built-in
  /// sections are still catalogued engine-side in `legacyCatalog` during the
  /// migration; new sections declare here). Only called for ACTIVE sections.
  static func correlationFeatures(context: ModelContext) -> [CorrelationFeature]

  /// Whether this section emits *time-of-day* data — timestamped instant
  /// events (a `LoggedEvent` entity), duration bands (sleep), or completion
  /// timestamps (tasks). The homepage Wheel mode uses this to decide which
  /// sections get a rhythm tile: a section with no timed source (Body,
  /// Groceries, GitHub, …) has nothing to plot on a 24-hour dial, so it's
  /// dropped rather than shown as a dead glyph. Default `false`; sections opt
  /// in alongside their `LoggedEvent` conformance. Activity is a future
  /// candidate once it exposes timestamped samples.
  static var producesTimedEvents: Bool { get }
}

/// Description of one "+" toolbar action declared by a plugin. The
/// view layer renders the affordance; the destination view performs
/// the work keyed off `id`.
struct LogAction: Identifiable, Hashable {
  let id: String
  let title: String
  let systemImage: String?

  init(id: String, title: String, systemImage: String? = nil) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
  }
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

/// Per-section Apple Health write toggle. Drop one of these into any plugin's
/// `detailPaneContent()` to give the user control over whether that section's
/// data flows to HealthKit. The toggle's enabled state and footer track the
/// *write* authorization for that specific type — so a user who denied this
/// category in the permission sheet sees an honest "turned off in Health"
/// message instead of a toggle that silently fails. Only renders on devices
/// where the type is writable (hidden on Mac, and for mood pre-iOS 18).
struct HKSyncSection: View {
  let label: String
  let icon: String
  let kind: HealthKitBridge.WritableKind

  @Environment(\.modelContext)     private var modelContext
  @Environment(CKEngine.self)      private var ckEngine
  @Environment(SettingsStore.self) private var store
  @State private var bridge = HealthKitBridge.shared

  var body: some View {
    let status = bridge.shareStatus(kind)
    if status != .unavailable {
      Section {
        Toggle(isOn: syncBinding) {
          Label(label, systemImage: icon)
        }
        .disabled(status != .authorized)
      } header: {
        Label("Apple Health", systemImage: "heart.text.square")
      } footer: {
        footer(for: status)
      }
      .task { bridge.refreshShareStatuses() }
    }
  }

  @ViewBuilder
  private func footer(for status: HealthKitBridge.ShareStatus) -> some View {
    switch status {
    case .notDetermined:
      Text("Connect Apple Health in Settings → Integrations to turn this on.")
    case .denied:
      Text("This category is turned off in Apple Health. To allow it, open Health → Profile → Apps → Septena.")
    case .authorized, .unavailable:
      EmptyView()
    }
  }

  private var keyPath: WritableKeyPath<HKSyncSettings, Bool> {
    switch kind {
    case .mood:      return \.mood
    case .nutrition: return \.nutrition
    }
  }

  private var syncBinding: Binding<Bool> {
    Binding {
      store.serverSettings?.hkSync?[keyPath: keyPath] ?? true
    } set: { newValue in
      var s = store.serverSettings ?? AppSettings(sectionOrder: nil, targets: nil,
                                                  units: nil, time: nil, theme: nil,
                                                  eink: nil, nutrition: nil, hkSync: nil)
      var hk = s.hkSync ?? HKSyncSettings()
      hk[keyPath: keyPath] = newValue
      s.hkSync = hk
      store.serverSettings = s
      HealthKitBridge.shared.syncSettings = hk
      SettingsMirror.upsert(settings: s, context: modelContext, engine: ckEngine)
    }
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
  /// Plugins without an `mcpSkill` (Sleep, Body, Activity) are skipped.
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
  /// destination (e.g. utility plugins with no standalone screen).
  /// Plugins that own their destination wrap it in AnyView and return
  /// it here.
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
  /// every off → on transition — for a setup flow that should re-run
  /// on each enable rather than commit to a one-time state.
  static var alwaysShowOnboarding: Bool { false }

  /// Default: no inline MCP brief — the section either has its entry
  /// in the legacy `SectionSkill.all` list (sections not yet migrated)
  /// or no agent contract at all (utility sections).
  static var mcpSkill: SectionSkill? { nil }

  /// Default: no measurable aim metrics. Plugins opt in by declaring a
  /// non-empty list and overriding `evaluateAim`.
  static var aimMetrics: [GoalMetric] { [] }

  /// Default: the static `aimMetrics`. Only sections with data-dependent
  /// metrics (intake) override this.
  static func aimMetrics(context: ModelContext) -> [GoalMetric] { aimMetrics }

  /// Default: no evaluator. Pairs with the empty default `aimMetrics`.
  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? { nil }

  /// Default: no quick-log actions. Sections opt in to surface a "+"
  /// affordance in the drawer by overriding this with at least one
  /// `LogAction` and wiring the destination view's `onLog` handler.
  static var logActions: [LogAction] { [] }

  /// Default: no commit flourish. Sections opt in by declaring a
  /// `LogFlourish` and routing their writes through `SectionLog`.
  static var logFlourish: LogFlourish? { nil }

  /// Default: no notification nudges. Sections opt in by declaring at least
  /// one `NotificationDescriptor` and overriding `evaluateNotification`.
  static var notificationDescriptors: [NotificationDescriptor] { [] }

  /// Default: no evaluator. Pairs with the empty default `notificationDescriptors`.
  static func evaluateNotification(_ descriptorID: String,
                                   context: ModelContext,
                                   now: Date) -> NotificationPlan? { nil }

  /// Default: section contributes no correlation features. Sections opt in
  /// by overriding this with at least one `CorrelationFeature`.
  static func correlationFeatures(context: ModelContext) -> [CorrelationFeature] { [] }

  /// Default: no time-of-day data. Timed sections override to `true`.
  static var producesTimedEvents: Bool { false }
}

/// Single source of truth for which plugins exist. Sections not in this
/// list still work via their inline implementations in
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
    ActivityPlugin.self,
    MoodPlugin.self,
    SymptomsPlugin.self,
    MedicationsPlugin.self,
    CaffeinePlugin.self,
    CannabisPlugin.self,
    IntakePlugin.self,
    GutPlugin.self,
    TrainingPlugin.self,
    NutritionPlugin.self,
    HydrationPlugin.self,
    GitHubPlugin.self,
  ]

  static var byKey: [String: any SectionPlugin.Type] {
    Dictionary(uniqueKeysWithValues: all.map { ($0.manifest.key, $0) })
  }

  static func plugin(forKey key: String) -> (any SectionPlugin.Type)? {
    byKey[key]
  }
}
