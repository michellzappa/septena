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

  /// Short legend label.
  static func label(_ key: String) -> String {
    switch key {
    case "kcal":    return "Cal"
    case "protein": return "Protein"
    case "carbs":   return "Carbs"
    case "fat":     return "Fat"
    case "fiber":   return "Fiber"
    default:        return key.capitalized
    }
  }

  /// One-letter chip label for the cramped rectangular legend.
  static func chip(_ key: String) -> String {
    switch key {
    case "kcal":    return ""      // shown as the headline number, not a chip
    case "protein": return "P"
    case "carbs":   return "C"
    case "fat":     return "F"
    case "fiber":   return "Fi"
    default:        return key.prefix(1).uppercased()
    }
  }
}

// MARK: - Concentric rings

/// Apple-Activity-style concentric rings — one per macro, each filling toward its
/// target. A nil goal (no target set) draws just the faint track. Sized to the
/// smaller side of its frame so it stays circular in any family.
struct MacroRingsView: View {
  let rings: [MacroComplicationData.Ring]
  var lineWidth: CGFloat
  var spacing: CGFloat

  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      ZStack {
        ForEach(Array(rings.enumerated()), id: \.element.key) { idx, ring in
          let inset = CGFloat(idx) * (lineWidth + spacing)
          ringArc(ring)
            .frame(width: side - inset * 2, height: side - inset * 2)
        }
      }
      .frame(width: side, height: side)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func ringArc(_ ring: MacroComplicationData.Ring) -> some View {
    let color = MacroStyle.color(ring.key)
    let fraction: Double = {
      guard let goal = ring.goal, goal > 0 else { return 0 }
      return min(ring.value / goal, 1)
    }()
    ZStack {
      Circle()
        .stroke(color.opacity(0.22), lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
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
  private var rings: [MacroComplicationData.Ring] {
    let byKey = Dictionary(entry.data.rings.map { ($0.key, $0) },
                           uniquingKeysWith: { a, _ in a })
    return MacroStyle.order.map { key in
      byKey[key] ?? MacroComplicationData.Ring(key: key, value: 0, goal: nil)
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
  let rings: [MacroComplicationData.Ring]

  var body: some View {
    // Five rings don't read at ~50pt — show the three headline macros, the rest
    // live on the rectangular family.
    MacroRingsView(rings: Array(rings.prefix(3)), lineWidth: 5, spacing: 1.5)
      .padding(2)
      .widgetAccentable(false)
  }
}

// MARK: - Rectangular: five rings + compact legend

private struct RectangularMacroView: View {
  let rings: [MacroComplicationData.Ring]

  private var kcal: MacroComplicationData.Ring? {
    rings.first { $0.key == "kcal" }
  }

  var body: some View {
    HStack(spacing: 8) {
      MacroRingsView(rings: rings, lineWidth: 3.5, spacing: 1.5)
        .widgetAccentable(false)

      VStack(alignment: .leading, spacing: 2) {
        // Calories headline.
        if let kcal {
          HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(Int(kcal.value.rounded()))")
              .font(.headline.weight(.semibold))
              .foregroundStyle(MacroStyle.color("kcal"))
            if let goal = kcal.goal {
              Text("/\(Int(goal.rounded()))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Text("cal")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        // Protein / carbs / fat / fiber as tinted chips on (up to) two rows.
        let macros = rings.filter { $0.key != "kcal" }
        HStack(spacing: 6) {
          ForEach(macros, id: \.key) { ring in
            HStack(spacing: 1) {
              Text("\(Int(ring.value.rounded()))")
                .font(.caption2.weight(.medium))
              Text(MacroStyle.chip(ring.key))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .foregroundStyle(MacroStyle.color(ring.key))
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 1)
  }
}
