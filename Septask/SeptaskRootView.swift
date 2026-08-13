import SwiftUI

/// Septask's top-level tabs (iPhone). Tasks hosts the full sidebar module —
/// same label and checkmark as Septena's Tasks tab, so the ✓ means "the task
/// module" in both apps; Today, Next, and Upcoming are first-class destinations
/// (Next matches the AppKit sidebar page — not a fold under Today); the
/// trailing `search` tab is a genuine Search destination — the ONLY thing
/// iOS 26 renders in the tab bar's detached trailing slot (a `role: .search`
/// tab). Quick-add is NOT a tab: every list already carries a nav-bar `+`
/// (`pageChrome`) and ⌘N, so capture lives there, not in the bar.
enum SeptaskTab: Hashable {
  case tasks, today, next, upcoming, search
}

/// Septask's root, mirroring `RootTabView`'s shell shape: the standard
/// system `TabView` on iPhone (bottom bar, Music-style minimize on scroll),
/// and NO tab bar on iPad regular / macOS — there the split-view sidebar is
/// the switcher, which is the norm (Septena's iPad segmented switcher is a
/// full-app exception, deliberately not copied). Composition only: every
/// tab hosts shared views unchanged.
struct SeptaskRootView: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  // Read the full task environment here (all injected by SeptaskApp, so these
  // are safe) so the modal sheets below can RE-inject it. `.sheet` normally
  // inherits `@Observable` environment, but the quick-add path presents
  // AddTaskPage directly (not via AddInfoSheet), and a sheet that reparents
  // must not be left guessing — a missing object is a hard launch trap
  // (docs/SEPTASK.md P1 env-injection note).
  @Environment(DayClock.self) private var dayClock
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(AreasMutator.self) private var areasMutator
  @Environment(ProjectsMutator.self) private var projectsMutator
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(LogCommitCenter.self) private var logCommit
  @State private var selection: SeptaskTab = .today
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #else
  @Environment(\.openWindow) private var openWindow
  #endif

  /// Re-inject the whole task environment onto a presented sheet's content —
  /// belt-and-suspenders against `@Observable` environment loss across a
  /// presentation boundary.
  private func withEnvironment<V: View>(_ content: V) -> some View {
    content
      .environment(nav)
      .environment(theme)
      .environment(dayClock)
      .environment(taskMutator)
      .environment(areasMutator)
      .environment(projectsMutator)
      .environment(ckEngine)
      .environment(settingsStore)
      .environment(logCommit)
  }

  var body: some View {
    @Bindable var nav = nav
    return rootLayout
      // Same as RootTabView: resolve the push-vs-sheet rule once at the
      // shell root and publish `\.usesPushNavigation` to every surface.
      .resolvesAdaptiveNavigation()
      // The app-global modals, one `.sheet(item:)` like RootTabView — the
      // subset with a Septask surface. The Next page's suggestions add two:
      // the mood check-in and the nutrition new-meal sheet. Training stays
      // out (its destination is the live-session surface Septask doesn't
      // compile — the feed filters that suggestion). Anything else ever set
      // shows empty rather than crashing.
      .sheet(item: $nav.presentedModal) { modal in
        switch modal {
        case .quickFind:
          withEnvironment(QuickFindView())
            .septenaModalSheet(detents: [.medium, .large],
                               macWidth: 560, macHeight: 420)
        case .addInfo(let section):
          // Septask's quick capture IS the task composer — no multi-section
          // palette here (the tasks-only twin of AddInfoSheet). The one
          // exception: the Next page's fast-break suggestion targets
          // nutrition, which opens the new-meal sheet directly.
          if section == .nutrition {
            withEnvironment(NewNutritionEntrySheet())
              .septenaModalSheet(macWidth: 560, macHeight: 600)
          } else {
            withEnvironment(SeptaskQuickAdd())
              .septenaModalSheet(detents: [.medium, .large],
                                 macWidth: 560, macHeight: 520)
          }
        case .moodCheckin:
          // The Next page's mood suggestion — same check-in page as
          // Septena's tab root (RootTabView.modalSheet).
          withEnvironment(AddMoodPage(anchorTime: dayClock.now, date: dayClock.today))
            .septenaModalSheet(macWidth: 560, macHeight: 600)
        case .keyboardShortcuts:
          withEnvironment(KeyboardShortcutsView())
            .septenaModalSheet(detents: [.medium, .large],
                               macWidth: 480, macHeight: 560)
        default:
          EmptyView()
        }
      }
      // Settings — mirrors RootTabView exactly: a sheet on iOS, a real
      // Settings window on macOS (traffic lights, ⌘W), opened by flipping
      // `nav.showSettings`. The window scene lives in SeptaskApp.
      #if os(iOS)
      .sheet(isPresented: $nav.showSettings) {
        withEnvironment(SeptaskSettingsView())
      }
      #else
      .onChange(of: nav.showSettings) { _, open in
        guard open else { return }
        openWindow(id: "septask-settings")
        nav.showSettings = false
      }
      #endif
  }

  @ViewBuilder
  private var rootLayout: some View {
    #if os(iOS)
    Group {
      if hSize == .compact {
        systemTabView
      } else {
        ContentView()
      }
    }
    // Shared task views navigate through the ONE NavigationState path
    // (project drill-ins, smart-list jumps); ContentView's stack renders it
    // on the Tasks tab. A route landing while a filter tab is frontmost
    // must move selection — the tab-bar twin of RootTabView's pendingTab
    // forwarding.
    .onChange(of: nav.path) { _, path in
      guard hSize == .compact, let last = path.last else { return }
      switch last {
      case .filter(.today):    selection = .today
      case .next:              selection = .next
      case .filter(.upcoming): selection = .upcoming
      default:                 selection = .tasks
      }
    }
    #else
    ContentView()
    #endif
  }

  #if os(iOS)
  /// Standard iOS 26 `TabView`. The detached trailing slot is a real Search tab
  /// (`role: .search`) — the only content iOS 26 pulls out of the tab cluster
  /// into its own separated slot; a plain action tab just renders inline. So the
  /// slot is genuine search (wired to `QuickFindView`), and quick-add moved to
  /// the per-list nav-bar `+` / ⌘N.
  private var systemTabView: some View {
    TabView(selection: $selection) {
      // ContentView self-tints to `theme.accent` (ink), so the Tasks tab's
      // chrome/content stays black; the reset on Today/Upcoming does the same
      // for the tabs that don't host ContentView. Only the bar's SELECTED item
      // picks up the Tasks color, from the `.tint` on the TabView below.
      Tab("Tasks", systemImage: "checkmark", value: SeptaskTab.tasks) {
        ContentView()
      }
      Tab("Today", systemImage: "sun.max.fill", value: SeptaskTab.today) {
        NavigationStack { TaskListView(filter: .today) }.tint(theme.accent)
      }
      Tab("Next", systemImage: "arrow.right", value: SeptaskTab.next) {
        NavigationStack { SeptaskNextPage() }.tint(theme.accent)
      }
      Tab("Upcoming", systemImage: "calendar", value: SeptaskTab.upcoming) {
        NavigationStack { TaskListView(filter: .upcoming) }.tint(theme.accent)
      }
      // The iOS 26 detached trailing slot. A genuine Search tab (searchable
      // `QuickFindView`, hosted `embedded` so it has no modal Cancel) — this is
      // what actually separates from the other tabs; a `role: .search` tab with
      // non-search content renders inline instead.
      Tab("Search", systemImage: "magnifyingglass",
          value: SeptaskTab.search, role: .search) {
        QuickFindView(embedded: true)
      }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
    .tint(theme.color(for: "tasks"))
  }
  #endif
}

/// Quick-add sheet: a fresh router per presentation so the draft never
/// leaks between opens. Sizing comes from the host's `septenaModalSheet`.
private struct SeptaskQuickAdd: View {
  @State private var router = AddInfoRouter()

  var body: some View {
    AddTaskPage(router: router)
  }
}
