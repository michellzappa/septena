import SwiftUI

// Activity — steps and movement mirrored from HealthKit. Read-only,
// no manual entry. The destination view shows daily totals and trends.

@MainActor
enum ActivityPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["activity"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] { [] }

  static func destinationView() -> AnyView? { AnyView(ActivityDestinationView()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "activity",
      title: "Set up Activity",
      intro: "Activity reads step counts and movement minutes from HealthKit so they sit alongside your other daily data.",
      bullets: [
        ("Read-only", "Septena observes HealthKit; never writes back."),
        ("HealthKit permission", "Granted in iOS Settings → Privacy → Health → Septena. Without it the section stays empty."),
      ],
      actionLabel: "Got it",
      complete: complete
    ))
  }
}
