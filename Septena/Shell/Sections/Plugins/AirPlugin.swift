import SwiftUI

// Air — indoor CO₂ + temperature/humidity from the Aranet bridge, plus
// outdoor pollen + AQI from PollenClient. Destination view renders the
// last 24h charts.

@MainActor
enum AirPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["air"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] { [] }

  static func destinationView() -> AnyView? { AnyView(AirDestinationView()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "air",
      title: "Set up Air",
      intro: "Air shows indoor CO₂, temperature, and humidity from an Aranet sensor, plus outdoor pollen and AQI.",
      bullets: [
        ("Aranet (optional)", "Pair an Aranet4 once and Septena reads samples via Bluetooth whenever the app is open."),
        ("Outdoor data", "Pollen and AQI come from your current-location lookup, no setup needed."),
        ("Read-only", "Air observes; it never writes back to any sensor or service."),
      ],
      actionLabel: "Got it",
      complete: complete
    ))
  }
}
