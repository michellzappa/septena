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
  @Environment(DayClock.self) private var clock
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif
  @AppStorage(SettingsKey.todayShowCompleted) private var showCompleted: Bool = true
  @AppStorage(SettingsKey.todayGroupByList) private var todayGroupByList: Bool = true

  /// Drives the "linger → fade" beat after a check (see `SettleStore`).
  @State private var settle = SettleStore()
  @State private var promoteFlash = PromoteFlashStore()
  @State private var toastStore = SeptenaToastStore()

  /// Open tasks routed into Today (pinned, or scheduled / deadline ≤ today).
  /// Mirrors `LocalCache.tasks(in:filter:.today)`; held in @State so we can
  /// apply optimistic edits in-session without waiting on the outbox.
  @State private var openTasks: [SeptenaTask] = []
  /// Tasks completed today, newest first. Gated on the "Show completed in
  /// Today" preference (shared with the Today log + Settings).
  @State private var doneTasks: [SeptenaTask] = []
  /// The Inbox — the unratified layer (agent proposals + loose captures) that
  /// renders as a normal section *above* Today. See docs/TRIAGE_BAND_SPEC.md.
  @State private var triageTasks: [SeptenaTask] = []
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
  /// The drawer is its own task surface, so it owns focus instead of relying on
  /// the surrounding SectionDrawer (which may be focused for another section's
  /// date navigation). This gives Mac and regular-width iPad the same arrows /
  /// Return / Space / Escape contract as the full Tasks tab.
  @FocusState private var taskListFocused: Bool
  /// Keyboard traversal may move past the visible drawer viewport. Keep this
  /// separate from `selectedId` so pointer selection never re-anchors the
  /// scroll position just because a user clicked a row.
  @State private var keyboardScrollTarget: String?
  // Tasks is a dual section: Log = today's actionable list; Patterns = a
  // throughput heatmap of completed tasks over time. Default Log — the list is
  // the everyday surface.
  @State private var mode: DrawerMode = .remembered(for: "tasks", default: .log)
  /// Daily completed-task counts backing the Patterns heatmap.
  @State private var history: [TaskCompletionDay] = []
  /// False until the first `reload()` paints — suppresses arrival motion on cold open.
  @State private var hasPaintedLists = false

  private var accent: Color { theme.color(for: "tasks") }

  /// New tasks from the drawer default to Today; a row tap edits.
  private func openCreate() { creating = true }
  private func openEdit(_ task: SeptenaTask) {
    selectedId = task.id
    editingTask = task
  }
  /// Row pointer/touch behavior mirrors the deep Tasks list: Mac selects on a
  /// click and opens on double-click; regular iPad selects first and opens on a
  /// second tap / Return; compact iPhone retains direct tap-to-edit.
  private func openTap(_ task: SeptenaTask) -> (() -> Void)? {
    #if os(macOS)
    return { selectedId = task.id }
    #else
    return {
      if horizontalSizeClass == .regular {
        if selectedId == task.id { openEdit(task) }
        else { selectedId = task.id }
      } else {
        openEdit(task)
      }
    }
    #endif
  }

  private var usesSelectionModel: Bool {
    #if os(macOS)
    true
    #else
    horizontalSizeClass == .regular
    #endif
  }

  private var composerIsOpen: Bool { creating || editingTask != nil }

  /// Exact visual order of selectable drawer rows — the keyboard must never
  /// jump from Inbox to Done while skipping Today.
  private var keyboardTasks: [SeptenaTask] {
    triageTasks + openTasks + (showCompleted ? doneTasks : [])
  }

  private func moveSelection(_ delta: Int) {
    guard !keyboardTasks.isEmpty else { return }
    let current = selectedId.flatMap { id in keyboardTasks.firstIndex { $0.id == id } }
    let index: Int
    if let current {
      index = min(max(current + delta, 0), keyboardTasks.count - 1)
    } else {
      index = delta > 0 ? 0 : keyboardTasks.count - 1
    }
    let id = keyboardTasks[index].id
    selectedId = id
    keyboardScrollTarget = id
  }

  private func activateSelection() {
    guard let selectedId,
          let task = keyboardTasks.first(where: { $0.id == selectedId }) else { return }
    openEdit(task)
  }

  private func reclaimTaskListFocus() {
    guard usesSelectionModel, !composerIsOpen else { return }
    DispatchQueue.main.async { taskListFocused = true }
  }

  private func scrollID(for taskID: String) -> String {
    "tasks-drawer-row-\(taskID)"
  }

  var body: some View {
    ScrollViewReader { proxy in
      SectionDrawer(sectionKey: "tasks",
                    title: "Tasks",
                    quickAdd: DrawerQuickAdd("New task") { openCreate() },
                    mode: $mode,
                    log: {
        logContent
      }, patterns: {
        TaskPatternsSection(accent: accent, days: history)
      })
      .tint(accent)
      .environment(promoteFlash)
      .septenaToastStore(toastStore)
      .septenaToastOverlay(store: toastStore)
      .task { reload() }
      .onChange(of: clock.today) { _, _ in reload() }
    // A remote completion (another device checked a Today row) would otherwise
    // only surface on the next reopen, with the row silently gone. Ghost-check
    // it live instead — see `absorbRemoteCompletions`. We deliberately don't
    // full-reload here (that would cancel in-flight local settle beats); other
    // remote edits still fold in on reopen as before.
      .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
        absorbRemoteCompletions()
        absorbRemoteArrivals()
        mergeTaskFieldsFromCache()
      }
    // Host the composer here so it stacks on top of the drawer sheet and
    // dismisses back to it.
      .taskComposerDrawer(isPresented: composerBinding) { composerCard }
      .focusable(usesSelectionModel)
      .focused($taskListFocused)
      .focusEffectDisabled()
      .onAppear { reclaimTaskListFocus() }
      .onChange(of: composerIsOpen) { _, isOpen in
        if !isOpen { reclaimTaskListFocus() }
      }
      .onChange(of: keyboardScrollTarget) { _, id in
        guard let id else { return }
        // With no explicit anchor, ScrollViewReader performs the least
        // disruptive movement needed to reveal an off-screen target.
        proxy.scrollTo(scrollID(for: id))
        keyboardScrollTarget = nil
      }
      .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
        guard usesSelectionModel, !composerIsOpen, mode == .log else { return .ignored }
        moveSelection(press.key == .downArrow ? 1 : -1)
        return .handled
      }
      .onKeyPress(.return) {
        guard usesSelectionModel, !composerIsOpen, mode == .log, selectedId != nil else { return .ignored }
        activateSelection()
        return .handled
      }
      .onKeyPress(.escape) {
        guard usesSelectionModel, !composerIsOpen, selectedId != nil else { return .ignored }
        selectedId = nil
        return .handled
      }
      #if os(macOS)
      .onExitCommand {
        guard !composerIsOpen else { return }
        selectedId = nil
      }
      #endif
    }
  }

  @ViewBuilder
  private var logContent: some View {
      // The Inbox (unratified layer) sits on top of Today as a normal section —
      // same row style as Today below (see docs/TRIAGE_BAND_SPEC.md).
      if !triageTasks.isEmpty {
        DrawerSection("Inbox", padding: .none) {
          ForEach(triageTasks) { task in
            TaskRow(task: task,
                    accent: accent,
                    areas: areas,
                    projects: projects,
                    showsTodayIndicator: false,
                    isSelected: selectedId == task.id,
                    onToggle: { toggleInbox(task) },
                    onTap: openTap(task))
              .septenaOnDoubleClick { openEdit(task) }
              .taskRowActions(task: task, filter: .triage, areas: areas,
                              projects: projects, mutator: mutator,
                              onOpenDetail: { openEdit($0) },
                              onChange: { reloadAnimated() })
              .id(scrollID(for: task.id))
          }
        }
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
                    onTap: openTap(task))
              .septenaOnDoubleClick { openEdit(task) }
              .taskRowActions(task: task, filter: .today, areas: areas,
                              projects: projects, mutator: mutator,
                              onOpenDetail: { openEdit($0) },
                              onChange: { reloadAnimated() })
              .transition(.opacity)
              .id(scrollID(for: task.id))
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
                    onTap: openTap(task))
              .septenaOnDoubleClick { openEdit(task) }
              .taskRowActions(task: task, filter: .logbook, areas: areas,
                              projects: projects, mutator: mutator,
                              onOpenDetail: { openEdit($0) },
                              onChange: { reloadAnimated() })
              .id(scrollID(for: task.id))
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

  /// Re-read the lists with a fade so a row that leaves Today (removed from
  /// today, rescheduled, moved, cancelled, deleted via the row menu) animates
  /// out in real time. The checkbox path keeps its own optimistic settle beat
  /// and does not route through here.
  private func reloadAnimated() {
    motion.run(Theme.Motion.settle) { reload() }
  }

  private func reload() {
    settle.cancelAll()
    let structure = StructureCache.snapshot(in: modelContext)
    areas = structure.areas
    projects = structure.projects
    // The band is the unratified layer; Today is what's left after it. The
    // `.today` filter already excludes band members (`convert`), so a row that
    // satisfies both predicates lands only in the band — Today stays clean.
    triageTasks = LocalCache.tasks(in: modelContext, filter: .triage)
    var todayOpen = LocalCache.tasks(in: modelContext, filter: .today)
    if !todayGroupByList {
      todayOpen.sort(by: SeptenaTask.compareNextPageOrder)
    }
    openTasks = todayOpen
    let today = clock.today
    let completed = LocalCache.tasks(in: modelContext, filter: .logbook)
    history = Self.dailyCounts(completed, today: today)
    guard showCompleted else { doneTasks = []; return }
    doneTasks = completed
      .filter { ($0.completedAt ?? "").hasPrefix(today) }
      .sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
    hasPaintedLists = true
  }

  /// Collapse the logbook into a contiguous daily series of completed-task
  /// counts, oldest → today, for the Patterns heatmap. Days with no completions
  /// are filled with zero so streak math reads gaps correctly.
  private static func dailyCounts(_ completed: [SeptenaTask], today: String) -> [TaskCompletionDay] {
    var counts: [String: Int] = [:]
    for task in completed {
      guard let day = task.completedAt?.prefix(10), day.count == 10 else { continue }
      counts[String(day), default: 0] += 1
    }
    guard let earliest = counts.keys.min(), let start = SeptenaDate.parse(earliest) else {
      return []
    }
    let cal = Calendar.current
    var series: [TaskCompletionDay] = []
    var cursor = cal.startOfDay(for: start)
    let end = SeptenaDate.startOfDay(for: today) ?? Date()
    while cursor <= end {
      if let iso = SeptenaDate.format(cursor) {
        series.append(TaskCompletionDay(date: iso, count: counts[iso] ?? 0))
      }
      guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
      cursor = next
    }
    return series
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
          openTasks[i].completedAt = clock.today + "T00:00:00"
        }
      }
      settle.schedule(task.id) {
        motion.run(Theme.Motion.settle) {
          settle.endSettle(task.id)
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

  /// Ghost-check drawer rows that another device just completed. A remote
  /// completion can drop the row from the fresh Today / Inbox read; rather than
  /// let it vanish, we replay the exact beat a local Today check uses — flip it
  /// struck-through in place (the checkbox refills off `isDone`), linger, then
  /// fade into Done. Silent: no `TaskCelebration`, so a passive sync doesn't
  /// buzz. Rows the user is mid-settling locally (or already flipped done) are
  /// skipped — `.septenaTasksChanged` also fires for our own writes, and this
  /// must be a no-op for those. Scoped to completions only; other remote edits
  /// still fold in on the next reopen (the drawer never live-reloaded those).
  private func absorbRemoteCompletions() {
    let freshToday = LocalCache.tasks(in: modelContext, filter: .today)
    let freshTriage = LocalCache.tasks(in: modelContext, filter: .triage)
    let todayDone = remotelyCompletedIDs(prior: openTasks, fresh: freshToday)
    let triageDone = remotelyCompletedIDs(prior: triageTasks, fresh: freshTriage)
    guard !todayDone.isEmpty || !triageDone.isEmpty else { return }

    for id in todayDone {
      ghostTodayCompletion(id: id, completedAt: completedAt(for: id, in: freshToday))
    }
    for id in triageDone {
      ghostInboxCompletion(id: id, completedAt: completedAt(for: id, in: freshTriage))
    }
  }

  /// Ghost-arrive rows another device just created or filed into this drawer.
  /// Replays the gentle expand-in beat (inverse of settle) without haptics.
  /// Field edits still route through `mergeTaskFieldsFromCache`; we don't
  /// full-reload here so in-flight local settle beats stay intact.
  private func absorbRemoteArrivals() {
    guard hasPaintedLists else { return }

    var freshToday = LocalCache.tasks(in: modelContext, filter: .today)
    if !todayGroupByList {
      freshToday.sort(by: SeptenaTask.compareNextPageOrder)
    }
    let freshTriage = LocalCache.tasks(in: modelContext, filter: .triage)

    let todayArrived = RemoteTaskSync.arrivingIDs(
      prior: openTasks, fresh: freshToday, animate: true
    )
    let triageArrived = RemoteTaskSync.arrivingIDs(
      prior: triageTasks, fresh: freshTriage, animate: true
    )
    guard !todayArrived.isEmpty || !triageArrived.isEmpty else { return }

    let mergedToday = RemoteTaskSync.preservingSettling(
      fresh: freshToday, prior: openTasks, isSettling: settle.isSettling
    )
    let mergedTriage = RemoteTaskSync.preservingSettling(
      fresh: freshTriage, prior: triageTasks, isSettling: settle.isSettling
    )
    RemoteTaskSync.flashTodayPromotes(ids: todayArrived, in: mergedToday, via: promoteFlash)

    motion.run(Theme.Motion.expand) {
      openTasks = mergedToday
      triageTasks = mergedTriage
    }
  }

  /// Refresh title/notes on visible rows from the local mirror without a full
  /// reload — preserves in-flight completion settle beats while folding in
  /// renames (and notes edits) from the Tasks tab or another surface.
  private func mergeTaskFieldsFromCache() {
    let freshByID = Dictionary(
      (LocalCache.tasks(in: modelContext, filter: .triage)
       + LocalCache.tasks(in: modelContext, filter: .today)
       + LocalCache.tasks(in: modelContext, filter: .logbook))
        .map { ($0.id, $0) },
      uniquingKeysWith: { a, _ in a }
    )
    func merge(_ list: inout [SeptenaTask]) {
      for i in list.indices {
        guard !settle.isSettling(list[i].id),
              let fresh = freshByID[list[i].id] else { continue }
        list[i].title = fresh.title
        list[i].notes = fresh.notes
      }
    }
    merge(&triageTasks)
    merge(&openTasks)
    merge(&doneTasks)
  }

  /// IDs from `prior` that are now completed in `fresh` or vanished from the
  /// filter because their backing SwiftData row flipped to done. This mirrors
  /// the full `TaskListView` detector so the drawer handles both filter shapes:
  /// lists that drop done rows and lists that return the same row as `.done`.
  private func remotelyCompletedIDs(prior: [SeptenaTask], fresh: [SeptenaTask]) -> Set<String> {
    let candidates = prior.filter { $0.status == .open && !settle.isSettling($0.id) }
    guard !candidates.isEmpty else { return [] }

    let freshByID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var done = Set<String>()
    var vanished = Set<String>()
    for task in candidates {
      if let freshTask = freshByID[task.id] {
        if freshTask.status == .done { done.insert(task.id) }
      } else {
        vanished.insert(task.id)
      }
    }
    if !vanished.isEmpty {
      done.formUnion(LocalCache.completedIDs(among: vanished, in: modelContext))
    }
    return done
  }

  private func completedAt(for id: String, in fresh: [SeptenaTask]) -> String {
    fresh.first(where: { $0.id == id })?.completedAt ?? clock.today + "T00:00:00"
  }

  private func prependDone(_ task: SeptenaTask) {
    doneTasks.removeAll { $0.id == task.id }
    if showCompleted { doneTasks.insert(task, at: 0) }
  }

  private func ghostTodayCompletion(id: String, completedAt: String) {
    motion.run(Theme.Motion.settle) {
      guard let i = openTasks.firstIndex(where: { $0.id == id }) else { return }
      openTasks[i].status = .done
      openTasks[i].completedAt = completedAt
    }
    settle.schedule(id) {
      motion.run(Theme.Motion.settle) {
        settle.endSettle(id)
        guard let i = openTasks.firstIndex(where: { $0.id == id }) else { return }
        let done = openTasks.remove(at: i)
        prependDone(done)
      }
    }
  }

  private func ghostInboxCompletion(id: String, completedAt: String) {
    motion.run(Theme.Motion.settle) {
      guard let i = triageTasks.firstIndex(where: { $0.id == id }) else { return }
      triageTasks[i].status = .done
      triageTasks[i].completedAt = completedAt
    }
    settle.schedule(id) {
      motion.run(Theme.Motion.settle) {
        settle.endSettle(id)
        guard let i = triageTasks.firstIndex(where: { $0.id == id }) else { return }
        let done = triageTasks.remove(at: i)
        prependDone(done)
      }
    }
  }

  // MARK: - Inbox

  /// Complete an Inbox row in place — same beat as a Today check, but the row
  /// lives in `triageTasks`. Completing it (status → done) drops it out of the
  /// Inbox and into Done. To triage instead of finish, tap the row to edit and
  /// place it (filing/scheduling/saving ratifies it; a bare peek does not).
  private func toggleInbox(_ task: SeptenaTask) {
    guard task.status != .done else { return }
    mutator.complete(id: task.id)
    var done = task
    done.status = .done
    done.completedAt = clock.today + "T00:00:00"
    motion.run(Theme.Motion.settle) {
      triageTasks.removeAll { $0.id == task.id }
      if showCompleted { doneTasks.insert(done, at: 0) }
    }
    TaskCelebration.completed(isToday: false, clearedToday: false,
                              accent: accent, logCommit: logCommit)
  }

}
