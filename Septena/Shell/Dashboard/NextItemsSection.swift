import SwiftUI
import SwiftData
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
  @Environment(\.modelContext) private var modelContext
  /// Backing catalog for each row's project / area subtitle. Loaded once from
  /// the local mirror — areas / projects are small and effectively static.
  @State private var areas: [Area] = []
  @State private var projects: [Project] = []

  var body: some View {
    let tasks = model.openTasks
    if !tasks.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        sectionHeader("Tasks", tint: theme.color(for: "tasks"))
        VStack(spacing: 0) {
          ForEach(tasks) { task in
            TodayTaskRow(task: task, model: model, mutator: mutator,
                         tint: theme.color(for: "tasks"),
                         areas: areas, projects: projects)
              .transition(.opacity)
          }
        }
        .nextSectionCard()
      }
      .task {
        areas = LocalCache.areas(in: modelContext)
        projects = LocalCache.projects(in: modelContext)
      }
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
  @Environment(\.a11yMotion) private var motion

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
      onToggle: { model.toggle(task, mutator: mutator, motion: motion) },
      onTap: nil
    )
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
      actedHabits.contains(h.id) || (!h.done && !h.skipped)
    }
  }

  var doneHabits: [HabitDayItem] {
    habits.filter { h in
      !actedHabits.contains(h.id) && (h.done || h.skipped)
    }
  }

  var openSupplements: [SupplementDayItem] {
    supplements.filter { s in
      actedSupplements.contains(s.id) || !s.done
    }
  }

  var doneSupplements: [SupplementDayItem] {
    supplements.filter { s in
      !actedSupplements.contains(s.id) && s.done
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

/// UserDefaults keys + defaults for the per-section "carry over missed
/// items" toggle (a.k.a. linger): keep an item on the Next list after its
/// time-of-day bucket has passed, until it's done. Per-device by design —
/// it's a glance-filter preference, so it stays out of the CloudKit schema.
/// The toggle lives in each section's settings (`detailPaneContent`); these
/// keys are the shared contract between that toggle and the Next filters.
/// Defaults preserve shipped behavior: supplements linger, habits stay strict.
enum NextLinger {
  static let supplementsKey = "next.linger.supplements"
  static let supplementsDefault = true
  static let habitsKey = "next.linger.habits"
  static let habitsDefault = false
}

struct NextOpenSection: View {
  var model: NextItemsModel
  var tasksModel: TodayTasksModel
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(SectionTheme.self) private var theme
  // Per-section "carry over missed items" prefs (see `NextLinger`). Read here
  // and written by the section-settings toggles; @AppStorage keeps the Next
  // feed in sync the instant either is flipped.
  @AppStorage(NextLinger.supplementsKey) private var lingerSupplements = NextLinger.supplementsDefault
  @AppStorage(NextLinger.habitsKey) private var lingerHabits = NextLinger.habitsDefault

  /// Live width offered to the section stack, measured below. Drives the
  /// column count without leaning on `horizontalSizeClass`, so a resizable
  /// macOS window and an iPad split view both reflow from real pixels (same
  /// approach as the homepage timeline / Dense layout).
  @State private var availableWidth: CGFloat = 0

  /// Wide screens tile the section cards into balanced columns instead of
  /// one long scroll. Thresholds are tuned so iPhone (any orientation) and a
  /// narrow split view stay single-column, iPad portrait gets two, and iPad
  /// landscape / a roomy Mac window gets three. Widths are the *inset* page
  /// width (NextView already trims 20pt each side).
  private func columnCount(for width: CGFloat) -> Int {
    if width >= 1040 { return 3 }
    if width >= 680  { return 2 }
    return 1
  }

  /// The Next blocks in the user's saved section order, via the shared
  /// `NextFeed` ordering rule (the same one the watch snapshot uses) so the
  /// list never diverges from the watch. Reads the reactive `SettingsStore`
  /// so reordering in Settings updates the list live.
  private var orderedKeys: [String] {
    NextFeed.orderedSectionKeys(
      enabledKeys: settingsStore.sections.filter(\.isEnabled).map(\.key))
  }

  /// Habits are bucketed by time-of-day ("morning" / "afternoon" / "evening").
  /// By default the Next screen shows only the habits for *now* — earlier
  /// buckets don't linger as catch-up debt, later buckets don't surface
  /// early. With the section's "carry over missed habits" toggle on, an
  /// undone habit from an earlier bucket keeps showing until it's done.
  /// Bucket selection is shared with the watch via `DayBucket`.
  private var currentHabitBucket: String { DayBucket.current.rawValue }

  private var habitsNow: [HabitDayItem] {
    // Default (strict): exact current-bucket match — unchanged, and keeps
    // non-DayBucket buckets like "anytime" out of the now-strip as before.
    guard lingerHabits else {
      let bucket = currentHabitBucket
      return model.openHabits.filter { $0.bucket == bucket }
    }
    // Carry-over: show every undone habit whose bucket has opened. "anytime"
    // / non-DayBucket habits aren't part of the now-strip in either mode.
    let nowOrder = DayBucket.current.order
    return model.openHabits.filter { h in
      guard let b = DayBucket(rawValue: h.bucket) else { return false }
      return b.order <= nowOrder
    }
  }

  /// Supplements are *optionally* bucketed (unlike habits). An "anytime"
  /// supplement (nil bucket) shows all day. A bucketed one shows during its
  /// window; with "carry over missed doses" on (the default) it also lingers
  /// through later buckets until taken, so a missed dose doesn't vanish.
  private var supplementsNow: [SupplementDayItem] {
    let nowOrder = DayBucket.current.order
    return model.openSupplements.filter { supp in
      guard let raw = supp.bucket, let b = DayBucket(rawValue: raw) else { return true }
      return lingerSupplements ? (b.order <= nowOrder) : (b.order == nowOrder)
    }
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

  var body: some View {
    let visible = orderedKeys.filter { !isEmpty($0) }
    let columns = columnCount(for: availableWidth)
    // Each block is a tinted header above its own rounded "pill" card (see
    // `nextSectionCard`); the cards + the header's top inset separate the
    // sections, so there's no hairline between them anymore.
    VStack(spacing: 0) {
      // Zero-height width probe (same pattern as DenseHomepageView): a real
      // view gives the background GeometryReader a concrete frame to measure.
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: 0)
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: NextSectionWidthKey.self, value: geo.size.width)
          }
        )
        .onPreferenceChange(NextSectionWidthKey.self) { availableWidth = $0 }

      if columns > 1 {
        // Wide: pack the variable-height cards into balanced columns so a
        // short section (e.g. 2 supplements) doesn't leave a tall ragged
        // gap beside a long one.
        NextMasonry(keys: visible, columnCount: columns) { key in
          block(for: key)
        }
      } else {
        // Compact: the original single open list, untouched.
        VStack(alignment: .leading, spacing: 0) {
          ForEach(visible, id: \.self) { key in
            block(for: key)
          }
        }
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
          ForEach(supplementsNow) { supp in
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

// MARK: - Column tiling (wide screens)

/// Reports the section stack's offered width up to `NextOpenSection`, which
/// turns it into a column count.
private struct NextSectionWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Per-tile measured heights, keyed by section key, collected up the tree so
/// the masonry can pack each card into the currently-shortest column.
private struct NextTileHeightsKey: PreferenceKey {
  static let defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue()) { _, new in new }
  }
}

/// Masonry layout for the Next section cards. Greedily assigns each card (in
/// the user's saved section order) to the shortest column, so cards of wildly
/// different heights pack tightly instead of aligning to a grid row's tallest
/// cell. Columns are equal-width, so a card's height is independent of which
/// column it lands in — the greedy pass therefore converges in a single
/// reflow rather than oscillating.
///
/// Before the first height measurement lands every tile reports a nominal
/// height, so the opening frame round-robins by count instead of dumping every
/// card into column 0; the real heights then refine the balance.
private struct NextMasonry<Block: View>: View {
  let keys: [String]
  let columnCount: Int
  var columnSpacing: CGFloat = 16
  @ViewBuilder let block: (String) -> Block

  @State private var heights: [String: CGFloat] = [:]

  /// Nominal height for a not-yet-measured tile. Only used on the first
  /// frame; large enough that unknown tiles spread across columns by count.
  private static var estimatedHeight: CGFloat { 240 }

  private var columns: [[String]] {
    var cols = Array(repeating: [String](), count: columnCount)
    var colHeights = Array(repeating: CGFloat(0), count: columnCount)
    for key in keys {
      let h = heights[key] ?? Self.estimatedHeight
      let target = colHeights.enumerated().min { $0.element < $1.element }?.offset ?? 0
      cols[target].append(key)
      colHeights[target] += h
    }
    return cols
  }

  var body: some View {
    let cols = columns
    HStack(alignment: .top, spacing: columnSpacing) {
      ForEach(0..<columnCount, id: \.self) { col in
        VStack(alignment: .leading, spacing: 0) {
          ForEach(cols[col], id: \.self) { key in
            block(key)
              .background(
                GeometryReader { geo in
                  Color.clear.preference(key: NextTileHeightsKey.self,
                                         value: [key: geo.size.height])
                }
              )
          }
        }
        .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .onPreferenceChange(NextTileHeightsKey.self) { heights = $0 }
  }
}

// MARK: - Done Today timeline
//
// A single chronological log of everything finished today — not a second
// copy of the open list. Two sources merge into one time-sorted stream:
//   • the checklist trio (chores / habits / supplements) from `NextItemsModel`,
//     so an item the user just ticked off appears here the instant its settle
//     beat ends (live session state, no refetch);
//   • passive logs (caffeine, cannabis, gut, mood, meals, training, completed
//     tasks) from `NextDoneModel`, read off the local mirror.
// Newest at top, so the freshest completion lands right under the open list.

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

  func load() async {
    let date = SeptenaDate.today
    let mirror = await MirrorReader.shared.read { ctx in
      NextDoneModel.collect(ctx: ctx, date: date)
    }
    let tasks = await Self.collectTasks(date: date)
    events = (mirror + tasks).sorted { $0.hour > $1.hour }
    hasLoaded = true
  }

  @MainActor
  private static func collectTasks(date: String) async -> [DoneEvent] {
    let ctx = LocalStore.shared.container.mainContext
    let resp = await TaskReads.list(view: "logbook", days: 1, context: ctx)
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

    for e in ChecklistMirror.loadCaffeineDay(context: ctx, date: date).entries {
      out.append(.init(id: "caf-\(e.id)", hour: DoneEvent.hour(from: e.time) ?? -1,
                       time: e.time, label: caffeineLabel(e.method),
                       detail: e.grams.map { "\(Int($0))g" } ?? e.beans,
                       sectionKey: "caffeine", moodQuadrant: nil))
    }

    for e in ChecklistMirror.loadCannabisDay(context: ctx, date: date).entries {
      out.append(.init(id: "can-\(e.id)", hour: DoneEvent.hour(from: e.time) ?? -1,
                       time: e.time, label: cannabisLabel(e.method),
                       detail: e.strain, sectionKey: "cannabis", moodQuadrant: nil))
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

    for e in ChecklistMirror.loadNutritionToday(context: ctx) {
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

  private static func caffeineLabel(_ m: String) -> String {
    switch m {
    case "v60":    return "V60"
    case "matcha": return "Matcha"
    case "other":  return "Caffeine"
    default:       return m.capitalized
    }
  }

  private static func cannabisLabel(_ m: String) -> String {
    switch m {
    case "vape":   return "Vape"
    case "edible": return "Edible"
    default:       return m.capitalized
    }
  }
}

struct NextDoneSection: View {
  /// Live session state for the checklist trio (chores / habits / supplements).
  var model: NextItemsModel
  /// Today's passive logs (caffeine / cannabis / gut / mood / meals /
  /// training / completed tasks).
  var passive: [DoneEvent]
  @Environment(SectionTheme.self) private var theme

  /// Merge the trio's live done splits with the passive logs into one
  /// newest-first stream.
  private var events: [DoneEvent] {
    var out = passive
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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(events) { event in
        DoneEventRow(event: event)
      }
    }
    // Sit in the same rounded "pill" card the open Next blocks use so the
    // Done log reads as one quiet card rather than floating bare on the
    // grouped background.
    .nextSectionCard()
  }
}

/// One timeline row: time chip · section-color dot · label · trailing detail.
private struct DoneEventRow: View {
  let event: DoneEvent
  @Environment(SectionTheme.self) private var theme
  @Environment(\.rowHInset) private var rowHInset

  var body: some View {
    let color = event.moodQuadrant.flatMap { MoodQuadrant(rawValue: $0)?.color }
      ?? theme.color(for: event.sectionKey)
    HStack(spacing: 10) {
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

  var body: some View {
    let inactive = habit.done || habit.skipped
    CheckableRow(
      tint: habit.skipped && !habit.done ? Theme.inkSecondary : tint,
      isDone: inactive,
      isInactive: inactive,
      leadingEmoji: habit.emoji ?? "•",
      title: habit.name,
      trailing: {
        if habit.skipped {
          StatusBadge(text: "Skipped")
        } else if let rate = completionRate {
          CompletionRateBadge(percent: rate)
        } else if let t = habit.time {
          Text(t).font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
        }
      },
      onToggle: {
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
            // Everyday completion — quantity-aware continuity: the tally row
            // grows as you get further through *this bucket* of the day. Count
            // includes the just-completed habit (model flipped it above), so
            // each tick within a bucket adds a mark; a new bucket starts fresh.
            let doneInBucket = model.habits.filter { $0.bucket == habit.bucket && $0.done }.count
            let intensity = min(2.0, Double(doneInBucket) / 4.0)
            Haptics.play(CommitMotion.tally.hapticSpec(intensity: intensity))
            logCommit?.fire(.flourish(motion: .tally, accent: accent, intensity: intensity))
          }
        } else {
          HabitMilestoneStore.reconcile(habit.id, currentStreak: streak)
        }
      }
    )
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
  /// 30-day completion rate shown in the trailing slot (instead of the
  /// time-of-day) when the Supplements checklist passes it. nil in the Next
  /// feed, where the time stays.
  var completionRate: Int? = nil
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
    CheckableRow(
      tint: tint,
      isDone: supplement.done,
      isInactive: supplement.done,
      leadingEmoji: supplement.emoji ?? "•",
      title: supplement.name,
      trailing: {
        if let rate = completionRate {
          CompletionRateBadge(percent: rate)
        } else if let t = supplement.time {
          Text(t).font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
        }
      },
      onToggle: { commitToggle() }
    )
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

    CheckableRow(
      tint: deferLabel != nil ? Theme.inkSecondary : tint,
      isDone: inactive,
      isInactive: inactive,
      leadingEmoji: chore.emoji ?? "•",
      title: chore.name,
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
          model.completeChore(chore, mutator: checklistMutator, motion: motion)
          // Filed onto the done pile. Settle ignores intensity (done is binary).
          Haptics.play(CommitMotion.settle.hapticSpec(intensity: 1))
          logCommit?.fire(.flourish(motion: .settle,
                                    accent: theme.color(for: "chores"),
                                    intensity: 1))
        }
      }
    )
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
      // Same de-stacking as DrawerSection: the card already sits 20pt off the
      // screen edge, so rows inside it read this tighter inset (aligned with the
      // section header above) instead of stacking a second 20pt margin.
      .environment(\.rowHInset, Theme.Spacing.xl)
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

/// Trailing "NN%" consistency read for a habit/supplement checklist row —
/// the 30-day completion rate, shown where the time-of-day otherwise sits.
/// Sits quietly in the row's meta slot; uses a monospaced-digit figure so the
/// percentages line up down the list.
struct CompletionRateBadge: View {
  let percent: Int
  var body: some View {
    Text("\(percent)%")
      .font(.septenaMeta.monospacedDigit())
      .foregroundStyle(Theme.inkSecondary)
  }
}

@ViewBuilder
private func sectionHeader(_ title: String, tint: Color) -> some View {
  // Title-only — no leading SF Symbol. The section accent already lives on
  // each row's checkbox, so an extra glyph in the header was redundant.
  Text(title)
    .font(.septenaSectionTitle)
    .foregroundStyle(tint)
    // Aligns with the row content inside the card below (which reads
    // `rowHInset` = Spacing.xl), not the wider Theme.hPadding.
    .padding(.horizontal, Theme.Spacing.xl)
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
  // Aligns with the row content inside the card below (rowHInset = Spacing.xl).
  .padding(.horizontal, Theme.Spacing.xl)
  .padding(.top, Theme.sectionSpacing)
  .padding(.bottom, 6)
}
