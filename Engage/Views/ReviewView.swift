import SwiftUI

// ─── Review View ────────────────────────────────────────────────────────────────
// Shows tasks flagged by agents that need human review.

struct ReviewView: View {
    @EnvironmentObject var client: AtaskClient

    var body: some View {
        Text("Review")
            .font(.title)
            .navigationTitle("Review")
    }
}
