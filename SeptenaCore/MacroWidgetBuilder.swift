import Foundation
import SwiftData

@MainActor
enum MacroWidgetBuilder {
  private static let metricKeyByMacro: [String: String] = [
    "protein": "nutrition.protein_sum",
    "fat": "nutrition.fat_sum",
    "carbs": "nutrition.carbs_sum",
    "kcal": "nutrition.kcal_sum",
    "fiber": "nutrition.fiber_sum",
  ]

  private static let ymdFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
  }()

  static func buildSnapshot(context: ModelContext, date: String = SeptenaDate.today) -> MacroWidgetWire? {
    let dates = last7Dates(ending: date)
    // Oldest fasting window needs the prior day's last meal — fetch one extra day.
    guard let since = ymdDaysBack(from: date, days: 7) else { return nil }
    let entries = ChecklistMirror.loadNutritionEntries(context: context, since: since)
    let stats = ChecklistMirror.buildNutritionStatsResponse(context: context, days: 8)
    let goals = LocalCache.goals(in: context)
    let legacy = NutritionPrefs.loadMacrosConfig()
    let tilePrefs = MacroCatalog.reconcile(
      SettingsMirror.loadSettings(context: context)?.nutrition?.macroTiles
        ?? MacroCatalog.defaultTilePrefs())

    var tiles: [MacroWidgetTileWire] = []
    for pref in tilePrefs where pref.visible {
      guard let macro = MacroCatalog.byID[pref.id] else { continue }
      let range = targetRange(for: macro, goals: goals, legacy: legacy)
      let colorHex = pref.colorHex ?? macro.defaultColorHex
      let (todayValue, history) = series(
        for: macro,
        dates: dates,
        entries: entries,
        stats: stats
      )
      tiles.append(.init(
        key: macro.id,
        label: macro.label,
        unit: macro.unit,
        colorHex: colorHex,
        todayValue: todayValue,
        targetMin: range.min,
        targetMax: range.max,
        history: history))
    }

    guard tiles.contains(where: { $0.todayValue > 0 || $0.targetMax > 0 }) else { return nil }
    let accent = tilePrefs.first(where: { $0.id == "kcal" })?.colorHex
      ?? MacroCatalog.byID["kcal"]?.defaultColorHex
      ?? "#eab308"
    return MacroWidgetWire(tiles: tiles, accentHex: accent, updatedAt: .now)
  }

  private static func series(
    for macro: MacroCatalog.Macro,
    dates: [String],
    entries: [NutritionEntry],
    stats: NutritionStatsResponse
  ) -> (today: Double, history: [Double]) {
    switch macro.source {
    case .entrySum(let field):
      var byDate: [String: Double] = [:]
      for entry in entries {
        byDate[entry.date, default: 0] += entry.value(for: field)
      }
      let history = dates.map { byDate[$0] ?? 0 }
      return (history.last ?? 0, history)

    case .fasting:
      let fastByDate = Dictionary(
        (stats.fasting ?? []).map { ($0.date, $0) },
        uniquingKeysWith: { _, latest in latest }
      )
      var history = dates.map { fastByDate[$0]?.hours ?? 0 }
      if let live = liveFastingHours(stats: stats) {
        history[history.count - 1] = live
      }
      return (history.last ?? 0, history)
    }
  }

  private static func liveFastingHours(stats: NutritionStatsResponse, now: Date = Date()) -> Double? {
    let mealsToday = stats.todayMealCount ?? 0
    guard mealsToday == 0 else { return nil }
    guard let last = stats.yesterdayLastMeal, let lastH = hoursFromHHMM(last) else { return nil }
    let cal = Calendar.current
    let comps = cal.dateComponents([.hour, .minute], from: now)
    let nowH = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60.0
    let hours = (24 - lastH) + nowH
    return hours >= 2 ? hours : nil
  }

  private static func hoursFromHHMM(_ s: String) -> Double? {
    let parts = s.split(separator: ":")
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
    return Double(h) + Double(m) / 60
  }

  private static func last7Dates(ending date: String) -> [String] {
    lastNDates(ending: date, count: 7)
  }

  private static func lastNDates(ending date: String, count: Int) -> [String] {
    let cal = Calendar.current
    let end = SeptenaDate.parse(date) ?? Date()
    return (0..<count).reversed().compactMap { off in
      cal.date(byAdding: .day, value: -off, to: end).map(ymdFormatter.string(from:))
    }
  }

  private static func ymdDaysBack(from date: String, days: Int) -> String? {
    guard let end = SeptenaDate.parse(date) else { return nil }
    return Calendar.current.date(byAdding: .day, value: -days, to: end)
      .map(ymdFormatter.string(from:))
  }

  private static func targetRange(
    for macro: MacroCatalog.Macro,
    goals: [Goal],
    legacy: MacrosConfig?
  ) -> (min: Double, max: Double) {
    if let g = goalRange(forMacroID: macro.id, goals: goals) {
      return (g.min, g.max)
    }
    let range: MacroRange?
    switch macro.id {
    case "protein": range = legacy?.protein
    case "fat": range = legacy?.fat
    case "carbs": range = legacy?.carbs
    case "kcal": range = legacy?.kcal
    case "fiber": range = legacy?.fiber
    case "fasting": range = legacy?.fasting
    default: range = nil
    }
    return (range?.min ?? macro.defaultMin, range?.max ?? macro.defaultMax)
  }

  private static func goalRange(forMacroID id: String, goals: [Goal]) -> MacroRange? {
    guard let key = metricKeyByMacro[id] else { return nil }
    guard let g = goals.first(where: {
      $0.metricKey == key && $0.metricComparator == "range" && $0.metricTargetUpper != nil
    }),
          let lo = g.metricTarget,
          let hi = g.metricTargetUpper,
          hi > lo else { return nil }
    return MacroRange(min: lo, max: hi, unit: MacroCatalog.byID[id]?.unit)
  }
}
