import SwiftUI

@main
struct EngageApp: App {
  @StateObject private var client = ConvexClient.shared
  @StateObject private var navigation = NavigationState()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(client)
        .environmentObject(navigation)
        .onAppear {
          UITableView.appearance().keyboardDismissMode = .interactive
        }
    }
  }
}

// ─── Navigation State ──────────────────────────────────────────────────────────

@MainActor
final class NavigationState: ObservableObject {
  @Published var selectedTab: Tab = .inbox
  @Published var selectedTask: EngageTask?
  @Published var showingQuickEntry = false
  @Published var showingAgentPanel = false

  enum Tab: Int, CaseIterable, Identifiable {
    case inbox = 0, today, upcoming, anytime, projects, areas, logbook, review
    var id: Int { rawValue }
  }
}

// ─── Content View ─────────────────────────────────────────────────────────────

struct ContentView: View {
  @EnvironmentObject var client: ConvexClient
  @EnvironmentObject var nav: NavigationState

  var body: some View {
    TabView(selection: $nav.selectedTab) {
      TaskListView(filter: .inbox)
        .tabItem {
          Label("Inbox", systemImage: "tray")
        }
        .tag(NavigationState.Tab.inbox)

      TaskListView(filter: .today)
        .tabItem {
          Label("Today", systemImage: "sun.max")
        }
        .tag(NavigationState.Tab.today)

      TaskListView(filter: .upcoming(days: 7))
        .tabItem {
          Label("Upcoming", systemImage: "calendar")
        }
        .tag(NavigationState.Tab.upcoming)

      TaskListView(filter: .anytime)
        .tabItem {
          Label("Anytime", systemImage: "circle")
        }
        .tag(NavigationState.Tab.anytime)

      ProjectsView()
        .tabItem {
          Label("Projects", systemImage: "folder")
        }
        .tag(NavigationState.Tab.projects)

      AreasView()
        .tabItem {
          Label("Areas", systemImage: "square.grid.2x2")
        }
        .tag(NavigationState.Tab.areas)

      LogbookView()
        .tabItem {
          Label("Logbook", systemImage: "book.closed")
        }
        .tag(NavigationState.Tab.logbook)

      ReviewView()
        .tabItem {
          Label("Review", systemImage: "exclamationmark.triangle")
        }
        .tag(NavigationState.Tab.review)
    }
    .sheet(isPresented: $nav.showingQuickEntry) {
      QuickEntryView()
    }
    .sheet(isPresented: $nav.showingAgentPanel) {
      AgentPanelView()
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          nav.showingQuickEntry = true
        } label: {
          Image(systemName: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          nav.showingAgentPanel = true
        } label: {
          Image(systemName: "brain")
        }
      }
    }
    .navigationDestination(for: EngageTask.self) { task in
      TaskDetailView(task: task)
    }
  }
}

// ─── Navigation (no longer needed, replaced by TabView) ────────────────────────
