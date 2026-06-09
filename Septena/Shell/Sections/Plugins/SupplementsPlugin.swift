import SwiftUI
import SwiftData

@MainActor
enum SupplementsPlugin: SectionPlugin {
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest {
    SectionManifest.byKey["supplements"]!
  }

  static func destinationView() -> AnyView? { AnyView(SupplementsDestinationView()) }

  static var logActions: [LogAction] {
    [LogAction(id: "new", title: "New supplement", systemImage: "plus")]
  }

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
    AnyView(SupplementsOnboardingView(complete: complete))
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

  static let all: [SupplementStarter] = [
    .init(id: "starter-vitamin-d",     name: "Vitamin D",         emoji: "☀️"),
    .init(id: "starter-omega-3",       name: "Omega-3",           emoji: "🐟"),
    .init(id: "starter-magnesium",     name: "Magnesium",         emoji: "🧂"),
    .init(id: "starter-multivitamin",  name: "Multivitamin",      emoji: "💊"),
    .init(id: "starter-creatine",      name: "Creatine",          emoji: "💪"),
    .init(id: "starter-protein",       name: "Protein",           emoji: "🥛"),
    .init(id: "starter-probiotic",     name: "Probiotic",         emoji: "🦠"),
    .init(id: "starter-b-complex",     name: "B-complex",         emoji: "🌾"),
    .init(id: "starter-iron",          name: "Iron",              emoji: "🩸"),
    .init(id: "starter-zinc",          name: "Zinc",              emoji: "⚙️"),
  ]
}

private struct SupplementsOnboardingView: View {
  let complete: () -> Void
  @Environment(ChecklistMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @State private var selected: Set<String> = []
  @State private var existingTitles: Set<String> = []

  private var accent: Color { theme.color(for: "supplements") }

  private func alreadyExists(_ s: SupplementStarter) -> Bool {
    existingTitles.contains(s.name.lowercased())
  }

  private func loadExisting() {
    let rows = (try? modelContext.fetch(FetchDescriptor<SupplementDefinitionEntity>())) ?? []
    existingTitles = Set(rows.map { $0.title.lowercased() })
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SectionOnboardingHero(
            sectionKey: "supplements",
            title: "Supplements",
            intro: "Logs the things you take daily. Pick a few common ones to start — edit, delete, or add your own anytime."
          )
          .onboardingHeroSection()
        }
        Section {
          ForEach(SupplementStarter.all) { starter in
            starterRow(starter)
          }
        }
      }
      .formStyle(.grouped)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .safeAreaInset(edge: .bottom) {
        bottomBar
      }
      .onAppear { loadExisting() }
    }
  }

  @ViewBuilder
  private func starterRow(_ s: SupplementStarter) -> some View {
    let exists = alreadyExists(s)
    let isSelected = selected.contains(s.id)
    Button {
      guard !exists else { return }
      if isSelected { selected.remove(s.id) } else { selected.insert(s.id) }
    } label: {
      HStack(spacing: 12) {
        Text(s.emoji).font(.title3)
          .opacity(exists ? 0.4 : 1)
        Text(s.name)
          .foregroundStyle(exists ? .secondary : .primary)
          .strikethrough(exists, color: .secondary)
        Spacer()
        if exists {
          Text("Already added")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.6))
            .font(.title3)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(exists)
  }

  @ViewBuilder
  private var bottomBar: some View {
    HStack(spacing: 12) {
      Button("Skip") { complete() }
        .buttonStyle(.bordered)
      Spacer()
      Button(actionTitle) { addAndFinish() }
        .buttonStyle(.borderedProminent)
        .tint(accent)
    }
    .padding()
    .background(.bar)
  }

  private var actionTitle: String {
    selected.isEmpty ? String(localized: "Done") : String(localized: "Add \(selected.count) supplements")
  }

  private func addAndFinish() {
    let toAdd = SupplementStarter.all.filter {
      selected.contains($0.id) && !alreadyExists($0)
    }
    for s in toAdd {
      mutator.createSupplement(name: s.name, emoji: s.emoji)
    }
    complete()
  }
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
