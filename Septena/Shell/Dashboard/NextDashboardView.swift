import SwiftUI

// Next tab — the merged daily checklist that used to live under the Tasks
// sidebar as a smart list. Embeds the existing NextView, which renders its
// own ScreenTitle ("Next" + arrow icon), so no extra navigationTitle here.

struct NextDashboardView: View {
  @Environment(NavigationState.self) private var nav

  var body: some View {
    NavigationStack {
      NextView()
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Shared home-landing chrome: the top-left "…" menu, identical to
        // Week / Coach. The `extra` row sits above the shared Settings item
        // and deep-links to the Next preferences pane (suggestions,
        // carry-over, which sections appear). The deep-link rides
        // `NavigationState`: macOS opens the Settings window at that pane,
        // iOS forwards it through the shared settings sheet (see RootTabView).
        .homeChrome {
          Button {
            nav.settingsDestination = .nextFeed
            nav.showSettings = true
          } label: {
            Label("Next Settings", systemImage: "arrow.forward.circle")
          }
        }
    }
  }
}
