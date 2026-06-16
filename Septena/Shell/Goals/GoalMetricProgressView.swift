import SwiftUI

// GoalMetricProgressView — small bar + caption rendered on goal cards
// when the goal has a measurement attached. Used by both GoalTile (Goals
// tab) and SectionGoalRow (per-section strip).

struct GoalMetricProgressView: View {
  let progress: GoalMetricProgress
  let accent: Color

  /// Reactive read of the weight-unit preference so the caption re-renders the
  /// instant the user flips kg↔lb. Only consulted for weight metrics.
  @AppStorage(WeightUnit.defaultsKey) private var weightUnitRaw = WeightUnit.kg.rawValue
  private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .kg }

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
      if let band = progress.band {
        bandTrack(band)
      } else {
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
  }

  /// Maintenance band: a tinted "good zone" segment with a marker for the
  /// current reading. Marker reads accent when in-band, amber when outside.
  private func bandTrack(_ band: (lower: Double, upper: Double, marker: Double)) -> some View {
    GeometryReader { geo in
      let w = geo.size.width
      let bandX = band.lower * w
      let bandW = max(2, (band.upper - band.lower) * w)
      let markerX = band.marker * w
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.secondary.opacity(0.15))
        Capsule()
          .fill(accent.opacity(0.3))
          .frame(width: bandW)
          .offset(x: bandX)
        Circle()
          .fill(progress.hit ? accent : Color.orange)
          .frame(width: 10, height: 10)
          .offset(x: min(max(0, markerX - 5), w - 10))
      }
    }
    .frame(height: 10)
  }

  /// Unit suffix shown to the user — the weight preference for kg-stored body
  /// metrics, the metric's own label otherwise.
  private var unitLabel: String {
    progress.isWeight ? weightUnit.suffix : progress.unitLabel
  }

  private var caption: String {
    if progress.isRange, let upper = progress.targetUpper {
      return "\(formatted(progress.current)) · \(formatted(progress.target))–\(formatted(upper)) \(unitLabel)"
    }
    let comparator: String
    switch progress.comparator {
    case "lte": comparator = "≤"
    case "eq":  comparator = "="
    default:    comparator = "≥"
    }
    let base = "\(formatted(progress.current)) / \(comparator) \(formatted(progress.target)) \(unitLabel)"
    // Surface the baseline so users see what reference point the bar
    // is measuring from. Only shown for baseline-aware progress to
    // avoid noise on count/sum goals.
    if let baseline = progress.baseline, baseline != progress.target,
       progress.comparator != "eq" {
      return base + " (from \(formatted(baseline)))"
    }
    return base
  }

  /// Format a stored value for display, converting kg → the user's weight unit
  /// first when this is a weight metric. Whole numbers print without decimals;
  /// converted (fractional) values round to one decimal.
  private func formatted(_ v: Double) -> String {
    let shown = progress.isWeight ? weightUnit.display(v) : v
    return shown == shown.rounded() ? String(Int(shown)) : String(format: "%.1f", shown)
  }
}
