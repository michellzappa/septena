import WidgetKit
import SwiftUI

// Training per-key styling (order / color / label / unit) lives in the shared
// `RingStyles.swift` so the complication and the in-app detail page agree.

// MARK: - Family router

struct TrainingComplicationView: View {
  let entry: TrainingEntry

  @Environment(\.widgetFamily) private var family

  /// Always render the three canonical rings (empty tracks before first sync).
  private var rings: [ComplicationRing] {
    let byKey = Dictionary(entry.data.rings.map { ($0.key, $0) },
                           uniquingKeysWith: { a, _ in a })
    return TrainingStyle.order.map { key in
      byKey[key] ?? ComplicationRing(key: key, value: 0, goal: nil)
    }
  }

  var body: some View {
    content
      .containerBackground(for: .widget) {
        family == .accessoryCircular ? AnyView(AccessoryWidgetBackground())
                                     : AnyView(Color.clear)
      }
      // Tap target: open the watch app's training detail page (handled by
      // `NextWatchView.onOpenURL`).
      .widgetURL(URL(string: "septena://training"))
  }

  @ViewBuilder
  private var content: some View {
    switch family {
    case .accessoryRectangular: RectangularTrainingView(rings: rings)
    default:                    CircularTrainingView(rings: rings)
    }
  }
}

// MARK: - Circular: three rings

private struct CircularTrainingView: View {
  let rings: [ComplicationRing]

  var body: some View {
    // Match the macro circular's stroke so the two round faces read as a pair.
    RingsView(rings: rings, color: TrainingStyle.color, lineWidth: 4.5, spacing: 1.5)
      .padding(2)
      .widgetAccentable(false)
  }
}

// MARK: - Rectangular: three rings + a row per metric

private struct RectangularTrainingView: View {
  let rings: [ComplicationRing]

  var body: some View {
    HStack(spacing: 9) {
      // Three rings, a touch fatter than the macro face's five.
      RingsView(rings: rings, color: TrainingStyle.color, lineWidth: 5, spacing: 1.5)
        .widgetAccentable(false)

      VStack(alignment: .leading, spacing: 3) {
        ForEach(rings, id: \.key) { metricRow($0) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 1)
  }

  /// "12/12 sets" — value, its target, and the unit, tinted to the ring color.
  private func metricRow(_ ring: ComplicationRing) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 2) {
      Text("\(Int(ring.value.rounded()))")
        .font(.system(size: 15, weight: .semibold))
      if let goal = ring.goal {
        Text("/\(Int(goal.rounded()))")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
      Text(TrainingStyle.unit(ring.key))
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .foregroundStyle(TrainingStyle.color(ring.key))
    .lineLimit(1)
    .minimumScaleFactor(0.7)
  }
}

// MARK: - Previews

#Preview("Training rectangular", as: .accessoryRectangular) {
  TrainingComplication()
} timeline: {
  TrainingEntry(date: .now, data: .sample)
}

#Preview("Training circular", as: .accessoryCircular) {
  TrainingComplication()
} timeline: {
  TrainingEntry(date: .now, data: .sample)
}
