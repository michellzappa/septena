import SwiftUI

// GitHub — read-only mirror of the authenticated user's contribution
// calendar (the commit heatmap). No Today timeline and no homepage tile
// yet; the destination view shows the year heatmap + a weekly commit
// sparkline. The data layer (Keychain token, GraphQL fetch, no CloudKit)
// lives in `SeptenaCore/GitHubProvider.swift`.

@MainActor
enum GitHubPlugin: SectionPlugin {
  static var manifest: SectionManifest { SectionManifest.byKey["github"]! }

  static func destinationView() -> AnyView? { AnyView(GitHubDestinationView()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "github",
      title: "GitHub",
      intro: "Your commit activity as a contribution heatmap. Septena reads your GitHub calendar; it never writes anything back.",
      bullets: [
        .init("Read-only, on this device",
              "Paste a personal access token once — it stays in this device's Keychain and is never sent to any Septena server.",
              icon: "lock"),
        .init("One year at a glance",
              "The same green contribution grid as your profile, plus a weekly sparkline of commits.",
              icon: "square.grid.3x3"),
      ],
      primaryActionLabel: "Open GitHub",
      complete: complete
    ))
  }
}
