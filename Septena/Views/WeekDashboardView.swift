import SwiftUI

// Placeholder for the Week module — the synthesizing 7-day timeline lens.
// Matches septena-app's `WeekDashboard`: a vertical scroll of the last 7
// days, each rendered as a per-day timeline that merges tasks done/due
// with habits, chores, supplements, etc. v1 will read real tasks via
// SeptenaClient and mock the rest until other modules exist.

struct WeekDashboardView: View {
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Week")
            .font(.largeTitle.bold())
            .padding(.horizontal)

          Text("7-day timeline lens — coming next. Will mirror the webapp's WeekDashboard: per-day rows with tasks, habits, chores synthesized.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal)

          Spacer(minLength: 200)
        }
        .padding(.top)
      }
      .navigationBarHidden(true)
    }
  }
}
