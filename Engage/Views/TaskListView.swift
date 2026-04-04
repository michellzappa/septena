import SwiftUI

// ─── Task List View ────────────────────────────────────────────────────────────

struct TaskListView: View {
  @EnvironmentObject var client: ConvexClient
  @State private var tasks: [EngageTask] = []
  @State private var isLoading = false
  @State private var errorMessage: String?

  let filter: TaskFilter

  var body: some View {
    Group {
      if isLoading && tasks.isEmpty {
        ProgressView()
      } else if let error = errorMessage {
        ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
      } else if tasks.isEmpty {
        ContentUnavailableView("No tasks", systemImage: "checkmark.circle", description: Text("Nothing here yet"))
      } else {
        List {
          ForEach(filteredTasks) { task in
            NavigationLink(value: task) {
              TaskRowView(task: task)
            }
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                cancel(task)
              } label: {
                Label("Cancel", systemImage: "xmark")
              }
              Button {
                complete(task)
              } label: {
                Label("Done", systemImage: "checkmark")
              }
              .tint(.green)
            }
            .swipeActions(edge: .leading) {
              assignToAgentAction(task)
            }
          }
        }
        .listStyle(.plain)
        .refreshable {
          await load()
        }
      }
    }
    .navigationTitle(filter.title)

    .task(id: filter.title) { await load() }
  }

  private var filteredTasks: [EngageTask] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    let weekEnd = calendar.date(byAdding: .day, value: 7, to: today)!

    return tasks.filter { task in
      switch filter {
      case .inbox:
        return task.status == .open && task.area == nil && task.project == nil && task.due == nil && task.start == nil
      case .today:
        return task.status == .open && (
          (task.due != nil && calendar.isDate(task.due!, inSameDayAs: today)) ||
          (task.start != nil && calendar.isDate(task.start!, inSameDayAs: today))
        )
      case .upcoming(let days):
        let end = calendar.date(byAdding: .day, value: days, to: today)!
        return task.status == .open && (
          (task.due != nil && task.due! >= today && task.due! <= end) ||
          (task.start != nil && task.start! >= today && task.start! <= end)
        )
      case .anytime:
        return task.status == .open && task.due == nil && task.start == nil
      case .someday:
        return task.status == .open && false // someday = cancelled/someday flag
      case .project(let projectId):
        return task.status == .open && task.project == projectId
      case .area(let areaId):
        return task.status == .open && task.area == areaId
      case .review:
        // Stale: no activity in 5+ days
        let stale = calendar.date(byAdding: .day, value: -5, to: today)!
        return task.status == .open && (
          task.agentStatus == .blocked ||
          (task.completedAt == nil && (task.due == nil || task.due! < today))
        )
      case .logbook:
        return task.status == .completed || task.status == .cancelled
      }
    }
  }

  private func load() async {
    isLoading = true
    errorMessage = nil
    do {
      tasks = try await client.tasksList()
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  private func complete(_ task: EngageTask) {
    Task {
      do {
        try await client.taskComplete(id: task.id, completedBy: "human")
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func cancel(_ task: EngageTask) {
    Task {
      do {
        try await client.taskCancel(id: task.id, actor: "human")
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  @ViewBuilder
  private func assignToAgentAction(_ task: EngageTask) -> some View {
    Button {
      Task {
        try? await client.taskAssign(
          id: task.id,
          owner: "agent",
          agentAcknowledged: false,
          actor: "human"
        )
        await load()
      }
    } label: {
      Label("Assign to Agent", systemImage: "brain")
    }
    .tint(.blue)
  }
}

// ─── Task Row ─────────────────────────────────────────────────────────────────

struct TaskRowView: View {
  let task: EngageTask
  @EnvironmentObject var client: ConvexClient
  @State private var agents: [Agent] = []

  var body: some View {
    HStack(spacing: 8) {
      // Origin badge
      originBadge

      VStack(alignment: .leading, spacing: 2) {
        Text(task.title)
          .font(.body)
          .strikethrough(task.status == .completed)
          .foregroundStyle(task.status == .completed ? .secondary : .primary)

        if let notes = task.notes, !notes.isEmpty {
          Text(notes)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        HStack(spacing: 6) {
          if let due = task.due {
            Label(EngageDateFormatter.relative(due), systemImage: "calendar")
              .font(.caption2)
              .foregroundStyle(dueColor(due))
          }
          if task.isRecurring {
            Image(systemName: "repeat")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          if task.agentAssignedMe {
            Image(systemName: "brain")
              .font(.caption2)
              .foregroundStyle(.blue)
          }
        }
      }

      Spacer()

      // Priority indicator
      if task.priority >= 2 {
        Circle()
          .fill(task.priority == 3 ? .red : .orange)
          .frame(width: 6, height: 6)
      }

      if task.status == .completed {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
    }
    .padding(.vertical, 2)
    .task { agents = (try? await client.agentsList()) ?? [] }
  }

  @ViewBuilder
  private var originBadge: some View {
    if task.origin == .agent {
      Image(systemName: "brain")
        .font(.caption)
        .foregroundStyle(.blue)
    } else {
      Image(systemName: "person")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func dueColor(_ date: Date) -> Color {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return .primary }
    if date < Date() { return .red }
    return .secondary
  }
}
