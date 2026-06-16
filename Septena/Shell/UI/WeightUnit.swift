import Foundation

/// The user's preferred unit for *displaying and entering* weights. Body and
/// training weights are always **stored in kilograms** (the CloudKit /
/// SwiftData fields are `*Kg`); this only governs presentation and the parsing
/// of typed input, so switching it never migrates or mutates stored data.
///
/// The choice is synced as part of `AppSettings.units` (weight + distance) and
/// mirrored into a device-local `UserDefaults` key (`WeightUnit.defaultsKey`)
/// so any view can read it via `@AppStorage` without the `SettingsStore`
/// environment — the same mirror pattern used for the welcome name and the
/// day-bucket cutoffs. `SettingsStore.setWeightUnit` / `reconcileUnits` keep
/// the synced payload and the local mirror in lockstep.
enum WeightUnit: String, CaseIterable, Identifiable {
  case kg
  case lb

  /// Kilograms per pound — the single conversion constant (matches the inline
  /// factor `ReportPayloadBuilder` already uses).
  private static let kgPerLb = 2.20462

  /// Device-local mirror key. Defined here (not only in the app's
  /// `SettingsKey`) so the helper is self-contained; `SettingsKey.weightUnit`
  /// aliases this same literal, the way `SettingsKey.localMcpEnabled` aliases
  /// `MCPDefaultsKey.enabled`.
  static let defaultsKey = "septena.units.weight"

  var id: String { rawValue }

  /// Resolve from a stored raw string ("kg"/"lb"), defaulting to kg for any
  /// missing or unrecognized value (so legacy installs read exactly as before).
  static func resolve(_ raw: String?) -> WeightUnit {
    WeightUnit(rawValue: raw ?? "") ?? .kg
  }

  /// The current preference, read straight from the device-local mirror. A
  /// non-reactive snapshot — use it in non-`View` contexts (static formatters,
  /// detail builders). Views that should update the instant the user flips the
  /// setting read `@AppStorage(WeightUnit.defaultsKey)` instead.
  static var current: WeightUnit {
    resolve(UserDefaults.standard.string(forKey: defaultsKey))
  }

  /// What a brand-new install should default to, inferred from the device
  /// locale: US (and other imperial locales) → pounds, everywhere else → kg.
  static var localeDefault: WeightUnit {
    Locale.current.measurementSystem == .metric ? .kg : .lb
  }

  /// Short unit suffix shown in the UI ("kg" | "lb").
  var suffix: String { rawValue }

  /// Multiplier that turns a kilogram value into this unit (1 for kg, ~2.2046
  /// for lb). Handy for scaling whole chart series in one shot.
  var displayFactor: Double { self == .lb ? Self.kgPerLb : 1 }

  /// Convert a stored kilogram value into this unit for display.
  func display(_ kg: Double) -> Double { kg * displayFactor }

  /// Convert a value typed in this unit back into kilograms for storage.
  func toKilograms(_ value: Double) -> Double { value / displayFactor }
}
