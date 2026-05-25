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
