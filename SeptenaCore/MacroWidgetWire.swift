import Foundation

struct MacroWidgetTileWire: Codable, Equatable, Sendable, Identifiable {
  var key: String
  var label: String
  var unit: String
  var colorHex: String
  var todayValue: Double
  var targetMin: Double
  var targetMax: Double
  /// Trailing seven days, oldest → newest (today last).
  var history: [Double]

  var id: String { key }
}

/// Nutrition macro tiles for the Macros home-screen widget.
struct MacroWidgetWire: Codable, Equatable, Sendable {
  var tiles: [MacroWidgetTileWire]
  var accentHex: String
  var updatedAt: Date

  static var sample: MacroWidgetWire {
    MacroWidgetWire(
      tiles: [
        .init(key: "protein", label: "Protein", unit: "g", colorHex: "#ef4444",
              todayValue: 95, targetMin: 100, targetMax: 140,
              history: [110, 128, 118, 105, 132, 121, 95]),
        .init(key: "fat", label: "Fat", unit: "g", colorHex: "#f59e0b",
              todayValue: 48, targetMin: 50, targetMax: 80,
              history: [62, 58, 64, 55, 61, 57, 48]),
        .init(key: "carbs", label: "Carbs", unit: "g", colorHex: "#3b82f6",
              todayValue: 120, targetMin: 150, targetMax: 250,
              history: [165, 188, 172, 160, 195, 181, 120]),
        .init(key: "fiber", label: "Fiber", unit: "g", colorHex: "#10b981",
              todayValue: 18, targetMin: 25, targetMax: 35,
              history: [22, 28, 24, 20, 26, 23, 18]),
        .init(key: "kcal", label: "Kcal", unit: "kcal", colorHex: "#eab308",
              todayValue: 1420, targetMin: 1800, targetMax: 2400,
              history: [1680, 2010, 1890, 1750, 2100, 1980, 1420]),
        .init(key: "fasting", label: "Fasting", unit: "h", colorHex: "#8b5cf6",
              todayValue: 14.5, targetMin: 14, targetMax: 16,
              history: [15.2, 14.8, 16.1, 13.5, 15.0, 14.2, 14.5]),
      ],
      accentHex: "#eab308",
      updatedAt: .now
    )
  }

  func hasSameContent(as other: MacroWidgetWire) -> Bool {
    tiles == other.tiles && accentHex == other.accentHex
  }
}
