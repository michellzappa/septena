import SwiftUI

// ─── Task Detail View ─────────────────────────────────────────────────────────

struct TaskDetailView: View {
  let task: EngageTask
  @EnvironmentObject var client: ConvexClient
  @EnvironmentObject var nav: NavigationState
  @State private var tasks: [EngageTask] = []
  @State private var comments: [Comment] = []
  @State private var newComment = ""
  @State private var isEditing = false
  @State private var editedTitle: String = ""
  @State private var editedNotes: String = ""

  var body: some View {
    List {
      // ── Header ────────────────────────────────────────────────────────────
      Section {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            originBadge
            Text(task.title)
              .font(.title2)
              .fontWeight(.semibold)
            Spacer()
            if task.priority > 0 {
              priorityLabel
            }
          }

          HStack {
            statusBadge
            if let due = task.due {
              Label(EngageDateFormatter.relative(due), systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if task.isRecurring {
              Label(task.repeatRule ?? "", systemImage: "repeat")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      // ── Notes ────────────────────────────────────────────────────────────
      if let notes = task.notes, !notes.isEmpty {
        Section("Notes") {
          Text(notes)
            .font(.body)
        }
      }

      // ── Agent Context ────────────────────────────────────────────────────
      if let agentCtx = task.agentContext, !agentCtx.isEmpty {
        Section("Agent") {
          HStack {
            Image(systemName: "brain")
              .foregroundStyle(.blue)
            Text(agentCtx)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }

      // ── Checklist ─────────────────────────────────────────────────────────
      if !task.checklist.isEmpty {
        Section("Checklist") {
          ForEach(task.checklist) { item in
            HStack {
              Button {
                toggleChecklistItem(item)
              } label: {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                  .foregroundStyle(item.done ? .green : .secondary)
                }
              Text(item.title)
                .strikethrough(item.done)
              Spacer()
            }
          }
        }
      }

      // ── Comments ──────────────────────────────────────────────────────────
      Section("Comments") {
        ForEach(comments) { comment in
          CommentRowView(comment: comment)
        }

        HStack {
          TextField("Add a comment…", text: $newComment)
          Button("Send") {
            addComment()
          }
          .disabled(newComment.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }

      // ── Metadata ─────────────────────────────────────────────────────────
      Section("Details") {
        LabeledContent("Created by", value: task.createdBy)
        if let completedBy = task.completedBy {
          LabeledContent("Completed by", value: completedBy)
        }
        if let conclusionRule = task.conclusionRule {
          LabeledContent("Conclusion rule", value: conclusionRule)
        }
      }

      // ── Actions ──────────────────────────────────────────────────────────
      Section {
        Button {
          completeTask()
        } label: {
          Label("Mark as Complete", systemImage: "checkmark.circle")
        }
        .disabled(task.status == .completed)

        Button {
          cancelTask()
        } label: {
          Label("Cancel Task", systemImage: "xmark.circle")
        }
        .foregroundStyle(.red)
        .disabled(task.status == .cancelled)

        Button {
          assignToAgent()
        } label: {
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
            Button("Save") {
              saveEdits()
            }
          }
        }
      }
      .presentationDetents([.medium])
    }
    .task { await loadComments() }
  }

  @ViewBuilder
  private var originBadge: some View {
    if task.origin == .agent {
      Image(systemName: "brain")
        .foregroundStyle(.blue)
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

  private func loadComments() async {
    do {
      comments = try await client.taskComments(taskId: task.id)
    } catch {
      // non-fatal
    }
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

  private func toggleChecklistItem(_ item: ChecklistItem) {
    // Update via task mutation
    let updated = task.checklist.map { ci in
      ci.id == item.id ? ChecklistItem(id: ci.id, title: ci.title, done: !ci.done) : ci
    }
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
      try? await client.taskUpdate(
        id: task.id,
        patch: ["title": editedTitle, "notes": editedNotes],
        actor: "human"
      )
      isEditing = false
    }
  }

  private func completeTask() {
    Task {
      try? await client.taskComplete(id: task.id, completedBy: "human")
    }
  }

  private func cancelTask() {
    Task {
      try? await client.taskCancel(id: task.id, actor: "human")
    }
  }

  private func assignToAgent() {
    Task {
      try? await client.taskAssign(
        id: task.id,
        owner: "agent",
        agentAcknowledged: false,
        actor: "human"
      )
    }
  }
}

// ─── Comment Row ───────────────────────────────────────────────────────────────

struct CommentRowView: View {
  let comment: Comment
  @EnvironmentObject var client: ConvexClient
  @State private var agents: [Agent] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        if comment.actor == "human" {
          Image(systemName: "person.fill")
            .foregroundStyle(.secondary)
        } else {
          Image(systemName: "brain")
            .foregroundStyle(.blue)
        }
        Text(comment.actor == "human" ? "You" : comment.actor)
          .font(.caption)
          .fontWeight(.medium)
        Spacer()
        Text(EngageDateFormatter.relative(comment.createdAt))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Text(comment.body)
        .font(.body)
    }
    .task { agents = (try? await client.agentsList()) ?? [] }
  }
}
