import SwiftUI

// Body — weight, body comp, biometric trends mirrored from HealthKit
// and Withings. No Today timeline contribution; the destination view
// shows the longitudinal chart.

@MainActor
enum BodyPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["body"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] { [] }

  static func destinationView() -> AnyView? { AnyView(BodyDestinationView()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "body",
      title: "Set up Body",
      intro: "Body shows your weight and body-composition trends from HealthKit and Withings. Septena reads; it never writes back.",
      bullets: [
        ("Source priority", "Withings wins for body comp (fat %, muscle, etc). HealthKit fills in days Withings missed."),
        ("Trends, not entries", "Body focuses on the trend line. Quick spikes get smoothed; multi-week direction is what matters."),
      ],
      actionLabel: "Got it",
      complete: complete
    ))
  }
}
