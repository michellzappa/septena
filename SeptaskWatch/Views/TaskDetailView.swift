import SwiftUI

// The task, read in full, with its actions. Complete is the big button and
// answers the double-tap gesture; Cancel is last, the one destructive act.

struct TaskDetailView: View {
  let task: WatchTask
  /// False when opened from Upcoming / Anytime: offers "Today" instead of
  /// "Remove from Today".
  let onToday: Bool

  @Environment(\.dismiss) private var dismiss
  @State private var confirmCancel = false
  private var store: WatchStore { .shared }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text(task.title)
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)

        facts

        if let notes = task.notes, !notes.isEmpty {
          Text(notes)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Button {
          act { store.complete(task) }
        } label: {
          Label("Complete", systemImage: "checkmark")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .handGestureShortcut(.primaryAction)
        .padding(.top, 4)

        if onToday {
          action("Tomorrow", "sunrise") { store.tomorrow(task) }
          action("Remove from Today", "calendar.badge.minus") { store.removeFromToday(task) }
        } else {
          action("Today", "star") { store.moveToToday(task) }
          action("Tomorrow", "sunrise") { store.tomorrow(task) }
        }

        Button(role: .destructive) { confirmCancel = true } label: {
          Label("Cancel Task", systemImage: "xmark.circle")
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 6)
      }
      .padding(.horizontal, 2)
    }
    .navigationTitle(task.container ?? String(localized: "Task"))
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("Cancel this task?", isPresented: $confirmCancel, titleVisibility: .visible) {
      Button("Cancel Task", role: .destructive) { act { store.cancel(task) } }
      Button("Keep", role: .cancel) {}
    }
  }

  @ViewBuilder
  private var facts: some View {
    let today = store.todayDay
    VStack(alignment: .leading, spacing: 3) {
      switch task.due(today: today) {
      case .overdue:
        fact("flag.fill", "Due \(TaskMetaLine.short(task.deadline ?? ""))", .red)
      case .dueToday:
        fact("flag.fill", String(localized: "Due today"), .orange)
      case .none:
        if let d = task.deadline { fact("flag", "Due \(TaskMetaLine.short(d))", .orange) }
      }
      if let s = task.scheduled, s > today {
        fact("calendar", TaskMetaLine.short(s), .secondary)
      }
      if let t = task.startTime { fact("clock", t, .secondary) }
      if task.isRepeating { fact("repeat", String(localized: "Repeats"), .secondary) }
      if let total = task.checklistCount, total > 0 {
        fact("checklist", "\(task.checklistDoneCount ?? 0) of \(total) steps", .secondary)
      }
    }
    .font(.footnote)
  }

  private func fact(_ symbol: String, _ text: String, _ color: Color) -> some View {
    Label(text, systemImage: symbol).foregroundStyle(color)
  }

  private func action(_ title: LocalizedStringKey, _ symbol: String, _ run: @escaping () -> Void) -> some View {
    Button { act(run) } label: {
      Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Back to the list first, so the change (and its Undo) plays there.
  private func act(_ run: @escaping () -> Void) {
    dismiss()
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(250))
      run()
    }
  }
}
