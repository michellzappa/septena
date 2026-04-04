import SwiftUI

// ─── Quick Entry View ─────────────────────────────────────────────────────────

struct QuickEntryView: View {
  @EnvironmentObject var client: ConvexClient
  @EnvironmentObject var nav: NavigationState
  @Environment(\.dismiss) private var dismiss

  @State private var title = ""
  @State private var notes = ""
  @State private var dueDate: Date?
  @State private var priority = 0
  @State private var isSubmitting = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("What needs to be done?", text: $title)
            .font(.title3)
        }

        Section("Notes") {
          TextField("Add notes…", text: $notes, axis: .vertical)
            .lineLimit(2...6)
        }

        Section("When") {
          HStack {
            DatePicker(
              "Due",
              selection: Binding(
                get: { dueDate ?? Date() },
                set: { dueDate = $0 }
              ),
              displayedComponents: [.date]
            )
            if dueDate != nil {
              Button("Clear") {
                dueDate = nil
              }
              .foregroundStyle(.red)
            }
          }

          // Natural language hint
          Text("Try: \"tomorrow\", \"next monday\", \"in 3 days\"")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }

        Section("Priority") {
          Picker("Priority", selection: $priority) {
            Text("None").tag(0)
            Text("Low").tag(1)
            Text("Medium").tag(2)
            Text("High").tag(3)
          }
          .pickerStyle(.segmented)
        }

        if let error = errorMessage {
          Section {
            Text(error)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("New Task")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            submit()
          }
          .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
        }
      }
    }
    .presentationDetents([.medium, .large])
    .interactiveDismissDisabled(isSubmitting)
  }

  private func submit() {
    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    isSubmitting = true
    errorMessage = nil

    Task {
      do {
        // Parse natural language date from title
        var parsedDue = dueDate
        if parsedDue == nil {
          parsedDue = EngageDateParser.parse(title)
        }

        // Parse repeat rule
        let repeatRule = EngageDateParser.parseRepeatRule(title)

        try await client.taskCreate(
          title: title.trimmingCharacters(in: .whitespaces),
          notes: notes.isEmpty ? nil : notes,
          origin: .human,
          owner: "human",
          due: parsedDue,
          priority: priority,
          repeatRule: repeatRule
        )
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
        isSubmitting = false
      }
    }
  }
}

// ─── Agent Panel View ─────────────────────────────────────────────────────────

struct AgentPanelView: View {
  @EnvironmentObject var client: ConvexClient
  @Environment(\.dismiss) private var dismiss
  @State private var memories: [AgentMemoryEntry] = []
  @State private var logEntries: [CollaborationLogEntry] = []
  @State private var isLoading = false

  private let agentId = "agent" // TODO: make configurable

  var body: some View {
    NavigationStack {
      List {
        Section("Recent Thinking") {
          if memories.isEmpty && !isLoading {
            Text("No agent activity yet")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          ForEach(memories) { entry in
            VStack(alignment: .leading, spacing: 4) {
              Text(entry.content)
                .font(.callout)
              Text(EngageDateFormatter.relative(entry.updatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
          }
        }

        Section("Activity") {
          if logEntries.isEmpty && !isLoading {
            Text("No activity yet")
              .foregroundStyle(.secondary)
              .font(.callout)
          }
          ForEach(logEntries) { entry in
            HStack {
              Image(systemName: entry.action.icon)
                .foregroundStyle(entry.action.color)
              VStack(alignment: .leading) {
                Text(entry.actor == "human" ? "Human" : "Agent")
                  .font(.caption)
                  .fontWeight(.medium)
                if let content = entry.content {
                  Text(content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Text(EngageDateFormatter.relative(entry.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Agent")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await load() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(isLoading)
        }
      }
      .task { await load() }
    }
  }

  private func load() async {
    isLoading = true
    do {
      memories = try await client.agentMemory(agentId: agentId)
      logEntries = try await client.collaborationLog(limit: 30)
    } catch {
      // non-fatal
    }
    isLoading = false
  }
}

extension LogAction {
  var icon: String {
    switch self {
    case .created: return "plus.circle"
    case .commented: return "bubble.left"
    case .reassigned: return "arrow.triangle.swap"
    case .prioritized: return "exclamationmark.circle"
    case .completed: return "checkmark.circle"
    case .cancelled: return "xmark.circle"
    case .blocked: return "hand.raised"
    case .unblocked: return "hand.raised.fill"
    case .staleFlagged: return "flag"
    }
  }

  var color: Color {
    switch self {
    case .completed: return .green
    case .cancelled, .blocked: return .red
    case .created: return .blue
    default: return .secondary
    }
  }
}
