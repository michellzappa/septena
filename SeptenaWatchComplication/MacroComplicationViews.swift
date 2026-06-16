import WidgetKit
import SwiftUI

// MARK: - Macro styling (key → label / unit / color)

/// Per-macro presentation, derived from the wire `key` so the snapshot stays
/// tiny. Order and colors mirror the Apple Activity rings' "one ring per goal"
/// idea: distinct, high-contrast hues that survive the accessory tint.
enum MacroStyle {
  /// Canonical outermost→innermost order. The complication renders rings in this
  /// order and slices the first three for the small circular family.
  static let order = ["kcal", "protein", "carbs", "fat", "fiber"]

  static func color(_ key: String) -> Color {
    switch key {
    case "kcal":    return .red
    case "protein": return .green
    case "carbs":   return .blue
    case "fat":     return .yellow
    case "fiber":   return .purple
    default:        return .gray
    }
  }

  /// One-letter chip label for the cramped rectangular legend.
  static func chip(_ key: String) -> String {
    switch key {
    case "protein": return "P"
    case "carbs":   return "C"
    case "fat":     return "F"
    case "fiber":   return "Fi"
    default:        return key.prefix(1).uppercased()
    }
  }
}

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
    // Five rings don't read at ~50pt — show the three headline macros, the rest
    // live on the rectangular family.
    RingsView(rings: Array(rings.prefix(3)), color: MacroStyle.color,
              lineWidth: 5, spacing: 1.5)
      .padding(2)
      .widgetAccentable(false)
  }
}

// MARK: - Rectangular: five rings + compact legend

private struct RectangularMacroView: View {
  let rings: [ComplicationRing]

  private var kcal: ComplicationRing? { rings.first { $0.key == "kcal" } }

  /// protein / carbs / fat / fiber in ring order.
  private var macros: [ComplicationRing] { rings.filter { $0.key != "kcal" } }

  var body: some View {
    HStack(spacing: 9) {
      RingsView(rings: rings, color: MacroStyle.color, lineWidth: 3.5, spacing: 1.5)
        .widgetAccentable(false)

      VStack(alignment: .leading, spacing: 4) {
        // Calories headline, with its target.
        if let kcal {
          HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(Int(kcal.value.rounded()))")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(MacroStyle.color("kcal"))
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
    .foregroundStyle(MacroStyle.color(ring.key))
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
