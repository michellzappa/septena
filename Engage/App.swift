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
          // Configure appearance
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

  enum Tab: String, CaseIterable, Identifiable {
    case inbox, today, upcoming, anytime, projects, areas, logbook, review
    var id: String { rawValue }
  }
}

// ─── Content View ─────────────────────────────────────────────────────────────

struct ContentView: View {
  @EnvironmentObject var client: ConvexClient
  @EnvironmentObject var nav: NavigationState

  var body: some View {
    NavigationSplitView {
      SidebarView()
    } content: {
      TaskListView(filter: nav.selectedTab.filter)
    } detail: {
      if let task = nav.selectedTask {
        TaskDetailView(task: task)
      } else {
        ContentUnavailableView(
          "Select a task",
          systemImage: "checkmark.circle",
          description: Text("Choose a task from the list to see details")
        )
      }
    }
    .sheet(isPresented: $nav.showingQuickEntry) {
      QuickEntryView()
    }
    .sheet(isPresented: $nav.showingAgentPanel) {
      AgentPanelView()
    }
    .keyboardShortcut("n", modifiers: .command)
  }
}

// ─── Sidebar ─────────────────────────────────────────────────────────────────

struct SidebarView: View {
  @EnvironmentObject var nav: NavigationState

  var body: some View {
    List(NavigationState.Tab.allCases, selection: $nav.selectedTab) { tab in
      Label(tab.rawValue.capitalized, systemImage: tab.icon)
        .tag(tab)
    }
    .listStyle(.sidebar)
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
    .navigationTitle("Engage")
  }
}

extension NavigationState.Tab {
  var filter: TaskFilter {
    switch self {
    case .inbox: return .inbox
    case .today: return .today
    case .upcoming: return .upcoming(days: 7)
    case .anytime: return .anytime
    case .projects: return .anytime // overridden in ProjectsView
    case .areas: return .anytime    // overridden in AreasView
    case .logbook: return .logbook
    case .review: return .review
    }
  }

  var icon: String {
    switch self {
    case .inbox: return "tray"
    case .today: return "sun.max"
    case .upcoming: return "calendar"
    case .anytime: return "circle"
    case .projects: return "folder"
    case .areas: return "square.grid.2x2"
    case .logbook: return "book.closed"
    case .review: return "exclamationmark.triangle"
    }
  }
}
