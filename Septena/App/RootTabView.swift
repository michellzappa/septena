import SwiftUI

// Top-level shell for Septena — three peer tabs, each a self-contained
// module. Week is the synthesizing dashboard, Next is the merged daily
// checklist, Tasks is the existing iOS task app embedded verbatim.
// Septena-app's `ContentView` (sidebar + task list) lives inside the Tasks
// tab unchanged so we can iterate on the new tabs without breaking the
// daily-driver UX.

// Shared selection so tiles deep inside the Week dashboard can switch tabs
// (e.g. Tasks tile → Tasks tab). Injected via .environment on the TabView.
@Observable final class TabSelection {
  var current: SeptenaTab = .week
}

struct RootTabView: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  // Tasks is the one tab gated on section enabled-state. `SettingsStore` is
  // `@Observable`; reading `sections` in `body` re-renders the bar live when
  // the user toggles the Tasks section in Settings. Week, Next, and Coach are
  // always present — Week/Next are aggregate surfaces with no 1:1 section, and
  // Coach is left always-on deliberately: the `goals` section is an
  // `.appFunction` whose only Enabled toggle is reached *through* the Coach
  // tab, so gating the tab on it would strand the user with no way back.
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(DayClock.self) private var clock
  // Gates the in-flight training pill below the tab bar. Read here (not
  // just inside the accessory) so the `.tabViewBottomAccessory` modifier
  // is attached only mid-workout — an empty accessory content still draws
  // a blank bar, so the bar has to be absent, not just empty.
  @Environment(TrainingDraftStore.self) private var draftStore
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif
  #if os(macOS)
  @Environment(\.openWindow) private var openWindow
  #endif
  @State private var tabSelection = TabSelection()
  #if os(iOS)
  // iPad tab-less container: which tabs have been visited (and so are kept
  // alive). Seeded with the launch tab; grows as the user switches.
  @State private var visitedTabs: Set<SeptenaTab> = [.week]
  // Per-tab "···"/"+" published by each page's `.pageChrome`, rendered by the
  // iPad top-bar overlay (so the chrome aligns to the content gutter).
  @State private var iPadChrome = IPadChromeModel()
  #endif

  // "What's New" gate. We show the sheet once when the app's marketing version
  // climbs past the last release the user saw — but never on a fresh install
  // (empty marker → adopt the current version silently; the welcome covers
  // first run) and never until the welcome is done.
  @AppStorage(SettingsKey.welcomeCompleted) private var welcomeCompleted = false
  @AppStorage(SettingsKey.lastSeenChangelogVersion) private var lastSeenChangelog = ""
  @State private var showWhatsNew = false

  // Default to shown when the section row hasn't loaded into the store yet;
  // fall back to the SwiftData mirror so a post-pull enablement isn't masked
  // by a stale in-memory cache during launch.
  private var tasksEnabled: Bool {
    if let row = settingsStore.sections.first(where: { $0.key == "tasks" }) {
      return row.isEnabled
    }
    let mirrored = SettingsMirror.loadSections(
      context: LocalStore.shared.container.mainContext)
    return mirrored.first(where: { $0.key == "tasks" })?.isEnabled ?? true
  }

  var body: some View {
    @Bindable var nav = nav
    rootTabView
      // If the user disables Tasks while sitting on its tab, that tab vanishes
      // from the bar — fall the selection back to Week so we never sit on a tag
      // with no matching tab. Week/Next/Coach are always present.
      .onChange(of: tasksEnabled) { _, on in
        if !on, tabSelection.current == .tasks { tabSelection.current = .week }
      }
      .tint(theme.accent)
      // Resolve the push-vs-sheet rule once, here at the shell root, and
      // publish it to every tab via `\.usesPushNavigation`. The Week
      // dashboard, Coach tab, and section-drawer inspector all read that one
      // value instead of each recomputing from the size class.
      .resolvesAdaptiveNavigation()
      .environment(tabSelection)
      #if os(iOS)
      .environment(iPadChrome)
      #endif
      // Anonymous aggregate telemetry — one event when the user lands on
      // a tab. `.task(id:)` re-runs only when the value changes and is
      // cancelled on disappear, so back-nav within a tab doesn't double
      // count. The actor is fire-and-forget; this never blocks UI.
      .task(id: tabSelection.current) {
        await TelemetryClient.shared.track(screen: tabSelection.current.analyticsName)
      }
      // App-global Settings. Lives at the TabView level so the top-left
      // "…" menu on every home view opens it, and so the sidebar row in
      // Tasks does too. On iOS it's a sheet; on macOS the same `showSettings`
      // flag opens the dedicated `"settings"` Window (declared in App.swift)
      // so the surface carries real traffic lights and closes like a window.
      #if os(iOS)
      // Forward the optional deep-link target so a contextual entry point
      // (e.g. a home "…" menu's "Next Settings" row) can open Settings already
      // pushed to its pane — matching the macOS window path below. Cleared on
      // dismiss so the next plain open lands on the root.
      .sheet(isPresented: $nav.showSettings, onDismiss: { nav.settingsDestination = nil }) {
        SettingsView(initialDestination: nav.settingsDestination)
      }
      #else
      .onChange(of: nav.showSettings) { _, open in
        guard open else { return }
        openWindow(id: "settings")
        nav.showSettings = false
      }
      #endif
      // Every app-global modal — Quick Find, Add Info, the Quick-Action section
      // sheet, the Training logger, the Mood check-in, the keyboard cheat-sheet
      // — routes through one `presentedModal` + this single `.sheet(item:)`,
      // so each surface works regardless of the selected tab without its own
      // boolean + onChange/onDismiss cleanup. Sizing is the shared
      // `septenaModalSheet` (iOS detents / macOS frame). (Insights destination
      // removed — Correlations now hosts its grids inline.)
      .sheet(item: $nav.presentedModal) { modal in
        modalSheet(modal)
      }
      // Home Screen Quick Action routing. Mounted at the tab-root so it
      // fires regardless of which tab is selected — ContentView (the
      // previous host) is only mounted while the Tasks tab is visible.
      // We deliberately do NOT switch tabs; the sheet covers the current
      // tab and dismissing returns the user there.
      .onChange(of: nav.pendingShortcut) { _, action in
        guard let action else { return }
        switch action {
        case .openSection(let key):
          nav.presentSection(key: key)
        case .newTask:
          // Same inline "new to-do" route as ⌘N / the sidebar + — lands on
          // Tasks ▸ Today with the composer open.
          OpenNewTaskRouting.apply(to: nav)
        case .today:
          nav.pendingTab = .tasks
          nav.path = [.filter(.today)]
        }
        nav.pendingShortcut = nil
      }
      // Deep-link tab switch (e.g. the Next widget's `septena://next`).
      .onChange(of: nav.pendingTab) { _, tab in
        guard let tab else { return }
        tabSelection.current = tab
        nav.pendingTab = nil
      }
      // "What's New" after an update — see the gate notes on `showWhatsNew`.
      .task(id: welcomeCompleted) {
        guard welcomeCompleted, let latest = Changelog.latestReleased?.version else { return }
        if lastSeenChangelog.isEmpty {
          lastSeenChangelog = latest            // fresh install: adopt silently
        } else if !Changelog.unseen(since: lastSeenChangelog).isEmpty {
          showWhatsNew = true
        }
      }
      .sheet(isPresented: $showWhatsNew, onDismiss: {
        if let latest = Changelog.latestReleased?.version { lastSeenChangelog = latest }
      }) {
        WhatsNewSheet(since: lastSeenChangelog)
          #if os(iOS)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
          #endif
      }
  }

  // The content + sizing for each app-global modal. One switch instead of one
  // `.sheet` modifier per case; sizing shares `septenaModalSheet`.
  @ViewBuilder
  private func modalSheet(_ modal: AppModal) -> some View {
    switch modal {
    case .quickFind:
      QuickFindView()
        .septenaModalSheet(detents: [.medium, .large], macWidth: 560, macHeight: 420)
    case .addInfo(let section):
      AddInfoSheet(initialSection: section)
        .septenaModalSheet(detents: [.medium, .large], macWidth: 560, macHeight: 520)
    case .section(let key):
      // Quick-Action section sheet — the plugin's destination in a
      // NavigationStack so its title + toolbar present cleanly.
      NavigationStack {
        if let view = SectionRegistry.plugin(forKey: key)?.destinationView() {
          view
        } else {
          Text("Section unavailable.").padding()
        }
      }
      .septenaModalSheet(macWidth: 560, macHeight: 600)
    case .intakeKind(let id):
      NavigationStack {
        IntakeKindPageView(kindID: id)
      }
      .septenaModalSheet(macWidth: 560, macHeight: 600)
    case .trainingSession:
      TrainingSessionView()
        .septenaModalSheet(macWidth: 560, macHeight: 600)
    case .moodCheckin:
      AddMoodPage(anchorTime: clock.now, date: clock.today)
        .septenaModalSheet(macWidth: 560, macHeight: 600)
    case .keyboardShortcuts:
      KeyboardShortcutsView()
        .septenaModalSheet(detents: [.medium, .large], macWidth: 480, macHeight: 560)
    }
  }

  // Standard iOS 26 TabView with the system tab-bar minimize behavior
  // (Music's collapse-on-scroll pattern). The floating "+" bubble that
  // used to ride beside the bar was removed — it crowded the tab bar
  // on iPhone and overlapped tab labels. Add Info still triggers from
  // ⌘K (menu bar) and each destination's own "+" button.
  @ViewBuilder
  private var rootTabView: some View {
    #if os(iOS)
    // iPad regular: NO `TabView`. The iPadOS 26 floating tab bar can't be
    // reliably hidden (`.toolbar(.hidden, for: .tabBar)` races and re-shows the
    // bar under our switcher), so we don't create one — each tab's nav-bar
    // switcher (`.pageChrome` → `.principal`) is the only switcher. iPhone keeps
    // the system `TabView` (bottom bar); macOS keeps it (title-bar tabs).
    if hSize == .regular {
      iPadTabless
    } else {
      systemTabView
    }
    #else
    systemTabView
    #endif
  }

  /// The view backing each tab. Shared by the `TabView` (iPhone/macOS) and the
  /// tab-less iPad container so the two stay in lockstep.
  @ViewBuilder
  private func tabContent(_ tab: SeptenaTab) -> some View {
    switch tab {
    case .week:  WeekDashboardView()
    case .next:  NextDashboardView()
    case .tasks: ContentView()
    case .goals: CoachView()
    }
  }

  /// Tabs in bar order, honoring the Tasks enabled-gate.
  private var availableTabs: [SeptenaTab] {
    var tabs: [SeptenaTab] = [.week, .next]
    if tasksEnabled { tabs.append(.tasks) }
    tabs.append(.goals)
    return tabs
  }

  /// System `TabView` — the real tab bar (bottom on iPhone, title-bar on macOS).
  private var systemTabView: some View {
    let tv = TabView(selection: Binding(get: { tabSelection.current },
                                        set: { tabSelection.current = $0 })) {
      WeekDashboardView()
        .tabItem {
          // `DiscsMark` is a custom SF Symbol (Septena's seven-disc mark).
          Label("Today", image: "DiscsMark")
        }
        .tag(SeptenaTab.week)

      NextDashboardView()
        .tabItem { Label("Next", systemImage: "arrow.right") }
        .tag(SeptenaTab.next)

      if tasksEnabled {
        ContentView()
          .tabItem { Label("Tasks", systemImage: "checkmark") }
          .tag(SeptenaTab.tasks)
      }

      CoachView()
        .tabItem {
          Label("Coach", systemImage: "smallcircle.filled.circle")
            .environment(\.symbolVariants, .none)
        }
        .tag(SeptenaTab.goals)
    }
    #if os(iOS)
    return tv
      .tabBarMinimizeBehavior(.onScrollDown)
      .trainingTabAccessory(when: draftStore)
    #else
    return tv
    #endif
  }

  #if os(iOS)
  /// iPad regular: render the selected tab with NO `TabView`. Each tab is
  /// created lazily on first visit and then kept alive (its `.task`/loads don't
  /// re-run on every switch, matching `TabView`'s persistence), shown by
  /// toggling opacity — so there's no tab bar to flicker and no re-fetch churn.
  private var iPadTabless: some View {
    ZStack {
      ForEach(availableTabs, id: \.self) { tab in
        if visitedTabs.contains(tab) {
          tabContent(tab)
            .opacity(tabSelection.current == tab ? 1 : 0)
            .allowsHitTesting(tabSelection.current == tab)
            .accessibilityHidden(tabSelection.current != tab)
        }
      }
    }
    // The whole top bar rides here at the WINDOW level — gear (leading) ·
    // switcher (centered) · ···/+ (trailing) — not in any page's nav bar. So it
    // aligns to `Theme.pageGutter` like the content, and the Tasks sidebar
    // opening/closing (which resizes the detail pane) can't shift any of it.
    //
    // Floating bar. The space it occupies is reserved INSIDE each page (via
    // `.pageChrome` → a top `safeAreaInset` of `PageChromeMetrics.iPadBarHeight`),
    // because a `safeAreaInset` here at the container doesn't propagate through
    // the tabs' NavigationStacks to their scroll content.
    .overlay(alignment: .top) {
      if iPadChrome.atRoot(for: tabSelection.current.chromeID) {
        iPadTopBar
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: iPadChrome.atRoot(for: tabSelection.current.chromeID))
    .onAppear { visitedTabs.insert(tabSelection.current) }
    .onChange(of: tabSelection.current) { _, tab in visitedTabs.insert(tab) }
  }

  /// The iPad window-level chrome bar: gear · switcher · ···/+. Gear + switcher
  /// are global; the "···"/"+" come from the current tab's `IPadChromeModel`
  /// entry. Insets match the page content gutter so nothing hugs the edge.
  private var iPadTopBar: some View {
    let entry = iPadChrome.entry(tabSelection.current.chromeID)
    return ZStack {
      HStack(spacing: 0) {
        HStack(spacing: 10) {
          // Left cluster: "···" (when the page publishes index actions), Quick Find
          // on Tasks, and the Tasks-only sidebar toggle — "+" stays trailing.
          if entry?.showsOverflowMenu != false {
            Menu {
              if let actions = entry?.localActions, let rows = actions() {
                rows
                Divider()
              }
              Button { nav.showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
              }
            } label: {
              cornerGlyph("ellipsis")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("More")
          }
          if tabSelection.current == .tasks {
            glassCornerButton("magnifyingglass", label: "Search") {
              nav.showQuickFind = true
            }
          }
          // Tasks only: the sole sidebar show/hide control on iPad — lives in
          // the global overlay (not the split's auto toolbar toggle, which we
          // strip via `.toolbar(removing: .sidebarToggle)` on both columns).
          if tabSelection.current == .tasks {
            Button {
              withAnimation(.snappy) {
                nav.sidebarVisibility = nav.sidebarVisibility == .detailOnly ? .all : .detailOnly
              }
            } label: {
              cornerGlyph("sidebar.left")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Toggle Sidebar")
          }
        }
        Spacer(minLength: 0)
        // Each trailing control gets its own `GlassEffectContainer` so sibling
        // `.buttonStyle(.glass)` circles don't fuse on device (spacing alone
        // doesn't stop iOS 26 from unioning them).
        HStack(spacing: 22) {
          GlassEffectContainer {
            ClaudeReconnectCue(.overlayCircle)
          }
          if let add = entry?.add {
            GlassEffectContainer {
              glassCornerButton("plus", label: "Add", action: resolveAdd(add))
            }
          }
        }
      }
      TabSwitcher()
    }
    .padding(.horizontal, Theme.pageGutter)
    .padding(.top, 8)
  }

  /// A corner-control glyph in a fixed square so both circles size identically.
  private func cornerGlyph(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.title3.weight(.semibold))
      .frame(width: 30, height: 30)
  }

  /// iPad overlay corner control — `.buttonStyle(.glass)` so the system draws the
  /// same-size circle as the "···" menu (manual `glassCircle()` on 30pt hugged
  /// the glyph and read half-sized).
  private func glassCornerButton(_ systemName: String, label: String,
                                 action: @escaping () -> Void) -> some View {
    Button(action: action) { cornerGlyph(systemName) }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .accessibilityLabel(label)
  }

  private func resolveAdd(_ add: PageAdd) -> () -> Void {
    switch add {
    case .addInfo:         return { nav.presentAddInfo() }
    case .action(let run): return run
    }
  }
  #endif
}

#if os(iOS)
private extension View {
  @ViewBuilder
  func trainingTabAccessory(when draftStore: TrainingDraftStore) -> some View {
    if let draft = draftStore.draft, draft.totalCount > 0 {
      tabViewBottomAccessory { TrainingTabAccessory() }
    } else {
      self
    }
  }
}
#endif
