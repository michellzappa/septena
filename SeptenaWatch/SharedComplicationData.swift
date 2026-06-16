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

/// One ring's running total vs target — the complication maps `key` to a
/// label / unit / color and fills the ring to `value / goal`. Shared by every
/// rings-style complication (macros, training, …).
struct ComplicationRing: Codable, Hashable {
  var key: String
  var value: Double
  var goal: Double?
}

/// Snapshot for the macro-ring complication, mirrored from the phone's
/// `NutritionRingsWire` into the shared app group so the complication reads it
/// O(1) (same pattern as `NextComplicationData`). The watch app writes it after
/// each snapshot fetch; the complication's timeline provider loads it.
struct MacroComplicationData: Codable {
  /// Outermost→innermost: kcal, protein, carbs, fat, fiber.
  var rings: [ComplicationRing]
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

  /// A representative day — used by the complication previews and, in DEBUG, as
  /// the simulator fallback when no real snapshot has been published yet (a
  /// fresh sim has no CloudKit data, so a placed complication would otherwise
  /// show only empty tracks).
  static let sample = MacroComplicationData(
    rings: [
      .init(key: "kcal",    value: 1400, goal: 2200),
      .init(key: "protein", value: 90,   goal: 150),
      .init(key: "carbs",   value: 120,  goal: 220),
      .init(key: "fat",     value: 40,   goal: 70),
      .init(key: "fiber",   value: 14,   goal: 30),
    ],
    updatedAt: .distantPast)
}

/// Snapshot for the training-ring complication — this week's (trailing-7-day)
/// strength, cardio, and session totals vs their targets. Same app-group
/// mirroring pattern as `MacroComplicationData`.
struct TrainingComplicationData: Codable {
  /// Outer→inner: strength (hard sets), cardio (minutes), sessions.
  var rings: [ComplicationRing]
  var updatedAt: Date

  static let userDefaultsKey = "septena.complication.training"
  static let appGroupSuite   = "group.com.septena.cloud"

  static func load() -> TrainingComplicationData {
    guard
      let defaults = UserDefaults(suiteName: appGroupSuite),
      let data     = defaults.data(forKey: userDefaultsKey),
      let decoded  = try? JSONDecoder().decode(TrainingComplicationData.self, from: data)
    else {
      return TrainingComplicationData(rings: [], updatedAt: .distantPast)
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

  static let sample = TrainingComplicationData(
    rings: [
      .init(key: "strength", value: 12, goal: 12),
      .init(key: "cardio",   value: 85, goal: 150),
      .init(key: "sessions", value: 3,  goal: 4),
    ],
    updatedAt: .distantPast)
}
