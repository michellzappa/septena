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
  @Environment(\.a11yMotion) private var motion
  @AppStorage(SettingsKey.todayShowCompleted) private var showCompleted: Bool = true

  /// Drives the "linger → fade" beat after a check (see `SettleStore`).
  @State private var settle = SettleStore()

  /// Open tasks routed into Today (pinned, or scheduled / deadline ≤ today).
  /// Mirrors `LocalCache.tasks(in:filter:.today)`; held in @State so we can
  /// apply optimistic edits in-session without waiting on the outbox.
  @State private var openTasks: [SeptenaTask] = []
  /// Tasks completed today, newest first. Gated on the "Show completed in
  /// Today" preference (shared with the Today log + Settings).
  @State private var doneTasks: [SeptenaTask] = []
  /// Areas / projects backing the edit sheet's "List" picker. Loaded once
  /// alongside the task lists so the modal can resolve and reassign a task's
  /// home the same way the full Tasks surface does.
  @State private var areas: [Area] = []
  @State private var projects: [Project] = []
  @State private var editing: SeptenaTask? = nil
  @State private var creating = false

  private var accent: Color { theme.color(for: "tasks") }

  var body: some View {
    SectionDrawer(sectionKey: "tasks",
                  title: "Tasks",
                  onLog: { _ in creating = true }) {
      if !openTasks.isEmpty {
        DrawerSection("Today", padding: .none) {
          ForEach(openTasks) { task in
            TaskRow(task: task,
                    accent: accent,
                    trailing: deadlineLabel(task),
                    trailingTint: isOverdue(task) ? Theme.overdueRed : nil,
                    onToggle: { toggle(task) },
                    onTap: { editing = task })
              .transition(.opacity)
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
      TaskQuickEditSheet(task: task, accent: accent, areas: areas, projects: projects,
                         onDone: { reload() })
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

  // MARK: - Data

  private func reload() {
    settle.cancelAll()
    areas = LocalCache.areas(in: modelContext)
    projects = LocalCache.projects(in: modelContext)
    openTasks = LocalCache.tasks(in: modelContext, filter: .today)
    guard showCompleted else { doneTasks = []; return }
    let today = SeptenaDate.today
    doneTasks = LocalCache.tasks(in: modelContext, filter: .logbook)
      .filter { ($0.completedAt ?? "").hasPrefix(today) }
      .sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
  }

  /// Optimistic toggle — routes through the mutator (outbox + CloudKit) and
  /// keeps the in-session arrays as the source of truth until the next appear
  /// (the local store write isn't guaranteed synchronous, so we don't reload).
  ///
  /// On complete the row doesn't vanish: it flips struck-through in place,
  /// lingers for the settle beat, then fades out of Today and lands at the top
  /// of Done (see `SettleStore`). Re-checking within the window cancels the
  /// fade. Reduce Motion drops the fade but keeps the delayed move.
  private func toggle(_ task: SeptenaTask) {
    Haptics.tick()
    if task.status == .done {
      // Uncomplete — abort any in-flight fade and restore to the open list,
      // whether the row is still settling in Today or already sitting in Done.
      mutator.uncomplete(id: task.id)
      settle.cancel(task.id)
      var reopened = task
      reopened.status = .open
      reopened.completedAt = nil
      motion.run(Theme.Motion.settle) {
        doneTasks.removeAll { $0.id == task.id }
        if let i = openTasks.firstIndex(where: { $0.id == task.id }) {
          openTasks[i] = reopened
        } else {
          openTasks.append(reopened)
        }
      }
    } else {
      // Complete — flip in place so the checkbox fills and the title strikes,
      // then schedule the fade-out into Done.
      mutator.complete(id: task.id)
      motion.run(Theme.Motion.settle) {
        if let i = openTasks.firstIndex(where: { $0.id == task.id }) {
          openTasks[i].status = .done
          openTasks[i].completedAt = SeptenaDate.today + "T00:00:00"
        }
      }
      settle.schedule(task.id) {
        motion.run(Theme.Motion.settle) {
          guard let i = openTasks.firstIndex(where: { $0.id == task.id }) else { return }
          let done = openTasks.remove(at: i)
          if showCompleted { doneTasks.insert(done, at: 0) }
        }
      }
    }
  }

  // MARK: - Row meta

  private func isOverdue(_ task: SeptenaTask) -> Bool {
    // Deadline-only, Things-style: a past *scheduled* date is just a plan that
    // rolled into Today, not an overdue task. See `SeptenaTask.isOverdue`.
    task.isOverdue
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
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f
  }()
  private static func shortDate(_ iso: String) -> String {
    guard let date = isoParser.date(from: String(iso.prefix(10))) else { return iso }
    return shortFormatter.string(from: date)
  }
}

// MARK: - Quick edit

/// Compact task editor presented from a drawer row tap. Exposes the same
/// fields the full Tasks surface does — title, notes, schedule (When),
/// deadline, repeat, and area/project (List) — behind the canonical task
/// icons, so a task edits identically wherever it's opened. Changes are held
/// locally and committed on Done (Cancel discards), matching the modal's
/// Cancel/Done contract.
private struct TaskQuickEditSheet: View {
  let task: SeptenaTask
  let accent: Color
  let areas: [Area]
  let projects: [Project]
  let onDone: () -> Void

  @Environment(TaskMutator.self) private var mutator
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var notes: String
  // Local edit buffers for the meta fields, seeded from the task and committed
  // on Done. `scheduled` mirrors the full surface: a task pinned to Today (no
  // explicit date) shows no scheduled date here — picking "Today" re-pins it.
  @State private var scheduled: Date?
  @State private var deadline: Date?
  @State private var recurrence: Recurrence?
  @State private var areaId: String?
  @State private var projectId: String?
  @State private var picker: EditPicker?

  private enum EditPicker: Int, Identifiable {
    case when, deadline, repeatRule, move
    var id: Int { rawValue }
  }

  init(task: SeptenaTask, accent: Color, areas: [Area], projects: [Project],
       onDone: @escaping () -> Void) {
    self.task = task
    self.accent = accent
    self.areas = areas
    self.projects = projects
    self.onDone = onDone
    _title = State(initialValue: task.title)
    _notes = State(initialValue: task.notes ?? "")
    _scheduled = State(initialValue: SeptenaDate.parse(task.scheduled))
    _deadline = State(initialValue: SeptenaDate.parse(task.deadline))
    _recurrence = State(initialValue: task.recurrence)
    _areaId = State(initialValue: task.area)
    _projectId = State(initialValue: task.project)
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
        // Standard task meta — same icons + pickers as the full Tasks surface.
        Section {
          metaRow("calendar", "When", value: scheduledLabel,
                  set: scheduled != nil) { picker = .when }
          metaRow("flag", "Deadline", value: deadlineLabel,
                  set: deadline != nil) { picker = .deadline }
          metaRow("repeat", "Repeat", value: recurrence?.shortLabel ?? "Never",
                  set: recurrence != nil) { picker = .repeatRule }
          metaRow("folder", "List", value: listLabel,
                  set: areaId != nil || projectId != nil) { picker = .move }
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
      .sheet(item: $picker) { which in
        editPicker(which)
      }
    }
  }

  // MARK: - Meta row

  /// A tappable Form row: leading task icon (tinted accent when the field is
  /// set), the field name, and its current value. Opens the matching picker.
  @ViewBuilder
  private func metaRow(_ icon: String, _ label: String, value: String,
                       set: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .scaledFont(size: 16)
          .foregroundStyle(set ? accent : Theme.inkSecondary)
          .frame(width: 24)
        Text(label)
          .foregroundStyle(Theme.inkPrimary)
        Spacer()
        Text(value)
          .foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func editPicker(_ which: EditPicker) -> some View {
    switch which {
    case .when:
      DatePickerSheet(title: "When", initialDate: scheduled,
                      setLabel: "Set Date", updateLabel: "Update Date",
                      clearLabel: "No Date") { scheduled = $0 }
        #if os(iOS)
        .presentationDetents([.height(DatePickerSheet.sheetHeight), .large])
        #endif
    case .deadline:
      DatePickerSheet(title: "Deadline", initialDate: deadline,
                      setLabel: "Set Deadline", updateLabel: "Update Deadline",
                      clearLabel: "Remove Deadline") { deadline = $0 }
        #if os(iOS)
        .presentationDetents([.height(DatePickerSheet.sheetHeight), .large])
        #endif
    case .repeatRule:
      RecurrencePickerSheet(initial: recurrence) { recurrence = $0 }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    case .move:
      MovePickerSheet(areas: areas, projects: projects,
                      currentAreaId: areaId, currentProjectId: projectId) { a, p in
        areaId = a; projectId = p
      }
        #if os(iOS)
        .presentationDetents([.large, .medium])
        #endif
    }
  }

  // MARK: - Value labels

  private var scheduledLabel: String {
    guard let scheduled else { return "None" }
    if Calendar.current.isDateInToday(scheduled) { return "Today" }
    return Self.shortFormatter.string(from: scheduled)
  }
  private var deadlineLabel: String {
    guard let deadline else { return "None" }
    return Self.shortFormatter.string(from: deadline)
  }
  private var listLabel: String {
    if let projectId, let p = projects.first(where: { $0.id == projectId }) {
      return p.title
    }
    if let areaId, let a = areas.first(where: { $0.id == areaId }) {
      return a.title
    }
    return "Inbox"
  }

  private static let shortFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f
  }()

  // MARK: - Commit

  private func save() {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let titleChanged = !trimmed.isEmpty && trimmed != task.title
    let notesChanged = notes != (task.notes ?? "")
    if titleChanged || notesChanged {
      mutator.update(id: task.id,
                     title: titleChanged ? trimmed : nil,
                     notes: notesChanged ? notes : nil)
    }

    // Schedule — Things-style mapping, mirroring `TaskListView.applyWhen`:
    // a "Today" pick pins to Today and clears any planning date; a future
    // date schedules it (server surfaces it on Today when it arrives); nil
    // clears both. Only fire when the picked date actually changed.
    if scheduled != SeptenaDate.parse(task.scheduled) {
      if let d = scheduled {
        if Calendar.current.isDateInToday(d) {
          mutator.schedule(id: task.id, date: nil)
          mutator.moveToToday(id: task.id, today: true)
        } else {
          mutator.moveToToday(id: task.id, today: false)
          mutator.schedule(id: task.id, date: d)
        }
      } else {
        mutator.schedule(id: task.id, date: nil)
        mutator.moveToToday(id: task.id, today: false)
      }
    }

    if deadline != SeptenaDate.parse(task.deadline) {
      mutator.setDue(id: task.id, date: deadline)
    }
    if recurrence != task.recurrence {
      mutator.setRecurrence(id: task.id, recurrence: recurrence)
    }

    // List — project wins; Septena derives the area from the project on save.
    if areaId != task.area || projectId != task.project {
      if projectId != nil {
        mutator.moveToProject(id: task.id, project: projectId)
      } else {
        mutator.moveToArea(id: task.id, area: areaId)
        mutator.moveToProject(id: task.id, project: nil)
      }
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
          TextField("Title", text: $title)
            .focused($titleFocused)
            .submitLabel(.done)
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
