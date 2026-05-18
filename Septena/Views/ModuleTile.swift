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
  var action: ActionButton? = nil

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
  }

  struct ActionButton {
    let systemImage: String    // "play.fill" / "checkmark"
    let onTap: () -> Void
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
    HStack {
      Text(title)
        .font(.title3.weight(.semibold))
      Spacer()
      if let action {
        Button(action: action.onTap) {
          Image(systemName: action.systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(accent))
        }
        .buttonStyle(.plain)
      }
    }
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
                ceiling: row.ceiling)
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
            if let ceiling, ceiling > 0 {
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
        history: .init(label: "7-day effort", values: [0, 1, 2, 1, 1, 0, 1], todayIndex: 1),
        action: .init(systemImage: "play.fill") {}
      )
      ModuleTile(
        title: "Nutrition",
        accent: .yellow,
        stats: [.init(label: "Protein", value: "50", unit: "g"),
                .init(label: "Kcal",    value: "855")],
        progress: .init(label: "Today's protein", current: 50, target: 150, unit: "g"),
        history: .init(label: "7-day protein", values: [120, 130, 140, 160, 80, 145, 60]),
        action: .init(systemImage: "checkmark") {}
      )
    }
    .padding()
  }
}
