import SwiftUI
import WidgetKit

struct MacroWidgetGridView: View {
  let tiles: [MacroWidgetTileWire]
  let accentHex: String

  @Environment(\.widgetFamily) private var family

  var body: some View {
    if family == .systemSmall {
      MacroWidgetSmallView(tiles: tiles, accentHex: accentHex)
    } else {
      MacroWidgetMediumView(tiles: tiles)
    }
  }
}

// MARK: - Small (1×1) — kcal + protein headline, one week chart

private struct MacroWidgetSmallView: View {
  let tiles: [MacroWidgetTileWire]
  let accentHex: String

  private var accent: Color {
    AdaptiveColor.adaptive(accentHex) ?? .accentColor
  }

  private var headlineTiles: [MacroWidgetTileWire] {
    let preferred = ["kcal", "protein"].compactMap { key in tiles.first { $0.key == key } }
    if preferred.count >= 2 { return preferred }
    return Array(tiles.prefix(2))
  }

  private var chartTile: MacroWidgetTileWire? {
    tiles.first { $0.key == "kcal" } ?? tiles.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        SectionGlyph(icon: "fork.knife", accent: accent, size: 24, glyphRatio: 0.48)
        Text("Macros")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }

      if !headlineTiles.isEmpty {
        HStack(alignment: .top, spacing: 10) {
          ForEach(Array(headlineTiles.enumerated()), id: \.element.id) { idx, tile in
            macroStat(tile)
            if idx == 0, headlineTiles.count > 1 {
              Spacer(minLength: 0)
            }
          }
        }
      }

      if let chartTile {
        let chartAccent = AdaptiveColor.adaptive(chartTile.colorHex) ?? accent
        TileWireHistogram(
          history: .dailyTrend(daily: chartTile.history),
          accent: chartAccent
        )
        .frame(height: 46)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func macroStat(_ tile: MacroWidgetTileWire) -> some View {
    let color = AdaptiveColor.adaptive(tile.colorHex) ?? accent
    return VStack(alignment: .leading, spacing: 1) {
      Text(tile.label.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(format(tile.todayValue, key: tile.key))
          .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
          .foregroundStyle(tile.todayValue > 0 ? color : .secondary)
          .lineLimit(1)
        Text(tile.unit)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func format(_ value: Double, key: String) -> String {
    if value <= 0 { return "—" }
    if key == "fasting" {
      return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
    return String(Int(value.rounded()))
  }
}

// MARK: - Medium (2×1) — visible macro pattern tiles

private struct MacroWidgetMediumView: View {
  let tiles: [MacroWidgetTileWire]

  private let layout = MacroWidgetLayout.sixGrid

  private var columns: [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: layout.gridSpacing), count: 3)
  }

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: layout.gridSpacing) {
      ForEach(tiles) { tile in
        MacroHistogramTile(tile: tile, layout: layout)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct MacroWidgetLayout {
  let gridSpacing: CGFloat
  let tileSpacing: CGFloat
  let labelFont: CGFloat
  let valueFont: CGFloat
  let unitFont: CGFloat
  let chartHeight: CGFloat

  static let sixGrid = MacroWidgetLayout(
    gridSpacing: 5,
    tileSpacing: 2,
    labelFont: 7,
    valueFont: 11,
    unitFont: 6.5,
    chartHeight: 26
  )
}

private struct MacroHistogramTile: View {
  let tile: MacroWidgetTileWire
  let layout: MacroWidgetLayout

  private var accent: Color {
    AdaptiveColor.adaptive(tile.colorHex) ?? .accentColor
  }

  var body: some View {
    VStack(alignment: .leading, spacing: layout.tileSpacing) {
      VStack(alignment: .leading, spacing: 0) {
        Text(tile.label.uppercased())
          .font(.system(size: layout.labelFont, weight: .semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
        HStack(alignment: .firstTextBaseline, spacing: 1) {
          Text(format(tile.todayValue))
            .font(.system(size: layout.valueFont, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(tile.todayValue > 0 ? accent : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
          Text(tile.unit)
            .font(.system(size: layout.unitFont))
            .foregroundStyle(.secondary)
        }
      }
      MacroMiniChart(
        values: tile.history,
        targetMin: tile.targetMin,
        targetMax: tile.targetMax,
        color: accent,
        chartHeight: layout.chartHeight
      )
    }
  }

  private func format(_ value: Double) -> String {
    if value <= 0 { return "—" }
    if tile.key == "fasting" {
      return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
    return String(Int(value.rounded()))
  }
}

private struct MacroMiniChart: View {
  let values: [Double]
  let targetMin: Double
  let targetMax: Double
  let color: Color
  let chartHeight: CGFloat

  private let gap: CGFloat = 2

  var body: some View {
    let yMax = chartMax
    GeometryReader { geo in
      let count = max(values.count, 1)
      let barW = max(2, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
      let h = geo.size.height
      ZStack(alignment: .bottomLeading) {
        if targetMax > targetMin {
          let bandTop = h * (1 - CGFloat(min(targetMax, yMax) / yMax))
          let bandBottom = h * (1 - CGFloat(max(targetMin, 0) / yMax))
          Rectangle()
            .fill(color.opacity(0.12))
            .frame(height: max(0, bandBottom - bandTop))
            .offset(y: bandTop)
        }
        if targetMin > 0, targetMin < yMax {
          targetLine(at: targetMin, yMax: yMax, width: geo.size.width, height: h)
        }
        if targetMax > 0, targetMax <= yMax {
          targetLine(at: targetMax, yMax: yMax, width: geo.size.width, height: h)
        }
        HStack(alignment: .bottom, spacing: gap) {
          ForEach(Array(values.enumerated()), id: \.offset) { idx, value in
            let isToday = idx == values.count - 1
            let frac = value > 0 ? CGFloat(value / yMax) : 0
            let barH = max(frac > 0 ? max(2, h * frac) : 0, isToday && value <= 0 ? 2 : 0)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
              .fill(barColor(value: value, isToday: isToday))
              .frame(width: barW, height: barH)
          }
        }
      }
    }
    .frame(height: chartHeight)
  }

  private func targetLine(at value: Double, yMax: Double, width: CGFloat, height: CGFloat) -> some View {
    let y = height * (1 - CGFloat(value / yMax))
    return Path { p in
      p.move(to: CGPoint(x: 0, y: y))
      p.addLine(to: CGPoint(x: width, y: y))
    }
    .stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
  }

  private var chartMax: Double {
    let dataMax = values.max() ?? 0
    return max(ceil(max(targetMax * 1.2, max(dataMax * 1.1, targetMax, 1))), 1)
  }

  private func barColor(value: Double, isToday: Bool) -> Color {
    if value <= 0 {
      return isToday ? color.opacity(0.16) : Color.secondary.opacity(0.18)
    }
    return color.opacity(value < targetMin ? 0.55 : 1)
  }
}
