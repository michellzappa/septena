import SwiftUI
import Charts

/// Dense homepage renderer — one row per domain, Apple-Health-Favorites
/// style. Phase 3 of the layout-modes refactor; first real consumer of
/// `HomepageDomainData`.
///
/// Layout per row, left-to-right:
///   * Accent-tinted icon square (28pt)
///   * Title + compact `headline` (e.g. "2/5 · 1 skipped")
///   * Inline sparkline from `HistorySeries` (~80×28pt)
///   * Disclosure chevron
///
/// The whole row is one tap target. Domains with no data render
/// "—" instead of a sparkline so the row stays the same height.
///
/// On wide iPad (> 900pt): 4-column card grid.
/// On portrait iPad (550–900pt): 3-column card grid.
/// On iPhone / compact: original full-width list.
/// Mirrors `HeatmapHomepageView`'s width-probe → column-count approach
/// so all wide-screen layout modes reflow into tiles consistently.
struct DenseHomepageView<MenuContent: View>: View {
  let items: [HomepageDomainData]
  let onTap: (DomainTapAction) -> Void
  /// Long-press / right-click contextual actions per domain — the same
  /// quickadd menus the Tiles renderer attaches via `.contextMenu`.
  /// Caller hands back `EmptyView` for domains with no menu (sleep,
  /// body, activity) and the menu is silently suppressed.
  @ViewBuilder let menuContent: (HomepageDomainData) -> MenuContent

  /// Measured at render time via a 0-height probe in the VStack below.
  /// Starts at 0; `hSize` guards against showing the grid on first
  /// render on iPhone.
  @State private var containerWidth: CGFloat = 0
  @Environment(\.horizontalSizeClass) private var hSize

  private var gridColumnCount: Int {
    // On compact (iPhone), always use the list layout regardless of width.
    guard hSize == .regular else { return 1 }
    // Default to 3 on first render (containerWidth == 0) so iPad shows a
    // grid immediately; refines to 4 once the width probe fires for landscape.
    if containerWidth > 900 { return 4 }
    return 3
  }

  private var gridColumns: [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: 12), count: gridColumnCount)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Zero-height width probe — see `HeatmapHomepageView` for the
      // rationale: a real (non-Group) view is needed to give the
      // background GeometryReader a concrete frame to measure.
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: 0)
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: DenseContainerWidthKey.self, value: geo.size.width)
          }
        )
        .onPreferenceChange(DenseContainerWidthKey.self) { containerWidth = $0 }

      if gridColumnCount > 1 {
        LazyVGrid(columns: gridColumns, spacing: 12) {
          ForEach(items, id: \.id) { item in
            Button { onTap(item.tap) } label: {
              DenseDomainCard(data: item)
            }
            .buttonStyle(.plain)
            .contextMenu { menuContent(item) }
          }
        }
      } else {
        VStack(spacing: 0) {
          ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
            Button {
              onTap(item.tap)
            } label: {
              DenseDomainRow(data: item)
            }
            .buttonStyle(.plain)
            .contextMenu { menuContent(item) }

            if idx < items.count - 1 {
              Divider().padding(.leading, 56)
            }
          }
        }
        .background(Theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
    }
  }
}

private struct DenseContainerWidthKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Single row in the Dense layout. Pure presentation — all data is in
/// the `HomepageDomainData` it receives.
private struct DenseDomainRow: View {
  let data: HomepageDomainData

  var body: some View {
    HStack(spacing: 12) {
      SectionGlyph(icon: data.icon,
                   accent: data.accent)

      VStack(alignment: .leading, spacing: 2) {
        Text(data.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
        Text(data.headline)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      DomainSparkline(history: data.history,
                      accent: data.accent,
                      smooth: data.smoothSparkline,
                      dropTrailingTodayPending: data.trailingTodayPending,
                      autoscale: data.autoscaleSparkline)
        .frame(width: 84, height: 28)

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .tileHover(cornerRadius: 10)
  }
}

/// Card variant used in the multi-column iPad grid. Icon + title +
/// headline stack above a full-width sparkline so the grid cells stay
/// readable — mirrors `HeatmapDomainCard`'s structure for the heatmap
/// grid, swapping the heatmap strip for the dense sparkline.
private struct DenseDomainCard: View {
  let data: HomepageDomainData

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        SectionGlyph(icon: data.icon,
                     accent: data.accent)
        Text(data.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      Text(data.headline)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      DomainSparkline(history: data.history,
                      accent: data.accent,
                      smooth: data.smoothSparkline,
                      dropTrailingTodayPending: data.trailingTodayPending,
                      autoscale: data.autoscaleSparkline)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.cardSurface)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .contentShape(Rectangle())
    .tileHover(cornerRadius: 14)
  }
}

/// Inline sparkline for a `HistorySeries`. Renders:
///   * `.bars`        → line + filled area under the curve
///   * `.dailyTrend`  → 7-day sum fill + a raw daily line tucked under it
///   * `.centered`    → bars above/below a centered baseline
///
/// Empty / all-zero data → a dash, so the row doesn't pretend to have
/// information it doesn't have.
private struct DomainSparkline: View {
  let history: HistorySeries?
  let accent: Color
  /// When true, apply a trailing-7d rolling mean to the values
  /// before plotting. Used for spiky cadences (training) where
  /// daily points hide the trend. See `HomepageDomainData.smoothSparkline`.
  var smooth: Bool = false
  /// When true, drop the trailing pending-today placeholder — and any
  /// further trailing zeros — from a `.bars` series before plotting.
  /// For a sensor series (sleep) a 0 is never a real value; it's "no
  /// data yet", so a run of trailing zeros (today plus recent nights
  /// Oura hasn't scored) must not anchor the line or it dives to the
  /// bottom of the autoscaled chart. The underlying values are kept in
  /// `HomepageDomainData.history` so the Heatmap renderer can still
  /// anchor its date map to today. See `trailingTrimmed`.
  var dropTrailingTodayPending: Bool = false
  /// When true, scale a `.bars` series to its window's actual min…max
  /// instead of the default 0…max. See
  /// `HomepageDomainData.autoscaleSparkline`.
  var autoscale: Bool = false

  /// Trailing-N-day rolling mean. The first `window-1` points
  /// average whatever's available so the line starts plotting
  /// immediately instead of cropping the early window.
  private func rollingMean(_ values: [Double], window: Int = 7) -> [Double] {
    guard window > 1, values.count > 1 else { return values }
    return values.indices.map { i in
      let lo = max(0, i - window + 1)
      let slice = values[lo...i]
      return slice.reduce(0, +) / Double(slice.count)
    }
  }

  /// Trailing-N-day rolling *sum* — the cumulative "how much in the last
  /// 7 days" envelope. A day is part of its own window, so the sum is
  /// always ≥ that day's value, which keeps the raw daily line underneath
  /// it. Early points sum whatever history is available.
  private func rollingSum(_ values: [Double], window: Int = 7) -> [Double] {
    guard window > 1, values.count > 1 else { return values }
    return values.indices.map { i in
      let lo = max(0, i - window + 1)
      return values[lo...i].reduce(0, +)
    }
  }

  /// Width of the horizontal axis in days. Every domain's series is
  /// padded (or truncated) to exactly this many points before plotting,
  /// so the rightmost x-position is **always "today"** and the same
  /// day in the past lands at the same x across rows. Without this,
  /// SwiftUI Charts auto-scales each row's x-axis to its own data
  /// length, so domains with shorter loader windows (Oura, HealthKit,
  /// etc.) would compress their data into the same chart width as a
  /// full 90-day series — visually misleading.
  ///
  /// Set to 30 (trailing month). The underlying loaders fetch 90 days
  /// so Heatmap mode has its full grid; the sparkline zooms in on the
  /// recent third. `aligned`/`alignedOptional` handle the truncation
  /// so widening or narrowing the window is a one-line change here.
  static let alignmentWindow: Int = 30

  /// Right-align `values` to a fixed `window` width. Shorter series
  /// get leading zeros (oldest days, no activity); longer series get
  /// truncated from the front (oldest days dropped, freshest 90 kept).
  /// Either way the rightmost element is the latest day.
  private func aligned(_ values: [Double], window: Int = alignmentWindow) -> [Double] {
    if values.count >= window { return Array(values.suffix(window)) }
    return Array(repeating: 0.0, count: window - values.count) + values
  }

  /// Same as `aligned`, but pads with `nil` for `.centered` series
  /// (body weight) so missing days stay missing instead of getting
  /// faked as "weight = 0".
  private func alignedOptional(_ values: [Double?], window: Int = alignmentWindow) -> [Double?] {
    if values.count >= window { return Array(values.suffix(window)) }
    return Array(repeating: nil, count: window - values.count) + values
  }

  /// When `dropTrailingTodayPending` is set, strip the trailing
  /// pending-today placeholder **and any further trailing zeros**. For
  /// a sensor series like sleep a 0 is never a real score — it means
  /// "no data recorded yet": today's still-pending night, plus any
  /// recent nights Oura hasn't scored (e.g. before the ring is
  /// connected or synced). Dropping only the last element left those
  /// nil→0 nights in place, and against the autoscaled floor (~70 for
  /// sleep score) the line dived from ~70 to the chart's bottom — the
  /// cliff at the right edge. Trimming the whole trailing zero-run ends
  /// the line at the last actually-measured night instead.
  ///
  /// Opt-in per domain — only sleep sets the flag today. Count domains
  /// (supplements, chores) don't, so their trailing "0 so far today"
  /// stays, where a 0 is a real and meaningful value.
  private func trailingTrimmed(_ values: [Int]) -> [Int] {
    guard dropTrailingTodayPending else { return values }
    var trimmed = values
    while let last = trimmed.last, last == 0 { trimmed.removeLast() }
    return trimmed
  }

  /// Y-domain override for the `.centered` case so AreaMark's bottom
  /// anchor + chart axis both line up on the window's actual range,
  /// not the default 0…max which would crush amplitude. Returns nil
  /// for other history shapes — those keep SwiftUI Charts' default
  /// auto-scaling.
  private var explicitYDomain: ClosedRange<Double>? {
    switch history {
    case .centered(let values, let baseline):
      let absolute = values.compactMap { $0.map { $0 + baseline } }
      return centeredYBounds(absolute)
    case .bars(let values) where autoscale:
      // Mirror the transform styledChart applies before plotting, then
      // frame the Y-axis on the real (non-zero) values. Leading padding
      // zeros from `aligned` and the dropped trailing no-data slots must
      // be excluded or `min` collapses the floor back to 0.
      let raw = aligned(trailingTrimmed(values).map(Double.init))
      let smoothed = smooth ? rollingMean(raw) : raw
      return centeredYBounds(smoothed.filter { $0 != 0 })
    default:
      return nil
    }
  }

  @ViewBuilder
  var body: some View {
    // Chart-family modifiers (`.chartXAxis`, `.chartYAxis`,
    // `.chartLegend`, `.chartPlotStyle`) MUST be attached directly
    // to the `Chart {}` instance — they don't propagate through
    // `_ConditionalContent`. Earlier I split this out and applied
    // them on the outer ViewBuilder branch, which silently dropped
    // axis-hiding and let the Chart reserve space for visible axes
    // inside the 84×28 sparkline frame, crushing the plot area to
    // ~0 height. Every domain except training (which uses a slightly
    // different render path) went blank.
    //
    // Fix: apply all chart styling inside `styledChart`, then wrap
    // only the optional `chartYScale` here at the outer level.
    if let domain = explicitYDomain {
      styledChart.chartYScale(domain: domain)
    } else {
      styledChart
    }
  }

  private var styledChart: some View {
    Chart {
      switch history {
      case .bars(let values):
        // Align to the fixed 90-day window first, then optionally
        // smooth. Order matters: smoothing before alignment would
        // average actual data with padded zeros at the boundary.
        let raw = aligned(trailingTrimmed(values).map(Double.init))
        let smoothed = smooth ? rollingMean(raw) : raw
        if let series = nonEmpty(smoothed) {
          // When autoscaled, the Y-domain starts well above 0, so anchor
          // the area's floor to the domain's lower bound (like `.centered`
          // does). Leaving the default y=0 anchor fills from far below the
          // visible plot and overflows the row's frame.
          let areaFloor = autoscale ? explicitYDomain?.lowerBound : nil
          ForEach(Array(series.enumerated()), id: \.offset) { idx, value in
            AreaMark(
              x: .value("Day", idx),
              yStart: .value("Floor", areaFloor ?? 0),
              yEnd: .value("Value", value)
            )
            .foregroundStyle(accent.opacity(0.22))
            .interpolationMethod(.monotone)
            LineMark(
              x: .value("Day", idx),
              y: .value("Value", value)
            )
            .foregroundStyle(accent)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .interpolationMethod(.monotone)
          }
        } else {
          emptyMark
        }

      case .dailyTrend(let daily):
        // One series, two layers — the unified chart:
        //   • the trailing-7d *sum* is the filled body (area + solid line)
        //     — "how much I've trained this week," the smooth cumulative;
        //   • the raw daily effort is a thinner line tucked underneath, so
        //     each session still shows — "what I did each day."
        // A day is part of its own 7-day window, so daily ≤ weekly always
        // → the per-day line stays inside the cumulative envelope on the
        // shared auto-scaled axis, no crushing. Sum on the full upstream
        // series *before* trimming to the display window so the leftmost
        // envelope point already carries up to `window-1` days of prior
        // history (training's loader provides ≥30 days; `aligned` pads
        // shorter input with leading zeros after).
        let weekly = aligned(rollingSum(daily))
        let perDay = aligned(daily)
        if nonEmpty(weekly) != nil {
          ForEach(Array(weekly.enumerated()), id: \.offset) { idx, value in
            AreaMark(
              x: .value("Day", idx),
              y: .value("Weekly", value),
              series: .value("Series", "weekly")
            )
            .foregroundStyle(accent.opacity(0.22))
            .interpolationMethod(.monotone)
            LineMark(
              x: .value("Day", idx),
              y: .value("Weekly", value),
              series: .value("Series", "weekly")
            )
            .foregroundStyle(accent)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .interpolationMethod(.monotone)
          }
          ForEach(Array(perDay.enumerated()), id: \.offset) { idx, value in
            LineMark(
              x: .value("Day", idx),
              y: .value("Daily", value),
              series: .value("Series", "daily")
            )
            .foregroundStyle(accent.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .interpolationMethod(.monotone)
          }
        } else {
          emptyMark
        }

      case .centered(let values, let baseline):
        // Reconstruct absolute values (delta + baseline) and render
        // the same area + line treatment as `.bars`, in the section
        // accent.
        //
        // Y-scale is locked to the window's actual min…max (computed
        // via `centeredYBounds`) and the area's bottom is anchored to
        // that min — without this, `AreaMark`'s default y-anchor of
        // 0 would fill the entire chart from 0 up to ~76kg, drowning
        // the actual ±1–2kg variation. Anchoring to the window's
        // min makes a small loss read as a small dip, a peak read as
        // a peak — visual amplitude matches data amplitude.
        //
        // `nil` days drop their mark; SwiftUI Charts interpolates
        // across the gap, which is the right semantic — a missed
        // weigh-in doesn't mean the user's weight reset to baseline.
        // Right-align with `nil` padding so a sparse weight series
        // (e.g. only 20 weigh-ins in 90 days) places those points
        // at the correct days-back-from-today, not bunched at the
        // left edge.
        let alignedValues = alignedOptional(values)
        let absolute: [(Int, Double)] = alignedValues.enumerated().compactMap { idx, v in
          guard let v else { return nil }
          return (idx, v + baseline)
        }
        if let bounds = centeredYBounds(absolute.map(\.1)) {
          ForEach(absolute, id: \.0) { idx, value in
            AreaMark(
              x: .value("Day", idx),
              yStart: .value("Floor", bounds.lowerBound),
              yEnd: .value("Weight", value)
            )
            .foregroundStyle(accent.opacity(0.22))
            .interpolationMethod(.monotone)
            LineMark(
              x: .value("Day", idx),
              y: .value("Weight", value)
            )
            .foregroundStyle(accent)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .interpolationMethod(.monotone)
          }
        } else {
          emptyMark
        }

      case .none:
        emptyMark
      }
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
    .chartPlotStyle { $0.background(Color.clear) }
    // No explicit `chartXScale`: the `aligned`/`alignedOptional`
    // padding already produces exactly `alignmentWindow` points per
    // series, so SwiftUI Charts' auto-scaling gives every row the
    // same `0…(window-1)` x-range. Forcing the scale on top of that
    // would mean an empty `.bars` row (all-zero, filtered out by
    // `nonEmpty`) still has a scale to lay out against — and Chart's
    // plot-area math goes negative inside the 84×28 frame, spamming
    // CoreGraphics with "Invalid frame dimension" warnings.
  }

  /// Returns `nil` if the series carries no signal (empty or all-zero),
  /// so callers can render a stub instead of a flat line that suggests
  /// "today we measured zero" when really we just have no data.
  private func nonEmpty(_ values: [Double]) -> [Double]? {
    guard !values.isEmpty else { return nil }
    return values.contains(where: { $0 != 0 }) ? values : nil
  }

  /// Y-domain for the `.centered` sparkline: window's actual
  /// min…max, with a tiny pad so the line + area don't sit flush
  /// against the chart edges. Returns nil for empty input (so the
  /// caller skips drawing).
  ///
  /// Pad is 5% of the range, with a 0.1 floor so a flat series
  /// (all measurements identical) still renders the line in the
  /// middle of the chart instead of flush-clipped.
  private func centeredYBounds(_ values: [Double]) -> ClosedRange<Double>? {
    guard let lo = values.min(), let hi = values.max() else { return nil }
    let span = hi - lo
    let pad = max(span * 0.05, 0.1)
    return (lo - pad)...(hi + pad)
  }

  private var emptyMark: some ChartContent {
    // A faint dashed baseline spanning the row's full width — the
    // window has days, just no measurements in it, which reads
    // differently from the row not existing at all. Dashed + low
    // opacity keeps it from being mistaken for a real flat reading.
    RuleMark(y: .value("Empty", 0))
      .foregroundStyle(accent.opacity(0.25))
      .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
  }
}
