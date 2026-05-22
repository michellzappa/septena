import SwiftUI

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
    // Match the insetGrouped look: white card on the gray canvas the
    // Week view supplies. `.secondarySystemGroupedBackground` is the
    // system token Reminders / Notes use for grouped-list rows.
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.secondaryGroupedBackground)
    )
    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
  }

  private var header: some View {
    Text(title)
      .font(.title3.weight(.semibold))
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
              .contentTransition(.numericText())
              .a11yAnimation(.snappy, value: stat.value)
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
      }
      // Custom capsule progress — SwiftUI's stock ProgressView on macOS
      // ignores `.tint` and falls back to the system control accent,
      // so every tile's bar reads as plain blue instead of the section
      // color. Hand-drawn capsules give consistent accent on both
      // platforms with no extra style work.
      GeometryReader { geo in
        let frac = max(0, min(1, progress.current / max(progress.target, 0.0001)))
        ZStack(alignment: .leading) {
          Capsule(style: .continuous).fill(accent.opacity(0.18))
          Capsule(style: .continuous)
            .fill(accent)
            .frame(width: geo.size.width * frac)
            // Tween the bar width when current/target change — quick-add
            // commits a new value, the bar slides instead of snapping.
            .a11yAnimation(.snappy, value: frac)
        }
      }
      .frame(height: 6)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(row.label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Histogram(values: row.values,
                accent: accent,
                emphasizedIndex: row.todayIndex ?? (row.values.count - 1),
                dayLabels: row.showDayLabels ? Self.weekdayLabels(count: row.values.count) : nil,
                ceiling: row.ceiling,
                secondaryValues: row.secondaryValues)
        .frame(height: row.showDayLabels ? 72 : 56)
    }
  }

  /// Last N weekday initials ending at today — e.g. for 7 values it's
  /// the last 7 days oldest→newest. Single-letter labels (M T W T F S S)
  /// keep the tile compact; we accept that the two T's and two S's collide.
  private static func weekdayLabels(count: Int) -> [String] {
    let cal = Calendar.current
    let fmt = DateFormatter()
    fmt.dateFormat = "EEEEE"     // narrow weekday: single letter
    return (0..<count).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: Date()).map(fmt.string(from:))
    }
  }
}

private struct CenteredHistoryView: View {
  let row: ModuleTile.CenteredHistoryRow
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(row.label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      CenteredBarChart(values: row.values, accent: accent,
                       dayLabels: weekdayLabels(count: row.values.count))
        .frame(height: 72)
    }
  }

  private func weekdayLabels(count: Int) -> [String] {
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "EEEEE"
    return (0..<count).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: Date()).map(fmt.string(from:))
    }
  }
}

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
      let barsH: CGFloat  = geo.size.height - labelH - 2
      let barW: CGFloat   = (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
      let midY: CGFloat   = barsH / 2
      let minH: CGFloat   = 3

      VStack(spacing: 2) {
        ZStack(alignment: .topLeading) {
          Rectangle()
            .fill(accent.opacity(0.2))
            .frame(width: geo.size.width, height: 1)
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
        .frame(width: geo.size.width, height: barsH)

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
      let barsH = max(geo.size.height - labelH, 4)
      let barW = (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
      VStack(spacing: 2) {
        HStack(alignment: .bottom, spacing: gap) {
          ForEach(Array(values.enumerated()), id: \.offset) { idx, v in
            if let secondaryValues, idx < secondaryValues.count {
              let primaryH = barsH * max(0, min(1, CGFloat(v) / 100))
              let secH = barsH * max(0, min(1, CGFloat(secondaryValues[idx]) / 100))
              VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                  .fill(accent.opacity(0.35))
                  .frame(height: secH)
                Rectangle()
                  .fill(accent)
                  .frame(height: primaryH)
              }
              .frame(width: barW, height: barsH)
              .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
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
            } else {
              let h = max(CGFloat(v) / CGFloat(maxV) * barsH, 4)
              RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent)
                .frame(width: barW, height: h)
            }
          }
        }
        .frame(height: barsH, alignment: .bottom)
        // Tween bar heights when the underlying series changes — a
        // quick-add bumps today's bar (the last one), which slides up
        // smoothly instead of jumping. Stacked modifiers because SwiftUI's
        // `.animation(_:value:)` watches one value each.
        .a11yAnimation(.snappy, value: values)
        .a11yAnimation(.snappy, value: secondaryValues)
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
