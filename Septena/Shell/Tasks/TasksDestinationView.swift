import SwiftUI
import SwiftData

// Tasks drawer — the light, standardized surface that opens from the
// homepage Tasks tile, built on the same `SectionDrawer` chrome every
// other section uses. Glance at today, check things off, capture a new
// task. The deep areas / projects / scheduling surface still lives in the
// Tasks tab; this is its quick-access counterpart, and the two share the
// canonical `TaskRow` so a task looks identical wherever it appears.
//
// Replaces the old behaviour where the Tasks tile sheeted the entire
// `TaskListView(filter: .today)` monolith — see `TasksPlugin.destinationView()`.

struct TasksDestinationView: View {
  @Environment(TaskMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @AppStorage(SettingsKey.todayShowCompleted) private var showCompleted: Bool = true

  /// Open tasks routed into Today (pinned, or scheduled / deadline ≤ today).
  /// Mirrors `LocalCache.tasks(in:filter:.today)`; held in @State so we can
  /// apply optimistic edits in-session without waiting on the outbox.
  @State private var openTasks: [SeptenaTask] = []
  /// Tasks completed today, newest first. Gated on the "Show completed in
  /// Today" preference (shared with the Today log + Settings).
  @State private var doneTasks: [SeptenaTask] = []
  @State private var editing: SeptenaTask? = nil
  @State private var creating = false

  private var accent: Color { theme.color(for: "tasks") }

  var body: some View {
    SectionDrawer(sectionKey: "tasks",
                  title: "Tasks",
                  onLog: { _ in creating = true }) {
      summary
      if !openTasks.isEmpty {
        DrawerSection("Today", padding: .none) {
          ForEach(openTasks) { task in
            TaskRow(task: task,
                    accent: accent,
                    trailing: deadlineLabel(task),
                    trailingTint: isOverdue(task) ? Theme.overdueRed : nil,
                    onToggle: { toggle(task) },
                    onTap: { editing = task })
          }
        }
      }
      if showCompleted, !doneTasks.isEmpty {
        DrawerSection("Done", padding: .none) {
          ForEach(doneTasks) { task in
            TaskRow(task: task,
                    accent: accent,
                    onToggle: { toggle(task) },
                    onTap: { editing = task })
          }
        }
      }
      if openTasks.isEmpty && doneTasks.isEmpty {
        DrawerSection {
          Text("Nothing for today yet. Tap + to add a task.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .trackScreen("tasks")
    .tint(accent)
    .task { reload() }
    .sheet(item: $editing) { task in
      TaskQuickEditSheet(task: task, accent: accent, onDone: { reload() })
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
    // The drawer's standard "+" / ⌘N (SectionDrawer toolbar, declared via
    // TasksPlugin.logActions) opens this — no bespoke add affordance.
    .sheet(isPresented: $creating) {
      NewTaskSheet(accent: accent, onDone: { reload() })
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
  }

  // MARK: - Header

  private var summary: some View {
    let overdue = openTasks.filter(isOverdue).count
    var stats: [Stat] = [Stat(value: "\(openTasks.count)", label: "to do", tint: accent)]
    if overdue > 0 {
      stats.append(Stat(value: "\(overdue)", label: "overdue", tint: Theme.overdueRed))
    }
    stats.append(Stat(value: "\(doneTasks.count)", label: "done"))
    return DrawerSection { StatStrip(stats: stats) }
  }

  // MARK: - Data

  private func reload() {
    openTasks = LocalCache.tasks(in: modelContext, filter: .today)
    guard showCompleted else { doneTasks = []; return }
    let today = SeptenaDate.today
    doneTasks = LocalCache.tasks(in: modelContext, filter: .logbook)
      .filter { ($0.completedAt ?? "").hasPrefix(today) }
      .sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
  }

  /// Optimistic toggle — moves the row between buckets immediately, then
  /// routes through the mutator (outbox + CloudKit). We deliberately don't
  /// `reload()` here: the local store write isn't guaranteed synchronous,
  /// so the in-session arrays are the source of truth until the next appear.
  private func toggle(_ task: SeptenaTask) {
    if task.status == .done {
      mutator.uncomplete(id: task.id)
      doneTasks.removeAll { $0.id == task.id }
      var reopened = task
      reopened.status = .open
      reopened.completedAt = nil
      openTasks.append(reopened)
    } else {
      mutator.complete(id: task.id)
      openTasks.removeAll { $0.id == task.id }
      if showCompleted {
        var done = task
        done.status = .done
        done.completedAt = SeptenaDate.today + "T00:00:00"
        doneTasks.insert(done, at: 0)
      }
    }
    Haptics.tick()
  }

  // MARK: - Row meta

  private func isOverdue(_ task: SeptenaTask) -> Bool {
    let today = SeptenaDate.today
    if let s = task.scheduled, s < today { return true }
    if let d = task.deadline, d < today { return true }
    return false
  }

  /// Trailing chip: the task's deadline rendered as "MMM d", or nil.
  private func deadlineLabel(_ task: SeptenaTask) -> String? {
    guard let deadline = task.deadline else { return nil }
    return Self.shortDate(deadline)
  }

  private static let isoParser: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()
  private static let shortFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f
  }()
  private static func shortDate(_ iso: String) -> String {
    guard let date = isoParser.date(from: String(iso.prefix(10))) else { return iso }
    return shortFormatter.string(from: date)
  }
}

// MARK: - Quick edit

/// Compact task editor presented from a drawer row tap. Edits the same
/// title + notes the deep surface's inline editor exposes, plus the Today
/// pin — the high-frequency fields. Scheduling, deadlines, repeat, and
/// area/project assignment remain in the full Tasks surface.
private struct TaskQuickEditSheet: View {
  let task: SeptenaTask
  let accent: Color
  let onDone: () -> Void

  @Environment(TaskMutator.self) private var mutator
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var notes: String
  @State private var isToday: Bool

  init(task: SeptenaTask, accent: Color, onDone: @escaping () -> Void) {
    self.task = task
    self.accent = accent
    self.onDone = onDone
    _title = State(initialValue: task.title)
    _notes = State(initialValue: task.notes ?? "")
    _isToday = State(initialValue: task.today)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Title", text: $title, axis: .vertical)
          TextField("Notes", text: $notes, axis: .vertical)
            .lineLimit(1...6)
            .foregroundStyle(.secondary)
        }
        Section {
          Toggle("Today", isOn: $isToday)
        }
        Section {
          Button(role: .destructive) {
            mutator.delete(id: task.id)
            onDone()
            dismiss()
          } label: {
            Label("Delete Task", systemImage: "trash")
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Task")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { save() }
        }
      }
      .tint(accent)
    }
  }

  private func save() {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let titleChanged = !trimmed.isEmpty && trimmed != task.title
    let notesChanged = notes != (task.notes ?? "")
    if titleChanged || notesChanged {
      mutator.update(id: task.id,
                     title: titleChanged ? trimmed : nil,
                     notes: notesChanged ? notes : nil)
    }
    if isToday != task.today {
      mutator.moveToToday(id: task.id, today: isToday)
    }
    onDone()
    dismiss()
  }
}

// MARK: - New task

/// Compact new-task composer opened from the drawer's standard "+" toolbar
/// action (SectionDrawer, declared via `TasksPlugin.logActions`). Creates a
/// task pinned to Today by default — this is the Today drawer; deeper
/// routing and scheduling live in the full Tasks surface.
private struct NewTaskSheet: View {
  let accent: Color
  let onDone: () -> Void

  @Environment(TaskMutator.self) private var mutator
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var isToday = true
  @FocusState private var titleFocused: Bool

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Title", text: $title, axis: .vertical)
            .focused($titleFocused)
            .onSubmit(add)
        }
        Section {
          Toggle("Today", isOn: $isToday)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("New Task")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add", action: add)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .tint(accent)
      .onAppear { titleFocused = true }
    }
  }

  private func add() {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    mutator.create(title: trimmed, today: isToday)
    Haptics.tick()
    onDone()
    dismiss()
  }
}
