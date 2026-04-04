import SwiftUI

// ─── Task Detail View ─────────────────────────────────────────────────────────

struct TaskDetailView: View {
  let task: EngageTask
  @EnvironmentObject var client: ConvexClient
  @EnvironmentObject var nav: NavigationState
  @State private var comments: [Comment] = []
  @State private var newComment = ""
  @State private var isEditing = false
  @State private var editedTitle: String = ""
  @State private var editedNotes: String = ""

  var body: some View {
    List {
      // ── 1. Agent Thinking Bubble ─────────────────────────────────────
      if let note = task.agentNote, !note.isEmpty {
        Section {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "brain")
              .font(.caption)
              .foregroundStyle(.blue)
              .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
              Text(note)
                .font(.callout)
                .foregroundStyle(.primary)
              if task.confidence > 0 {
                confidenceBadge
              }
            }
          }
          .padding(.vertical, 2)
        } header: {
          Text("Agent Thinking")
        }
      }

      // ── 2. Human Review Banner ────────────────────────────────────────
      if task.needsHumanReview {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.title2)
                .foregroundStyle(.orange)
              VStack(alignment: .leading, spacing: 2) {
                Text("Awaiting your review")
                  .font(.subheadline)
                  .fontWeight(.medium)
                if let ctx = task.agentContext, !ctx.isEmpty {
                  Text(ctx)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }

            HStack(spacing: 12) {
              Button("Accept") { acceptTask() }
                .buttonStyle(.borderedProminent)
                .tint(.green)

              Button("Dismiss") { dismissTask() }
                .buttonStyle(.bordered)

              Button {
                // Focus comment field
              } label: {
                Label("Reply", systemImage: "bubble.left")
              }
              .buttonStyle(.bordered)
            }
          }
          .padding(.vertical, 6)
        }
      }

      // ── Header ───────────────────────────────────────────────────────
      Section {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            originBadge
            Text(task.title)
              .font(.title2)
              .fontWeight(.semibold)
            Spacer()
            if task.priority > 0 { priorityLabel }
          }

          HStack {
            statusBadge
            if let due = task.due {
              Label(EngageDateFormatter.relative(due), systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(dueColor(task.due))
            }
            if task.isRecurring {
              Label(task.repeatRule ?? "", systemImage: "repeat")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      // ── Notes ─────────────────────────────────────────────────────────
      if let notes = task.notes, !notes.isEmpty {
        Section("Notes") {
          Text(notes)
            .font(.body)
        }
      }

      // ── Checklist ─────────────────────────────────────────────────────
      if !task.checklist.isEmpty {
        Section("Checklist") {
          ForEach(task.checklist) { item in
            HStack {
              Button { toggleChecklistItem(item) } label: {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                  .foregroundStyle(item.done ? .green : .secondary)
              }
              .buttonStyle(.plain)
              Text(item.title)
                .strikethrough(item.done)
              Spacer()
            }
          }
        }
      }

      // ── 3. Comments ────────────────────────────────────────────────────
      Section("Comments") {
        ForEach(comments) { comment in
          CommentRowView(
            comment: comment,
            onResolve: task.origin == .human ? { resolved in
              resolveComment(comment, resolved: resolved)
            } : nil
          )
        }

        HStack {
          TextField("Add a comment…", text: $newComment)
          Button("Send") { addComment() }
            .disabled(newComment.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }

      // ── Metadata ──────────────────────────────────────────────────────
      Section("Details") {
        LabeledContent("Created by", value: task.createdBy)
        if let completedBy = task.completedBy {
          LabeledContent("Completed by", value: completedBy)
        }
        if let conclusionRule = task.conclusionRule {
          LabeledContent("Conclusion rule", value: conclusionRule)
        }
        if task.origin == .agent && task.confidence > 0 {
          LabeledContent("Agent confidence", value: confidenceLabel)
        }
      }

      // ── Actions ───────────────────────────────────────────────────────
      Section {
        Button { completeTask() } label: {
          Label("Mark as Complete", systemImage: "checkmark.circle")
        }
        .disabled(task.status == .completed)

        Button { cancelTask() } label: {
          Label("Cancel Task", systemImage: "xmark.circle")
        }
        .foregroundStyle(.red)
        .disabled(task.status == .cancelled)

        Button { assignToAgent() } label: {
          Label("Assign to Agent", systemImage: "brain")
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle(task.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Edit") {
          editedTitle = task.title
          editedNotes = task.notes ?? ""
          isEditing = true
        }
      }
    }
    .sheet(isPresented: $isEditing) {
      NavigationStack {
        Form {
          TextField("Title", text: $editedTitle)
          TextField("Notes", text: $editedNotes, axis: .vertical)
            .lineLimit(3...8)
        }
        .navigationTitle("Edit Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { isEditing = false }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { saveEdits() }
          }
        }
      }
      .presentationDetents([.medium])
    }
    .task { await loadComments() }
  }

  // ─── Subviews ─────────────────────────────────────────────────────────────

  @ViewBuilder
  private var originBadge: some View {
    if task.origin == .agent {
      Image(systemName: "brain")
        .foregroundStyle(.blue)
    } else {
      Image(systemName: "person")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    Text(task.status.rawValue.capitalized)
      .font(.caption)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(task.status == .completed ? Color.green.opacity(0.2) : Color.secondary.opacity(0.2))
      .foregroundStyle(task.status == .completed ? .green : .secondary)
      .clipShape(Capsule())
  }

  @ViewBuilder
  private var priorityLabel: some View {
    HStack(spacing: 2) {
      ForEach(0..<task.priority, id: \.self) { _ in
        Image(systemName: "exclamationmark")
          .font(.caption2)
      }
    }
    .foregroundStyle(task.priority == 3 ? .red : .orange)
  }

  @ViewBuilder
  private var confidenceBadge: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(confidenceColor)
        .frame(width: 6, height: 6)
      Text(confidenceLabel)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private var confidenceColor: Color {
    switch task.confidence {
    case 3: return .green
    case 2: return .orange
    case 1: return .red
    default: return .clear
    }
  }

  private var confidenceLabel: String {
    switch task.confidence {
    case 3: return "High confidence"
    case 2: return "Medium confidence"
    case 1: return "Low confidence"
    default: return "No confidence"
    }
  }

  private func dueColor(_ date: Date?) -> Color {
    guard let date else { return .secondary }
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return .primary }
    if date < Date() { return .red }
    return .secondary
  }

  // ─── Actions ─────────────────────────────────────────────────────────────

  private func loadComments() async {
    do { comments = try await client.taskComments(taskId: task.id) } catch {}
  }

  private func addComment() {
    let body = newComment.trimmingCharacters(in: .whitespaces)
    guard !body.isEmpty else { return }
    Task {
      try? await client.taskAddComment(taskId: task.id, actor: "human", body: body)
      newComment = ""
      await loadComments()
    }
  }

  private func resolveComment(_ comment: Comment, resolved: Bool) {
    Task {
      try? await client.resolveComment(id: comment.id, resolved: resolved)
      await loadComments()
    }
  }

  private func toggleChecklistItem(_ item: ChecklistItem) {
    let updated = task.checklist.map { $0.id == item.id ? ChecklistItem(id: $0.id, title: $0.title, done: !$0.done) : $0 }
    Task {
      try? await client.taskUpdate(
        id: task.id,
        patch: ["checklist": updated.map { ["id": $0.id, "title": $0.title, "done": $0.done] }],
        actor: "human"
      )
    }
  }

  private func saveEdits() {
    Task {
      try? await client.taskUpdate(id: task.id, patch: ["title": editedTitle, "notes": editedNotes], actor: "human")
      isEditing = false
    }
  }

  private func completeTask() {
    Task { try? await client.taskComplete(id: task.id, completedBy: "human") }
  }

  private func cancelTask() {
    Task { try? await client.taskCancel(id: task.id, actor: "human") }
  }

  private func assignToAgent() {
    Task { try? await client.taskAssign(id: task.id, owner: "agent", agentAcknowledged: false, actor: "human") }
  }

  private func acceptTask() {
    Task { try? await client.taskUpdate(id: task.id, patch: ["needsHumanReview": false], actor: "human") }
  }

  private func dismissTask() {
    Task { try? await client.taskCancel(id: task.id, actor: "human") }
  }
}

// ─── Comment Row ───────────────────────────────────────────────────────────────

struct CommentRowView: View {
  let comment: Comment
  var onResolve: ((Bool) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        actorIcon
        Text(comment.actor == "human" ? "You" : comment.actor)
          .font(.caption)
          .fontWeight(.medium)
        Spacer()
        Text(EngageDateFormatter.relative(comment.createdAt))
          .font(.caption2)
          .foregroundStyle(.tertiary)
        if comment.resolved {
          Image(systemName: "checkmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(.green)
        }
      }

      Text(comment.body)
        .font(.body)
        .opacity(comment.resolved ? 0.5 : 1.0)
        .strikethrough(comment.resolved)

      if let onResolve {
        Button {
          onResolve(!comment.resolved)
        } label: {
          Text(comment.resolved ? "Unresolve" : "Resolve")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .opacity(comment.resolved ? 0.6 : 1.0)
  }

  @ViewBuilder
  private var actorIcon: some View {
    if comment.actor == "human" {
      Image(systemName: "person.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Image(systemName: "brain")
        .font(.caption)
        .foregroundStyle(.blue)
    }
  }
}
