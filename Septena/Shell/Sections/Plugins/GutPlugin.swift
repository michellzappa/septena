import SwiftUI
import SwiftData

// Digestive event log. The Bristol stool scale labels and the
// detail-line construction (volume, blood, note) live here with the
// rest of the section's contract.

@MainActor
enum GutPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["gut"]!
  }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "gutEvent", purpose: "one bowel-movement log", fields: [
          .req("id", "string"), .req("date", "date"), .req("time", "time"),
          .req("bristol", "int", "1–7"), .req("blood", "int", "0–3"),
          .opt("volume", "string"), .opt("discomfortLevel", "string"),
          .opt("discomfortStart", "time"), .opt("discomfortEnd", "time"),
          .opt("note", "string"),
        ]),
      ],
      collect: { ctx in
        let events = try ctx.fetch(FetchDescriptor<GutEventEntity>())
        return ["gutEvent": events.map(gutEventExportDict)]
      }
    )
  }

  static func destinationView() -> AnyView? { AnyView(GutDestinationView()) }

  // MARK: - Quick-log actions

  static var logActions: [LogAction] {
    [LogAction(id: "movement", title: "Log movement", systemImage: "plus")]
  }

  // MARK: - First-enable onboarding

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "gut",
      title: "Gut",
      intro: "A private digestive event log. Useful for tracking down a food sensitivity, recovering from antibiotics, or just spotting patterns.",
      bullets: [
        .init("Bristol Stool Scale", "1 = hard pellets, 7 = watery. Required for every entry.", icon: "ruler"),
        .init("Volume + blood", "Small / medium / large; blood as a count. Both optional.", icon: "drop"),
        .init("Discomfort window", "Optional HH:MM start / end when cramping or pain matters.", icon: "clock.badge.exclamationmark"),
      ],
      primaryActionLabel: "Start logging",
      complete: complete
    ))
  }

  /// Bristol Stool Scale 1–7 → human label. Also used by the gut edit
  /// sheet so the displayed string stays in sync.
  static func bristolLabel(_ n: Int) -> String {
    switch n {
    case 1: return "Type 1 — Separate lumps"
    case 2: return "Type 2 — Lumpy sausage"
    case 3: return "Type 3 — Cracked sausage"
    case 4: return "Type 4 — Smooth sausage"
    case 5: return "Type 5 — Soft blobs"
    case 6: return "Type 6 — Fluffy pieces"
    case 7: return "Type 7 — Liquid"
    default: return "Bristol \(n)"
    }
  }

  // MARK: - MCP / agent contract

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "gut",
      summary: "Digestive event log.",
      tools: [
        SectionSkill.Tool("gut_events_list",  "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        SectionSkill.Tool("gut_event_log",    "Log an event",
              inputs: "required: bristol (1-7) · optional: date (default today), time (HH:MM:SS), blood (boolean), volume (small|medium|large), discomfortLevel (free-form), discomfortStart (HH:MM), discomfortEnd (HH:MM), note"),
        SectionSkill.Tool("gut_event_delete", "Remove an event",
              inputs: "required: id"),
      ],
      body: """
      `bristol` is the Bristol Stool Scale (1 = hard pellets, 7 = watery) and \
      is required. Log `discomfortStart`/`discomfortEnd` as `HH:MM` when the \
      user describes cramping or pain.
      """
    )
  }

  // MARK: - Aim metrics

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "gut.event_count",
                 label: "Gut events (this week)",
                 sectionKey: "gut",
                 window: "calendarWeek",
                 unitLabel: "events"),
      GoalMetric(key: "gut.blood_count",
                 label: "Gut events with blood (this week)",
                 sectionKey: "gut",
                 window: "calendarWeek",
                 unitLabel: "events"),
      GoalMetric(key: "gut.discomfort_count",
                 label: "Gut events with discomfort (this week)",
                 sectionKey: "gut",
                 window: "calendarWeek",
                 unitLabel: "events"),
      GoalMetric(key: "gut.bristol_avg",
                 label: "Average bristol score (this week)",
                 sectionKey: "gut",
                 window: "calendarWeek",
                 unitLabel: "bristol"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window)
    else { return 0 }
    switch metric.key {
    case "gut.event_count":
      let descriptor = FetchDescriptor<GutEventEntity>(
        predicate: #Predicate { $0.date >= startStr && $0.date <= endStr }
      )
      return Double((try? context.fetch(descriptor).count) ?? 0)
    case "gut.blood_count":
      let descriptor = FetchDescriptor<GutEventEntity>(
        predicate: #Predicate {
          $0.date >= startStr && $0.date <= endStr && $0.blood > 0
        }
      )
      return Double((try? context.fetch(descriptor).count) ?? 0)
    case "gut.discomfort_count":
      let descriptor = FetchDescriptor<GutEventEntity>(
        predicate: #Predicate {
          $0.date >= startStr && $0.date <= endStr && $0.discomfortLevel != nil
        }
      )
      return Double((try? context.fetch(descriptor).count) ?? 0)
    case "gut.bristol_avg":
      // 0 when no events this week — reads as "no data" against any
      // target rather than misleadingly perfect.
      let descriptor = FetchDescriptor<GutEventEntity>(
        predicate: #Predicate { $0.date >= startStr && $0.date <= endStr }
      )
      let entries = (try? context.fetch(descriptor)) ?? []
      guard !entries.isEmpty else { return 0 }
      return Double(entries.reduce(0) { $0 + $1.bristol }) / Double(entries.count)
    default:
      return nil
    }
  }
}

@MainActor func gutEventExportDict(_ e: GutEventEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "time": e.time,
    "bristol": e.bristol, "blood": e.blood, "volume": e.volume,
    "discomfortLevel": e.discomfortLevel,
    "discomfortStart": e.discomfortStart,
    "discomfortEnd": e.discomfortEnd,
    "note": e.note, "updatedAt": isoDate(e.updatedAt),
  ])
}
