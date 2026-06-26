import Foundation
import SwiftUI

// MARK: - Wire history (Codable mirror of `HistorySeries`)

enum HistoryWire: Codable, Equatable, Sendable {
  case bars([Int])
  case dailyTrend(daily: [Double])
  case centered(values: [Double?], baseline: Double)
}

struct TileStatWire: Codable, Equatable, Sendable {
  var label: String
  var value: String
  var unit: String?

  init(label: String, value: String, unit: String? = nil) {
    self.label = label
    self.value = value
    self.unit = unit
  }
}

/// Render-facing tile payload — hex accent, no `SectionTheme` dependency.
/// Shared by the widget extension and dashboard tile views.
struct TileDisplayData: Equatable, Sendable {
  var itemID: String
  var iconSymbol: String
  var title: String
  var accentHex: String
  var headline: String
  var headlineStats: [TileStatWire]
  var history: HistoryWire?
  var trailingTodayPending: Bool

  var accent: Color { AdaptiveColor.adaptive(accentHex) ?? .accentColor }
  var icon: String { iconSymbol }
}

struct TileWidgetWire: Codable, Equatable, Sendable {
  var itemID: String
  var title: String
  var iconSymbol: String
  var accentHex: String
  var headline: String
  var headlineStats: [TileStatWire]
  var history: HistoryWire?
  var trailingTodayPending: Bool
  var updatedAt: Date

  var display: TileDisplayData {
    TileDisplayData(
      itemID: itemID,
      iconSymbol: iconSymbol,
      title: title,
      accentHex: accentHex,
      headline: headline,
      headlineStats: headlineStats,
      history: history,
      trailingTodayPending: trailingTodayPending
    )
  }

  init(from data: TileDisplayData, updatedAt: Date = .now) {
    itemID = data.itemID
    title = data.title
    iconSymbol = data.iconSymbol
    accentHex = data.accentHex
    headline = data.headline
    headlineStats = data.headlineStats
    history = data.history
    trailingTodayPending = data.trailingTodayPending
    self.updatedAt = updatedAt
  }
}

struct TileSectionOption: Codable, Equatable, Sendable, Identifiable {
  var id: String { itemID }
  var itemID: String
  var title: String
  var iconSymbol: String
}

struct TileWidgetCatalog: Codable, Equatable, Sendable {
  var sections: [TileSectionOption]
  var tiles: [String: TileWidgetWire]

  static let empty = TileWidgetCatalog(sections: [], tiles: [:])

  /// Gallery / placeholder content for the widget picker.
  static var sampleHabits: TileWidgetWire {
    TileWidgetWire(
      from: TileDisplayData(
        itemID: HomepageDomain.habits.rawValue,
        iconSymbol: "figure.mind.and.body",
        title: "Habits",
        accentHex: "#22c55e",
        headline: "3/5",
        headlineStats: [
          .init(label: "Done", value: "3"),
          .init(label: "Skipped", value: "0"),
        ],
        history: .bars([2, 4, 3, 5, 4, 3, 5]),
        trailingTodayPending: false
      )
    )
  }
}
