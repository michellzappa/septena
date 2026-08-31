import Foundation
import SwiftData

// MARK: - Filing suggestions
//
// "Where should this go?" — the gate behind the "→ Suggested" capsule and the
// context menu's Suggested section.
//
// Hoisted out of `TaskListView` so the AppKit shell can render the same chip
// without re-deriving the rules. A second copy of "which tasks are
// suggestible" is exactly the drift docs/SEPTASK.md forbids: the two shells
// would eventually disagree about whether a loose Today capture gets a
// suggestion, and nothing would catch it.
//
// This lives in `Shell/Tasks` rather than `SeptenaCore` because the gate reads
// `TaskRowFlags` and `SettingsKey`, which are Shell-level. `Shell/Tasks`
// compiles into both apps and into the AppKit shell, so it is the shared layer
// here — the same role core plays for data.
@MainActor
enum TaskFilingSuggestions {

  /// The ranked filing picks for `task`, best first, or `nil` when this row
  /// should carry no suggestion at all.
  ///
  /// `childProjectIds` resolves an area's active child projects; callers pass
  /// their own structure snapshot rather than this reaching for the store, so
  /// a list already holding `projects` doesn't pay for a second read.
  static func ranked(for task: SeptenaTask,
                     filter: TaskFilter,
                     engine: SuggestionEngine,
                     childProjectIds: (String) -> Set<String>)
    -> [SuggestionEngine.Suggestion]? {
    guard TaskRowFlags.filingSuggestionsEnabled else { return nil }
    guard task.status == .open else { return nil }
    guard filter != .logbook && filter != .recentlyDeleted else { return nil }
    guard task.project == nil else { return nil }

    // Inbox → area or project. BOTH populations that share the Today Inbox
    // card get the capsule: agent proposals (the triage band) AND loose manual
    // captures the user quick-added (project/area-less, `today == true`, so
    // *not* in the band — but still unfiled work that wants a folding hint).
    if task.isInTriageBand || isLooseTodayInboxCapture(task, filter: filter) {
      if let top = engine.topSuggestion(for: task.id) {
        let ranked = engine.suggestions[task.id] ?? [top]
        return alreadyMatches(task, ranked.first) ? nil : ranked
      }
      guard let s = engine.suggest(forText: task.title) else { return nil }
      return alreadyMatches(task, s) ? nil : [s]
    }

    // Area page: area-direct → child project only.
    if case .area(let areaId) = filter, task.area == areaId {
      let scope = SuggestionEngine.SuggestionScope.projects(childProjectIds(areaId))
      let ranked = engine.rankedSuggestions(forText: task.title, scope: scope)
      guard let top = ranked.first else { return nil }
      return alreadyMatches(task, top) ? nil : ranked
    }

    return nil
  }

  /// The single top pick — what the one-tap row capsule shows.
  static func top(for task: SeptenaTask,
                  filter: TaskFilter,
                  engine: SuggestionEngine,
                  childProjectIds: (String) -> Set<String>)
    -> SuggestionEngine.Suggestion? {
    ranked(for: task, filter: filter, engine: engine,
           childProjectIds: childProjectIds)?.first
  }

  /// A quick-added Today row with no date and no filing — unfiled work that
  /// shares the Inbox card with the agent proposals.
  static func isLooseTodayInboxCapture(_ task: SeptenaTask, filter: TaskFilter) -> Bool {
    filter == .today && task.status == .open
      && task.scheduled == nil && task.deadline == nil
      && task.project == nil && task.area == nil && task.today
  }

  /// Never suggest the place the task already is.
  static func alreadyMatches(_ task: SeptenaTask,
                             _ suggestion: SuggestionEngine.Suggestion?) -> Bool {
    guard let suggestion else { return false }
    return (suggestion.kind == .area && task.area == suggestion.id)
      || (suggestion.kind == .project && task.project == suggestion.id)
  }

  /// Prime the engine for `filter`. Today's Inbox gets the richer per-id
  /// ranked picks; every other creatable list just primes the general model so
  /// area-direct rows can be ranked on demand. Mirrors
  /// `TaskListModel.refreshFilingSuggestions`, which calls the same two engine
  /// entry points.
  static func prime(filter: TaskFilter,
                    context: ModelContext,
                    engine: SuggestionEngine,
                    projects: [Project],
                    areas: [Area]) {
    guard TaskRowFlags.filingSuggestionsEnabled,
          filter != .logbook, filter != .recentlyDeleted else { return }
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
  }
}
