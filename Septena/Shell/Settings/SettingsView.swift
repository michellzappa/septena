import SwiftUI
import SwiftData
import EventKit
import CloudKit
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

// Settings — the single unified surface for everything user-configurable.
// One sheet, one store, one entry point (sidebar row + ⌘,).
//
// Layout (Apple-style: app-wide rows on top, per-section rows below):
//   • Customize       — app-wide preferences (homepage layout, icon, quick actions)
//   • Integrations    — Reminders / Calendar / HealthKit permissions
//   • Sync            — server URL + manual sync
//   • Privacy         — analytics consent
//   • About           — version / links
//   ── Sections ────────────────────────────
//   • Tasks           — badge, today toggle, task sort + identity
//   • Training, Nutrition, Sleep, Habits, Cannabis, Caffeine, …
//                     — identity + (where applicable) catalog data
//
// Per-section rows are driven by `SectionManifest.all` filtered against
// the user's installed `SectionEntity` set (CloudKit-mirrored via
// CKEngine). Each row pushes to `SectionDetailPane(key:)` which composes
// identity + section-specific content.

// MARK: - Default keys

enum SettingsKey {
  static let badgeShowOverdue = "septena.badge.showOverdue"
  static let todayShowCompleted = "septena.today.showCompleted"
  /// Consent toggle for anonymous aggregate usage analytics (Plausible).
  /// Same key string is referenced by `PlausibleClient.consentKey` so the
  /// guard inside the actor and the @AppStorage binding stay in sync.
  static let shareUsageData   = "septena.privacy.shareUsageData"
  /// Global sort applied to task lists inside a project or area. Stored as
  /// the raw value of `TaskSort`. Lives in UserDefaults rather than per-list
  /// state — there's no per-project manual order in this app, so one global
  /// choice is the whole sort surface.
  static let taskSort         = "septena.task.sort"
  /// Which renderer the homepage uses. Raw value of `HomepageLayoutMode`.
  /// Default (`tiles`) preserves the existing card-grid behaviour, so
  /// users with no setting see no change.
  static let homepageLayout   = "septena.homepage.layout"
  /// Whether the day-timeline strip renders above the homepage layout.
  /// Default on; users who want a denser dashboard can hide it.
  static let homepageShowTodayTimeline = "septena.homepage.showTodayTimeline"
  /// Whether the time-of-day welcome (greeting + subtitle) renders at the
  /// very top of the homepage. Default on; mirrors the webapp's overview
  /// dashboard header.
  static let homepageShowWelcome = "septena.homepage.showWelcome"
  /// Time window (in days) the Correlations homepage mode computes over.
  /// Same key as the old Insights destination so prior preference carries
  /// forward.
  static let correlationsWindowDays = "insights.windowDays"
  /// Section filter for the Correlations homepage mode. "all" or a
  /// section key (e.g. "sleep").
  static let correlationsSectionFilter = "septena.correlations.sectionFilter"
  /// Whether to show the supplements → sleep score table above the
  /// trusted-signals grid. Default on.
  static let correlationsShowSupplements = "septena.correlations.showSupplements"
  /// Whether to show the "Not enough data yet" collapsed section
  /// below the exploratory grid. Default off.
  static let correlationsShowInsufficient = "septena.correlations.showInsufficient"
  /// Master toggle for fasting tracking. When on, the nutrition tile
  /// morphs into a live fasting timer once the state machine detects a
  /// fasting window, and the nutrition heatmap may show fasting hours
  /// per day (see `nutritionHeatmapMetric`). Off → no fasting UI.
  static let nutritionTrackFasting = "septena.nutrition.trackFasting"
  /// Which metric the nutrition heatmap encodes per cell. Either
  /// "protein" (default) or "fasting". Persistent preference; not
  /// state-based — the heatmap is historical, so the choice doesn't
  /// flip with current fasting state.
  static let nutritionHeatmapMetric = "septena.nutrition.heatmapMetric"
  /// User-selected Home Screen Quick Actions, stored as comma-separated
  /// section keys (max 4). Applied to `UIApplication.shared.shortcutItems`
  /// at launch and whenever the selection changes.
  static let quickActionKeys = "septena.quickActions.keys"
  /// Where the Tasks tile opens to from the homepage. Other section tiles
  /// open as a bottom-sheet drawer; Tasks historically jumped straight to
  /// the Tasks tab. Default `drawer` so Tasks matches the other sections;
  /// users who prefer landing on the full Tasks tab can flip it.
  static let tasksOpenIn      = "septena.tasks.openIn"
}

/// Where a homepage tap on the Tasks tile lands. `drawer` shows today's
/// tasks as a bottom-sheet (matches every other section); `tab` switches
/// the tab bar to the full Tasks surface.
enum TasksOpenMode: String, CaseIterable, Identifiable {
  case drawer, tab
  var id: String { rawValue }
  var label: String {
    switch self {
    case .drawer: return "Drawer"
    case .tab:    return "Tasks tab"
    }
  }
}

enum NutritionHeatmapMetric: String, CaseIterable, Identifiable {
  case protein, fasting
  var id: String { rawValue }
  var label: String { self == .protein ? "Protein" : "Fasting hours" }
}

enum AppIconOption: String, CaseIterable, Identifiable {
  case `default` = "AppIcon"
  case red       = "AppIconRed"
  case orange    = "AppIconOrange"
  case yellow    = "AppIconYellow"
  case green     = "AppIconGreen"
  case cyan      = "AppIconCyan"
  case blue      = "AppIconBlue"
  case purple    = "AppIconPurple"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .default: return "Default"
    case .red:     return "Red"
    case .orange:  return "Orange"
    case .yellow:  return "Yellow"
    case .green:   return "Green"
    case .cyan:    return "Cyan"
    case .blue:    return "Blue"
    case .purple:  return "Purple"
    }
  }

  var alternateIconName: String? {
    self == .default ? nil : rawValue
  }

  var background: Color {
    background(forDarkMode: false)
  }

  func background(forDarkMode isDarkMode: Bool) -> Color {
    if isDarkMode {
      return .clear
    }
    switch self {
    case .default: return .white
    case .red:     return parseHexColor("#ef4444")
    case .orange:  return parseHexColor("#f97316")
    case .yellow:  return parseHexColor("#eab308")
    case .green:   return parseHexColor("#22c55e")
    case .cyan:    return parseHexColor("#06b6d4")
    case .blue:    return parseHexColor("#3b82f6")
    case .purple:  return parseHexColor("#8b5cf6")
    }
  }

  var dotColors: [Color] {
    dotColors(forDarkMode: false)
  }

  func dotColors(forDarkMode isDarkMode: Bool) -> [Color] {
    if isDarkMode {
      switch self {
      case .default:
        return [
          parseHexColor("#ef4444"),
          parseHexColor("#f97316"),
          parseHexColor("#eab308"),
          parseHexColor("#22c55e"),
          parseHexColor("#06b6d4"),
          parseHexColor("#3b82f6"),
          parseHexColor("#8b5cf6"),
        ]
      case .red:
        return Array(repeating: parseHexColor("#ef4444"), count: 7)
      case .orange:
        return Array(repeating: parseHexColor("#f97316"), count: 7)
      case .yellow:
        return Array(repeating: parseHexColor("#eab308"), count: 7)
      case .green:
        return Array(repeating: parseHexColor("#22c55e"), count: 7)
      case .cyan:
        return Array(repeating: parseHexColor("#06b6d4"), count: 7)
      case .blue:
        return Array(repeating: parseHexColor("#3b82f6"), count: 7)
      case .purple:
        return Array(repeating: parseHexColor("#8b5cf6"), count: 7)
      }
    }
    switch self {
    case .default:
      return [
        parseHexColor("#ef4444"),
        parseHexColor("#f97316"),
        parseHexColor("#eab308"),
        parseHexColor("#22c55e"),
        parseHexColor("#06b6d4"),
        parseHexColor("#3b82f6"),
        parseHexColor("#8b5cf6"),
      ]
    default:
      return Array(repeating: .white, count: 7)
    }
  }

  #if os(iOS)
  static var current: AppIconOption {
    guard let name = UIApplication.shared.alternateIconName else { return .default }
    return AppIconOption(rawValue: name) ?? .default
  }
  #endif
}

/// Sort modes for tasks within a project or area detail view. Areas and
/// projects in the sidebar have manual drag-reorder, but tasks inside them
/// do not — so these two derived orderings are the entire sort surface.
enum TaskSort: String, CaseIterable, Identifiable {
  case dateAdded
  case alphabetical
  case dueDate
  var id: String { rawValue }
  var label: String {
    switch self {
    case .dateAdded:    return "Sort by Date Added"
    case .alphabetical: return "Sort by Name"
    case .dueDate:      return "Sort by Due Date"
    }
  }
  var icon: String {
    switch self {
    case .dateAdded:    return "clock"
    case .alphabetical: return "textformat"
    case .dueDate:      return "calendar"
    }
  }
}

// MARK: - Store
//
// One Observable holding the in-memory view of the user's settings,
// hydrated from the CloudKit-mirrored `SettingsEntity` + `SectionEntity`
// records via SettingsMirror. Local prefs continue to live as @AppStorage
// at use sites — they're already shared through the SettingsKey constants
// and don't need wrapping.

@MainActor
@Observable
final class SettingsStore {
  var serverSettings: AppSettings? = nil
  var sections: [SectionConfig] = []
  var caffeine: CaffeineConfig? = nil
  var cannabis: CannabisConfig? = nil
  var macros: MacrosConfig? = nil
  var sessionTypes: [SessionTypeConfig] = []
  var chores: [ChoreItem] = []
  var serverLoading: Bool = false

  /// Hydrate from the local mirror / disk cache during construction so the
  /// dashboard's first frame uses the user's saved section order and config
  /// instead of an empty array (which falls back to `HomepageDomain.defaultOrder`
  /// and causes a half-second reorder flash).
  init() {
    paintFromCache()
  }

  private enum CacheKey {
    static let serverSettings = "settings.serverSettings"
    static let sections       = "settings.sections"
    static let caffeine       = "settings.caffeine"
    static let cannabis       = "settings.cannabis"
    static let macros         = "settings.macros"
    static let sessionTypes   = "settings.sessionTypes"
    static let chores         = "settings.chores"
  }

  /// Synchronous read from disk-cached responses. Run at app launch
  /// before `refresh()` so the dashboard's tile order (driven by
  /// `sections`) and the section-config sub-panes render with last-known
  /// data instead of empty / default state during the network round-trip.
  func paintFromCache() {
    let context = LocalStore.shared.container.mainContext
    if let v = SettingsMirror.loadSettings(context: context) {
      serverSettings = v
      HealthKitBridge.shared.syncSettings = v.hkSync ?? HKSyncSettings()
    } else if let v = ResponseCache.load(AppSettings.self, forKey: CacheKey.serverSettings) {
      serverSettings = v
      HealthKitBridge.shared.syncSettings = v.hkSync ?? HKSyncSettings()
    }
    let mirroredSections = SettingsMirror.loadSections(context: context)
    if !mirroredSections.isEmpty {
      sections = mirroredSections
    } else if let v = ResponseCache.load([SectionConfig].self, forKey: CacheKey.sections) {
      sections = v
    }
    if let v = ResponseCache.load(CaffeineConfig.self, forKey: CacheKey.caffeine) { caffeine = v }
    if let v = ResponseCache.load(CannabisConfig.self, forKey: CacheKey.cannabis) { cannabis = v }
    if let v = ResponseCache.load(MacrosConfig.self, forKey: CacheKey.macros) { macros = v }
    if let v = ResponseCache.load([SessionTypeConfig].self, forKey: CacheKey.sessionTypes) { sessionTypes = v }
    if let v = ResponseCache.load([ChoreItem].self, forKey: CacheKey.chores) { chores = v }
  }

  func moveSections(fromOffsets: IndexSet, toOffset: Int,
                    context: ModelContext, engine: CKEngine?) {
    sections.move(fromOffsets: fromOffsets, toOffset: toOffset)
    var s = serverSettings ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                                          time: nil, theme: nil, eink: nil, nutrition: nil,
                                          hkSync: nil)
    s.sectionOrder = sections.map(\.key)
    serverSettings = s
    SettingsMirror.upsert(settings: s, context: context, engine: engine)
  }

  func refresh() async {
    serverLoading = true
    defer { serverLoading = false }
    let context = LocalStore.shared.container.mainContext

    // Every source below is local. Settings / sections are CloudKit-
    // mirrored via SettingsEntity / SectionEntity; chores / beans /
    // strains / session-types ride on their own CK entities; macros
    // live in NSUbiquitousKeyValueStore.
    if let mirroredSettings = SettingsMirror.loadSettings(context: context) {
      serverSettings = mirroredSettings
      ResponseCache.save(mirroredSettings, forKey: CacheKey.serverSettings)
      HealthKitBridge.shared.syncSettings = mirroredSettings.hkSync ?? HKSyncSettings()
    }
    let mirroredSections = SettingsMirror.loadSections(context: context)
    if !mirroredSections.isEmpty {
      sections = mirroredSections
      ResponseCache.save(mirroredSections, forKey: CacheKey.sections)
    }

    let macs: MacrosConfig? = NutritionPrefs.loadMacrosConfig()
    let st: [SessionTypeConfig]? = ChecklistMirror.loadSessionTypes(context: context)
    let ch: [ChoreItem]? = ChecklistMirror.loadChores(context: context)
    let cf: CaffeineConfig = {
      let beans = ChecklistMirror.loadCaffeineBeans(context: context)
      return CaffeineConfig(beans: beans)
    }()
    let cn = CannabisConfig(usesPerCapsule: 3)
    caffeine = cf; ResponseCache.save(cf, forKey: CacheKey.caffeine)
    cannabis = cn; ResponseCache.save(cn, forKey: CacheKey.cannabis)
    if let macs { macros = macs; ResponseCache.save(macs, forKey: CacheKey.macros) }
    if let st { sessionTypes = st; ResponseCache.save(st, forKey: CacheKey.sessionTypes) }
    if let ch { chores = ch; ResponseCache.save(ch, forKey: CacheKey.chores) }
  }
}

// MARK: - Sheet root

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store
  @State private var selection: SettingsDestination? = .general
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail

  /// Sidebar entries. Static cases for app-wide settings; `section(key)`
  /// for per-section rows resolved against `SectionManifest` + the live
  /// `store.sections` list.
  enum SettingsDestination: Hashable {
    case general, integrations, importExport, skills, siriShortcuts, privacy, about
    case manageSections
    case quickActions
    case appIcon
    case layout
    case correlations
    case section(String)
  }

  var body: some View {
    #if os(iOS)
    NavigationStack {
      sidebarList
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsDestination.self) { dest in
          pane(for: dest)
            .navigationTitle(title(for: dest))
            .navigationBarTitleDisplayMode(.inline)
        }
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
    #else
    NavigationSplitView(columnVisibility: $columnVisibility,
                        preferredCompactColumn: $preferredCompactColumn) {
      sidebarList(selection: $selection)
        .navigationTitle("Settings")
    } detail: {
      NavigationStack {
        let dest = selection ?? .general
        pane(for: dest)
          .navigationTitle(title(for: dest))
      }
    }
    .frame(minWidth: 720, minHeight: 460)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
      }
    }
    #endif
  }

  #if os(iOS)
  @ViewBuilder
  private var sidebarList: some View {
    List {
      SwiftUI.Section {
        ForEach(staticDestinations, id: \.self) { dest in
          NavigationLink(value: dest) { staticRow(dest) }
        }
      }
      if !sectionEntries.isEmpty {
        SwiftUI.Section("Sections") {
          ForEach(sectionEntries) { entry in
            NavigationLink(value: SettingsDestination.section(entry.key)) {
              sectionRow(entry)
            }
          }
          .onMove { from, to in
            store.moveSections(fromOffsets: from, toOffset: to,
                               context: modelContext, engine: ckEngine)
          }
        }
        .environment(\.editMode, .constant(.active))
      }
    }
  }
  #else
  @ViewBuilder
  private func sidebarList(selection: Binding<SettingsDestination?>) -> some View {
    List(selection: selection) {
      SwiftUI.Section {
        ForEach(staticDestinations, id: \.self) { dest in
          staticRow(dest).tag(dest)
        }
      }
      if !sectionEntries.isEmpty {
        SwiftUI.Section("Sections") {
          ForEach(sectionEntries) { entry in
            sectionRow(entry).tag(SettingsDestination.section(entry.key))
          }
          .onMove { from, to in
            store.moveSections(fromOffsets: from, toOffset: to,
                               context: modelContext, engine: ckEngine)
          }
        }
      }
    }
  }
  #endif

  private var staticDestinations: [SettingsDestination] {
    [.general, .integrations, .importExport, .skills, .manageSections, .privacy, .about]
  }

  /// Per-section sidebar rows, ordered by the user's saved `sectionOrder`
  /// (from the CloudKit-mirrored `AppSettings`), filtered to sections
  /// present in both the local manifest and the installed `SectionEntity`
  /// set. Disabled sections are still listed so the user can tap in to
  /// re-enable them; `sectionRow` renders them visually muted.
  private var sectionEntries: [SectionEntry] {
    let installedByKey = Dictionary(uniqueKeysWithValues: store.sections.map { ($0.key, $0) })
    let order = store.serverSettings?.sectionOrder ?? store.sections.map(\.key)
    return order.compactMap { key in
      guard let manifest = SectionManifest.byKey[key],
            let installed = installedByKey[key] else { return nil }
      return SectionEntry(manifest: manifest, server: installed)
    }
  }

  private func staticRow(_ dest: SettingsDestination) -> some View {
    Label {
      Text(title(for: dest))
    } icon: {
      ColoredGlyph(icon: icon(for: dest), color: tint(for: dest), size: 29, glyphRatio: 0.38)
    }
  }

  private func sectionRow(_ entry: SectionEntry) -> some View {
    // Reuse the homepage's per-section glyph *and its tinted treatment*
    // (`SectionGlyph`) so a section's icon reads identically in the
    // Dense/Heatmap tiles and here in the Settings sidebar. `calendar`
    // isn't a homepage domain — fall back to its own symbol; anything
    // else unknown falls back to a neutral dot.
    Label {
      Text(entry.label)
        .foregroundStyle(entry.isEnabled ? .primary : .secondary)
    } icon: {
      SectionGlyph(icon: sectionIcon(for: entry.key), accent: entry.accent, size: 29, glyphRatio: 0.38)
        .opacity(entry.isEnabled ? 1 : 0.4)
    }
  }

  private func sectionIcon(for key: String) -> String {
    if let m = SectionManifest.byKey[key] { return m.iconSymbol }
    return "circle.fill"
  }

  private func title(for dest: SettingsDestination) -> String {
    switch dest {
    case .general:      return "Customize"
    case .quickActions: return "Quick Actions"
    case .appIcon:      return "App Icon"
    case .layout:       return "Layout"
    case .correlations: return "Correlations"
    case .integrations: return "Integrations"
    case .importExport: return "Import & Export"
    case .skills:       return "Skills"
    case .siriShortcuts: return "Siri & Shortcuts"
    case .privacy:      return "Privacy"
    case .about:        return "About"
    case .manageSections: return "Manage Sections"
    case .section(let key):
      return store.sections.first(where: { $0.key == key })?.label
        ?? SectionManifest.byKey[key]?.defaultLabel
        ?? key.capitalized
    }
  }

  // Icon + tint helpers are only used for the static rows on top —
  // section rows render their own color-dot label via `sectionRow`.
  private func icon(for dest: SettingsDestination) -> String {
    switch dest {
    case .general:      return "slider.horizontal.3"
    case .quickActions: return "bolt"
    case .appIcon:      return "app.badge"
    case .layout:       return "square.grid.2x2"
    case .correlations: return "chart.dots.scatter"
    case .integrations: return "app.connected.to.app.below.fill"
    case .importExport: return "square.and.arrow.up.on.square"
    case .skills:       return "sparkles"
    case .siriShortcuts: return "mic"
    case .privacy:      return "hand.raised"
    case .about:        return "info.circle"
    case .manageSections: return "square.grid.2x2"
    case .section:      return ""  // unreachable; sectionRow handles section dests
    }
  }

  /// The app's 7 accent colors — the Septena app-icon rainbow (same set
  /// as `AppIconOption`'s discs). The app-wide settings rows cycle
  /// through these in `staticDestinations` order instead of carrying
  /// ad-hoc per-row tints, so the palette stays on-brand and consistent.
  private static let accentPalette: [Color] = [
    parseHexColor("#ef4444"), // red
    parseHexColor("#f97316"), // orange
    parseHexColor("#eab308"), // yellow
    parseHexColor("#22c55e"), // green
    parseHexColor("#06b6d4"), // cyan
    parseHexColor("#3b82f6"), // blue
    parseHexColor("#8b5cf6"), // purple
  ]

  private func tint(for dest: SettingsDestination) -> Color {
    guard let idx = staticDestinations.firstIndex(of: dest) else { return .gray }
    return Self.accentPalette[idx % Self.accentPalette.count]
  }

  @ViewBuilder
  private func pane(for dest: SettingsDestination) -> some View {
    switch dest {
    case .general:           GeneralSettingsPane()
    case .quickActions:      QuickActionsSettingsPane()
    case .appIcon:           AppIconSettingsPane()
    case .layout:            LayoutSettingsPane()
    case .correlations:      CorrelationsSettingsPane()
    case .integrations:      IntegrationsSettingsPane()
    case .importExport:      ImportExportSettingsPane()
    case .skills:            SkillsSettingsPane()
    case .siriShortcuts:     SiriShortcutsSettingsPane()
    case .privacy:           PrivacySettingsPane()
    case .about:             AboutSettingsPane()
    case .manageSections:    ManageSectionsPane()
    case .section(let key):  SectionDetailPane(sectionKey: key)
    }
  }
}

/// Resolved sidebar row for a section — combines the static manifest
/// (icon, defaults) with the live server overrides (label, accent).
struct SectionEntry: Identifiable, Hashable {
  let manifest: SectionManifest
  let server: SectionConfig
  var id: String { manifest.key }
  var key: String { manifest.key }
  /// Installed `SectionEntity.title` wins; manifest default is the
  /// fallback when the user hasn't customized the label (or the local
  /// mirror hasn't hydrated yet).
  var label: String {
    server.label.isEmpty ? manifest.defaultLabel : server.label
  }
  /// Accent comes from the user's `SectionEntity.color`. No catalog
  /// default — `parseHexColor` already returns neutral gray for empty
  /// or unparseable strings, which is the right fallback when the user
  /// hasn't picked a color yet.
  var accent: Color { parseHexColor(server.color) }
  /// User has turned this section off. The row stays in the sidebar but
  /// renders muted so it's clear the section isn't active.
  var isEnabled: Bool { server.isEnabled }
}

// MARK: - Privacy
//
// One toggle (anonymous Plausible screen-view analytics) plus a plain-
// language disclosure of exactly what is and isn't sent. The toggle is
// the same UserDefault key the actor reads, so flipping it takes effect
// on the next screen view — no app restart needed.

struct PrivacySettingsPane: View {
  @AppStorage(SettingsKey.shareUsageData) private var share: Bool = true

  var body: some View {
    Form {
      Section {
        Toggle("Share anonymous usage data", isOn: $share)
      } footer: {
        Text("Helps us understand which features people use, so we improve the right things.")
      }

      Section("What is sent") {
        bullet("Which screens you open (e.g. \"Nutrition\", \"Sleep\")")
        bullet("App version, build, and platform (iOS or macOS)")
      }

      Section("What is never sent") {
        bullet("Anything you log — food, caffeine, cannabis, supplements, sleep, mood, notes. None of it leaves your device through analytics.")
        bullet("Any identifier that links events to you, or links today's session to yesterday's.")
        bullet("Your IP address. The analytics provider uses it briefly to derive your country, then discards it.")
      }

      Section {
        EmptyView()
      } footer: {
        VStack(alignment: .leading, spacing: 8) {
          Text("Analytics is provided by Plausible Analytics (EU-hosted, cookie-free).")
          Link("plausible.io/privacy",
               destination: URL(string: "https://plausible.io/privacy")!)
            .font(.callout)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("•").foregroundStyle(.secondary)
      Text(text).foregroundStyle(.primary)
    }
  }
}

// MARK: - General

struct GeneralSettingsPane: View {
  @AppStorage(SettingsKey.homepageShowTodayTimeline)
  private var showTodayTimeline: Bool = true
  @AppStorage(SettingsKey.homepageShowWelcome)
  private var showWelcome: Bool = true

  var body: some View {
    Form {
      Section {
        NavigationLink(value: SettingsView.SettingsDestination.layout) {
          Label("Layout", systemImage: "square.grid.2x2")
        }
        NavigationLink(value: SettingsView.SettingsDestination.correlations) {
          Label("Correlations", systemImage: "chart.dots.scatter")
        }
      } footer: {
        Text("Pick how the homepage renders — Histogram, Sparkline, Heatmap, or Correlations.")
      }

      homepageWelcomeSection
      homepageTimelineSection

      #if os(iOS)
      Section {
        NavigationLink(value: SettingsView.SettingsDestination.quickActions) {
          Label("Quick Actions", systemImage: "bolt")
        }
      } footer: {
        Text("Choose up to 4 sections to surface when you long-press the app icon on the Home Screen.")
      }
      #endif

      Section {
        NavigationLink(value: SettingsView.SettingsDestination.appIcon) {
          Label("App Icon", systemImage: "app.badge")
        }
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private var homepageTimelineSection: some View {
    Section {
      Toggle(isOn: $showTodayTimeline) {
        Label("Show Today timeline", systemImage: "clock")
      }
    } footer: {
      Text("Renders the day-timeline strip above the homepage layout.")
    }
  }

  @ViewBuilder
  private var homepageWelcomeSection: some View {
    Section {
      Toggle(isOn: $showWelcome) {
        Label("Show welcome", systemImage: "sun.horizon")
      }
    } footer: {
      Text("A centered time-of-day greeting at the top of the home tab.")
    }
  }

}

// MARK: - Layout submenu
//
// Picker for the homepage renderer, plus one generic example
// (icon + label, no data) showing what the selected mode looks like.
// Example is mode-styled — Tile card / Sparkline row / Heatmap row.

struct LayoutSettingsPane: View {
  @AppStorage(SettingsKey.homepageLayout)
  private var homepageLayoutRaw: String = HomepageLayoutMode.tiles.rawValue

  private var binding: Binding<HomepageLayoutMode> {
    Binding(
      get: { HomepageLayoutMode(rawValue: homepageLayoutRaw) ?? .tiles },
      set: { homepageLayoutRaw = $0.rawValue }
    )
  }

  var body: some View {
    let current = binding.wrappedValue
    Form {
      Section {
        Picker(selection: binding) {
          ForEach(HomepageLayoutMode.allCases) { mode in
            Label {
              HStack {
                Text(mode.title)
                if !mode.isImplemented {
                  Spacer()
                  Text("Coming soon")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
            } icon: {
              Image(systemName: mode.icon)
            }
            .tag(mode)
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
        #if os(iOS)
        .pickerStyle(.inline)
        #endif
      } footer: {
        Text(current.summary)
      }

      Section {
        LayoutPreviewExample(mode: current)
          .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
      } header: {
        Text("Example")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Correlations submenu
//
// Controls the `.correlations` homepage layout mode — time window,
// section filter, and which extra sections (supplements table /
// insufficient-data fold-out) render below the trusted + exploratory
// grids. Replaces the toolbar controls of the old Insights page.

struct CorrelationsSettingsPane: View {
  @AppStorage(SettingsKey.correlationsWindowDays)
  private var windowDays: Int = 365
  @AppStorage(SettingsKey.correlationsSectionFilter)
  private var sectionFilter: String = "all"
  @AppStorage(SettingsKey.correlationsShowSupplements)
  private var showSupplements: Bool = true
  @AppStorage(SettingsKey.correlationsShowInsufficient)
  private var showInsufficient: Bool = false

  private let sectionOptions: [(key: String, label: String)] = [
    ("all",         "All"),
    ("habits",      "Habits"),
    ("supplements", "Supplements"),
    ("training",    "Training"),
    ("nutrition",   "Nutrition"),
    ("caffeine",    "Caffeine"),
    ("cannabis",    "Cannabis"),
    ("gut",         "Gut"),
    ("sleep",       "Sleep"),
  ]

  var body: some View {
    Form {
      Section {
        Picker("Time window", selection: $windowDays) {
          Text("30 days").tag(30)
          Text("90 days").tag(90)
          Text("6 months").tag(180)
          Text("1 year").tag(365)
          Text("2 years").tag(730)
        }
        Picker("Section filter", selection: $sectionFilter) {
          ForEach(sectionOptions, id: \.key) { Text($0.label).tag($0.key) }
        }
      } footer: {
        Text("Window controls how far back CorrelationEngine pulls data. Section filter limits which predictor → target pairs render — pairs are kept if either side matches.")
      }

      Section {
        Toggle("Show Supplements → Sleep table", isOn: $showSupplements)
        Toggle("Show insufficient-data section", isOn: $showInsufficient)
      } footer: {
        Text("Insufficient pairs (1 ≤ n < \(CorrelationEngine.minN) overlapping days) are too noisy to chart but listed here so you can see what's almost ready.")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - App Icon submenu

struct AppIconSettingsPane: View {
  #if os(iOS)
  @State private var selectedIcon: AppIconOption = .current
  @State private var iconError: String? = nil
  @State private var iconChangeInFlight = false
  #endif

  var body: some View {
    Form {
      #if os(iOS)
      if UIApplication.shared.supportsAlternateIcons {
        appIconSection
      } else {
        Section {
          Text("App icon selection isn’t available on this device.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      #else
      Section {
        Text("App icon selection is available on the iPhone and iPad app.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      #endif
    }
    .formStyle(.grouped)
    #if os(iOS)
    .onAppear { selectedIcon = .current }
    .alert("Couldn’t Change App Icon", isPresented: Binding(
      get: { iconError != nil },
      set: { if !$0 { iconError = nil } }
    )) {
      Button("OK", role: .cancel) { iconError = nil }
    } message: {
      Text(iconError ?? "Please try again.")
    }
    #endif
  }

  #if os(iOS)
  private var appIconSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 14) {
          AppIconPreview(option: selectedIcon, size: 62)
          VStack(alignment: .leading, spacing: 3) {
            Text("Current Icon")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(selectedIcon.title)
              .font(.septenaCardTitle)
            if selectedIcon == .default {
              Text("The original multicolor icon.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
              Text("Light mode uses a \(selectedIcon.title.lowercased()) background with white discs. Dark mode uses transparent artwork so the system background shows through behind \(selectedIcon.title.lowercased()) discs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
          ForEach(AppIconOption.allCases) { option in
            Button {
              selectIcon(option)
            } label: {
              AppIconChoiceCard(option: option,
                                isSelected: option == selectedIcon,
                                isDisabled: iconChangeInFlight)
            }
            .buttonStyle(.plain)
            .disabled(iconChangeInFlight)
          }
        }
      }
      .padding(.vertical, 4)
    } footer: {
      Text("iOS shows a confirmation prompt each time you switch icons.")
    }
  }

  private func selectIcon(_ option: AppIconOption) {
    guard option != selectedIcon, !iconChangeInFlight else { return }
    iconChangeInFlight = true
    UIApplication.shared.setAlternateIconName(option.alternateIconName) { error in
      DispatchQueue.main.async {
        iconChangeInFlight = false
        if let error {
          selectedIcon = .current
          iconError = error.localizedDescription
        } else {
          selectedIcon = option
        }
      }
    }
  }
  #endif
}

// MARK: - Layout preview
//
// One generic example rendered with the real homepage components
// (`ModuleTile`, `DenseHomepageView`, `HeatmapHomepageView`) populated
// with deterministic fake data — so the preview matches what the
// homepage actually draws, not a hand-rolled approximation.

private enum LayoutPreviewSample {
  /// Deterministic 90-day series shared by all three renderers — the
  /// tile's 7-day histogram is just `bars90.suffix(7)`, the sparkline
  /// and heatmap consume the full 90-day window. Values span 1…7 so
  /// every day is visible (no all-zero gaps in the 7-day strip) while
  /// still covering enough range for the heatmap to bucket into all
  /// five levels.
  static let bars90: [Int] = (0..<90).map { i in
    let phase = Double(i) * 0.42
    let v = 4.0 + 2.6 * sin(phase) + 1.2 * sin(phase * 0.31)
    return max(1, Int(v.rounded()))
  }

  /// Trailing 7-day window of `bars90` — same source data, just sliced.
  static let bars7: [Int] = Array(bars90.suffix(7))
  static let accent: Color = .green

  static let domainData = HomepageDomainData(
    domain: .habits,
    title: "Habits",
    accent: accent,
    headline: "5 of 7 today",
    headlineStats: [
      .init(label: "Today",   value: "5"),
      .init(label: "Skipped", value: "1"),
    ],
    progress: .init(label: "Today's progress", current: 5, target: 7),
    history: .bars(bars90),
    tap: .openSheet(.habits)
  )
}

private struct LayoutPreviewExample: View {
  let mode: HomepageLayoutMode

  var body: some View {
    Group {
      switch mode {
      case .tiles:
        ModuleTile(
          title: "Habits",
          accent: LayoutPreviewSample.accent,
          stats: [
            .init(label: "Today",   value: "5"),
            .init(label: "Skipped", value: "1"),
          ],
          progress: .init(
            label: "Today's progress",
            current: 5,
            target: 7
          ),
          history: .init(label: "7-day adherence", values: LayoutPreviewSample.bars7)
        )
      case .dense:
        DenseHomepageView(
          items: [LayoutPreviewSample.domainData],
          onTap: { _ in },
          menuContent: { _ in EmptyView() }
        )
      case .heatmap:
        HeatmapHomepageView(
          items: [LayoutPreviewSample.domainData],
          onTap: { _ in },
          menuContent: { _ in EmptyView() }
        )
      case .correlations:
        CorrelationsPreviewExample()
      }
    }
    .allowsHitTesting(false)
  }
}

/// Static sample row for the `.correlations` mode preview — doesn't
/// run CorrelationEngine, just shows what one trusted-pair row looks
/// like so the settings example matches the live dashboard shape.
private struct CorrelationsPreviewExample: View {
  var body: some View {
    VStack(spacing: 0) {
      row(predictor: "Magnesium", target: "Sleep score", r: 0.42, lag: 1, n: 58, p: 0.014, color: .indigo, positive: true)
      Divider().padding(.leading, 12)
      row(predictor: "Caffeine after 2pm", target: "Sleep score", r: -0.31, lag: 0, n: 41, p: 0.038, color: .brown, positive: false)
    }
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardSurface)
    )
  }

  private func row(predictor: String, target: String, r: Double, lag: Int, n: Int, p: Double, color: Color, positive: Bool) -> some View {
    HStack(spacing: 10) {
      Circle().fill(color).frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(predictor).font(.subheadline.weight(.medium)).lineLimit(1)
          Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
          Text(target).font(.subheadline.weight(.medium)).lineLimit(1)
        }
        Text("lag \(lag)d · n=\(n) · p=\(String(format: "%.3f", p))")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text(String(format: "%+.2f", r))
        .font(.caption.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((positive ? Color.green : Color.red).opacity(0.18), in: Capsule())
        .foregroundStyle(positive ? Color.green : Color.red)
      Image(systemName: "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
  }
}

private struct AppIconPreview: View {
  @Environment(\.colorScheme) private var colorScheme
  let option: AppIconOption
  let size: CGFloat

  private let discCenters: [CGPoint] = [
    CGPoint(x: 0.50, y: 0.2235),
    CGPoint(x: 0.7171, y: 0.3256),
    CGPoint(x: 0.7709, y: 0.5631),
    CGPoint(x: 0.6206, y: 0.7505),
    CGPoint(x: 0.3794, y: 0.7505),
    CGPoint(x: 0.2291, y: 0.5631),
    CGPoint(x: 0.2829, y: 0.3256),
  ]

  var body: some View {
    let isDarkMode = colorScheme == .dark
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)
        .fill(option.background(forDarkMode: isDarkMode))
      ForEach(Array(discCenters.enumerated()), id: \.offset) { index, center in
        Circle()
          .fill(option.dotColors(forDarkMode: isDarkMode)[index])
          .frame(width: size * 0.182, height: size * 0.182)
          .position(x: size * center.x, y: size * center.y)
      }
    }
    .frame(width: size, height: size)
    .overlay(
      RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)
        .stroke(Color.black.opacity(isDarkMode ? 0.12 : (option == .default ? 0.07 : 0.09)), lineWidth: 0.8)
    )
    .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
  }
}

#if os(iOS)
private struct AppIconChoiceCard: View {
  let option: AppIconOption
  let isSelected: Bool
  let isDisabled: Bool

  var body: some View {
    VStack(spacing: 8) {
      ZStack(alignment: .topTrailing) {
        AppIconPreview(option: option, size: 64)
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .scaledFont(size: 18, weight: .semibold)
            .foregroundStyle(.white, .green)
            .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
            .offset(x: 5, y: -5)
        }
      }
      Text(option.title)
        .font(.footnote.weight(isSelected ? .semibold : .regular))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.9)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .background(cardBackground)
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(isSelected ? option.background.opacity(option == .default ? 0.18 : 0.92)
                           : Color.primary.opacity(0.08),
                lineWidth: isSelected ? 2 : 1)
    )
    .opacity(isDisabled ? 0.7 : 1)
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var cardBackground: some ShapeStyle {
    isSelected
      ? AnyShapeStyle(option.background.opacity(option == .default ? 0.08 : 0.16))
      : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
  }
}
#endif

// MARK: - Quick Actions
//
// Multi-select pane (capped at 4) that picks which sections appear in the
// Home Screen long-press menu. Persists as a comma-separated list of
// section keys in UserDefaults; on every change, `QuickActionsApplier`
// rebuilds `UIApplication.shared.shortcutItems` to match. Listing is
// driven by `store.sections` filtered to enabled rows so disabled
// sections can never be picked.

struct QuickActionsSettingsPane: View {
  @Environment(SettingsStore.self) private var store
  @AppStorage(SettingsKey.quickActionKeys) private var stored: String = ""

  private static let limit = 4

  private var selected: [String] {
    stored.split(separator: ",")
      .map { String($0) }
      .filter { !$0.isEmpty }
  }

  private var availableEntries: [(manifest: SectionManifest, accent: Color)] {
    let order = store.serverSettings?.sectionOrder ?? store.sections.map(\.key)
    let configByKey = Dictionary(uniqueKeysWithValues: store.sections.map { ($0.key, $0) })
    return order.compactMap { key -> (SectionManifest, Color)? in
      guard let manifest = SectionManifest.byKey[key],
            let config = configByKey[key],
            config.isEnabled,
            manifest.supportsDashboard,
            WeekDestination(rawValue: key) != nil else { return nil }
      return (manifest, parseHexColor(config.color))
    }
  }

  var body: some View {
    Form {
      Section {
        ForEach(availableEntries, id: \.manifest.key) { entry in
          row(for: entry.manifest, accent: entry.accent)
        }
      } header: {
        HStack {
          Text("Sections")
          Spacer()
          Text("\(selected.count) / \(Self.limit)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      } footer: {
        Text("Pick up to \(Self.limit) sections. Each one becomes a shortcut in the Home Screen long-press menu, opening directly into that section.")
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private func row(for manifest: SectionManifest, accent: Color) -> some View {
    let isSelected = selected.contains(manifest.key)
    let isAtLimit = selected.count >= Self.limit
    Button {
      toggle(manifest.key)
    } label: {
      HStack(spacing: 12) {
        ColoredGlyph(icon: manifest.iconSymbol, color: accent, size: 22)
        VStack(alignment: .leading, spacing: 1) {
          let serverLabel = store.sections.first(where: { $0.key == manifest.key })?.label ?? ""
          Text(serverLabel.isEmpty ? manifest.defaultLabel : serverLabel)
            .foregroundStyle(.primary)
          if !manifest.shortDescription.isEmpty {
            Text(manifest.shortDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isSelected && isAtLimit)
    .opacity(!isSelected && isAtLimit ? 0.5 : 1)
  }

  private func toggle(_ key: String) {
    var current = selected
    if let idx = current.firstIndex(of: key) {
      current.remove(at: idx)
    } else {
      guard current.count < Self.limit else { return }
      current.append(key)
    }
    stored = current.joined(separator: ",")
    #if os(iOS)
    QuickActionsApplier.apply()
    #endif
  }
}

// MARK: - Section detail
//
// One pane per section, addressed by stable key. Identity (icon, label,
// color, description) comes from the local `SectionManifest`; the user's
// installed `SectionEntity` (label/color) overrides the defaults when
// present. Per-key content below uses cached catalog data from
// `SettingsStore` — caffeine beans, cannabis strains, etc. Sections
// without catalog data show identity only. Tasks is special-cased to
// host the local task prefs (badge, today, sort) that used to live in
// a top-level Tasks pane.

// MARK: - Palette

private struct PaletteSwatch: Identifiable {
  let id: String
  let label: String
  let hex: String
}

private let sectionPalette: [PaletteSwatch] = [
  // Bright row — Tailwind 500
  .init(id: "red",        label: "Red",        hex: "#ef4444"),
  .init(id: "orange",     label: "Orange",     hex: "#f97316"),
  .init(id: "amber",      label: "Amber",      hex: "#f59e0b"),
  .init(id: "yellow",     label: "Yellow",     hex: "#eab308"),
  .init(id: "lime",       label: "Lime",       hex: "#84cc16"),
  .init(id: "green",      label: "Green",      hex: "#22c55e"),
  .init(id: "emerald",    label: "Emerald",    hex: "#10b981"),
  .init(id: "teal",       label: "Teal",       hex: "#14b8a6"),
  .init(id: "cyan",       label: "Cyan",       hex: "#06b6d4"),
  .init(id: "sky",        label: "Sky",        hex: "#0ea5e9"),
  .init(id: "blue",       label: "Blue",       hex: "#3b82f6"),
  .init(id: "indigo",     label: "Indigo",     hex: "#6366f1"),
  .init(id: "violet",     label: "Violet",     hex: "#8b5cf6"),
  .init(id: "purple",     label: "Purple",     hex: "#a855f7"),
  .init(id: "pink",       label: "Pink",       hex: "#ec4899"),
  .init(id: "rose",       label: "Rose",       hex: "#f43f5e"),
  // Earth row — Tailwind 700/800 warm hues
  .init(id: "terracotta", label: "Terracotta", hex: "#9a3412"),
  .init(id: "brown",      label: "Brown",      hex: "#b45309"),
  .init(id: "mustard",    label: "Mustard",    hex: "#854d0e"),
  .init(id: "olive",      label: "Olive",      hex: "#3f6212"),
  .init(id: "taupe",      label: "Taupe",      hex: "#78716c"),
  .init(id: "espresso",   label: "Espresso",   hex: "#44403c"),
]

private struct PaletteSwatchGrid: View {
  let selectedHex: String
  let onSelect: (String) -> Void

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(sectionPalette) { swatch in
        let color = parseHexColor(swatch.hex)
        let isSelected = selectedHex.lowercased() == swatch.hex.lowercased()
        Button {
          onSelect(swatch.hex)
        } label: {
          Circle()
            .fill(color)
            .frame(width: 28, height: 28)
            .overlay(
              Circle()
                .strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                .padding(isSelected ? -3 : 0)
            )
            .overlay(
              Circle()
              #if canImport(UIKit)
                .strokeBorder(Color(UIColor.systemBackground), lineWidth: isSelected ? 2 : 0)
              #else
                .strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: isSelected ? 2 : 0)
              #endif
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.label)
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Manage Sections pane

/// Master list of every section in `SectionManifest.all` with per-row
/// enable/disable toggles. `.always` sections render as locked. Toggling
/// here writes through `SettingsMirror.setSectionEnabled` — never deletes
/// the SectionEntity row, so customizations (color, label) survive.
struct ManageSectionsPane: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @State private var pendingOnboarding: PendingOnboarding? = nil

  /// Identifiable wrapper so `.sheet(item:)` can drive presentation
  /// from the key alone — the plugin is looked up at render time.
  private struct PendingOnboarding: Identifiable {
    let key: String
    var id: String { key }
  }

  private var rows: [SectionManifest] {
    let order = store.serverSettings?.sectionOrder ?? store.sections.map(\.key)
    let orderedKeys = order.compactMap { SectionManifest.byKey[$0]?.key }
    let orderedSet = Set(orderedKeys)
    let trailing = SectionManifest.all
      .filter { !orderedSet.contains($0.key) }
      .map(\.key)
    return (orderedKeys + trailing).compactMap { SectionManifest.byKey[$0] }
  }

  private func isEnabled(_ key: String) -> Bool {
    store.sections.first(where: { $0.key == key })?.isEnabled ?? true
  }

  var body: some View {
    Form {
      Section {
        ForEach(rows) { manifest in
          row(for: manifest)
        }
      } footer: {
        Text("Disabled sections stay in the central store. Toggling one off hides it on the dashboard and sidebar, but never deletes any data or your color and label customizations.")
      }
    }
    .formStyle(.grouped)
    .sheet(item: $pendingOnboarding) { pending in
      onboardingSheet(for: pending.key)
    }
  }

  /// Resolve the plugin for `key` and present its onboarding view. The
  /// view is responsible for calling `complete()` to finish the flow;
  /// any other dismissal (swipe down, Cancel button if the plugin
  /// provides one) leaves the section disabled.
  @ViewBuilder
  private func onboardingSheet(for key: String) -> some View {
    if let plugin = SectionRegistry.plugin(forKey: key),
       let view = plugin.onboarding(complete: {
         completeOnboarding(key: key)
       }) {
      view
    } else {
      // Defensive — shouldn't happen because we only set
      // `pendingOnboarding` after confirming the plugin offers one.
      Text("No onboarding available.")
        .padding()
    }
  }

  private func completeOnboarding(key: String) {
    SettingsMirror.setSectionHasOnboarded(key,
                                          hasOnboarded: true,
                                          context: modelContext,
                                          engine: ckEngine)
    SettingsMirror.setSectionEnabled(key,
                                     enabled: true,
                                     context: modelContext,
                                     engine: ckEngine)
    store.sections = store.sections.map { config in
      config.key == key
        ? SectionConfig(key: config.key,
                        label: config.label,
                        color: config.color,
                        isEnabled: true,
                        showInToday: config.showInToday,
                        hasOnboarded: true)
        : config
    }
    pendingOnboarding = nil
  }

  @ViewBuilder
  private func row(for manifest: SectionManifest) -> some View {
    let enabled = isEnabled(manifest.key)
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(label(for: manifest))
          .foregroundStyle(enabled ? .primary : .secondary)
        if !manifest.shortDescription.isEmpty {
          Text(manifest.shortDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      setupButton(for: manifest.key)
      if manifest.canDisable {
        Toggle("Enabled", isOn: Binding(
          get: { enabled },
          set: { setEnabled(manifest.key, $0) }
        ))
        .labelsHidden()
      } else {
        Text("Always on")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// Manual onboarding trigger. Visible only when the section's plugin
  /// declares an `onboarding(complete:)` view — for everything else,
  /// the section has no setup flow to run. Tapping reuses the same
  /// presentation path the off → on toggle uses.
  @ViewBuilder
  private func setupButton(for key: String) -> some View {
    if let plugin = SectionRegistry.plugin(forKey: key),
       plugin.onboarding(complete: {}) != nil {
      Button {
        pendingOnboarding = PendingOnboarding(key: key)
      } label: {
        Image(systemName: "wand.and.stars")
          .font(.callout)
          .foregroundStyle(.tint)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Run setup")
    }
  }

  private func label(for manifest: SectionManifest) -> String {
    let server = store.sections.first(where: { $0.key == manifest.key })?.label ?? ""
    return server.isEmpty ? manifest.defaultLabel : server
  }

  private func setEnabled(_ key: String, _ enabled: Bool) {
    // Off → on transition: if the section has a plugin onboarding flow
    // and either hasn't been onboarded yet OR the plugin opts into
    // re-presenting on every enable, route through the sheet
    // instead of enabling directly. The sheet's completion handler
    // does the enable + hasOnboarded write.
    if enabled,
       let config = store.sections.first(where: { $0.key == key }),
       !config.isEnabled,
       let plugin = SectionRegistry.plugin(forKey: key),
       plugin.onboarding(complete: {}) != nil,
       (!config.hasOnboarded || plugin.alwaysShowOnboarding) {
      pendingOnboarding = PendingOnboarding(key: key)
      return
    }

    SettingsMirror.setSectionEnabled(key,
                                     enabled: enabled,
                                     context: modelContext,
                                     engine: ckEngine)
    store.sections = store.sections.map { config in
      config.key == key
        ? SectionConfig(key: config.key,
                        label: config.label,
                        color: config.color,
                        isEnabled: enabled,
                        showInToday: config.showInToday,
                        hasOnboarded: config.hasOnboarded)
        : config
    }
  }

}

// MARK: - Section detail pane

struct SectionDetailPane: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  let sectionKey: String
  @State private var showingColorPicker = false
  // showingSupplementSheet moved into SupplementsPlugin's detailPaneContent.

  // Per-section preferences and sheets now live inside each plugin's
  // detailPaneContent view, where they're only constructed when that
  // section's page is showing. No more app-wide @AppStorage bindings
  // declared up here for sections this pane doesn't always render.

  private var manifest: SectionManifest? { SectionManifest.byKey[sectionKey] }
  private var server: SectionConfig? {
    store.sections.first(where: { $0.key == sectionKey })
  }
  private var label: String {
    let serverLabel = server?.label ?? ""
    if !serverLabel.isEmpty { return serverLabel }
    return manifest?.defaultLabel ?? sectionKey.capitalized
  }
  private var accent: Color {
    parseHexColor(server?.color ?? "")
  }

  /// Background of a grouped-form row — used as the gap color between the
  /// swatch's rainbow ring and its colored center, so the ring stays
  /// visually detached on both platforms.
  private var rowBackgroundColor: Color {
    #if canImport(UIKit)
    Color(uiColor: .secondarySystemGroupedBackground)
    #else
    Color(nsColor: .windowBackgroundColor)
    #endif
  }

  var body: some View {
    Form {
      identitySection
      sectionSpecific
      // Contextual "Ask Siri" tip for this section's primary log action.
      // Centralized here (not per-plugin) so all 13 sections are covered in
      // one place; iOS-only, renders nothing for sections without an action.
      sectionSiriTip(forKey: sectionKey)
      skillAndDataSection
    }
    .formStyle(.grouped)
  }

  /// Bottom-of-page row, shared by every section. Two entries:
  ///   • Section Skill — navigates to the per-section MCP brief.
  ///   • Export Data   — ShareLink with a JSON snapshot of this section.
  /// Both are conditional: skill only shows if `SectionSkill.byKey[key]`
  /// exists; export only shows if this key is in `exportableSectionKeys`
  /// (resolved against ImportExportService).
  @ViewBuilder
  private var skillAndDataSection: some View {
    Section {
      if SectionSkill.resolve(sectionKey) != nil {
        NavigationLink {
          SectionSkillView(sectionKey: sectionKey)
        } label: {
          Label("Section Skill", systemImage: "sparkles")
        }
      }
      sectionExportRow
    } header: {
      Text("Skill & Data")
    } footer: {
      Text("Section Skill briefs an AI assistant on how to use this section via the Septena MCP. Export downloads every record in this section as JSON.")
    }
  }

  @ViewBuilder
  private var sectionExportRow: some View {
    // Build payload lazily on render. Empty Data → ShareLink still renders
    // but the file will be near-empty; that's the user's signal that this
    // section has no exportable rows yet (or a code path missing in
    // ImportExportService.collectTables).
    let payload = (try? ImportExportService.exportSection(sectionKey)) ?? Data()
    let filename = "septena-\(sectionKey)-\(ImportExportService.todayStamp).json"
    ShareLink(item: ExportFile(data: payload, suggestedName: filename),
              preview: SharePreview(filename, image: Image(systemName: "square.and.arrow.up"))) {
      HStack {
        Label("Export Data", systemImage: "square.and.arrow.up")
          .foregroundStyle(.primary)
        Spacer()
        Text(SectionDetailPane.formatBytes(payload.count))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
  }

  // Local copy of byteSize — ImportExportSettingsPane's helper is private.
  // Cheap; not worth refactoring shared state for one call site.
  private static func formatBytes(_ bytes: Int) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useBytes, .useKB, .useMB]
    f.countStyle = .file
    return f.string(fromByteCount: Int64(bytes))
  }

  @ViewBuilder
  private var identitySection: some View {
    Section {
      HStack(spacing: 12) {
        Text(label).foregroundStyle(.primary)
        Spacer()
        colorSwatchButton
      }
      enabledRow
      showInTodayRow
    } footer: {
      if let m = manifest, !m.shortDescription.isEmpty {
        Text(m.shortDescription)
      }
    }
  }

  /// Trailing-aligned, circular color swatch wrapped in the conic
  /// rainbow ring iOS's system `ColorPicker` well uses — the
  /// unmistakable "tap to change the color" affordance. The current
  /// section color fills the center; a thin gap in the row's background
  /// separates it from the ring so the ring reads as a ring, not a
  /// border. (We keep our own curated palette popover rather than the
  /// system picker, so the ring is hand-rolled.)
  @ViewBuilder
  private var colorSwatchButton: some View {
    Button {
      showingColorPicker.toggle()
    } label: {
      ZStack {
        Circle()
          .fill(AngularGradient(
            gradient: Gradient(colors: [.red, .orange, .yellow, .green,
                                        .cyan, .blue, .purple, .red]),
            center: .center))
        Circle()
          .fill(rowBackgroundColor)
          .padding(2)
        Circle()
          .fill(accent)
          .padding(4)
      }
      .frame(width: 26, height: 26)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Section color")
    .popover(isPresented: $showingColorPicker, arrowEdge: .trailing) {
      PaletteSwatchGrid(selectedHex: server?.color ?? "") { hex in
        updateColor(hex)
        showingColorPicker = false
      }
      .padding(12)
      .presentationCompactAdaptation(.popover)
    }
  }

  /// Per-section opt-out for the Next timeline. Only shown for sections
  /// the manifest marks as `appearsInToday` — others have nothing to
  /// gate, so the toggle would be confusing.
  @ViewBuilder
  private var showInTodayRow: some View {
    if let m = manifest, m.appearsInToday {
      Toggle(isOn: Binding(
        get: { server?.showInToday ?? true },
        set: { setShowInToday($0) }
      )) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Show in Next")
          Text("Include this section's entries in the Next timeline.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func setShowInToday(_ value: Bool) {
    SettingsMirror.setSectionShowInToday(sectionKey,
                                         showInToday: value,
                                         context: modelContext,
                                         engine: ckEngine)
    store.sections = store.sections.map { config in
      config.key == sectionKey
        ? SectionConfig(key: config.key,
                        label: config.label,
                        color: config.color,
                        isEnabled: config.isEnabled,
                        showInToday: value,
                        hasOnboarded: config.hasOnboarded)
        : config
    }
  }

  /// Master enabled toggle. Hidden for `.always` sections (e.g. Tasks).
  /// Disabling hides the section from the dashboard, sidebar, and every
  /// other surface that filters on `isEnabled` — but never deletes data
  /// or the SectionEntity row, so customizations survive a toggle.
  @ViewBuilder
  private var enabledRow: some View {
    if let m = manifest, m.canDisable {
      Toggle(isOn: Binding(
        get: { server?.isEnabled ?? true },
        set: { setEnabled($0) }
      )) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Enabled")
          Text("Hides this section everywhere. Your data and customizations stay.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } else if manifest != nil {
      HStack {
        Text("Always on")
        Spacer()
        Text("Required")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func setEnabled(_ enabled: Bool) {
    SettingsMirror.setSectionEnabled(sectionKey,
                                     enabled: enabled,
                                     context: modelContext,
                                     engine: ckEngine)
    store.sections = store.sections.map { config in
      config.key == sectionKey
        ? SectionConfig(key: config.key,
                        label: config.label,
                        color: config.color,
                        isEnabled: enabled,
                        showInToday: config.showInToday,
                        hasOnboarded: config.hasOnboarded)
        : config
    }
  }

  private func updateColor(_ hex: String) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == sectionKey }
    )
    guard let entity = try? modelContext.fetch(descriptor).first else { return }
    entity.color = hex
    entity.updatedAt = .now
    try? modelContext.save()
    ckEngine.noteSectionChange(id: sectionKey)
    store.sections = store.sections.map { config in
      config.key == sectionKey
        ? SectionConfig(key: config.key,
                        label: config.label,
                        color: hex,
                        isEnabled: config.isEnabled,
                        showInToday: config.showInToday,
                        hasOnboarded: config.hasOnboarded)
        : config
    }
  }

  /// Per-key content. Tasks gets local prefs; the rest pull cached
  /// catalog data from `SettingsStore`. Unknown / un-cataloged keys
  /// fall through to identity-only.
  /// Section-specific content is plugin-driven. Each migrated plugin
  /// returns one or more `Section { ... }` blocks via `detailPaneContent`;
  /// sections without a plugin or without a detail-pane override
  /// render no extra content (identity row + onboarding trigger only).
  @ViewBuilder
  private var sectionSpecific: some View {
    if let view = SectionRegistry.plugin(forKey: sectionKey)?.detailPaneContent() {
      view
    }
  }

  // All per-section detail content now lives in the corresponding
  // plugin's `detailPaneContent()` view. Sections without an override
  // render the identity row + onboarding trigger only. See e.g.
  // CaffeineDetailContent / TasksDetailContent / NutritionDetailContent.
}

// MARK: - Macro tiles editor
//
// Reorderable / toggleable / recolorable list of nutrition macro tiles.
// Persists through `NutritionPrefsWriter.saveTilePrefs` which writes to
// `AppSettings.nutrition.macroTiles` and queues a CloudKit push.
//
// Local @State is the source of truth while the sheet is open — the writer
// fires on every change so other devices see the edit immediately. We don't
// re-sync from `store.serverSettings` while editing; that would cause a row
// to jump back if a CK push round-trips during a drag.

struct MacroTilesEditor: View {
  @Environment(\.modelContext) private var modelContext

  @State private var prefs: [MacroTilePref]

  init(initialPrefs: [MacroTilePref]) {
    _prefs = State(initialValue: initialPrefs)
  }

  var body: some View {
    Section {
      ForEach($prefs) { $pref in
        MacroTileRow(pref: $pref, onChange: persist)
      }
      .onMove { indices, newOffset in
        prefs.move(fromOffsets: indices, toOffset: newOffset)
        persist()
      }
    } header: {
      HStack {
        Text("Macro tiles")
        Spacer()
        Button("Reset") {
          prefs = MacroCatalog.defaultTilePrefs()
          persist()
        }
        .font(.caption)
      }
    } footer: {
      Text("Drag to reorder. Toggle to show or hide a tile on the Nutrition dashboard. Tap a swatch to change its color.")
    }
    // Drag handles are off by default in a Form; flip edit mode on so the user
    // can reorder without having to hunt for an Edit button. iOS-only API.
    #if os(iOS)
    .environment(\.editMode, .constant(.active))
    #endif
  }

  private func persist() {
    NutritionPrefsWriter.saveTilePrefs(
      prefs,
      context: modelContext,
      engine: SeptenaServices.shared.ckEngine)
  }
}

private struct MacroTileRow: View {
  @Binding var pref: MacroTilePref
  var onChange: () -> Void

  var body: some View {
    let macro = MacroCatalog.byID[pref.id]
    HStack(spacing: 12) {
      ColorPicker(selection: colorBinding, supportsOpacity: false) {
        EmptyView()
      }
      .labelsHidden()
      .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 1) {
        Text(macro?.label ?? pref.id)
          .font(.body)
        if let unit = macro?.unit, !unit.isEmpty {
          Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
      }

      Spacer()

      Toggle("", isOn: Binding(
        get: { pref.visible },
        set: { pref.visible = $0; onChange() }
      ))
      .labelsHidden()
    }
  }

  /// Color picker is bound to a `Color`, but the model stores hex. Convert
  /// both ways and fall back to the catalog's default when the user hasn't
  /// overridden the swatch yet.
  private var colorBinding: Binding<Color> {
    Binding(
      get: {
        let hex = pref.colorHex ?? MacroCatalog.byID[pref.id]?.defaultColorHex
        return Color(hexString: hex) ?? .gray
      },
      set: { newColor in
        pref.colorHex = newColor.toHexString()
        onChange()
      }
    )
  }
}

private extension Color {
  /// Best-effort hex string ("#rrggbb"). Falls back to "#888888" if the
  /// underlying CGColor can't be resolved (e.g. system dynamic colors).
  func toHexString() -> String {
    #if canImport(UIKit)
    let ui = UIColor(self)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#888888" }
    let ri = Int(round(r * 255)), gi = Int(round(g * 255)), bi = Int(round(b * 255))
    return String(format: "#%02x%02x%02x", ri, gi, bi)
    #else
    return "#888888"
    #endif
  }
}

/// Tolerant parse of "#rrggbb" hex strings. Falls back to gray for
/// hsl(...) or other formats — the server returns either, but only the
/// hex form decodes natively. A future pass can add hsl() support.
private func parseHexColor(_ s: String) -> Color {
  var hex = s.trimmingCharacters(in: .whitespacesAndNewlines)
  if hex.hasPrefix("#") { hex.removeFirst() }
  guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return .gray }
  let r = Double((v >> 16) & 0xFF) / 255
  let g = Double((v >>  8) & 0xFF) / 255
  let b = Double( v        & 0xFF) / 255
  return Color(red: r, green: g, blue: b)
}

// MARK: - Integrations
//
// Native iOS access states for the frameworks Septena reaches outside the
// FastAPI proxy: Reminders + Calendar (EventKit), Apple Health (HealthKit),
// and Photos (PhotoKit). The Reminders row pushes to a detail screen with
// source-list picker + auto-import controls when access is granted; the
// others push to a detail screen showing access state and a grant/fix path.

struct IntegrationsSettingsPane: View {
  @State private var remindersBridge = RemindersBridge.shared
  @State private var calendarBridge = CalendarBridge.shared
  @State private var healthBridge = HealthKitBridge.shared
  @State private var ouraProvider = OuraProvider.shared
  @State private var withingsProvider = WithingsProvider.shared
  @State private var photosBridge = PhotosBridge.shared
  @State private var claudeProvider = ClaudeGatewayProvider.shared
  var body: some View {
    Form {
      Section {
        NavigationLink {
          RemindersInboxDetail()
            .navigationTitle("Reminders")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Reminders",
                   systemImage: "checklist",
                   state: remindersAccessLabel,
                   isGranted: remindersBridge.access == .granted)
        }

        NavigationLink {
          CalendarDetail()
            .navigationTitle("Calendar")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Calendar",
                   systemImage: "calendar",
                   state: calendarAccessLabel,
                   isGranted: calendarBridge.access == .granted)
        }

        NavigationLink {
          AppleHealthDetail()
            .navigationTitle("Apple Health")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Apple Health",
                   systemImage: "heart.text.square",
                   state: healthAccessLabel,
                   isGranted: healthBridge.access == .granted)
        }

        // Photos — used to attach thumbnails to nutrition (meal) entries.
        // Access is requested lazily by the picker too, but surfacing it
        // here gives denied users a fix path (and a way to grant up front).
        NavigationLink {
          PhotosDetail()
            .navigationTitle("Photos")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Photos",
                   systemImage: "photo",
                   state: photosAccessLabel,
                   isGranted: photosBridge.access == .granted)
        }

        // Siri & Shortcuts — Apple system integration; grouped here with
        // the other Apple ones rather than as a top-level Settings row.
        NavigationLink {
          SiriShortcutsSettingsPane()
            .navigationTitle("Siri & Shortcuts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          Label("Siri & Shortcuts", systemImage: "mic")
            .foregroundStyle(.primary)
        }

      } header: {
        Text("Apple")
      } footer: {
        Text("Grant access here, or manage permissions in iOS Settings → Privacy.")
      }

      Section {
        // Oura — direct iOS client (Personal Access Token). Replaces the
        // old FastAPI proxy at /api/health/oura.
        NavigationLink {
          OuraIntegrationDetail()
            .navigationTitle("Oura")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Oura",
                   systemImage: "circle.circle",
                   state: ouraProvider.hasToken ? "Connected" : "Grant",
                   isGranted: ouraProvider.hasToken)
        }

        // Withings — direct iOS client (OAuth2). Replaces the old
        // FastAPI proxy at /api/health/withings.
        NavigationLink {
          WithingsIntegrationDetail()
            .navigationTitle("Withings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          stateRow(title: "Withings",
                   systemImage: "scalemass",
                   state: withingsProvider.hasTokens ? "Connected" : "Connect",
                   isGranted: withingsProvider.hasTokens)
        }

      } header: {
        Text("Services")
      }

      // Claude — keeps the Septena MCP gateway supplied with a live
      // CloudKit token so Claude can read/write your data without you
      // re-authorizing every few hours. The gateway stores only the
      // rotating token, never your data.
      Section {
        NavigationLink {
          ClaudeGatewayDetail()
            .navigationTitle("Claude")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
          HStack {
            Label {
              Text("Claude")
            } icon: {
              Image("ClaudeMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
            }
            .foregroundStyle(.primary)
            Spacer()
            Text(claudeProvider.isEnabled ? "Connected" : "Connect")
              .font(.subheadline)
              .foregroundStyle(claudeProvider.isEnabled ? Color.green : .secondary)
          }
        }
      } footer: {
        Text("Let Claude read and write your Septena data at mcp.septena.app.")
      }
    }
    .formStyle(.grouped)
  }

  private func stateRow(title: String,
                        systemImage: String,
                        state: String,
                        isGranted: Bool) -> some View {
    HStack {
      Label(title, systemImage: systemImage)
        .foregroundStyle(.primary)
      Spacer()
      Text(state)
        .font(.subheadline)
        .foregroundStyle(isGranted ? Color.green : .secondary)
    }
  }

  @ViewBuilder
  private func grantButton(title: String,
                           systemImage: String,
                           state: String,
                           isGranted: Bool,
                           canRequest: Bool,
                           onTap: @escaping () -> Void) -> some View {
    if canRequest {
      Button(action: onTap) {
        stateRow(title: title, systemImage: systemImage, state: state, isGranted: isGranted)
      }
      .buttonStyle(.plain)
    } else {
      stateRow(title: title, systemImage: systemImage, state: state, isGranted: isGranted)
    }
  }

  private var remindersAccessLabel: String {
    switch remindersBridge.access {
    case .granted:       return "Granted"
    case .writeOnly:     return "Write-only"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }

  private var calendarAccessLabel: String {
    switch calendarBridge.access {
    case .granted:       return "Granted"
    case .writeOnly:     return "Write-only"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }

  private var healthAccessLabel: String {
    guard healthBridge.isAvailable else { return "Not available" }
    switch healthBridge.access {
    case .granted:       return "Granted"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }

  private var photosAccessLabel: String {
    switch photosBridge.access {
    case .granted:       return "Granted"
    case .denied:        return "Denied"
    case .notDetermined: return "Grant"
    }
  }
}

// MARK: - Apple Health Detail

/// Full-screen integration settings for Apple Health. Shown after tapping the
/// Apple Health row in Integrations. Handles the initial grant request and
/// per-section write toggles — each toggle syncs through CloudKit so the
/// user's preference follows them across devices.
struct AppleHealthDetail: View {
  @Environment(\.modelContext)    private var modelContext
  @Environment(CKEngine.self)     private var ckEngine
  @Environment(SettingsStore.self) private var store
  @State private var healthBridge = HealthKitBridge.shared

  private var rows: [(label: String, icon: String, kind: HealthKitBridge.WritableKind)] {
    [
      ("Mood",                  "face.smiling",                          .mood),
      ("Caffeine",              "cup.and.saucer",                        .caffeine),
      ("Nutrition & Hydration", "fork.knife",                            .nutrition),
    ]
  }

  /// True when at least one writable category was denied in the permission
  /// sheet — drives the "some categories are off" advisory.
  private var anyDenied: Bool {
    rows.contains { healthBridge.shareStatus($0.kind) == .denied }
  }

  var body: some View {
    Form {
      // ── Connection ─────────────────────────────────────────────────────
      Section {
        if !healthBridge.isAvailable {
          Label("Apple Health is not available on this device.",
                systemImage: "heart.slash")
            .foregroundStyle(.secondary)
        } else if healthBridge.hasRequestedWrite {
          Label("Connected", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          Button {
            Task { _ = await healthBridge.requestAccess() }
          } label: {
            Label("Connect Apple Health", systemImage: "heart.text.square")
          }
        }
      } footer: {
        Text("Septena writes your logged data to Apple Health so it appears alongside data from your other apps and devices.")
      }

      // ── Write Toggles (shown once the user has been through the sheet) ───
      if healthBridge.isAvailable && healthBridge.hasRequestedWrite {
        Section {
          ForEach(rows, id: \.kind) { row in
            toggleRow(row.label, row.icon, row.kind)
          }
        } header: {
          Text("Write to Health")
        } footer: {
          if anyDenied {
            Text("Some categories are turned off in Apple Health. To allow them, open Health → Profile → Apps → Septena. New entries are sent going forward — existing ones aren't back-filled.")
          } else {
            Text("New entries you log in Septena will be sent to Apple Health. Existing entries are not back-filled.")
          }
        }
      }
    }
    .navigationTitle("Apple Health")
    // Re-request on every visit so any write types added since the user's
    // last authorization are picked up immediately. HealthKit only shows a
    // sheet for types not yet resolved — no-ops if everything is already
    // decided. Always refresh status afterward so denials render correctly.
    .task {
      if healthBridge.isAvailable {
        _ = await healthBridge.requestAccess()
        healthBridge.refreshShareStatuses()
      }
    }
  }

  /// One row in the write-toggles section. Enabled when the category is
  /// authorized; when denied, the toggle is disabled and a caption explains
  /// that Apple Health is blocking it (so the failure is never silent).
  @ViewBuilder
  private func toggleRow(_ title: String, _ icon: String,
                         _ kind: HealthKitBridge.WritableKind) -> some View {
    let status = healthBridge.shareStatus(kind)
    if status != .unavailable {
      Toggle(isOn: syncBinding(kind)) {
        VStack(alignment: .leading, spacing: 2) {
          Label(title, systemImage: icon)
          if status == .denied {
            Text("Turned off in Apple Health")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .disabled(status != .authorized)
    }
  }

  private func keyPath(for kind: HealthKitBridge.WritableKind) -> WritableKeyPath<HKSyncSettings, Bool> {
    switch kind {
    case .mood:      return \.mood
    case .caffeine:  return \.caffeine
    case .nutrition: return \.nutrition
    }
  }

  /// Binding that reads/writes one field of `HKSyncSettings` through the
  /// CloudKit-backed `AppSettings`. Falls back to `true` (all-on default)
  /// when no settings are stored yet.
  private func syncBinding(_ kind: HealthKitBridge.WritableKind) -> Binding<Bool> {
    let keyPath = keyPath(for: kind)
    return Binding {
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

// MARK: - Reminders → Inbox detail
//
// Reached from Integrations → Reminders. Permission grant + source list
// + auto-import all live here, since this is where the user actually
// configures the Reminders → Septena Inbox bridge.

private struct RemindersInboxDetail: View {
  @State private var bridge = RemindersBridge.shared
  @State private var access: RemindersBridge.Access = .notDetermined
  @State private var lists: [EKCalendar] = []
  @State private var selectedID: String?

  var body: some View {
    Form {
      Section {
        Text("Pick a Reminders list. Its pending items show in your Inbox; tap to import (originals are removed from Reminders).")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      switch access {
      case .notDetermined:
        Section {
          Button("Grant Access to Reminders") {
            Task {
              _ = await bridge.requestAccess()
              refresh()
            }
          }
        }
      case .denied, .writeOnly:
        Section {
          Text(access == .writeOnly
               ? "Septena has write-only access. Enable Full Access in Settings → Privacy → Reminders."
               : "Reminders access is denied. Enable it in Settings → Privacy → Reminders.")
            .font(.callout)
        }
      case .granted:
        Section("Source list") {
          pickerRow(title: "None", tint: nil, id: nil)
          ForEach(lists, id: \.calendarIdentifier) { cal in
            pickerRow(title: cal.title,
                      tint: Color(cgColor: cal.cgColor),
                      id: cal.calendarIdentifier)
          }
        }

        Section {
          Toggle("Auto-import new reminders", isOn: Binding(
            get: { bridge.autoImport },
            set: { bridge.autoImport = $0 }
          ))
          .disabled(bridge.sourceListID == nil)
        } footer: {
          Text("When on, pending items in the source list import automatically and are removed from Reminders. Runs on app launch and whenever Reminders changes.")
        }

        if !bridge.recentImports.isEmpty {
          Section("Recent auto-imports") {
            ForEach(bridge.recentImports.prefix(10)) { entry in
              autoImportRow(entry)
            }
            Button("Clear log", role: .destructive) {
              bridge.recentImports = []
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
  }

  @ViewBuilder
  private func autoImportRow(_ entry: AutoImportLogEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(entry.succeeded ? Color.green : Color.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .foregroundStyle(.primary)
          .lineLimit(2)
        HStack(spacing: 6) {
          Text(relativeDate(entry.importedAt))
            .font(.caption)
            .foregroundStyle(.secondary)
          if let err = entry.error {
            Text("· \(err)")
              .font(.caption)
              .foregroundStyle(.orange)
              .lineLimit(1)
          }
        }
      }
      Spacer()
    }
  }

  private func relativeDate(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
  }

  @ViewBuilder
  private func pickerRow(title: String, tint: Color?, id: String?) -> some View {
    Button {
      bridge.sourceListID = id
      selectedID = id
    } label: {
      HStack(spacing: 10) {
        if let tint {
          Circle().fill(tint).frame(width: 10, height: 10)
        } else {
          Circle().stroke(.secondary, lineWidth: 1).frame(width: 10, height: 10)
        }
        Text(title).foregroundStyle(.primary)
        Spacer()
        if selectedID == id {
          Image(systemName: "checkmark")
            .scaledFont(size: 13, weight: .semibold)
            .foregroundStyle(.tint)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func refresh() {
    access = bridge.access
    if access == .granted {
      lists = bridge.reminderLists()
      selectedID = bridge.sourceListID
    }
  }
}

// MARK: - Calendar detail
//
// Reached from Integrations → Calendar. Lists every event calendar EventKit
// exposes and lets the user toggle visibility per source. Hidden calendars
// drop out of CalendarBridge's fetch helpers, so both the day timeline and
// the Next page stop showing those events.

private struct CalendarDetail: View {
  @State private var bridge = CalendarBridge.shared
  @State private var access: CalendarBridge.Access = .notDetermined
  @State private var calendars: [EKCalendar] = []

  var body: some View {
    Form {
      Section {
        Text("Pick which calendars contribute events to your day timeline and Next page. Hidden calendars stay untouched in iOS Calendar.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      switch access {
      case .notDetermined:
        Section {
          Button("Grant Access to Calendar") {
            Task {
              _ = await bridge.requestAccess()
              refresh()
            }
          }
        }
      case .denied, .writeOnly:
        Section {
          Text(access == .writeOnly
               ? "Septena has write-only access. Enable Full Access in Settings → Privacy → Calendars."
               : "Calendar access is denied. Enable it in Settings → Privacy → Calendars.")
            .font(.callout)
        }
      case .granted:
        if calendars.isEmpty {
          Section {
            Text("No calendars found.")
              .foregroundStyle(.secondary)
          }
        } else {
          Section("Calendars") {
            ForEach(calendars, id: \.calendarIdentifier) { cal in
              calendarRow(cal)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
  }

  private func calendarRow(_ cal: EKCalendar) -> some View {
    Toggle(isOn: Binding(
      get: { !bridge.isHidden(cal) },
      set: { bridge.setHidden(!$0, for: cal) }
    )) {
      HStack(spacing: 10) {
        Circle()
          .fill(Color(cgColor: cal.cgColor))
          .frame(width: 10, height: 10)
        VStack(alignment: .leading, spacing: 2) {
          Text(cal.title)
            .foregroundStyle(.primary)
          if let source = cal.source?.title, !source.isEmpty {
            Text(source)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func refresh() {
    access = bridge.access
    if access == .granted {
      calendars = bridge.allCalendars()
    }
  }
}

// MARK: - Photos Detail
//
// Photo access is used to attach thumbnails to nutrition (meal) entries.
// When access is denied, meal thumbnails silently fall back to a
// placeholder — this screen explains why and points to iOS Settings.
private struct PhotosDetail: View {
  @State private var bridge = PhotosBridge.shared
  @State private var access: PhotosBridge.Access = .notDetermined

  var body: some View {
    Form {
      Section {
        Text("Septena attaches photos to your meal entries and shows their thumbnails in your nutrition log. Photos stay on your device.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      switch access {
      case .notDetermined:
        Section {
          Button("Grant Access to Photos") {
            Task {
              _ = await bridge.requestAccess()
              refresh()
            }
          }
        }
      case .denied:
        Section {
          Text("Photo access is denied. Enable it in Settings → Privacy → Photos. Meal thumbnails won't show until then.")
            .font(.callout)
        }
      case .granted:
        Section {
          Label("Connected", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
  }

  private func refresh() {
    access = bridge.access
  }
}

// Oura → Personal Access Token entry. The user pastes a token from
// cloud.ouraring.com/personal-access-tokens; OuraProvider stores it in
// Keychain. Test button does a 1-day fetchHistory round-trip so the
// user gets immediate confirmation the token works.
private struct OuraIntegrationDetail: View {
  @State private var provider = OuraProvider.shared
  @State private var draft: String = ""
  @State private var testing = false
  @State private var lastResult: String? = nil

  var body: some View {
    Form {
      Section {
        SecureField("Personal Access Token", text: $draft)
          #if os(iOS)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          #endif
        HStack {
          Button("Save") {
            provider.setToken(draft)
            draft = ""
            lastResult = nil
            // Kick off a full one-year backfill so the user's history
            // lands in SwiftData + CloudKit immediately, not after the
            // next dashboard visit.
            Task { await runBackfill() }
          }
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Spacer()
          if provider.hasToken {
            Button("Remove", role: .destructive) {
              provider.clearToken()
              lastResult = nil
            }
          }
        }
      } header: {
        Text("Token")
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text("Create a Personal Access Token at cloud.ouraring.com/personal-access-tokens, then paste it here. Tokens stay on this device (Keychain) and are never sent to any Septena server.")
          Link("Open Oura tokens page",
               destination: URL(string: "https://cloud.ouraring.com/personal-access-tokens")!)
            .font(.callout)
        }
      }

      Section {
        HStack {
          Label("Status", systemImage: "circle.circle")
          Spacer()
          Text(provider.hasToken ? "Connected" : "Not configured")
            .foregroundStyle(provider.hasToken ? .green : .secondary)
        }
        Button {
          Task { await runTest() }
        } label: {
          HStack {
            Label("Test connection", systemImage: "checkmark.seal")
            Spacer()
            if testing { ProgressView().controlSize(.small) }
          }
        }
        .disabled(!provider.hasToken || testing)
        if let lastResult {
          Text(lastResult)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func runTest() async {
    testing = true
    defer { testing = false }
    do {
      let rows = try await provider.fetchHistory(days: 7)
      let withScore = rows.compactMap(\.sleepScore).count
      lastResult = "OK — \(rows.count) days fetched, \(withScore) with a sleep score."
    } catch {
      lastResult = "Failed: \(error.localizedDescription)"
    }
  }

  private func runBackfill() async {
    testing = true
    defer { testing = false }
    lastResult = "Backfilling last 365 days…"
    do {
      let rows = try await provider.fetchHistory(days: 365)
      let withScore = rows.compactMap(\.sleepScore).count
      lastResult = "Backfill complete — \(rows.count) nights, \(withScore) with a sleep score. Syncing to iCloud."
    } catch {
      lastResult = "Backfill failed: \(error.localizedDescription)"
    }
  }
}

// MARK: - Claude Gateway Detail

/// Connect / status / disconnect for the Septena MCP gateway. "Connect"
/// mints a CloudKit Web Services token and pushes it to mcp.septena.app;
/// the app then re-mints on foreground so Claude keeps working without
/// the user re-authorizing every ~8h. The gateway holds only the rotating
/// token, never the user's data.
private struct ClaudeGatewayDetail: View {
  @State private var provider = ClaudeGatewayProvider.shared

  private var lastRefreshLabel: String {
    guard let at = provider.lastRefreshAt else { return "Never" }
    return at.formatted(.relative(presentation: .named))
  }

  var body: some View {
    Form {
      Section {
        if provider.isEnabled {
          Button("Disconnect", role: .destructive) {
            provider.disconnect()
          }
        } else {
          Button("Connect Claude") {
            Task { await provider.connect() }
          }
        }
      } footer: {
        Text("Connecting lets Claude (at claude.ai or in the Claude app) read and write your Septena data via the MCP connector. Your data stays in iCloud — the gateway only relays a short-lived access token, which this app refreshes automatically. Add the connector in Claude using mcp.septena.app.")
      }

      if provider.isEnabled {
        Section {
          HStack {
            Label("Status", systemImage: "sparkles")
            Spacer()
            Text(provider.needsReauth ? "Reconnect needed" : (provider.lastError == nil ? "Connected" : "Needs attention"))
              .foregroundStyle(provider.needsReauth || provider.lastError != nil ? .orange : .green)
          }
          HStack {
            Label("Last authenticated", systemImage: "clock.arrow.circlepath")
            Spacer()
            Text(lastRefreshLabel).foregroundStyle(.secondary)
          }
          Button {
            Task { await provider.refreshNow() }
          } label: {
            HStack {
              Label("Reauthenticate", systemImage: "lock.rotation")
              Spacer()
              if provider.isRefreshing { ProgressView().controlSize(.small) }
            }
          }
          .disabled(provider.isRefreshing)
          if let err = provider.lastError {
            Text(err)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Connection")
        }
      }
    }
    .formStyle(.grouped)
  }
}

// Withings → OAuth2 connect / backfill / disconnect. "Connect" opens
// ASWebAuthenticationSession against account.withings.com; the returned
// code is exchanged for access + refresh tokens stored in Keychain.
// Backfill pulls the last 365 days into SwiftData + CloudKit so other
// devices pick them up via CKSyncEngine.
private struct WithingsIntegrationDetail: View {
  @State private var provider = WithingsProvider.shared
  @State private var working = false
  @State private var lastResult: String? = nil

  var body: some View {
    Form {
      if !provider.isConfigured {
        Section {
          Text("Withings app credentials are not configured.")
            .foregroundStyle(.secondary)
        } footer: {
          Text("Register a Withings dev app at developer.withings.com (Public Health Data API), then paste your client_id and client_secret into WithingsAppCredentials in WithingsProvider.swift. The redirect URI should be septena://withings/callback.")
        }
      }

      Section {
        HStack {
          Label("Status", systemImage: "scalemass")
          Spacer()
          Text(provider.hasTokens ? "Connected" : "Not connected")
            .foregroundStyle(provider.hasTokens ? .green : .secondary)
        }

        if provider.hasTokens {
          Button {
            Task { await runBackfill() }
          } label: {
            HStack {
              Label("Backfill last 365 days", systemImage: "arrow.clockwise")
              Spacer()
              if working { ProgressView().controlSize(.small) }
            }
          }
          .disabled(working)
          Button("Disconnect", role: .destructive) {
            provider.disconnect()
            lastResult = nil
          }
          .disabled(working)
        } else {
          Button {
            Task { await runConnect() }
          } label: {
            HStack {
              Label("Connect Withings", systemImage: "link")
              Spacer()
              if working { ProgressView().controlSize(.small) }
            }
          }
          .disabled(!provider.isConfigured || working)
        }

        if let lastResult {
          Text(lastResult)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } footer: {
        Text("Tokens live in this device's Keychain and never leave it. Weigh-ins sync to your other devices via iCloud.")
      }
    }
    .formStyle(.grouped)
  }

  private func runConnect() async {
    working = true
    defer { working = false }
    lastResult = "Opening Withings sign-in…"
    do {
      try await provider.connect()
      lastResult = "Connected. Backfilling last 365 days…"
      let rows = try await provider.fetchHistory(days: 365)
      lastResult = "Connected — \(rows.count) days fetched. Syncing to iCloud."
    } catch {
      lastResult = "Failed: \(error.localizedDescription)"
    }
  }

  private func runBackfill() async {
    working = true
    defer { working = false }
    lastResult = "Backfilling last 365 days…"
    do {
      let rows = try await provider.fetchHistory(days: 365)
      lastResult = "Backfill complete — \(rows.count) days, syncing to iCloud."
    } catch {
      lastResult = "Backfill failed: \(error.localizedDescription)"
    }
  }
}

// MARK: - About

struct AboutSettingsPane: View {
  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }
  private var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
  }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .center, spacing: 14) {
          AppIconPreview(option: .default, size: 72)
            .padding(.top, 4)
          VStack(spacing: 4) {
            Text("Septena")
              .font(.septenaSectionTitle)
            Text("One app for several corners of personal health")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          Text("Version \(version) (\(build))")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
      }

      Section {
        Text("Track training, nutrition, habits, sleep, supplements, caffeine, chores, and more — all in one place, synced across your devices with iCloud.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section("Links") {
        outboundLink("Website", destination: "https://septena.app", icon: "globe")
        outboundLink("Feedback", destination: "mailto:mz@envisioning.com", icon: "envelope")
        outboundLink("License", destination: "https://opensource.org/licenses/MIT", icon: "doc.text")
      }

      Section {
        infoRow("Platform", platformLabel)
        infoRow("Version", version)
        infoRow("Build", build)
      }
    }
    .formStyle(.grouped)
  }

  private var platformLabel: String {
    #if os(macOS)
    return "macOS"
    #else
    return "iOS · iPadOS"
    #endif
  }

  private func outboundLink(_ title: String, destination: String, icon: String) -> some View {
    Link(destination: URL(string: destination)!) {
      HStack {
        Label(title, systemImage: icon)
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "arrow.up.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private func infoRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .font(.callout.monospacedDigit())
    }
  }
}

// MARK: - Shared pane helpers

private func row(_ label: String, _ value: String) -> some View {
  HStack {
    Text(label)
    Spacer()
    Text(value)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.trailing)
  }
}

// MARK: - Import & Export
//
// One pane for getting data in and out of Septena. Export produces a
// stable JSON envelope per section (and an "Everything" bundle); import
// parses the same envelope, validates it against the local schema, and
// previews per-table counts before any writes land. The JSON format is
// designed to round-trip — anything exported here is a valid import.
//
// Envelope shape (stable, versioned):
//   {
//     "septena_export_version": 1,
//     "section": "<section key>" | "all",
//     "exported_at": "<ISO-8601>",
//     "app_version": "<CFBundleShortVersionString> (<CFBundleVersion>)",
//     "tables": {
//        "<table_name>": [ { ...record... }, ... ],
//        ...
//     }
//   }
//
// Sections that aren't backed by exportable local entities (e.g.
// `activity`, `sleep`) are skipped — Import/Export only lists what it
// can actually produce.

import UniformTypeIdentifiers

// MARK: - Skills

/// Top-level Skills page. Lists every section that has an MCP skill brief,
/// plus a "Connection" row at top showing the universal preamble. Each row
/// navigates to a `SectionSkillView`.
///
/// Skills are static content (defined in `SectionSkill.all`); this pane
/// just renders them. To add a section, edit `SectionSkill.swift`.
struct SkillsSettingsPane: View {
  @Environment(SettingsStore.self) private var store

  /// Show section skills in the user's actual sidebar order when possible,
  /// falling back to the catalog order in `SectionSkill.all`. Skills for
  /// sections the user doesn't have installed are still shown — they're
  /// informational, and someone evaluating which sections to enable
  /// benefits from previewing the skill content.
  private var orderedKeys: [String] {
    let order = store.serverSettings?.sectionOrder ?? []
    let known = SectionSkill.allKnownKeys
    let head  = order.filter { known.contains($0) }
    let rest  = known.subtracting(head).sorted()
    return head + rest
  }

  var body: some View {
    Form {
      Section {
        NavigationLink {
          SkillPreambleView()
        } label: {
          Label("Connection & conventions", systemImage: "antenna.radiowaves.left.and.right")
        }
      } header: {
        Text("MCP")
      } footer: {
        Text("Connect Claude or another MCP client to mcp.septena.app to read and write your Septena data. The brief below is what the model needs to know to use the connection well.")
      }

      Section {
        ForEach(orderedKeys, id: \.self) { key in
          if let skill = SectionSkill.resolve(key) {
            NavigationLink {
              SectionSkillView(sectionKey: key)
            } label: {
              skillRowLabel(for: key, skill: skill)
            }
          }
        }
      } header: {
        Text("Section skills")
      } footer: {
        Text("Each brief teaches a model how to use one section through the MCP — tools available, conventions, examples.")
      }

      Section {
        Button {
          SkillCopy.copy(SectionRegistry.fullSkillMarkdown())
          showCopiedToast = true
        } label: {
          Label("Copy MCP gateway brief", systemImage: "doc.on.doc")
        }
      } header: {
        Text("Gateway sync")
      } footer: {
        Text("Copies the preamble + every section's brief as one Markdown document. Paste into septena-mcp-gateway/skill.md so the LLM-facing catalog can't drift from the plugin definitions in this app.")
      }
    }
    .formStyle(.grouped)
    .overlay(alignment: .bottom) {
      if showCopiedToast {
        Text("Copied")
          .font(.callout)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(.thinMaterial, in: Capsule())
          .padding(.bottom, 24)
          .transition(.opacity)
          .task {
            try? await Task.sleep(for: .seconds(1.4))
            showCopiedToast = false
          }
      }
    }
    .animation(.snappy, value: showCopiedToast)
  }

  @State private var showCopiedToast = false

  @ViewBuilder
  private func skillRowLabel(for key: String, skill: SectionSkill) -> some View {
    let entry = store.sections.first(where: { $0.key == key })
    let label = entry?.label
      ?? SectionManifest.byKey[key]?.defaultLabel
      ?? key.capitalized
    let color = parseHexColor(entry?.color ?? "")
    HStack(spacing: 12) {
      ColoredGlyph(icon: skillSectionIcon(key: key), color: color, size: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(label).foregroundStyle(.primary)
        Text(skill.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private func skillSectionIcon(key: String) -> String {
    return SectionManifest.byKey[key]?.iconSymbol ?? "circle.fill"
  }
}

/// Per-section skill detail. Reused by both the Skills top-level pane
/// (via SkillsSettingsPane) and the bottom of each section's settings
/// page (via SectionDetailPane.skillAndDataSection).
struct SectionSkillView: View {
  @Environment(SettingsStore.self) private var store
  let sectionKey: String

  private var skill: SectionSkill? { SectionSkill.resolve(sectionKey) }
  private var label: String {
    store.sections.first(where: { $0.key == sectionKey })?.label
      ?? SectionManifest.byKey[sectionKey]?.defaultLabel
      ?? sectionKey.capitalized
  }

  var body: some View {
    Form {
      if let skill {
        Section {
          Text(skill.summary)
            .font(.callout)
            .foregroundStyle(.primary)
        } header: {
          Text("\(label) skill")
        }

        Section("Tools") {
          ForEach(skill.tools, id: \.name) { tool in
            VStack(alignment: .leading, spacing: 3) {
              Text(tool.name)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
              Text(tool.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
              if let inputs = tool.inputs {
                Text(inputs)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
            .padding(.vertical, 3)
          }
        }

        Section("Conventions & examples") {
          Text(.init(skill.body))
            .font(.callout)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
        }

        Section {
          Button {
            SkillCopy.copy(skill.fullMarkdown)
          } label: {
            Label("Copy full skill", systemImage: "doc.on.doc")
          }
          ShareLink(item: skill.fullMarkdown) {
            Label("Share…", systemImage: "square.and.arrow.up")
          }
        } footer: {
          Text("The copied text includes the connection preamble + this section's brief — paste it into an MCP client's system prompt or a Claude conversation to teach it how to use the section.")
        }
      } else {
        Section {
          Label("No skill yet", systemImage: "questionmark.circle")
            .foregroundStyle(.secondary)
        } footer: {
          Text("This section doesn't yet have MCP tools. A skill will appear here when it does.")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("\(label) skill")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

/// Connection preamble shown above all section skills. Static content
/// pulled from `SectionSkill.preamble`.
struct SkillPreambleView: View {
  var body: some View {
    Form {
      Section {
        Text(.init(SectionSkill.preamble))
          .font(.callout)
          .textSelection(.enabled)
      }
      Section {
        Button {
          SkillCopy.copy(SectionSkill.preamble)
        } label: {
          Label("Copy preamble", systemImage: "doc.on.doc")
        }
        ShareLink(item: SectionSkill.preamble) {
          Label("Share…", systemImage: "square.and.arrow.up")
        }
      } footer: {
        Text("Universal conventions every section relies on. Each section skill below extends this.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Connection & conventions")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

/// Tiny cross-platform pasteboard wrapper. Lives at file scope so all
/// skill views (and the per-section detail pane footer) share one impl.
private enum SkillCopy {
  static func copy(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
  }
}

private let importExportEnvelopeVersion = 1

/// Sections the exporter understands today. Order matches the Settings
/// sidebar.
private let exportableSectionKeys: [String] = [
  "tasks", "training", "nutrition", "habits", "chores",
  "supplements", "groceries", "caffeine", "cannabis", "gut",
]

struct ImportExportSettingsPane: View {
  @Environment(SettingsStore.self) private var store
  @Environment(CKEngine.self) private var ckEngine
  @State private var exportError: String? = nil
  @State private var importDoc: ImportExportEnvelope? = nil
  @State private var importMessage: String? = nil
  @State private var importIsError: Bool = false
  @State private var showingPaste = false
  @State private var showingFilePicker = false
  @State private var pasteBuffer: String = ""
  @State private var nutritionRepairState: RepairState = .idle

  enum RepairState: Equatable {
    case idle
    case running
    case success(entryCount: Int, summaryCount: Int)
    case failure(message: String)
  }

  var body: some View {
    Form {
      exportSection
      importSection
      repairSection
      schemaPromptsSection
      formatSection
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showingPaste) {
      pasteSheet
    }
    .fileImporter(isPresented: $showingFilePicker,
                  allowedContentTypes: [.json],
                  allowsMultipleSelection: false) { result in
      handleFileImport(result)
    }
  }

  // MARK: Export

  @ViewBuilder
  private var exportSection: some View {
    Section {
      exportRow(label: "Everything",
                systemImage: "tray.full",
                fileBase: "septena-export") {
        try ImportExportService.exportAll()
      }
      ForEach(exportableSectionKeys, id: \.self) { key in
        exportRow(label: sectionLabel(for: key),
                  systemImage: sectionGlyph(for: key),
                  fileBase: "septena-\(key)") {
          try ImportExportService.exportSection(key)
        }
      }
    } header: {
      Text("Export")
    } footer: {
      Text("JSON dumps of every record in the local store. Use these as a backup, to move to another device, or to feed into other tools.")
    }
  }

  @ViewBuilder
  private func exportRow(label: String,
                         systemImage: String,
                         fileBase: String,
                         build: @escaping () throws -> Data) -> some View {
    let payload = (try? build()) ?? Data()
    let filename = "\(fileBase)-\(ImportExportService.todayStamp).json"
    ShareLink(item: ExportFile(data: payload, suggestedName: filename),
              preview: SharePreview(filename, image: Image(systemName: systemImage))) {
      HStack {
        Label(label, systemImage: systemImage)
          .foregroundStyle(.primary)
        Spacer()
        Text(byteSize(payload.count))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Image(systemName: "square.and.arrow.up")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Import

  @ViewBuilder
  private var importSection: some View {
    Section {
      Button {
        showingFilePicker = true
      } label: {
        Label("Choose JSON file…", systemImage: "doc.badge.plus")
      }
      Button {
        pasteBuffer = ""
        importMessage = nil
        importIsError = false
        showingPaste = true
      } label: {
        Label("Paste JSON…", systemImage: "doc.on.clipboard")
      }

      if let doc = importDoc {
        importPreview(doc)
      } else if let msg = importMessage {
        Label(msg, systemImage: importIsError ? "exclamationmark.triangle" : "checkmark.circle")
          .foregroundStyle(importIsError ? .red : .green)
          .font(.callout)
      }
    } header: {
      Text("Import")
    } footer: {
      Text("Provide JSON in the Septena export format. Records are merged by id — existing rows update in place, new rows are inserted. Definition tables (habits, supplements, chores, beans, grocery items) apply now; event/log tables preview only in this build.")
    }
  }

  @ViewBuilder
  private func importPreview(_ doc: ImportExportEnvelope) -> some View {
    let sectionName = doc.section == "all"
      ? "Everything"
      : sectionLabel(for: doc.section)
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Loaded — \(sectionName)", systemImage: "checkmark.seal")
          .foregroundStyle(.green)
        Spacer()
        Button("Clear", role: .destructive) {
          importDoc = nil
          importMessage = nil
        }
        .buttonStyle(.borderless)
        .font(.caption)
      }
      if let ts = doc.exportedAt {
        Text("Exported \(ts)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Divider()
      ForEach(doc.tables.keys.sorted(), id: \.self) { table in
        HStack {
          Text(table)
            .font(.callout.monospaced())
          Spacer()
          Text("\(doc.tables[table]?.count ?? 0) rows")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      Divider()
      HStack {
        Spacer()
        Button {
          applyImport(doc)
        } label: {
          Label("Apply", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var pasteSheet: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 8) {
        Text("Paste a Septena JSON export below.")
          .font(.callout)
          .foregroundStyle(.secondary)
        TextEditor(text: $pasteBuffer)
          .font(.body.monospaced())
          .frame(minHeight: 240)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(.secondary.opacity(0.2))
          )
        if importIsError, let msg = importMessage {
          Text(msg).font(.callout).foregroundStyle(.red)
        }
      }
      .padding()
      .navigationTitle("Paste JSON")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { showingPaste = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Load") {
            handlePaste(pasteBuffer)
          }
          .disabled(pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }

  // MARK: Schema prompts
  //
  // One copyable LLM prompt per section. Paste the prompt into Claude /
  // ChatGPT / etc. along with whatever source data you have (CSV, journal
  // entries, freeform notes) and the model produces a JSON envelope that
  // round-trips through this importer. The schema is generated from the
  // same field list the exporter uses, so the prompt is always in sync.

  // MARK: Repair

  // One-shot re-pull for record types whose history may be missing locally
  // because CKSyncEngine's incremental fetch token advanced past records
  // the device couldn't yet decode (e.g. nutrition records arrived while
  // this Mac was running a build that didn't have the
  // `case NutritionEntryCloudKitSchema.recordType` arm in
  // `applyFetchedRecord`). `fetchAllRecords` does a fresh nil-token zone
  // replay so historical records are redelivered regardless of the engine
  // checkpoint.
  @ViewBuilder
  private var repairSection: some View {
    Section {
      Button {
        Task { await repairNutritionFromCloudKit() }
      } label: {
        HStack {
          Label("Repair nutrition from CloudKit", systemImage: "stethoscope")
          Spacer()
          switch nutritionRepairState {
          case .idle:
            EmptyView()
          case .running:
            ProgressView().controlSize(.small)
          case .success(let entries, let summaries):
            Text("\(entries) entries · \(summaries) days")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          case .failure:
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
      }
      .disabled(nutritionRepairState == .running)
      if case .failure(let message) = nutritionRepairState {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Repair")
    } footer: {
      Text("Re-pulls every nutrition entry and daily summary from CloudKit and merges them into the local store. Use if this device's protein/kcal history looks empty even though entries exist on another device.")
    }
  }

  private func repairNutritionFromCloudKit() async {
    nutritionRepairState = .running
    do {
      let records = try await ckEngine.fetchAllRecords(recordTypes: [
        NutritionEntryCloudKitSchema.recordType,
        NutritionDailySummaryCloudKitSchema.recordType,
      ])
      var entries = 0
      var summaries = 0
      for record in records {
        ckEngine.applyFetchedRecord?(record)
        if record.recordType == NutritionEntryCloudKitSchema.recordType {
          entries += 1
        } else if record.recordType == NutritionDailySummaryCloudKitSchema.recordType {
          summaries += 1
        }
      }
      ckEngine.applyDidFinishBatch?()
      nutritionRepairState = .success(entryCount: entries, summaryCount: summaries)
    } catch {
      nutritionRepairState = .failure(message: error.localizedDescription)
    }
  }

  @ViewBuilder
  private var schemaPromptsSection: some View {
    Section {
      ForEach(exportableSectionKeys, id: \.self) { key in
        schemaPromptRow(for: key)
      }
    } header: {
      Text("Schema prompts")
    } footer: {
      Text("Copy a prompt and paste it into an LLM along with the source data you want to import. The model returns JSON that pastes straight into Import above.")
    }
  }

  @ViewBuilder
  private func schemaPromptRow(for key: String) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        Text(ImportExportService.schemaPrompt(for: key))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Button {
          copyToPasteboard(ImportExportService.schemaPrompt(for: key))
        } label: {
          Label("Copy prompt", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
      }
      .padding(.vertical, 4)
    } label: {
      Label(sectionLabel(for: key), systemImage: sectionGlyph(for: key))
    }
  }

  private func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
  }

  // MARK: Format reference

  @ViewBuilder
  private var formatSection: some View {
    Section {
      DisclosureGroup("Envelope") {
        Text(ImportExportService.envelopeReference)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    } header: {
      Text("Format")
    } footer: {
      Text("Format version \(importExportEnvelopeVersion). The exporter above produces files that round-trip through this importer unchanged.")
    }
  }

  // MARK: Handlers

  private func handlePaste(_ text: String) {
    do {
      importDoc = try ImportExportService.parseEnvelope(Data(text.utf8))
      importMessage = nil
      importIsError = false
      showingPaste = false
    } catch {
      importMessage = error.localizedDescription
      importIsError = true
    }
  }

  private func handleFileImport(_ result: Result<[URL], Error>) {
    importMessage = nil
    importIsError = false
    importDoc = nil
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        importDoc = try ImportExportService.parseEnvelope(try Data(contentsOf: url))
      } catch {
        importMessage = error.localizedDescription
        importIsError = true
      }
    case .failure(let error):
      importMessage = error.localizedDescription
      importIsError = true
    }
  }

  private func applyImport(_ doc: ImportExportEnvelope) {
    do {
      let result = try ImportExportService.apply(doc)
      importDoc = nil
      importMessage = "Imported \(result.applied) row\(result.applied == 1 ? "" : "s"); skipped \(result.skipped) (unsupported table\(result.skipped == 1 ? "" : "s"))."
      importIsError = false
    } catch {
      importMessage = error.localizedDescription
      importIsError = true
    }
  }

  // MARK: Helpers

  private func sectionLabel(for key: String) -> String {
    store.sections.first(where: { $0.key == key })?.label
      ?? SectionManifest.byKey[key]?.defaultLabel
      ?? key.capitalized
  }

  private func sectionGlyph(for key: String) -> String {
    if let m = SectionManifest.byKey[key] { return m.iconSymbol }
    return "circle.fill"
  }

  private func byteSize(_ bytes: Int) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB]
    f.countStyle = .file
    return f.string(fromByteCount: Int64(bytes))
  }
}

// MARK: - ShareLink payload

private struct ExportFile: Transferable {
  let data: Data
  let suggestedName: String

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .json) { item in
      item.data
    }
    .suggestedFileName { $0.suggestedName }
  }
}

// MARK: - Parsed envelope

struct ImportExportEnvelope {
  let version: Int
  let section: String
  let exportedAt: String?
  let appVersion: String?
  let tables: [String: [[String: Any]]]
}

// MARK: - Service
//
// Pure functions: build a JSON `Data` blob for a given section (or all),
// or parse an inbound `Data` blob into an `ImportExportEnvelope`. No UI
// state — the pane drives it.

enum ImportExportService {
  enum ImportError: LocalizedError {
    case notJSON
    case missingEnvelope
    case unsupportedVersion(Int)
    case unsupportedSection(String)
    case malformed(String)

    var errorDescription: String? {
      switch self {
      case .notJSON: return "File isn't valid JSON."
      case .missingEnvelope: return "Missing Septena export envelope (septena_export_version / section / tables)."
      case .unsupportedVersion(let v): return "Export version \(v) is newer than this build understands."
      case .unsupportedSection(let s): return "Unknown section: \(s)."
      case .malformed(let m): return m
      }
    }
  }

  static var todayStamp: String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: .now)
  }

  /// Skill-style LLM prompt for one section. Self-contained: states the
  /// goal, the exact envelope shape to produce, and every field expected
  /// in every table (with type + required/optional). Designed to be
  /// copy-pasted into Claude / ChatGPT with arbitrary source data
  /// appended underneath.
  @MainActor
  static func schemaPrompt(for sectionKey: String) -> String {
    let sectionLabel = SectionManifest.byKey[sectionKey]?.defaultLabel
      ?? sectionKey.capitalized
    let tables = schemaTables(for: sectionKey)
    var out = """
    # Septena \(sectionLabel) Import

    You convert source data into a JSON document that Septena's Settings → Import & Export pane can apply.

    ## Output

    Return **only** the JSON below — no commentary, no markdown fences. Wrap your records in this envelope verbatim, substituting only `tables`:

    ```
    {
      "septena_export_version": 1,
      "section": "\(sectionKey)",
      "exported_at": "<current ISO-8601 timestamp>",
      "tables": {
    """
    for (i, t) in tables.enumerated() {
      let comma = (i == tables.count - 1) ? "" : ","
      out += "\n    \"\(t.name)\": [ … ]\(comma)"
    }
    out += """

      }
    }
    ```

    ## Tables

    """
    for t in tables {
      out += "\n### `\(t.name)` — \(t.purpose)\n"
      for f in t.fields {
        let req = f.required ? "**required**" : "optional"
        let note = f.note.map { " — \($0)" } ?? ""
        out += "- `\(f.name)` (\(f.type), \(req))\(note)\n"
      }
    }
    out += """

    ## Rules
    - `id` is a stable string; reuse the same id to update an existing row, choose a new one to insert.
    - Dates: `YYYY-MM-DD`. Times: `HH:MM`. Timestamps: ISO-8601 (e.g. `2026-05-24T08:30:00Z`).
    - Omit optional fields you don't have rather than sending `null`.
    - Skip any record you can't confidently map; partial data is better than fabricated data.

    ## Source data
    <paste your source data below this line>
    """
    return out
  }

  /// Table schemas exposed to the prompt builder. Kept in sync with the
  /// entity → dict mappers above; if you add a field there, add it here.
  @MainActor
  private static func schemaTables(for sectionKey: String) -> [SchemaTable] {
    // Every section now lives in its plugin's exportContribution. If
    // the lookup fails, the section either doesn't exist or doesn't
    // participate in import/export — return [] so the prompt builder
    // emits an empty schema block instead of crashing.
    return SectionRegistry.plugin(forKey: sectionKey)?.exportContribution?.tables ?? []
  }

  // SchemaTable / SchemaField hoisted to top-level types (see end of
  // file) so plugin files can declare their own export contribution
  // without needing to reach into ImportExportService's nesting.

  static let envelopeReference = """
{
  "septena_export_version": 1,
  "section": "tasks" | "training" | … | "all",
  "exported_at": "<ISO-8601>",
  "app_version": "<short> (<build>)",
  "tables": {
    "task":    [{ "id": …, "title": …, … }],
    "project": [...],
    …
  }
}
"""

  // MARK: Build

  @MainActor
  static func exportAll() throws -> Data {
    var tables: [String: [[String: Any]]] = [:]
    for key in exportableSectionKeys {
      let sectionTables = try collectTables(for: key)
      for (k, v) in sectionTables { tables[k] = v }
    }
    return try encode(section: "all", tables: tables)
  }

  @MainActor
  static func exportSection(_ key: String) throws -> Data {
    let tables = try collectTables(for: key)
    return try encode(section: key, tables: tables)
  }

  @MainActor
  private static func collectTables(for key: String) throws -> [String: [[String: Any]]] {
    let ctx = LocalStore.shared.container.mainContext
    guard let contribution = SectionRegistry.plugin(forKey: key)?.exportContribution else {
      throw ImportError.unsupportedSection(key)
    }
    return try contribution.collect(ctx)
  }

  // fetchAll helper retired — plugins do their own ctx.fetch calls
  // inside their exportContribution.collect closures.

  private static func encode(section: String,
                             tables: [String: [[String: Any]]]) throws -> Data {
    let envelope: [String: Any] = [
      "septena_export_version": importExportEnvelopeVersion,
      "section": section,
      "exported_at": ISO8601DateFormatter().string(from: .now),
      "app_version": appVersion(),
      "tables": tables,
    ]
    return try JSONSerialization.data(withJSONObject: envelope,
                                      options: [.prettyPrinted, .sortedKeys])
  }

  private static func appVersion() -> String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    return "\(v) (\(b))"
  }

  // MARK: Parse

  static func parseEnvelope(_ data: Data) throws -> ImportExportEnvelope {
    let raw: Any
    do {
      raw = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw ImportError.notJSON
    }
    guard let dict = raw as? [String: Any],
          let version = dict["septena_export_version"] as? Int,
          let section = dict["section"] as? String,
          let tablesRaw = dict["tables"] as? [String: Any]
    else { throw ImportError.missingEnvelope }
    if version > importExportEnvelopeVersion {
      throw ImportError.unsupportedVersion(version)
    }
    var typed: [String: [[String: Any]]] = [:]
    for (table, rows) in tablesRaw {
      guard let rows = rows as? [[String: Any]] else {
        throw ImportError.malformed("Table '\(table)' is not an array of objects.")
      }
      typed[table] = rows
    }
    return ImportExportEnvelope(
      version: version,
      section: section,
      exportedAt: dict["exported_at"] as? String,
      appVersion: dict["app_version"] as? String,
      tables: typed
    )
  }

  // MARK: Apply
  //
  // v1 limits write-back to the simple, idempotent definition rows that
  // are pure upserts by id and have a `noteXChange(id:)` on `CKEngine`.
  // Event/log rows (nutrition entries, caffeine events, training entries,
  // etc.) route through dedicated mutators that handle recurrence,
  // summaries, and CK fan-out — those land in a follow-up. Unsupported
  // tables are counted toward `skipped` so the user sees what landed.

  struct ApplyResult {
    var applied: Int
    var skipped: Int
  }

  @MainActor
  static func apply(_ doc: ImportExportEnvelope) throws -> ApplyResult {
    let ctx = LocalStore.shared.container.mainContext
    let engine = SeptenaServices.shared.ckEngine
    var applied = 0
    var skipped = 0
    for (table, rows) in doc.tables {
      switch table {
      case "habitDefinition":
        for r in rows { try upsertHabitDefinition(r, ctx: ctx, engine: engine); applied += 1 }
      case "supplementDefinition":
        for r in rows { try upsertSupplementDefinition(r, ctx: ctx, engine: engine); applied += 1 }
      case "choreDefinition":
        for r in rows { try upsertChoreDefinition(r, ctx: ctx, engine: engine); applied += 1 }
      case "caffeineBean":
        for r in rows { try upsertCaffeineBean(r, ctx: ctx, engine: engine); applied += 1 }
      case "groceryCategory":
        for r in rows { try upsertGroceryCategory(r, ctx: ctx, engine: engine); applied += 1 }
      case "groceryItem":
        for r in rows { try upsertGroceryItem(r, ctx: ctx, engine: engine); applied += 1 }
      default:
        skipped += rows.count
      }
    }
    try ctx.save()
    return ApplyResult(applied: applied, skipped: skipped)
  }
}

// MARK: - Entity → dict mappers


// Internal (not private) so plugin export-contribution helpers in
// sibling files can reuse the same compaction + ISO-date primitives.
func isoDate(_ d: Date) -> String {
  ISO8601DateFormatter().string(from: d)
}

/// Strips nil values so the JSON stays compact and `JSONSerialization`
/// doesn't trip on `Any?`.
func compact(_ dict: [String: Any?]) -> [String: Any] {
  var out: [String: Any] = [:]
  for (k, v) in dict {
    guard let v else { continue }
    out[k] = v
  }
  return out
}

// MARK: - Upserts (definition tables only)

@MainActor
private func upsertHabitDefinition(_ r: [String: Any],
                                   ctx: ModelContext,
                                   engine: CKEngine) throws {
  guard let id = r["id"] as? String,
        let title = r["title"] as? String,
        let bucket = r["bucket"] as? String
  else { throw ImportExportService.ImportError.malformed("habitDefinition row missing id/title/bucket") }
  let existing = try ctx.fetch(FetchDescriptor<HabitDefinitionEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? HabitDefinitionEntity(id: id, title: title, bucket: bucket)
  if existing == nil { ctx.insert(e) }
  e.title = title
  e.bucket = bucket
  e.emoji = r["emoji"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteHabitDefinitionChange(id: id)
}

@MainActor
private func upsertSupplementDefinition(_ r: [String: Any],
                                        ctx: ModelContext,
                                        engine: CKEngine) throws {
  guard let id = r["id"] as? String, let title = r["title"] as? String
  else { throw ImportExportService.ImportError.malformed("supplementDefinition row missing id/title") }
  let existing = try ctx.fetch(FetchDescriptor<SupplementDefinitionEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? SupplementDefinitionEntity(id: id, title: title)
  if existing == nil { ctx.insert(e) }
  e.title = title
  e.emoji = r["emoji"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteSupplementDefinitionChange(id: id)
}

@MainActor
private func upsertChoreDefinition(_ r: [String: Any],
                                   ctx: ModelContext,
                                   engine: CKEngine) throws {
  guard let id = r["id"] as? String,
        let title = r["title"] as? String,
        let cadence = r["cadenceDays"] as? Int
  else { throw ImportExportService.ImportError.malformed("choreDefinition row missing id/title/cadenceDays") }
  let existing = try ctx.fetch(FetchDescriptor<ChoreDefinitionEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? ChoreDefinitionEntity(id: id, title: title, cadenceDays: cadence)
  if existing == nil { ctx.insert(e) }
  e.title = title
  e.cadenceDays = cadence
  e.emoji = r["emoji"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteChoreDefinitionChange(id: id)
}

@MainActor
private func upsertCaffeineBean(_ r: [String: Any],
                                ctx: ModelContext,
                                engine: CKEngine) throws {
  guard let id = r["id"] as? String, let name = r["name"] as? String
  else { throw ImportExportService.ImportError.malformed("caffeineBean row missing id/name") }
  let existing = try ctx.fetch(FetchDescriptor<CaffeineBeanEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? CaffeineBeanEntity(id: id, name: name)
  if existing == nil { ctx.insert(e) }
  e.name = name
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteCaffeineBeanChange(id: id)
}

@MainActor
private func upsertGroceryCategory(_ r: [String: Any],
                                   ctx: ModelContext,
                                   engine: CKEngine) throws {
  guard let id = r["id"] as? String, let name = r["name"] as? String
  else { throw ImportExportService.ImportError.malformed("groceryCategory row missing id/name") }
  let existing = try ctx.fetch(FetchDescriptor<GroceryCategoryEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? GroceryCategoryEntity(id: id, name: name)
  if existing == nil { ctx.insert(e) }
  e.name = name
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteGroceryCategoryChange(id: id)
}

@MainActor
private func upsertGroceryItem(_ r: [String: Any],
                               ctx: ModelContext,
                               engine: CKEngine) throws {
  guard let id = r["id"] as? String,
        let name = r["name"] as? String,
        let category = r["category"] as? String
  else { throw ImportExportService.ImportError.malformed("groceryItem row missing id/name/category") }
  let existing = try ctx.fetch(FetchDescriptor<GroceryItemEntity>(
    predicate: #Predicate { $0.id == id })).first
  let e = existing ?? GroceryItemEntity(id: id, name: name, category: category)
  if existing == nil { ctx.insert(e) }
  e.name = name
  e.category = category
  e.emoji = r["emoji"] as? String ?? ""
  e.low = r["low"] as? Bool ?? false
  e.lastBought = r["lastBought"] as? String
  e.sortIndex = r["sortIndex"] as? Int ?? 0
  e.updatedAt = .now
  engine.noteGroceryItemChange(id: id)
}

// MARK: - Export schema types (top-level)
//
// Hoisted out of ImportExportService so plugin files can reference
// them when declaring per-section export contributions.

struct SchemaTable {
  let name: String
  let purpose: String
  let fields: [SchemaField]
}

struct SchemaField {
  let name: String
  let type: String
  let required: Bool
  let note: String?
  static func req(_ name: String, _ type: String, _ note: String? = nil) -> SchemaField {
    SchemaField(name: name, type: type, required: true, note: note)
  }
  static func opt(_ name: String, _ type: String, _ note: String? = nil) -> SchemaField {
    SchemaField(name: name, type: type, required: false, note: note)
  }
}

/// Per-section export contribution. A plugin returns this if it wants
/// to participate in Settings → Import & Export and the schema-prompt
/// generator. `tables` declares the JSON shape; `collect` returns a
/// freshly-built `[tableName: [row]]` dictionary for the user's data.
struct SectionExportContribution {
  let tables: [SchemaTable]
  let collect: @MainActor (ModelContext) throws -> [String: [[String: Any]]]
}
