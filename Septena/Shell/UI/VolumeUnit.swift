import Foundation

/// The user's preferred unit for *displaying and entering* fluid volume
/// (hydration / water). Volume is always stored in **milliliters** (`waterMl`,
/// `hydration.dailyTargetMl`); this is a display + input overlay only.
///
/// The third axis of the single metric/imperial switch, alongside `WeightUnit`
/// and `DistanceUnit`: `SettingsStore.setWeightUnit` derives and mirrors it
/// (kg → ml, lb → fl oz). Unlike weight/distance it is NOT a separate
/// `AppUnits` field — it's derived from the synced weight choice and kept only
/// in a device-local mirror, so old synced payloads need no migration.
enum VolumeUnit: String, CaseIterable {
  case ml   = "ml"
  case flOz = "floz"

  /// US fluid ounce.
  private static let mlPerFlOz = 29.5735

  static let defaultsKey = "septena.units.volume"

  static func resolve(_ raw: String?) -> VolumeUnit {
    VolumeUnit(rawValue: raw ?? "") ?? .ml
  }

  static var current: VolumeUnit {
    resolve(UserDefaults.standard.string(forKey: defaultsKey))
  }

  /// Locale default: metric → ml, imperial → fl oz (paired with the others).
  static var localeDefault: VolumeUnit {
    Locale.current.measurementSystem == .metric ? .ml : .flOz
  }

  /// Short suffix ("ml" | "fl oz").
  var suffix: String { self == .flOz ? "fl oz" : "ml" }

  /// Stored milliliters → a whole display value in this unit (the hydration
  /// chrome shows round numbers, so this rounds).
  func display(_ ml: Int) -> Int {
    self == .flOz ? Int((Double(ml) / Self.mlPerFlOz).rounded()) : ml
  }

  /// A value typed/stepped in this unit → milliliters for storage.
  func toMilliliters(_ value: Int) -> Int {
    self == .flOz ? Int((Double(value) * Self.mlPerFlOz).rounded()) : value
  }

  /// Fractional variants for the nutrition water field (stored as a Double ml).
  func displayDouble(_ ml: Double) -> Double {
    self == .flOz ? ml / Self.mlPerFlOz : ml
  }
  func toMillilitersDouble(_ value: Double) -> Double {
    self == .flOz ? value * Self.mlPerFlOz : value
  }

  /// One-tap quick-add amounts, expressed in this unit.
  var quickPresets: [Int] { self == .flOz ? [8, 12, 16] : [250, 330, 500] }

  /// Daily-target stepper bounds + step, in this unit (≈500–5000 ml).
  var targetRange: ClosedRange<Int> { self == .flOz ? 16...170 : 500...5000 }
  var targetStep: Int { self == .flOz ? 4 : 250 }

  /// Custom-amount stepper bounds + step, in this unit (≈50–2000 ml).
  var customRange: ClosedRange<Int> { self == .flOz ? 2...68 : 50...2000 }
  var customStep: Int { self == .flOz ? 2 : 50 }
}
