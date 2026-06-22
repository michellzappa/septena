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
      // Tap target: open the watch app's nutrition detail page (handled by
      // `NextWatchView.onOpenURL`) — it shows the live fast too while one runs.
      .widgetURL(URL(string: "septena://nutrition"))
  }

  @ViewBuilder
  private var content: some View {
    // A live fast morphs the whole face — a single ring + elapsed timer — exactly
    // as the phone's Nutrition tile does. The fed-vs-fasting decision is recomputed
    // *here*, per timeline entry, from the entry's date — so the morph appears (and
    // the elapsed steps forward) over the fast and across midnight without a
    // provider reload or a phone republish.
    if let fast = entry.data.fasting, case let state = fast.liveState(now: entry.date),
       state.isFasting {
      switch family {
      case .accessoryRectangular: RectangularFastingView(fast: fast, elapsed: state.elapsed)
      default:                    CircularFastingView(fast: fast, elapsed: state.elapsed)
      }
    } else {
      switch family {
      case .accessoryRectangular: RectangularMacroView(rings: rings)
      default:                    CircularMacroView(rings: rings)
      }
    }
  }
}

// MARK: - Fasting morph (single ring filling toward the fasting target)

/// Split the elapsed interval into whole hours + minutes once, for both faces.
private func fastingHM(_ elapsed: TimeInterval) -> (h: Int, m: Int) {
  let totalMin = Int(elapsed) / 60
  return (totalMin / 60, totalMin % 60)
}

/// Whole hours for the hours-only circular face, rounded to the nearest hour
/// (12h31m reads as 13h, 12h20m as 12h). A single big number has no room for
/// the minutes, so rounding reads truer than truncating an half-hour down.
private func fastingRoundedHours(_ elapsed: TimeInterval) -> Int {
  Int((elapsed / 3600).rounded())
}

/// The single fasting ring, filling toward the target (laps past 100% like any
/// other ring). The wire's authored color wins; `FastingStyle` is the fallback.
private func fastingRing(_ fast: FastingComplication, elapsed: TimeInterval) -> ComplicationRing {
  ComplicationRing(key: "fasting", value: elapsed / 3600,
                   goal: max(fast.targetHours, 0.1), colorHex: fast.colorHex)
}

// MARK: - Circular: one ring with the elapsed hours centered

private struct CircularFastingView: View {
  let fast: FastingComplication
  let elapsed: TimeInterval

  var body: some View {
    ZStack {
      RingsView(rings: [fastingRing(fast, elapsed: elapsed)],
                color: { _ in FastingStyle.color(fast.colorHex) },
                lineWidth: 5, spacing: 0)
        .padding(1)
      VStack(spacing: -2) {
        Text("\(fastingRoundedHours(elapsed))")
          .font(.system(size: 18, weight: .semibold, design: .rounded))
        Text("h")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .widgetAccentable(false)
  }
}

// MARK: - Rectangular: ring + "Fasting" headline, elapsed, and since/target

private struct RectangularFastingView: View {
  let fast: FastingComplication
  let elapsed: TimeInterval

  var body: some View {
    let hm = fastingHM(elapsed)
    let tint = FastingStyle.color(fast.colorHex)
    HStack(spacing: 10) {
      ZStack {
        RingsView(rings: [fastingRing(fast, elapsed: elapsed)],
                  color: { _ in tint }, lineWidth: 5, spacing: 0)
        Image(systemName: "hourglass")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(tint)
      }
      .frame(width: 44, height: 44)
      .widgetAccentable(false)

      VStack(alignment: .leading, spacing: 1) {
        Text("Fasting")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(tint)
        Text("\(hm.h)h \(hm.m)m")
          .font(.system(size: 18, weight: .semibold, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        Text("since \(fast.sinceLabel) · \(Int(fast.targetHours.rounded()))h goal")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 1)
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

#Preview("Rectangular · fasting", as: .accessoryRectangular) {
  MacroComplication()
} timeline: {
  MacroEntry(date: .now, data: .fastingSample)
}

#Preview("Circular · fasting", as: .accessoryCircular) {
  MacroComplication()
} timeline: {
  MacroEntry(date: .now, data: .fastingSample)
}
