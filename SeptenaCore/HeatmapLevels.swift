import Foundation

/// Pure helpers for mapping dashboard history series to heatmap 0…4 levels.
/// Shared by the homepage heatmap renderer and the Section Tile widget.
enum HeatmapLevels {
  private static let ymdFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    return fmt
  }()

  /// Pre-computed ISO-date → 0…4 level map for the grid's `getDay`
  /// closure. Shared by `HeatmapDomainRow` and `HeatmapDomainCard`.
  static func buildLevelMap(from history: HistoryWire?, windowDays: Int, today: Date) -> [String: Int] {
    var levels = levels(for: history)
    guard !levels.isEmpty else { return [:] }
    if levels.count > windowDays {
      levels = Array(levels.suffix(windowDays))
    }
    if levels.count < windowDays {
      levels = Array(repeating: 0, count: windowDays - levels.count) + levels
    }
    let cal = Calendar.current
    let fmt = ymdFormatter
    let todayStart = cal.startOfDay(for: today)
    var map: [String: Int] = [:]
    for (i, level) in levels.enumerated() {
      let daysBack = levels.count - 1 - i
      if let d = cal.date(byAdding: .day, value: -daysBack, to: todayStart) {
        map[fmt.string(from: d)] = level
      }
    }
    return map
  }

  static func levels(for history: HistoryWire?) -> [Int] {
    switch history {
    case .bars(let values):
      return normalizedLevels(values.map(Double.init))

    case .dailyTrend(let daily):
      return normalizedLevels(daily)

    case .centered(let values, _):
      let abs = values.map { $0.map(Swift.abs) ?? 0 }
      let missing = values.map { $0 == nil }
      return normalizedLevels(abs, isMissing: missing)

    case .none:
      return []
    }
  }

  static func normalizedLevels(
    _ values: [Double],
    isMissing: [Bool] = []
  ) -> [Int] {
    guard let maxV = values.max(), maxV > 0 else {
      return Array(repeating: 0, count: values.count)
    }
    return values.enumerated().map { idx, v in
      if idx < isMissing.count, isMissing[idx] { return 0 }
      guard v > 0 else { return 0 }
      let ratio = v / maxV
      if ratio >= 0.75 { return 4 }
      if ratio >= 0.5 { return 3 }
      if ratio >= 0.25 { return 2 }
      return 1
    }
  }
}
