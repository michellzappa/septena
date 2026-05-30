import SwiftUI
import SwiftData

// Mood is the first section migrated to the `SectionPlugin` model.
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

  static func detailPaneContent() -> AnyView? { AnyView(MoodDetailContent()) }

  static var logActions: [LogAction] {
    [LogAction(id: "log", title: "Log mood", systemImage: "plus")]
  }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "mood",
      title: "Mood",
      intro: "How you feel, plotted on the affect circumplex: pleasant ↔ unpleasant, calm ↔ energetic. Three check-ins a day is a good cadence — more or fewer is fine.",
      bullets: [
        .init("Tap a quadrant", "Pick the feeling that matches, then a word for it. That's the whole log.", icon: "hand.tap"),
        .init("Morning / afternoon / evening", "Suggested buckets, but timestamps are exact — log whenever it fits.", icon: "clock"),
        .init("Notes when useful", "Add free-text context when something specific is shaping the feeling.", icon: "text.bubble"),
      ],
      primaryActionLabel: "Start logging",
      complete: complete
    ))
  }

  // MARK: - Aim metrics

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "mood.entry_count_today",
                 label: "Mood check-ins (today)",
                 sectionKey: "mood",
                 window: "today",
                 unitLabel: "entries"),
      GoalMetric(key: "mood.entry_count_week",
                 label: "Mood check-ins (this week)",
                 sectionKey: "mood",
                 window: "calendarWeek",
                 unitLabel: "entries"),
      GoalMetric(key: "mood.avg_valence_week",
                 label: "Average valence (this week)",
                 sectionKey: "mood",
                 window: "calendarWeek",
                 unitLabel: "1–3"),
    ]
  }

  // MARK: - Settings detail pane

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window)
    else { return 0 }
    switch metric.key {
    case "mood.entry_count_today", "mood.entry_count_week":
      let descriptor = FetchDescriptor<MoodEventEntity>(
        predicate: #Predicate { $0.date >= startStr && $0.date <= endStr }
      )
      return Double((try? context.fetch(descriptor).count) ?? 0)
    case "mood.avg_valence_week":
      // Valence is stored as 1…3 (higher = more pleasant). nil when no
      // entries this week — the dispatcher hides the bar rather than
      // rendering 0 (which would misleadingly read as "rock bottom").
      let descriptor = FetchDescriptor<MoodEventEntity>(
        predicate: #Predicate { $0.date >= startStr && $0.date <= endStr }
      )
      let rows = (try? context.fetch(descriptor)) ?? []
      guard !rows.isEmpty else { return nil }
      return Double(rows.reduce(0) { $0 + $1.valence }) / Double(rows.count)
    default:
      return nil
    }
  }
}

private struct MoodDetailContent: View {
  var body: some View {
    HKSyncSection(label: "Write to Apple Health",
                  icon: "heart.text.square",
                  kind: .mood)
  }
}
