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
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button { nav.showAddInfo = true } label: {
              Image(systemName: "plus")
            }
            .accessibilityLabel("Add Info")
          }
        }
    }
  }
}
