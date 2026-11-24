import SwiftData
import SwiftUI

// The History panel of the task page (edit mode): who changed this task and
// what, newest first, from the task backend's change log (`TaskHistory`,
// SeptenaCore). The History pill on the attribute rail opens it, like the
// Attachments panel (registry `taskAttributes` `history`). It mounts only
// when the pill opens, so opening a task never waits on the network, and
// each open reads the log again. The pill shows only where the backend owns
// tasks (`TaskHistory.isAvailable`).
struct TaskHistoryPanel: View {
  let taskID: String

  @Environment(\.modelContext) private var modelContext
  @State private var rows: [TaskHistoryRow] = []
  @State private var loadedFor: String?
  @State private var failed = false
  /// The `history_edge` upsell under the last row (spec §3.2), when the
  /// server hid older changes for the free plan.
  @State private var edge: RegistryPlanNote?
  @State private var edgeSeen = false
  @State private var showingPlus = false

  var body: some View {
    // A VStack, not a Group: `.task` needs a child that always exists
    // (CLAUDE.md Group-modifier trap).
    VStack(alignment: .leading, spacing: 8) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: taskID) { await load() }
    #if SEPTASK
    .sheet(isPresented: $showingPlus) { SeptaskPlusSheet(upsellID: edge?.id) }
    #endif
  }

  @ViewBuilder private var content: some View {
    if loadedFor != taskID {
      ProgressView().controlSize(.small)
    } else if failed {
      Text("Couldn’t load history.").font(.caption).foregroundStyle(.secondary)
    } else if rows.isEmpty, edge == nil {
      Text("No changes yet.").font(.caption).foregroundStyle(.secondary)
    } else {
      ForEach(rows) { TaskHistoryRowView(row: $0) }
      if let edge { edgeLine(edge) }
    }
  }

  /// A quiet last line: older changes are hidden, one tap to Plus. The
  /// detail shows until the account has seen this moment; after that only
  /// the title and the button stay (spec §7.1).
  private func edgeLine(_ moment: RegistryPlanNote) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(moment.title).font(.caption).foregroundStyle(.secondary)
      if !edgeSeen {
        Text(moment.detail).font(.caption2).foregroundStyle(.secondary)
      }
      #if SEPTASK
      Button(RegistryPlans.Paywall.seePlus) {
        TaskNotices.markUpsellSeen(moment.id, context: modelContext)
        edgeSeen = true
        showingPlus = true
      }
      .font(.caption)
      .buttonStyle(.borderless)
      #endif
    }
  }

  private func load() async {
    guard loadedFor != taskID else { return }
    let id = taskID
    do {
      let page = try await TaskBackendClient.shared.history(taskID: id)
      let lists = StructureCache.snapshot(in: modelContext)
      edge = TaskHistory.edgeUpsell(page)
      edgeSeen = SettingsMirror.upsellsSeen(context: modelContext).contains("history_edge")
      rows = TaskHistory.rows(page.changes) { listID in
        lists.projects.first { $0.id == listID }?.title ?? lists.areas.first { $0.id == listID }?.title
      }
      failed = false
    } catch is CancellationError {
      return
    } catch TaskBackendError.limitReached(let limit) {
      PlanStatus.shared.noteLimitReached(limit)
      rows = []
      if let note = limit.upsellNote {
        edge = note
        edgeSeen = SettingsMirror.upsellsSeen(context: modelContext).contains(note.id)
        failed = false
      } else {
        edge = nil
        failed = true
      }
    } catch {
      rows = []
      edge = nil
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
