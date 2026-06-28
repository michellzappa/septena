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
        // Unified three-slot chrome (docs/PAGE_CHROME_SPEC.md): gear → Settings
        // (leading, constant), "···" → page-local rows (here just the Next
        // preferences deep-link), "+" → Add-Info picker (Next is a time-view, so
        // its "+" logs into any section). The Next-Settings deep-link rides
        // `NavigationState`: macOS opens the Settings window at that pane, iOS
        // forwards it through the shared settings sheet (see RootTabView).
        .pageChrome(
          id: "next",
          title: "Next",
          localActions: {
            AnyView(
              Button {
                nav.settingsDestination = .nextFeed
                nav.showSettings = true
              } label: {
                Label("Next Settings", systemImage: "arrow.forward.circle")
              }
            )
          },
          add: .addInfo
        )
    }
  }
}
