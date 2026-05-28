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
      title: "Air",
      intro: "Indoor CO₂, temperature, and humidity from an Aranet sensor — plus outdoor pollen and AQI.",
      bullets: [
        .init("Aranet (optional)", "Pair an Aranet4 once; Septena reads samples via Bluetooth whenever the app is open.", icon: "sensor.tag.radiowaves.forward"),
        .init("Outdoor data, no setup", "Pollen and AQI come from your current-location lookup automatically.", icon: "leaf"),
        .init("Read-only", "Air observes; never writes back to any sensor or service.", icon: "lock"),
      ],
      primaryActionLabel: "Open Air",
      complete: complete
    ))
  }
}
