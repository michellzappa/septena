import SwiftUI

/// Septask's top-level tabs (iPhone). Tasks hosts the full sidebar module —
/// same label and checkmark as Septena's Tasks tab, so the ✓ means "the task
/// module" in both apps; Today and Upcoming are first-class destinations; the
/// trailing `newTask` slot uses `role: .search` so iOS 26 renders the native
/// detached circular `+` button in the exact tab-bar baseline (both expanded
/// and minimized on scroll). A transparent drag overlay directly on top of that
/// circle adds native `.draggable(TaskDragIDs.newTask)` so you can press-and-
/// drag `+` onto any row gap, heading, group, Upcoming day, or Tasks destination,
/// while tap opens `SeptaskQuickAdd`. Search lives in the trailing nav bar.
///
/// Septask has no Next page (removed 2026-11-19: it showed life-OS content,
/// not tasks; Today covers "what's next" for tasks).
enum SeptaskTab: Hashable {
  case tasks, today, upcoming, newTask
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
  @Environment(\.verticalSizeClass) private var vSize
  /// Matches `ResolveAdaptiveNavigation` (`usesPushNavigation`): split layout
  /// only when BOTH dimensions are regular (unfolded iPhone Duo, iPad full-
  /// screen / large multitasking). Testing `== .regular` rather than
  /// `!= .compact` keeps a transient `nil` size class during fold/unfold in
  /// the safe compact branch, and keeps compact-height landscape phones out of
  /// a cramped split view.
  private var usesSplitLayout: Bool { hSize == .regular && vSize == .regular }
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
      // subset with a Septask surface. The mood check-in and new-meal sheets
      // left with the Next page (2026-11-19). Anything else ever set shows
      // empty rather than crashing.
      .sheet(item: $nav.presentedModal) { modal in
        switch modal {
        case .quickFind:
          withEnvironment(QuickFindView())
            .septenaModalSheet(detents: [.medium, .large],
                               macWidth: 560, macHeight: 420)
        case .addInfo:
          // Septask's quick capture IS the task composer — no multi-section
          // palette here (the tasks-only twin of AddInfoSheet), whatever
          // section the request names.
          withEnvironment(SeptaskQuickAdd())
            .septenaModalSheet(detents: [.medium, .large],
                               macWidth: 560, macHeight: 520)
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
      if usesSplitLayout {
        ContentView()
      } else {
        systemTabView
      }
    }
    // Fold / unfold continuity (iPhone Duo) and iPad multitasking resize:
    // preserve the exact surface the user is viewing across the TabView ↔
    // NavigationSplitView boundary instead of snapping back to Today.
    .onChange(of: usesSplitLayout) { _, isSplit in
      syncRouteAcrossLayoutTransition(toSplit: isSplit)
    }
    // Shared task views navigate through the ONE NavigationState path
    // (project drill-ins, smart-list jumps); ContentView's stack renders it
    // on the Tasks tab. A route landing while a filter tab is frontmost
    // must move selection — the tab-bar twin of RootTabView's pendingTab
    // forwarding.
    //
    // Today and Upcoming ARE tabs, so a route to either switches to that tab
    // and is then dropped from the shared path. Leaving it there also pushed a
    // second copy of the list inside the Tasks tab: back on Tasks you landed in
    // a duplicate Today instead of the Tasks home, and that hidden copy could
    // consume a search reveal meant for the tab you were looking at.
    .onChange(of: nav.path) { _, path in
      guard !usesSplitLayout, let last = path.last else { return }
      switch last {
      case .filter(.today):
        selection = .today
        nav.path = []
      case .filter(.upcoming):
        selection = .upcoming
        nav.path = []
      default:
        selection = .tasks
      }
    }
    #else
    ContentView()
    #endif
  }

  #if os(iOS)
  /// Keep the user's active view aligned when crossing compact ↔ split
  /// (folding/unfolding iPhone Duo or resizing an iPad window).
  private func syncRouteAcrossLayoutTransition(toSplit: Bool) {
    if toSplit {
      switch selection {
      case .today:
        nav.path = [.filter(.today)]
      case .upcoming:
        nav.path = [.filter(.upcoming)]
      case .tasks:
        if nav.path.isEmpty { nav.path = [.filter(.today)] }
      case .newTask:
        if nav.path.isEmpty { nav.path = [.filter(.today)] }
      }
    } else {
      switch nav.path.last {
      case .filter(.today):
        selection = .today
        nav.path = []
      case .filter(.upcoming):
        selection = .upcoming
        nav.path = []
      case .some:
        selection = .tasks
      case nil:
        break
      }
    }
  }
  #endif

  #if os(iOS)
  /// User tab-bar selection bridge:
  /// - Tapping the detached `+` (`newTask`) presents `SeptaskQuickAdd` without
  ///   switching away from the active list (fallback if a tap hits the native
  ///   tab directly, e.g. via VoiceOver or at the very outer edge).
  /// - Tapping `Tasks` (whether switching from Today/Upcoming or re-tapping
  ///   Tasks) always clears `nav.path` so the Tasks tab lands at its top-level
  ///   index rather than staying trapped inside a previously pushed folder.
  /// - Switching to Today or Upcoming clears any stale Tasks stack route.
  ///
  /// Programmatic navigation (e.g. tapping a project from Quick Find or a task
  /// row) sets `selection = .tasks` directly in `.onChange(of: nav.path)` and
  /// bypasses this setter so the pushed route is preserved.
  private var tabSelection: Binding<SeptaskTab> {
    Binding(
      get: { selection },
      set: { tapped in
        switch tapped {
        case .newTask:
          Haptics.tap()
          nav.presentAddInfo(section: .tasks)
        case .tasks:
          if !nav.path.isEmpty {
            nav.path = []
          }
          selection = .tasks
        case .today, .upcoming:
          if !nav.path.isEmpty {
            nav.path = []
          }
          selection = tapped
        }
      }
    )
  }

  /// Standard iOS 26 `TabView` with the native detached `+` slot (`role: .search`)
  /// so the 3-tab pill narrows cleanly alongside `+` when expanded and collapses
  /// symmetrically opposite `+` when minimized on scroll. Because SwiftUI does
  /// not expose `.draggable` on a system `Tab`, a transparent circular hit-target
  /// sits directly over the detached `+` slot to provide native drag-and-drop.
  private var systemTabView: some View {
    ZStack(alignment: .bottomTrailing) {
      TabView(selection: tabSelection) {
        // Septask has no section colors: the bar, the tabs and their content
        // all take the platform accent (no `.tint` on the TabView).
        Tab("Tasks", systemImage: "checkmark", value: SeptaskTab.tasks) {
          ContentView()
        }
        Tab("Today", systemImage: "sun.max.fill", value: SeptaskTab.today) {
          NavigationStack { TaskListView(filter: .today) }.tint(theme.accent)
        }
        Tab("Upcoming", systemImage: "calendar", value: SeptaskTab.upcoming) {
          NavigationStack { TaskListView(filter: .upcoming) }.tint(theme.accent)
        }
        Tab("New Task", systemImage: "plus",
            value: SeptaskTab.newTask, role: .search) {
          Color.clear
        }
      }
      .tabBarMinimizeBehavior(.onScrollDown)

      magicPlusDragOverlay
        .padding(.trailing, 18)
        .padding(.bottom, 18)
        .ignoresSafeArea(.all, edges: .bottom)
    }
  }

  /// Transparent Magic Plus hit-target aligned over the system `TabView`'s
  /// detached trailing `+` circle:
  /// - Tap: opens `SeptaskQuickAdd` without leaving the active tab.
  /// - Press-and-drag: carries `TaskDragIDs.newTask` through native iOS drag
  ///   and drop into any `TaskReorderDrop`, `TaskMoveDrop`, or `SidebarTaskDrop`.
  /// Uses a 0.001-opacity fill so UIKit's `UIDragInteraction` always hit-tests
  /// it reliably while the underlying system Liquid Glass circle renders the UI.
  private var magicPlusDragOverlay: some View {
    Button {
      Haptics.tap()
      nav.presentAddInfo(section: .tasks)
    } label: {
      Circle()
        .fill(Color.primary.opacity(0.001))
        .frame(width: 64, height: 64)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .contentShape(.dragPreview, Circle())
    .accessibilityHidden(true)
    .draggable(TaskDragIDs.newTask) {
      Image(systemName: "plus")
        .scaledFont(size: 20, weight: .semibold)
        .foregroundStyle(Color.accentColor)
        .frame(width: 52, height: 52)
        .background(.regularMaterial, in: Circle())
        .contentShape(.dragPreview, Circle())
    }
  }
  #endif
}

/// Quick-add sheet: a fresh router per presentation so the draft never
/// leaks between opens. Sizing comes from the host's `septenaModalSheet`.
///
/// The SAME `AddTaskPage` Septena's quick-add palette shows, in its
/// self-hosted mode: Septena feeds the page's query from `AddInfoSheet`'s
/// search bar, which Septask doesn't compile, so here the page draws its own
/// focused title field plus Cancel / Add, and files to the Inbox. (Presenting
/// the page bare used to leave the sheet with no text field at all.)
private struct SeptaskQuickAdd: View {
  @State private var router = AddInfoRouter()

  var body: some View {
    NavigationStack {
      AddTaskPage(router: router, hostsTitleField: true, forcesInbox: true)
        .navigationTitle("New Task")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
  }
}
