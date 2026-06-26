import SwiftUI

#if !WIDGET_EXTENSION
// Rich tile for the Week dashboard. One per module. Composed of optional
// chunks: a header row (title + circular trailing action), a stats grid
// (2-3 big-number cells with caption labels), a progress bar, and a
// 7-day histogram. Anything omitted just doesn't render. Mirrors the
// webapp's card layout but uses stock iOS materials / fonts.

struct ModuleTile: View {
  let title: String
  let accent: Color
  var stats: [Stat] = []
  var progress: ProgressBar? = nil
  var history: HistoryRow? = nil
  var centeredHistory: CenteredHistoryRow? = nil

  struct Stat: Hashable {
    let label: String          // "SESSIONS"
    let value: String          // "5/7" or "115"
    var unit: String? = nil    // "m"
  }

  struct ProgressBar: Hashable {
    let label: String          // "Z2 CARDIO"
    let current: Double
    let target: Double
    var unit: String = ""      // "m" or "g"
  }

  struct HistoryRow: Hashable {
    let label: String          // "7-DAY EFFORT"
    let values: [Int]          // last 7 days, oldest → newest
    var todayIndex: Int? = nil // bar to emphasize (defaults to last)
    var showDayLabels: Bool = true   // Mon/Tue/Wed/… under each bar
    /// If set, each bar renders at a constant total height representing
    /// this ceiling, with the `value` portion in full accent and the
    /// remaining `(ceiling - value)` portion in a lighter accent tone.
    /// Useful when bars represent a score against a fixed target (e.g.
    /// sleep score / 100), where seeing the gap to 100 is the point.
    var ceiling: Int? = nil
    /// When set, each bar becomes a two-tone stack: `values[i]` in full
    /// accent on the bottom, `secondaryValues[i]` in a lighter shade on
    /// top. Both arrays are pre-normalized into a 0…100 total range
    /// (each series independently scaled, mirroring the webapp's
    /// training overview where strength + cardio are charted together).
    var secondaryValues: [Int]? = nil
  }

  /// Bidirectional bar chart centered on y=0. Positive values go up,
  /// negative go down. nil entries render as a small neutral stub so gaps
  /// don't collapse the bar area on days with no measurement.
  struct CenteredHistoryRow: Hashable {
    let label: String
    let values: [Double?]
  }

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(accent)
        .frame(width: 3)
      VStack(alignment: .leading, spacing: 16) {
        header
        if !stats.isEmpty { statsGrid }
        if let progress { ProgressRow(progress: progress, accent: accent) }
        if let history { HistoryView(row: history, accent: accent) }
        if let centeredHistory { CenteredHistoryView(row: centeredHistory, accent: accent) }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    // iOS 26: float the tile on neutral liquid glass — the section color
    // lives only in the 3pt leading bar and the chart fills, not the card
    // background, so the histogram grid reads on a clean white-glass surface.
    // macOS keeps the opaque grouped card (glass over the mac paper canvas
    // reads muddy) — both paths handled in `glassCard`. The clip keeps the
    // 3pt leading accent bar inside the rounded corners.
    .glassCard()
    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
  }

  private var header: some View {
    Text(title)
      .font(.septenaTileTitle)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statsGrid: some View {
    HStack(alignment: .top, spacing: 24) {
      ForEach(stats, id: \.self) { stat in
        VStack(alignment: .leading, spacing: 4) {
          Text(stat.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
          HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(stat.value)
              .font(.system(.title, design: .rounded).weight(.semibold))
              .foregroundStyle(accent)
              // Quick-add updates the value; .numericText() tween the
              // digit transition (5 → 6, 14 → 15) instead of a hard cut.
              // Rolls on the gauge spring so the number's bounce matches the
              // bar's fill — they move as one when a log lands.
              .contentTransition(.numericText())
              .a11yAnimation(Theme.Motion.gauge, value: stat.value)
            if let unit = stat.unit {
              Text(unit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
        }
        if stat != stats.last { Spacer(minLength: 0) }
      }
    }
  }
}

private struct ProgressRow: View {
  let progress: ModuleTile.ProgressBar
  let accent: Color

  /// The settled fill fraction. Animated toward `targetFrac` on the gauge
  /// spring so the bar travels and overshoots into place rather than
  /// snapping. Seeded once (without animation) so opening the dashboard
  /// doesn't flash every bar filling from empty.
  @State private var fillFrac: CGFloat = 0
  /// Leading edge of the "just added" highlight — a brighter segment that
  /// sweeps across the span between the old and new fill on a grow. This is
  /// the glow re-expressed as motion *along* the bar, so it reads on a
  /// 6pt-tall gauge where an area glow can't.
  @State private var hlStart: CGFloat = 0
  @State private var hlEnd: CGFloat = 0
  @State private var hlOpacity: Double = 0
  /// First value is applied unanimated (initial load / cache hydrate / cell
  /// recycle); only later changes animate + highlight.
  @State private var seeded = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Same opt-out the commit flourishes honor (Settings ▸ Customize). Off →
  /// the bar still moves to the right value, just without the travel/glint.
  @AppStorage(SettingsKey.loggingAnimationsEnabled) private var animationsEnabled = true

  private var targetFrac: CGFloat {
    max(0, min(1, CGFloat(progress.current / max(progress.target, 0.0001))))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(progress.label)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
        Spacer()
        Text("\(format(progress.current))/\(format(progress.target))\(progress.unit)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
          .a11yAnimation(Theme.Motion.gauge, value: progress.current)
      }
      // Custom capsule progress — SwiftUI's stock ProgressView on macOS
      // ignores `.tint` and falls back to the system control accent,
      // so every tile's bar reads as plain blue instead of the section
      // color. Hand-drawn capsules give consistent accent on both
      // platforms with no extra style work.
      GeometryReader { geo in
        let safeW: CGFloat = (geo.size.width.isFinite && geo.size.width > 0) ? geo.size.width : 0
        ZStack(alignment: .leading) {
          Capsule(style: .continuous).fill(accent.opacity(0.18))
          Capsule(style: .continuous)
            .fill(accent)
            .frame(width: safeW * fillFrac)
          // The traveling glint over the newly-added span. White at low
          // opacity reads as a brightening of the accent beneath it.
          Capsule(style: .continuous)
            .fill(Color.white.opacity(hlOpacity))
            .frame(width: max(0, safeW * (hlEnd - hlStart)))
            .offset(x: safeW * hlStart)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
      }
      .frame(height: 6)
    }
    .onAppear {
      // Seed the settled fill without motion the first time the row mounts
      // (it may mount with a cached non-zero value), so nothing flash-fills.
      if !seeded { seeded = true; fillFrac = targetFrac }
    }
    .onChange(of: targetFrac) { old, new in
      guard seeded else { seeded = true; fillFrac = new; return }
      guard !reduceMotion, animationsEnabled else { fillFrac = new; return }
      withAnimation(Theme.Motion.gauge) { fillFrac = new }
      // Only a grow earns the glint (a log added something); a correction
      // downward just slides back quietly.
      guard new > old else { return }
      hlStart = old; hlEnd = old; hlOpacity = 0.55
      withAnimation(.easeOut(duration: 0.55)) { hlEnd = new }
      withAnimation(.easeOut(duration: 0.65)) { hlOpacity = 0 }
    }
  }

  private func format(_ v: Double) -> String {
    v.truncatingRemainder(dividingBy: 1) == 0
      ? String(Int(v))
      : String(format: "%.1f", v)
  }
}

private struct HistoryView: View {
  let row: ModuleTile.HistoryRow
  let accent: Color

  private static let narrowWeekdayFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "EEEEE"     // narrow weekday: single letter
    return fmt
  }()

  var body: some View {
    // Tile histograms always render 7 columns (last 7 days, oldest →
    // newest). When the caller passes fewer values — e.g. a loader
    // that returned a partial window — pad the leading days with 0 so
    // missing days read as empty slots instead of collapsing the chart
    // to a shorter row. Same treatment for `secondaryValues`.
    let values = Self.padTo7(row.values)
    let secondary = row.secondaryValues.map(Self.padTo7)
    VStack(alignment: .leading, spacing: 8) {
      Text(row.label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Histogram(values: values,
                accent: accent,
                emphasizedIndex: row.todayIndex ?? (values.count - 1),
                dayLabels: row.showDayLabels ? Self.weekdayLabels(count: values.count) : nil,
                ceiling: row.ceiling,
                secondaryValues: secondary)
        .frame(height: row.showDayLabels ? 72 : 56)
    }
  }

  private static func padTo7(_ values: [Int]) -> [Int] {
    if values.count >= 7 { return Array(values.suffix(7)) }
    return Array(repeating: 0, count: 7 - values.count) + values
  }

  /// Last N weekday initials ending at today — e.g. for 7 values it's
  /// the last 7 days oldest→newest. Single-letter labels (M T W T F S S)
  /// keep the tile compact; we accept that the two T's and two S's collide.
  private static func weekdayLabels(count: Int) -> [String] {
    let cal = Calendar.current
    let fmt = narrowWeekdayFormatter
    return (0..<count).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: Date()).map(fmt.string(from:))
    }
  }
}

private struct CenteredHistoryView: View {
  let row: ModuleTile.CenteredHistoryRow
  let accent: Color

  private static let narrowWeekdayFormatter: DateFormatter = {
    let fmt = DateFormatter(); fmt.dateFormat = "EEEEE"
    return fmt
  }()

  var body: some View {
    // Always render 7 columns; pad leading days with `nil` (missing) so
    // a short series doesn't compress the chart to fewer bars.
    let values: [Double?] = row.values.count >= 7
      ? Array(row.values.suffix(7))
      : Array(repeating: nil, count: 7 - row.values.count) + row.values
    VStack(alignment: .leading, spacing: 8) {
      Text(row.label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      CenteredBarChart(values: values, accent: accent,
                       dayLabels: weekdayLabels(count: values.count))
        .frame(height: 72)
    }
  }

  private func weekdayLabels(count: Int) -> [String] {
    let cal = Calendar.current
    let fmt = Self.narrowWeekdayFormatter
    return (0..<count).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: Date()).map(fmt.string(from:))
    }
  }
}

#endif

/// Bidirectional bar chart drawn manually with GeometryReader — no SwiftUI
/// Charts dependency. A horizontal reference line sits at the midpoint (avg).
/// Bars above the line = above-average weight (gain, full accent).
/// Bars below the line = below-average weight (loss, dimmer accent).
/// Missing days get a small neutral stub at the midline.
private struct CenteredBarChart: View {
  let values: [Double?]
  let accent: Color
  var dayLabels: [String]? = nil

  var body: some View {
    GeometryReader { geo in
      let present   = values.compactMap { $0 }
      let maxAbs    = max(0.01, present.map { abs($0) }.max() ?? 0.01)
      let count     = max(values.count, 1)
      let gap: CGFloat    = 4
      let labelH: CGFloat = dayLabels == nil ? 0 : 14
      // Sanitize the proposed size — geo.size can carry NaN during
      // transient layout passes, and any subsequent subtract / divide
      // propagates NaN into `.frame(width:height:)` calls which
      // CoreGraphics rejects with per-render-pass log spam.
      let safeW: CGFloat  = (geo.size.width.isFinite && geo.size.width > 0)  ? geo.size.width  : 0
      let safeH: CGFloat  = (geo.size.height.isFinite && geo.size.height > 0) ? geo.size.height : 0
      let barsH: CGFloat  = max(0, safeH - labelH - 2)
      let barW: CGFloat   = max(0, (safeW - gap * CGFloat(count - 1)) / CGFloat(count))
      let midY: CGFloat   = barsH / 2
      let minH: CGFloat   = 3

      VStack(spacing: 2) {
        ZStack(alignment: .topLeading) {
          Rectangle()
            .fill(accent.opacity(0.2))
            .frame(width: safeW, height: 1)
            .offset(y: midY)

          ForEach(Array(values.enumerated()), id: \.offset) { idx, v in
            let missing       = v == nil
            let dev           = v ?? 0.0
            let barH: CGFloat = max(CGFloat(abs(dev) / maxAbs) * midY, minH)
            let xPos: CGFloat = (barW + gap) * CGFloat(idx)
            let yPos: CGFloat = dev >= 0 ? midY - barH : midY
            let color: Color  = missing ? accent.opacity(0.15)
                              : dev > 0 ? accent
                              :           accent.opacity(0.45)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(color)
              .frame(width: barW, height: barH)
              .offset(x: xPos, y: yPos)
          }
        }
        .frame(width: safeW, height: barsH)

        if let dayLabels {
          HStack(spacing: gap) {
            ForEach(Array(dayLabels.enumerated()), id: \.offset) { idx, lbl in
              Text(lbl)
                .font(.caption2)
                .foregroundStyle(idx == values.count - 1
                                 ? Theme.inkPrimary : Theme.inkSecondary)
                .frame(width: barW)
            }
          }
          .frame(height: labelH)
        }
      }
    }
  }
}

/// N-bar histogram. The emphasized bar (defaults to today/newest) renders
/// at full accent; others fade. Heights normalize against the max value
/// (or 1 if all-zero, so the row doesn't divide by zero on empty weeks).
/// Optional day labels render below each bar (Mon/Tue/Wed/…).
///
/// When `ceiling` is set, bars run at a constant total height (the
/// ceiling) and split into two tones: the `value` portion in full accent,
/// `(ceiling - value)` on top in a lighter tone. Use for score-style
/// metrics where the gap-to-target matters as much as the value itself.
struct Histogram: View {
  let values: [Int]
  let accent: Color
  var emphasizedIndex: Int? = nil
  var dayLabels: [String]? = nil
  var ceiling: Int? = nil
  /// Companion series stacked on top of `values` in a lighter accent
  /// shade. Both series share a fixed 0…100 ceiling and the caller is
  /// responsible for pre-normalizing them so `values[i] + secondaryValues[i]`
  /// never exceeds 100. Mirrors the two-series stacked bar in the
  /// webapp's training overview (strength + cardio).
  var secondaryValues: [Int]? = nil

  var body: some View {
    GeometryReader { geo in
      let maxV = max(values.max() ?? 0, 1)
      let count = max(values.count, 1)
      let gap: CGFloat = 6
      let labelH: CGFloat = dayLabels == nil ? 0 : 14
      // Sanitize proposed size — NaN width/height from transient
      // layout passes propagates into `.frame(width:height:)` calls
      // that CoreGraphics rejects. Same defensive pattern as
      // `CenteredBarChart`, `DayTimelineView`, and `ConsistencyHeatmap`.
      let safeW: CGFloat = (geo.size.width.isFinite && geo.size.width > 0)  ? geo.size.width  : 0
      let safeH: CGFloat = (geo.size.height.isFinite && geo.size.height > 0) ? geo.size.height : 0
      let barsH = max(safeH - labelH, 4)
      let barW = max(0, (safeW - gap * CGFloat(count - 1)) / CGFloat(count))
      VStack(spacing: 2) {
        HStack(alignment: .bottom, spacing: gap) {
          ForEach(Array(values.enumerated()), id: \.offset) { idx, v in
            if let secondaryValues, idx < secondaryValues.count {
              let primaryH = barsH * max(0, min(1, CGFloat(v) / 100))
              let secH = barsH * max(0, min(1, CGFloat(secondaryValues[idx]) / 100))
              VStack(spacing: 0) {
                Spacer(minLength: 0)
                // Round the *visible* stack (cardio on top of strength), not
                // the full-height column. Clipping the column rounds corners at
                // the top of the frame — far above a short bar — which left the
                // bar itself flat-topped, unlike the single-bar branch below.
                VStack(spacing: 0) {
                  Rectangle()
                    .fill(accent.opacity(0.35))
                    .frame(height: secH)
                  Rectangle()
                    .fill(accent)
                    .frame(height: primaryH)
                }
                .frame(height: secH + primaryH)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
              }
              .frame(width: barW, height: barsH)
            } else if let ceiling, ceiling > 0 {
              let frac = max(0, min(1, CGFloat(v) / CGFloat(ceiling)))
              let fillH = barsH * frac
              let restH = barsH - fillH
              VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                  .fill(accent.opacity(0.18))
                  .frame(height: restH)
                Rectangle()
                  .fill(accent)
                  .frame(height: fillH)
              }
              .frame(width: barW, height: barsH)
              .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else if v > 0 {
              // Min-height of 4pt so a tiny-but-positive value still
              // reads as a stub bar (a "1" in a series whose max is
              // 100 would otherwise be sub-pixel). Zero values fall
              // through to the empty branch below — a missed day
              // reads as a gap, not a stub.
              let h = max(CGFloat(v) / CGFloat(maxV) * barsH, 4)
              RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent)
                .frame(width: barW, height: h)
            } else {
              // Empty slot: preserve column layout (so neighboring
              // bars stay at their day positions) but render nothing.
              Color.clear.frame(width: barW, height: barsH)
            }
          }
        }
        .frame(height: barsH, alignment: .bottom)
        // Tween bar heights when the underlying series changes — a
        // quick-add bumps today's bar (the last one), which slides up
        // smoothly instead of jumping. Stacked modifiers because SwiftUI's
        // `.animation(_:value:)` watches one value each.
        #if !WIDGET_EXTENSION
        .a11yAnimation(Theme.Motion.standard, value: values)
        .a11yAnimation(Theme.Motion.standard, value: secondaryValues)
        #endif
        if let dayLabels {
          HStack(spacing: gap) {
            ForEach(Array(dayLabels.enumerated()), id: \.offset) { idx, lbl in
              Text(lbl)
                .font(.caption2)
                .foregroundStyle(idx == emphasizedIndex
                                 ? Theme.inkPrimary : Theme.inkSecondary)
                .frame(width: barW)
            }
          }
          .frame(height: labelH)
        }
      }
    }
  }
}

// MARK: - Unified domain tile (Histogram layout mode)

/// The Histogram layout mode's cell, rendered from the shared
/// `HomepageDomainData` — the same view-model Sparkline / Heatmap / Rings
/// read, so the four modes can't drift on what "today's number" means.
///
/// It speaks the family's visual vocabulary (a `SectionGlyph` identity
/// square + a flat `Theme.cardSurface` card, matching `DenseDomainCard` /
/// `HeatmapDomainCard`) while keeping the mode's signature: up to two
/// headline numbers above a 7-day histogram. No progress bar — that
/// concept moved to Rings mode.
struct DomainTile: View {
  private let icon: String
  private let title: String
  private let accent: Color
  private let stats: [TileStatWire]
  #if !WIDGET_EXTENSION
  private let appHistory: HistorySeries?
  #endif
  private let wireHistory: HistoryWire?
  private let useHover: Bool

  #if !WIDGET_EXTENSION
  init(data: HomepageDomainData) {
    icon = data.icon
    title = data.title
    accent = data.accent
    stats = data.headlineStats.prefix(2).map(\.wire)
    appHistory = data.history
    wireHistory = nil
    useHover = true
  }
  #endif

  init(display: TileDisplayData) {
    icon = display.icon
    title = display.title
    accent = display.accent
    stats = Array(display.headlineStats.prefix(2))
    #if !WIDGET_EXTENSION
    appHistory = nil
    #endif
    wireHistory = display.history
    useHover = false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        SectionGlyph(icon: icon, accent: accent)
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }

      if !stats.isEmpty {
        HStack(alignment: .top, spacing: 16) {
          ForEach(Array(stats.enumerated()), id: \.offset) { idx, stat in
            VStack(alignment: .leading, spacing: 2) {
              Text(stat.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
              HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(stat.value)
                  .font(.system(.title2, design: .rounded).weight(.semibold))
                  .foregroundStyle(accent)
                  #if !WIDGET_EXTENSION
                  .contentTransition(.numericText())
                  .a11yAnimation(Theme.Motion.gauge, value: stat.value)
                  #endif
                  .lineLimit(1)
                  .minimumScaleFactor(0.6)
                if let unit = stat.unit {
                  Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
            if idx != stats.count - 1 { Spacer(minLength: 0) }
          }
        }
      }

      #if !WIDGET_EXTENSION
      if let history = appHistory {
        TileHistogram(history: history, accent: accent)
          .frame(height: 58)
      } else if let history = wireHistory {
        TileWireHistogram(history: history, accent: accent)
          .frame(height: 58)
      }
      #else
      if let history = wireHistory {
        TileWireHistogram(history: history, accent: accent)
          .frame(height: 58)
      }
      #endif
    }
    #if WIDGET_EXTENSION
    .padding(.horizontal, 6)
    .padding(.vertical, 12)
    #else
    .padding(12)
    #endif
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.cardSurface)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .contentShape(Rectangle())
    .modifier(DomainTileChrome(useHover: useHover))
  }
}

private struct DomainTileChrome: ViewModifier {
  let useHover: Bool
  func body(content: Content) -> some View {
    #if !WIDGET_EXTENSION
    if useHover {
      content.tileHover(cornerRadius: 14)
    } else {
      content
    }
    #else
    content
    #endif
  }
}

#if !WIDGET_EXTENSION
/// reusing the same primitives the tile always used (`Histogram` for
/// counts / two-series effort, `CenteredBarChart` for body-weight deltas).
/// 90-day series get sliced to the trailing 7 here — at ~half-screen tile
/// width, 90 bars compress into nothing; the long window is for the
/// Sparkline / Heatmap modes that read `history` directly.
private struct TileHistogram: View {
  let history: HistorySeries
  let accent: Color

  var body: some View {
    switch history {
    case .bars(let values):
      let v = Self.last7(values)
      Histogram(values: v,
                accent: accent,
                emphasizedIndex: v.count - 1,
                dayLabels: Self.weekdayLabels(count: v.count))

    case .dailyTrend(let daily):
      // Tiles mode is a 7-day histogram — collapse to the trailing week's
      // raw per-day effort (rounded to whole minutes), today emphasized.
      let v = Self.last7(daily.map { Int($0.rounded()) })
      Histogram(values: v,
                accent: accent,
                emphasizedIndex: v.count - 1,
                dayLabels: Self.weekdayLabels(count: v.count))

    case .centered(let values, _):
      let v = Self.last7Optional(values)
      CenteredBarChart(values: v,
                       accent: accent,
                       dayLabels: Self.weekdayLabels(count: v.count))
    }
  }

  /// Trailing 7, padded with leading zeros if the series is shorter (so a
  /// short window reads as empty days, not a compressed chart).
  private static func last7<T: ExpressibleByIntegerLiteral>(_ v: [T]) -> [T] {
    v.count >= 7 ? Array(v.suffix(7)) : Array(repeating: 0, count: 7 - v.count) + v
  }

  /// Same, but pads missing days with `nil` for `.centered` series so a
  /// gap stays a gap rather than a fake zero deviation.
  private static func last7Optional(_ v: [Double?]) -> [Double?] {
    v.count >= 7 ? Array(v.suffix(7)) : Array(repeating: nil, count: 7 - v.count) + v
  }

  private static let narrowWeekdayFormatter: DateFormatter = {
    let fmt = DateFormatter(); fmt.dateFormat = "EEEEE"   // single-letter weekday
    return fmt
  }()

  /// Last `count` weekday initials ending at today, oldest → newest.
  private static func weekdayLabels(count: Int) -> [String] {
    let cal = Calendar.current
    let fmt = narrowWeekdayFormatter
    return (0..<count).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: Date()).map(fmt.string(from:))
    }
  }
}
#endif

/// Widget / wire snapshot variant of `TileHistogram`.
struct TileWireHistogram: View {
  let history: HistoryWire
  let accent: Color

  var body: some View {
    switch history {
    case .bars(let values):
      let v = Self.last7(values)
      Histogram(values: v,
                accent: accent,
                emphasizedIndex: v.count - 1,
                dayLabels: Self.weekdayLabels(count: v.count))

    case .dailyTrend(let daily):
      let v = Self.last7(daily.map { Int($0.rounded()) })
      Histogram(values: v,
                accent: accent,
                emphasizedIndex: v.count - 1,
                dayLabels: Self.weekdayLabels(count: v.count))

    case .centered(let values, _):
      let v = Self.last7Optional(values)
      CenteredBarChart(values: v,
                       accent: accent,
                       dayLabels: Self.weekdayLabels(count: v.count))
    }
  }

  private static func last7<T: ExpressibleByIntegerLiteral>(_ v: [T]) -> [T] {
    v.count >= 7 ? Array(v.suffix(7)) : Array(repeating: 0, count: 7 - v.count) + v
  }

  private static func last7Optional(_ v: [Double?]) -> [Double?] {
    v.count >= 7 ? Array(v.suffix(7)) : Array(repeating: nil, count: 7 - v.count) + v
  }

  private static let narrowWeekdayFormatter: DateFormatter = {
    let fmt = DateFormatter(); fmt.dateFormat = "EEEEE"
    return fmt
  }()

  private static func weekdayLabels(count: Int) -> [String] {
    let cal = Calendar.current
    let fmt = narrowWeekdayFormatter
    return (0..<count).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: Date()).map(fmt.string(from:))
    }
  }
}

#if !WIDGET_EXTENSION
#Preview {
  ScrollView {
    VStack(spacing: 14) {
      ModuleTile(
        title: "Training",
        accent: .orange,
        stats: [.init(label: "Sessions", value: "5/7"),
                .init(label: "Z2 min",   value: "115", unit: "m")],
        progress: .init(label: "Z2 cardio", current: 115, target: 150, unit: "m"),
        history: .init(label: "7-day effort", values: [0, 1, 2, 1, 1, 0, 1], todayIndex: 1)
      )
      ModuleTile(
        title: "Nutrition",
        accent: .yellow,
        stats: [.init(label: "Protein", value: "50", unit: "g"),
                .init(label: "Kcal",    value: "855")],
        progress: .init(label: "Today's protein", current: 50, target: 150, unit: "g"),
        history: .init(label: "7-day protein", values: [120, 130, 140, 160, 80, 145, 60])
      )
    }
    .padding()
  }
}
#endif
