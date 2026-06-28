import SwiftUI

// Next tab — the merged daily checklist that used to live under the Tasks
// sidebar as a smart list. Embeds the existing NextView, which renders its
// own ScreenTitle ("Next" + arrow icon), so no extra navigationTitle here.

struct NextDashboardView: View {
  var body: some View {
    NavigationStack {
      NextView()
    }
  }
}
