import SwiftUI

// ─── Task Detail View ──────────────────────────────────────────────────────────
// Full task view with agent note, comments, checklist.

struct TaskDetailView: View {
    let task: EngageTask
    @EnvironmentObject var client: AtaskClient

    var body: some View {
        Text(task.title)
            .font(.title2)
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
