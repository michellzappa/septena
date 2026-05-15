import SwiftUI

@main
struct EngageApp: App {
  @State private var clientProvider = ClientProvider.shared
  @State private var navigation = NavigationState()
  @State private var theme = SectionTheme()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(clientProvider.client)
        .environment(navigation)
        .environment(theme)
        .task { await theme.refresh(from: clientProvider.client) }
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
  var showingQuickEntry = false

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
      .sheet(isPresented: $nav.showingQuickEntry) {
        QuickEntryView()
      }
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
  private func stackLayout(path: Binding<[Route]>) -> some View {
    NavigationStack(path: path) {
      SidebarRootView()
        .navigationDestination(for: Route.self) { destination(for: $0) }
    }
  }

  // iPad regular / macOS: two-column. Sidebar stays put, detail navigates.
  private func splitLayout(path: Binding<[Route]>) -> some View {
    @Bindable var nav = nav
    return NavigationSplitView(columnVisibility: $nav.sidebarVisibility) {
      SidebarRootView()
    } detail: {
      NavigationStack(path: path) {
        TaskListView(filter: .today)
          .padding(.horizontal, Theme.listLeadingInset)
          .background(Theme.paperBackground)
          // macOS 26 paints toolbar items as Liquid Glass pills floating
          // over the content (Reminders / System Settings look). Letting
          // the toolbar render — instead of hiding it as before — restores
          // that look; the root has no back button so there's no chrome to
          // hide. Push destinations below get the back button automatically.
          .navigationDestination(for: Route.self) { route in
            // `.id(route)` forces a fresh view instance whenever the route
            // changes — critical for going .project(A) → .project(B) on macOS
            // where NavigationStack would otherwise reuse the same detail view
            // and leave its @State bound to the previous project.
            destination(for: route)
              .id(route)
              .padding(.horizontal, Theme.listLeadingInset)
              .background(Theme.paperBackground)
          }
      }
    }
  }

  @ViewBuilder
  private func destination(for route: Route) -> some View {
    switch route {
    case .filter(let f):  TaskListView(filter: f)
    case .next:           NextView()
    case .project(let p): ProjectDetailView(project: p)
    case .area(let a):    AreaDetailView(area: a)
    case .settings:       ServerConfigView()
    case .remindersImport: RemindersImportView()
    }
  }
}
