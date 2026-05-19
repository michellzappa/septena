import SwiftUI

// Time-of-day action suggestions for the Next view. Mirrors the webapp's
// `hooks/use-next-actions.ts` engine: for each contributing section (caffeine,
// cannabis, training, nutrition) we read the last ~14 days of history, find
// the user's median "first time" for that activity, and surface a card when
// `now >= usual - 45m` AND the activity hasn't happened yet today.
//
// Pure functions for the math (`timingScore`, `firstDailyTimes`, …) sit at
// the top so they're independently testable and trivially reusable when the
// data source eventually flips from REST to CloudKit. The view layer at the
// bottom only depends on `[NextSuggestion]` — swap the loader, keep the UI.

// MARK: - Suggestion model

struct NextSuggestion: Identifiable, Hashable {
  enum Kind: String, Hashable {
    case caffeine, cannabis, training, fastBreak

    /// Section accent key for `SectionTheme.color(for:)`.
    var sectionKey: String {
      switch self {
      case .caffeine:  return "caffeine"
      case .cannabis:  return "cannabis"
      case .training:  return "training"
      case .fastBreak: return "nutrition"
      }
    }
  }

  let id: String
  let kind: Kind
  let title: String
  let emoji: String?
  let detail: String
  let score: Double
  /// Minutes since midnight of when this action is "due". Used for the
  /// primary sort in the Now bucket — webapp sorts by time of day first,
  /// score only breaks ties when neither side has a time.
  let proposedMinutes: Int?
}

// MARK: - Math (pure)

enum NextScoring {
  /// `nowMinutes - usual` mapped to a -30…+30 ribbon centered on the usual
  /// time. Mirrors the webapp's `timingScore`: strong positive near the
  /// expected time, negative if we're well past or well before.
  static func timingScore(usual: Int?, nowMinutes: Int, isToday: Bool) -> Double {
    guard isToday, let usual else { return 0 }
    let diff = Double(nowMinutes - usual)
    if diff < -180 { return -30 }
    if diff < -90  { return -12 }
    if diff <= 90  { return 30 - abs(diff) / 6 }
    if diff <= 240 { return 10 }
    return -8
  }

  static func trainingUrgency(daysAgo: Int?) -> Double {
    guard let d = daysAgo else { return 32 }
    if d >= 5 { return 34 }
    if d >= 3 { return 24 }
    if d >= 2 { return 14 }
    return 0
  }

  static func median(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
  }

  /// "HH:MM" → minutes since midnight.
  static func parseHHMM(_ value: String?) -> Int? {
    guard let value, value.count >= 4 else { return nil }
    let parts = value.split(separator: ":")
    guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
    return h * 60 + m
  }

  /// First (earliest) entry-time per day across `items`, excluding `today`.
  /// Returns one minute-of-day per qualifying day, in arbitrary order — caller
  /// passes the result to `median()`.
  static func firstDailyTimes(dateTimes: [(date: String, time: String)],
                              beforeDay today: String) -> [Int] {
    var earliest: [String: Int] = [:]
    for entry in dateTimes where entry.date < today {
      guard let mins = parseHHMM(entry.time) else { continue }
      if let existing = earliest[entry.date] {
        if mins < existing { earliest[entry.date] = mins }
      } else {
        earliest[entry.date] = mins
      }
    }
    return Array(earliest.values)
  }

  static func relativeMinutes(target: Int, now: Int) -> String {
    let diff = target - now
    let abs = Swift.abs(diff)
    if abs < 5 { return "now" }
    let h = abs / 60
    let m = abs % 60
    let label = h == 0 ? "\(m)m" : (m == 0 ? "\(h)h" : "\(h)h \(m)m")
    return diff > 0 ? "in \(label)" : "\(label) ago"
  }
}

// MARK: - Session-type lookup

/// Map a `SuggestedWorkout.type` (e.g. "upper") to display label + emoji.
/// First consults the cached `[SessionTypeConfig]` (same cache the Settings /
/// Training screens use); falls back to a humanized type string + 🏋️ when the
/// cache is cold so the row still renders on first launch.
private func trainingDisplay(for type: String) -> (label: String, emoji: String) {
  if let types = ResponseCache.load([SessionTypeConfig].self, forKey: "settings.sessionTypes"),
     let hit = types.first(where: { $0.id == type }) {
    return (hit.label, hit.emoji ?? "🏋️")
  }
  return (type.prefix(1).uppercased() + type.dropFirst(), "🏋️")
}

// MARK: - Model

@MainActor
@Observable
final class NextSuggestionsModel {
  var suggestions: [NextSuggestion] = []
  var hasLoaded: Bool = false
  /// IDs the user dismissed this day. Hydrated from UserDefaults on load and
  /// scoped per-date so yesterday's skips don't follow you forward.
  var skipped: Set<String> = []

  private var today: String { SeptenaDate.today }

  func paintFromCache() {
    skipped = Self.loadSkips(date: today)
    hasLoaded = true
  }

  func load(client: SeptenaClient) async {
    let today = self.today
    let since14 = Self.daysAgoISO(14)
    let since30 = Self.daysAgoISO(30)

    async let caffeineHist = try? await client.caffeineEntries(days: 14)
    async let caffeineDay  = try? await client.caffeineDay(date: today)
    async let cannabisHist = try? await client.cannabisEntries(days: 14)
    async let cannabisDay  = try? await client.cannabisDay(date: today)
    async let nutrition    = try? await client.nutritionEntries(since: since14)
    async let training     = try? await client.trainingEntries(since: since30)
    async let workout      = try? await client.suggestedWorkout()
    async let settings     = try? await client.settings()

    let (caf, cafD, can, canD, nut, tr, sw, st) =
      await (caffeineHist, caffeineDay, cannabisHist, cannabisDay,
             nutrition, training, workout, settings)

    suggestions = Self.compute(
      today: today,
      isToday: true,
      caffeineHistory: caf?.entries ?? [],
      caffeineToday: cafD?.entries ?? [],
      cannabisHistory: can?.entries ?? [],
      cannabisToday: canD?.entries ?? [],
      nutrition: nut ?? [],
      training: tr ?? [],
      workout: sw?.suggested,
      workoutDaysAgo: sw?.daysAgo ?? [:],
      fastingTargetH: st?.targets?.fastingMaxH ?? 18,
      now: Date()
    )
    skipped = Self.loadSkips(date: today)
    hasLoaded = true
  }

  func toggleSkip(_ id: String) {
    Haptics.tick()
    let key = Self.skipKey(date: today)
    var arr = UserDefaults.standard.stringArray(forKey: key) ?? []
    if let i = arr.firstIndex(of: id) {
      arr.remove(at: i)
    } else {
      arr.append(id)
    }
    UserDefaults.standard.set(arr, forKey: key)
    skipped = Set(arr)
  }

  // MARK: Skips persistence

  private static func skipKey(date: String) -> String { "septena.next.skips.\(date)" }

  private static func loadSkips(date: String) -> Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: skipKey(date: date)) ?? [])
  }

  // MARK: Date helpers

  private static func daysAgoISO(_ days: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    return SeptenaDate.format(d) ?? SeptenaDate.today
  }

  // MARK: Compute (pure, takes everything it needs)

  static func compute(
    today: String,
    isToday: Bool,
    caffeineHistory: [CaffeineTimePoint],
    caffeineToday: [CaffeineEntry],
    cannabisHistory: [CannabisTimePoint],
    cannabisToday: [CannabisEntry],
    nutrition: [NutritionEntry],
    training: [ExerciseEntry],
    workout: SuggestedWorkout?,
    workoutDaysAgo: [String: Int],
    fastingTargetH: Double,
    now: Date
  ) -> [NextSuggestion] {
    let cal = Calendar.current
    let nowMinutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
    var out: [NextSuggestion] = []

    // Caffeine — first cup
    let firstCaffeineUsual = NextScoring.median(
      NextScoring.firstDailyTimes(
        dateTimes: caffeineHistory.map { (date: $0.date, time: $0.time) },
        beforeDay: today
      )
    )
    if caffeineToday.isEmpty, isToday,
       let usual = firstCaffeineUsual,
       nowMinutes >= usual - 45 {
      out.append(NextSuggestion(
        id: "caffeine:first",
        kind: .caffeine,
        title: "Log caffeine",
        emoji: "☕️",
        detail: "Usually \(NextScoring.relativeMinutes(target: usual, now: nowMinutes))",
        score: 34 + NextScoring.timingScore(usual: usual, nowMinutes: nowMinutes, isToday: isToday),
        proposedMinutes: usual
      ))
    }

    // Cannabis — first session
    let firstCannabisUsual = NextScoring.median(
      NextScoring.firstDailyTimes(
        dateTimes: cannabisHistory.map { (date: $0.date, time: $0.time) },
        beforeDay: today
      )
    )
    if cannabisToday.isEmpty, isToday,
       let usual = firstCannabisUsual,
       nowMinutes >= usual - 45 {
      out.append(NextSuggestion(
        id: "cannabis:first",
        kind: .cannabis,
        title: "Log cannabis",
        emoji: "🌿",
        detail: "Usually \(NextScoring.relativeMinutes(target: usual, now: nowMinutes))",
        score: 32 + NextScoring.timingScore(usual: usual, nowMinutes: nowMinutes, isToday: isToday),
        proposedMinutes: usual
      ))
    }

    // Training — only when we haven't trained today and the server has a
    // suggested workout type. The webapp combines a base score, the
    // "days since last of this type" urgency, and the usual-time bonus.
    let trainedToday = training.contains { $0.date == today }
    if !trainedToday, isToday, let workout {
      let usualTraining = NextScoring.median(
        training
          .filter { $0.date < today }
          .compactMap { entry -> Int? in
            guard let ended = entry.concludedAt else { return nil }
            // concludedAt is an ISO timestamp; the HH:MM substring sits at offset 11..16
            guard ended.count >= 16 else { return nil }
            let hhmm = String(ended.dropFirst(11).prefix(5))
            return NextScoring.parseHHMM(hhmm)
          }
      )
      let suggestedGap = workoutDaysAgo[workout.type]
      let dueNow = suggestedGap == nil || (suggestedGap ?? 0) >= 2 || usualTraining == nil
      let display = trainingDisplay(for: workout.type)
      let lastLabel: String = {
        switch suggestedGap {
        case .none:    return "never"
        case .some(0): return "today"
        case .some(1): return "yesterday"
        case .some(let d): return "\(d)d ago"
        }
      }()
      // Only surface if it's actually due now (the webapp also keeps it in the
      // Later bucket when usual-time is much further out; we collapse to "now"
      // here since v1 doesn't render a Later strip).
      if dueNow {
        out.append(NextSuggestion(
          id: "training:suggested",
          kind: .training,
          title: display.label,
          emoji: display.emoji,
          detail: "Last \(lastLabel)",
          score: 78
            + NextScoring.trainingUrgency(daysAgo: suggestedGap)
            + NextScoring.timingScore(usual: usualTraining, nowMinutes: nowMinutes, isToday: isToday),
          proposedMinutes: usualTraining
        ))
      }
    }

    // Nutrition — break the fast. Triggers once `fastingTargetH` has elapsed
    // since the last logged meal (and the user hasn't logged anything today).
    let mealsSorted = nutrition.sorted { ($0.date + $0.time) < ($1.date + $1.time) }
    let hasMealToday = mealsSorted.contains { $0.date == today }
    if !hasMealToday, isToday, let lastMeal = mealsSorted.last {
      let lastTs = isoTimestamp(date: lastMeal.date, time: lastMeal.time)
      let breakTs = lastTs.addingTimeInterval(fastingTargetH * 3600)
      let startOfToday = cal.startOfDay(for: now)
      let breakMinutes = Int(breakTs.timeIntervalSince(startOfToday) / 60)
      let fastedMin = max(0, Int(now.timeIntervalSince(lastTs) / 60))
      let fastedH = fastedMin / 60
      let fastedM = fastedMin % 60
      let past = nowMinutes >= breakMinutes
      let detail: String = past
        ? "Fasted \(fastedH)h\(String(format: "%02d", fastedM)) — break it"
        : "Break fast \(NextScoring.relativeMinutes(target: breakMinutes, now: nowMinutes)) (\(Int(fastingTargetH))h)"
      let timing = past ? 30 : NextScoring.timingScore(usual: breakMinutes, nowMinutes: nowMinutes, isToday: isToday)
      out.append(NextSuggestion(
        id: "nutrition:first-meal",
        kind: .fastBreak,
        title: "Log meal",
        emoji: "🍽️",
        detail: detail,
        score: 38 + timing,
        proposedMinutes: breakMinutes
      ))
    }

    // Webapp sorts by proposedMinutes asc, falling back to score desc when one
    // side has no time. Keeps "due now" items in time order, then the rest.
    return out.sorted { a, b in
      switch (a.proposedMinutes, b.proposedMinutes) {
      case let (.some(am), .some(bm)): return am < bm
      case (.some, .none): return true
      case (.none, .some): return false
      case (.none, .none): return a.score > b.score
      }
    }
  }
}

/// Build a `Date` from "YYYY-MM-DD" + "HH:MM" in the device's current zone.
/// Used by the fasting-break math; we want wall-clock semantics, not UTC.
private func isoTimestamp(date: String, time: String) -> Date {
  var c = DateComponents()
  let dParts = date.split(separator: "-")
  let tParts = time.split(separator: ":")
  if dParts.count == 3 {
    c.year = Int(dParts[0]); c.month = Int(dParts[1]); c.day = Int(dParts[2])
  }
  if tParts.count >= 2 {
    c.hour = Int(tParts[0]); c.minute = Int(tParts[1])
  }
  return Calendar.current.date(from: c) ?? Date()
}

// MARK: - View

/// Strip rendered at the top of the Next screen, above chores/habits/etc.
/// One row per visible suggestion; tap routes to the matching Add Info page
/// (or the Training session sheet). Long-press skips for the rest of today.
struct NextSuggestionsSection: View {
  var model: NextSuggestionsModel
  @Environment(SectionTheme.self) private var theme
  @Environment(NavigationState.self) private var nav

  private var visible: [NextSuggestion] {
    model.suggestions.filter { !model.skipped.contains($0.id) }
  }

  var body: some View {
    let items = visible
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        Text("Suggested")
          .font(.septenaSectionTitle)
          .foregroundStyle(Theme.inkSecondary)
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, Theme.sectionSpacing)
          .padding(.bottom, 6)
        ForEach(items) { suggestion in
          NextSuggestionRow(
            suggestion: suggestion,
            model: model,
            nav: nav,
            tint: theme.color(for: suggestion.kind.sectionKey)
          )
        }
      }
    }
  }
}

private struct NextSuggestionRow: View {
  let suggestion: NextSuggestion
  var model: NextSuggestionsModel
  let nav: NavigationState
  let tint: Color

  var body: some View {
    Button {
      Haptics.tap()
      perform()
    } label: {
      HStack(spacing: Theme.iconTextGap) {
        // Filled tinted circle with the suggestion's emoji — mirrors the
        // section-accent dot the existing log rows wear, but bigger so the
        // glyph reads as the row's verb at a glance.
        ZStack {
          Circle().fill(tint.opacity(0.18))
          Text(suggestion.emoji ?? "•").font(.body)
        }
        .frame(width: 26, height: 26)

        VStack(alignment: .leading, spacing: 2) {
          Text(suggestion.title)
            .font(.septenaTaskTitle)
            .foregroundStyle(Theme.inkPrimary)
          Text(suggestion.detail)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.vertical, Theme.rowVPadding + 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button {
        model.toggleSkip(suggestion.id)
      } label: {
        Label("Skip today", systemImage: "forward.end")
      }
    }
  }

  private func perform() {
    switch suggestion.kind {
    case .caffeine:
      nav.addInfoRequestedSection = .caffeine
      nav.showAddInfo = true
    case .cannabis:
      nav.addInfoRequestedSection = .cannabis
      nav.showAddInfo = true
    case .fastBreak:
      nav.addInfoRequestedSection = .nutrition
      nav.showAddInfo = true
    case .training:
      // TrainingSessionView reads the active draft out of TrainingDraftStore;
      // routing the suggested type is handled by the existing Start flow.
      nav.showTrainingSession = true
    }
  }
}
