import SwiftUI

/// Wide heatmap strip — shared by the homepage and the Section Tile widget.
struct HeatmapTileRow: View {
  let display: TileDisplayData
  var useHover: Bool = false
  var windowDays: Int = 90
  #if !WIDGET_EXTENSION
  @Environment(DayClock.self) private var dayClock
  #endif

  var body: some View {
    #if WIDGET_EXTENSION
    widgetLayout
    #else
    appLayout
    #endif
  }

  // MARK: - Widget — text column on the left, heatmap right-aligned

  #if WIDGET_EXTENSION
  private var widgetLayout: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          SectionGlyph(icon: display.icon, accent: display.accent, size: 22, glyphRatio: 0.48)
          Text(display.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
        }
        // Headline (e.g. "4 sessions · 210/300 min") sits under the title and
        // wraps to as many rows as it needs rather than truncating.
        Text(display.headline)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: 115, alignment: .leading)

      heatmap
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
      endDate: heatmapEndDate,
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

  private var heatmapEndDate: Date {
    #if WIDGET_EXTENSION
    Date()
    #else
    dayClock.now
    #endif
  }

  private var firstDataDate: Date? {
    Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: heatmapEndDate)
  }

  private var levelByIso: [String: Int] {
    #if WIDGET_EXTENSION
    HeatmapLevels.buildLevelMap(from: display.history, windowDays: windowDays, today: Date())
    #else
    HeatmapLevels.buildLevelMap(from: display.history, windowDays: windowDays,
                                today: dayClock.now)
    #endif
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
