import SwiftUI
import SwiftData

// Activity — steps and movement mirrored from HealthKit. Read-only,
// no manual entry. The destination view shows daily totals and trends.

@MainActor
enum ActivityPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["activity"]!
  }

  static func destinationView() -> AnyView? { AnyView(ActivityDestinationView()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "activity",
      title: "Activity",
      intro: "Step counts and movement minutes from HealthKit, alongside the rest of your daily data.",
      bullets: [
        .init("Read-only", "Septena observes HealthKit; never writes back.", icon: "lock"),
        .init("HealthKit permission", "Granted in iOS Settings → Privacy → Health → Septena. Without it the section stays empty.", icon: "heart.text.square"),
      ],
      primaryActionLabel: "Open Activity",
      complete: complete
    ))
  }

  // Steps + exercise minutes as daily correlation series, read from the
  // synced ActivityDayEntity mirror. Tagged `.lever` — they're behaviours you
  // choose ("does walking more improve my sleep?"), the QS framing the engine
  // pairs as predictors. Active kcal is omitted: it's near-collinear with
  // these two and would only inflate the FDR-gated candidate pool. Returns []
  // until a phone has ingested at least one day with data.
  static func correlationFeatures(context: ModelContext) -> [CorrelationFeature] {
    let rows = (try? context.fetch(FetchDescriptor<ActivityDayEntity>())) ?? []
    guard !rows.isEmpty else { return [] }

    var steps: [String: Double] = [:]
    var exMin: [String: Double] = [:]
    for r in rows {
      if let s = r.stepCount, s > 0 { steps[r.date] = Double(s) }
      if let e = r.exerciseMinutes, e > 0 { exMin[r.date] = Double(e) }
    }

    var features: [CorrelationFeature] = []
    if !steps.isEmpty {
      features.append(CorrelationFeature(
        key: "activity_steps", label: "Steps", section: "activity",
        unit: "", role: .lever, distribution: .continuous, series: steps))
    }
    if !exMin.isEmpty {
      features.append(CorrelationFeature(
        key: "activity_exercise_minutes", label: "Exercise minutes", section: "activity",
        unit: "min", role: .lever, distribution: .continuous, series: exMin))
    }
    return features
  }
}
