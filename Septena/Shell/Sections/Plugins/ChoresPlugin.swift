import SwiftUI
import SwiftData

@MainActor
enum ChoresPlugin: SectionPlugin {
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest {
    SectionManifest.byKey["chores"]!
  }

  static func destinationView() -> AnyView? { AnyView(ChoresDestinationView()) }

  static var logActions: [LogAction] {
    [LogAction(id: "new", title: "New chore", systemImage: "plus")]
  }

  static func detailPaneContent() -> AnyView? { AnyView(ChoresDetailContent()) }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "choreDefinition", purpose: "a recurring chore", fields: [
          .req("id", "string"), .req("title", "string"),
          .req("cadenceDays", "int"),
          .opt("emoji", "string"), .opt("sortIndex", "int"),
        ]),
        SchemaTable(name: "choreEvent", purpose: "completion / skip / reschedule", fields: [
          .req("id", "string"), .req("choreID", "string"),
          .req("action", "string", "completed | skipped | rescheduled"),
          .req("date", "date"), .req("sortKey", "string"),
          .opt("newDueDate", "date"), .opt("reason", "string"),
          .opt("note", "string"), .opt("time", "time"),
        ]),
      ],
      collect: { ctx in
        let defs   = try ctx.fetch(FetchDescriptor<ChoreDefinitionEntity>())
        let events = try ctx.fetch(FetchDescriptor<ChoreEventEntity>())
        return [
          "choreDefinition": defs.map(choreDefinitionExportDict),
          "choreEvent":      events.map(choreEventExportDict),
        ]
      }
    )
  }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionOnboarding(
      sectionKey: "chores",
      intro: "Recurring household tasks with computed due dates. Pick the ones that apply — cadences are a starting point you can adjust later.",
      nounPlural: String(localized: "chores"),
      items: ChoreStarter.all,
      glyph: { .emoji($0.emoji) },
      primary: { $0.name },
      secondary: { $0.cadenceLabel },
      existsKey: { AnyHashable($0.name.lowercased()) },
      loadExistingKeys: {
        await MirrorReader.shared.read { ctx in
          Set(((try? ctx.fetch(FetchDescriptor<ChoreDefinitionEntity>())) ?? [])
            .map { AnyHashable($0.title.lowercased()) })
        }
      },
      add: { items in
        let mutator = SeptenaServices.shared.checklistMutator
        for s in items { mutator.createChore(name: s.name, cadenceDays: s.cadenceDays, emoji: s.emoji) }
      },
      complete: complete
    ))
  }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "chores",
      summary: "Recurring household tasks with computed due dates.",
      tools: [
        SectionSkill.Tool("chores_list",       "Definitions + computed due/last-completed (replays 180d)"),
        SectionSkill.Tool("chores_create",     "New chore",
              inputs: "required: title, cadenceDays · optional: emoji"),
        SectionSkill.Tool("chores_update",     "Update fields",
              inputs: "required: id · optional: title, cadenceDays (min 1), emoji"),
        SectionSkill.Tool("chores_delete",     "Delete definition and events",
              inputs: "required: id"),
        SectionSkill.Tool("chores_complete",   "Log completion for today or a given date",
              inputs: "required: id · optional: date (default today)"),
        SectionSkill.Tool("chores_defer",      "Defer to 'day' (tomorrow) or 'weekend' (next Saturday)",
              inputs: "required: id, mode (day|weekend) · optional: date"),
        SectionSkill.Tool("chores_uncomplete", "Remove most recent completion",
              inputs: "required: id · optional: date"),
      ],
      body: """
      `chores_list` replays the last 180 days of events to compute when each \
      chore is next due. Surface overdue items first.
      """
    )
  }

  // MARK: - Aim metrics

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "chores.completed_week",
                 label: "Chores completed (this week)",
                 sectionKey: "chores",
                 window: "calendarWeek",
                 unitLabel: "chores"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window)
    else { return 0 }
    switch metric.key {
    case "chores.completed_week":
      // ChoreEvent rows where action == "complete" — matches the
      // sentinel written by `SeptenaServices.completeChore`. Defers
      // and other actions don't count toward a completion goal.
      let descriptor = FetchDescriptor<ChoreEventEntity>(
        predicate: #Predicate {
          $0.date >= startStr && $0.date <= endStr && $0.action == "complete"
        }
      )
      return Double((try? context.fetch(descriptor).count) ?? 0)
    default:
      return nil
    }
  }

  // MARK: - Notifications

  static var notificationDescriptors: [NotificationDescriptor] {
    [NotificationDescriptor(
      id: "chores.overdue", sectionKey: "chores", title: String(localized: "Overdue chore digest", comment: "Scheduled notification name"),
      actions: [NotificationAction(id: NotificationActionID.choreComplete, title: String(localized: "✓ Mark done"))],
      priority: 10)]
  }

  static func evaluateNotification(_ descriptorID: String,
                                   context: ModelContext,
                                   now: Date) -> NotificationPlan? {
    guard descriptorID == "chores.overdue" else { return nil }
    // Reuse the same overdue definition the Next feed and Today pill use,
    // most-overdue first.
    let overdue = ChecklistMirror.loadChores(context: context)
      .filter { $0.daysOverdue > 0 }
      .sorted { $0.daysOverdue > $1.daysOverdue }
    guard let top = overdue.first else { return nil }   // nothing overdue → suppress

    // Fire when the user has usually wrapped chores up (80th-percentile),
    // so it only pings when genuinely behind. Fallback 18:00.
    let events = (try? context.fetch(FetchDescriptor<ChoreEventEntity>())) ?? []
    let dateTimes = events.compactMap { e -> (date: String, time: String)? in
      guard e.action == "complete" else { return nil }
      return (e.date, EventTimestamp.hhmm(from: e.occurredAt))
    }
    let minute = NextScoring.learnedLateMinute(dateTimes: dateTimes,
                                               today: SeptenaDate.today,
                                               fallback: 18 * 60)
    let n = overdue.count
    let body = n == 1
      ? String(localized: "“\(top.name)” is overdue — mark it if you’ve done it.", comment: "Chore reminder (one)")
      : String(localized: "\(n) chores overdue — “\(top.name)” is the latest. Mark it if it’s done.", comment: "Chore reminder (many)")
    // The "✓ Mark done" action completes the single most-overdue chore; for
    // the rest the next reconcile re-surfaces them (or the user opens the app).
    return NotificationPlan(descriptorID: descriptorID, title: String(localized: "Chores"),
                            body: body, threadID: "chores", minuteOfDay: minute,
                            userInfo: [NotificationUserInfoKey.choreID: top.id])
  }
}

private struct ChoresDetailContent: View {
  @Environment(SettingsStore.self) private var store

  var body: some View {
    if !store.chores.isEmpty {
      Section("Definitions") {
        ForEach(store.chores) { c in
          HStack {
            if let e = c.emoji { Text(e) }
            Text(c.name).foregroundStyle(.primary)
            Spacer()
            if let due = c.dueDate {
              Text(due)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }
}

/// Starter chores include a recommended cadence (in days). User can edit
/// after import. Additive only — existing chore titles are skipped.
private struct ChoreStarter: Identifiable, Hashable {
  let id: String
  let name: String
  let emoji: String
  let cadenceDays: Int

  static let all: [ChoreStarter] = [
    .init(id: "starter-dishes",       name: "Dishes",          emoji: "🍽️", cadenceDays: 1),
    .init(id: "starter-trash",        name: "Take out trash",  emoji: "🗑️", cadenceDays: 3),
    .init(id: "starter-laundry",      name: "Laundry",         emoji: "🧺", cadenceDays: 7),
    .init(id: "starter-vacuum",       name: "Vacuum",          emoji: "🧹", cadenceDays: 7),
    .init(id: "starter-bathroom",     name: "Clean bathroom",  emoji: "🛁", cadenceDays: 7),
    .init(id: "starter-sheets",       name: "Change sheets",   emoji: "🛏️", cadenceDays: 14),
    .init(id: "starter-fridge",       name: "Clean fridge",    emoji: "🧊", cadenceDays: 30),
    .init(id: "starter-windows",      name: "Wash windows",    emoji: "🪟", cadenceDays: 90),
  ]

  var cadenceLabel: String {
    switch cadenceDays {
    case 1:           return "daily"
    case 2...6:       return "every \(cadenceDays) days"
    case 7:           return "weekly"
    case 8...13:      return "every \(cadenceDays) days"
    case 14:          return "every 2 weeks"
    case 15...29:     return "every \(cadenceDays) days"
    case 30:          return "monthly"
    case 31...89:     return "every \(cadenceDays) days"
    case 90:          return "quarterly"
    default:          return "every \(cadenceDays) days"
    }
  }
}

@MainActor func choreDefinitionExportDict(_ e: ChoreDefinitionEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "emoji": e.emoji,
    "cadenceDays": e.cadenceDays, "sortIndex": e.sortIndex,
    "updatedAt": isoDate(e.updatedAt),
  ])
}

@MainActor func choreEventExportDict(_ e: ChoreEventEntity) -> [String: Any] {
  compact([
    "id": e.id, "choreID": e.choreID, "action": e.action,
    "date": e.date, "newDueDate": e.newDueDate,
    "reason": e.reason, "note": e.note,
    "time": e.action == "complete" ? EventTimestamp.hhmm(from: e.occurredAt) : nil,
    "sortKey": e.sortKey, "updatedAt": isoDate(e.updatedAt),
  ])
}
