import SwiftUI
import SwiftData

@main
struct EngageApp: App {
  @State private var clientProvider = ClientProvider.shared
  @State private var navigation = NavigationState()
  @State private var theme = SectionTheme()
  private let localStore = LocalStore.shared

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(clientProvider.client)
        .environment(navigation)
        .environment(theme)
        .modelContainer(localStore.container)
        .task {
          await theme.refresh(from: clientProvider.client)
          let syncer = Syncer(client: clientProvider.client,
                              context: localStore.container.mainContext)
          await syncer.pullAll()
        }
        .onAppear {
          #if canImport(UIKit)
          UITableView.appearance().keyboardDismissMode = .interactive
          #endif
        }
    }
    // macOS: drop the "Septena" title strip. Traffic lights remain — the
    // window chrome collapses into the toolbar area, giving the sidebar /
    // detail content the full height like the reference design does.
    #if os(macOS)
    .windowStyle(.hiddenTitleBar)
    #endif
    // ⌘1-4 jump to the smart lists. compact: 1=Inbox, 2=Today, 3=Upcoming,
    // 4=Unscheduled. Sets nav.path to the route directly so it works from
    // anywhere in the app, including detail screens.
    .commands {
      CommandMenu("Go") {
        Button("Inbox")       { navigation.path = [.filter(.inbox)] }
          .keyboardShortcut("1", modifiers: .command)
        Button("Today")       { navigation.path = [.filter(.today)] }
          .keyboardShortcut("2", modifiers: .command)
        Button("Next")        { navigation.path = [.next] }
          .keyboardShortcut("3", modifiers: .command)
        Button("Upcoming")    { navigation.path = [.filter(.upcoming)] }
          .keyboardShortcut("4", modifiers: .command)
        Button("Unscheduled") { navigation.path = [.filter(.unscheduled)] }
          .keyboardShortcut("5", modifiers: .command)
      }
      // ⌘/ toggles the sidebar. Lives in the standard View > Sidebar group
      // so macOS shows it alongside the built-in column-visibility items.
      CommandGroup(after: .sidebar) {
        Button(navigation.sidebarVisibility == .detailOnly
               ? "Show Sidebar" : "Hide Sidebar") {
          navigation.sidebarVisibility =
            navigation.sidebarVisibility == .detailOnly ? .all : .detailOnly
        }
        .keyboardShortcut("/", modifiers: .command)
      }
    }
  }
}

// MARK: - Routes

enum Route: Hashable {
  case filter(TaskFilter)
  case next
  case project(Project)
  case area(Area)
  case settings
  case remindersImport
}

// MARK: - Navigation state

@MainActor
@Observable
final class NavigationState {
  var path: [Route] = []
  /// One-shot trigger: when set to true, the currently-visible
  /// TaskListView starts a new inline task (same flow as ⌘N) on its
  /// next render. TaskListView resets it to false after consuming. Used
  /// by toolbar `+` actions and the sidebar Menu's New To-Do entry, so
  /// 'new task' never opens a modal sheet — always inline, like Things.
  var shouldStartCreating = false

  /// macOS sidebar visibility — toggled by ⌘/. `.all` shows both columns,
  /// `.detailOnly` collapses the sidebar so detail content runs edge-to-edge.
  var sidebarVisibility: NavigationSplitViewVisibility = .all

  /// Persisted base URL — UserDefaults-backed, mirrored from ClientProvider.
  var serverURL: String = UserDefaults.standard.string(forKey: "septena.serverURL")
    ?? SeptenaClient.default.absoluteString
}

// MARK: - Content view

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
      NavigationStack {
        destination(for: route)
          .padding(.horizontal, Theme.listLeadingInset)
          .background(Theme.paperBackground)
      }
    }
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
    case .settings:       ServerConfigView()
    case .remindersImport: RemindersImportView()
    }
  }
}
