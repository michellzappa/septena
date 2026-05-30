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

  static func destinationView() -> AnyView? { AnyView(SleepDestinationView()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "sleep",
      title: "Sleep",
      intro: "Mirrors bed time, wake time, duration, and stages from HealthKit and Oura. Septena reads; it never writes back.",
      bullets: [
        .init("Oura wins when connected", "Richer per-night detail. HealthKit fills in nights Oura missed.", icon: "moon.stars"),
        .init("Read-only", "Edit nights in Apple Health or the Oura app — Septena reflects whatever's there.", icon: "lock"),
      ],
      primaryActionLabel: "Open Sleep",
      complete: complete
    ))
  }
}
