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
        // Consistent home-page chrome across Week / Next / Tasks:
        //   • top-left "…" menu (Settings today; room to grow)
        //   • top-right magnifyingglass → universal Quick Find sheet
        .toolbar { homeToolbar }
    }
  }

  @ToolbarContentBuilder
  private var homeToolbar: some ToolbarContent {
    #if os(iOS)
    ToolbarItem(placement: .topBarLeading) { homeMenu }
    ToolbarItem(placement: .topBarTrailing) { homeSearch }
    #else
    ToolbarItem(placement: .primaryAction) { homeMenu }
    ToolbarItem(placement: .primaryAction) { homeSearch }
    #endif
  }

  private var homeMenu: some View {
    Menu {
      Button {
        nav.showSettings = true
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .accessibilityLabel("More")
  }

  private var homeSearch: some View {
    Button { nav.showQuickFind = true } label: {
      Image(systemName: "magnifyingglass")
    }
    .accessibilityLabel("Search")
  }
}
