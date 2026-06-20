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
  /// The metric's authored color (hex / hsl), mirrored from the user's Settings
  /// so the ring matches the section. Nil → the complication's fixed fallback hue.
  var colorHex: String? = nil
}

/// The live fast carried alongside the macro rings, mirrored from the phone's
/// `FastingWire`. When present, the macro complication morphs into a fasting
/// face (a single ring + elapsed timer) instead of drawing the macro rings —
/// the same morph the phone's Nutrition tile does. Mirrors `ComplicationRing`'s
/// app-group sharing: defined here so both the watch app and the complication
/// extension see it (the extension doesn't link SeptenaCore's `FastingWire`).
struct FastingComplication: Codable, Hashable {
  /// The absolute instant the fast began — the complication derives elapsed from
  /// the timeline entry's date, so the ring + readout step forward over the fast.
  var since: Date
  /// "HH:mm" of the meal the fast started from (the "since 19:30" label).
  var sinceLabel: String
  /// The lower fasting target in hours; the ring fills toward it.
  var targetHours: Double
  /// The fasting metric's authored color token, else the fixed fallback hue.
  var colorHex: String? = nil
}

/// Snapshot for the macro-ring complication, mirrored from the phone's
/// `NutritionRingsWire` into the shared app group so the complication reads it
/// O(1) (same pattern as `NextComplicationData`). The watch app writes it after
/// each snapshot fetch; the complication's timeline provider loads it.
struct MacroComplicationData: Codable {
  /// Outermost→innermost: kcal, protein, carbs, fat, fiber.
  var rings: [ComplicationRing]
  var updatedAt: Date
  /// The live fast, when one is running and the user tracks fasting. When set,
  /// the complication renders a fasting face instead of the macro rings.
  /// Optional so older saved blobs decode unchanged.
  var fasting: FastingComplication? = nil

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
      // colorHex mirrors the MacroCatalog defaults so the DEBUG sim previews the
      // real Settings palette, not the fixed fallback.
      .init(key: "kcal",    value: 1400, goal: 2200, colorHex: "#eab308"),
      .init(key: "protein", value: 90,   goal: 150,  colorHex: "#ef4444"),
      .init(key: "carbs",   value: 120,  goal: 220,  colorHex: "#3b82f6"),
      .init(key: "fat",     value: 40,   goal: 70,   colorHex: "#f59e0b"),
      .init(key: "fiber",   value: 14,   goal: 30,   colorHex: "#10b981"),
    ],
    updatedAt: .distantPast)

  /// A representative active fast — used by the fasting-face previews and the
  /// DEBUG simulator fallback. ~14h in, since "19:30", 16h target.
  static let fastingSample = MacroComplicationData(
    rings: [],
    updatedAt: .distantPast,
    fasting: FastingComplication(
      since: Date(timeIntervalSinceNow: -14.05 * 3600),
      sinceLabel: "19:30", targetHours: 16, colorHex: "#8b5cf6"))
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
