import Foundation

struct NextComplicationData: Codable {
  var bucket: String
  var remaining: Int
  var firstTitle: String?
  var updatedAt: Date

  static let userDefaultsKey = "septena.complication.next"
  static let appGroupSuite   = "group.com.septena.cloud"

  static func load() -> NextComplicationData {
    guard
      let defaults = UserDefaults(suiteName: appGroupSuite),
      let data     = defaults.data(forKey: userDefaultsKey),
      let decoded  = try? JSONDecoder().decode(NextComplicationData.self, from: data)
    else {
      return NextComplicationData(bucket: "", remaining: 0, firstTitle: nil, updatedAt: .distantPast)
    }
    return decoded
  }

  func save() {
    guard
      let defaults = UserDefaults(suiteName: Self.appGroupSuite),
      let data     = try? JSONEncoder().encode(self)
    else { return }
    defaults.set(data, forKey: Self.userDefaultsKey)
  }
}

/// Snapshot for the macro-ring complication, mirrored from the phone's
/// `NutritionRingsWire` into the shared app group so the complication reads it
/// O(1) (same pattern as `NextComplicationData`). The watch app writes it after
/// each snapshot fetch; the complication's timeline provider loads it.
struct MacroComplicationData: Codable {
  /// One macro's running total vs target — the complication maps `key` to a
  /// label / unit / color and fills the ring to `value / goal`.
  struct Ring: Codable, Hashable {
    var key: String
    var value: Double
    var goal: Double?
  }

  /// Outermost→innermost: kcal, protein, carbs, fat, fiber.
  var rings: [Ring]
  var updatedAt: Date

  static let userDefaultsKey = "septena.complication.macros"
  static let appGroupSuite   = "group.com.septena.cloud"

  static func load() -> MacroComplicationData {
    guard
      let defaults = UserDefaults(suiteName: appGroupSuite),
      let data     = defaults.data(forKey: userDefaultsKey),
      let decoded  = try? JSONDecoder().decode(MacroComplicationData.self, from: data)
    else {
      return MacroComplicationData(rings: [], updatedAt: .distantPast)
    }
    return decoded
  }

  func save() {
    guard
      let defaults = UserDefaults(suiteName: Self.appGroupSuite),
      let data     = try? JSONEncoder().encode(self)
    else { return }
    defaults.set(data, forKey: Self.userDefaultsKey)
  }
}
