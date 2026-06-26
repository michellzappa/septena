import SwiftUI

/// Wide heatmap strip — shared by the homepage and the Section Tile widget.
struct HeatmapTileRow: View {
  let display: TileDisplayData
  var useHover: Bool = false
  var windowDays: Int = 90

  var body: some View {
    #if WIDGET_EXTENSION
    widgetLayout
    #else
    appLayout
    #endif
  }

  // MARK: - Widget — compact header, heatmap full width

  #if WIDGET_EXTENSION
  private var widgetLayout: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        SectionGlyph(icon: display.icon, accent: display.accent, size: 22, glyphRatio: 0.48)
        Text(display.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(display.headline)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(-1)
        Spacer(minLength: 0)
      }
      heatmap
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  #endif

  // MARK: - App — metadata column beside heatmap

  #if !WIDGET_EXTENSION
  private var appLayout: some View {
    HStack(alignment: .top, spacing: 14) {
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
      .frame(width: 140, alignment: .leading)

      heatmap
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .contentShape(Rectangle())
    .modifier(HeatmapTileRowChrome(useHover: useHover))
  }
  #endif

  private var heatmap: some View {
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

  private var firstDataDate: Date? {
    Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: Date())
  }

  private var levelByIso: [String: Int] {
    HeatmapLevels.buildLevelMap(from: display.history, windowDays: windowDays)
  }
}

#if !WIDGET_EXTENSION
private struct HeatmapTileRowChrome: ViewModifier {
  let useHover: Bool
  func body(content: Content) -> some View {
    if useHover {
      content.tileHover(cornerRadius: 10)
    } else {
      content
    }
  }
}
#endif
