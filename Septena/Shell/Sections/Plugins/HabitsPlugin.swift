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
    let buckets = ["morning", "anytime", "evening"]
    let groups = buckets.map { bucket in
      StarterGroup(id: bucket, header: bucket.capitalized,
                   items: HabitStarter.all.filter { $0.bucket == bucket })
    }
    return AnyView(SectionOnboarding(
      sectionKey: "habits",
      intro: "Track simple daily routines. Pick a few to get started — edit or delete anytime, or skip and add your own.",
      nounPlural: String(localized: "habits"),
      footer: String(localized: "Pick a few to start — edit, skip, or add your own anytime."),
      groups: groups,
      glyph: { .emoji($0.emoji) },
      primary: { $0.name },
      secondary: { $0.blurb },
      existsKey: { AnyHashable($0.name.lowercased()) },
      loadExistingKeys: {
        await MirrorReader.shared.read { ctx in
          Set(((try? ctx.fetch(FetchDescriptor<HabitDefinitionEntity>())) ?? [])
            .map { AnyHashable($0.title.lowercased()) })
        }
      },
      add: { items in
        let mutator = SeptenaServices.shared.checklistMutator
        for s in items { mutator.createHabit(name: s.name, bucket: s.bucket, emoji: s.emoji) }
      },
      complete: complete
    ))
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
              inputs: "required: title, bucket (morning|afternoon|evening|anytime) · optional: emoji"),
        SectionSkill.Tool("habits_update", "Update fields",
              inputs: "required: id · optional: title, bucket (morning|afternoon|evening|anytime), emoji"),
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

  /// Per-habit weekly-completion metric key: "habits.<habitID>.done_week".
  /// Lets a goal target ONE habit ("do Surya 7 days/week") rather than only
  /// the two aggregate metrics. One per definition, so a heavily-used habit
  /// can be promoted to a measured, pinnable goal.
  private static let perHabitPrefix = "habits."
  private static let perHabitSuffix = ".done_week"
  private static func perHabitKey(_ habitID: String) -> String {
    "\(perHabitPrefix)\(habitID)\(perHabitSuffix)"
  }

  static func aimMetrics(context: ModelContext) -> [GoalMetric] {
    var metrics = aimMetrics
    let defs = (try? context.fetch(FetchDescriptor<HabitDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    for d in defs {
      metrics.append(GoalMetric(
        key: perHabitKey(d.id),
        label: "\(d.title) — days done (this week)",
        sectionKey: "habits",
        window: "calendarWeek",
        unitLabel: "days"))
    }
    return metrics
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext, now: Date) -> Double? {
    guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window, now: now)
    else { return 0 }
    // Per-habit weekly completion: distinct days this week where THIS habit
    // was marked done. (Prefix+suffix match, so it can't collide with the two
    // aggregate keys above, which don't end in ".done_week".)
    if metric.key.hasPrefix(perHabitPrefix), metric.key.hasSuffix(perHabitSuffix) {
      let habitID = String(metric.key.dropFirst(perHabitPrefix.count)
                                     .dropLast(perHabitSuffix.count))
      let descriptor = FetchDescriptor<HabitDayStateEntity>(
        predicate: #Predicate {
          $0.habitID == habitID && $0.date >= startStr && $0.date <= endStr && $0.done == true
        }
      )
      let rows = (try? context.fetch(descriptor)) ?? []
      return Double(Set(rows.map { $0.date }).count)
    }
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
      id: "habits.incomplete", sectionKey: "habits", title: String(localized: "Habits reminder", comment: "Scheduled notification name"),
      priority: 20),
     // "One day from a streak rung" — fires only on the day a milestone is a
     // single log away and that log is still pending. Nudge to mark, not nag
     // to do; outranks the generic incomplete nudge when both qualify.
     NotificationDescriptor(
      id: "habits.streakRung", sectionKey: "habits", title: String(localized: "Streak milestone reminder", comment: "Scheduled notification name"),
      priority: 25)]
  }

  static func evaluateNotification(_ descriptorID: String,
                                   context: ModelContext,
                                   now: Date) -> NotificationPlan? {
    if descriptorID == "habits.streakRung" {
      return streakRungPlan(context: context, now: now)
    }
    let today = SeptenaDate.format(now) ?? SeptenaDate.today
    guard descriptorID == "habits.incomplete" else { return nil }
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
    let body = String(localized: "\(n) habits left today", comment: "Habit reminder body (plural)")
    return NotificationPlan(descriptorID: descriptorID, title: String(localized: "Habits"),
                            body: body, threadID: "habits", minuteOfDay: minute)
  }

  /// A habit is one day from an unearned streak rung (current streak ==
  /// rung − 1) and today's log is still pending. When several qualify, the
  /// biggest rung wins — "one day from 100" beats "one day from 7".
  private static func streakRungPlan(context: ModelContext,
                                     now: Date) -> NotificationPlan? {
    let today = SeptenaDate.format(now) ?? SeptenaDate.today
    guard let day = ChecklistMirror.loadHabitsDay(context: context, date: today) else { return nil }
    let pending = day.grouped.values.flatMap { $0 }.filter { !$0.done && !$0.skipped }
    guard !pending.isEmpty else { return nil }

    let earned = Set((((try? context.fetch(FetchDescriptor<GoalMilestoneEntity>())) ?? []))
      .filter { $0.kind == "streak" }
      .map(\.id))

    var best: (habit: String, rung: Int)? = nil
    for item in pending {
      let dates = ChecklistMirror.habitCompletionDates(context: context, habitID: item.id)
      let streak = ConsistencyStats.make(dates: dates, today: today).currentStreak
      guard let rung = MilestoneMutator.streakLadder.first(where: { $0 == streak + 1 }),
            !earned.contains("habit:\(item.id)|streak:\(rung)") else { continue }
      if rung > (best?.rung ?? 0) { best = (item.name, rung) }
    }
    guard let best else { return nil }

    // Same learned wrap-up hour as the incomplete nudge — this isn't a
    // second ping time, it's a better reason at the same moment.
    let states = (try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
      predicate: #Predicate { $0.done == true }
    ))) ?? []
    let dateTimes = states.map { ($0.date, EventTimestamp.hhmm(from: $0.occurredAt)) }
    let minute = NextScoring.learnedLateMinute(dateTimes: dateTimes,
                                               today: today, fallback: 20 * 60)
    let body = String(localized: "One day from a \(best.rung)-day streak — log \(best.habit) to lock it in.",
                      comment: "Streak milestone reminder body")
    return NotificationPlan(descriptorID: "habits.streakRung",
                            title: String(localized: "Habits"),
                            body: body, threadID: "habits", minuteOfDay: minute)
  }
}

/// Starter habit suggestion — `name`, `emoji`, `bucket` mirror the fields
/// `ChecklistMutator.createHabit(name:bucket:emoji:)` accepts.
private struct HabitStarter: Identifiable, Hashable {
  let id: String          // stable key for selection state, not the entity id
  let name: String
  let emoji: String
  let bucket: String      // "morning" | "afternoon" | "evening" | "anytime"
  let blurb: String       // one-line descriptor shown under the name

  static let all: [HabitStarter] = [
    // Morning
    .init(id: "starter-hydrate",  name: "Hydrate",        emoji: "💧", bucket: "morning", blurb: "A glass of water to start"),
    .init(id: "starter-run",      name: "Run",            emoji: "🏃", bucket: "morning", blurb: "A morning run, any distance"),
    .init(id: "starter-meditate", name: "Meditate",       emoji: "🧘", bucket: "morning", blurb: "A few quiet minutes"),
    .init(id: "starter-stretch",  name: "Stretch",        emoji: "🤸", bucket: "morning", blurb: "Loosen up for the day"),
    // Anytime
    .init(id: "starter-read",     name: "Read",           emoji: "📖", bucket: "anytime", blurb: "Pages before screens"),
    .init(id: "starter-walk",     name: "Walk outside",   emoji: "🚶", bucket: "anytime", blurb: "Get out and move"),
    .init(id: "starter-journal",  name: "Journal",        emoji: "✍️", bucket: "anytime", blurb: "Jot down a thought"),
    .init(id: "starter-language", name: "Language study", emoji: "🗣️", bucket: "anytime", blurb: "Practice a new language"),
    // Evening
    .init(id: "starter-phone-off", name: "Phone off",     emoji: "📵", bucket: "evening", blurb: "Unplug before bed"),
    .init(id: "starter-reflect",   name: "Reflect on day", emoji: "📝", bucket: "evening", blurb: "Look back on the day"),
  ]
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
