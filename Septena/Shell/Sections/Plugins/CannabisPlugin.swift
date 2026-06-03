import SwiftUI
import SwiftData

// Cannabis log section. Same pattern as CaffeinePlugin: one file owns
// the display-label helper and the full MCP contract, so adding a new
// method or column updates everything in lock-step.

@MainActor
enum CannabisPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["cannabis"]!
  }

  static func destinationView() -> AnyView? { AnyView(CannabisDestinationView()) }

  // A mellow wind-down — a calm full-screen ripple wash. Single motion, no
  // time/dose dynamism (a cannabis log has no meaningful magnitude axis).
  static var logFlourish: LogFlourish? { LogFlourish(motion: .ripple) }

  static var logActions: [LogAction] {
    [
      LogAction(id: "log-vape",   title: "Log vape",      systemImage: "wind"),
      LogAction(id: "log-edible", title: "Log edible",    systemImage: "leaf.circle"),
    ]
  }

  static func detailPaneContent() -> AnyView? { AnyView(CannabisDetailContent()) }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "cannabisEvent", purpose: "one session", fields: [
          .req("id", "string"), .req("date", "date"), .req("time", "time"),
          .req("method", "string", "vape | edible"),
          .opt("strain", "string", "legacy — no longer set in-app"),
          .opt("hit", "int"), .opt("grams", "double"),
          .opt("effect", "string"), .opt("note", "string"),
        ]),
      ],
      collect: { ctx in
        let events = try ctx.fetch(FetchDescriptor<CannabisEventEntity>())
        return [
          "cannabisEvent": events.map(cannabisEventExportDict),
        ]
      }
    )
  }

  /// Human-readable label for an intake method. Used by both the Today
  /// timeline and the cannabis edit sheet — single source of truth.
  static func label(for entry: CannabisEntry) -> String {
    switch entry.method {
    case "vape":   return "Vape"
    case "edible": return "Edible"
    default:       return entry.method.capitalized
    }
  }

  // MARK: - MCP / agent contract

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "cannabis",
      summary: "Log cannabis intake (vape/edible) with effect.",
      tools: [
        SectionSkill.Tool("cannabis_events_list",  "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        SectionSkill.Tool("cannabis_event_log",    "Log an intake",
              inputs: "required: method (vape|edible) · optional: date (default today), time (HH:MM:SS), hit (count for vape), grams (for edibles), effect (free-form, e.g. relaxed/creative), note"),
        SectionSkill.Tool("cannabis_event_delete", "Remove an event",
              inputs: "required: id"),
      ],
      body: """
      `effect` is subjective free-form: "relaxed", "creative", "couch-locked".
      """
    )
  }

  // MARK: - Aim metrics

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "cannabis.event_count",
                 label: "Cannabis sessions (today)",
                 sectionKey: "cannabis",
                 window: "today",
                 unitLabel: "sessions"),
      GoalMetric(key: "cannabis.event_count_week",
                 label: "Cannabis sessions (this week)",
                 sectionKey: "cannabis",
                 window: "calendarWeek",
                 unitLabel: "sessions"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    switch metric.key {
    case "cannabis.event_count", "cannabis.event_count_week":
      // Each CannabisEventEntity = one session. Grams + hit count vary so
      // we count sessions rather than try to synthesise a dose number.
      guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window) else { return 0 }
      let descriptor = FetchDescriptor<CannabisEventEntity>(
        predicate: #Predicate { $0.date >= startStr && $0.date <= endStr }
      )
      return Double((try? context.fetch(descriptor).count) ?? 0)
    default:
      return nil
    }
  }
}

private struct CannabisDetailContent: View {
  @Environment(SettingsStore.self) private var store

  var body: some View {
    if let cnb = store.cannabis {
      Section("Dosing") {
        sectionDetailRow("Uses per capsule", "\(cnb.usesPerCapsule)")
      }
    }
  }
}

@MainActor func cannabisEventExportDict(_ e: CannabisEventEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "time": e.time, "method": e.method,
    "strain": e.strain, "hit": e.hit, "grams": e.grams,
    "effect": e.effect, "note": e.note,
    "updatedAt": isoDate(e.updatedAt),
  ])
}
