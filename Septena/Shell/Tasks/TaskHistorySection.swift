import SwiftData
import SwiftUI

// The History section of the task composer (edit mode): who changed this
// task and what, newest first, from the task backend's change log
// (`TaskHistory`, SeptenaCore). Collapsed by default; the log loads only when
// the section opens, so opening a task never waits on the network.
// Shown only where the backend owns tasks (`TaskHistory.isAvailable`).
struct TaskHistorySection: View {
  let taskID: String

  @Environment(\.modelContext) private var modelContext
  @State private var expanded = false
  @State private var rows: [TaskHistoryRow] = []
  @State private var loadedFor: String?
  @State private var failed = false

  var body: some View {
    // A VStack, not a Group: `.task` needs a child that always exists
    // (CLAUDE.md Group-modifier trap).
    VStack(alignment: .leading, spacing: 8) {
      if TaskHistory.isAvailable {
        Button {
          expanded.toggle()
          // Each open reads the log again: it may have grown since.
          if !expanded { loadedFor = nil }
        } label: { header }
          .buttonStyle(.plain)
        if expanded { content }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: expanded ? taskID : nil) { await load() }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: expanded ? "chevron.down" : "chevron.right")
        .font(.caption2.weight(.semibold))
      Text("History").font(.subheadline.weight(.semibold))
      Spacer(minLength: 0)
    }
    .foregroundStyle(.secondary)
    .contentShape(Rectangle())
  }

  @ViewBuilder private var content: some View {
    if loadedFor != taskID {
      ProgressView().controlSize(.small)
    } else if failed {
      Text("History did not load.").font(.caption).foregroundStyle(.secondary)
    } else if rows.isEmpty {
      Text("No changes yet.").font(.caption).foregroundStyle(.secondary)
    } else {
      ForEach(rows) { TaskHistoryRowView(row: $0) }
    }
  }

  private func load() async {
    guard expanded, loadedFor != taskID else { return }
    let id = taskID
    do {
      let changes = try await TaskBackendClient.shared.history(taskID: id)
      let lists = StructureCache.snapshot(in: modelContext)
      rows = TaskHistory.rows(changes) { listID in
        lists.projects.first { $0.id == listID }?.title ?? lists.areas.first { $0.id == listID }?.title
      }
      failed = false
    } catch is CancellationError {
      return
    } catch {
      rows = []
      failed = true
    }
    loadedFor = id
  }
}

/// One compact history row: what changed, then who and when.
private struct TaskHistoryRowView: View {
  let row: TaskHistoryRow

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(row.lines, id: \.self) { Text($0).font(.caption).lineLimit(2) }
      Text("\(row.who) · \(TaskHistory.relative(row.date, now: DayClock.appNow))")
        .font(.caption2)
        // Claude's changes carry a heavier label, not a second color.
        .fontWeight(row.byClaude ? .semibold : .regular)
        .foregroundStyle(.secondary)
    }
  }
}
