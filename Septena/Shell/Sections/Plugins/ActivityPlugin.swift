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
}
