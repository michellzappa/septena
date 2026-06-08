import Foundation
import SwiftData

// One-shot migration: the user's nutrition macro targets used to live in
// `MacrosConfig` (min/max bands in iCloud KVS, server-era). A target is a
// commitment, and a commitment is a goal — so we lift each macro band into a
// real range goal tagged `nutrition`. Once migrated, the macro targets show
// progress, surface in the Nutrition strip and under the Food coach, and the
// coach can adjust them.
//
// Idempotent (flag-gated) and dedup-guarded (skips a macro that already has a
// goal). Runs after CloudKit binding + fetch so it doesn't duplicate bands
// another device already migrated. The legacy MacrosConfig is left intact for
// now — the Nutrition section still reads it until the read-side moves to
// goals (the "bidirectional" follow-up).

@MainActor
enum MacroTargetMigration {
  private static let flag = "migration.macroTargetsToGoals.v1"

  static func runIfNeeded(context: ModelContext) {
    guard !UserDefaults.standard.bool(forKey: flag) else { return }
    guard let cfg = NutritionPrefs.loadMacrosConfig() else {
      // Nothing to migrate — still set the flag so we don't re-check forever.
      UserDefaults.standard.set(true, forKey: flag)
      return
    }

    let mutator = SeptenaServices.shared.goalMutator
    let existingKeys = Set(LocalCache.goals(in: context).compactMap(\.metricKey))

    func migrate(_ metricKey: String, _ label: String, _ range: MacroRange, _ unit: String) {
      guard !existingKeys.contains(metricKey) else { return }
      guard range.max > range.min else { return }
      let text = "\(label) \(int(range.min))–\(int(range.max)) \(unit)/day"
      let goal = mutator.createGoal(text: text)
      mutator.updateGoal(id: goal.id, text: text, sections: ["nutrition"])
      mutator.updateGoalMetric(id: goal.id,
                               metricKey: metricKey,
                               window: "today",
                               comparator: "range",
                               target: range.min,
                               baseline: nil,
                               upper: range.max)
    }

    migrate("nutrition.protein_sum", "Protein", cfg.protein, "g")
    migrate("nutrition.fat_sum",     "Fat",     cfg.fat,     "g")
    migrate("nutrition.carbs_sum",   "Carbs",   cfg.carbs,   "g")
    migrate("nutrition.kcal_sum",    "Calories", cfg.kcal,   "kcal")
    if let fiber = cfg.fiber { migrate("nutrition.fiber_sum", "Fiber", fiber, "g") }

    UserDefaults.standard.set(true, forKey: flag)
  }

  private static func int(_ v: Double) -> String { String(Int(v.rounded())) }
}
