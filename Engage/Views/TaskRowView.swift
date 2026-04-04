import SwiftUI

// ─── Task Row ─────────────────────────────────────────────────────────────────

struct TaskRowView: View {
  let task: EngageTask

  var body: some View {
    HStack(spacing: 8) {
      // Origin indicator
      originBadge

      VStack(alignment: .leading, spacing: 2) {
        Text(task.title)
          .font(.body)
          .strikethrough(task.status == .completed)
          .foregroundStyle(task.status == .completed ? .secondary : .primary)
          .lineLimit(2)

        // Row 2: badges + metadata
        HStack(spacing: 6) {
          // 4a. Review badge — agent flagged for human review
          if task.needsHumanReview {
            Label("Review", systemImage: "arrow.right.circle.fill")
              .font(.caption2)
              .foregroundStyle(.orange)
          }

          // 4a. Agent thinking preview — truncated note shown on row
          if let note = task.agentNote, !note.isEmpty {
            HStack(spacing: 2) {
              Image(systemName: "brain")
                .font(.caption2)
              Text(note.prefix(36) + (note.count > 36 ? "…" : ""))
                .font(.caption2)
            }
            .foregroundStyle(.blue)
          }

          // Fallback: notes preview when no agent note
          else if let notes = task.notes, !notes.isEmpty {
            Text(notes)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          if task.isRecurring {
            Image(systemName: "repeat")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }

        // Row 3: due date + priority dot + confidence
        HStack(spacing: 6) {
          if let due = task.due {
            Label(EngageDateFormatter.relative(due), systemImage: "calendar")
              .font(.caption2)
              .foregroundStyle(dueColor(due))
          }

          if task.agentAssignedMe {
            Image(systemName: "person.fill.checkmark")
              .font(.caption2)
              .foregroundStyle(.blue)
          }

          // Confidence dot
          if task.confidence > 0 && task.origin == .agent {
            Circle()
              .fill(confidenceColor)
              .frame(width: 5, height: 5)
          }
        }
      }

      Spacer()

      // Priority indicator
      if task.priority >= 2 {
        Circle()
          .fill(task.priority == 3 ? Color.red : Color.orange)
          .frame(width: 6, height: 6)
      }

      if task.status == .completed {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
    }
    .padding(.vertical, 2)
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

  private var confidenceColor: Color {
    switch task.confidence {
    case 3: return .green
    case 2: return .orange
    case 1: return .red
    default: return .clear
    }
  }

  private func dueColor(_ date: Date) -> Color {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return .primary }
    if date < Date() { return .red }
    return .secondary
  }
}
