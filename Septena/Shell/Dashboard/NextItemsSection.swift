import SwiftUI
import EventKit

// Today-screen "everything else" rendering: chores, habits, supplements.
// Split into two views (open / done) so the parent can place all open items
// above tasks-done. Shared state lives in NextItemsModel.

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

  func paintFromCache() {
    refreshFromCache()
    hasLoaded = true
  }

  func refreshFromCache() {
    tasks = LocalCache.tasks(in: LocalStore.shared.container.mainContext,
                             filter: .today)
  }

  func load(client: SeptenaClient) async {
    let context = LocalStore.shared.container.mainContext
    // CloudKit-mode read: TaskReads.list returns LocalCache directly,
    // so we just need to ensure the mirror is fresh, then repaint.
    _ = await TaskReads.list(view: "today", context: context)
    refreshFromCache()
    actedTasks = []
    hasLoaded = true
  }

  /// Open today tasks, plus any toggled this session (so a just-completed
  /// row lingers struck through instead of vanishing under the finger).
  var openTasks: [SeptenaTask] {
    tasks.filter { actedTasks.contains($0.id) || $0.status == .open }
  }

  func toggle(_ task: SeptenaTask, mutator: TaskMutator) {
    if task.status == .done {
      Haptics.tap()
      mutator.uncomplete(id: task.id)
    } else {
      Haptics.success()
      mutator.complete(id: task.id)
    }
    actedTasks.insert(task.id)
    refreshFromCache()
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
        ForEach(tasks) { task in
          TodayTaskRow(task: task, model: model, mutator: mutator,
                       tint: theme.color(for: "tasks"))
        }
      }
    }
  }
}

struct TodayTaskRow: View {
  let task: SeptenaTask
  var model: TodayTasksModel
  let mutator: TaskMutator
  let tint: Color

  var body: some View {
    let isDone = task.status == .done
    HStack(spacing: 12) {
      TaskCheckbox(tint: tint, isDone: isDone) {
        model.toggle(task, mutator: mutator)
      }
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
      if task.today {
        Button {
          Haptics.tick()
          mutator.moveToToday(id: task.id, today: false)
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
  /// Chores marked done this session — same treatment.
  var completedChores: Set<String> = []
  /// Habits the user toggled/skipped this session. Keeps them rendered in
  /// the open list (struck through) so the row doesn't hop to the bottom
  /// the moment you check it.
  var actedHabits: Set<String> = []
  /// Same idea for supplements.
  var actedSupplements: Set<String> = []
  /// Today's calendar events — surfaced inline in Next instead of as a
  /// separate dashboard tile (matches the webapp's `/api/calendar/day`
  /// integration into the Next list).
  var calendarEvents: [EKEvent] = []

  /// Flips true after the first network response (success or failure) so the
  /// empty state never flashes during the initial load.
  var hasLoaded: Bool = false

  // Computed (not captured at init) so mutation bodies always tag the
  // current day. The owning view also calls `load()` from
  // `.onChange(of: clock.today)` to refetch day-scoped data on rollover.
  private var today: String { SeptenaDate.today }

  // MARK: - Open / Done splits (the source of truth for both subviews)

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

  /// Chores due today or overdue. Linger in the open list after completion
  /// (struck through) so the row doesn't vanish under the user's finger —
  /// same treatment as habits/supplements. Deferred chores hide because
  /// "defer" rescheduled them to a future day.
  var openChores: [ChoreItem] {
    chores
      .filter { $0.daysOverdue >= 0 }
      .filter { c in
        completedChores.contains(c.id) || deferredChores[c.id] == nil
      }
      .sorted { ($0.daysOverdue, $0.name) > ($1.daysOverdue, $1.name) }
  }

  /// Deferred-this-session chores only. Completed chores stay in the open
  /// list (lingering) to match the habit / supplement pattern.
  var doneChores: [ChoreItem] {
    chores.filter { !completedChores.contains($0.id) && deferredChores[$0.id] != nil }
  }

  /// Calendar events still ahead today (or currently happening). Past
  /// events drop into `doneCalendarEvents`.
  var openCalendarEvents: [EKEvent] {
    calendarEvents.filter { $0.endDate > Date() }
  }

  var doneCalendarEvents: [EKEvent] {
    calendarEvents.filter { $0.endDate <= Date() }
  }

  var hasAnyOpen: Bool {
    !openHabits.isEmpty || !openSupplements.isEmpty || !openChores.isEmpty
      || !openCalendarEvents.isEmpty
  }

  var hasAnyDone: Bool {
    !doneHabits.isEmpty || !doneSupplements.isEmpty || !doneChores.isEmpty
      || !doneCalendarEvents.isEmpty
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

  func load(client: SeptenaClient) async {
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

    // Local EventKit fetch — no network. Returns [] when access isn't
    // granted yet; the user grants in Calendar destination view / Settings.
    calendarEvents = CalendarBridge.shared.todayEvents()
    // Reload clears the per-session "kept visible" buckets — server is now
    // the source of truth.
    deferredChores = [:]
    completedChores = []
    actedHabits = []
    actedSupplements = []
    hasLoaded = true
  }

  // MARK: - Mutations (optimistic local flips, server-side write)

  func toggleHabit(_ habit: HabitDayItem, mutator: ChecklistMutator) {
    let next = !habit.done
    if next { Haptics.success() } else { Haptics.tap() }
    if let i = habits.firstIndex(where: { $0.id == habit.id }) {
      habits[i].done = next
      if next { habits[i].skipped = false }
      habits[i].time = next ? currentTimeString() : nil
    }
    actedHabits.insert(habit.id)
    mutator.toggleHabit(id: habit.id, date: today, done: next)
  }

  func skipHabit(_ habit: HabitDayItem, skipped: Bool, mutator: ChecklistMutator) {
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
  }

  func toggleSupplement(_ supp: SupplementDayItem, mutator: ChecklistMutator) {
    let next = !supp.done
    if next { Haptics.success() } else { Haptics.tap() }
    if let i = supplements.firstIndex(where: { $0.id == supp.id }) {
      supplements[i].done = next
      supplements[i].time = next ? currentTimeString() : nil
    }
    actedSupplements.insert(supp.id)
    mutator.toggleSupplement(id: supp.id, date: today, done: next)
  }

  func completeChore(_ chore: ChoreItem, mutator: ChecklistMutator) {
    Haptics.success()
    completedChores.insert(chore.id)
    deferredChores.removeValue(forKey: chore.id)
    if let i = chores.firstIndex(where: { $0.id == chore.id }) {
      chores[i].lastCompleted = today
      chores[i].lastCompletedTime = currentTimeString()
    }
    mutator.completeChore(id: chore.id, date: today)
  }

  func deferChore(_ chore: ChoreItem, mode: String, label: String, mutator: ChecklistMutator) {
    Haptics.tick()
    deferredChores[chore.id] = label
    completedChores.remove(chore.id)
    mutator.deferChore(id: chore.id, mode: mode, from: today)
  }

  func uncompleteChore(_ chore: ChoreItem, mutator: ChecklistMutator) {
    Haptics.tap()
    completedChores.remove(chore.id)
    if let i = chores.firstIndex(where: { $0.id == chore.id }) {
      chores[i].lastCompleted = nil
      chores[i].lastCompletedTime = nil
    }
    mutator.uncompleteChore(id: chore.id, date: today)
  }

  private func currentTimeString() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: .now)
  }
}

// MARK: - Open subview (rendered above tasks-done)

struct NextOpenSection: View {
  var model: NextItemsModel
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme

  /// Habits are bucketed by time-of-day on the server ("morning" / "afternoon"
  /// / "evening"). The Next screen only shows the habits for *now* — earlier
  /// buckets shouldn't linger as catch-up debt, and later buckets shouldn't
  /// surface ahead of time. One-bucket-at-a-time keeps the screen focused.
  private var currentHabitBucket: String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case ..<12:  return "morning"
    case 12..<17: return "afternoon"
    default:      return "evening"
    }
  }

  private var habitsNow: [HabitDayItem] {
    let bucket = currentHabitBucket
    return model.openHabits.filter { $0.bucket == bucket }
  }

  var body: some View {
    let chores = model.openChores
    let habits = habitsNow
    let supplements = model.openSupplements
    let events = model.openCalendarEvents

    VStack(alignment: .leading, spacing: 0) {
      if !events.isEmpty {
        sectionHeader("Calendar", tint: theme.color(for: "calendar"))
        ForEach(events, id: \.eventIdentifier) { event in
          CalendarEventRow(event: event,
                           tint: theme.color(for: "calendar"))
        }
      }

      if !chores.isEmpty {
        if !events.isEmpty { Hairline().padding(.top, 8) }
        sectionHeader("Chores", tint: theme.color(for: "chores"))
        ForEach(chores) { chore in
          ChoreRow(chore: chore, model: model, checklistMutator: checklistMutator,
                   tint: theme.color(for: "chores"))
        }
      }

      if !habits.isEmpty {
        if !events.isEmpty || !chores.isEmpty { Hairline().padding(.top, 8) }
        habitBucketHeader(bucket: currentHabitBucket,
                          tint: theme.color(for: "habits"))
        ForEach(habits) { habit in
          HabitRow(habit: habit, model: model, checklistMutator: checklistMutator,
                   tint: theme.color(for: "habits"))
        }
      }

      if !supplements.isEmpty {
        if !events.isEmpty || !chores.isEmpty || !habits.isEmpty {
          Hairline().padding(.top, 8)
        }
        sectionHeader("Supplements", tint: theme.color(for: "supplements"))
        ForEach(supplements) { supp in
          SupplementRow(supplement: supp, model: model, checklistMutator: checklistMutator,
                        tint: theme.color(for: "supplements"))
        }
      }
    }
  }
}

// MARK: - Done subview (rendered after tasks-done)

struct NextDoneSection: View {
  var model: NextItemsModel
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme

  var body: some View {
    let chores = model.doneChores
    let habits = model.doneHabits
    let supplements = model.doneSupplements
    let events = model.doneCalendarEvents

    VStack(alignment: .leading, spacing: 0) {
      // No section headers in the done strip — keep it visually quiet.
      // Items still wear their section accent on the (filled) check. One
      // hairline between adjacent kinds rather than between every row.
      if !events.isEmpty {
        ForEach(events, id: \.eventIdentifier) { event in
          CalendarEventRow(event: event,
                           tint: theme.color(for: "calendar"),
                           inactive: true)
        }
      }
      if !chores.isEmpty {
        if !events.isEmpty { Hairline().padding(.top, 8) }
        ForEach(chores) { chore in
          ChoreRow(chore: chore, model: model, checklistMutator: checklistMutator,
                   tint: theme.color(for: "chores"))
        }
      }
      if !habits.isEmpty {
        if !events.isEmpty || !chores.isEmpty { Hairline().padding(.top, 8) }
        ForEach(habits) { habit in
          HabitRow(habit: habit, model: model, checklistMutator: checklistMutator,
                   tint: theme.color(for: "habits"))
        }
      }
      if !supplements.isEmpty {
        if !events.isEmpty || !chores.isEmpty || !habits.isEmpty {
          Hairline().padding(.top, 8)
        }
        ForEach(supplements) { supp in
          SupplementRow(supplement: supp, model: model, checklistMutator: checklistMutator,
                        tint: theme.color(for: "supplements"))
        }
      }
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

  var body: some View {
    let inactive = habit.done || habit.skipped
    HStack(spacing: 12) {
      TaskCheckbox(
        tint: habit.skipped && !habit.done ? Theme.inkSecondary : tint,
        isDone: inactive
      ) { model.toggleHabit(habit, mutator: checklistMutator) }

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
        model.skipHabit(habit, skipped: !habit.skipped, mutator: checklistMutator)
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

  var body: some View {
    HStack(spacing: 12) {
      TaskCheckbox(tint: tint, isDone: supplement.done) {
        model.toggleSupplement(supplement, mutator: checklistMutator)
      }
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
    // Only attach a context menu when there's actually an action to
    // show — Next view passes no `onDelete`, and SwiftUI's long-press
    // preview still triggers for an empty menu, which feels broken.
    .modifier(SupplementRowContextMenu(onDelete: onDelete))
  }
}

/// Conditional `.contextMenu` for `SupplementRow`. Lifted out so the
/// row's body stays a single expression and we don't apply the modifier
/// when there are no items to show.
private struct SupplementRowContextMenu: ViewModifier {
  let onDelete: (() -> Void)?
  func body(content: Content) -> some View {
    if let onDelete {
      content.contextMenu {
        Button(role: .destructive) { onDelete() } label: {
          Label("Delete", systemImage: "trash")
        }
      }
    } else {
      content
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

  var body: some View {
    let isDone = model.completedChores.contains(chore.id)
    let deferLabel = model.deferredChores[chore.id]
    let inactive = isDone || deferLabel != nil

    HStack(spacing: 12) {
      TaskCheckbox(
        tint: deferLabel != nil ? Theme.inkSecondary : tint,
        isDone: inactive
      ) {
        if isDone {
          model.uncompleteChore(chore, mutator: checklistMutator)
        } else {
          model.completeChore(chore, mutator: checklistMutator)
        }
      }
      Text(chore.emoji ?? "•").font(.body)
      Text(chore.name)
        .font(.septenaTaskTitle)
        .foregroundStyle(inactive ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(inactive)
        .opacity(inactive ? 0.5 : 1)
      Spacer()
      if isDone {
        StatusBadge(text: "Done")
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

// Read-only row for a calendar event in the Next list. Mirrors the webapp,
// which folds /api/calendar/day events into the Next feed instead of
// surfacing them as a separate widget. No checkbox — events come from the
// system calendar and aren't actionable from here.
struct CalendarEventRow: View {
  let event: EKEvent
  let tint: Color
  var inactive: Bool = false

  var body: some View {
    HStack(spacing: 12) {
      // Source-calendar color dot so multi-calendar users can still tell
      // events apart; falls back to the section tint when EventKit gives
      // us no color (rare).
      Circle()
        .fill(eventColor)
        .frame(width: 10, height: 10)
        .padding(.leading, 2)
      Text(event.title?.isEmpty == false ? event.title! : "(Untitled)")
        .font(.septenaTaskTitle)
        .foregroundStyle(inactive ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(inactive)
        .opacity(inactive ? 0.5 : 1)
      Spacer()
      if let trailing = timeRange {
        Text(trailing).font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding)
  }

  private var eventColor: Color {
    if let cg = event.calendar?.cgColor { return Color(cgColor: cg) }
    return tint
  }

  private var timeRange: String? {
    if event.isAllDay { return "all-day" }
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    return "\(f.string(from: event.startDate))–\(f.string(from: event.endDate))"
  }
}

// MARK: - Shared chrome

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
    let hour: Int
    switch bucket {
    case "morning":   hour = 12
    case "afternoon": hour = 17
    default:          hour = 24  // end of day → tomorrow 00:00
    }
    if hour == 24 {
      let startOfTomorrow = cal.date(byAdding: .day, value: 1,
                                     to: cal.startOfDay(for: now))!
      return startOfTomorrow
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
