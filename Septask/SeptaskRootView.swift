import SwiftUI

/// Septask's top-level tabs (iPhone). Home hosts the full sidebar module;
/// Today and Upcoming are first-class smart-list tabs; the trailing `+` is
/// an action, not a destination — it presents quick-add and selection never
/// actually moves to it.
enum SeptaskTab: Hashable {
  case home, today, upcoming, add
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
  @State private var selection: SeptaskTab = .today
  @State private var showQuickAdd = false
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  var body: some View {
    rootLayout
      // Same as RootTabView: resolve the push-vs-sheet rule once at the
      // shell root and publish `\.usesPushNavigation` to every surface.
      .resolvesAdaptiveNavigation()
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
    // on the Home tab. A route landing while a filter tab is frontmost
    // must move selection — the tab-bar twin of RootTabView's pendingTab
    // forwarding.
    .onChange(of: nav.path) { _, path in
      guard hSize == .compact, let last = path.last else { return }
      switch last {
      case .filter(.today):    selection = .today
      case .filter(.upcoming): selection = .upcoming
      default:                 selection = .home
      }
    }
    // Quick-add, presented from the tab bar's separated `+`. AddTaskPage is
    // the same smart-bucketing composer the full app's ⌘K palette hosts —
    // it files into whatever list `nav.path` currently shows.
    .sheet(isPresented: $showQuickAdd) {
      SeptaskQuickAdd()
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
          showQuickAdd = true
        } else {
          selection = newValue
        }
      })) {
      Tab("Home", systemImage: "house.fill", value: SeptaskTab.home) {
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

#if os(iOS)
/// Quick-add sheet: a fresh router per presentation so the draft never
/// leaks between opens. Medium detent first — it's a capture surface.
private struct SeptaskQuickAdd: View {
  @State private var router = AddInfoRouter()

  var body: some View {
    AddTaskPage(router: router)
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
  }
}
#endif
