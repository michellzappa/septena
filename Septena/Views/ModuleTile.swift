import SwiftUI

// Sample tile for the Week dashboard. One per module (tasks, habits, chores,
// training, etc). Shows the module name, a one-line snapshot string, the
// module's accent color, and a 7-day histogram of activity. Tap navigates
// into that module's full destination. All data here is wired to literal
// inputs — the dashboard layer feeds real (or mocked) counts.

struct ModuleTile: View {
  let title: String
  let snapshot: String          // e.g. "5 today · 2 late"
  let accent: Color
  let history: [Int]            // last 7 days, oldest → newest
  var onTap: (() -> Void)? = nil

  var body: some View {
    Button(action: { onTap?() }) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
          Spacer()
          Text(snapshot)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Histogram(values: history, accent: accent)
          .frame(height: 36)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color(.secondarySystemBackground))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(.quaternary, lineWidth: 0.5)
      )
    }
    .buttonStyle(.plain)
  }
}

/// Minimal 7-bar histogram. Heights normalize against the max value (or 1
/// if all-zero, so empty weeks render a flat baseline rather than crashing
/// on division-by-zero). The newest bar gets full opacity; older bars fade
/// slightly to imply recency.
struct Histogram: View {
  let values: [Int]
  let accent: Color

  var body: some View {
    GeometryReader { geo in
      let maxV = max(values.max() ?? 0, 1)
      let count = max(values.count, 1)
      let gap: CGFloat = 4
      let barW = (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
      HStack(alignment: .bottom, spacing: gap) {
        ForEach(Array(values.enumerated()), id: \.offset) { idx, v in
          let h = max(CGFloat(v) / CGFloat(maxV) * geo.size.height, 2)
          let opacity = 0.45 + 0.55 * (Double(idx) / Double(max(count - 1, 1)))
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(accent.opacity(opacity))
            .frame(width: barW, height: h)
        }
      }
    }
  }
}

#Preview {
  VStack(spacing: 12) {
    ModuleTile(
      title: "Tasks",
      snapshot: "5 today · 2 late",
      accent: .blue,
      history: [3, 5, 2, 7, 4, 6, 5]
    )
    ModuleTile(
      title: "Habits",
      snapshot: "4 of 6 done",
      accent: .green,
      history: [6, 6, 5, 6, 4, 6, 4]
    )
    ModuleTile(
      title: "Training",
      snapshot: "Legs · 45 min",
      accent: .orange,
      history: [0, 1, 0, 1, 0, 0, 1]
    )
  }
  .padding()
}
