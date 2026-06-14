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
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest {
    // Force-unwrap is safe: manifest entry for "mood" ships in the
    // catalog. A compile-time check would be nicer; will switch to a
    // strongly-typed manifest reference once every section is migrated.
    SectionManifest.byKey["mood"]!
  }

  static func destinationView() -> AnyView? { AnyView(MoodDestinationView()) }

  static func detailPaneContent() -> AnyView? { AnyView(MoodDetailContent()) }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionOnboarding(
      sectionKey: "mood",
      intro: "How you feel, plotted on the affect circumplex: pleasant ↔ unpleasant, calm ↔ energetic. Three check-ins a day is a good cadence — more or fewer is fine.",
      bullets: [
        .init("Tap a quadrant", "Pick the feeling that matches, then a word for it. That's the whole log.", icon: "hand.tap"),
        .init("Morning / afternoon / evening", "Suggested buckets, but timestamps are exact — log whenever it fits.", icon: "clock"),
        .init("Notes when useful", "Add free-text context when something specific is shaping the feeling.", icon: "text.bubble"),
      ],
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

  // MARK: - Notifications
  //
  // Mood's unit is the daypart check-in (morning / afternoon / evening), so
  // the nudge tracks the *current* daypart: it fires only when this part of
  // the day has no check-in yet, and goes quiet the moment you log one. The
  // scheduler keeps a single pending request per descriptor, so at most one
  // mood nudge is ever queued — as the day advances, reconcile re-arms it for
  // whichever daypart you're now in. Fire-time is the hour you usually check
  // in for that daypart (learned), falling back to near the end of its
  // window so you get the whole stretch to log naturally first.

  static var notificationDescriptors: [NotificationDescriptor] {
    [NotificationDescriptor(
      id: "mood.checkin", sectionKey: "mood", title: "Mood check-in",
      priority: 7)]
  }

  static func evaluateNotification(_ descriptorID: String,
                                   context: ModelContext,
                                   now: Date) -> NotificationPlan? {
    guard descriptorID == "mood.checkin" else { return nil }
    let today = SeptenaDate.today
    let bucket = DayBucket.from(date: now)
    let day = ChecklistMirror.loadMoodDay(context: context, date: today)
    // Already checked in for the daypart we're in → nothing to nudge.
    guard day.byBucket[bucket.rawValue] == nil else { return nil }

    // Learn from past check-ins *in this same daypart* so morning fires near
    // your usual morning time, etc. Fallback: just before the window closes.
    let bucketRaw = bucket.rawValue
    let history = (try? context.fetch(FetchDescriptor<MoodEventEntity>(
      predicate: #Predicate { $0.bucket == bucketRaw }
    ))) ?? []
    let dateTimes = history.map { (date: $0.date, time: EventTimestamp.hhmm(from: $0.occurredAt)) }
    let fallbackHour: Int
    switch bucket {
    case .morning:   fallbackHour = max(DayBucket.cutoffs.morningEnd - 1, 8)
    case .afternoon: fallbackHour = max(DayBucket.cutoffs.afternoonEnd - 1, DayBucket.cutoffs.morningEnd)
    case .evening:   fallbackHour = 20   // evening runs to midnight; keep it before quiet hours
    }
    let minute = NextScoring.learnedLateMinute(dateTimes: dateTimes,
                                               today: today, fallback: fallbackHour * 60)
    let body = "Haven’t checked in this \(bucket.rawValue) yet — tap to note how you’re feeling."
    return NotificationPlan(descriptorID: descriptorID, title: "Mood",
                            body: body, threadID: "mood", minuteOfDay: minute)
  }
}

private struct MoodDetailContent: View {
  var body: some View {
    HKSyncSection(label: "Write to Apple Health",
                  icon: "heart.text.square",
                  kind: .mood)
  }
}
