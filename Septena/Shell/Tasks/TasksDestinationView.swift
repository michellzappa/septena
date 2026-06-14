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
  /// The triage band — the unratified layer (agent proposals + loose captures)
  /// that renders *above* Today. See `TriageBandView`, docs/TRIAGE_BAND_SPEC.md.
  @State private var triageTasks: [SeptenaTask] = []
  /// Band collapse state (per drawer session). Starts expanded so proposals are
  /// one tap from accepted; the user can fold it without emptying it.
  @State private var triageCollapsed = false
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
      // The unratified layer sits on top of Today — accepting a row drops it
      // into the day below, in view (see docs/TRIAGE_BAND_SPEC.md).
      if !triageTasks.isEmpty {
        TriageBandView(tasks: triageTasks,
                       accent: accent,
                       projects: projects,
                       areas: areas,
                       collapsed: $triageCollapsed,
                       onOpen: { openEdit($0) },
                       onDispose: { dispose($0, $1) },
                       onAcceptAll: { acceptAllProposals() })
      }
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
      if openTasks.isEmpty && doneTasks.isEmpty && triageTasks.isEmpty {
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
    // The band is the unratified layer; Today is what's left after it. The
    // `.today` filter already excludes band members (`convert`), so a row that
    // satisfies both predicates lands only in the band — Today stays clean.
    triageTasks = LocalCache.tasks(in: modelContext, filter: .triage)
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

  // MARK: - Triage

  /// Apply a disposition to a band row, then animate it across the divider — it
  /// drops into Today if its new placement lands there, or leaves this surface
  /// entirely (scheduled later / someday / dropped / filed to a project). Any
  /// disposition other than Drop also acknowledges an agent row, so the cue
  /// clears in the same gesture.
  private func dispose(_ task: SeptenaTask, _ d: TriageDisposition) {
    Haptics.tap()
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())
    switch d {
    case .today:            mutator.moveToToday(id: task.id)
    case .tomorrow:         mutator.schedule(id: task.id, date: tomorrow)
    case .someday:          mutator.moveToSomeday(id: task.id)
    case .drop:             mutator.cancel(id: task.id)
    case .acceptAgent:      break  // acknowledge below is the whole action
    case .project(let pid): mutator.moveToProject(id: task.id, project: pid)
    }
    if task.source == TaskSource.mcp, d != .drop { mutator.acknowledge(id: task.id) }

    var moved = task
    applyLocally(d, to: &moved, tomorrow: tomorrow)
    motion.run(Theme.Motion.settle) {
      triageTasks.removeAll { $0.id == task.id }
      if moved.isOnToday, !moved.isInTriageBand,
         !openTasks.contains(where: { $0.id == moved.id }) {
        openTasks.append(moved)
      }
    }
  }

  /// Mirror a disposition onto an in-memory copy so `isOnToday` /
  /// `isInTriageBand` recompute correctly for the optimistic move (the local
  /// store write isn't guaranteed synchronous — same reasoning as `toggle`).
  /// Kept in lockstep with the mutator calls in `dispose`.
  private func applyLocally(_ d: TriageDisposition, to t: inout SeptenaTask, tomorrow: Date?) {
    switch d {
    case .today:            t.today = true
    case .tomorrow:         t.today = false
                            if let tomorrow { t.scheduled = Self.ymd.string(from: tomorrow) }
    case .someday:          t.status = .someday
    case .drop:             t.status = .cancelled
    case .acceptAgent:      break
    case .project(let pid): t.project = pid; t.area = nil
    }
    if t.source == TaskSource.mcp, d != .drop { t.acknowledgedAt = Date() }
  }

  /// Accept every agent proposal in one gesture — acknowledge each (keeping its
  /// proposed placement); the ones placed today flow into the list below. Loose
  /// human captures carry no proposal, so they stay in the band.
  private func acceptAllProposals() {
    let proposals = triageTasks.filter { $0.source == TaskSource.mcp }
    guard !proposals.isEmpty else { return }
    Haptics.success()
    for p in proposals { mutator.acknowledge(id: p.id) }
    let ids = Set(proposals.map(\.id))
    motion.run(Theme.Motion.settle) {
      triageTasks.removeAll { ids.contains($0.id) }
      for p in proposals {
        var moved = p
        moved.acknowledgedAt = Date()
        if moved.isOnToday, !moved.isInTriageBand,
           !openTasks.contains(where: { $0.id == moved.id }) {
          openTasks.append(moved)
        }
      }
    }
  }

  private static let ymd: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX"); return f
  }()

}

