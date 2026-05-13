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
          UITableView.appearance().keyboardDismissMode = .interactive
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

  var body: some View {
    NavigationStack(path: $nav.path) {
      SidebarRootView()
        .navigationDestination(for: Route.self) { route in
          switch route {
          case .filter(let f):  TaskListView(filter: f)
          case .next:           NextView()
          case .project(let p): ProjectDetailView(project: p)
          case .area(let a):    AreaDetailView(area: a)
          case .settings:       ServerConfigView()
          }
        }
    }
    .tint(theme.accent)
    .sheet(isPresented: $nav.showingQuickEntry) {
      QuickEntryView()
    }
  }
}
