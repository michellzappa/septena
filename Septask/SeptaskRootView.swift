import SwiftUI

/// Septask's top-level tabs (iPhone). Browse hosts the full sidebar module;
/// the other three are the smart lists as first-class tabs.
enum SeptaskTab: Hashable {
  case inbox, today, upcoming, browse
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
    // on the Browse tab. A route landing while a filter tab is frontmost
    // must move selection — the tab-bar twin of RootTabView's pendingTab
    // forwarding.
    .onChange(of: nav.path) { _, path in
      guard hSize == .compact, let last = path.last else { return }
      switch last {
      case .project, .area:    selection = .browse
      case .filter(.triage):   selection = .inbox
      case .filter(.today):    selection = .today
      case .filter(.upcoming): selection = .upcoming
      case .filter, .next:     selection = .browse
      }
    }
    #else
    ContentView()
    #endif
  }

  #if os(iOS)
  /// Standard iOS 26 `TabView`, exactly the full app's pattern
  /// (RootTabView.systemTabView): `.tabItem` labels, system minimize
  /// behavior, accent tint.
  private var systemTabView: some View {
    TabView(selection: $selection) {
      NavigationStack { TaskListView(filter: .triage) }
        .tabItem { Label("Inbox", systemImage: "tray.full") }
        .tag(SeptaskTab.inbox)

      NavigationStack { TaskListView(filter: .today) }
        .tabItem { Label("Today", systemImage: "sun.max.fill") }
        .tag(SeptaskTab.today)

      NavigationStack { TaskListView(filter: .upcoming) }
        .tabItem { Label("Upcoming", systemImage: "calendar") }
        .tag(SeptaskTab.upcoming)

      ContentView()
        .tabItem { Label("Browse", systemImage: "list.bullet") }
        .tag(SeptaskTab.browse)
    }
    .tabBarMinimizeBehavior(.onScrollDown)
    .tint(theme.accent)
  }
  #endif
}
