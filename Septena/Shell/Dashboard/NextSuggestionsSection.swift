import SwiftUI
import SwiftData

// Time-of-day action suggestions for the Next view. Mirrors the webapp's
// `hooks/use-next-actions.ts` engine: for each contributing section (intake,
// training, nutrition) we read the last ~14 days of history, find
// the user's median "first time" for that activity, and surface a card when
// `now >= usual - 45m` AND the activity hasn't happened yet today.
//
// Pure functions for the math (`timingScore`, `firstDailyTimes`, …) sit at
// the top so they're independently testable and trivially reusable when the
// data source eventually flips from REST to CloudKit. The view layer at the
// bottom only depends on `[NextSuggestion]` — swap the loader, keep the UI.

// MARK: - Suggestion model

struct NextSuggestion: Identifiable, Hashable, Sendable {
  enum Kind: String, Hashable, Sendable {
    case training, fastBreak, mood, intake

    /// Section accent key for `SectionTheme.color(for:)`.
    var sectionKey: String {
      switch self {
      case .training:  return "training"
      case .fastBreak: return "nutrition"
      case .mood:      return "mood"
      case .intake:    return "intake"
      }
    }
  }

  let id: String
  let kind: Kind
  let title: String
  let emoji: String?
  /// SF Symbol name. When set, the row renders this instead of `emoji` —
  /// training rows pass `SessionKind.icon` here so yoga shows
  /// `figure.yoga` rather than the legacy `SessionTypeConfig.emoji`.
  let symbol: String?
  let detail: String
  let score: Double
  /// Minutes since midnight of when this action is "due". Used for the
  /// primary sort in the Now bucket — webapp sorts by time of day first,
  /// score only breaks ties when neither side has a time.
  let proposedMinutes: Int?
  /// For `.intake` nudges: the tracker id + its container-aware quick-log
  /// choices, so the row logs inline (the watch-style pick) instead of
  /// navigating. Empty for every other kind.
  var intakeKindID: String? = nil
  var intakeChoices: [SuggestionBlocks.Choice] = []
  /// For `.intake` nudges: the tracker's own accent (hex/hsl token). The
  /// `intake` host section has no single palette color, so the row tints
  /// from the per-kind color and only falls back to the section key when
  /// this is nil. Without it caffeine/tea/… all render the gray fallback.
  var kindColor: String? = nil
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

  /// Latest entry-time per day across `items`, excluding `today` — the mirror
  /// of `firstDailyTimes`. Feeds the learned "curfew": the time of day past
  /// which you typically stop, so cadence suggestions don't nag into the night.
  static func lastDailyTimes(dateTimes: [(date: String, time: String)],
                             beforeDay today: String) -> [Int] {
    var latest: [String: Int] = [:]
    for entry in dateTimes where entry.date < today {
      guard let mins = parseHHMM(entry.time) else { continue }
      if let existing = latest[entry.date] {
        if mins > existing { latest[entry.date] = mins }
      } else {
        latest[entry.date] = mins
      }
    }
    return Array(latest.values)
  }

  /// The user's typical first-time-of-day (minutes since midnight) for an
  /// activity, learned from history — or `fallback` when there aren't enough
  /// settled days to trust the rhythm. Wraps `firstDailyTimes` + `median`;
  /// reused by `LocalNotificationScheduler` to pick a nudge's fire-time so
  /// the "mark what you did" prompt lands around when the user usually logs.
  static func learnedFirstMinute(dateTimes: [(date: String, time: String)],
                                 today: String,
                                 fallback: Int,
                                 minSamples: Int = 3) -> Int {
    let times = firstDailyTimes(dateTimes: dateTimes, beforeDay: today)
    guard times.count >= minSamples, let m = median(times) else { return fallback }
    return m
  }

  /// Linear-interpolated percentile of a minute-of-day sample. `p` in 0…1.
  static func percentile(_ values: [Int], _ p: Double) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    if sorted.count == 1 { return sorted[0] }
    let rank = max(0, min(Double(sorted.count - 1), p * Double(sorted.count - 1)))
    let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
    if lo == hi { return sorted[lo] }
    let frac = rank - Double(lo)
    return Int((Double(sorted[lo]) * (1 - frac) + Double(sorted[hi]) * frac).rounded())
  }

  /// A "you're running late" fire-time: the high-percentile (default 80th) of
  /// the *latest* daily times for an activity — i.e. the hour by which you've
  /// usually wrapped it up. Firing here (not at the median) means the nudge
  /// stays silent on the ~80% of days you finish on schedule and only speaks
  /// up when you've genuinely drifted past your window. Falls back to a fixed
  /// anchor until there's enough history to trust.
  static func learnedLateMinute(dateTimes: [(date: String, time: String)],
                                today: String,
                                fallback: Int,
                                p: Double = 0.8,
                                minSamples: Int = 3) -> Int {
    let times = lastDailyTimes(dateTimes: dateTimes, beforeDay: today)
    guard times.count >= minSamples, let m = percentile(times, p) else { return fallback }
    return m
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

// MARK: - Cadence (pure, unit-agnostic)

/// Learned rhythm of a repeating action: the median interval between
/// consecutive occurrences plus the typical number per cycle. Deliberately
/// unit-agnostic — caffeine feeds it **minutes within a day** (gap between
/// cups), a future chore path feeds it **days between completions**. The same
/// predictor, `next(after:)`, serves both; only the unit of `medianGap`
/// changes. Built from history via `withinDay` / `acrossDays`.
struct Cadence: Hashable {
  /// Median gap between consecutive occurrences, in the caller's unit
  /// (minutes for within-day, days for across-day).
  let medianGap: Int
  /// Typical occurrences per cycle — cups/day for caffeine, 1 for a chore
  /// (it completes once per cycle). Used as the count ceiling.
  let typicalCount: Int
  /// Number of gaps observed. A confidence proxy: a single coincidental pair
  /// shouldn't drive a suggestion.
  let sampleSize: Int

  /// True once we've seen enough repeats to trust the rhythm.
  var isConfident: Bool { sampleSize >= 3 }

  /// Predicted next occurrence given the most recent one, same unit as `last`.
  func next(after last: Int) -> Int { last + medianGap }

  /// Within-day rhythm: gap between consecutive same-day events (minutes) and
  /// the typical event count per active day. `today` is excluded so the model
  /// learns only from settled days.
  static func withinDay(dateTimes: [(date: String, time: String)],
                        before today: String) -> Cadence? {
    var perDay: [String: [Int]] = [:]
    for e in dateTimes where e.date < today {
      guard let m = NextScoring.parseHHMM(e.time) else { continue }
      perDay[e.date, default: []].append(m)
    }
    guard !perDay.isEmpty else { return nil }

    var gaps: [Int] = []
    for mins in perDay.values {
      let sorted = mins.sorted()
      guard sorted.count >= 2 else { continue }
      for i in 1..<sorted.count { gaps.append(sorted[i] - sorted[i - 1]) }
    }
    guard let gap = NextScoring.median(gaps), gap > 0 else { return nil }
    let count = NextScoring.median(perDay.values.map(\.count)) ?? 1
    return Cadence(medianGap: gap, typicalCount: max(count, 1), sampleSize: gaps.count)
  }

  /// Across-day rhythm: gap in **days** between consecutive completion dates.
  /// `typicalCount` is 1 — a chore fires once per cycle. This is the seam for
  /// a future cadence-learned chore suggestion (resurface ~N days after the
  /// last completion); it is intentionally not yet wired into `compute`.
  static func acrossDays(dates: [String]) -> Cadence? {
    let ordinals = Array(Set(dates.compactMap(dayOrdinal))).sorted()
    guard ordinals.count >= 2 else { return nil }
    var gaps: [Int] = []
    for i in 1..<ordinals.count { gaps.append(ordinals[i] - ordinals[i - 1]) }
    guard let gap = NextScoring.median(gaps), gap > 0 else { return nil }
    return Cadence(medianGap: gap, typicalCount: 1, sampleSize: gaps.count)
  }

  /// "YYYY-MM-DD" → a serial day number via era-day ordinality (DST-safe).
  static func dayOrdinal(_ iso: String) -> Int? {
    let p = iso.split(separator: "-")
    guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
    var c = DateComponents(); c.year = y; c.month = m; c.day = d
    guard let date = Calendar.current.date(from: c) else { return nil }
    return Calendar.current.ordinality(of: .day, in: .era, for: date)
  }
}

// MARK: - Session-type lookup

/// Map a `SuggestedWorkout.type` (e.g. "upper", "yoga") to display label +
/// SF Symbol. Symbol comes from `SessionKind.icon` so mobility routines
/// render as `figure.yoga`, cardio as `figure.run`, etc. Falls back to the
/// id-based default when the routine cache is cold.
private func trainingDisplay(for type: String) -> (label: String, symbol: String) {
  if let types = ResponseCache.load([SessionTypeConfig].self, forKey: "settings.sessionTypes"),
     let hit = types.first(where: { $0.id == type }) {
    return (hit.label, hit.kind.icon)
  }
  let label = type.prefix(1).uppercased() + type.dropFirst()
  return (label, SessionKind.defaulted(for: type).icon)
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

  private var cachedToday: String = ""

  func paintFromCache(today: String) {
    cachedToday = today
    skipped = Self.loadSkips(date: today)
    hasLoaded = true
  }

  func load(now: Date) async {
    // Run the history scan + scorer on the MirrorReader's background actor so
    // the read (14–30 days of nutrition/training/intake/mood) never hitches the
    // Next tab. `computeAll` is `nonisolated` so it can execute off the main
    // actor; `[NextSuggestion]` is `Sendable` so it crosses back cleanly.
    let todayDate = SeptenaDate.format(now) ?? cachedToday
    cachedToday = todayDate
    let (computed, remoteSkips) = await MirrorReader.shared.read { ctx -> ([NextSuggestion], Set<String>) in
      let suggestions = Self.computeAll(context: ctx, now: now)
      let remote = Set(SettingsMirror.loadSettings(context: ctx)?.nextSkips?[todayDate] ?? [])
      return (suggestions, remote)
    }
    // Apply the user's Next ▸ Suggestions prefs (master switch + per-kind
    // opt-out, device-local). Filtered here rather than inside `computeAll`
    // so the watch snapshot — which shares the scorer — is unaffected until
    // its own parity pass lands.
    suggestions = computed.filter { NextSuggestionsPrefs.allows(rawKind: $0.kind.rawValue) }
    // Union local (fast, device-only) with remote (synced via AppSettings).
    skipped = Self.loadSkips(date: todayDate).union(remoteSkips)
    hasLoaded = true
  }

  /// Gather ~14–30 days of history + today's state from the local mirror and
  /// run the pure scorer. Shared by the Next view and the watch snapshot
  /// publisher so both surface the identical suggestions.
  nonisolated static func computeAll(context ctx: ModelContext, now: Date) -> [NextSuggestion] {
    let today = SeptenaDate.format(now) ?? ""
    let since14 = daysAgoISO(14, now: now)
    let since30 = daysAgoISO(30, now: now)

    let nut = ChecklistMirror.loadNutritionEntries(context: ctx, since: since14)
    let tr: [ExerciseEntry]? = ChecklistMirror.loadTrainingEntries(context: ctx, since: since30)
    let sw: SuggestedWorkoutResponse? = ChecklistMirror.loadSuggestedWorkout(context: ctx, today: today, now: now)
    let st: AppSettings? = SettingsMirror.loadSettings(context: ctx)

    // Mood is a per-daypart check-in (morning / afternoon / evening), not a
    // learned-time activity: surface it whenever the bucket we're currently
    // in has no entry yet. So it reappears up to three times a day, once per
    // bucket, and goes quiet the moment you log — see the `mood` block in
    // `compute`. Gated on the section being enabled so a hidden Mood section
    // never nudges.
    let moodEnabled = SettingsMirror.loadSections(context: ctx)
      .first { $0.key == "mood" }?.isEnabled ?? false
    let moodBucket = DayBucket.from(date: now)
    let moodLoggedThisBucket = ChecklistMirror.loadMoodDay(context: ctx, date: today)
      .byBucket[moodBucket.rawValue] != nil

    var out = compute(
      today: today,
      isToday: true,
      nutrition: nut,
      training: tr ?? [],
      workout: sw?.suggested,
      workoutDaysAgo: sw?.daysAgo ?? [:],
      fastingTargetH: st?.targets?.fastingMaxH ?? 18,
      moodEnabled: moodEnabled,
      moodLoggedThisBucket: moodLoggedThisBucket,
      now: now
    )
    // Per-tracker intake nudges — the generic successor to the old caffeine
    // per-substance first/next rules. Reads each active
    // kind's learned rhythm and carries the container-aware choices so the row
    // logs inline. Lives here (not in pure `compute`) because the kind list is
    // dynamic and needs the live store.
    out += intakeSuggestions(context: ctx, today: today, now: now)
    return out
  }

  /// One nudge per active intake tracker whose learned first-use time (or
  /// within-day cadence, once logged) is due. Container kinds carry their
  /// Continue/New/method choices; simple kinds carry their method list.
  nonisolated static func intakeSuggestions(context ctx: ModelContext, today: String, now: Date) -> [NextSuggestion] {
    let kinds = ((try? ctx.fetch(FetchDescriptor<IntakeKindEntity>())) ?? [])
      .filter { $0.archivedAt == nil }
    guard !kinds.isEmpty else { return [] }
    let since14 = daysAgoISO(14, now: now)
    let recent = (try? ctx.fetch(FetchDescriptor<IntakeEventEntity>(
      predicate: #Predicate { $0.date >= since14 }))) ?? []
    guard !recent.isEmpty else { return [] }
    let byKind = Dictionary(grouping: recent, by: \.kindID)

    // The objective's cap (the daily "limit" target) lives on a linked Goal —
    // fetch once, key by the kind's metricKey prefix. See IntakeReader.objectiveGoalInfo.
    let goals = ((try? ctx.fetch(FetchDescriptor<GoalEntity>())) ?? [])
    func objectiveGoal(_ kindID: String) -> (target: Double, weekly: Bool)? {
      guard let g = goals.first(where: { $0.metricKey?.hasPrefix("intake.\(kindID).") == true })
      else { return nil }
      return (g.metricTarget ?? 0, g.metricKey?.hasSuffix(".count_week") == true)
    }

    let cal = Calendar.current
    let nowMinutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
    var out: [NextSuggestion] = []

    for kind in kinds {
      let evs = byKind[kind.id] ?? []
      guard !evs.isEmpty else { continue }
      // Quit: never proactively suggest a dose — not even the first of the day.
      let objective = kind.objective
      if objective == "quit" { continue }
      let history = evs.map { (date: $0.date, time: EventTimestamp.hhmm(from: $0.occurredAt)) }
      let todays = evs.filter { $0.date == today }

      // Container-aware choices, computed once for whichever nudge fires.
      let methods = kind.methods.map {
        ConsumableContainer.Method(token: $0.token, label: $0.label,
                                   emoji: $0.emoji, usesContainer: $0.usesContainer)
      }
      let lastCount: Int? = {
        guard let token = kind.methods.first(where: { $0.usesContainer })?.token else { return nil }
        return todays.filter { $0.method == token }.max(by: { $0.occurredAt < $1.occurredAt })?.count
      }()
      let choices = ConsumableContainer.choices(
        lastCount: lastCount, containerCap: kind.containerCap,
        containerNoun: kind.containerNoun ?? "container",
        countNoun: kind.countNoun ?? "use", methods: methods)

      func nudge(idSuffix: String, due: Int, baseScore: Double, detail: String) -> NextSuggestion {
        NextSuggestion(
          id: "intake:\(kind.id):\(idSuffix)", kind: .intake,
          title: "Log \(kind.name)", emoji: nil, symbol: kind.symbol,
          detail: detail,
          score: baseScore + NextScoring.timingScore(usual: due, nowMinutes: nowMinutes, isToday: true),
          proposedMinutes: due,
          intakeKindID: kind.id, intakeChoices: choices, kindColor: kind.color)
      }

      // First use of the day.
      let firstUsual = NextScoring.median(
        NextScoring.firstDailyTimes(dateTimes: history, beforeDay: today))
      if todays.isEmpty, let usual = firstUsual, nowMinutes >= usual - 45 {
        out.append(nudge(idSuffix: "first", due: usual, baseScore: 33,
                         detail: "Usually \(NextScoring.relativeMinutes(target: usual, now: nowMinutes))"))
        continue   // never the first AND next nudge at once
      }

      // Reduce: keep the gentle first-of-day cue above, but never prompt the
      // *next* dose — that would push consumption back up toward the old habit.
      if objective == "reduce" { continue }

      // Next use — learned within-day rhythm, capped by typical count + curfew.
      let cadence = Cadence.withinDay(dateTimes: history, before: today)
      let curfew = NextScoring.median(
        NextScoring.lastDailyTimes(dateTimes: history, beforeDay: today))
      if !todays.isEmpty,
         let cadence, cadence.isConfident,
         let lastToday = todays.compactMap({ NextScoring.parseHHMM(EventTimestamp.hhmm(from: $0.occurredAt)) }).max() {
        // Cap to the learned daily count, tightened to the user's limit when one
        // is set as a *daily* cap — never suggest a use at or over the limit.
        var cap = cadence.typicalCount
        if objective == "limit", let g = objectiveGoal(kind.id), !g.weekly, g.target >= 1 {
          cap = min(cap, Int(g.target))
        }
        guard todays.count < cap else { continue }
        let next = cadence.next(after: lastToday)
        let beforeCurfew = curfew.map { next <= $0 } ?? true
        if beforeCurfew, nowMinutes >= next - 45 {
          out.append(nudge(idSuffix: "next", due: next, baseScore: 29,
                           detail: "\(todays.count + 1) today · usually \(NextScoring.relativeMinutes(target: next, now: nowMinutes))"))
        }
      }
    }
    return out
  }

  /// Suggestions minus the ones the user skipped today — what actually renders.
  static func visibleSuggestions(context ctx: ModelContext, now: Date) -> [NextSuggestion] {
    let today = SeptenaDate.format(now) ?? ""
    let skips = loadSkips(date: today)
    return computeAll(context: ctx, now: now).filter { !skips.contains($0.id) }
  }

  func toggleSkip(_ id: String, context: ModelContext) {
    Haptics.tick()
    let date = cachedToday
    let key = Self.skipKey(date: date)
    var arr = UserDefaults.standard.stringArray(forKey: key) ?? []
    if let i = arr.firstIndex(of: id) {
      arr.remove(at: i)
    } else {
      arr.append(id)
    }
    UserDefaults.standard.set(arr, forKey: key)
    skipped = Set(arr)
    Self.pushSkipsToSettings(ids: arr, date: date, context: context)
  }

  // MARK: Skips persistence

  private static func skipKey(date: String) -> String { "septena.next.skips.\(date)" }

  private static func loadSkips(date: String) -> Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: skipKey(date: date)) ?? [])
  }

  /// Write today's skip list into AppSettings so other devices receive it via
  /// CloudKit. Union-safe: incoming syncs are merged in `load()`. Prunes any
  /// stale date keys before writing to keep the payload small.
  private static func pushSkipsToSettings(ids: [String], date: String, context: ModelContext) {
    var settings = SettingsMirror.loadSettings(context: context)
      ?? AppSettings()
    var skips = (settings.nextSkips ?? [:]).filter { $0.key == date }
    skips[date] = ids
    settings.nextSkips = skips
    SettingsMirror.upsert(settings: settings, context: context,
                          engine: SeptenaServices.shared.ckEngine)
  }

  // MARK: Date helpers

  nonisolated private static func daysAgoISO(_ days: Int, now: Date) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
    return SeptenaDate.format(d) ?? ""
  }

  // MARK: Compute (pure, takes everything it needs)

  nonisolated static func compute(
    today: String,
    isToday: Bool,
    nutrition: [NutritionEntry],
    training: [ExerciseEntry],
    workout: SuggestedWorkout?,
    workoutDaysAgo: [String: Int],
    fastingTargetH: Double,
    moodEnabled: Bool = false,
    moodLoggedThisBucket: Bool = false,
    now: Date
  ) -> [NextSuggestion] {
    let cal = Calendar.current
    let nowMinutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
    var out: [NextSuggestion] = []

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
          emoji: nil,
          symbol: display.symbol,
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
        symbol: nil,
        detail: detail,
        score: 38 + timing,
        proposedMinutes: breakMinutes
      ))
    }

    // Mood — daypart check-in. Unlike the activity nudges above, this isn't
    // learned from a median time: the gate is simply "the bucket we're in now
    // has no entry yet." That makes it a recurring, low-friction prompt that
    // surfaces once per morning / afternoon / evening and clears the instant
    // you check in. No `proposedMinutes` (it isn't due at a clock time — it's
    // due whenever you next look), so it sorts among the untimed nudges by
    // score, sitting gently below anything that's genuinely time-critical.
    if moodEnabled, isToday, !moodLoggedThisBucket {
      let bucket = DayBucket.from(date: now)
      out.append(NextSuggestion(
        id: "mood:\(bucket.rawValue)",
        kind: .mood,
        title: "How are you feeling?",
        emoji: nil,
        symbol: "face.smiling",
        detail: "\(bucket.title) check-in",
        score: 20,
        proposedMinutes: nil
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
  /// Page-level `List(selection:)` — drives row highlight + keyboard cursor.
  var selection: Set<String> = []
  @Environment(SectionTheme.self) private var theme
  @Environment(NavigationState.self) private var nav

  private var visible: [NextSuggestion] {
    model.suggestions.filter { !model.skipped.contains($0.id) }
  }

  var body: some View {
    let items = visible
    if !items.isEmpty {
      groupedListSection(header: { sectionGroupHeader("Suggested") }) {
        ForEach(Array(items.enumerated()), id: \.element.id) { idx, suggestion in
          let tag = NextRowTag.suggestion(suggestion.id)
          NextSuggestionRow(
            suggestion: suggestion,
            model: model,
            nav: nav,
            tint: suggestion.kindColor.flatMap(AdaptiveColor.adaptive)
              ?? theme.color(for: suggestion.kind.sectionKey)
          )
          .septenaNextRow(tag: tag, isSelected: selection.contains(tag),
                          index: idx, count: items.count)
        }
      }
    }
  }
}

/// Internal (not private): Septask's embedded Next fold renders the same rows
/// under the Tasks card chrome (see SeptaskNextFold).
struct NextSuggestionRow: View {
  let suggestion: NextSuggestion
  var model: NextSuggestionsModel
  let nav: NavigationState
  let tint: Color

  @Environment(\.modelContext) private var modelContext
  @Environment(\.rowHInset) private var rowHInset
  @Environment(DayClock.self) private var clock
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  var body: some View {
    Group {
      // Intake nudges log inline — tapping reveals the tracker's container-
      // aware choices (Continue · use N / New / methods) and writes on pick,
      // the same affordance the watch wrist offers. Everything else navigates.
      if suggestion.kind == .intake, !suggestion.intakeChoices.isEmpty {
        Menu {
          ForEach(suggestion.intakeChoices, id: \.value) { choice in
            Button {
              commitIntake(choice.value)
            } label: {
              if let e = choice.emoji, !e.isEmpty {
                Label { Text(choice.label) } icon: { Text(e) }
              } else {
                Label(choice.label, systemImage: choice.symbol ?? "plus")
              }
            }
          }
        } label: { rowLabel }
        .buttonStyle(.plain)
        .focusable(false)
      } else {
        Button {
          Haptics.tap()
          perform()
        } label: { rowLabel }
        .buttonStyle(.plain)
        .focusable(false)
      }
    }
    .contextMenu {
      Button {
        model.toggleSkip(suggestion.id, context: modelContext)
      } label: {
        Label("Skip today", systemImage: "forward.end")
      }
    }
  }

  private var rowLabel: some View {
    HStack(spacing: Theme.iconTextGap) {
      // Filled tinted circle with the suggestion's emoji — mirrors the
      // section-accent dot the existing log rows wear, but bigger so the
      // glyph reads as the row's verb at a glance.
      ZStack {
        Circle().fill(tint.opacity(0.18))
        if let symbol = suggestion.symbol {
          Image(systemName: symbol)
            .scaledFont(size: 13, weight: .semibold)
            .foregroundStyle(tint)
        } else {
          Text(suggestion.emoji ?? "•").font(.body)
        }
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
      Image(systemName: suggestion.kind == .intake ? "plus.circle" : "chevron.right")
        .font(.septenaMeta)
        .foregroundStyle(Theme.inkSecondary)
    }
    .padding(.horizontal, rowHInset)
    .padding(.vertical, Theme.rowVPadding + 2)
    .contentShape(Rectangle())
  }

  private func commitIntake(_ value: String) {
    guard let kindID = suggestion.intakeKindID else { return }
    Haptics.tap()
    IntakeNudgeLog.commit(kindID: kindID, value: value, today: clock.today, logCommit: logCommit)
    // Optimistically hide this nudge; the dataChanged recompute reconciles
    // (a still-due "next" nudge has its own id and can reappear).
    model.toggleSkip(suggestion.id, context: modelContext)
  }

  private func perform() {
    switch suggestion.kind {
    case .fastBreak:
      nav.presentAddInfo(section: .nutrition)
    case .mood:
      // Mood isn't in the AddInfo palette (its check-in is a bespoke
      // two-step quadrant picker, not a search-to-log row), so route to
      // the dedicated AddMoodPage sheet mounted at the tab root.
      nav.showMoodCheckin = true
    case .training:
      // TrainingSessionView reads the active draft out of TrainingDraftStore;
      // routing the suggested type is handled by the existing Start flow.
      nav.showTrainingSession = true
    case .intake:
      break   // handled inline by the Menu above; never routed through perform
    }
  }
}

/// Inline commit for an intake nudge — mirrors `IntakeKindPageView`'s fast
/// path so the wrist/menu/nudge all write identically. Resolves the live kind
/// by id, parses the choice token, and logs through the mutator inside a
/// quiet `SectionLog` — a light tick + announce, no fullscreen flourish
/// (intake is a high-frequency log, kept off the canvas like the page itself).
@MainActor
private enum IntakeNudgeLog {
  static func commit(kindID: String, value: String, today: String, logCommit: LogCommitCenter?) {
    let ctx = LocalStore.shared.container.mainContext
    guard let kind = ((try? ctx.fetch(FetchDescriptor<IntakeKindEntity>(
      predicate: #Predicate { $0.id == kindID }))) ?? []).first else { return }
    let (token, count) = ConsumableContainer.parse(value: value)
    let method = kind.methods.first { $0.token == token }
    let showsAmount = kind.doseStyle == "amount" || kind.doseStyle == "both"
    let amount = showsAmount ? method?.defaultAmount : nil
    SectionLog.quietLog(announce: "Logged \(kind.name).") {
      _ = SeptenaServices.shared.intakeMutator.addEntry(
        kindID: kindID, date: today,
        time: SeptenaDate.nowHHMM, method: token, amount: amount, count: count)
    }
  }
}
