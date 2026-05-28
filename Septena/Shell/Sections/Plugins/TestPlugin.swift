import SwiftUI

// Sandbox plugin used to exercise SectionPlugin + onboarding wiring
// without touching real user data. Hidden by default; only visible in
// Settings → Manage Sections. The manifest entry for "test" lives in
// SectionManifest.swift and should be deleted (along with this file)
// before shipping to TestFlight / App Store.

@MainActor
enum TestPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["test"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    []
  }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(TestOnboardingView(complete: complete))
  }

  /// Always re-present on enable. Sandbox is a test bed — repeated
  /// access to the onboarding sheet is the point.
  static var alwaysShowOnboarding: Bool { true }
}

/// Minimal first-enable onboarding flow. Demonstrates the pattern other
/// sections will follow: brief intro, a single primary action that
/// commits the section to "onboarded" state, and a navigation chrome
/// the host (ManageSectionsPane) provides via `.sheet`.
private struct TestOnboardingView: View {
  let complete: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Welcome to the Sandbox")
            .font(.septenaSectionTitle)
          Text("This is a throwaway section used to test how Septena turns sections on and off, runs first-time setup, and keeps data safe across toggles.")
            .foregroundStyle(.secondary)
          Text("Tapping **Get started** marks this section as onboarded — you won't see this screen again unless the underlying flag is reset.")
            .foregroundStyle(.secondary)
          Button("Get started") { complete() }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding()
      }
      .navigationTitle("Sandbox")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
    }
  }
}
