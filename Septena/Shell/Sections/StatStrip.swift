import SwiftUI

// One-line stat row used at the top of section drawers — protein/fat/
// carbs for Nutrition, sessions/grams for Caffeine, sessions/Z2-min for
// Training, etc. Replaces ~10 hand-rolled `stat(value:label:tint:unit:)`
// helpers + summary HStacks that all rendered exactly the same shape.

/// One value tile inside a `StatStrip`. The optional `unit` reads as a
/// quieter caption next to the value baseline (e.g. "10.0 g"); the
/// `label` sits below the value as a secondary caption.
struct Stat: Identifiable, Hashable {
  let id: String
  let value: String
  let label: String
  let tint: Color
  let unit: String?

  init(id: String? = nil,
       value: String,
       label: String,
       tint: Color = .secondary,
       unit: String? = nil) {
    self.id = id ?? "\(label)#\(value)"
    self.value = value
    self.label = label
    self.tint = tint
    self.unit = unit
  }
}

/// Horizontal strip of stat tiles. Each tile renders the same shape used
/// across the destinations before this consolidation (system rounded
/// title2 numeral, optional subheadline unit, caption label below).
struct StatStrip: View {
  let stats: [Stat]
  /// Horizontal spacing between adjacent tiles. Matches the 24pt the
  /// original ad-hoc summary HStacks used.
  var spacing: CGFloat = 24

  var body: some View {
    HStack(alignment: .top, spacing: spacing) {
      ForEach(stats) { stat in
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(stat.value)
              .font(.system(.title2, design: .rounded).weight(.semibold))
              .foregroundStyle(stat.tint)
            if let unit = stat.unit {
              Text(unit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
          Text(stat.label)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
  }
}

/// The standard top-of-Log readout: a titled card wrapping the shared
/// `StatStrip`. Editable event-log sections (Symptoms, Medications, Intake)
/// put one of these at the top of their Log so the day's headline stats read
/// identically everywhere — same title, placement, and tile shape. Sections
/// with a genuinely richer readout (Sleep score rings, Body trend tiles,
/// Hydration progress bar) keep their bespoke top block; this is only for the
/// stat-strip family.
struct DrawerSummary: View {
  let stats: [Stat]
  var title: String = "Summary"

  var body: some View {
    DrawerSection(title) { StatStrip(stats: stats) }
  }
}

#Preview("StatStrip — two stats") {
  StatStrip(stats: [
    Stat(value: "12", label: "today", tint: .blue),
    Stat(value: "10.0", label: "grams", tint: .brown, unit: "g"),
  ])
  .padding()
  .background(Theme.secondaryGroupedBackground)
}

#Preview("StatStrip — many stats") {
  StatStrip(stats: [
    Stat(value: "8542", label: "steps", tint: .green),
    Stat(value: "245", label: "active", tint: .green, unit: "kcal"),
    Stat(value: "32", label: "exercise", tint: .green, unit: "m"),
  ])
  .padding()
  .background(Theme.secondaryGroupedBackground)
}
