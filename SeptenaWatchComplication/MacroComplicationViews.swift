import WidgetKit
import SwiftUI

// Macro per-key styling (order / color / chip / label / unit) lives in the
// shared `RingStyles.swift` so the complication and the in-app detail page agree.

// MARK: - Family router

struct MacroComplicationView: View {
  let entry: MacroEntry

  @Environment(\.widgetFamily) private var family

  /// Always render the five canonical rings (falling back to empty tracks when
  /// the phone hasn't published yet) so the complication reads as "macros" even
  /// before the first sync.
  private var rings: [ComplicationRing] {
    let byKey = Dictionary(entry.data.rings.map { ($0.key, $0) },
                           uniquingKeysWith: { a, _ in a })
    return MacroStyle.order.map { key in
      byKey[key] ?? ComplicationRing(key: key, value: 0, goal: nil)
    }
  }

  var body: some View {
    content
      .containerBackground(for: .widget) {
        family == .accessoryCircular ? AnyView(AccessoryWidgetBackground())
                                     : AnyView(Color.clear)
      }
      // Tap target: open the watch app's macro detail page (handled by
      // `NextWatchView.onOpenURL`).
      .widgetURL(URL(string: "septena://nutrition"))
  }

  @ViewBuilder
  private var content: some View {
    switch family {
    case .accessoryRectangular: RectangularMacroView(rings: rings)
    default:                    CircularMacroView(rings: rings)
    }
  }
}

// MARK: - Circular: three rings (kcal · protein · carbs)

private struct CircularMacroView: View {
  let rings: [ComplicationRing]

  var body: some View {
    // The four drawn macros (kcal/protein/carbs/fat) — same set as the
    // rectangular face; fiber stays a legend-only number.
    RingsView(rings: Array(rings.prefix(4)), color: MacroStyle.color,
              lineWidth: 4.0, spacing: 1.5)
      .padding(2)
      .widgetAccentable(false)
  }
}

// MARK: - Rectangular: five rings + compact legend

private struct RectangularMacroView: View {
  let rings: [ComplicationRing]

  private var kcal: ComplicationRing? { rings.first { $0.key == "kcal" } }

  /// protein / carbs / fat / fiber in ring order — the full legend.
  private var macros: [ComplicationRing] { rings.filter { $0.key != "kcal" } }

  /// Drawn rings: drop fiber so four thicker rings read more cleanly than five
  /// thin ones. Fiber stays in the legend below, so no number is lost.
  private var drawnRings: [ComplicationRing] { rings.filter { $0.key != "fiber" } }

  /// The ring's authored Settings color, else the fixed macro hue.
  private func tint(_ ring: ComplicationRing) -> Color {
    Color(hexToken: ring.colorHex) ?? MacroStyle.color(ring.key)
  }

  var body: some View {
    HStack(spacing: 9) {
      RingsView(rings: drawnRings, color: MacroStyle.color, lineWidth: 3.4, spacing: 1.6)
        .widgetAccentable(false)

      VStack(alignment: .leading, spacing: 4) {
        // Calories headline, with its target.
        if let kcal {
          HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(Int(kcal.value.rounded()))")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(tint(kcal))
            if let goal = kcal.goal {
              Text("/\(Int(goal.rounded()))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            Text("cal")
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
          }
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        }
        // The four macros as value/target cells in a 2-column grid, so the
        // legend fills the width instead of leaving the right half empty.
        Grid(horizontalSpacing: 10, verticalSpacing: 3) {
          GridRow {
            ForEach(macros.prefix(2), id: \.key) { macroCell($0) }
          }
          GridRow {
            ForEach(macros.dropFirst(2), id: \.key) { macroCell($0) }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 1)
  }

  /// "90/150 P" — current value, its target, and the macro's one-letter tag,
  /// tinted to the ring color.
  private func macroCell(_ ring: ComplicationRing) -> some View {
    HStack(spacing: 1) {
      Text("\(Int(ring.value.rounded()))")
        .font(.system(size: 12, weight: .medium))
      if let goal = ring.goal {
        Text("/\(Int(goal.rounded()))")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
      }
      Text(MacroStyle.chip(ring.key))
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(.secondary)
    }
    .foregroundStyle(tint(ring))
    .lineLimit(1)
    .minimumScaleFactor(0.6)
    .gridColumnAlignment(.leading)
  }
}

// MARK: - Previews (Xcode canvas — no simulator / CloudKit needed)

#Preview("Rectangular · 5 rings", as: .accessoryRectangular) {
  MacroComplication()
} timeline: {
  MacroEntry(date: .now, data: .sample)
}

#Preview("Circular · 3 rings", as: .accessoryCircular) {
  MacroComplication()
} timeline: {
  MacroEntry(date: .now, data: .sample)
}
