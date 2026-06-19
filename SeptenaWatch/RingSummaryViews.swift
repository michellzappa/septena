import SwiftUI

// In-app detail pages for the macro and training ring complications — the pages
// their `widgetURL` taps open, and the same pages reachable from the foot of the
// Next list. They render the phone-computed rings held on `WatchConnectivity`
// (the snapshot's `nutritionRings` / `trainingRings`), reusing the complication's
// shared `RingsView` + `MacroStyle` / `TrainingStyle` so the page and the
// complication can't drift. The watch carries no nutrition / training model.

/// A pushable summary page. Drives `NextWatchView`'s `navigationDestination`,
/// set both by the foot-of-feed links and by the complication deep links.
enum WatchPage: Hashable {
  case nutrition
  case training
}

// MARK: - Nutrition (today's macros)

struct NutritionDetailView: View {
  let conn: WatchConnectivity

  /// The canonical five in order, backfilling any the snapshot hasn't sent with
  /// empty tracks — so the page reads as "macros" even before the first sync
  /// (mirrors the complication's `rings`).
  private var rings: [ComplicationRing] {
    RingMetrics.canonical(order: MacroStyle.order, from: conn.nutritionRings)
  }

  var body: some View {
    RingSummaryPage(
      // Draw kcal/protein/carbs/fat (fiber stays legend-only) — same set the
      // circular complication draws.
      drawnRings: Array(rings.prefix(4)),
      legendRings: rings,
      color: MacroStyle.color,
      label: MacroStyle.label,
      unit: MacroStyle.unit,
      isEmpty: conn.nutritionRings.isEmpty,
      emptyHint: "No meals logged today")
    .navigationTitle("Macros")
    .navigationBarTitleDisplayMode(.inline)
    // Direct deep-link launches mount this page under the Next root; the root's
    // `.task` fetches, but pull once more here if we arrived before any data.
    .task { if conn.nutritionRings.isEmpty { conn.fetchNext() } }
  }
}

// MARK: - Training (this week)

struct TrainingDetailView: View {
  let conn: WatchConnectivity

  private var rings: [ComplicationRing] {
    RingMetrics.canonical(order: TrainingStyle.order, from: conn.trainingRings)
  }

  var body: some View {
    RingSummaryPage(
      drawnRings: rings,
      legendRings: rings,
      color: TrainingStyle.color,
      label: TrainingStyle.label,
      unit: TrainingStyle.unit,
      isEmpty: conn.trainingRings.isEmpty,
      emptyHint: "No training logged this week")
    .navigationTitle("This week")
    .navigationBarTitleDisplayMode(.inline)
    .task { if conn.trainingRings.isEmpty { conn.fetchNext() } }
  }
}

// MARK: - Shared page layout

/// The big ring stack on top, then one legend row per metric. Generic over the
/// per-key style closures so the macro and training pages share the layout.
private struct RingSummaryPage: View {
  let drawnRings: [ComplicationRing]
  let legendRings: [ComplicationRing]
  let color: (String) -> Color
  let label: (String) -> String
  let unit: (String) -> String
  let isEmpty: Bool
  let emptyHint: String

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        RingsView(rings: drawnRings, color: color, lineWidth: 7, spacing: 3)
          .frame(width: 108, height: 108)
          .padding(.top, 4)

        VStack(spacing: 7) {
          ForEach(legendRings, id: \.key) { ring in
            RingLegendRow(ring: ring,
                          label: label(ring.key),
                          unit: unit(ring.key),
                          color: Color(hexToken: ring.colorHex) ?? color(ring.key))
          }
        }

        if isEmpty {
          Text(emptyHint)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
        }
      }
      .padding(.horizontal, 6)
      .padding(.bottom, 8)
    }
  }
}

/// One metric's row: a color dot, its label, the value/goal readout, and a slim
/// progress bar filling toward the goal (a faint track when no goal is set).
private struct RingLegendRow: View {
  let ring: ComplicationRing
  let label: String
  let unit: String
  let color: Color

  private var fraction: Double {
    guard let goal = ring.goal, goal > 0 else { return 0 }
    return min(ring.value / goal, 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(label)
          .font(.caption)
          .lineLimit(1)
        Spacer(minLength: 4)
        HStack(spacing: 2) {
          Text("\(Int(ring.value.rounded()))")
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(color)
          if let goal = ring.goal {
            Text("/ \(Int(goal.rounded()))")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          if !unit.isEmpty {
            Text(unit)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      }

      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(color.opacity(0.22))
          Capsule().fill(color).frame(width: geo.size.width * fraction)
        }
      }
      .frame(height: 4)
    }
  }
}

// MARK: - Helpers

private enum RingMetrics {
  /// Return the canonical metrics in `order`, backfilling any the snapshot
  /// hasn't sent yet with empty (no-goal) tracks.
  static func canonical(order: [String], from rings: [ComplicationRing]) -> [ComplicationRing] {
    let byKey = Dictionary(rings.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    return order.map { byKey[$0] ?? ComplicationRing(key: $0, value: 0, goal: nil) }
  }
}
