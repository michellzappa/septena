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
        .tabItem {
          // Brand glyph (7 dots), oversized vs the other tabs to anchor the
          // bar. .resizable + explicit frame survives the tabItem clamp on
          // iOS 18+; .imageScale fine-tunes the SF-symbol tabs to feel
          // visually smaller than the glyph.
          Label {
            Text("Week")
          } icon: {
            Image("Discs")
              .renderingMode(.template)
              .resizable()
              .scaledToFit()
              .frame(width: 30, height: 30)
          }
        }
        .tag(Tab.week)

      NextDashboardView()
        .tabItem {
          Label {
            Text("Next")
          } icon: {
            Image(systemName: "arrow.right").imageScale(.small)
          }
        }
        .tag(Tab.next)

      ContentView()
        .tabItem {
          Label {
            Text("Tasks")
          } icon: {
            Image(systemName: "checkmark").imageScale(.small)
          }
        }
        .tag(Tab.tasks)

      SearchTabView()
        .tabItem {
          Label {
            Text("Search")
          } icon: {
            Image(systemName: "magnifyingglass").imageScale(.small)
          }
        }
        .tag(Tab.search)
    }
    .tint(theme.accent)
  }
}
