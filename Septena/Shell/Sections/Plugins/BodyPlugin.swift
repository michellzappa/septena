import SwiftUI
import SwiftData

// Body — weight, body comp, biometric trends mirrored from HealthKit
// and Withings. No Today timeline contribution; the destination view
// shows the longitudinal chart.

@MainActor
enum BodyPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["body"]!
  }

  static func destinationView() -> AnyView? { AnyView(BodyDestinationView()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "body",
      title: "Body",
      intro: "Weight and body-composition trends from HealthKit and Withings. Septena reads; it never writes back.",
      bullets: [
        .init("Withings wins for composition", "Fat %, muscle, water. HealthKit fills in days Withings missed.", icon: "figure.stand"),
        .init("Trend over spikes", "The multi-week direction is what matters — daily noise gets smoothed.", icon: "chart.line.uptrend.xyaxis"),
      ],
      primaryActionLabel: "Open Body",
      complete: complete
    ))
  }

  // MARK: - Aim metrics
  //
  // Body metrics read the *latest* non-nil value across all WithingsRow
  // rows. Window is "latest" (a special key — not time-bound). When the
  // user has no reading at all the evaluator returns nil so the progress
  // bar simply doesn't render — better than showing "0 / 80kg" which
  // misleadingly reads as "perfectly under target."

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "body.weight",
                 label: "Body weight (latest)",
                 sectionKey: "body",
                 window: "latest",
                 unitLabel: "kg"),
      GoalMetric(key: "body.fat_pct",
                 label: "Body fat % (latest)",
                 sectionKey: "body",
                 window: "latest",
                 unitLabel: "%"),
      GoalMetric(key: "body.muscle_mass",
                 label: "Muscle mass (latest)",
                 sectionKey: "body",
                 window: "latest",
                 unitLabel: "kg"),
      GoalMetric(key: "body.muscle_pct",
                 label: "Muscle % of body weight (latest)",
                 sectionKey: "body",
                 window: "latest",
                 unitLabel: "%"),
      GoalMetric(key: "body.fat_mass",
                 label: "Fat mass (latest)",
                 sectionKey: "body",
                 window: "latest",
                 unitLabel: "kg"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    switch metric.key {
    case "body.weight":      return latest(context: context) { $0.weightKg }
    case "body.fat_pct":     return latest(context: context) { $0.fatPct }
    case "body.muscle_mass": return latest(context: context) { $0.muscleMassKg }
    case "body.fat_mass":    return latest(context: context) { $0.fatMassKg }
    case "body.muscle_pct":
      // Derived: latest row where BOTH muscle mass and total weight are
      // present, then percent of body weight. Scanning by date desc and
      // requiring both fields means a row that's missing one doesn't
      // silently use stale numbers from a different weigh-in.
      let descriptor = FetchDescriptor<WithingsRowEntity>(
        sortBy: [SortDescriptor(\.id, order: .reverse)]
      )
      let rows = (try? context.fetch(descriptor)) ?? []
      guard let row = rows.first(where: {
        $0.muscleMassKg != nil && $0.weightKg != nil && ($0.weightKg ?? 0) > 0
      }),
        let muscle = row.muscleMassKg,
        let weight = row.weightKg
      else { return nil }
      return muscle / weight * 100
    default:                 return nil
    }
  }

  /// Most recent non-nil value across all Withings rows, scanning by
  /// date descending. Returns nil when no row has a reading for the
  /// requested field — caller treats nil as "no data, don't render".
  private static func latest(context: ModelContext,
                             field: (WithingsRowEntity) -> Double?) -> Double? {
    let descriptor = FetchDescriptor<WithingsRowEntity>(
      sortBy: [SortDescriptor(\.id, order: .reverse)]
    )
    let rows = (try? context.fetch(descriptor)) ?? []
    return rows.lazy.compactMap(field).first
  }
}
