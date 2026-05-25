import SwiftUI

// Sleep — HealthKit / Oura-mirrored sleep data. No Today timeline
// contribution (sleep ends in the morning, doesn't slot into a
// chronological log), no MCP brief yet. The destination view owns
// rendering. When the MCP gateway gains sleep tools, declare the
// brief here.

@MainActor
enum SleepPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["sleep"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] { [] }

  static func destinationView() -> AnyView? { AnyView(SleepDestinationView()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "sleep",
      title: "Set up Sleep",
      intro: "Sleep mirrors data from HealthKit and Oura — bed time, wake time, duration, stages. Septena reads; it never writes to your sleep records.",
      bullets: [
        ("Source priority", "Oura wins when connected (richer detail). HealthKit fills in nights Oura missed."),
        ("No manual entry", "Sleep is read-only here. Edit in Health.app or the Oura app."),
      ],
      actionLabel: "Got it",
      complete: complete
    ))
  }
}
