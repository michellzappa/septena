import SwiftUI
import SwiftData
import EventKit

// Today-screen "everything else" rendering: chores, habits, supplements.
// One open list — a completed item lingers struck through for the settle
// beat, then fades out in place (there's no "done" strip to slide into).
// Shared state lives in NextItemsModel.

// MARK: - List selection tags
//
// The Next page is one `List` of heterogeneous rows (tasks / chores / habits /
// supplements / suggestions / done-log). To get native `List(selection:)`
// keyboard nav across all of them — the same arrow-key cursor + highlight the
// Tasks tab has — every row is `.tag`'d with a kind-prefixed string id so the
// page-level selection (`Set<String>`) can map a cursor back to its action.
enum NextRowTag {
  static func task(_ id: String) -> String       { "task:\(id)" }
  static func chore(_ id: String) -> String      { "chore:\(id)" }
  static func habit(_ id: String) -> String      { "habit:\(id)" }
  static func supplement(_ id: String) -> String { "supp:\(id)" }
  static func suggestion(_ id: String) -> String { "sugg:\(id)" }
  static func done(_ id: String) -> String       { "done:\(id)" }

  /// Split a tag back into its `(kind, id)` halves. The id may itself contain
  /// ":" (CloudKit record names don't, but be safe), so split on the first.
  static func split(_ tag: String) -> (kind: String, id: String) {
    guard let i = tag.firstIndex(of: ":") else { return ("", tag) }
    return (String(tag[..<i]), String(tag[tag.index(after: i)...]))
  }
}

// MARK: - Today tasks (inline on Next)
//
// Mirrors NextItemsModel for the Tasks slice — Next renders open Today tasks
// in due-date order above chores / habits / supplements. Full task editing still
// lives in the Tasks tab; this surface is a read-through checklist (tap to
// complete, tap again to uncomplete).

@MainActor
@Observable
final class TodayTasksModel {
  var tasks: [SeptenaTask] = []
  /// Tasks the user toggled this session — keeps them rendered in place
  /// (struck through) so the row doesn't hop the moment you check it.
  var actedTasks: Set<String> = []
  var hasLoaded: Bool = false
  /// Drives the "linger → fade" beat after a check (see `SettleStore`).
  let settle = SettleStore()

  func paintFromCache() {
    refreshFromCache()
    hasLoaded = true
  }

  func refreshFromCache() {
    let context = LocalStore.shared.container.mainContext
    let fresh = LocalCache.tasks(in: context, filter: .today)
    let freshByID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    // The `.today` query excludes done tasks, so a plain re-read would yank a
    // just-completed row out from under the settle beat — and this runs on
    // every `.septenaTasksChanged` (see NextView), which a completion posts.
    // Preserve session-acted rows the query now hides, in their current
    // position, so they linger struck through then fade rather than hop/vanish.
    var merged = tasks.compactMap { old -> SeptenaTask? in
      if let f = freshByID[old.id] { return f }        // still open → refreshed copy
      // Linger beat — both guards must win over the fresh read, because
      // `.septenaTasksChanged` can fire before the acted set is stamped.
      if actedTasks.contains(old.id) || settle.isSettling(old.id) { return old }
      return nil                                       // gone
    }
    let kept = Set(merged.map(\.id))
    merged.append(contentsOf: fresh.filter { !kept.contains($0.id) })  // newly arrived
    tasks = merged
    // Urgency sort on sync only — never while a row is mid-settle (that would
    // hop it). Completion keeps its in-list index; `openTasks` is a filter.
    if actedTasks.isEmpty {
      tasks.sort(by: SeptenaTask.compareNextPageOrder)
    }
  }

  func load(today: String, now: Date) async {
    let context = LocalStore.shared.container.mainContext
    // CloudKit-mode read: TaskReads.list returns LocalCache directly,
    // so we just need to ensure the mirror is fresh, then repaint.
    _ = await TaskReads.list(view: "today", today: today, now: now, context: context)
    // Clear session state BEFORE repainting so the merge in refreshFromCache
    // doesn't preserve now-stale lingering rows — load() is authoritative.
    actedTasks = []
    settle.cancelAll()
    refreshFromCache()
    hasLoaded = true
  }

  /// Open Today tasks, plus any toggled this session (so a just-completed
  /// row lingers struck through instead of vanishing under the finger).
  /// Order is whatever `tasks` holds — never re-sorted here, so a check
  /// can't hop the row (the Tasks tab uses the same in-place settle rule).
  var openTasks: [SeptenaTask] {
    tasks.filter {
      $0.status == .open || actedTasks.contains($0.id) || settle.isSettling($0.id)
    }
  }

  /// Task ids still in the open-list settle beat (struck through, not yet faded).
  /// The Done Today log filters these out so a row doesn't duplicate into the
  /// timeline until the linger ends — same contract as `actedChores` → `doneChores`.
  var lingeringDoneTaskIDs: Set<String> {
    Set(tasks.compactMap { t in
      guard t.status == .done,
            actedTasks.contains(t.id) || settle.isSettling(t.id) else { return nil }
      return t.id
    })
  }

  func toggle(_ task: SeptenaTask, mutator: TaskMutator, motion: A11yMotion) {
    // Flip status IN PLACE rather than re-reading from the cache: the Today
    // cache query excludes done tasks (Persistence `LocalCache.tasks(.today)`),
    // so a `refreshFromCache()` here would drop the just-completed row before
    // it could linger. Keeping it in `tasks` (struck through, held visible by
    // `actedTasks` + `settle`) is what lets it settle then fade.
    //
    // Order matches `TaskListView.toggle` / `TasksDestinationView.toggle`:
    // stamp the linger window and flip local state first; call the mutator
    // last so the `.septenaTasksChanged` refresh can't yank the row.
    guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
    if task.status == .done {
      Haptics.tap()
      settle.cancel(task.id)
      motion.run(Theme.Motion.settle) {
        tasks[i].status = .open
        _ = actedTasks.remove(task.id)
      }
      mutator.uncomplete(id: task.id)
    } else {
      // Done-side haptic is owned by the caller (TodayTaskRow), which fires
      // the context-scaled `TaskCelebration` haptic after this returns.
      actedTasks.insert(task.id)
      settle.schedule(task.id) { [weak self] in
        guard let self else { return }
        motion.run(Theme.Motion.settle) {
          self.settle.endSettle(task.id)
          _ = self.actedTasks.remove(task.id)
        }
      }
      motion.run(Theme.Motion.settle) { tasks[i].status = .done }
      mutator.complete(id: task.id)
    }
  }
}

struct TodayTaskRow: View {
  let task: SeptenaTask
  var model: TodayTasksModel
  let mutator: TaskMutator
  let tint: Color
  var areas: [Area] = []
  var projects: [Project] = []
  /// Native `List(selection:)` cursor — dark ink on the gray capsule.
  var isListSelected: Bool = false
  /// Open this task's edit / agent pane. nil → tap only toggles (no editor host).
  var onOpen: (() -> Void)? = nil
  @Environment(\.a11yMotion) private var motion
  /// App-root celebration layer — only used by the day-cleared `.arc`
  /// (see `TaskCelebration`). Optional and nil-safe.
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  /// The checkbox owns its own tap region; a tap on the rest of the row opens
  /// the editor. Platform split mirrors the Tasks tab:
  ///   • iOS: single tap → open (touch convention).
  ///   • macOS: the row's own tap is disabled (`nil`) so a single click stays
  ///     native `List` selection (the keyboard-nav cursor + context-menu
  ///     target); the caller wires double-click → open via a tap gesture.
  private var rowTap: (() -> Void)? {
    #if os(macOS)
    nil
    #else
    onOpen
    #endif
  }

  var body: some View {
    // On the Next surface every row is already today, so no Today indicator and
    // no scheduled chip; an overdue `due` still surfaces via the canonical
    // trailing. The project / area subtitle renders when the catalog is loaded.
    TaskRow(
      task: task,
      accent: tint,
      areas: areas,
      projects: projects,
      showsTodayIndicator: false,
      isListSelected: isListSelected,
      onToggle: {
        let completing = task.status != .done
        model.toggle(task, mutator: mutator, motion: motion)
        // Every row here is a Today task; if the check left nothing open
        // (the just-checked row lingers as done), today's list is clear.
        if completing {
          let clearedToday = !model.openTasks.contains { $0.status == .open && $0.isOnToday }
          TaskCelebration.completed(isToday: task.isOnToday, clearedToday: clearedToday,
                                    accent: tint, logCommit: logCommit)
        }
      },
      onTap: rowTap
    )
    // The per-row context menu + its picker sheets are attached by the caller
    // via `.taskRowActions(...)` (see `TaskRowActions`) — the same shared menu
    // the Tasks list uses, so Next and the list can't drift.
  }
}

// MARK: - Shared model

@MainActor
@Observable
final class NextItemsModel {
  var habits: [HabitDayItem] = []
  var habitBuckets: [String] = []
  /// Habit IDs backed by a "do it more" goal (see
  /// `ChecklistMirror.habitsWithGrowthGoal`). These get a quiet target mark and
  /// stay in the open list once done, so the habit you're building keeps a bit
  /// more presence in Next than the rest.
  var goalBackedHabitIDs: Set<String> = []
  var supplements: [SupplementDayItem] = []
  var chores: [ChoreItem] = []
  /// Chores deferred this session — kept visible (with badge) until reload.
  var deferredChores: [String: String] = [:]
  /// Chores marked done this session — the "is completed" flag the row reads.
  /// Distinct from `actedChores` (the linger set): completion must survive the
  /// settle beat, or the chore would un-complete as it fades.
  var completedChores: Set<String> = []
  /// Habits the user toggled/skipped this session. Keeps them rendered in
  /// the open list (struck through) so the row doesn't hop to the bottom
  /// the moment you check it.
  var actedHabits: Set<String> = []
  /// Same idea for supplements.
  var actedSupplements: Set<String> = []
  /// Same idea for chores — the linger set, separate from `completedChores`
  /// so the settle beat moves the row to Done without un-completing it.
  var actedChores: Set<String> = []
  /// Today's calendar events. No longer rendered in the Next *list* (calendar
  /// was removed from Next) — kept only to feed the homepage today-timeline
  /// card (`WeekDashboardTimelineCard`, via `WeekDashboardView.todayTimeline`),
  /// which is a separate ambient glance surface.
  var calendarEvents: [EKEvent] = []
  /// Drives the "linger → fade" beat after a check (see `SettleStore`). One
  /// store covers habits / supplements / chores — ids never collide.
  let settle = SettleStore()

  /// Flips true after the first network response (success or failure) so the
  /// empty state never flashes during the initial load.
  var hasLoaded: Bool = false

  // Updated by the owning view from `clock.today` on load / rollover.
  private var cachedToday: String = ""
  private var cachedNow: Date = Date()

  private var today: String { cachedToday }
  private var nowHHMM: String { EventTimestamp.hhmm(from: cachedNow) }

  private func stampNow(_ now: Date?) {
    if let now { cachedNow = now }
  }

  // MARK: - Open / Done splits (the source of truth for both subviews)
  //
  // A completed/skipped item lingers in the open list (struck through) for
  // the settle beat — `completedChores`/`actedHabits` etc. keep it there —
  // then drops into the Done split, which the "Done Today" log renders at the
  // bottom of Next.

  /// Show an item in the open list if it's still pending OR if the user
  /// just acted on it this session (keeps it from jumping to "done").
  var openHabits: [HabitDayItem] {
    habits.filter { h in
      actedHabits.contains(h.id) || (!h.done && !h.skipped) || isStickyGoalHabit(h)
    }
  }

  var doneHabits: [HabitDayItem] {
    habits.filter { h in
      !actedHabits.contains(h.id) && (h.done || h.skipped) && !isStickyGoalHabit(h)
    }
  }

  /// A goal-backed habit that's been completed (not skipped) stays in the open
  /// list — checked, in place — instead of dropping into the Done strip, so the
  /// habit you're deliberately building keeps its presence for the rest of its
  /// time-of-day window. A *skipped* one still drifts to Done (skipping is a
  /// deliberate set-aside; don't force stickiness on it).
  func isStickyGoalHabit(_ h: HabitDayItem) -> Bool {
    goalBackedHabitIDs.contains(h.id) && h.done && !h.skipped
  }

  var openSupplements: [SupplementDayItem] {
    supplements.filter { s in
      actedSupplements.contains(s.id) || (!s.done && !s.skipped)
    }
  }

  var doneSupplements: [SupplementDayItem] {
    supplements.filter { s in
      !actedSupplements.contains(s.id) && (s.done || s.skipped)
    }
  }

  /// Chores due today or overdue. A just-acted chore lingers in the open list
  /// (struck through) for the settle beat so it doesn't vanish under the
  /// finger; once the beat clears `actedChores` it drops into `doneChores`.
  var openChores: [ChoreItem] {
    chores
      .filter { $0.daysOverdue >= 0 }
      .filter { c in
        actedChores.contains(c.id)
          || (!completedChores.contains(c.id) && deferredChores[c.id] == nil)
      }
      .sorted { ($0.daysOverdue, $0.name) > ($1.daysOverdue, $1.name) }
  }

  /// Completed- or deferred-this-session chores that have finished lingering
  /// (no longer in `actedChores`) — they show in the Done strip.
  var doneChores: [ChoreItem] {
    chores.filter { c in
      !actedChores.contains(c.id)
        && (completedChores.contains(c.id) || deferredChores[c.id] != nil)
    }
  }

  var hasAnyOpen: Bool {
    !openHabits.isEmpty || !openSupplements.isEmpty || !openChores.isEmpty
  }

  var hasAnyDone: Bool {
    !doneHabits.isEmpty || !doneSupplements.isEmpty || !doneChores.isEmpty
  }

  // MARK: - Loading

  private enum CacheKey {
    static let habits        = "next.habits"
    static let habitBuckets  = "next.habitBuckets"
    static let supplements   = "next.supplements"
    static let chores        = "next.chores"
    static let growthGoals   = "next.growthGoals"
  }

  /// Synchronous cache prime — paints the last-known habits / supplements
  /// / chores snapshot on view appear, so screens that consume this model
  /// (Habits / Supplements / Chores destinations + Next) render real data
  /// on the first frame instead of empty sections while the network
  /// catches up. Reads only the fast `ResponseCache` blobs (a UserDefaults
  /// decode) — never the SwiftData mirror — so the synchronous first frame
  /// can't hitch the push transition. The authoritative mirror read happens
  /// off-main in `load()`, which also refreshes these blobs.
  func paintFromCache(today: String, now: Date? = nil) {
    cachedToday = today
    stampNow(now)
    if let v = ResponseCache.load([HabitDayItem].self, forKey: CacheKey.habits) { habits = v }
    if let v = ResponseCache.load([String].self, forKey: CacheKey.habitBuckets) { habitBuckets = v }
    if let v = ResponseCache.load([SupplementDayItem].self, forKey: CacheKey.supplements) { supplements = v }
    if let v = ResponseCache.load([ChoreItem].self, forKey: CacheKey.chores) { chores = v }
    if let v = ResponseCache.load([String].self, forKey: CacheKey.growthGoals) { goalBackedHabitIDs = Set(v) }
    calendarEvents = CalendarBridge.shared.todayEvents()
    hasLoaded = true
  }

  func load(today: String, now: Date? = nil) async {
    cachedToday = today
    stampNow(now)
    // Habits / Supplements / Chores are CloudKit-authoritative — read
    // directly from the local SwiftData mirror. CKEngine keeps it fresh
    // via fetchChanges() + silent pushes; no FastAPI fallback needed.
    // Run the (today-scoped) reads off the main actor via MirrorReader so
    // the fetch + JSON-decode cost never competes with the push transition;
    // assign the Sendable result back on the main actor below.
    let day = today
    let snap = await MirrorReader.shared.read { ctx in
      (habits: ChecklistMirror.loadHabitsDay(context: ctx, date: day),
       supplements: ChecklistMirror.loadSupplementsDay(context: ctx, date: day),
       chores: ChecklistMirror.loadChores(context: ctx, today: day),
       growthGoals: ChecklistMirror.habitsWithGrowthGoal(context: ctx))
    }

    if let hRes = snap.habits {
      habits = hRes.buckets.flatMap { hRes.grouped[$0] ?? [] }
      habitBuckets = hRes.buckets
      ResponseCache.save(habits, forKey: CacheKey.habits)
      ResponseCache.save(habitBuckets, forKey: CacheKey.habitBuckets)
    }

    goalBackedHabitIDs = snap.growthGoals
    ResponseCache.save(Array(snap.growthGoals), forKey: CacheKey.growthGoals)

    if let sRes = snap.supplements {
      supplements = sRes.items
      ResponseCache.save(supplements, forKey: CacheKey.supplements)
    }

    chores = snap.chores
    if !snap.chores.isEmpty {
      ResponseCache.save(snap.chores, forKey: CacheKey.chores)
    }

    // Local EventKit fetch — no network. Feeds the homepage today-timeline
    // card only; the Next list no longer renders calendar.
    calendarEvents = CalendarBridge.shared.todayEvents()
    // Reload clears the per-session "kept visible" buckets — server is now
    // the source of truth.
    deferredChores = [:]
    completedChores = []
    actedHabits = []
    actedSupplements = []
    actedChores = []
    settle.cancelAll()
    hasLoaded = true
  }

  // MARK: - Mutations (optimistic local flips, server-side write)

  func toggleHabit(_ habit: HabitDayItem, mutator: ChecklistMutator, motion: A11yMotion,
                   now: Date? = nil) {
    stampNow(now)
    let next = !habit.done
    // Done-side haptic is owned by the caller (HabitRow), which can reach
    // the environment and branch milestone (.ignition) vs everyday (the
    // shared checkbox `.stamp`). Undo stays a light tap here so every host
    // feels the un-check.
    if !next { Haptics.tap() }
    if let i = habits.firstIndex(where: { $0.id == habit.id }) {
      habits[i].done = next
      if next { habits[i].skipped = false }
      habits[i].time = next ? nowHHMM : nil
    }
    actedHabits.insert(habit.id)
    mutator.toggleHabit(id: habit.id, date: today, done: next)
    settleActed(habit.id, in: \.actedHabits, done: next, motion: motion)
  }

  func skipHabit(_ habit: HabitDayItem, skipped: Bool, mutator: ChecklistMutator, motion: A11yMotion) {
    Haptics.tick()
    if let i = habits.firstIndex(where: { $0.id == habit.id }) {
      habits[i].skipped = skipped
      if skipped {
        habits[i].done = false
        habits[i].time = nil
      }
    }
    actedHabits.insert(habit.id)
    mutator.skipHabit(id: habit.id, date: today, skipped: skipped)
    // A skip drifts into Done the same way a completion does; un-skip keeps it.
    settleActed(habit.id, in: \.actedHabits, done: skipped, motion: motion)
  }

  func toggleSupplement(_ supp: SupplementDayItem, mutator: ChecklistMutator, motion: A11yMotion,
                        now: Date? = nil) {
    stampNow(now)
    let next = !supp.done
    // Taken-side haptic is owned by the caller (SupplementRow) — the
    // checkbox plays the shared `.stamp` feel; undo stays a light tap here.
    if !next { Haptics.tap() }
    if let i = supplements.firstIndex(where: { $0.id == supp.id }) {
      supplements[i].done = next
      if next { supplements[i].skipped = false }
      supplements[i].time = next ? nowHHMM : nil
    }
    actedSupplements.insert(supp.id)
    mutator.toggleSupplement(id: supp.id, date: today, done: next)
    settleActed(supp.id, in: \.actedSupplements, done: next, motion: motion)
  }

  func skipSupplement(_ supp: SupplementDayItem, skipped: Bool, mutator: ChecklistMutator, motion: A11yMotion) {
    Haptics.tick()
    if let i = supplements.firstIndex(where: { $0.id == supp.id }) {
      supplements[i].skipped = skipped
      if skipped {
        supplements[i].done = false
        supplements[i].time = nil
      }
    }
    actedSupplements.insert(supp.id)
    mutator.skipSupplement(id: supp.id, date: today, skipped: skipped)
    // A skip drifts into Done the same way a completion does; un-skip keeps it.
    settleActed(supp.id, in: \.actedSupplements, done: skipped, motion: motion)
  }

  func completeChore(_ chore: ChoreItem, mutator: ChecklistMutator, motion: A11yMotion,
                     now: Date? = nil) {
    stampNow(now)
    // Completion haptic is owned by the caller (ChoreRow) — the checkbox
    // plays the shared `.stamp` feel.
    completedChores.insert(chore.id)
    actedChores.insert(chore.id)
    deferredChores.removeValue(forKey: chore.id)
    if let i = chores.firstIndex(where: { $0.id == chore.id }) {
      chores[i].lastCompleted = today
      chores[i].lastCompletedTime = nowHHMM
    }
    mutator.completeChore(id: chore.id, date: today)
    // Linger struck through, then fade into Done. We clear `actedChores` (the
    // linger set) — NOT `completedChores` — so the chore stays *completed* as
    // it moves from the open list to the Done strip.
    settle.schedule(chore.id) { [weak self] in
      motion.run(Theme.Motion.settle) {
        self?.settle.endSettle(chore.id)
        _ = self?.actedChores.remove(chore.id)
      }
    }
  }

  /// Shared "linger → fade" wiring for the acted-set rows (habits / supplements).
  /// When `done`, schedule the id to drop out of the acted set after the beat
  /// (which moves it from the open split into the done split); otherwise cancel
  /// any pending fade so an un-check stays put.
  private func settleActed(_ id: String,
                           in keyPath: ReferenceWritableKeyPath<NextItemsModel, Set<String>>,
                           done: Bool, motion: A11yMotion) {
    guard done else { settle.cancel(id); return }
    settle.schedule(id) { [weak self] in
      guard let self else { return }
      motion.run(Theme.Motion.settle) {
        self.settle.endSettle(id)
        _ = self[keyPath: keyPath].remove(id)
      }
    }
  }

  func deferChore(_ chore: ChoreItem, mode: String, label: String, mutator: ChecklistMutator) {
    Haptics.tick()
    deferredChores[chore.id] = label
    completedChores.remove(chore.id)
    mutator.deferChore(id: chore.id, mode: mode, from: today)
  }

  /// Pull a future-dated chore into the Today bucket. Unlike `deferChore`,
  /// the chore stays actionable — we set `daysOverdue = 0` so the row lands
  /// in the active Today section instead of getting a strikethrough pill.
  func bringChoreToToday(_ chore: ChoreItem, mutator: ChecklistMutator) {
    Haptics.tick()
    deferredChores.removeValue(forKey: chore.id)
    completedChores.remove(chore.id)
    if let i = chores.firstIndex(where: { $0.id == chore.id }) {
      chores[i].dueDate = today
      chores[i].daysOverdue = 0
    }
    mutator.deferChore(id: chore.id, mode: "today", from: today)
  }

  func uncompleteChore(_ chore: ChoreItem, mutator: ChecklistMutator) {
    Haptics.tap()
    settle.cancel(chore.id)
    completedChores.remove(chore.id)
    actedChores.remove(chore.id)
    if let i = chores.firstIndex(where: { $0.id == chore.id }) {
      chores[i].lastCompleted = nil
      chores[i].lastCompletedTime = nil
    }
    mutator.uncompleteChore(id: chore.id, date: today)
  }

  // MARK: - Daily clear-out (canvas celebration)
  //
  // Completing the last open item in a daily checklist clears the whole day's
  // stack — the same at-most-once-a-day "you finished" moment as clearing your
  // last Today task. The rows read these after their optimistic flip and, when
  // true, fire the canvas burst. "Open" excludes the deliberately set-aside
  // (skipped habits, deferred chores); an empty list is never a clear-out.

  /// No habit is still open (every one done or skipped) and there was at least one.
  var habitsAllCleared: Bool {
    !habits.isEmpty && !habits.contains { !$0.done && !$0.skipped }
  }
  /// No supplement still open (every one taken or skipped) and there was one.
  var supplementsAllCleared: Bool {
    !supplements.isEmpty && !supplements.contains { !$0.done && !$0.skipped }
  }
  /// No chore still open (every one completed or deferred away) and there was one.
  var choresAllCleared: Bool {
    !chores.isEmpty && !chores.contains {
      !completedChores.contains($0.id) && deferredChores[$0.id] == nil
    }
  }
}

// MARK: - Open subview (rendered above tasks-done)
//
// `NextLinger` (the "carry over missed items" keys/defaults) now lives in
// SeptenaCore/NextWire.swift so the iOS Next list, the watch, and the widget
// snapshot filter all share one contract.

struct NextOpenSection: View {
  var model: NextItemsModel
  var tasksModel: TodayTasksModel
  /// Page-level `List(selection:)` — drives row highlight + keyboard cursor.
  var selection: Set<String> = []
  /// Backing catalog for each task row's project / area subtitle + the task
  /// menu's pickers. Loaded once up in `NextView` (small, effectively static)
  /// and threaded down so the Tasks block doesn't re-fetch.
  var areas: [Area] = []
  var projects: [Project] = []
  /// Open a task's edit / agent pane — handed down to the Tasks block's rows.
  /// nil keeps tasks a read-through checklist.
  var onOpenTask: ((SeptenaTask) -> Void)? = nil
  /// macOS click-selection for a task row (honors ⌘/⇧). A tap gesture on the
  /// row defeats native `List` click-selection, so the gesture writes the
  /// page's selection set itself. Unused on iOS. See `NextView.clickSelectTask`.
  var onClickSelect: (String) -> Void = { _ in }
  /// Quick-add from the Tasks section header's trailing "+". nil hides the
  /// button (e.g. a read-only host).
  var onAddTask: (() -> Void)? = nil
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(SectionTheme.self) private var theme
  // Per-section "carry over missed items" prefs (see `NextLinger`). Read here
  // and written by the section-settings toggles; @AppStorage keeps the Next
  // feed in sync the instant either is flipped.
  @AppStorage(NextLinger.supplementsKey) private var lingerSupplements = NextLinger.supplementsDefault
  @AppStorage(NextLinger.habitsKey) private var lingerHabits = NextLinger.habitsDefault

  /// The Next blocks in the user's saved section order, via the shared
  /// `NextFeed` ordering rule (the same one the watch snapshot uses) so the
  /// list never diverges from the watch. Reads the reactive `SettingsStore`
  /// so reordering in Settings updates the list live.
  private var orderedKeys: [String] {
    NextFeed.nextSectionKeys(from: settingsStore.sections)
  }

  /// Habits and supplements are bucketed identically (see `DayBucket.isDueNow`):
  /// an "anytime" item shows all day; a bucketed one shows in its window, and
  /// with the section's "carry over missed items" toggle on also lingers through
  /// later buckets until done. Habits default to strict (exactly now),
  /// supplements to carry-over — the same single rule the watch/widget snapshot
  /// uses (`itemsForBucket`), so the surfaces never disagree.
  private var habitsNow: [HabitDayItem] {
    model.openHabits.filter { DayBucket.isDueNow(bucketKey: $0.bucket, linger: lingerHabits) }
  }

  private var supplementsNow: [SupplementDayItem] {
    model.openSupplements.filter { DayBucket.isDueNow(bucketKey: $0.bucket, linger: lingerSupplements) }
  }

  private func isEmpty(_ key: String) -> Bool {
    switch key {
    case "tasks":       return tasksModel.openTasks.isEmpty
    case "chores":      return model.openChores.isEmpty
    case "habits":      return habitsNow.isEmpty
    case "supplements": return supplementsNow.isEmpty
    default:
      // `orderedKeys` only ever yields `NextBlocks` members, so a key with
      // no case here means a row was added to the table without a render
      // case. Fail loudly in debug; hide it in release rather than crash.
      assertionFailure("NextOpenSection has no case for Next block '\(key)'")
      return true
    }
  }

  // One native `Section` per visible block, in the user's saved order. A
  // `ForEach` whose closure yields `Section`s is SwiftUI's dynamic-sections
  // pattern — `List` flattens them into the grouped layout (was a hand-rolled
  // VStack of "pill" cards + a wide-screen masonry, both retired with the
  // single-column List).
  var body: some View {
    let visible = orderedKeys.filter { !isEmpty($0) }
    ForEach(visible, id: \.self) { key in
      block(for: key)
    }
  }

  @ViewBuilder
  private func block(for key: String) -> some View {
    switch key {
    case "tasks":
      nextSection(header: {
        ListSectionHeaderTitle(title: "Tasks Today",
                               onAdd: onAddTask,
                               addAccessibilityLabel: "Add task",
                               accent: theme.color(for: "tasks"))
      }) {
        let tasks = tasksModel.openTasks
        ForEach(Array(tasks.enumerated()), id: \.element.id) { idx, task in
          let tag = NextRowTag.task(task.id)
          TodayTaskRow(task: task, model: tasksModel, mutator: taskMutator,
                       tint: theme.color(for: "tasks"),
                       areas: areas, projects: projects,
                       isListSelected: selection.contains(tag),
                       onOpen: onOpenTask.map { open in { open(task) } })
            // The full task menu (Edit Details… / When… / Deadline… / Move… /
            // Repeat… / Today / Cancel / Delete) + its picker sheets, shared
            // with the Tasks list so the two surfaces never drift.
            .taskRowActions(task: task, areas: areas, projects: projects,
                            mutator: taskMutator, onOpenDetail: onOpenTask)
            // macOS: single click selects (the row's own tap is nil'd in
            // `TodayTaskRow`), double-click opens — the same convention the
            // Tasks tab uses. iOS keeps single-tap-to-open via the row.
            #if os(macOS)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
              onClickSelect(task.id); onOpenTask?(task)
            })
            .simultaneousGesture(TapGesture(count: 1).onEnded {
              onClickSelect(task.id)
            })
            #endif
            .septenaNextRow(tag: tag, isSelected: selection.contains(tag),
                            index: idx, count: tasks.count)
            .transition(.opacity)
        }
      }

    case "chores":
      nextSection(header: { sectionHeader("Chores") }) {
        let chores = model.openChores
        ForEach(Array(chores.enumerated()), id: \.element.id) { idx, chore in
          let tag = NextRowTag.chore(chore.id)
          ChoreRow(chore: chore, model: model, checklistMutator: checklistMutator,
                   tint: theme.color(for: "chores"),
                   isListSelected: selection.contains(tag))
            .septenaNextRow(tag: tag, isSelected: selection.contains(tag),
                            index: idx, count: chores.count)
        }
      }

    case "habits":
      nextSection(header: { bucketSectionHeader("Habits", showsCountdown: !lingerHabits) }) {
        let habits = habitsNow
        ForEach(Array(habits.enumerated()), id: \.element.id) { idx, habit in
          let tag = NextRowTag.habit(habit.id)
          HabitRow(habit: habit, model: model, checklistMutator: checklistMutator,
                   tint: theme.color(for: "habits"),
                   isListSelected: selection.contains(tag))
            .septenaNextRow(tag: tag, isSelected: selection.contains(tag),
                            index: idx, count: habits.count)
        }
      }

    case "supplements":
      nextSection(header: { bucketSectionHeader("Supplements", showsCountdown: !lingerSupplements) }) {
        let supps = supplementsNow
        ForEach(Array(supps.enumerated()), id: \.element.id) { idx, supp in
          let tag = NextRowTag.supplement(supp.id)
          SupplementRow(supplement: supp, model: model, checklistMutator: checklistMutator,
                        tint: theme.color(for: "supplements"),
                        isListSelected: selection.contains(tag))
            .septenaNextRow(tag: tag, isSelected: selection.contains(tag),
                            index: idx, count: supps.count)
        }
      }

    default:
      // Unreachable: `isEmpty(_:)` already hides (and asserts on) any
      // member key without a case. Kept exhaustive so a new `NextBlocks`
      // row fails loudly here too rather than silently rendering nothing.
      let _ = { assertionFailure("NextOpenSection.block(for:) has no case for '\(key)'") }()
      EmptyView()
    }
  }
}

// MARK: - Done Today timeline
//
// A single chronological log of everything finished today — not a second
// copy of the open list. Two sources merge into one time-sorted stream:
//   • the checklist trio (chores / habits / supplements) from `NextItemsModel`,
//     so an item the user just ticked off appears here the instant its settle
//     beat ends (live session state, no refetch);
//   • passive logs (intake, gut, mood, meals, training, completed
//     tasks) from `NextDoneModel`, read off the local mirror.
// Newest at top, so the freshest completion lands right under the open list.

/// Shared merge for the Done Today log — used by the section renderer and
/// `NextView`'s keyboard-order walk so ↑↓ traverse the full timeline.
@MainActor
enum NextDoneEvents {
  static func merged(model: NextItemsModel, passive: [DoneEvent],
                     lingeringTaskIDs: Set<String> = []) -> [DoneEvent] {
    var out = passive.filter { event in
      guard event.sectionKey == "tasks", event.id.hasPrefix("task-") else { return true }
      let taskID = String(event.id.dropFirst("task-".count))
      return !lingeringTaskIDs.contains(taskID)
    }
    for c in model.doneChores {
      out.append(.init(id: "chore-\(c.id)", hour: c.lastCompletedTime.flatMap(DoneEvent.hour(from:)) ?? -1,
                       time: c.lastCompletedTime, label: c.name, detail: nil,
                       sectionKey: "chores", moodQuadrant: nil))
    }
    for h in model.doneHabits {
      out.append(.init(id: "habit-\(h.id)", hour: h.time.flatMap(DoneEvent.hour(from:)) ?? -1,
                       time: h.time, label: h.name,
                       detail: (h.skipped && !h.done) ? "skipped" : nil,
                       sectionKey: "habits", moodQuadrant: nil))
    }
    for s in model.doneSupplements {
      out.append(.init(id: "supp-\(s.id)", hour: s.time.flatMap(DoneEvent.hour(from:)) ?? -1,
                       time: s.time, label: s.name, detail: nil,
                       sectionKey: "supplements", moodQuadrant: nil))
    }
    return out.sorted { $0.hour > $1.hour }
  }
}

// MARK: - Done Today section

/// One row in the Done Today log. Value type (no `Color`) so it crosses the
/// `MirrorReader` actor boundary; the row view resolves color from the
/// `sectionKey` (or `moodQuadrant`) at render time.
struct DoneEvent: Identifiable, Sendable {
  let id: String
  /// Fractional hour-of-day for sorting. `-1` for timeless items (e.g. a
  /// skipped habit) so they sink to the bottom.
  let hour: Double
  let time: String?       // "HH:MM" display, nil when timeless
  let label: String
  let detail: String?     // trailing secondary text (grams, kcal, set count…)
  let sectionKey: String  // drives the dot color + icon via SectionTheme
  let moodQuadrant: String? // non-nil only for mood → colored by quadrant

  static func hour(from hhmm: String) -> Double? {
    let parts = hhmm.split(separator: ":")
    guard parts.count >= 2, let h = Double(parts[0]), let m = Double(parts[1]) else { return nil }
    return h + m / 60
  }
}

/// Loads today's passive logs (everything that doesn't pass through the Next
/// open list) for the Done Today timeline. Mirror reads run off-main via
/// `MirrorReader`; tasks come from the `@MainActor` `TaskReads`.
@Observable
final class NextDoneModel {
  private(set) var events: [DoneEvent] = []
  var hasLoaded = false

  func load(today: String, now: Date) async {
    let date = today
    let mirror = await MirrorReader.shared.read { ctx in
      NextDoneModel.collect(ctx: ctx, date: date)
    }
    let tasks = await Self.collectTasks(date: date, now: now)
    events = (mirror + tasks).sorted { $0.hour > $1.hour }
    hasLoaded = true
  }

  @MainActor
  private static func collectTasks(date: String, now: Date) async -> [DoneEvent] {
    let ctx = LocalStore.shared.container.mainContext
    let resp = await TaskReads.list(view: "logbook", days: 1,
                                    today: date, now: now, context: ctx)
    return resp.items.compactMap { t -> DoneEvent? in
      guard t.status == .done, let ts = t.completedAt,
            ts.hasPrefix(date), ts.count >= 16 else { return nil }
      let hhmm = String(ts.dropFirst(11).prefix(5))
      return DoneEvent(id: "task-\(t.id)", hour: DoneEvent.hour(from: hhmm) ?? -1,
                       time: hhmm, label: t.title, detail: nil,
                       sectionKey: "tasks", moodQuadrant: nil)
    }
  }

  private static func collect(ctx: ModelContext, date: String) -> [DoneEvent] {
    var out: [DoneEvent] = []

    // Wake time from today's Oura night. Reads the same cached blob the Week
    // dashboard fills (`CacheKey.ouraNights`); only the night dated today
    // counts, so a missed sync shows nothing rather than yesterday's wake.
    if let nights = ResponseCache.load([OuraNight].self, forKey: "week.ouraNights"),
       let night = nights.first(where: { $0.date == date }),
       let wake = night.wakeTime {
      out.append(.init(id: "wake-\(date)", hour: DoneEvent.hour(from: wake) ?? -1,
                       time: wake, label: "Woke up", detail: nil,
                       sectionKey: "sleep", moodQuadrant: nil))
    }

    for e in ChecklistMirror.loadGutDay(context: ctx, date: date).entries {
      out.append(.init(id: "gut-\(e.id)", hour: DoneEvent.hour(from: e.time) ?? -1,
                       time: e.time, label: "Gut event",
                       detail: "Bristol \(e.bristol)", sectionKey: "gut", moodQuadrant: nil))
    }

    for e in ChecklistMirror.loadMoodDay(context: ctx, date: date).entries {
      let hhmm = String(e.time.prefix(5))
      out.append(.init(id: "mood-\(e.id)", hour: DoneEvent.hour(from: hhmm) ?? -1,
                       time: hhmm, label: e.emotion, detail: nil,
                       sectionKey: "mood", moodQuadrant: e.quadrant))
    }

    for e in ChecklistMirror.loadNutritionToday(context: ctx, today: date) {
      let label = e.foods.first ?? e.emoji ?? "Meal"
      out.append(.init(id: "nut-\(e.id)", hour: DoneEvent.hour(from: e.time) ?? -1,
                       time: e.time, label: label, detail: "\(Int(e.kcal)) kcal",
                       sectionKey: "nutrition", moodQuadrant: nil))
    }

    // Training: collapse a session's many sets into one row (earliest set
    // start = the row's time, count = sets logged).
    var sessions: [String: (hour: Double, time: String, count: Int)] = [:]
    for e in ChecklistMirror.loadTrainingEntries(context: ctx, since: date) where e.date == date {
      guard let c = e.concludedAt, c.count >= 16 else { continue }
      let hhmm = String(c.dropFirst(11).prefix(5))
      guard let h = DoneEvent.hour(from: hhmm) else { continue }
      let key = e.session.isEmpty ? "session" : e.session
      var s = sessions[key] ?? (hour: h, time: hhmm, count: 0)
      s.count += 1
      if h < s.hour { s.hour = h; s.time = hhmm }
      sessions[key] = s
    }
    for (key, s) in sessions {
      out.append(.init(id: "train-\(key)", hour: s.hour, time: s.time,
                       label: key == "session" ? "Workout" : key.capitalized,
                       detail: "\(s.count) \(s.count == 1 ? "set" : "sets")",
                       sectionKey: "training", moodQuadrant: nil))
    }

    return out
  }
}

struct NextDoneSection: View {
  /// Live session state for the checklist trio (chores / habits / supplements).
  var model: NextItemsModel
  /// Today's passive logs (intake / gut / mood / meals /
  /// training / completed tasks).
  var passive: [DoneEvent]
  /// Tasks still in the open-list settle beat — withheld from the log until fade.
  var lingeringTaskIDs: Set<String> = []
  /// Fold state for the Done Today log — persisted by the caller via AppStorage.
  @Binding var isCollapsed: Bool
  /// Page-level `List(selection:)` — drives row highlight + keyboard cursor.
  var selection: Set<String> = []
  /// Open the editor for an editable done-row (mood / gut / nutrition). The
  /// editor presentation itself is hosted up in `NextView`, on the `List`
  /// container — NOT here. Attaching `adaptiveDetail` (a macOS `.inspector`)
  /// to this `Section` collapses it, laying its rows out sideways instead of
  /// stacked; the presentation must live outside the List.
  var onEdit: (DoneEvent) -> Void
  /// Delete an editable done-row through its section mutator.
  var onDelete: (DoneEvent) -> Void
  @Environment(SectionTheme.self) private var theme

  // Edit/Delete from the Done log apply only to the kinds whose `DoneEvent.id`
  // resolves back to a single live entity (mood / gut / nutrition). Training is
  // a collapsed session and "woke up" has no record, so those stay read-only.
  private static let editableKeys: Set<String> = ["mood", "gut", "nutrition"]
  private func isEditable(_ e: DoneEvent) -> Bool { Self.editableKeys.contains(e.sectionKey) }

  /// Merge the trio's live done splits with the passive logs into one
  /// newest-first stream.
  private var events: [DoneEvent] {
    NextDoneEvents.merged(model: model, passive: passive,
                          lingeringTaskIDs: lingeringTaskIDs)
  }

  var body: some View {
    // Pure list `Section` — no presentation modifiers. Mood / gut / nutrition
    // get their home Edit + Delete menu (delegated up to `NextView`); the rest
    // of the log (tasks, the trio's done splits, training, wake) stays a
    // read-through record. The log folds away behind its header (chevron +
    // count) so the open work stays in focus.
    let items = events
    nextSection(header: {
      nextFoldableSectionHeader(title: "Done Today", count: items.count,
                                isCollapsed: isCollapsed) {
        Haptics.tick()
        withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() }
      }
    }) {
      if !isCollapsed {
        ForEach(Array(items.enumerated()), id: \.element.id) { idx, event in
          let tag = NextRowTag.done(event.id)
          DoneEventRow(
            event: event,
            onEdit: isEditable(event) ? { onEdit(event) } : nil,
            onDelete: isEditable(event) ? { onDelete(event) } : nil
          )
          .septenaNextRow(tag: tag, isSelected: selection.contains(tag),
                          index: idx, count: items.count)
        }
      }
    }
  }
}

/// One timeline row: time chip · section-color dot · label · trailing detail.
private struct DoneEventRow: View {
  let event: DoneEvent
  /// Open the entry's editor. nil → read-only row (no menu).
  var onEdit: (() -> Void)? = nil
  /// Delete the entry. nil → read-only row (no menu).
  var onDelete: (() -> Void)? = nil
  @Environment(SectionTheme.self) private var theme
  @Environment(\.rowHInset) private var rowHInset

  var body: some View {
    // Attach the menu only when the row is actionable — an empty `.contextMenu`
    // would arm a long-press that opens nothing.
    if onEdit == nil && onDelete == nil {
      row
    } else {
      row.contextMenu {
        if let onEdit {
          Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
        }
        if let onDelete {
          Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
        }
      }
    }
  }

  private var row: some View {
    let color = event.moodQuadrant.flatMap { MoodQuadrant(rawValue: $0)?.color }
      ?? theme.color(for: event.sectionKey)
    return HStack(spacing: 10) {
      Text(event.time ?? "—")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 42, alignment: .trailing)
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(event.label)
        .font(.callout)
        .foregroundStyle(Theme.inkPrimary)
        .lineLimit(1)
      Spacer(minLength: 8)
      if let detail = event.detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 7)
    .padding(.horizontal, rowHInset)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Row primitives

// Shared by NextOpenSection (current-bucket strip) and HabitsDestinationView
// (full all-day list). `onDelete` is supplied by destinations that own the
// underlying record (e.g. the Habits mini-app); Next leaves it nil since
// it never deletes inline.
struct HabitRow: View {
  let habit: HabitDayItem
  var model: NextItemsModel
  let checklistMutator: ChecklistMutator
  let tint: Color
  var onDelete: (() -> Void)? = nil
  /// Native `List(selection:)` cursor — dark ink on the gray capsule.
  var isListSelected: Bool = false
  /// When set (the Habits checklist passes it), the row's trailing slot shows
  /// this 30-day completion rate (NN%) instead of the time-of-day — a
  /// glanceable consistency read on every habit. nil elsewhere (Next feed),
  /// where the time-of-day stays.
  var completionRate: Int? = nil
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(\.a11yMotion) private var motion
  // Optional — HabitRow renders in multiple hosts (Next tab, Habits sheet);
  // not all inherit the root env. nil → celebration no-ops, toggle still runs.
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
  @Environment(DayClock.self) private var clock

  /// Toggle + (on done) the shared `.stamp` celebration at the checkbox.
  /// The haptic is the matched stamp, a touch fuller as the day's count grows.
  private func commitToggle() {
    let done = !habit.done
    model.toggleHabit(habit, mutator: checklistMutator, motion: motion, now: clock.now)
    guard done else { return }
    let doneInBucket = model.habits.filter { $0.bucket == habit.bucket && $0.done }.count
    Haptics.play(CheckFeel.stamp.hapticSpec(intensity: 0.8 + Double(doneInBucket) * 0.1))
    if model.habitsAllCleared {
      logCommit?.fire(.flourish(motion: .burst, accent: tint, intensity: 1))
    }
  }

  var body: some View {
    let inactive = habit.done || habit.skipped
    CheckableRow(
      tint: habit.skipped && !habit.done ? Theme.inkSecondary : tint,
      isDone: inactive,
      feel: .stamp,
      isInactive: inactive,
      leadingEmoji: habit.emoji ?? "•",
      title: habit.name,
      isListSelected: isListSelected,
      trailing: {
        HStack(spacing: 6) {
          // Quiet mark for a habit you've set a "do it more" goal on — a small
          // target glyph in the section tint, low-key so it reads as "this is
          // one you're building," never as a nag.
          if model.goalBackedHabitIDs.contains(habit.id) {
            Image(systemName: "target")
              .font(.body)
              .foregroundStyle(tint.opacity(0.7))
              .accessibilityLabel("Goal habit")
          }
          if habit.skipped {
            StatusBadge(text: "Skipped")
          } else if let rate = completionRate {
            CompletionRateBadge(percent: rate, tint: tint)
          } else if let t = habit.time {
            Text(t).font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
          }
        }
      },
      onToggle: { commitToggle() }
    )
    .contextMenu {
      Button { commitToggle() } label: {
        Label(habit.done ? "Mark not done" : "Mark done",
              systemImage: habit.done ? "arrow.uturn.left" : "checkmark")
      }
      Button {
        model.skipHabit(habit, skipped: !habit.skipped, mutator: checklistMutator, motion: motion)
      } label: {
        Label(habit.skipped ? "Unskip" : "Skip today",
              systemImage: habit.skipped ? "arrow.uturn.left" : "forward.end")
      }
      if let onDelete {
        Divider()
        Button(role: .destructive) { onDelete() } label: {
          Label("Delete", systemImage: "trash")
        }
      }
    }
  }
}

// Shared by NextOpenSection and SupplementsDestinationView. Same toggle
// semantics as HabitRow without the skip vocab — supplements are simpler
// (taken / not taken).
struct SupplementRow: View {
  let supplement: SupplementDayItem
  var model: NextItemsModel
  let checklistMutator: ChecklistMutator
  let tint: Color
  var onDelete: (() -> Void)? = nil
  /// Native `List(selection:)` cursor — dark ink on the gray capsule.
  var isListSelected: Bool = false
  /// 30-day completion rate shown in the trailing slot (instead of the
  /// time-of-day) when the Supplements checklist passes it. nil in the Next
  /// feed, where the time stays.
  var completionRate: Int? = nil
  @Environment(\.a11yMotion) private var motion
  // Optional — SupplementRow renders in multiple hosts; not all inherit the
  // root env. nil → the clear-out burst no-ops, toggle still runs.
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
  @Environment(DayClock.self) private var clock

  /// Toggle + (on taken) the shared `.stamp` celebration at the checkbox
  /// (standardized across all checkable rows). The haptic is the matched
  /// stamp, a touch fuller as the day's count grows. Undo's light tap is
  /// handled inside the model.
  private func commitToggle() {
    let taken = !supplement.done
    model.toggleSupplement(supplement, mutator: checklistMutator, motion: motion, now: clock.now)
    guard taken else { return }
    let count = model.supplements.filter { $0.done }.count
    Haptics.play(CheckFeel.stamp.hapticSpec(intensity: 0.8 + Double(count) * 0.08))
    // Took the last one — the whole day's supplements are done; the canvas
    // earns a burst.
    if model.supplementsAllCleared {
      logCommit?.fire(.flourish(motion: .burst, accent: tint, intensity: 1))
    }
  }

  var body: some View {
    let inactive = supplement.done || supplement.skipped
    CheckableRow(
      tint: supplement.skipped && !supplement.done ? Theme.inkSecondary : tint,
      isDone: inactive,
      feel: .stamp,
      isInactive: inactive,
      leadingEmoji: supplement.emoji ?? "•",
      title: supplement.name,
      isListSelected: isListSelected,
      trailing: {
        if supplement.skipped {
          StatusBadge(text: "Skipped")
        } else if let rate = completionRate {
          CompletionRateBadge(percent: rate, tint: tint)
        } else if let t = supplement.time {
          Text(t).font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
        }
      },
      onToggle: { commitToggle() }
    )
    // Consistent with the other Next rows: long-press always offers a menu.
    // Mark taken/not-taken mirrors the checkbox for discoverability; Skip
    // marks the supplement not-needed today (mirrors habits); Delete shows
    // only where a host owns the record (the Supplements mini-app).
    .contextMenu {
      Button {
        commitToggle()
      } label: {
        Label(supplement.done ? "Mark not taken" : "Mark taken",
              systemImage: supplement.done ? "arrow.uturn.left" : "checkmark")
      }
      Button {
        model.skipSupplement(supplement, skipped: !supplement.skipped,
                             mutator: checklistMutator, motion: motion)
      } label: {
        Label(supplement.skipped ? "Unskip" : "Skip today",
              systemImage: supplement.skipped ? "arrow.uturn.left" : "forward.end")
      }
      if let onDelete {
        Divider()
        Button(role: .destructive) { onDelete() } label: {
          Label("Delete", systemImage: "trash")
        }
      }
    }
  }
}

// Shared by NextOpenSection and ChoresDestinationView. Tap completes,
// long-press exposes defer + (when supplied) delete. Defer is hidden
// once the chore is done or has been deferred this session.
struct ChoreRow: View {
  let chore: ChoreItem
  var model: NextItemsModel
  let checklistMutator: ChecklistMutator
  let tint: Color
  var onDelete: (() -> Void)? = nil
  /// Native `List(selection:)` cursor — dark ink on the gray capsule.
  var isListSelected: Bool = false
  @Environment(\.a11yMotion) private var motion
  // Optional — ChoreRow renders in multiple hosts; not all inherit the root
  // env. nil → the clear-out burst no-ops, completion still runs.
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
  @Environment(DayClock.self) private var clock

  var body: some View {
    let isDone = model.completedChores.contains(chore.id)
    let deferLabel = model.deferredChores[chore.id]
    let inactive = isDone || deferLabel != nil

    CheckableRow(
      tint: deferLabel != nil ? Theme.inkSecondary : tint,
      isDone: inactive,
      feel: .stamp,
      isInactive: inactive,
      leadingEmoji: chore.emoji ?? "•",
      title: chore.name,
      isListSelected: isListSelected,
      trailing: {
        if isDone {
          // Show when it was completed (persisted via the chore's complete
          // event), matching the time treatment on habit / supplement rows.
          // Falls back to a "Done" badge if no time was recorded.
          if let t = chore.lastCompletedTime, !t.isEmpty {
            Text(t).font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
          } else {
            StatusBadge(text: "Done")
          }
        } else if let label = deferLabel {
          StatusBadge(text: label)
        } else {
          choreOverdueBadge(chore.daysOverdue)
        }
      },
      onToggle: {
        if isDone {
          model.uncompleteChore(chore, mutator: checklistMutator)
        } else {
          model.completeChore(chore, mutator: checklistMutator, motion: motion, now: clock.now)
          // Filed away — the checkbox plays the shared `.stamp` feel
          // (standardized across all checkable rows); this is its matched
          // haptic. Done is binary, so no intensity scaling.
          Haptics.play(CheckFeel.stamp.hapticSpec())
          // Filed the last one — the whole day's chores are clear; the canvas
          // earns a burst.
          if model.choresAllCleared {
            logCommit?.fire(.flourish(motion: .burst, accent: tint, intensity: 1))
          }
        }
      }
    )
    .contextMenu {
      if !isDone && deferLabel == nil {
        Button {
          model.completeChore(chore, mutator: checklistMutator, motion: motion, now: clock.now)
          Haptics.play(CheckFeel.stamp.hapticSpec())
          if model.choresAllCleared {
            logCommit?.fire(.flourish(motion: .burst, accent: tint, intensity: 1))
          }
        } label: {
          Label("Mark done", systemImage: "checkmark")
        }
        if chore.daysOverdue < 0 {
          Button {
            model.bringChoreToToday(chore, mutator: checklistMutator)
          } label: {
            Label("Bring to today", systemImage: "calendar.badge.exclamationmark")
          }
        }
        Button {
          model.deferChore(chore, mode: "day", label: "Tomorrow", mutator: checklistMutator)
        } label: {
          Label("Defer to tomorrow", systemImage: "calendar.badge.plus")
        }
        Button {
          model.deferChore(chore, mode: "weekend", label: "Weekend", mutator: checklistMutator)
        } label: {
          Label("Defer to weekend", systemImage: "calendar.badge.clock")
        }
      } else if isDone {
        Button {
          model.uncompleteChore(chore, mutator: checklistMutator)
        } label: {
          Label("Mark not done", systemImage: "arrow.uturn.left")
        }
      }
      if let onDelete {
        Divider()
        Button(role: .destructive) { onDelete() } label: {
          Label("Delete", systemImage: "trash")
        }
      }
    }
  }

  @ViewBuilder
  private func choreOverdueBadge(_ days: Int) -> some View {
    if days > 0 {
      Text("\(days)d over").font(.septenaMeta).foregroundStyle(Theme.overdueRed)
    } else if days == 0 {
      Text("today").font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
    } else {
      Text("\(-days)d").font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
    }
  }
}

// MARK: - Shared chrome

extension View {
  /// Cell treatment for a Next row. iOS: native `insetGrouped` cells supply the
  /// grouped pill; macOS: each row carries a slice of a Tasks-style grouped card
  /// via `taskCardChrome` (rounded corners, page gutter, hairline separators).
  func septenaNextRow(tag: String, isSelected: Bool,
                      index: Int = 0, count: Int = 1) -> some View {
    #if os(macOS)
    self
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .tag(tag)
      .septenaSuppressListCellSelection()
      .taskCardChrome(TaskCardPosition(index: index, count: count),
                      isSelected: isSelected)
    #else
    self
      .environment(\.rowHInset, Theme.Spacing.xl)
      .selectableListRow(tag: tag, isSelected: isSelected)
    #endif
  }
}

// Reused across HabitRow / SupplementRow / ChoreRow for "Done" / "Skipped"
// / defer-label pills. Pulled out of private scope so the chores mini-app
// can render its own status pills inline.
struct StatusBadge: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.septenaMeta)
      .foregroundStyle(Theme.inkSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .glassCapsule()
  }
}

/// Trailing consistency read for a habit/supplement checklist row — the 30-day
/// completion rate as a tiny progress ring, where the time-of-day otherwise
/// sits. Reuses `ProjectProgressIcon` (the tasks/projects ring) so the
/// "how full" language is shared, tuned smaller + thicker for a row's meta
/// slot. The exact percent lives one tap away in the detail's "last 30 days"
/// tile; here it's just a glance — and a VoiceOver label.
struct CompletionRateBadge: View {
  let percent: Int
  var tint: Color = Theme.inkSecondary
  var body: some View {
    ProjectProgressIcon(progress: Double(percent) / 100,
                        tint: tint,
                        diameter: 14,
                        lineWidth: 2.5)
      .accessibilityLabel("\(percent) percent done, last 30 days")
  }
}

// Section headers for the Next List. iOS: plain `Text` so the grouped `List`
// styles them with its default header treatment. macOS: Tasks-style group
// headers — semibold title parked over the card's checkbox column.
/// Foldable Next section header — title, live count, and a disclosure chevron.
/// Tapping anywhere toggles the section. Matches `DayBucketHeader`'s chevron
/// rotation (right when collapsed, down when expanded) and the Tasks tab's
/// `foldableSectionHeader` gesture.
@ViewBuilder
func nextFoldableSectionHeader(title: String, count: Int, isCollapsed: Bool,
                               onToggle: @escaping () -> Void) -> some View {
  Button(action: onToggle) {
    HStack(spacing: 8) {
      Text(title)
      if count > 0 {
        Text("\(count)")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
    }
    .contentShape(Rectangle())
  }
  .buttonStyle(.plain)
  #if os(macOS)
  .selectionDisabled()
  #endif
  .accessibilityHint(isCollapsed ? "Expand" : "Collapse")
}

@ViewBuilder
func nextSectionHeader<Content: View>(@ViewBuilder content: () -> Content) -> some View {
  #if os(macOS)
  content()
    .font(.system(size: Theme.groupHeaderFontSize, weight: .semibold))
    .foregroundStyle(Theme.inkPrimary)
    .textCase(nil)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, TaskCardMetrics.headerLeading)
    .padding(.trailing, TaskCardMetrics.margin)
    .padding(.top, 24)
    .padding(.bottom, 8)
  #else
  content()
  #endif
}

/// Next `Section` wrapper. macOS `List` pins `Section` headers while scrolling;
/// Tasks keeps headers in the scroll content (`SelectableScrollList`). On macOS
/// we render the header as the first row of each section so it scrolls away with
/// its card — the same rhythm as Tasks. iOS keeps native grouped section headers.
@ViewBuilder
func nextSection<Header: View, Content: View>(
  @ViewBuilder header: () -> Header,
  @ViewBuilder content: () -> Content
) -> some View {
  #if os(macOS)
  Section {
    nextSectionHeader(content: header)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .selectionDisabled()
    content()
  }
  #else
  Section {
    content()
  } header: {
    nextSectionHeader(content: header)
  }
  #endif
}

@ViewBuilder
private func sectionHeader(_ title: String) -> some View {
  Text(title)
}

// MARK: - Bucketed section header
//
// Shared by the time-of-day sections (habits + supplements) so both read the
// same: the current bucket's name prefixing the section noun ("Morning Habits"
// / "Morning Supplements"), labelled through the canonical `DayBucket.label`.
// `showsCountdown` adds a trailing "time left in this bucket" chip — shown only
// when the section is *strict* (not lingering), because a countdown to the
// window's close is meaningful only when the item actually drops off at the
// cutoff; a lingering section carries the item over, so no deadline to show.
@ViewBuilder
private func bucketSectionHeader(_ sectionTitle: String,
                                 showsCountdown: Bool) -> some View {
  let bucket = DayBucket.current.rawValue
  HStack(spacing: 8) {
    Text("\(DayBucket.label(forKey: bucket)) \(sectionTitle)")
    Spacer()
    if showsCountdown { BucketTimeLeft(bucket: bucket, font: .footnote.weight(.semibold)) }
  }
}
