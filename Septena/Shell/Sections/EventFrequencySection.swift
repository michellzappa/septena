import SwiftUI

// Section-level "Patterns" heatmap for single-stream event-log sections that
// have no sub-items to break down (Gut, Intake-kind) — the counterpart to
// `CompletionPatternsSection` (checklist sections) and the per-item heatmap in
// `LogDetailScaffold`. Where those encode done/total or severity, this encodes
// how many events landed each day, so the stream's own consistency reads at a
// glance. Reuses `ConsistencyHeatmap` so the ramp can't drift from the rest.

struct EventFrequencySection: View {
  /// Card title — "How often" / "Frequency", section-phrased by the caller.
  let title: String
  let accent: Color
  /// One ISO date (YYYY-MM-DD) per event; repeats on a date encode multiples.
  let dates: [String]
  /// Optional keep-logging nudge shown when there's no history yet.
  var emptyText: String? = nil

  private var countByDate: [String: Int] {
    dates.reduce(into: [:]) { $0[$1, default: 0] += 1 }
  }
  private var firstDate: Date? { dates.min().flatMap(SeptenaDate.parse) }

  var body: some View {
    if !dates.isEmpty {
      DrawerSection(title) {
        ConsistencyHeatmap(
          endDate: Date(),
          firstDataDate: firstDate,
          accent: accent,
          getDay: { iso in
            let count = countByDate[iso] ?? 0
            return HeatmapDay(level: HeatmapLevel.frequency(count: count),
                              label: count > 0 ? "\(iso): \(count)" : iso)
          }
        )
        .padding(.vertical, 2)
      }
    } else if let emptyText {
      DrawerSection(title) {
        Text(emptyText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

}
