import SwiftUI
import SwiftData

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
    AnyView(SectionOnboarding(
      sectionKey: "github",
      intro: "Your commit activity as a contribution heatmap. Septena reads your GitHub calendar; it never writes anything back.",
      bullets: [
        .init("Read-only, on this device",
              "Paste a personal access token once — it stays in this device's Keychain and is never sent to any Septena server.",
              icon: "lock"),
        .init("One year at a glance",
              "The same green contribution grid as your profile, plus a weekly sparkline of commits.",
              icon: "square.grid.3x3"),
      ],
      complete: complete
    ))
  }

  // Commits-per-day as a correlation feature. Tagged `.outcome` (it's an
  // output you might want to *raise* — "what helps me ship?") and `.count`.
  // Reads the cached contribution calendar the destination / tile already
  // fetch; no extra network. Returns [] until GitHub is connected.
  static func correlationFeatures(context: ModelContext) -> [CorrelationFeature] {
    let cached = ResponseCache.load(GitHubContributions.self, forKey: "github.contributions")
      ?? ResponseCache.load(GitHubContributions.self, forKey: "week.github")
    guard let c = cached, !c.days.isEmpty else { return [] }
    let series = Dictionary(uniqueKeysWithValues: c.days.map { ($0.date, Double($0.count)) })
    return [
      CorrelationFeature(key: "github_commits",
                         label: "Commits",
                         section: "github",
                         unit: "",
                         role: .outcome,
                         distribution: .count,
                         series: series)
    ]
  }
}
