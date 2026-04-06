import SwiftUI

// ─── Agent Panel View ───────────────────────────────────────────────────────────
// Shows agent status and allows sending messages to agents.

struct AgentPanelView: View {
    @EnvironmentObject var client: AtaskClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text("Agent Panel")
                .navigationTitle("Agent")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
