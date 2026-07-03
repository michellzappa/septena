import SwiftUI

/// Septask's top-level tabs (iPhone). Tasks hosts the full sidebar module —
/// same label and checkmark as Septena's Tasks tab, so the ✓ means "the task
/// module" in both apps; Today and Upcoming are first-class smart-list tabs;
/// the trailing `+` is an action, not a destination — it presents quick-add
/// and selection never actually moves to it.
enum SeptaskTab: Hashable {
  case tasks, today, upcoming, add
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
      // task-relevant subset only. Full-app modals (training, mood, section
      // sheets) have no Septask entry points; if one is ever set anyway the
      // sheet shows empty rather than crashing.
      .sheet(item: $nav.presentedModal) { modal in
        switch modal {
        case .quickFind:
          withEnvironment(QuickFindView())
            .septenaModalSheet(detents: [.medium, .large],
                               macWidth: 560, macHeight: 420)
        case .addInfo:
          // Septask's quick capture IS the task composer — no multi-section
          // palette here (the tasks-only twin of AddInfoSheet).
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
      case .filter(.upcoming): selection = .upcoming
      default:                 selection = .tasks
      }
    }
    #else
    ContentView()
    #endif
  }

  #if os(iOS)
  /// Standard iOS 26 `TabView`, the full app's pattern (RootTabView):
  /// system tab items, minimize-on-scroll, accent tint. The `+` rides the
  /// separated trailing slot; selecting it presents quick-add and the
  /// binding swallows the change so the current tab stays put.
  private var systemTabView: some View {
    TabView(selection: Binding(
      get: { selection },
      set: { newValue in
        if newValue == .add {
          // Route through the shared modal state so the tab-bar `+`, ⌘K,
          // and any future entry point all present the same sheet.
          nav.presentAddInfo(section: .tasks)
        } else {
          selection = newValue
        }
      })) {
      Tab("Tasks", systemImage: "checkmark", value: SeptaskTab.tasks) {
        ContentView()
      }
      Tab("Today", systemImage: "sun.max.fill", value: SeptaskTab.today) {
        NavigationStack { TaskListView(filter: .today) }
      }
      Tab("Upcoming", systemImage: "calendar", value: SeptaskTab.upcoming) {
        NavigationStack { TaskListView(filter: .upcoming) }
      }
      Tab("New To-Do", systemImage: "plus", value: SeptaskTab.add, role: .search) {
        Color.clear
      }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
    .tint(theme.accent)
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
