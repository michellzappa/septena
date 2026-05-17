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
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(.secondarySystemBackground))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(.quaternary, lineWidth: 0.5)
    )
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
      ProgressView(value: min(progress.current, progress.target),
                   total: max(progress.target, 0.0001))
        .tint(accent)
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
                emphasizedIndex: row.todayIndex ?? (row.values.count - 1))
        .frame(height: 56)
    }
  }
}

/// 7-bar histogram. The emphasized bar (defaults to today/newest) renders
/// at full accent; others fade. Heights normalize against the max value
/// (or 1 if all-zero, so the row doesn't divide by zero on empty weeks).
struct Histogram: View {
  let values: [Int]
  let accent: Color
  var emphasizedIndex: Int? = nil

  var body: some View {
    GeometryReader { geo in
      let maxV = max(values.max() ?? 0, 1)
      let count = max(values.count, 1)
      let gap: CGFloat = 6
      let barW = (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
      HStack(alignment: .bottom, spacing: gap) {
        ForEach(Array(values.enumerated()), id: \.offset) { idx, v in
          let h = max(CGFloat(v) / CGFloat(maxV) * geo.size.height, 4)
          let isEmphasized = idx == emphasizedIndex
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(accent.opacity(isEmphasized ? 1.0 : 0.55))
            .frame(width: barW, height: h)
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
