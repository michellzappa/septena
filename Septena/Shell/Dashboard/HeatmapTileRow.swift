import SwiftUI

/// Wide heatmap strip — shared by the homepage and the Section Tile widget.
struct HeatmapTileRow: View {
  let display: TileDisplayData
  var useHover: Bool = false
  var windowDays: Int = 90

  var body: some View {
    HStack(alignment: .top, spacing: rowSpacing) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          SectionGlyph(icon: display.icon, accent: display.accent)
          Text(display.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
        }
        Text(display.headline)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: metadataWidth, alignment: .leading)

      ConsistencyHeatmap(
        endDate: Date(),
        firstDataDate: firstDataDate,
        accent: display.accent,
        getDay: { iso in
          HeatmapDay(
            level: levelByIso[iso] ?? 0,
            label: "\(iso) · \(display.title)"
          )
        }
      )
    }
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .contentShape(Rectangle())
    .modifier(HeatmapTileRowChrome(useHover: useHover))
  }

  #if WIDGET_EXTENSION
  private let metadataWidth: CGFloat = 112
  private let rowSpacing: CGFloat = 10
  private let horizontalPadding: CGFloat = 7
  #else
  private let metadataWidth: CGFloat = 140
  private let rowSpacing: CGFloat = 14
  private let horizontalPadding: CGFloat = 14
  #endif
  private let verticalPadding: CGFloat = 12

  private var firstDataDate: Date? {
    Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: Date())
  }

  private var levelByIso: [String: Int] {
    HeatmapLevels.buildLevelMap(from: display.history, windowDays: windowDays)
  }
}

private struct HeatmapTileRowChrome: ViewModifier {
  let useHover: Bool
  func body(content: Content) -> some View {
    #if !WIDGET_EXTENSION
    if useHover {
      content.tileHover(cornerRadius: 10)
    } else {
      content
    }
    #else
    content
    #endif
  }
}
