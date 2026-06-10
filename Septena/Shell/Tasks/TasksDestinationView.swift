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
  /// App-root celebration layer — only used by the day-cleared `.arc`
  /// (see `TaskCelebration`). Optional and nil-safe.
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
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
  /// Composer state, hosted on this drawer so its cover stacks *above* the
  /// drawer sheet (rather than replacing it).
  @State private var creating = false
  @State private var editingTask: SeptenaTask?
  /// Row currently open in the composer — drives the selection highlight.
  @State private var selectedId: String?

  private var accent: Color { theme.color(for: "tasks") }

  /// New tasks from the drawer default to Today; a row tap edits.
  private func openCreate() { creating = true }
  private func openEdit(_ task: SeptenaTask) {
    selectedId = task.id
    editingTask = task
  }

  var body: some View {
    SectionDrawer(sectionKey: "tasks",
                  title: "Tasks",
                  onLog: { _ in openCreate() }) {
      if !openTasks.isEmpty {
        DrawerSection("Today", padding: .none) {
          ForEach(openTasks) { task in
            TaskRow(task: task,
                    accent: accent,
                    areas: areas,
                    projects: projects,
                    showsTodayIndicator: false,
                    isSelected: selectedId == task.id,
                    onToggle: { toggle(task) },
                    onTap: { openEdit(task) })
              .transition(.opacity)
          }
        }
      }
      if showCompleted, !doneTasks.isEmpty {
        DrawerSection("Done", padding: .none) {
          ForEach(doneTasks) { task in
            TaskRow(task: task,
                    accent: accent,
                    areas: areas,
                    projects: projects,
                    showsTodayIndicator: false,
                    isSelected: selectedId == task.id,
                    onToggle: { toggle(task) },
                    onTap: { openEdit(task) })
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
    .tint(accent)
    .task { reload() }
    // Host the composer here so it stacks on top of the drawer sheet and
    // dismisses back to it.
    .taskComposerDrawer(isPresented: composerBinding) { composerCard }
  }

  @ViewBuilder
  private var composerCard: some View {
    if let mode = composerMode {
      TaskComposerCard(mode: mode, areas: areas, projects: projects, accent: accent,
                       onDone: { reload() })
    }
  }
  private var composerMode: TaskComposerCard.Mode? {
    if creating { return .create(.today) }
    if let task = editingTask { return .edit(task) }
    return nil
  }
  private var composerBinding: Binding<Bool> {
    Binding(get: { creating || editingTask != nil }, set: { if !$0 { closeComposer() } })
  }
  private func closeComposer() {
    creating = false
    editingTask = nil
    selectedId = nil
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
    if task.status == .done {
      Haptics.tap()
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
      // The drawer is Today-only, so every check is a Today completion;
      // after the in-place flip "all done" means today's list is clear.
      // (See `TaskCelebration` — the context-scaled completion haptic.)
      let clearedToday = !openTasks.contains { $0.status == .open }
      TaskCelebration.completed(isToday: true, clearedToday: clearedToday,
                                accent: accent, logCommit: logCommit)
    }
  }

}

