import SwiftUI

// Placeholder for the Next module — today's merged actionable checklist
// across tasks, habits, chores, supplements. Distinct from the existing
// `NextView` (which is a tasks-only smart list under the Tasks tab).
// Matches septena-app's `NextDashboard`: grouped sections (Today / Late /
// Done), tap-to-complete, swipe-to-defer/skip. v1 reads tasks via the
// already-wired /api/next/items endpoint; other modules mocked until built.

struct NextDashboardView: View {
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Next")
            .font(.largeTitle.bold())
            .padding(.horizontal)

          Text("Merged daily checklist — coming next. Tasks + habits + chores + supplements grouped by Today / Late / Done. Tap to complete, swipe to defer.")
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
