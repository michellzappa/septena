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
// What lives here so far — the two derived snapshots that are pure functions of
// (filter, store, structure) and have nothing to do with laying out rows:
//   • the woven calendar agenda,
//   • the per-row filing suggestions behind the "→ Suggested" capsule,
//   • per-project completion ratios for the project pie glyph.
//
// Still in the view, for the next increment: the task snapshot arrays
// themselves (`items` / `triageStorage`), the settle/ghost/arrival merge
// passes, and the debounced `load()` that drives them.
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
