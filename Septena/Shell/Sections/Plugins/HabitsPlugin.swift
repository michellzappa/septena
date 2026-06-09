import SwiftUI
import SwiftData

@MainActor
enum HabitsPlugin: SectionPlugin {
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest {
    SectionManifest.byKey["habits"]!
  }

  static func destinationView() -> AnyView? { AnyView(HabitsDestinationView()) }

  static func detailPaneContent() -> AnyView? { AnyView(HabitsDetailContent()) }

  static var logActions: [LogAction] {
    [LogAction(id: "new", title: "New habit", systemImage: "plus")]
  }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "habitDefinition", purpose: "a habit you track", fields: [
          .req("id", "string"), .req("title", "string"),
          .req("bucket", "string", "free-form group key, e.g. morning"),
          .opt("emoji", "string"), .opt("sortIndex", "int"),
        ]),
        SchemaTable(name: "habitDayState", purpose: "one habit on one day", fields: [
          .req("id", "string", "stable per habit+day, e.g. <habitID>:<date>"),
          .req("date", "date"), .req("habitID", "string"),
          .req("done", "bool"), .req("skipped", "bool"),
          .opt("note", "string"), .opt("time", "time"),
        ]),
      ],
      collect: { ctx in
        let defs   = try ctx.fetch(FetchDescriptor<HabitDefinitionEntity>())
        let states = try ctx.fetch(FetchDescriptor<HabitDayStateEntity>())
        return [
          "habitDefinition": defs.map(habitDefinitionExportDict),
          "habitDayState":   states.map(habitDayStateExportDict),
        ]
      }
    )
  }

  // MARK: - First-enable onboarding
  //
  // Curated starter list grouped by daypart. Tapping toggles inclusion;
  // "Add habits" inserts a HabitDefinitionEntity per selection via
  // ChecklistMutator (which handles ID minting, sort indexing, and the
  // CKEngine push). Users can always edit / delete / add more from the
  // Habits destination afterwards — this is a head-start, not a gate.

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(HabitsOnboardingView(complete: complete))
  }

  // MARK: - MCP / agent contract

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "habits",
      summary: "Daily routines with done/skipped state per date.",
      tools: [
        SectionSkill.Tool("habits_list",   "Definitions with today's state merged",
              inputs: "optional: date (YYYY-MM-DD, default today)"),
        SectionSkill.Tool("habits_create", "New definition",
              inputs: "required: title, bucket (morning|evening|anytime) · optional: emoji"),
        SectionSkill.Tool("habits_update", "Update fields",
              inputs: "required: id · optional: title, bucket (morning|evening|anytime), emoji"),
        SectionSkill.Tool("habits_delete", "Delete definition and all its events",
              inputs: "required: id"),
        SectionSkill.Tool("habits_toggle", "Mark done/skipped/unmarked for a date. Idempotent",
              inputs: "required: id, done · optional: date, skipped"),
      ],
      body: """
      Habits separate **definitions** (the thing) from **events** (per-date state).

      ### Examples
      **"Mark my morning habits done"**
      ```
      habits_list()                         → filter bucket == "morning"
      habits_toggle(id, done: true)         → for each
      ```

      **"I'm taking a rest day from exercise"**
      ```
      habits_toggle(id, done: false, skipped: true)
      ```

      ### Don't
      - Don't create a new definition to log today's completion.
      """
    )
  }

  // MARK: - Aim metrics

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "habits.done_today",
                 label: "Habits checked off (today)",
                 sectionKey: "habits",
                 window: "today",
                 unitLabel: "habits"),
      GoalMetric(key: "habits.days_active_week",
                 label: "Days with ≥1 habit done (this week)",
                 sectionKey: "habits",
                 window: "calendarWeek",
                 unitLabel: "days"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window)
    else { return 0 }
    switch metric.key {
    case "habits.done_today":
      // Count HabitDayState rows for today where done=true. Each row is
      // one (habit, day) check — counting them gives "how many habits
      // did I tick today."
      let descriptor = FetchDescriptor<HabitDayStateEntity>(
        predicate: #Predicate {
          $0.date >= startStr && $0.date <= endStr && $0.done == true
        }
      )
      return Double((try? context.fetch(descriptor).count) ?? 0)
    case "habits.days_active_week":
      // Distinct dates where ≥1 habit was marked done — a "habit-active
      // day." Better signal than total ticks for week-shape goals
      // because it doesn't reward stacking ten habits on one day.
      let descriptor = FetchDescriptor<HabitDayStateEntity>(
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
  // One coalesced daily nudge (not one per daypart — that's too noisy). It
  // fires at the hour the user has *usually wrapped up* their habits (the
  // 80th percentile of completion times), so it stays quiet on days they
  // finish on schedule and only speaks when they've drifted past their
  // window. Suppressed entirely once nothing is left to mark today.

  static var notificationDescriptors: [NotificationDescriptor] {
    // No inline action — habits get checked off one at a time, not in a batch,
    // so the nudge just opens the app. Tap-to-open only.
    [NotificationDescriptor(
      id: "habits.incomplete", sectionKey: "habits", title: "Habits reminder",
      priority: 20)]
  }

  static func evaluateNotification(_ descriptorID: String,
                                   context: ModelContext,
                                   now: Date) -> NotificationPlan? {
    guard descriptorID == "habits.incomplete" else { return nil }
    let today = SeptenaDate.today
    guard let day = ChecklistMirror.loadHabitsDay(context: context, date: today) else { return nil }

    let pending = day.grouped.values.flatMap { $0 }.filter { !$0.done && !$0.skipped }
    guard !pending.isEmpty else { return nil }   // all handled → suppress

    // Fire when the routine is *usually* wrapped up, learned from every
    // habit's completion times. Fallback: 20:00 (end of the active day).
    let states = (try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
      predicate: #Predicate { $0.done == true }
    ))) ?? []
    let dateTimes = states.compactMap { s -> (date: String, time: String)? in
      return (s.date, EventTimestamp.hhmm(from: s.occurredAt))
    }
    let minute = NextScoring.learnedLateMinute(dateTimes: dateTimes,
                                               today: today, fallback: 20 * 60)
    let n = pending.count
    let body = n == 1
      ? "1 habit left today — mark it if it’s done."
      : "\(n) habits left today — mark any you’ve done."
    return NotificationPlan(descriptorID: descriptorID, title: "Habits",
                            body: body, threadID: "habits", minuteOfDay: minute)
  }
}

/// Starter habit suggestion — `name`, `emoji`, `bucket` mirror the fields
/// `ChecklistMutator.createHabit(name:bucket:emoji:)` accepts.
private struct HabitStarter: Identifiable, Hashable {
  let id: String          // stable key for selection state, not the entity id
  let name: String
  let emoji: String
  let bucket: String      // "morning" | "anytime" | "evening"

  static let all: [HabitStarter] = [
    // Morning
    .init(id: "starter-hydrate",  name: "Hydrate",        emoji: "💧", bucket: "morning"),
    .init(id: "starter-run",      name: "Run",            emoji: "🏃", bucket: "morning"),
    .init(id: "starter-meditate", name: "Meditate",       emoji: "🧘", bucket: "morning"),
    .init(id: "starter-stretch",  name: "Stretch",        emoji: "🤸", bucket: "morning"),
    // Anytime
    .init(id: "starter-read",     name: "Read",           emoji: "📖", bucket: "anytime"),
    .init(id: "starter-walk",     name: "Walk outside",   emoji: "🚶", bucket: "anytime"),
    .init(id: "starter-journal",  name: "Journal",        emoji: "✍️", bucket: "anytime"),
    .init(id: "starter-language", name: "Language study", emoji: "🗣️", bucket: "anytime"),
    // Evening
    .init(id: "starter-phone-off", name: "Phone off",     emoji: "📵", bucket: "evening"),
    .init(id: "starter-reflect",   name: "Reflect on day", emoji: "📝", bucket: "evening"),
  ]
}

private struct HabitsOnboardingView: View {
  let complete: () -> Void
  @Environment(ChecklistMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @State private var selected: Set<String> = []
  /// Lowercased titles of habits the user already has. Built once on
  /// appear — onboarding is additive-only, so any starter whose name
  /// already exists is shown as "Already added" and can't be selected.
  @State private var existingTitles: Set<String> = []

  private var accent: Color { theme.color(for: "habits") }

  private func alreadyExists(_ starter: HabitStarter) -> Bool {
    existingTitles.contains(starter.name.lowercased())
  }

  private func loadExisting() {
    let rows = (try? modelContext.fetch(FetchDescriptor<HabitDefinitionEntity>())) ?? []
    existingTitles = Set(rows.map { $0.title.lowercased() })
  }

  private var grouped: [(String, [HabitStarter])] {
    let order = ["morning", "anytime", "evening"]
    return order.map { bucket in
      (bucket, HabitStarter.all.filter { $0.bucket == bucket })
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SectionOnboardingHero(
            sectionKey: "habits",
            title: "Habits",
            intro: "Track simple daily routines. Pick a few to get started — edit or delete anytime, or skip and add your own."
          )
          .onboardingHeroSection()
        }

        ForEach(grouped, id: \.0) { bucket, starters in
          Section(bucket.capitalized) {
            ForEach(starters) { starter in
              starterRow(starter)
            }
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
  private func starterRow(_ starter: HabitStarter) -> some View {
    let exists = alreadyExists(starter)
    let isSelected = selected.contains(starter.id)
    Button {
      guard !exists else { return }
      if isSelected { selected.remove(starter.id) }
      else          { selected.insert(starter.id) }
    } label: {
      HStack(spacing: 12) {
        Text(starter.emoji).font(.title3)
          .opacity(exists ? 0.4 : 1)
        Text(starter.name)
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
    selected.isEmpty ? String(localized: "Done") : String(localized: "Add \(selected.count) habits")
  }

  private func addAndFinish() {
    // Double-guard against duplicates in case the existing set changed
    // while the sheet was open (CK sync, multi-device). Additive only —
    // never overwrites or modifies an existing habit.
    let toAdd = HabitStarter.all.filter {
      selected.contains($0.id) && !alreadyExists($0)
    }
    for s in toAdd {
      mutator.createHabit(name: s.name, bucket: s.bucket, emoji: s.emoji)
    }
    complete()
  }
}

// Per-section settings shown in Settings → Habits. Just the Next-list
// carry-over toggle for now; per-device (@AppStorage), read by the Next
// feed's `habitsNow` filter. Default OFF — habits stay strict to their slot.
private struct HabitsDetailContent: View {
  @AppStorage(NextLinger.habitsKey) private var carryOver = NextLinger.habitsDefault

  var body: some View {
    Section {
      Toggle(isOn: $carryOver) {
        VStack(alignment: .leading, spacing: 1) {
          Text("Carry over missed habits")
          Text("Keep an undone habit on the Next list after its time of day, until you do it. Off shows each habit only during its slot.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Next list")
    }
  }
}

@MainActor func habitDefinitionExportDict(_ e: HabitDefinitionEntity) -> [String: Any] {
  compact([
    "id": e.id, "title": e.title, "emoji": e.emoji,
    "bucket": e.bucket, "sortIndex": e.sortIndex,
    "updatedAt": isoDate(e.updatedAt),
  ])
}

@MainActor func habitDayStateExportDict(_ e: HabitDayStateEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "habitID": e.habitID,
    "done": e.done, "skipped": e.skipped, "note": e.note,
    "time": EventTimestamp.hhmm(from: e.occurredAt),
    "updatedAt": isoDate(e.updatedAt),
  ])
}
