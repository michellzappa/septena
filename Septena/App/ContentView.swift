import SwiftUI

struct ContentView: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme

  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  var body: some View {
    @Bindable var nav = nav
    layout(path: $nav.path)
      .tint(theme.accent)
      // Settings / QuickFind / AddInfo sheets are mounted at the
      // RootTabView level (so they work from Week / Next, not just the
      // Tasks tab which hosts ContentView).
  }

  @ViewBuilder
  private func layout(path: Binding<[Route]>) -> some View {
    #if os(macOS)
    splitLayout(path: path)
    #else
    if hSize == .regular {
      splitLayout(path: path)
    } else {
      stackLayout(path: path)
    }
    #endif
  }

  // iPhone / compact: sidebar IS the root, routes push onto the stack.
  // The app is conceptually flat (selectRoute replaces the path rather
  // than appending), so stack depth is always 1 — the back chevron iOS
  // renders is simply "return to sidebar".
  private func stackLayout(path: Binding<[Route]>) -> some View {
    NavigationStack(path: path) {
      SidebarRootView()
        .navigationDestination(for: Route.self) { destination(for: $0) }
    }
  }

  // iPad regular / macOS: two-column. Sidebar stays put, detail swaps.
  //
  // The app is conceptually flat — sidebar selection always sets
  // `nav.path = [route]` (single element, never pushed onto). So instead of
  // a NavigationStack(path:) that animates a pop+push on every click, the
  // detail pane just renders the current route directly. `.id(route)` keeps
  // each project/area as its own fresh view instance.
  private func splitLayout(path: Binding<[Route]>) -> some View {
    @Bindable var nav = nav
    let route = nav.path.last ?? .filter(.today)
    return NavigationSplitView(columnVisibility: $nav.sidebarVisibility) {
      SidebarRootView()
    } detail: {
      destination(for: route)
        .id(route.id)
        #if os(iOS)
        // Same as the sidebar column: one global overlay toggle on iPad Tasks.
        .toolbar(removing: .sidebarToggle)
        #endif
    }
    .navigationSplitViewStyle(.balanced)
    .iPadReportsNavDepth(id: "tasks", atRoot: true)
    // Split surfaces always show a detail pane, so the sidebar must always
    // have a row selected — seed Today when the path is still empty (launch,
    // or compact → regular resize) and never let it clear back to none.
    .onAppear { ensureSplitTasksSelection() }
    .onChange(of: nav.path) { _, newPath in
      if newPath.isEmpty { nav.path = [.filter(.today)] }
    }
  }

  /// Keep `nav.path` aligned with the detail fallback on iPad regular / macOS.
  private func ensureSplitTasksSelection() {
    if nav.path.isEmpty { nav.path = [.filter(.today)] }
  }

  // Per-route .id is applied INSIDE destination(for:) — TaskListView is
  // intentionally reused across filter swaps (sub-second snap; resets its
  // own session state via .onChange(of: filter)), while Project / Area
  // detail use their entity ids so navigating between two projects gives
  // a fresh view with fresh state.
  @ViewBuilder
  private func destination(for route: Route) -> some View {
    switch route {
    case .filter(let f):  TaskListView(filter: f)
    case .next:           NextView()
    case .project(let p): ProjectDetailView(project: p).id(p.id)
    case .area(let a):    AreaDetailView(area: a).id(a.id)
    }
  }
}
