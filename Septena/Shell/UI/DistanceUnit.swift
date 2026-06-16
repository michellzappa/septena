import Foundation

/// The user's preferred unit for *displaying* cardio distance and speed.
/// Distance is always stored in **meters** (`distanceM`) and pace in m/min;
/// this is a display overlay only, so flipping it never mutates data.
///
/// Paired with `WeightUnit`: the single Settings ▸ General metric/imperial
/// switch writes both `AppUnits.weight` and `AppUnits.distance`, and
/// `SettingsStore` mirrors each into its own device-local `UserDefaults` key.
/// Distance INPUT stays in meters for both systems (an unambiguous base unit
/// the cardio pace-presets rely on); only readouts localize.
enum DistanceUnit: String, CaseIterable {
  case km
  case mi

  private static let mPerMi = 1609.344

  /// Device-local mirror key (aliased by `SettingsKey.distanceUnit`).
  static let defaultsKey = "septena.units.distance"

  static func resolve(_ raw: String?) -> DistanceUnit {
    raw == "mi" ? .mi : .km
  }

  /// Non-reactive snapshot from the device-local mirror (for static formatters
  /// and detail builders). Reactive views read `@AppStorage(DistanceUnit.defaultsKey)`.
  static var current: DistanceUnit {
    resolve(UserDefaults.standard.string(forKey: defaultsKey))
  }

  /// Locale default: metric → km, imperial → mi (paired with `WeightUnit.localeDefault`).
  static var localeDefault: DistanceUnit {
    Locale.current.measurementSystem == .metric ? .km : .mi
  }

  /// Distance suffix ("km" | "mi").
  var suffix: String { rawValue }

  /// Speed suffix ("km/h" | "mi/h").
  var speedSuffix: String { self == .mi ? "mi/h" : "km/h" }

  /// m/min → speed in this unit per hour.
  func speed(_ mPerMin: Double) -> Double {
    mPerMin * 60 / (self == .mi ? Self.mPerMi : 1000)
  }

  /// Input-field unit: metric enters raw meters (unchanged), imperial enters
  /// miles. Kept distinct from the display `suffix` (km) because cardio entry
  /// has always been in the small base unit.
  var inputSuffix: String { self == .mi ? "mi" : "m" }

  /// A value typed in the input unit → meters for storage.
  func metersFromInput(_ v: Double) -> Double {
    self == .mi ? v * Self.mPerMi : v
  }

  /// Stored meters → the value shown in the input field.
  func inputFromMeters(_ m: Double) -> Double {
    self == .mi ? m / Self.mPerMi : m
  }

  /// A human distance string from a stored meters value. Metric keeps the
  /// existing m→km threshold; imperial always reads in miles.
  func format(meters m: Double) -> String {
    switch self {
    case .km: return m >= 1000 ? "\((m / 1000).decimalString(1)) km" : "\(Int(m)) m"
    case .mi: return "\((m / Self.mPerMi).decimalString(2)) mi"
    }
  }
}
