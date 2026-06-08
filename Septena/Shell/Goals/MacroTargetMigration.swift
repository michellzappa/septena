import Foundation
import SwiftData

// One-shot migration: lift the user's nutrition macro targets into real range
// goals tagged `nutrition`. A target is a commitment, and a commitment is a
// goal — so once migrated they show progress, surface in the Nutrition strip
// and under the Food coach, and the coach can adjust them. The goals-first
// read in `NutritionTargets` then sources the section's bands from these.
//
// The "effective" band is the source of truth the user actually sees:
//   • their personal `MacrosConfig` (iCloud KVS, server-era) when present,
//   • otherwise the `MacroCatalog` default for that macro (which is what the
//     section renders when no MacrosConfig exists — i.e. still "their" target).
// So whatever band shows in Nutrition today becomes a goal.
//
// Idempotent (flag-gated) and dedup-guarded (never clobbers an existing goal
// for that metric). Runs after CloudKit bind + fetch so it can't duplicate a
// band a sibling device already migrated.

@MainActor
enum MacroTargetMigration {
  // v2: v1 gave up permanently when MacrosConfig was nil (it set the flag and
  // never retried), so users whose targets are the catalog defaults — or whose
  // KVS hadn't synced yet — imported nothing. v2 always migrates from the
  // effective band and only sets the flag once goals are in place.
  private static let flag = "migration.macroTargetsToGoals.v2"

  /// macro id → (metric key, label, unit). Order = creation order.
  private static let macros: [(id: String, key: String, label: String, unit: String)] = [
    ("protein", "nutrition.protein_sum", "Protein",  "g"),
    ("fat",     "nutrition.fat_sum",     "Fat",      "g"),
    ("carbs",   "nutrition.carbs_sum",   "Carbs",    "g"),
    ("kcal",    "nutrition.kcal_sum",    "Calories", "kcal"),
    ("fiber",   "nutrition.fiber_sum",   "Fiber",    "g"),
  ]

  static func runIfNeeded(context: ModelContext) {
    guard !UserDefaults.standard.bool(forKey: flag) else { return }

    let cfg = NutritionPrefs.loadMacrosConfig()   // may be nil → catalog defaults
    let mutator = SeptenaServices.shared.goalMutator
    let existingKeys = Set(LocalCache.goals(in: context).compactMap(\.metricKey))

    for m in macros {
      guard !existingKeys.contains(m.key) else { continue }   // never clobber
      guard let band = effectiveBand(for: m.id, cfg: cfg), band.max > band.min else { continue }
      let text = "\(m.label) \(int(band.min))–\(int(band.max)) \(m.unit)/day"
      let goal = mutator.createGoal(text: text)
      mutator.updateGoal(id: goal.id, text: text, sections: ["nutrition"])
      mutator.updateGoalMetric(id: goal.id,
                               metricKey: m.key,
                               window: "today",
                               comparator: "range",
                               target: band.min,
                               baseline: nil,
                               upper: band.max)
    }

    UserDefaults.standard.set(true, forKey: flag)
  }

  /// The band the user effectively has for a macro: their MacrosConfig value,
  /// else the catalog default (what the section shows when no config exists).
  private static func effectiveBand(for id: String, cfg: MacrosConfig?) -> (min: Double, max: Double)? {
    if let r = configBand(for: id, cfg: cfg) { return (r.min, r.max) }
    if let macro = MacroCatalog.byID[id] { return (macro.defaultMin, macro.defaultMax) }
    return nil
  }

  private static func configBand(for id: String, cfg: MacrosConfig?) -> MacroRange? {
    guard let cfg else { return nil }
    switch id {
    case "protein": return cfg.protein
    case "fat":     return cfg.fat
    case "carbs":   return cfg.carbs
    case "kcal":    return cfg.kcal
    case "fiber":   return cfg.fiber
    default:        return nil
    }
  }

  private static func int(_ v: Double) -> String { String(Int(v.rounded())) }
}
