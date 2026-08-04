import SwiftUI
import SwiftData
import EventKit

// The task list's read/derive layer, pulled out of `TaskListView`.
//
// This is the first increment of docs/TASK_LIST_OBSERVATION_PLAN.md: one
// `@Observable` object owns the list's derived data and is the only thing that
// rebuilds it, instead of a dozen `@State` snapshots the view refreshes by hand
// from ~30 call sites. Each increment moves one concern here and deletes the
// matching state + refresher from the view.
//
// What lives here so far:
//   • the derived snapshots that are pure functions of (filter, store,
//     structure) — the woven calendar agenda, the per-row filing suggestions
//     behind the "→ Suggested" capsule, per-project completion ratios;
//   • the settle store and this session's completed / created ids;
//   • `merge`, which reconciles a fresh store read against what's on screen
//     (ghost-check, settle preservation, arrival detection).
//
// Still in the view, for the next increment: the snapshot arrays themselves
// (`items` / `triageStorage`) and the debounced `load()` that drives them.
// Motion stays in the view on purpose — `merge` returns which beat it earned
// rather than playing it, so this type has no opinion about animation.
@MainActor
@Observable
final class TaskListModel {
  /// The day's calendar events for the lists that weave them in (Today,
  /// Upcoming). Empty whenever the feature is off, access isn't granted, or
  /// this isn't one of those lists — so the view renders straight from this
  /// without re-checking.
  private(set) var calendarEvents: [EKEvent] = []

  /// Top filing pick per visible open row, snapshotted so the row capsule and
  /// the context menu can't disagree (both resolve through
  /// `SuggestionEngine`).
  private(set) var filingSuggestions: [String: SuggestionEngine.Suggestion] = [:]

  /// Completion ratio per project, for the pie glyph in mixed-list headers.
  /// Aggregated from raw entities rather than projecting the whole historical
  /// corpus into row DTOs on every refresh.
  private(set) var progressByProject: [String: Double] = [:]

  /// Drives the "linger → fade" beat after a check: a just-completed row holds
  /// its place for a moment, then fades where it sits instead of being yanked
  /// the instant you tap. Owned here because the merge below has to know which
  /// rows are mid-settle to keep them alive across a re-read.
  let settle = SettleStore()

  /// Rows completed during this view's lifetime, and rows created on this
  /// device this session. Both exist to tell "the user just did this" apart
  /// from "another device did this" — the first animates locally and must not
  /// be ghost-checked again, the second must not get the remote-arrival beat.
  private(set) var sessionDoneIds: Set<String> = []
  var sessionCreatedIds: Set<String> = []

  /// Which animation a merge earned. Ghost completions prefer settle; remote
  /// arrivals prefer expand; an ordinary re-read gets neither. Returned rather
  /// than applied so the view keeps ownership of motion + the promote flash,
  /// which are presentation, not data.
  enum MergeMotion { case none, settle, expand }

  struct MergeOutcome {
    let rows: [SeptenaTask]
    let motion: MergeMotion
    /// Rows that arrived from another device — the view flashes any that landed
    /// on Today.
    let arrived: Set<String>
  }

  // MARK: - Merge

  /// Reconcile a fresh store read against what's on screen.
  ///
  /// Three passes, in order, each of which exists because a naive assignment
  /// looked wrong:
  ///   1. **Ghost-check** — a row completed on ANOTHER device should animate
  ///      like a local tap rather than blink out. Detected two ways because a
  ///      completed row shows up differently per filter: drop-done lists
  ///      (Today / Inbox / Upcoming) make it vanish, while project / area lists
  ///      keep every status so it's present-but-flipped. Only the vanished ids
  ///      hit the store, so an ordinary reload stays a no-op.
  ///   2. **Settle preservation** — a row mid-fade is reinserted at the slot it
  ///      held, anchored after its nearest surviving predecessor, so it fades in
  ///      place instead of jumping to the bottom.
  ///   3. **Arrival detection** — rows that weren't on screen a moment ago and
  ///      weren't created here get the gentle expand-in beat.
  /// `openSettleWindow` is called for each row this pass ghosts, BEFORE the
  /// preservation pass reads `isSettling` — the view supplies it because
  /// closing the window is an animated transaction, and animation belongs to
  /// the view. Without it a remotely-completed row that vanished from the fresh
  /// read is never preserved, so it blinks out instead of fading in place.
  func merge(prior: [SeptenaTask],
             fresh: [SeptenaTask],
             context: ModelContext,
             animateArrivals: Bool,
             ownCreations: Set<String>,
             openSettleWindow: (String) -> Void) -> MergeOutcome {
    let ghost = ghostCheckRemoteCompletions(prior: prior, fresh: fresh,
                                            context: context,
                                            openSettleWindow: openSettleWindow)
    let rows = RemoteTaskSync.preservingSettling(fresh: fresh,
                                                 prior: ghost.rows,
                                                 isSettling: settle.isSettling)
    let arrived = RemoteTaskSync.arrivingIDs(prior: prior,
                                             fresh: fresh,
                                             excluding: ownCreations,
                                             animate: animateArrivals)
    let motion: MergeMotion = !ghost.ghosted.isEmpty ? .settle
                            : (!arrived.isEmpty ? .expand : .none)
    return MergeOutcome(rows: rows, motion: motion, arrived: arrived)
  }

  /// Flip rows the user completed elsewhere to `.done` and open their settle
  /// window, so a passive sync replays the same beat a tap does. Silent on
  /// purpose — no `TaskCelebration`, so a remote completion never buzzes.
  private func ghostCheckRemoteCompletions(prior: [SeptenaTask],
                                           fresh: [SeptenaTask],
                                           context: ModelContext,
                                           openSettleWindow: (String) -> Void)
    -> (rows: [SeptenaTask], ghosted: Set<String>) {
    let candidates = prior.filter {
      $0.status == .open && !settle.isSettling($0.id) && !sessionDoneIds.contains($0.id)
    }
    guard !candidates.isEmpty else { return (prior, []) }
    let freshByID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var done = Set<String>()
    var vanished = Set<String>()
    for c in candidates {
      if let f = freshByID[c.id] { if f.status == .done { done.insert(c.id) } }
      else { vanished.insert(c.id) }
    }
    if !vanished.isEmpty {
      done.formUnion(LocalCache.completedIDs(among: vanished, in: context))
    }
    guard !done.isEmpty else { return (prior, []) }
    var rows = prior
    for id in done {
      openSettleWindow(id)
      sessionDoneIds.insert(id)
      if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].status = .done }
    }
    return (rows, done)
  }

  // MARK: - Session bookkeeping

  func noteCompleted(_ id: String, done: Bool) {
    if done { sessionDoneIds.insert(id) } else { sessionDoneIds.remove(id) }
  }

  func noteCreated(_ id: String) { sessionCreatedIds.insert(id) }

  /// A filter swap starts a fresh session: nothing on the new list was
  /// completed or created "just now" from the user's point of view.
  func resetSession() {
    sessionDoneIds = []
    sessionCreatedIds = []
    settle.cancelAll()
  }

  // MARK: - Calendar agenda

  /// Pull the day's events for the lists that show them. `CalendarBridge` is
  /// `@MainActor` like this type, so the read is a direct call — which is what
  /// lets the view refresh synchronously on appear and on a filter swap, and
  /// get a correct first frame instead of popping a beat later.
  func refreshCalendarEvents(filter: TaskFilter, enabled: Bool) {
    guard enabled,
          filter == .today || filter == .upcoming,
          CalendarBridge.shared.access == .granted
    else {
      if !calendarEvents.isEmpty { calendarEvents = [] }
      return
    }
    calendarEvents = filter == .today
      ? CalendarBridge.shared.remainingTodayEvents()
      : CalendarBridge.shared.upcomingEvents(days: 30)
  }

  // MARK: - Filing suggestions

  /// Rebuild the per-row filing-suggestion snapshot. Cheap to call eagerly: the
  /// classifier's model build is memoized on a corpus signature
  /// (`SuggestionEngine.ensureModel`), so an appear beat and a load beat train
  /// it at most once between them.
  ///
  /// `rankedTop` is supplied by the caller rather than reimplemented here so
  /// the snapshot and the on-demand context-menu path stay one code path.
  func refreshFilingSuggestions(
    filter: TaskFilter,
    context: ModelContext,
    engine: SuggestionEngine,
    projects: [Project],
    areas: [Area],
    candidates: [SeptenaTask],
    rankedTop: (SeptenaTask) -> SuggestionEngine.Suggestion?
  ) {
    guard TaskRowFlags.filingSuggestionsEnabled,
          filter != .logbook, filter != .recentlyDeleted else {
      if !filingSuggestions.isEmpty { filingSuggestions = [:] }
      return
    }
    // Today's Inbox gets the richer per-id ranked picks; every other creatable
    // list just primes the general model so area-direct rows can be ranked on
    // demand.
    if filter == .today {
      engine.refresh(inbox: LocalCache.tasks(in: context, filter: .triage),
                     allTasks: LocalCache.trainingTasks(in: context),
                     projects: projects,
                     areas: areas)
    } else {
      engine.prepare(allTasks: LocalCache.trainingTasks(in: context),
                     projects: projects,
                     areas: areas)
    }
    var fresh: [String: SuggestionEngine.Suggestion] = [:]
    for task in candidates {
      if let top = rankedTop(task) { fresh[task.id] = top }
    }
    filingSuggestions = fresh
  }

  // MARK: - Project progress

  /// Only the surfaces that render project headers pay for this; everywhere
  /// else it clears so a stale ratio can't paint after a filter swap.
  func refreshProjectProgress(filter: TaskFilter, context: ModelContext) {
    if filter == .today || filter == .unscheduled {
      progressByProject = LocalCache.projectCompletionRatios(in: context)
    } else if !progressByProject.isEmpty {
      progressByProject = [:]
    }
  }
}
