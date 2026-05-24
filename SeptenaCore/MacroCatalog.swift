import Foundation
import SwiftData

/// Single source of truth for the macros surfaced in the Nutrition tile grid
/// and the matching settings UI. The id strings persist into `NutritionSettings.macroTiles`
/// — never rename one without a migration.
enum MacroCatalog {

  /// Where a tile's daily series comes from.
  enum Source: Hashable {
    /// Sum a property of each `NutritionEntry` for the day. Cast to Double; nil counts as 0.
    case entrySum(EntryField)
    /// Special-cased fasting series — built from `NutritionStatsResponse.fasting`,
    /// not from individual entries.
    case fasting
  }

  /// KeyPath-equivalent enum so the catalog stays Hashable / non-generic.
  /// The view layer maps these to the actual entry fields when summing.
  enum EntryField: String, Hashable {
    case protein, fat, saturatedFat, carbs, sugar, fiber, alcohol, kcal
    case sodium, cholesterol, potassium, water
  }

  struct Macro: Identifiable, Hashable {
    let id: String
    let label: String
    let unit: String
    let defaultColorHex: String
    /// Built-in fallback when `MacrosConfig` doesn't carry a target for this id.
    /// For "limit" macros (sat fat, sugar, sodium, cholesterol, alcohol) min is 0
    /// and max is the recommended ceiling. For "floor" macros (potassium, water)
    /// min is the recommended floor and max is min*1.5. Range macros (protein,
    /// fat, carbs, fiber, kcal) follow `MacrosConfig` first and fall back to these.
    let defaultMin: Double
    let defaultMax: Double
    /// Whether this macro shows up in the tile grid for first-launch users
    /// (i.e. before they touch the settings).
    let defaultVisible: Bool
    let source: Source
  }

  /// Catalog order is also the default tile order. Adding a macro: append it
  /// here and decide whether `defaultVisible` should be true.
  static let all: [Macro] = [
    .init(id: "protein",       label: "Protein",        unit: "g",    defaultColorHex: "#ef4444",
          defaultMin: 100,  defaultMax: 140,   defaultVisible: true,  source: .entrySum(.protein)),
    .init(id: "fat",           label: "Fat",            unit: "g",    defaultColorHex: "#f59e0b",
          defaultMin: 50,   defaultMax: 80,    defaultVisible: true,  source: .entrySum(.fat)),
    .init(id: "saturatedFat",  label: "Saturated Fat",  unit: "g",    defaultColorHex: "#fb923c",
          defaultMin: 0,    defaultMax: 20,    defaultVisible: false, source: .entrySum(.saturatedFat)),
    .init(id: "carbs",         label: "Carbs",          unit: "g",    defaultColorHex: "#3b82f6",
          defaultMin: 150,  defaultMax: 250,   defaultVisible: true,  source: .entrySum(.carbs)),
    .init(id: "sugar",         label: "Sugar",          unit: "g",    defaultColorHex: "#ec4899",
          defaultMin: 0,    defaultMax: 50,    defaultVisible: false, source: .entrySum(.sugar)),
    .init(id: "fiber",         label: "Fiber",          unit: "g",    defaultColorHex: "#10b981",
          defaultMin: 25,   defaultMax: 35,    defaultVisible: true,  source: .entrySum(.fiber)),
    .init(id: "alcohol",       label: "Alcohol",        unit: "g",    defaultColorHex: "#a855f7",
          defaultMin: 0,    defaultMax: 14,    defaultVisible: false, source: .entrySum(.alcohol)),
    .init(id: "kcal",          label: "Kcal",           unit: "kcal", defaultColorHex: "#eab308",
          defaultMin: 1800, defaultMax: 2400,  defaultVisible: true,  source: .entrySum(.kcal)),
    .init(id: "sodium",        label: "Sodium",         unit: "mg",   defaultColorHex: "#64748b",
          defaultMin: 0,    defaultMax: 2300,  defaultVisible: false, source: .entrySum(.sodium)),
    .init(id: "cholesterol",   label: "Cholesterol",    unit: "mg",   defaultColorHex: "#dc2626",
          defaultMin: 0,    defaultMax: 300,   defaultVisible: false, source: .entrySum(.cholesterol)),
    .init(id: "potassium",     label: "Potassium",      unit: "mg",   defaultColorHex: "#14b8a6",
          defaultMin: 3500, defaultMax: 4700,  defaultVisible: false, source: .entrySum(.potassium)),
    .init(id: "water",         label: "Water",          unit: "ml",   defaultColorHex: "#06b6d4",
          defaultMin: 2000, defaultMax: 3000,  defaultVisible: false, source: .entrySum(.water)),
    .init(id: "fasting",       label: "Fasting",        unit: "h",    defaultColorHex: "#8b5cf6",
          defaultMin: 14,   defaultMax: 16,    defaultVisible: true,  source: .fasting),
  ]

  static let byID: [String: Macro] =
    Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

  /// The first-run tile list — every catalog entry, in catalog order, with the
  /// catalog's `defaultVisible` flag. Used when `NutritionSettings.macroTiles` is nil.
  static func defaultTilePrefs() -> [MacroTilePref] {
    all.map { MacroTilePref(id: $0.id, colorHex: nil, visible: $0.defaultVisible) }
  }

  /// Reconciles a stored prefs list with the current catalog: drops ids the
  /// catalog no longer knows about, appends new catalog entries at the end
  /// (hidden by default — they show up in settings ready to enable). Stable
  /// for ids that already exist in `stored`.
  static func reconcile(_ stored: [MacroTilePref]) -> [MacroTilePref] {
    let known = Set(all.map(\.id))
    let cleaned = stored.filter { known.contains($0.id) }
    let present = Set(cleaned.map(\.id))
    let appended = all
      .filter { !present.contains($0.id) }
      .map { MacroTilePref(id: $0.id, colorHex: nil, visible: false) }
    return cleaned + appended
  }
}

@MainActor
enum NutritionPrefsWriter {
  /// Persist a new tile-prefs list. Reads the current `AppSettings`, swaps in
  /// the new `nutrition.macroTiles`, and writes back through `SettingsMirror`
  /// — which queues a CloudKit push so other devices pick it up.
  static func saveTilePrefs(_ prefs: [MacroTilePref],
                            context: ModelContext,
                            engine: CKEngine?) {
    var settings = SettingsMirror.loadSettings(context: context)
      ?? AppSettings(sectionOrder: nil, targets: nil, units: nil,
                     time: nil, theme: nil, eink: nil, nutrition: nil)
    var nut = settings.nutrition
      ?? NutritionSettings(macroColors: nil, macroTiles: nil)
    nut.macroTiles = prefs
    settings.nutrition = nut
    SettingsMirror.upsert(settings: settings, context: context, engine: engine)
    // Local UI refresh — the destination view listens for this notification
    // and re-reads tile prefs, so reorder/toggle changes appear immediately
    // without waiting for a CloudKit round-trip.
    NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
  }
}

extension NutritionEntry {
  /// Pulls one of the catalog's `EntryField` values off a `NutritionEntry`.
  /// Centralized here so the tile grid and the settings preview agree on which
  /// property feeds which catalog id.
  func value(for field: MacroCatalog.EntryField) -> Double {
    switch field {
    case .protein:      return proteinG
    case .fat:          return fatG
    case .saturatedFat: return saturatedFatG ?? 0
    case .carbs:        return carbsG
    case .sugar:        return sugarG ?? 0
    case .fiber:        return fiberG ?? 0
    case .alcohol:      return alcoholG ?? 0
    case .kcal:         return kcal
    case .sodium:       return sodiumMg ?? 0
    case .cholesterol:  return cholesterolMg ?? 0
    case .potassium:    return potassiumMg ?? 0
    case .water:        return waterMl ?? 0
    }
  }
}
