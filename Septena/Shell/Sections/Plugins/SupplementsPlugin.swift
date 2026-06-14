import SwiftUI
import SwiftData

@MainActor
enum SupplementsPlugin: SectionPlugin {
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest {
    SectionManifest.byKey["supplements"]!
  }

  static func destinationView() -> AnyView? { AnyView(SupplementsDestinationView()) }

  static func detailPaneContent() -> AnyView? { AnyView(SupplementsDetailContent()) }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "supplementDefinition", purpose: "a supplement you take", fields: [
          .req("id", "string"), .req("title", "string"),
          .opt("emoji", "string"),
          .opt("bucket", "string"),  // "morning"|"afternoon"|"evening"; absent = anytime
          .opt("sortIndex", "int"),
        ]),
        SchemaTable(name: "supplementDayState", purpose: "one supplement on one day", fields: [
          .req("id", "string"), .req("date", "date"),
          .req("supplementID", "string"), .req("done", "bool"),
          .opt("note", "string"), .opt("time", "time"),
        ]),
      ],
      collect: { ctx in
        let defs   = try ctx.fetch(FetchDescriptor<SupplementDefinitionEntity>())
        let states = try ctx.fetch(FetchDescriptor<SupplementDayStateEntity>())
        return [
          "supplementDefinition": defs.map(supplementDefinitionExportDict),
          "supplementDayState":   states.map(supplementDayStateExportDict),
        ]
      }
    )
  }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionOnboarding(
      sectionKey: "supplements",
      intro: "Logs the things you take daily. Pick a few common ones to start — edit, delete, or add your own anytime.",
      nounPlural: String(localized: "supplements"),
      header: String(localized: "Starter supplements"),
      footer: String(localized: "Pick a few — rename, remove, or add your own anytime."),
      items: SupplementStarter.all,
      glyph: { .emoji($0.emoji) },
      primary: { $0.name },
      secondary: { $0.blurb },
      existsKey: { AnyHashable($0.name.lowercased()) },
      loadExistingKeys: {
        await MirrorReader.shared.read { ctx in
          Set(((try? ctx.fetch(FetchDescriptor<SupplementDefinitionEntity>())) ?? [])
            .map { AnyHashable($0.title.lowercased()) })
        }
      },
      add: { items in
        let mutator = SeptenaServices.shared.checklistMutator
        for s in items { mutator.createSupplement(name: s.name, emoji: s.emoji) }
      },
      complete: complete
    ))
  }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "supplements",
      summary: "Daily supplement log — same shape as habits.",
      tools: [
        SectionSkill.Tool("supplements_list",   "Definitions with today's state merged",
              inputs: "optional: date (default today)"),
        SectionSkill.Tool("supplements_create", "New definition",
              inputs: "required: title · optional: emoji, bucket (morning|afternoon|evening; omit for anytime)"),
        SectionSkill.Tool("supplements_update", "Update fields",
              inputs: "required: id · optional: title, emoji, bucket"),
        SectionSkill.Tool("supplements_delete", "Delete definition and events",
              inputs: "required: id"),
        SectionSkill.Tool("supplements_toggle", "Mark taken/untaken for a date",
              inputs: "required: id, done · optional: date"),
      ],
      body: """
      Same definition+state shape as habits. \
      `supplements_toggle(id, done: false)` removes today's mark.
      """
    )
  }

  // MARK: - Aim metrics

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "supplements.done_today",
                 label: "Supplements taken (today)",
                 sectionKey: "supplements",
                 window: "today",
                 unitLabel: "items"),
      GoalMetric(key: "supplements.days_active_week",
                 label: "Days with ≥1 supplement (this week)",
                 sectionKey: "supplements",
                 window: "calendarWeek",
                 unitLabel: "days"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window)
    else { return 0 }
    switch metric.key {
    case "supplements.done_today":
      let descriptor = FetchDescriptor<SupplementDayStateEntity>(
        predicate: #Predicate {
          $0.date >= startStr && $0.date <= endStr && $0.done == true
        }
      )
      return Double((try? context.fetch(descriptor).count) ?? 0)
    case "supplements.days_active_week":
      // Distinct days with ≥1 supplement marked — counts adherence in
      // day-shape, not pill-shape, so taking five pills one day still
      // counts as one day.
      let descriptor = FetchDescriptor<SupplementDayStateEntity>(
        predicate: #Predicate {
          $0.date >= startStr && $0.date <= endStr && $0.done == true
        }
      )
      let rows = (try? context.fetch(descriptor)) ?? []
      return Double(Set(rows.map { $0.date }).count)
    default:
      return nil
    }
  }

  // MARK: - Notifications
  //
  // The Habits nudge, applied to the same definition+state shape. One
  // coalesced daily reminder (never one per supplement) that fires at the
  // hour the user has *usually finished* taking them — the 80th percentile
  // of past taken-times — and suppresses the instant nothing's left to mark
  // today. Tap-to-open only: doses get checked off one at a time.

  static var notificationDescriptors: [NotificationDescriptor] {
    [NotificationDescriptor(
      id: "supplements.incomplete", sectionKey: "supplements", title: "Supplements reminder",
      priority: 15)]
  }

  static func evaluateNotification(_ descriptorID: String,
                                   context: ModelContext,
                                   now: Date) -> NotificationPlan? {
    guard descriptorID == "supplements.incomplete" else { return nil }
    let today = SeptenaDate.today
    guard let day = ChecklistMirror.loadSupplementsDay(context: context, date: today) else { return nil }

    let pending = day.items.filter { !$0.done }
    guard !pending.isEmpty else { return nil }   // all taken → suppress

    // Fire when the routine is *usually* wrapped up, learned from every
    // supplement's taken-times. Fallback: 20:00 (end of the active day).
    let states = (try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
      predicate: #Predicate { $0.done == true }
    ))) ?? []
    let dateTimes = states.compactMap { s -> (date: String, time: String)? in
      return (s.date, EventTimestamp.hhmm(from: s.occurredAt))
    }
    let minute = NextScoring.learnedLateMinute(dateTimes: dateTimes,
                                               today: today, fallback: 20 * 60)
    let n = pending.count
    let body = n == 1
      ? "1 supplement left today — mark it if you’ve taken it."
      : "\(n) supplements left today — mark any you’ve taken."
    return NotificationPlan(descriptorID: descriptorID, title: "Supplements",
                            body: body, threadID: "supplements", minuteOfDay: minute)
  }
}

private struct SupplementsDetailContent: View {
  @State private var showingSheet = false
  /// Per-device "carry over missed doses" toggle — read by the Next feed's
  /// `supplementsNow` filter. Default ON (lingers). See `NextLinger`.
  @AppStorage(NextLinger.supplementsKey) private var carryOver = NextLinger.supplementsDefault

  // Two sibling Sections returned straight from the ViewBuilder body (no
  // `Group` wrapper). A `.sheet` attached to a multi-child `Group` inside a
  // `Form` mis-anchors and transiently self-presents as the pane appears —
  // so the sheet must hang off the single Section that actually triggers it.
  var body: some View {
    Section {
      Toggle(isOn: $carryOver) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Carry over missed doses")
          Text("Keep a supplement on the Next list after its time of day, until you take it. Off shows it only during its slot.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Next list")
    }
    Section {
      Button {
        showingSheet = true
      } label: {
        Label("Manage Supplements", systemImage: "pills")
      }
    } footer: {
      Text("Renaming a supplement doesn't affect its history — events are linked by ID.")
    }
    .sheet(isPresented: $showingSheet) {
      SupplementTypeSheet()
        .environment(SeptenaServices.shared.checklistMutator)
    }
    // Note: the contextual "Ask Siri" tip is rendered centrally by
    // SectionDetailPane via sectionSiriTip(forKey:), so every section gets one
    // without a per-plugin call here.
  }
}

/// Curated starter supplements. Additive only — items the user already
/// has (case-insensitive title match) render as "Already added".
private struct SupplementStarter: Identifiable, Hashable {
  let id: String
  let name: String
  let emoji: String
  let blurb: String

  static let all: [SupplementStarter] = [
    .init(id: "starter-vitamin-d",     name: "Vitamin D",         emoji: "☀️", blurb: "Daily, with a meal"),
    .init(id: "starter-omega-3",       name: "Omega-3",           emoji: "🐟", blurb: "Fish oil — EPA & DHA"),
    .init(id: "starter-magnesium",     name: "Magnesium",         emoji: "🧂", blurb: "Often taken in the evening"),
    .init(id: "starter-multivitamin",  name: "Multivitamin",      emoji: "💊", blurb: "A daily all-rounder"),
    .init(id: "starter-creatine",      name: "Creatine",          emoji: "💪", blurb: "For training and strength"),
    .init(id: "starter-protein",       name: "Protein",           emoji: "🥛", blurb: "Shake or powder"),
    .init(id: "starter-probiotic",     name: "Probiotic",         emoji: "🦠", blurb: "For gut health"),
    .init(id: "starter-b-complex",     name: "B-complex",         emoji: "🌾", blurb: "The B-vitamin group"),
    .init(id: "starter-iron",          name: "Iron",              emoji: "🩸", blurb: "Often paired with vitamin C"),
    .init(id: "starter-zinc",          name: "Zinc",              emoji: "⚙️", blurb: "Immune support"),
  ]
}

@MainActor func supplementDefinitionExportDict(_ e: SupplementDefinitionEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "emoji": e.emoji, "bucket": e.bucket,
    "sortIndex": e.sortIndex, "updatedAt": isoDate(e.updatedAt),
  ])
}

@MainActor func supplementDayStateExportDict(_ e: SupplementDayStateEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "supplementID": e.supplementID,
    "done": e.done, "note": e.note,
    "time": EventTimestamp.hhmm(from: e.occurredAt),
    "updatedAt": isoDate(e.updatedAt),
  ])
}
