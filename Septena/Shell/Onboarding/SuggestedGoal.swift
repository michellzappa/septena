import Foundation
import SwiftData

// A recommended starter goal a section offers a brand-new user. It's a normal
// metric-bound Goal (same `metricKey` infrastructure the Goals tab and section
// strips use) — `SuggestedGoal` is just the *proposal* of one, shown in the
// first-run "Set your starting targets" step and seeded for existing users by
// the per-section target migrations. Declaring them on the plugin keeps each
// section's sensible defaults in one place (the same place its `aimMetrics`
// live), so the onboarding step, the migration, and the section never disagree.

struct SuggestedGoal: Identifiable, Hashable {
  /// The metric this goal measures (stable key, e.g. `training.session_count`).
  let metricKey: String
  /// The section that owns it — the goal is tagged with this so it surfaces in
  /// that section's goals strip.
  let sectionKey: String
  /// User-facing goal title, e.g. "4 training sessions/week".
  let text: String
  /// `gte` | `lte` | `eq` | `range`.
  let comparator: String
  /// Lower bound / exact target.
  let target: Double
  /// Upper bound — only for `range`.
  let upper: Double?
  /// `today` | `calendarWeek`.
  let window: String
  /// Unit shown next to the editable target field (e.g. "sets", "min", "ml").
  let unitLabel: String
  /// Whether this starts pre-checked in the onboarding step — reserve for the
  /// few genuinely universal targets so a new user leaves with a small set.
  let recommended: Bool

  var id: String { metricKey }

  /// A copy with edited target bounds (the onboarding step lets the user tweak
  /// before seeding).
  func with(target: Double, upper: Double?) -> SuggestedGoal {
    SuggestedGoal(metricKey: metricKey, sectionKey: sectionKey, text: text,
                  comparator: comparator, target: target, upper: upper,
                  window: window, unitLabel: unitLabel, recommended: recommended)
  }
}

@MainActor
extension SuggestedGoal {
  /// Create this as a real goal unless one already exists for its metric key.
  /// Dedup-guarded so onboarding and the migration compose (and re-runs are
  /// safe). Caller passes the current set of taken metric keys.
  func seedIfAbsent(existingKeys: Set<String>, mutator: GoalMutator) {
    guard !existingKeys.contains(metricKey) else { return }
    let goal = mutator.createGoal(text: text)
    mutator.updateGoal(id: goal.id, text: text, sections: [sectionKey])
    mutator.updateGoalMetric(id: goal.id,
                             metricKey: metricKey,
                             window: window,
                             comparator: comparator,
                             target: target,
                             baseline: nil,
                             upper: comparator == "range" ? upper : nil)
  }

  /// All suggested goals for the given section keys, in registry order, with
  /// each section's own order preserved. Used by the onboarding targets step.
  static func all(forSections keys: Set<String>, context: ModelContext) -> [SuggestedGoal] {
    SectionRegistry.all.flatMap { plugin -> [SuggestedGoal] in
      guard keys.contains(plugin.manifest.key) else { return [] }
      return plugin.suggestedGoals(context: context)
    }
  }
}
