import SwiftUI

// Top-level shell for Septena Cloud — four peer tabs, each a self-contained
// module. Week is the synthesizing dashboard, Next is the merged daily
// checklist, Tasks is the existing iOS task app embedded verbatim, Search
// is Quick Find promoted from a sheet to a destination. Engage-app's
// `ContentView` (sidebar + task list) lives inside the Tasks tab unchanged
// so we can iterate on the new tabs without breaking the daily-driver UX.

enum SeptenaTab: Hashable { case week, next, tasks }

// Shared selection so tiles deep inside the Week dashboard can switch tabs
// (e.g. Tasks tile → Tasks tab). Injected via .environment on the TabView.
@Observable final class TabSelection {
  var current: SeptenaTab = .week
}

struct RootTabView: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  @State private var tabSelection = TabSelection()

  var body: some View {
    @Bindable var nav = nav
    TabView(selection: Binding(get: { tabSelection.current },
                               set: { tabSelection.current = $0 })) {
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
        .tag(SeptenaTab.week)

      NextDashboardView()
        .tabItem { Label("Next", systemImage: "arrow.right") }
        .tag(SeptenaTab.next)

      ContentView()
        .tabItem { Label("Tasks", systemImage: "checkmark") }
        .tag(SeptenaTab.tasks)
    }
    .tint(theme.accent)
    .environment(tabSelection)
    // App-global Settings sheet. Lives at the TabView level so the gear
    // on Week / Next opens it just like the sidebar row in Tasks does.
    .sheet(isPresented: $nav.showSettings) {
      SettingsView()
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 460)
        #endif
    }
    // Training session sheet — mounted at the tab root so ⌘K's "Start
    // training" rows present cleanly from any tab, and so the Start
    // button inside the Week tab's Training destination can stack a
    // second sheet on top without dismissing the dashboard.
    .sheet(isPresented: $nav.showTrainingSession) {
      TrainingSessionView()
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 560, minHeight: 600)
        #endif
    }
  }
}
