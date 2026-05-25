import SwiftUI

// Mood is the first section migrated to the `SectionPlugin` model.
// Proof-of-concept: its Today event production now lives in one place
// instead of being inlined in `TodayLogView.buildEvents`.
//
// Future slots that will land in subsequent commits (one section per
// commit, per the staged migration plan):
//   - dashboardTile(ctx:) — moves `moodTile` + `moodDomainData` here
//   - detailPane()        — moves the SectionDetailPane "mood" branch here
//   - mcpSkill            — declares its SectionSkill brief here
//   - onboarding()        — runs on first enable (gated by hasOnboarded)

@MainActor
enum MoodPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    // Force-unwrap is safe: manifest entry for "mood" ships in the
    // catalog. A compile-time check would be nicer; will switch to a
    // strongly-typed manifest reference once every section is migrated.
    SectionManifest.byKey["mood"]!
  }

  static func destinationView() -> AnyView? { AnyView(MoodDestinationView()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "mood",
      title: "Set up Mood",
      intro: "Mood logs how you feel as a point on the affect circumplex — pleasant ↔ unpleasant on one axis, calm ↔ energetic on the other. Three check-ins a day is the suggested cadence; do more or fewer as you like.",
      bullets: [
        ("Tap or drag", "Pick a quadrant and pick a word that matches. Done."),
        ("Three buckets", "Morning, afternoon, evening — but timestamps are exact, so log whenever it fits."),
        ("Optional notes", "Add free-text context when something specific is shaping the feeling."),
      ],
      actionLabel: "Got it",
      complete: complete
    ))
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    ctx.mood.map { e in
      // Use the quadrant color rather than the section accent — the
      // affective dimension is the whole point of a mood log; a single
      // section-wide color would erase it.
      let quadColor = MoodQuadrant(rawValue: e.quadrant)?.color ?? .gray
      return TodayEvent(
        id: "mood-\(e.id)",
        time: String(e.time.prefix(5)),
        section: "mood",
        color: quadColor,
        title: e.emotion,
        detail: e.note,
        kind: .mood(e)
      )
    }
  }
}
