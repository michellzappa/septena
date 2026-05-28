import SwiftUI

// GoalMetricProgressView — small bar + caption rendered on goal cards
// when the goal has a measurement attached. Used by both GoalTile (Goals
// tab) and SectionGoalRow (per-section strip).

struct GoalMetricProgressView: View {
  let progress: GoalMetricProgress
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(caption)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        if progress.hit {
          Image(systemName: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(accent)
        }
        Spacer()
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(accent.opacity(0.15))
          Capsule()
            .fill(accent)
            .frame(width: max(2, geo.size.width * progress.fraction))
        }
      }
      .frame(height: 6)
    }
  }

  private var caption: String {
    let comparator: String
    switch progress.comparator {
    case "lte": comparator = "≤"
    case "eq":  comparator = "="
    default:    comparator = "≥"
    }
    let base = "\(formatted(progress.current)) / \(comparator) \(formatted(progress.target)) \(progress.unitLabel)"
    // Surface the baseline so users see what reference point the bar
    // is measuring from. Only shown for baseline-aware progress to
    // avoid noise on count/sum goals.
    if let baseline = progress.baseline, baseline != progress.target,
       progress.comparator != "eq" {
      return base + " (from \(formatted(baseline)))"
    }
    return base
  }

  private func formatted(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
  }
}
