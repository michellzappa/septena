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

  // Search was a tab; pulled out because it interfered with QuickFindView's
  // sheet-style dismissal expectations. SearchTabView.swift stays so the
  // view is reachable from elsewhere (e.g. a future Settings entry).
  enum Tab: Hashable { case week, next, tasks }

  var body: some View {
    TabView(selection: $selection) {
      WeekDashboardView()
        .tabItem {
          // Custom asset via the standard Label(icon:) initializer.
          // Discs.png is template-rendered so it picks up the tab tint.
          Label {
            Text("Week")
          } icon: {
            Image("Discs").renderingMode(.template)
          }
        }
        .tag(Tab.week)

      NextDashboardView()
        .tabItem { Label("Next", systemImage: "arrow.right") }
        .tag(Tab.next)

      ContentView()
        .tabItem { Label("Tasks", systemImage: "checkmark") }
        .tag(Tab.tasks)
    }
    .tint(theme.accent)
  }
}
