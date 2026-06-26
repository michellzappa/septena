import Foundation
import SwiftData

/// Today's macro rings + fasting context — shared by the watch snapshot publisher
/// and the iOS Section Tile widget catalog so both surfaces read the same data.
@MainActor
enum NutritionRingsBuilder {
  /// Macro key → its goal metric key, mirroring the app's `NutritionTargets`.
  private static let macroOrder: [(key: String, metricKey: String)] = [
    ("kcal",    "nutrition.kcal_sum"),
    ("protein", "nutrition.protein_sum"),
    ("carbs",   "nutrition.carbs_sum"),
    ("fat",     "nutrition.fat_sum"),
    ("fiber",   "nutrition.fiber_sum"),
  ]

  /// Device-local mirror of `SettingsKey.nutritionTrackFasting` (app target).
  private static let trackFastingDefaultsKey = "septena.nutrition.trackFasting"

  /// Today's macro totals-so-far vs targets. Returns nil when no macro has
  /// either data or a target.
  static func buildRings(context: ModelContext, date: String) -> NutritionRingsWire? {
    let entries = ChecklistMirror.loadNutritionEntries(context: context, since: date)
      .filter { $0.date == date }

    let totals: [String: Double] = [
      "kcal":    entries.reduce(0) { $0 + $1.kcal },
      "protein": entries.reduce(0) { $0 + $1.proteinG },
      "carbs":   entries.reduce(0) { $0 + $1.carbsG },
      "fat":     entries.reduce(0) { $0 + $1.fatG },
      "fiber":   entries.reduce(0) { $0 + ($1.fiberG ?? 0) },
    ]

    let goals = LocalCache.goals(in: context)
    let legacy = NutritionPrefs.loadMacrosConfig()
    func goalFor(_ key: String, metricKey: String) -> Double? {
      if let g = goals.first(where: { $0.metricKey == metricKey }),
         let target = g.metricTargetUpper ?? g.metricTarget, target > 0 {
        return target
      }
      let range: MacroRange?
      switch key {
      case "kcal":    range = legacy?.kcal
      case "protein": range = legacy?.protein
      case "carbs":   range = legacy?.carbs
      case "fat":     range = legacy?.fat
      case "fiber":   range = legacy?.fiber
      default:        range = nil
      }
      return range.map { $0.max }
    }

    let tiles = MacroCatalog.reconcile(
      SettingsMirror.loadSettings(context: context)?.nutrition?.macroTiles
        ?? MacroCatalog.defaultTilePrefs())
    func colorFor(_ key: String) -> String? {
      tiles.first(where: { $0.id == key })?.colorHex
        ?? MacroCatalog.byID[key]?.defaultColorHex
    }

    let rings = macroOrder.map { macro in
      RingMetricWire(key: macro.key,
                     value: totals[macro.key] ?? 0,
                     goal: goalFor(macro.key, metricKey: macro.metricKey),
                     colorHex: colorFor(macro.key))
    }
    guard rings.contains(where: { $0.value > 0 || $0.goal != nil }) else { return nil }
    return NutritionRingsWire(rings: rings)
  }

  /// Fasting anchor + target for ring morphs. When `prior` is supplied and the
  /// meal fetch is empty, it is returned for up to 48h (watch snapshot stickiness).
  static func buildFasting(
    context: ModelContext,
    prior: FastingWire? = nil
  ) -> FastingWire? {
    let tracks = SettingsMirror.loadSettings(context: context)?.nutrition?.trackFasting
      ?? UserDefaults.standard.bool(forKey: trackFastingDefaultsKey)
    guard tracks else { return nil }

    let since = SeptenaDate.format(
      Calendar.current.date(byAdding: .day, value: -2, to: Date()))
    let meals = ChecklistMirror.loadNutritionEntries(context: context, since: since)
      .filter { $0.foods != ["Water"] }
    guard let last = meals.max(by: { ($0.date, $0.time) < ($1.date, $1.time) }),
          let lastMealAt = SeptenaDate.instant(date: last.date, time: last.time)
    else {
      if let prior, Date().timeIntervalSince(prior.lastMealAt) < 48 * 3600 {
        return prior
      }
      return nil
    }

    let targetH = NutritionPrefs.loadMacrosConfig()?.fasting?.min ?? FastingDefaults.targetMinH
    let tiles = MacroCatalog.reconcile(
      SettingsMirror.loadSettings(context: context)?.nutrition?.macroTiles
        ?? MacroCatalog.defaultTilePrefs())
    let colorHex = tiles.first(where: { $0.id == "fasting" })?.colorHex
      ?? MacroCatalog.byID["fasting"]?.defaultColorHex

    return FastingWire(
      lastMealAt: lastMealAt,
      sinceLabel: String(last.time.prefix(5)),
      targetHours: max(targetH, 1),
      colorHex: colorHex)
  }
}
