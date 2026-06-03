import SwiftUI
import EventKit

// Today-screen "everything else" rendering: chores, habits, supplements.
// One open list — a completed item lingers struck through for the settle
// beat, then fades out in place (there's no "done" strip to slide into).
// Shared state lives in NextItemsModel.

// MARK: - Today tasks (inline on Next)
//
// Mirrors NextItemsModel for the Tasks slice — Next renders today's open
// tasks as the first list above chores / habits / supplements. Full task
// editing still lives in the Tasks tab; this surface is a read-through
// checklist (tap to complete, tap again to uncomplete).

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
    let fresh = LocalCache.tasks(in: LocalStore.shared.container.mainContext,
                                 filter: .today)
    // The `.today` query excludes done tasks, so a plain re-read would yank a
    // just-completed row out from under the settle beat — and this runs on
    // every `.septenaTasksChanged` (see NextView), which a completion posts.
    // Preserve session-acted rows the query now hides, in their current
    // position, so they linger struck through then fade rather than hop/vanish.
    let freshByID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var merged = tasks.compactMap { old -> SeptenaTask? in
      if let f = freshByID[old.id] { return f }        // still open → refreshed copy
      if actedTasks.contains(old.id) { return old }    // lingering → keep in place
      return nil                                       // gone
    }
    let kept = Set(merged.map(\.id))
    merged.append(contentsOf: fresh.filter { !kept.contains($0.id) })  // newly arrived
    tasks = merged
  }

  func load() async {
    let context = LocalStore.shared.container.mainContext
    // CloudKit-mode read: TaskReads.list returns LocalCache directly,
    // so we just need to ensure the mirror is fresh, then repaint.
    _ = await TaskReads.list(view: "today", context: context)
    // Clear session state BEFORE repainting so the merge in refreshFromCache
    // doesn't preserve now-stale lingering rows — load() is authoritative.
    actedTasks = []
    settle.cancelAll()
    refreshFromCache()
    hasLoaded = true
  }

  /// Open today tasks, plus any toggled this session (so a just-completed
  /// row lingers struck through instead of vanishing under the finger).
  var openTasks: [SeptenaTask] {
    tasks.filter { actedTasks.contains($0.id) || $0.status == .open }
  }

  func toggle(_ task: SeptenaTask, mutator: TaskMutator, motion: A11yMotion) {
    // Flip status IN PLACE rather than re-reading from the cache: the Today
    // cache query excludes done tasks (Persistence `LocalCache.tasks(.today)`),
    // so a `refreshFromCache()` here would drop the just-completed row before
    // it could linger. Keeping it in `tasks` (struck through, held visible by
    // `actedTasks`) is what lets it settle then fade.
    guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
    if task.status == .done {
      Haptics.tap()
      mutator.uncomplete(id: task.id)
      settle.cancel(task.id)
      tasks[i].status = .open
      actedTasks.insert(task.id)
    } else {
      Haptics.success()
      mutator.complete(id: task.id)
      tasks[i].status = .done
      actedTasks.insert(task.id)
      // Linger struck through, then fade out of the open list. Next has no
      // tasks-done section, so a settled task simply drifts away.
      settle.schedule(task.id) { [weak self] in
        motion.run(Theme.Motion.settle) { _ = self?.actedTasks.remove(task.id) }
      }
    }
  }
}

struct TodayTasksSection: View {
  var model: TodayTasksModel
  @Environment(TaskMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme

  var body: some View {
    let tasks = model.openTasks
    if !tasks.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        sectionHeader("Tasks", tint: theme.color(for: "tasks"))
        VStack(spacing: 0) {
          ForEach(tasks) { task in
            TodayTaskRow(task: task, model: model, mutator: mutator,
                         tint: theme.color(for: "tasks"))
              .transition(.opacity)
          }
        }
        .nextSectionCard()
      }
    }
  }
}

struct TodayTaskRow: View {
  let task: SeptenaTask
  var model: TodayTasksModel
  let mutator: TaskMutator
  let tint: Color
  @Environment(\.a11yMotion) private var motion

  var body: some View {
    let isDone = task.status == .done
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(tint: tint, isDone: isDone) {
        model.toggle(task, mutator: mutator, motion: motion)
      }
      .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
      Text(task.title)
        .font(.septenaTaskTitle)
        .foregroundStyle(isDone ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(isDone)
        .opacity(isDone ? 0.5 : 1)
      Spacer()
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding)
    // Same app-wide pattern as the other rows: long-press → menu. The
    // richer task menu (When… / Move… / Repeat… / Suggested) lives in
    // TaskListView because those actions need sheet state that doesn't
    // exist on the Next surface; here we surface the subset that works
    // standalone (Today toggle, Cancel, Delete).
    .contextMenu {
      if task.isOnToday {
        Button {
          Haptics.tick()
          mutator.removeFromToday(id: task.id)
        } label: {
          Label("Remove from Today", systemImage: "sun.min")
        }
      } else {
        Button {
          Haptics.tick()
          mutator.moveToToday(id: task.id, today: true)
        } label: {
          Label("Move to Today", systemImage: "sun.max.fill")
        }
      }
      Button {
        Haptics.tick()
        mutator.cancel(id: task.id)
      } label: {
        Label("Cancel Task", systemImage: "xmark.circle")
      }
      Divider()
      Button(role: .destructive) {
        Haptics.warning()
        mutator.delete(id: task.id)
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
  }
}

// MARK: - Shared model

@MainActor
@Observable
final class NextItemsModel {
  var habits: [HabitDayItem] = []
  var habitBuckets: [String] = []
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

  // Computed (not captured at init) so mutation bodies always tag the
  // current day. The owning view also calls `load()` from
  // `.onChange(of: clock.today)` to refetch day-scoped data on rollover.
  private var today: String { SeptenaDate.today }

  // MARK: - Open split (the source of truth for the open list)
  //
  // No "done" split: a completed/skipped item lingers in the open list
  // (struck through) for the settle beat, then fades out in place and is
  // gone — it never collects in a Done section. `completedChores` etc. still
  // track session state so the row reads as done while it lingers.

  /// Show an item in the open list if it's still pending OR if the user
  /// just acted on it this session (keeps it from jumping out from under
  /// the finger before it fades).
  var openHabits: [HabitDayItem] {
    habits.filter { h in
      actedHabits.contains(h.id) || (!h.done && !h.skipped)
    }
  }

  var openSupplements: [SupplementDayItem] {
    supplements.filter { s in
      actedSupplements.contains(s.id) || !s.done
    }
  }

  /// Chores due today or overdue. A just-acted chore lingers in the open list
  /// (struck through) for the settle beat so it doesn't vanish under the
  /// finger; once the beat clears `actedChores` it fades out in place.
  var openChores: [ChoreItem] {
    chores
      .filter { $0.daysOverdue >= 0 }
      .filter { c in
        actedChores.contains(c.id)
          || (!completedChores.contains(c.id) && deferredChores[c.id] == nil)
      }
      .sorted { ($0.daysOverdue, $0.name) > ($1.daysOverdue, $1.name) }
  }

  var hasAnyOpen: Bool {
    !openHabits.isEmpty || !openSupplements.isEmpty || !openChores.isEmpty
  }

  // MARK: - Loading

  private enum CacheKey {
    static let habits        = "next.habits"
    static let habitBuckets  = "next.habitBuckets"
    static let supplements   = "next.supplements"
    static let chores        = "next.chores"
  }

  /// Synchronous cache prime — paints the last-known habits / supplements
  /// / chores snapshot on view appear, so screens that consume this model
  /// (Habits / Supplements / Chores destinations + Next) render real data
  /// on the first frame instead of empty sections while the network
  /// catches up.
  func paintFromCache() {
    let context = LocalStore.shared.container.mainContext
    if let day = ChecklistMirror.loadHabitsDay(context: context, date: today) {
      habits = day.buckets.flatMap { day.grouped[$0] ?? [] }
      habitBuckets = day.buckets
      ResponseCache.save(habits, forKey: CacheKey.habits)
      ResponseCache.save(habitBuckets, forKey: CacheKey.habitBuckets)
    } else {
      if let v = ResponseCache.load([HabitDayItem].self, forKey: CacheKey.habits) { habits = v }
      if let v = ResponseCache.load([String].self, forKey: CacheKey.habitBuckets) { habitBuckets = v }
    }
    if let day = ChecklistMirror.loadSupplementsDay(context: context, date: today) {
      supplements = day.items
      ResponseCache.save(supplements, forKey: CacheKey.supplements)
    } else if let v = ResponseCache.load([SupplementDayItem].self, forKey: CacheKey.supplements) {
      supplements = v
    }
    let mirroredChores = ChecklistMirror.loadChores(context: context)
    if !mirroredChores.isEmpty {
      chores = mirroredChores
      ResponseCache.save(mirroredChores, forKey: CacheKey.chores)
    } else if let v = ResponseCache.load([ChoreItem].self, forKey: CacheKey.chores) {
      chores = v
    }
    calendarEvents = CalendarBridge.shared.todayEvents()
    hasLoaded = true
  }

  func load() async {
    let context = LocalStore.shared.container.mainContext

    // Habits / Supplements / Chores are CloudKit-authoritative — read
    // directly from the local SwiftData mirror. CKEngine keeps it fresh
    // via fetchChanges() + silent pushes; no FastAPI fallback needed.
    if let hRes = ChecklistMirror.loadHabitsDay(context: context, date: today) {
      habits = hRes.buckets.flatMap { hRes.grouped[$0] ?? [] }
      habitBuckets = hRes.buckets
      ResponseCache.save(habits, forKey: CacheKey.habits)
      ResponseCache.save(habitBuckets, forKey: CacheKey.habitBuckets)
    }

    if let sRes = ChecklistMirror.loadSupplementsDay(context: context, date: today) {
      supplements = sRes.items
      ResponseCache.save(supplements, forKey: CacheKey.supplements)
    }

    let mirroredChores = ChecklistMirror.loadChores(context: context)
    chores = mirroredChores
    if !mirroredChores.isEmpty {
      ResponseCache.save(mirroredChores, forKey: CacheKey.chores)
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

  func toggleHabit(_ habit: HabitDayItem, mutator: ChecklistMutator, motion: A11yMotion) {
    let next = !habit.done
    // Done-side haptic + flourish is owned by the caller (HabitRow), which
    // can reach the environment and branch milestone (.ignition) vs everyday
    // (.tally). Undo stays a light tap here so every host feels the un-check.
    if !next { Haptics.tap() }
    if let i = habits.firstIndex(where: { $0.id == habit.id }) {
      habits[i].done = next
      if next { habits[i].skipped = false }
      habits[i].time = next ? SeptenaDate.nowHHMM : nil
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

  func toggleSupplement(_ supp: SupplementDayItem, mutator: ChecklistMutator, motion: A11yMotion) {
    let next = !supp.done
    // Taken-side haptic + flourish is owned by the caller (SupplementRow);
    // undo stays a light tap here.
    if !next { Haptics.tap() }
    if let i = supplements.firstIndex(where: { $0.id == supp.id }) {
      supplements[i].done = next
      supplements[i].time = next ? SeptenaDate.nowHHMM : nil
    }
    actedSupplements.insert(supp.id)
    mutator.toggleSupplement(id: supp.id, date: today, done: next)
    settleActed(supp.id, in: \.actedSupplements, done: next, motion: motion)
  }

  func completeChore(_ chore: ChoreItem, mutator: ChecklistMutator, motion: A11yMotion) {
    // Completion haptic + flourish (.settle) is owned by the caller (ChoreRow).
    completedChores.insert(chore.id)
    actedChores.insert(chore.id)
    deferredChores.removeValue(forKey: chore.id)
    if let i = chores.firstIndex(where: { $0.id == chore.id }) {
      chores[i].lastCompleted = today
      chores[i].lastCompletedTime = SeptenaDate.nowHHMM
    }
    mutator.completeChore(id: chore.id, date: today)
    // Linger struck through, then fade into Done. We clear `actedChores` (the
    // linger set) — NOT `completedChores` — so the chore stays *completed* as
    // it moves from the open list to the Done strip.
    settle.schedule(chore.id) { [weak self] in
      motion.run(Theme.Motion.settle) { _ = self?.actedChores.remove(chore.id) }
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
      motion.run(Theme.Motion.settle) { _ = self[keyPath: keyPath].remove(id) }
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
}

// MARK: - Open subview (rendered above tasks-done)

struct NextOpenSection: View {
  var model: NextItemsModel
  var tasksModel: TodayTasksModel
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(SectionTheme.self) private var theme

  /// The Next blocks in the user's saved section order, via the shared
  /// `NextFeed` ordering rule (the same one the watch snapshot uses) so the
  /// list never diverges from the watch. Reads the reactive `SettingsStore`
  /// so reordering in Settings updates the list live.
  private var orderedKeys: [String] {
    NextFeed.orderedSectionKeys(
      enabledKeys: settingsStore.sections.filter(\.isEnabled).map(\.key))
  }

  /// Habits are bucketed by time-of-day on the server ("morning" / "afternoon"
  /// / "evening"). The Next screen only shows the habits for *now* — earlier
  /// buckets shouldn't linger as catch-up debt, and later buckets shouldn't
  /// surface ahead of time. One-bucket-at-a-time keeps the screen focused.
  /// Bucket selection is shared with the watch via `DayBucket` so they
  /// never disagree about which habits are due now.
  private var currentHabitBucket: String { DayBucket.current.rawValue }

  private var habitsNow: [HabitDayItem] {
    let bucket = currentHabitBucket
    return model.openHabits.filter { $0.bucket == bucket }
  }

  private func isEmpty(_ key: String) -> Bool {
    switch key {
    case "tasks":       return tasksModel.openTasks.isEmpty
    case "chores":      return model.openChores.isEmpty
    case "habits":      return habitsNow.isEmpty
    case "supplements": return model.openSupplements.isEmpty
    default:
      // `orderedKeys` only ever yields `NextBlocks` members, so a key with
      // no case here means a row was added to the table without a render
      // case. Fail loudly in debug; hide it in release rather than crash.
      assertionFailure("NextOpenSection has no case for Next block '\(key)'")
      return true
    }
  }

  var body: some View {
    let visible = orderedKeys.filter { !isEmpty($0) }
    // Each block is a tinted header above its own rounded "pill" card (see
    // `nextSectionCard`); the cards + the header's top inset separate the
    // sections, so there's no hairline between them anymore.
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(visible.enumerated()), id: \.element) { _, key in
        block(for: key)
      }
    }
  }

  @ViewBuilder
  private func block(for key: String) -> some View {
    switch key {
    case "tasks":
      // TodayTasksSection renders its own "Tasks" header + pill card.
      TodayTasksSection(model: tasksModel)

    case "chores":
      VStack(alignment: .leading, spacing: 0) {
        sectionHeader("Chores", tint: theme.color(for: "chores"))
        VStack(spacing: 0) {
          ForEach(model.openChores) { chore in
            ChoreRow(chore: chore, model: model, checklistMutator: checklistMutator,
                     tint: theme.color(for: "chores"))
              .transition(.opacity)
          }
        }
        .nextSectionCard()
      }

    case "habits":
      VStack(alignment: .leading, spacing: 0) {
        habitBucketHeader(bucket: currentHabitBucket,
                          tint: theme.color(for: "habits"))
        VStack(spacing: 0) {
          ForEach(habitsNow) { habit in
            HabitRow(habit: habit, model: model, checklistMutator: checklistMutator,
                     tint: theme.color(for: "habits"))
              .transition(.opacity)
          }
        }
        .nextSectionCard()
      }

    case "supplements":
      VStack(alignment: .leading, spacing: 0) {
        sectionHeader("Supplements", tint: theme.color(for: "supplements"))
        VStack(spacing: 0) {
          ForEach(model.openSupplements) { supp in
            SupplementRow(supplement: supp, model: model, checklistMutator: checklistMutator,
                          tint: theme.color(for: "supplements"))
              .transition(.opacity)
          }
        }
        .nextSectionCard()
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
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(\.a11yMotion) private var motion
  // Optional — HabitRow renders in multiple hosts (Next tab, Habits sheet);
  // not all inherit the root env. nil → celebration no-ops, toggle still runs.
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  var body: some View {
    let inactive = habit.done || habit.skipped
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(
        tint: habit.skipped && !habit.done ? Theme.inkSecondary : tint,
        isDone: inactive
      ) {
        // The optimistic flip + write lives on NextItemsModel; layer the
        // streak celebration on top here (the View can reach the environment;
        // the model can't). `done` is the value being written.
        let done = !habit.done
        model.toggleHabit(habit, mutator: checklistMutator, motion: motion)
        let streak = ChecklistMirror.habitStreak(context: modelContext, habitId: habit.id, asOf: SeptenaDate.today)
        let accent = theme.color(for: "habits")
        if done {
          if let m = StreakMilestones.reached(streak), HabitMilestoneStore.lastCelebrated(habit.id) < m {
            // Milestone — the loud version: rings + streak number.
            HabitMilestoneStore.setCelebrated(habit.id, m)
            Haptics.success()
            logCommit?.fire(.ignition(accent: accent, streak: streak))
            A11y.announce("\(streak) day streak!")
          } else {
            // Everyday completion — continuity, not celebration: a mark joins
            // the row. Longer streaks show a fuller row (more priors).
            let intensity = min(2.0, max(0.6, Double(streak) / 5.0))
            Haptics.play(CommitMotion.tally.hapticSpec(intensity: intensity))
            logCommit?.fire(.flourish(motion: .tally, accent: accent, intensity: intensity))
          }
        } else {
          HabitMilestoneStore.reconcile(habit.id, currentStreak: streak)
        }
      }
      .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      Text(habit.emoji ?? "•").font(.body)
      Text(habit.name)
        .font(.septenaTaskTitle)
        .foregroundStyle(inactive ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(inactive)
        .opacity(inactive ? 0.5 : 1)
      Spacer()
      if habit.skipped {
        StatusBadge(text: "Skipped")
      } else if let t = habit.time {
        Text(t).font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding)
    .contextMenu {
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
  @Environment(\.a11yMotion) private var motion
  @Environment(SectionTheme.self) private var theme
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  /// Toggle + (on taken) the `.cascade` celebration: marks dropping in
  /// sequence, scaled by how many supplements are now taken today. Undo's
  /// light tap is handled inside the model.
  private func commitToggle() {
    let taken = !supplement.done
    model.toggleSupplement(supplement, mutator: checklistMutator, motion: motion)
    guard taken else { return }
    let count = model.supplements.filter { $0.done }.count
    let intensity = min(1.5, max(0.7, Double(count) / 4.0))
    Haptics.play(CommitMotion.cascade.hapticSpec(intensity: intensity))
    logCommit?.fire(.flourish(motion: .cascade,
                              accent: theme.color(for: "supplements"),
                              intensity: intensity))
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(tint: tint, isDone: supplement.done) {
        commitToggle()
      }
      .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
      Text(supplement.emoji ?? "•").font(.body)
      Text(supplement.name)
        .font(.septenaTaskTitle)
        .foregroundStyle(supplement.done ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(supplement.done)
        .opacity(supplement.done ? 0.5 : 1)
      Spacer()
      if let t = supplement.time {
        Text(t).font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding)
    // Consistent with the other Next rows: long-press always offers a menu.
    // Mark taken/not-taken mirrors the checkbox for discoverability; Delete
    // shows only where a host owns the record (the Supplements mini-app).
    .contextMenu {
      Button {
        commitToggle()
      } label: {
        Label(supplement.done ? "Mark not taken" : "Mark taken",
              systemImage: supplement.done ? "arrow.uturn.left" : "checkmark")
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
  @Environment(\.a11yMotion) private var motion
  @Environment(SectionTheme.self) private var theme
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  var body: some View {
    let isDone = model.completedChores.contains(chore.id)
    let deferLabel = model.deferredChores[chore.id]
    let inactive = isDone || deferLabel != nil

    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(
        tint: deferLabel != nil ? Theme.inkSecondary : tint,
        isDone: inactive
      ) {
        if isDone {
          model.uncompleteChore(chore, mutator: checklistMutator)
        } else {
          model.completeChore(chore, mutator: checklistMutator, motion: motion)
          // Filed onto the done pile. Settle ignores intensity (done is binary).
          Haptics.play(CommitMotion.settle.hapticSpec(intensity: 1))
          logCommit?.fire(.flourish(motion: .settle,
                                    accent: theme.color(for: "chores"),
                                    intensity: 1))
        }
      }
      .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
      Text(chore.emoji ?? "•").font(.body)
      Text(chore.name)
        .font(.septenaTaskTitle)
        .foregroundStyle(inactive ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(inactive)
        .opacity(inactive ? 0.5 : 1)
      Spacer()
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
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding)
    .contextMenu {
      if !isDone && deferLabel == nil {
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
  /// Wraps a stack of Next rows in the same rounded "pill" card that the
  /// Tasks / Goals drawers use (`DrawerSection`): a secondary-grouped fill
  /// with 22pt continuous corners. Lets the Next screen read as grouped
  /// cards on the light page background instead of a full-bleed list, so it
  /// matches Week / Tasks / Goals. The section's tinted header sits *above*
  /// this card (not inside), mirroring the drawer convention.
  func nextSectionCard() -> some View {
    self
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
          .fill(Theme.secondaryGroupedBackground)
      )
      .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
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
      .background(Theme.mutedSurface, in: Capsule())
  }
}

@ViewBuilder
private func sectionHeader(_ title: String, tint: Color) -> some View {
  // Title-only — no leading SF Symbol. The section accent already lives on
  // each row's checkbox, so an extra glyph in the header was redundant.
  Text(title)
    .font(.septenaSectionTitle)
    .foregroundStyle(tint)
    .padding(.horizontal, Theme.hPadding)
    .padding(.top, Theme.sectionSpacing)
    .padding(.bottom, 6)
}

// MARK: - Habit bucket header
//
// Same chrome as `sectionHeader`, plus a trailing "time left in this bucket"
// chip that rounds coarsely when there's plenty of slack and tightens up
// (minutes, then warm color, then red) as the cutoff approaches.

@ViewBuilder
private func habitBucketHeader(bucket: String, tint: Color) -> some View {
  HStack(spacing: 8) {
    Text("\(bucket.capitalized) Habits")
      .font(.septenaSectionTitle).foregroundStyle(tint)
    Spacer()
    BucketTimeLeft(bucket: bucket)
  }
  .padding(.horizontal, Theme.hPadding)
  .padding(.top, Theme.sectionSpacing)
  .padding(.bottom, 6)
}

/// Tiny "Xh / Xm left" chip that ticks once a minute. Same font as the
/// section title so it sits in the row's metrics; only the color changes
/// (secondary → orange → red) as we approach the bucket cutoff.
private struct BucketTimeLeft: View {
  let bucket: String

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { ctx in
      let parts = formatted(remaining: cutoff().timeIntervalSince(ctx.date))
      Text(parts.text)
        .font(.septenaSectionTitle)
        .foregroundStyle(parts.color)
        .monospacedDigit()
    }
  }

  /// End of the current habit window. Bucket boundaries mirror
  /// `NextOpenSection.currentHabitBucket`: noon, 5pm, midnight.
  private func cutoff() -> Date {
    let cal = Calendar.current
    let now = Date()
    // Window boundary comes from DayBucket so it can't drift from the
    // morning/afternoon/evening cutoffs the rest of the app uses.
    let hour = (DayBucket(rawValue: bucket) ?? .evening).endHour
    if hour >= 24 {
      return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
    }
    return cal.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
  }

  private func formatted(remaining seconds: TimeInterval) -> (text: String, color: Color) {
    let s = max(0, Int(seconds))
    let totalMin = s / 60
    let h = totalMin / 60
    let m = totalMin % 60

    let text: String
    if totalMin >= 120 {
      // Plenty of runway — coarse hours only.
      text = "\(h)h"
    } else if totalMin >= 60 {
      // Last hour-and-a-bit — show "1h 25m", rounded to 5m.
      let rounded = (m / 5) * 5
      text = rounded == 0 ? "\(h)h" : "\(h)h \(rounded)m"
    } else {
      // Under an hour — minutes, exact (this is the "more detail" zone).
      text = "\(totalMin)m"
    }

    let color: Color
    if totalMin < 15      { color = Theme.overdueRed }
    else if totalMin < 60 { color = .orange }
    else                  { color = Theme.inkSecondary }

    return (text, color)
  }
}
