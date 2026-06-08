import Foundation
import SwiftData

// Macro targets now live in goals (range goals tagged `nutrition`). This is
// the read bridge: the section asks here first, and only falls back to the
// legacy `MacrosConfig` (server-era KVS) / catalog defaults when a macro has
// no goal. Setting a target = editing the goal (it surfaces in the section's
// goals strip and under the Food coach), so the two stay in sync — the
// "bidirectional" the whole targets-as-goals move was about.

@MainActor
enum NutritionTargets {
  /// Macro catalog id → the goal metric key that carries its target band.
  /// Only the macros that are genuine commitments map; the guardrail macros
  /// (sugar, sodium, …) keep their catalog defaults.
  static let metricKeyByMacro: [String: String] = [
    "protein": "nutrition.protein_sum",
    "fat":     "nutrition.fat_sum",
    "carbs":   "nutrition.carbs_sum",
    "kcal":    "nutrition.kcal_sum",
    "fiber":   "nutrition.fiber_sum",
  ]

  /// The target band for a macro sourced from its range goal, or nil if the
  /// user has no range goal for it (callers fall back to MacrosConfig / catalog).
  static func goalRange(forMacroID id: String, context: ModelContext) -> MacroRange? {
    guard let key = metricKeyByMacro[id] else { return nil }
    let match = LocalCache.goals(in: context).first {
      $0.metricKey == key && $0.metricComparator == "range" && $0.metricTargetUpper != nil
    }
    guard let g = match, let lo = g.metricTarget, let hi = g.metricTargetUpper, hi > lo else { return nil }
    return MacroRange(min: lo, max: hi, unit: MacroCatalog.byID[id]?.unit)
  }
}
