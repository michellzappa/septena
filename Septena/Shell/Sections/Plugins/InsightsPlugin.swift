import SwiftUI

// Insights — read-only meta-section: cross-section correlation discovery
// (the engine in CorrelationEngine.swift). No data of its own, no Today
// presence, no quick-add. Its destination is the full explorer; its
// homepage tile is a single glance at the strongest trusted signal. Gated
// behind Septena+ inside the destination. See InsightsDestination.swift.

@MainActor
enum InsightsPlugin: SectionPlugin {
  static var manifest: SectionManifest { SectionManifest.byKey["insights"]! }

  static func destinationView() -> AnyView? { AnyView(InsightsDestinationView()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "insights",
      title: "Insights",
      intro: "What actually moves your day. Septena correlates everything you log — privately, on-device — and surfaces the relationships that hold up.",
      bullets: [
        .init("Honest by default",
              "Findings are FDR-gated and shown with their strength. The top tier stays empty until the evidence earns it — no fishing-expedition false positives.",
              icon: "checkmark.seal"),
        .init("Across everything you track",
              "Sleep, training, caffeine, mood, commits — any active section is a candidate. Disable a section and it leaves Insights too.",
              icon: "chart.dots.scatter"),
      ],
      primaryActionLabel: "Open Insights",
      complete: complete
    ))
  }
}
