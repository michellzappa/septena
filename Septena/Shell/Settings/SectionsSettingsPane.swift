import SwiftUI
import SwiftData
import EventKit
import CloudKit
import CoreLocation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

struct PaletteSwatch: Identifiable {
  let id: String
  let label: String
  let hex: String
}

let sectionPalette: [PaletteSwatch] = [
  // Bright row — Tailwind 500
  .init(id: "red",        label: String(localized: "Red", comment: "Accent color"),        hex: "#ef4444"),
  .init(id: "orange",     label: String(localized: "Orange", comment: "Accent color"),     hex: "#f97316"),
  .init(id: "amber",      label: String(localized: "Amber", comment: "Accent color"),      hex: "#f59e0b"),
  .init(id: "yellow",     label: String(localized: "Yellow", comment: "Accent color"),     hex: "#eab308"),
  .init(id: "lime",       label: String(localized: "Lime", comment: "Accent color"),       hex: "#84cc16"),
  .init(id: "green",      label: String(localized: "Green", comment: "Accent color"),      hex: "#22c55e"),
  .init(id: "emerald",    label: String(localized: "Emerald", comment: "Accent color"),    hex: "#10b981"),
  .init(id: "teal",       label: String(localized: "Teal", comment: "Accent color"),       hex: "#14b8a6"),
  .init(id: "cyan",       label: String(localized: "Cyan", comment: "Accent color"),       hex: "#06b6d4"),
  .init(id: "sky",        label: String(localized: "Sky", comment: "Accent color"),        hex: "#0ea5e9"),
  .init(id: "blue",       label: String(localized: "Blue", comment: "Accent color"),       hex: "#3b82f6"),
  .init(id: "indigo",     label: String(localized: "Indigo", comment: "Accent color"),     hex: "#6366f1"),
  .init(id: "violet",     label: String(localized: "Violet", comment: "Accent color"),     hex: "#8b5cf6"),
  .init(id: "purple",     label: String(localized: "Purple", comment: "Accent color"),     hex: "#a855f7"),
  .init(id: "pink",       label: String(localized: "Pink", comment: "Accent color"),       hex: "#ec4899"),
  .init(id: "rose",       label: String(localized: "Rose", comment: "Accent color"),       hex: "#f43f5e"),
  // Earth row — Tailwind 700/800 warm hues
  .init(id: "terracotta", label: "Terracotta", hex: "#9a3412"),
  .init(id: "brown",      label: "Brown",      hex: "#b45309"),
  .init(id: "mustard",    label: "Mustard",    hex: "#854d0e"),
  .init(id: "olive",      label: "Olive",      hex: "#3f6212"),
  .init(id: "taupe",      label: "Taupe",      hex: "#78716c"),
  .init(id: "espresso",   label: "Espresso",   hex: "#44403c"),
]

struct PaletteSwatchGrid: View {
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

/// Compact "tap to change the color" affordance: the current color in a circle
/// wrapped in the conic rainbow ring iOS's system `ColorPicker` well uses,
/// opening a popover with the curated `PaletteSwatchGrid`. The single component
/// every color selector uses (section identity, intake trackers, macro tiles) so
/// they read identically and draw from the one curated palette rather than an
/// inline full grid or the OS full-spectrum well.
struct PaletteSwatchButton: View {
  let selectedHex: String
  var arrowEdge: Edge = .trailing
  let onSelect: (String) -> Void

  @State private var showingPicker = false

  /// Gap color between the rainbow ring and the colored center, so the ring
  /// stays visually detached from the row background on both platforms.
  private var ringGap: Color {
    #if canImport(UIKit)
    Color(uiColor: .secondarySystemGroupedBackground)
    #else
    Color(nsColor: .windowBackgroundColor)
    #endif
  }

  var body: some View {
    Button {
      showingPicker.toggle()
    } label: {
      ZStack {
        Circle()
          .fill(AngularGradient(
            gradient: Gradient(colors: [.red, .orange, .yellow, .green,
                                        .cyan, .blue, .purple, .red]),
            center: .center))
        Circle().fill(ringGap).padding(2)
        Circle().fill(parseHexColor(selectedHex)).padding(4)
      }
      .frame(width: 26, height: 26)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Color")
    .popover(isPresented: $showingPicker, arrowEdge: arrowEdge) {
      PaletteSwatchGrid(selectedHex: selectedHex) { hex in
        onSelect(hex)
        showingPicker = false
      }
      .padding(12)
      .presentationCompactAdaptation(.popover)
    }
  }
}

// MARK: - Sections pane (collapsed app-style list)

/// The single "Sections" pane — Apple's iOS-18 "Apps" move. Every installed
/// section in the user's saved order; tap a row to open its detail page (color,
/// enabled, Show in Next, per-section settings). Drag to reorder, which drives
/// the dashboard and sidebar order. Disabled sections stay in the list (muted,
/// "Off") so they can be re-enabled from their detail page. The per-section
/// enable toggle — and its onboarding-on-enable flow — now lives in
/// `SectionDetailPane`, so there is one enable path instead of two.
struct SectionsSettingsPane: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine

  /// Installed sections in the user's saved order, with newly seeded sections
  /// (not yet in `sectionOrder`) appended. Includes disabled sections.
  private var entries: [SectionEntry] {
    let installedByKey = Dictionary(uniqueKeysWithValues: store.sections.map { ($0.key, $0) })
    let order = store.serverSettings?.sectionOrder ?? store.sections.map(\.key)
    let seen = Set(order)
    let trailing = store.sections.map(\.key).filter { !seen.contains($0) }
    var emitted = Set<String>()
    return (order + trailing).compactMap { key in
      guard emitted.insert(key).inserted,
            let manifest = SectionManifest.byKey[key],
            // Manage Sections lists data-logging life domains only.
            // App-functions (Coach/goals) register for their machinery — MCP
            // tools, the Coach destination, section-tagged goals — but aren't
            // life domains, so they're excluded here.
            manifest.kind == .loggingDomain,
            let installed = installedByKey[key] else { return nil }
      return SectionEntry(manifest: manifest, server: installed)
    }
  }

  /// Active sections, in saved order — the reorderable group.
  private var enabledEntries: [SectionEntry] { entries.filter(\.isEnabled) }
  /// Disabled sections — listed below, statically (their order doesn't drive
  /// any surface, and reordering an off section reads as noise).
  private var disabledEntries: [SectionEntry] { entries.filter { !$0.isEnabled } }

  var body: some View {
    Form {
      Section {
        ForEach(enabledEntries) { entry in
          NavigationLink(value: SettingsView.SettingsDestination.section(entry.key)) {
            row(for: entry)
          }
        }
        .onMove { from, to in
          var keys = enabledEntries.map(\.key)
          keys.move(fromOffsets: from, toOffset: to)
          store.applySectionOrder(enabledOrder: keys,
                                  context: modelContext, engine: ckEngine)
        }
      } footer: {
        Text("Tap a section to set its color, turn it on or off, and tune what it tracks. Drag to reorder how sections appear across the app.")
      }

      if !disabledEntries.isEmpty {
        Section {
          ForEach(disabledEntries) { entry in
            NavigationLink(value: SettingsView.SettingsDestination.section(entry.key)) {
              row(for: entry)
            }
          }
        } header: {
          Text("Off")
        } footer: {
          Text("Turned-off sections disappear from the home tab but keep all their data. Turn one back on anytime.")
        }
      }
    }
    .formStyle(.grouped)
    #if os(iOS)
    .toolbar { EditButton() }
    #endif
  }

  private func row(for entry: SectionEntry) -> some View {
    HStack(spacing: 12) {
      SectionGlyph(icon: entry.manifest.iconSymbol, accent: entry.accent,
                   size: 29, glyphRatio: 0.38)
        .opacity(entry.isEnabled ? 1 : 0.4)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.label)
          .foregroundStyle(entry.isEnabled ? .primary : .secondary)
        if !entry.manifest.shortDescription.isEmpty {
          Text(entry.manifest.shortDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
    }
  }
}

// MARK: - Section detail pane

struct SectionDetailPane: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SectionTheme.self) private var theme
  let sectionKey: String
  /// Drives the starter-onboarding sheet when the user flips Enabled on for a
  /// section whose plugin offers one. Moved here from the old Manage Sections
  /// pane so there is a single enable path.
  @State private var pendingOnboarding = false
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
    SectionManifest.displayLabel(key: sectionKey, stored: server?.label ?? "")
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
    .sheet(isPresented: $pendingOnboarding) { onboardingSheet.macSheetFrame() }
  }

  /// The section plugin's starter-onboarding view, shown when enabling a
  /// section that offers one. Completion writes hasOnboarded + enabled.
  @ViewBuilder
  private var onboardingSheet: some View {
    if let plugin = SectionRegistry.plugin(forKey: sectionKey),
       let view = plugin.onboarding(complete: { completeOnboarding() }) {
      view
    } else {
      Text("No onboarding available.").padding()
    }
  }

  private func completeOnboarding() {
    let wasEnabled = server?.isEnabled ?? false
    SettingsMirror.setSectionHasOnboarded(sectionKey, hasOnboarded: true,
                                          context: modelContext, engine: ckEngine)
    SettingsMirror.setSectionEnabled(sectionKey, enabled: true,
                                     context: modelContext, engine: ckEngine)
    if !wasEnabled {
      Task { await TelemetryClient.shared.recordSectionEnabled(section: sectionKey, enabled: true) }
    }
    // Reload from the mirror (not a hand-patched map) so the accent that
    // `setSectionEnabled` auto-assigned is reflected, then repaint the theme
    // so the section's tile shows that color instead of gray.
    store.sections = SettingsMirror.loadSections(context: modelContext)
    theme.paintFromCache()
    pendingOnboarding = false
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
          Label("Section Skill", systemImage: "book.closed")
        }
      }
      sectionExportRow
    } header: {
      Text("Skill & Data")
    } footer: {
      Text("Section Skill tells Claude how to use this section when you connect it. Export downloads every record in this section as JSON.")
    }
  }

  @ViewBuilder
  private var sectionExportRow: some View {
    // Serialize lazily — ExportFile carries the closure, so the section's
    // records are fetched + encoded only when the share sheet pulls them, not
    // on every render of this pane.
    let key = sectionKey
    let filename = "septena-\(key)-\(ImportExportService.todayStamp).json"
    ShareLink(item: ExportFile(suggestedName: filename) {
                try ImportExportService.exportSection(key)
              },
              preview: SharePreview(filename, image: Image(systemName: "square.and.arrow.up"))) {
      HStack {
        Label("Export Data", systemImage: "square.and.arrow.up")
          .foregroundStyle(.primary)
        Spacer()
      }
    }
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
      showInSpotlightRow
    } footer: {
      if let m = manifest, !m.explainer.isEmpty {
        Text(m.explainer)
      }
    }
  }

  /// Trailing-aligned "tap to change the color" swatch — the shared
  /// `PaletteSwatchButton` (rainbow ring + curated palette popover).
  @ViewBuilder
  private var colorSwatchButton: some View {
    PaletteSwatchButton(selectedHex: server?.color ?? "") { hex in
      updateColor(hex)
    }
    .accessibilityLabel("Section color")
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
                        showInSpotlight: config.showInSpotlight,
                        hasOnboarded: config.hasOnboarded)
        : config
    }
  }

  /// Per-section opt-out for Spotlight / Siri / Apple Intelligence. Shown only
  /// for sections that actually contribute entities to the index, so a
  /// read-only section (Sleep, GitHub, Insights) doesn't show a dead toggle.
  /// Default on — Septena exposes everything unless the user opts out here.
  @ViewBuilder
  private var showInSpotlightRow: some View {
    if SpotlightIndexer.indexableSectionKeys.contains(sectionKey) {
      Toggle(isOn: Binding(
        get: { server?.showInSpotlight ?? true },
        set: { setShowInSpotlight($0) }
      )) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Show in Spotlight & Siri")
          Text("Let Siri and Apple Intelligence find this section's entries in search.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func setShowInSpotlight(_ value: Bool) {
    SettingsMirror.setSectionShowInSpotlight(sectionKey,
                                             showInSpotlight: value,
                                             context: modelContext,
                                             engine: ckEngine)
    store.sections = store.sections.map { config in
      config.key == sectionKey
        ? SectionConfig(key: config.key,
                        label: config.label,
                        color: config.color,
                        isEnabled: config.isEnabled,
                        showInToday: config.showInToday,
                        showInSpotlight: value,
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
    let previous = server?.isEnabled
    // Off → on for a section whose plugin offers starter onboarding (and that
    // hasn't been onboarded yet, or opts into re-presenting): route through the
    // sheet, which does the enable + hasOnboarded write on completion.
    if enabled,
       let config = server, !config.isEnabled,
       let plugin = SectionRegistry.plugin(forKey: sectionKey),
       plugin.onboarding(complete: {}) != nil,
       (!config.hasOnboarded || plugin.alwaysShowOnboarding) {
      pendingOnboarding = true
      return
    }

    SettingsMirror.setSectionEnabled(sectionKey,
                                     enabled: enabled,
                                     context: modelContext,
                                     engine: ckEngine)
    if previous != enabled {
      Task { await TelemetryClient.shared.recordSectionEnabled(section: sectionKey, enabled: enabled) }
    }
    #if os(iOS)
    // Refresh App Shortcut suggestions so this section's items leave / re-enter
    // Siri + Spotlight in step with its enabled state.
    SeptenaShortcuts.updateAppShortcutParameters()
    #endif
    // Reload from the mirror so an accent auto-assigned on first enable is
    // reflected, then repaint the theme so the tile isn't gray.
    store.sections = SettingsMirror.loadSections(context: modelContext)
    theme.paintFromCache()
  }

  private func updateColor(_ hex: String) {
    // Route through the SettingsMirror write boundary instead of
    // fetch-mutate-saving the SectionEntity here (matches enable / showInToday
    // / showInSpotlight). Persists + syncs via CKEngine.
    SettingsMirror.setSectionColor(sectionKey, hex: hex,
                                   context: modelContext, engine: ckEngine)
    store.sections = store.sections.map { config in
      config.key == sectionKey
        ? SectionConfig(key: config.key,
                        label: config.label,
                        color: hex,
                        isEnabled: config.isEnabled,
                        showInToday: config.showInToday,
                        showInSpotlight: config.showInSpotlight,
                        hasOnboarded: config.hasOnboarded)
        : config
    }
    // Repaint the in-memory accent cache so the dashboard and section
    // views recolor immediately — no wait for the next theme.refresh().
    theme.setColor(hex, for: sectionKey)
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
    // Manifest-driven: any plugin that declares notification descriptors
    // gets a "Notifications" section here automatically — no per-plugin edit.
    SectionNotificationToggles(sectionKey: sectionKey)
  }

  // All per-section detail content now lives in the corresponding
  // plugin's `detailPaneContent()` view. Sections without an override
  // render the identity row + onboarding trigger only. See e.g.
  // CaffeineDetailContent / TasksDetailContent / NutritionDetailContent.
}

// MARK: - Per-section notification toggles
//
// Renders one "Notifications" Section listing every `NotificationDescriptor`
// the section's plugin declares. Toggles write the descriptor's UserDefaults
// key, which posts `didChangeNotification` → `LocalNotificationScheduler`
// reconciles. Sections with no descriptors render nothing.

struct SectionNotificationToggles: View {
  let sectionKey: String

  private var descriptors: [NotificationDescriptor] {
    SectionRegistry.plugin(forKey: sectionKey)?.notificationDescriptors ?? []
  }

  var body: some View {
    if !descriptors.isEmpty {
      Section {
        ForEach(descriptors) { descriptor in
          NotificationToggleRow(descriptor: descriptor)
        }
      } header: {
        Label("Notifications", systemImage: "bell.badge")
      } footer: {
        Text("Nudges fire around when you usually log this, and stay quiet once it’s done for the day.")
      }
    }
  }
}

private struct NotificationToggleRow: View {
  let descriptor: NotificationDescriptor
  @State private var isOn: Bool

  init(descriptor: NotificationDescriptor) {
    self.descriptor = descriptor
    let stored = UserDefaults.standard.object(forKey: descriptor.defaultsKey) as? Bool
    _isOn = State(initialValue: stored ?? descriptor.defaultEnabled)
  }

  var body: some View {
    Toggle(descriptor.title, isOn: Binding(
      get: { isOn },
      set: { newValue in
        isOn = newValue
        UserDefaults.standard.set(newValue, forKey: descriptor.defaultsKey)
      }
    ))
  }
}

// MARK: - Unified notifications overview
//
// One screen listing every nudge across all sections and when it's set to
// fire — the answer to "what will notify me, and when?". The schedule comes
// straight from `LocalNotificationScheduler.overview` (the same gates the
// real scheduler applies), so this can't drift from what actually fires.
// Each row deep-links to its section's settings, where the nudge can be
// toggled. Reached from Customize → Scheduled Notifications.

struct NotificationsOverviewPane: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @AppStorage(SettingsKey.notificationsEnabled) private var notificationsEnabled: Bool = true
  @AppStorage(ClaudeGatewayProvider.connectionNudgeKey) private var claudeNudgeEnabled: Bool = true
  @State private var items: [NotificationOverviewItem] = []

  /// On and firing today, earliest first.
  private var live: [NotificationOverviewItem] {
    items.filter(\.isLive).sorted { minutes($0.state) < minutes($1.state) }
  }
  /// On, but suppressed right now (already logged / nothing pending, or held
  /// out of quiet hours).
  private var resting: [NotificationOverviewItem] {
    items.filter {
      switch $0.state {
      case .idle, .quietHours: return true
      default: return false
      }
    }
  }
  /// Turned off — this nudge, or its whole section.
  private var off: [NotificationOverviewItem] {
    items.filter {
      switch $0.state {
      case .off, .sectionOff: return true
      default: return false
      }
    }
  }

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $notificationsEnabled) {
          Label("Notifications", systemImage: "bell.badge")
        }
      } footer: {
        Text("The master switch. Each nudge fires around when you usually log it and goes quiet once it's marked for the day.")
      }

      if notificationsEnabled {
        Section {
          Toggle(isOn: $claudeNudgeEnabled) {
            Label("Keep Claude connected", systemImage: "antenna.radiowaves.left.and.right")
          }
        } header: {
          Label("Connections", systemImage: "link")
        } footer: {
          Text("Nudges you to refresh the Claude connection just before its ~8-hour session expires, so Claude keeps reading your data without you reconnecting from claude.ai. Only fires while Claude is connected.")
        }

        if !live.isEmpty {
          Section {
            ForEach(live) { row(for: $0) }
          } header: {
            Label("Coming Up Today", systemImage: "clock")
          }
        }

        if !resting.isEmpty {
          Section {
            ForEach(resting) { row(for: $0) }
          } header: {
            Label("Quiet Right Now", systemImage: "moon.zzz")
          } footer: {
            Text("On, but nothing to nudge about right now — today's done, nothing's pending, or it's quiet hours.")
          }
        }

        if !off.isEmpty {
          Section {
            ForEach(off) { row(for: $0) }
          } header: {
            Label("Off", systemImage: "bell.slash")
          }
        }

        if items.isEmpty {
          Section {
            Text("No sections offer reminders yet.")
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: reload)
    // Opening this pane is the opt-in: request OS notification permission now
    // (no-op unless the master switch is on and the status is still
    // `.notDetermined`). We deliberately do NOT ask at launch — only here,
    // when the user has navigated to Notifications because they want them.
    .task { await requestPermissionIfWanted() }
    .onChange(of: notificationsEnabled) { _, on in
      if on { Task { await LocalNotificationScheduler.shared.requestAuthorizationIfNeeded() } }
    }
    // Toggling a nudge writes UserDefaults; logging data posts a data-change.
    // Both can change what's scheduled, so re-read on either.
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in reload() }
  }

  /// Ask for notification permission only when the user has the master switch
  /// on (the default) — i.e. they want nudges. `requestAuthorizationIfNeeded`
  /// itself no-ops unless the OS status is `.notDetermined`, so re-visits don't
  /// re-prompt.
  private func requestPermissionIfWanted() async {
    guard notificationsEnabled else { return }
    await LocalNotificationScheduler.shared.requestAuthorizationIfNeeded()
  }

  private func reload() {
    items = LocalNotificationScheduler.shared.overview(context: modelContext)
  }

  @ViewBuilder
  private func row(for item: NotificationOverviewItem) -> some View {
    let p = presentation(for: item.sectionKey)
    NavigationLink(value: SettingsView.SettingsDestination.section(item.sectionKey)) {
      HStack(spacing: 12) {
        SectionGlyph(icon: p.icon, accent: p.accent, size: 29, glyphRatio: 0.38)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
          Text(p.label)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        trailing(for: item.state)
      }
    }
  }

  @ViewBuilder
  private func trailing(for state: NotificationOverviewItem.State) -> some View {
    switch state {
    case let .scheduled(hour, minute):
      Text(timeLabel(hour, minute))
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .monospacedDigit()
    case let .quietHours(hour, minute):
      Text("\(timeLabel(hour, minute)) · quiet")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    case .idle:
      Text("Quiet")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .off:
      Text("Off")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .sectionOff:
      Text("Section off")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .masterOff:
      EmptyView()
    }
  }

  /// Resolve a section's display label, accent, and icon the same way the
  /// sidebar and `SectionDetailPane` do — live override first, manifest
  /// default as fallback.
  private func presentation(for key: String) -> (label: String, accent: Color, icon: String) {
    let server = store.sections.first(where: { $0.key == key })
    let manifest = SectionManifest.byKey[key]
    let serverLabel = server?.label ?? ""
    let label = SectionManifest.displayLabel(key: key, stored: serverLabel)
    return (label, parseHexColor(server?.color ?? ""), manifest?.iconSymbol ?? "circle.fill")
  }

  private func minutes(_ state: NotificationOverviewItem.State) -> Int {
    switch state {
    case let .scheduled(hour, minute): return hour * 60 + minute
    default: return Int.max
    }
  }

  private func timeLabel(_ hour: Int, _ minute: Int) -> String {
    var comps = DateComponents()
    comps.hour = hour
    comps.minute = minute
    let date = Calendar.current.date(from: comps) ?? Date()
    return date.formatted(date: .omitted, time: .shortened)
  }
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

  /// Hex currently stored for this tile, falling back to the catalog default.
  private var currentHex: String {
    pref.colorHex ?? MacroCatalog.byID[pref.id]?.defaultColorHex ?? ""
  }

  var body: some View {
    let macro = MacroCatalog.byID[pref.id]
    HStack(spacing: 12) {
      // Shared swatch button, same picker the sections and trackers use, so
      // macro tiles draw from the one curated palette rather than the OS
      // full-spectrum well.
      PaletteSwatchButton(selectedHex: currentHex, arrowEdge: .leading) { hex in
        pref.colorHex = hex
        onChange()
      }
      .accessibilityLabel("Tile color")

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
}
