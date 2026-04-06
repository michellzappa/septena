import SwiftUI

// ─── Logbook View ──────────────────────────────────────────────────────────────
// Shows completed tasks log.

struct LogbookView: View {
    @EnvironmentObject var client: AtaskClient

    var body: some View {
        Text("Logbook")
            .font(.title)
            .navigationTitle("Logbook")
    }
}
