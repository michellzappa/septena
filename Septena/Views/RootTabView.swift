import SwiftUI

// Top-level shell for Septena Cloud — four peer tabs, each a self-contained
// module. Week is the synthesizing dashboard, Next is the merged daily
// checklist, Tasks is the existing iOS task app embedded verbatim, Search
// is Quick Find promoted from a sheet to a destination. Engage-app's
// `ContentView` (sidebar + task list) lives inside the Tasks tab unchanged
// so we can iterate on the new tabs without breaking the daily-driver UX.

struct RootTabView: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  @State private var selection: Tab = .week

  enum Tab: Hashable { case week, next, tasks, search }

  var body: some View {
    TabView(selection: $selection) {
      WeekDashboardView()
        .tabItem { Label("Week", systemImage: "square.grid.2x2") }
        .tag(Tab.week)

      NextDashboardView()
        .tabItem { Label("Next", systemImage: "checklist") }
        .tag(Tab.next)

      ContentView()
        .tabItem { Label("Tasks", systemImage: "list.bullet") }
        .tag(Tab.tasks)

      SearchTabView()
        .tabItem { Label("Search", systemImage: "magnifyingglass") }
        .tag(Tab.search)
    }
    .tint(theme.accent)
  }
}
