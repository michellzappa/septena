import SwiftUI

// Shared goal-grid plumbing reused by the Goals surface and the Coach
// destination. Two things live here so both surfaces stay in lockstep:
//
//   • GoalGrid.columns — the responsive tile-grid column spec (iPhone
//     compact = 1, iPad regular = 3, macOS = adaptive ~280pt).
//   • GoalDrafts.save — the single Discovery-draft → Goal write path, so a
//     coach proposing a goal and a mini-app finishing both land through the
//     exact same mutator calls (no divergent save logic).

enum GoalGrid {
  /// Mirrors WeekDashboardView's grid. `regularWidth` is the iOS horizontal
  /// size class being `.regular`; ignored on macOS (always adaptive).
  static func columns(regularWidth: Bool) -> [GridItem] {
    #if os(iOS)
    let count = regularWidth ? 3 : 1
    return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    #else
    return [GridItem(.adaptive(minimum: 280), spacing: 14)]
    #endif
  }
}

enum GoalDrafts {
  /// Persist the included drafts through GoalMutator and return the created
  /// goals (newest first, ready to splice into a local list). Mirrors the
  /// create → updateGoal → updateGoalMetric sequence the Goals tab has always
  /// used; centralized so the Coach surface shares it verbatim.
  @MainActor
  @discardableResult
  static func save(_ drafts: [DraftGoal], mutator: GoalMutator) -> [Goal] {
    var created: [Goal] = []
    for draft in drafts where draft.include {
      let clean = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !clean.isEmpty else { continue }

      let goal = mutator.createGoal(text: clean)
      mutator.updateGoal(id: goal.id, text: clean, sections: draft.sections)
      if let metricKey = draft.metricKey {
        mutator.updateGoalMetric(id: goal.id,
                                 metricKey: metricKey,
                                 window: draft.metricWindow,
                                 comparator: draft.metricComparator,
                                 target: draft.metricTarget,
                                 baseline: draft.metricBaseline,
                                 upper: draft.metricTargetUpper)
      }

      var updated = goal
      updated.text = clean
      updated.sections = draft.sections
      updated.metricKey = draft.metricKey
      updated.metricWindow = draft.metricWindow
      updated.metricComparator = draft.metricComparator
      updated.metricTarget = draft.metricTarget
      updated.metricBaseline = draft.metricBaseline
      updated.metricTargetUpper = draft.metricTargetUpper
      created.append(updated)
    }
    return created
  }
}
