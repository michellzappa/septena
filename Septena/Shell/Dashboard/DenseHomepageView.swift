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
struct DenseHomepageView<MenuContent: View>: View {
  let items: [HomepageDomainData]
  let onTap: (DomainTapAction) -> Void
  /// Long-press / right-click contextual actions per domain — the same
  /// quickadd menus the Tiles renderer attaches via `.contextMenu`.
  /// Caller hands back `EmptyView` for domains with no menu (sleep,
  /// air, body, activity) and the menu is silently suppressed.
  @ViewBuilder let menuContent: (HomepageDomain) -> MenuContent

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.domain) { idx, item in
        Button {
          onTap(item.tap)
        } label: {
          DenseDomainRow(data: item)
        }
        .buttonStyle(.plain)
        .contextMenu { menuContent(item.domain) }

        if idx < items.count - 1 {
          Divider().padding(.leading, 56)
        }
      }
    }
    .background(Theme.cardSurface)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

/// Single row in the Dense layout. Pure presentation — all data is in
/// the `HomepageDomainData` it receives.
private struct DenseDomainRow: View {
  let data: HomepageDomainData

  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(data.accent.opacity(0.18))
        .frame(width: 28, height: 28)
        .overlay {
          Image(systemName: data.domain.icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(data.accent)
        }

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
                      dropTrailingTodayPending: data.trailingTodayPending)
        .frame(width: 84, height: 28)

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }
}

/// Inline sparkline for a `HistorySeries`. Renders:
///   * `.bars`        → line + filled area under the curve
///   * `.stackedBars` → primary line + secondary line layered
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
  /// When true, treat the last element of a `.bars` series as a
  /// pending-today placeholder and drop it before plotting. The
  /// underlying value is kept in `HomepageDomainData.history` so the
  /// Heatmap renderer can still anchor its date map to today.
  var dropTrailingTodayPending: Bool = false

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

  /// Y-domain override for the `.centered` case so AreaMark's bottom
  /// anchor + chart axis both line up on the window's actual range,
  /// not the default 0…max which would crush amplitude. Returns nil
  /// for other history shapes — those keep SwiftUI Charts' default
  /// auto-scaling.
  private var explicitYDomain: ClosedRange<Double>? {
    guard case .centered(let values, let baseline) = history else { return nil }
    let absolute = values.compactMap { $0.map { $0 + baseline } }
    return centeredYBounds(absolute)
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
        let trimmed = dropTrailingTodayPending && !values.isEmpty
          ? Array(values.dropLast())
          : values
        let raw = aligned(trimmed.map(Double.init))
        let smoothed = smooth ? rollingMean(raw) : raw
        if let series = nonEmpty(smoothed) {
          ForEach(Array(series.enumerated()), id: \.offset) { idx, value in
            AreaMark(
              x: .value("Day", idx),
              y: .value("Value", value)
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

      case .stackedBars(let primary, let secondary):
        // Two overlapping translucent lines — bars at this size are
        // too busy. Training uses this case and opts into smoothing
        // (`HomepageDomainData.smoothSparkline`), which collapses the
        // every-other-day rest-day spikes into a sustained-load curve
        // (cf. Apple Watch Exercise ring).
        //
        // The primary series gets a filled area under the curve to
        // match `.bars` (visual parity across domains). Secondary
        // stays line-only so the two series remain distinguishable
        // — filling both would muddy the overlap.
        let pAligned = aligned(primary)
        let sAligned = aligned(secondary)
        let p = smooth ? rollingMean(pAligned) : pAligned
        let s = smooth ? rollingMean(sAligned) : sAligned
        ForEach(Array(p.enumerated()), id: \.offset) { idx, value in
          AreaMark(
            x: .value("Day", idx),
            y: .value("Primary", value),
            series: .value("Series", "primary")
          )
          .foregroundStyle(accent.opacity(0.22))
          .interpolationMethod(.monotone)
          LineMark(
            x: .value("Day", idx),
            y: .value("Primary", value),
            series: .value("Series", "primary")
          )
          .foregroundStyle(accent)
          .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
          .interpolationMethod(.monotone)
        }
        ForEach(Array(s.enumerated()), id: \.offset) { idx, value in
          LineMark(
            x: .value("Day", idx),
            y: .value("Secondary", value),
            series: .value("Series", "secondary")
          )
          .foregroundStyle(accent.opacity(0.45))
          .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
          .interpolationMethod(.monotone)
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
    // Invisible mark so the Chart still lays out at the requested
    // frame size; a sibling overlay paints the dash. Returning
    // EmptyChartContent isn't a thing, so use a single zero-opacity
    // RuleMark instead.
    RuleMark(y: .value("Empty", 0))
      .foregroundStyle(.clear)
  }
}
