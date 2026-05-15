import SwiftUI

@main
struct EngageApp: App {
  @StateObject private var clientProvider = ClientProvider.shared
  @StateObject private var navigation = NavigationState()
  @StateObject private var theme = SectionTheme()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(clientProvider.client)
        .environmentObject(navigation)
        .environmentObject(theme)
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
final class NavigationState: ObservableObject {
  @Published var path: [Route] = []
  @Published var showingQuickEntry = false

  /// Persisted base URL — UserDefaults-backed, mirrored from ClientProvider.
  @Published var serverURL: String = UserDefaults.standard.string(forKey: "septena.serverURL")
    ?? SeptenaClient.default.absoluteString
}

// MARK: - Content view

struct ContentView: View {
  @EnvironmentObject var nav: NavigationState
  @EnvironmentObject var theme: SectionTheme

  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  var body: some View {
    layout
      .tint(theme.accent)
      .sheet(isPresented: $nav.showingQuickEntry) {
        QuickEntryView()
      }
  }

  @ViewBuilder
  private var layout: some View {
    #if os(macOS)
    splitLayout
    #else
    if hSize == .regular {
      splitLayout
    } else {
      stackLayout
    }
    #endif
  }

  // iPhone / compact: sidebar IS the root, routes push onto the stack.
  private var stackLayout: some View {
    NavigationStack(path: $nav.path) {
      SidebarRootView()
        .navigationDestination(for: Route.self) { destination(for: $0) }
    }
  }

  // iPad regular / macOS: two-column. Sidebar stays put, detail navigates.
  private var splitLayout: some View {
    NavigationSplitView {
      SidebarRootView()
    } detail: {
      NavigationStack(path: $nav.path) {
        TaskListView(filter: .today)
          .padding(.leading, Theme.listLeadingInset)
          .background(Theme.paperBackground)
          // macOS chromeless: drop the NavigationStack's back-button row
          // and the divider underneath it. Content flows to the top of the
          // detail pane like the reference design does. Sidebar still drives nav by
          // replacing nav.path, so we don't need a back button — the user
          // navigates by tapping the sidebar instead.
          #if os(macOS)
          .toolbar(.hidden)
          #endif
          .navigationDestination(for: Route.self) { route in
            // `.id(route)` forces a fresh view instance whenever the route
            // changes — critical for going .project(A) → .project(B) on macOS
            // where NavigationStack would otherwise reuse the same detail view
            // and leave its @State bound to the previous project.
            destination(for: route)
              .id(route)
              .padding(.leading, Theme.listLeadingInset)
              .background(Theme.paperBackground)
              #if os(macOS)
              .toolbar(.hidden)
              #endif
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
