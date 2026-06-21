import CloudKit
import SwiftData
import WidgetKit

/// Publishes a single, tiny CloudKit record holding the watch's entire "Next"
/// payload so the watch can do one O(1) `record(for:)` read instead of replaying
/// the whole zone. Written to the **default** private zone so it stays clear of
/// CKSyncEngine's `septena-v1` zone.
///
/// The payload is the full day's open checklist (`loadNextItems` with no bucket
/// filter) — every habit is tagged with its bucket in `subtitle`, so the watch
/// filters to the current time-of-day bucket itself and the snapshot stays valid
/// all day. It's rewritten on every checklist mutation and on app foreground.
enum WatchSnapshotPublisher {
  static let recordType = "WatchSnapshot"
  static let recordName = "watch-next-snapshot"
  private static let containerID = "iCloud.com.septena.cloud"

  /// The in-flight debounced publish, if any. Cancelled and rescheduled by
  /// each `schedule` call so a burst collapses to one build + write.
  @MainActor private static var pending: Task<Void, Never>?

  /// `.septenaDataChanged` / `.septenaTasksChanged` observers, retained for the
  /// process lifetime. Non-nil once `install` has run, which also makes the
  /// install idempotent.
  @MainActor private static var observers: [NSObjectProtocol]?

  /// The sections whose data actually composes the Next snapshot, so a change to
  /// an unrelated section (goals, gut, symptoms, medications, groceries, …)
  /// doesn't pay for a full rebuild. This is every input `publish` reads:
  /// the completable Next members (chores/habits/supplements — tasks ride the
  /// separate `.septenaTasksChanged`) plus the four suggestion sources
  /// (`NextSuggestionsModel.Kind`: training, fastBreak→nutrition, mood, intake)
  /// and the meal/ring data. Keep in sync when adding a Next member or a
  /// suggestion source — an omission here is exactly what left training/mood
  /// stale on the watch before. Unscoped posts (CloudKit batch arrival, section
  /// colour / settings edits) bypass this filter and always republish.
  ///
  /// medications / symptoms / groceries are here not as Next members but because
  /// their *catalogs* ride the snapshot for the watch's + capture menu — so a
  /// med/symptom edit, or a grocery flipping in/out of stock, must republish to
  /// keep the wrist menu current.
  private static let snapshotSections: Set<String> =
    ["chores", "habits", "supplements", "training", "nutrition", "mood", "intake",
     "medications", "symptoms", "groceries"]

  /// Coalesce a burst of mutations (ticking five habits in a row) into a single
  /// snapshot build + CloudKit write. The full payload is a snapshot, so only
  /// the last build in a burst matters — the intermediates would each rebuild
  /// the entire Next feed (a `NextFeed.flat` that runs the suggestions engine
  /// over 14–30 days of history) and fire a CloudKit read-modify-write, all
  /// wasted. Mutation paths and app-foreground route here instead of calling
  /// `publish` directly.
  @MainActor
  static func schedule(context: ModelContext, date: String = SeptenaDate.today) {
    pending?.cancel()
    pending = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1200))
      guard !Task.isCancelled else { return }
      pending = nil
      publish(context: context, date: date)
    }
  }

  /// The single choke point that keeps the watch / widget snapshot in sync.
  ///
  /// Every mutator already posts `.septenaDataChanged` (scoped) or
  /// `.septenaTasksChanged`, and CloudKit batch arrival posts them unscoped, so
  /// observing those two notifications here republishes on *any* change that can
  /// affect Next — without each mutator having to remember to call `schedule`.
  /// That omission is what used to leave the watch nagging "do cardio" / "log
  /// your mood" after the user already had: training, nutrition, mood and intake
  /// only refresh the snapshot through this observer. Idempotent.
  @MainActor
  static func install(context: ModelContext) {
    guard observers == nil else { return }
    let center = NotificationCenter.default
    let data = center.addObserver(
      forName: .septenaDataChanged, object: nil, queue: .main
    ) { note in
      // Only sections that feed the snapshot; unscoped posts (nil) always pass.
      guard note.affectsAnySection(of: snapshotSections) else { return }
      MainActor.assumeIsolated { schedule(context: context) }
    }
    let tasks = center.addObserver(
      forName: .septenaTasksChanged, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { schedule(context: context) }
    }
    // Republish on the midnight rollover too. The snapshot carries day-keyed
    // values (today's intake tally, macro rings, the Next feed's today bucket),
    // but a bare day change posts no data/task notification — so without this
    // the widgets and watch complications keep rendering yesterday's counts
    // until the next mutation or app-foreground. `schedule` re-reads
    // `SeptenaDate.today`, so the rebuilt snapshot is keyed to the new day.
    let dayChange = center.addObserver(
      forName: .NSCalendarDayChanged, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { schedule(context: context) }
    }
    observers = [data, tasks, dayChange]
  }

  /// Compute on the main actor (SwiftData read), then save off-main. Best-effort:
  /// a failed write is retried by the next mutation / foreground. Prefer
  /// `schedule` from mutation paths so rapid edits don't each pay the full cost.
  @MainActor
  static func publish(context: ModelContext, date: String = SeptenaDate.today) {
    // The full Next feed (suggestions + tasks/chores/habits/supplements in the
    // user's saved section order) comes from the one shared builder, so the
    // watch snapshot can never diverge from the app's Next list.
    let items = NextFeed.flat(context: context, date: date)
    // Carry this phone's current bucket cutoffs in the payload so the watch
    // applies the same morning/afternoon/evening boundaries. The watch has its
    // own separate app-group container — the phone's DayBucket.saveCutoffs()
    // write never reaches it — so without this the watch always uses factory
    // defaults (morning < 12, afternoon < 17) regardless of user settings.
    let cutoffs = DayBucket.cutoffs
    // Carry this phone's current linger prefs in the payload so the watch and
    // widget filter to the current bucket exactly as this phone's Next list does
    // (App Group defaults are per-device, so they can't reach the watch otherwise).
    let defaults = UserDefaults.standard
    let lingerHabits = defaults.object(forKey: NextLinger.habitsKey) as? Bool
      ?? NextLinger.habitsDefault
    let lingerSupplements = defaults.object(forKey: NextLinger.supplementsKey) as? Bool
      ?? NextLinger.supplementsDefault
    // The user's actual (possibly customized) section accents, so the watch
    // tints its Next group rules to match the phone instead of a default
    // palette. Falls back to the shipped baseline when nothing's mirrored yet.
    let sections = SettingsMirror.loadSections(context: context)
    let configs = sections.isEmpty ? SectionTheme.defaultPalette : sections
    let sectionColors = Dictionary(configs.map { ($0.key, $0.color) },
                                   uniquingKeysWith: { a, _ in a })
    // Enabled intake trackers, so the wrist + menu always offers every tracker
    // with container-aware choices.
    let kindRows = ((try? context.fetch(FetchDescriptor<IntakeKindEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
      .filter { $0.archivedAt == nil }
    var intakeKinds: [IntakeKindWire] = []
    // Today's per-tracker tally for the wrist's Intakes summary page ("what I've
    // had today"). Built from the same `todaysEvents` fetch as the + menu's
    // container math, so it costs nothing extra. One row per tracker with at
    // least one event today, in the user's saved order.
    var intakeToday: [IntakeTodayWire] = []
    if !kindRows.isEmpty {
      let todaysEvents = (try? context.fetch(FetchDescriptor<IntakeEventEntity>(
        predicate: #Predicate { $0.date == date }))) ?? []
      intakeToday = kindRows.compactMap { k in
        let n = todaysEvents.filter { $0.kindID == k.id }.count
        guard n > 0 else { return nil }
        var detail: String? = nil
        if let noun = k.countNoun, !noun.isEmpty {
          detail = "\(n) \(noun)\(n == 1 ? "" : "s")"
        }
        return IntakeTodayWire(id: k.id, name: k.name, symbol: k.symbol,
                               color: k.color, count: n, detail: detail)
      }
      intakeKinds = kindRows.map { k in
        var last: Int? = nil
        if let token = k.methods.first(where: { $0.usesContainer })?.token {
          last = todaysEvents
            .filter { $0.kindID == k.id && $0.method == token }
            .max(by: { $0.occurredAt < $1.occurredAt })?.count
        }
        return IntakeKindWire(
          id: k.id, name: k.name, symbol: k.symbol, color: k.color,
          countNoun: k.countNoun, containerNoun: k.containerNoun,
          containerCap: k.containerCap, lastContainerCount: last,
          showsAmount: k.doseStyle == "amount" || k.doseStyle == "both",
          methods: k.methods.map {
            .init(token: $0.token, label: $0.label, emoji: $0.emoji,
                  defaultAmount: $0.defaultAmount, usesContainer: $0.usesContainer)
          })
      }
    }
    // The user's most-eaten meals, so the wrist + menu can re-log a real meal
    // (foods + macros) with one tap — frequency-then-recency ranked, capped to
    // a wrist-sized list.
    let topMeals = buildTopMeals(context: context)
    // Today's macro totals-so-far vs targets, for the watch macro-ring
    // complication. Nil when nutrition is untracked / no goals, so the wire
    // stays additive.
    let nutritionRings = buildNutritionRings(context: context, date: date)
    // This week's training (trailing 7 days) vs targets, for the watch's
    // training-ring complication. Present whenever a target exists (they always
    // have built-in defaults), so it mirrors the macro rings' availability.
    let trainingRings = buildTrainingRings(context: context)
    // The live fast, if the user tracks fasting and one is running — so the watch
    // macro complication morphs into a fasting face like the phone tile. Nil
    // otherwise, so the wrist keeps showing macros.
    let fasting = buildFasting(context: context)
    // The medications / symptoms / groceries capture catalogs, each gated on the
    // section being enabled so the wrist + menu is dynamic — disabling a section
    // on the phone drops its rows from the watch on the next publish.
    let enabledKeys = Set(sections.filter { $0.isEnabled }.map { $0.key })
    let medications = enabledKeys.contains("medications")
      ? buildMedications(context: context) : []
    let symptoms = enabledKeys.contains("symptoms")
      ? buildSymptoms(context: context) : []
    let groceries = enabledKeys.contains("groceries")
      ? buildGroceries(context: context) : []
    // Recent meal / training rows for the watch summary pages' freshness lists.
    // Built only when the rings rode along (same data presence), so a page that
    // shows nothing carries no list either.
    let recentNutrition = nutritionRings != nil ? buildRecentNutrition(context: context) : []
    let recentTraining = trainingRings != nil ? buildRecentTraining(context: context) : []
    let response = NextItemsResponse(date: date, bucket: "", items: items,
                                     morningCutoff: cutoffs.morningEnd,
                                     afternoonCutoff: cutoffs.afternoonEnd,
                                     lingerHabits: lingerHabits,
                                     lingerSupplements: lingerSupplements,
                                     sectionColors: sectionColors,
                                     intakeKinds: intakeKinds.isEmpty ? nil : intakeKinds,
                                     topMeals: topMeals.isEmpty ? nil : topMeals,
                                     nutritionRings: nutritionRings,
                                     trainingRings: trainingRings,
                                     fasting: fasting,
                                     medications: medications.isEmpty ? nil : medications,
                                     symptoms: symptoms.isEmpty ? nil : symptoms,
                                     groceries: groceries.isEmpty ? nil : groceries,
                                     enabledSections: enabledKeys.isEmpty ? nil : Array(enabledKeys),
                                     recentNutrition: recentNutrition.isEmpty ? nil : recentNutrition,
                                     recentTraining: recentTraining.isEmpty ? nil : recentTraining,
                                     intakeToday: intakeToday.isEmpty ? nil : intakeToday)
    guard let payload = try? JSONEncoder().encode(response) else { return }

    // The time-wheel/day-dial widget is DISABLED for now (its glass face can't
    // render in a widget snapshot — see `SeptenaWidgetsBundle`), so we skip
    // building + publishing its `RhythmWire` blob: no point paying the
    // per-mutation build cost or registering the `WatchSnapshot.rhythmPayload`
    // field in Production for a feature nothing reads. The builder
    // (`RhythmSnapshotBuilder`) is kept; re-enable by restoring the block below
    // and `record["rhythmPayload"]` in `save`, plus the bundle line.
    //
    //   let todayStart = SeptenaDate.parse(date).map { Calendar.current.startOfDay(for: $0) }
    //     ?? Calendar.current.startOfDay(for: Date())
    //   let rhythm = RhythmSnapshotBuilder.build(context: context, sections: configs,
    //                                            todayStart: todayStart, windowDays: 1)
    //   let rhythmPayload = try? JSONEncoder().encode(rhythm)

    // Nudge the iOS "Next" home/lock-screen widget to re-read the snapshot. Same
    // trigger as the watch complication's reload — every checklist edit and app
    // foreground flows through here. The kind string matches `NextWidget.kind`
    // in the SeptenaWidgets target (separate module, so it can't be referenced
    // directly). No-op on platforms without the widget.
    #if os(iOS)
    WidgetCenter.shared.reloadTimelines(ofKind: "NextWidget")
    #endif

    Task.detached(priority: .utility) {
      await save(payload: payload, date: date)
    }
  }

  // MARK: - Top meals (wrist quick-add)

  /// Wrist quick-add list cap and lookback window. Bounded so the debounced
  /// per-mutation snapshot build stays cheap.
  private static let topMealsCap = 50
  private static let topMealsWindowDays = 120

  /// The user's most-eaten meals for the wrist quick-add, frequency- then
  /// recency-ranked, capped to `topMealsCap`. Mirrors the phone's
  /// `allDistinctMeals` (the Nutrition "+" meal search): group by a normalized
  /// food signature, keep the most-recent instance as the template, exclude the
  /// macro-free water marker (hydration has its own quick-log).
  @MainActor
  private static func buildTopMeals(context: ModelContext) -> [MealWire] {
    let since = SeptenaDate.format(
      Calendar.current.date(byAdding: .day, value: -topMealsWindowDays, to: Date()))
    let entries = ChecklistMirror.loadNutritionEntries(context: context, since: since)

    func signature(_ e: NutritionEntry) -> String {
      e.foods
        .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }

    var groups: [String: [NutritionEntry]] = [:]
    for e in entries {
      guard let first = e.foods.first, !first.isEmpty else { continue }
      // The macro-free water marker is hydration, not a meal — it has its own
      // wrist quick-log (`SuggestionBlocks` hydration).
      if e.foods == ["Water"] { continue }
      groups[signature(e), default: []].append(e)
    }

    // (wire, date, time) so the rank can break frequency ties by recency
    // without recomputing the template's timestamp.
    let ranked = groups.compactMap { sig, items -> (MealWire, String, String)? in
      guard let t = items.max(by: { ($0.date, $0.time) < ($1.date, $1.time) })
      else { return nil }
      let wire = MealWire(
        id: sig, emoji: t.emoji, foods: t.foods, count: items.count,
        proteinG: t.proteinG, fatG: t.fatG, carbsG: t.carbsG, kcal: t.kcal,
        fiberG: t.fiberG, sugarG: t.sugarG, saturatedFatG: t.saturatedFatG,
        alcoholG: t.alcoholG, sodiumMg: t.sodiumMg, cholesterolMg: t.cholesterolMg,
        potassiumMg: t.potassiumMg)
      return (wire, t.date, t.time)
    }
    .sorted { a, b in
      if a.0.count != b.0.count { return a.0.count > b.0.count }
      return (a.1, a.2) > (b.1, b.2)
    }

    return ranked.prefix(topMealsCap).map(\.0)
  }

  // MARK: - Macro rings (wrist nutrition complication)

  /// Macro key → its goal metric key, mirroring the app's `NutritionTargets`
  /// (which lives in the app target, out of SeptenaCore's reach). Kept in the
  /// canonical ring order: kcal, protein, carbs, fat, fiber.
  private static let macroOrder: [(key: String, metricKey: String)] = [
    ("kcal",    "nutrition.kcal_sum"),
    ("protein", "nutrition.protein_sum"),
    ("carbs",   "nutrition.carbs_sum"),
    ("fat",     "nutrition.fat_sum"),
    ("fiber",   "nutrition.fiber_sum"),
  ]

  /// Today's macro totals-so-far vs targets for the watch's macro-ring
  /// complication. Sums today's `NutritionEntry` rows directly (robust whether
  /// or not the daily-summary entity has recomputed yet), and reads each macro's
  /// target from its range goal, falling back to the legacy `MacrosConfig`.
  /// Returns nil when no macro has either data or a target, so an untracked user
  /// carries nothing on the wire.
  @MainActor
  private static func buildNutritionRings(context: ModelContext, date: String)
    -> NutritionRingsWire? {
    let entries = ChecklistMirror.loadNutritionEntries(context: context, since: date)
      .filter { $0.date == date }

    // Per-macro running totals so far today.
    let totals: [String: Double] = [
      "kcal":    entries.reduce(0) { $0 + $1.kcal },
      "protein": entries.reduce(0) { $0 + $1.proteinG },
      "carbs":   entries.reduce(0) { $0 + $1.carbsG },
      "fat":     entries.reduce(0) { $0 + $1.fatG },
      "fiber":   entries.reduce(0) { $0 + ($1.fiberG ?? 0) },
    ]

    // Targets: range goals first (the modern source), legacy MacrosConfig as a
    // fallback so users who never moved off the old config still get rings.
    let goals = LocalCache.goals(in: context)
    let legacy = NutritionPrefs.loadMacrosConfig()
    func goalFor(_ key: String, metricKey: String) -> Double? {
      if let g = goals.first(where: { $0.metricKey == metricKey }),
         let target = g.metricTargetUpper ?? g.metricTarget, target > 0 {
        return target
      }
      let range: MacroRange?
      switch key {
      case "kcal":    range = legacy?.kcal
      case "protein": range = legacy?.protein
      case "carbs":   range = legacy?.carbs
      case "fat":     range = legacy?.fat
      case "fiber":   range = legacy?.fiber
      default:        range = nil
      }
      return range.map { $0.max }
    }

    // Each macro's authored color, resolved exactly as the Nutrition section
    // does (`NutritionDestinationView.color(for:)`): the user's per-tile override
    // else the `MacroCatalog` default — so the wrist ring matches the tile color
    // on the phone. The catalog id == our ring key for these five.
    let tiles = MacroCatalog.reconcile(
      SettingsMirror.loadSettings(context: context)?.nutrition?.macroTiles
        ?? MacroCatalog.defaultTilePrefs())
    func colorFor(_ key: String) -> String? {
      tiles.first(where: { $0.id == key })?.colorHex
        ?? MacroCatalog.byID[key]?.defaultColorHex
    }

    let rings = macroOrder.map { macro in
      RingMetricWire(key: macro.key,
                     value: totals[macro.key] ?? 0,
                     goal: goalFor(macro.key, metricKey: macro.metricKey),
                     colorHex: colorFor(macro.key))
    }
    // Nothing logged and no target anywhere → don't bother the wire.
    guard rings.contains(where: { $0.value > 0 || $0.goal != nil }) else { return nil }
    return NutritionRingsWire(rings: rings)
  }

  // MARK: - Recent logs (wrist summary-page freshness lists)

  /// How many recent rows to carry per summary page, and how far back to look.
  /// Small — these ride the snapshot on every mutation and only exist so the user
  /// can eyeball that the latest log reached the wrist.
  private static let recentLogCap = 4
  private static let recentLogWindowDays = 3

  /// A short, already-formatted "when" label for a recent row: the wall-clock
  /// "HH:mm" for today, else the friendly day prefixed ("Yesterday 14:30").
  private static func recentWhen(date: String, time: String) -> String {
    let hm = String(time.prefix(5))
    guard date != SeptenaDate.today else { return hm }
    let day = SeptenaDate.friendlyLabel(date)
    return hm.isEmpty ? day : "\(day) \(hm)"
  }

  /// The newest few logged meals (last `recentLogWindowDays`, newest first), so
  /// the watch's Macros page can list them under the rings as a freshness check.
  /// `loadNutritionEntries` already sorts newest-first by `loggedAt`.
  @MainActor
  private static func buildRecentNutrition(context: ModelContext) -> [RecentLogWire] {
    let since = SeptenaDate.format(
      Calendar.current.date(byAdding: .day, value: -recentLogWindowDays, to: Date()))
    let entries = ChecklistMirror.loadNutritionEntries(context: context, since: since)
      .filter { $0.foods != ["Water"] }   // hydration isn't a meal
      .prefix(recentLogCap)
    return entries.map { e in
      RecentLogWire(
        id: e.file,
        emoji: e.emoji,
        title: e.foods.first ?? "Meal",
        detail: "\(Int(e.kcal.rounded())) kcal",
        when: recentWhen(date: e.date, time: e.time))
    }
  }

  /// The newest few logged training entries (this trailing week, newest first),
  /// listed under the rings on the watch's training summary page.
  @MainActor
  private static func buildRecentTraining(context: ModelContext) -> [RecentLogWire] {
    let entries = TrainingMetrics.entriesThisWeek(context: context)
      .sorted { $0.occurredAt > $1.occurredAt }
      .prefix(recentLogCap)
    return entries.map { e in
      RecentLogWire(
        id: e.id,
        title: e.exercise,
        detail: trainingSummary(e),
        when: recentWhen(date: e.date, time: trainingTime(e)))
    }
  }

  /// "3×8 · 80kg" for a strength set, "30 min" / "5.0 km" for cardio — a compact
  /// one-line readout of what was logged. Metric units (the wrist carries no unit
  /// preference; the summary pages already render metric values).
  private static func trainingSummary(_ e: ExerciseEntryEntity) -> String? {
    var parts: [String] = []
    if let sets = e.sets, !sets.isEmpty, let reps = e.reps, !reps.isEmpty {
      parts.append("\(sets)×\(reps)")
    }
    if let w = e.weight, w > 0 { parts.append("\(Int(w.rounded()))kg") }
    if let mins = e.durationMin, mins > 0 { parts.append("\(Int(mins.rounded())) min") }
    if let m = e.distanceM, m > 0 { parts.append(String(format: "%.1f km", m / 1000)) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// "HH:mm" for a training entry from its canonical instant (no separate time
  /// string on the entity), falling back to empty for pre-migration rows.
  private static func trainingTime(_ e: ExerciseEntryEntity) -> String {
    guard e.occurredAt != .distantPast else { return "" }
    return recentTimeFormatter.string(from: e.occurredAt)
  }

  private static let recentTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
  }()

  // MARK: - Training rings (wrist training complication)

  /// This week's (trailing-7-day) strength / cardio / session totals vs targets.
  /// Values + targets come from `TrainingMetrics`; targets prefer a real goal and
  /// fall back to the built-in defaults (12 hard sets, 150 cardio min, 4 sessions).
  /// Strength volume is `sets × difficulty weight` (hard/max = 1, moderate =
  /// 0.5); cardio is summed `durationMin`; a session is a distinct training day.
  /// Present whenever there's progress or a target (targets always have built-in
  /// defaults), so it stays available like the macro rings.
  @MainActor
  private static func buildTrainingRings(context: ModelContext) -> TrainingRingsWire? {
    // Values + targets both come from `TrainingMetrics` so the wrist matches the
    // in-app strength/cardio cards and the Goals bars exactly. Each target
    // prefers a real goal (hard_sets_week / cardio_minutes_week / session_count)
    // and falls back to the built-in default when the user set none.
    let entries = TrainingMetrics.entriesThisWeek(context: context)
    let band    = TrainingMetrics.hardSetsBand(context: context)

    let rings = [
      RingMetricWire(key: "strength",
                     value: TrainingMetrics.hardSets(entries),
                     goal: band.target),
      RingMetricWire(key: "cardio",
                     value: TrainingMetrics.cardioMinutes(entries),
                     goal: TrainingMetrics.cardioMinutesTarget(context: context)),
      RingMetricWire(key: "sessions",
                     value: TrainingMetrics.sessionCount(entries),
                     goal: TrainingMetrics.sessionTarget(context: context)),
    ]
    // Publish whenever there's progress OR a target — mirroring
    // `buildNutritionRings`. Training targets always carry a built-in default, so
    // this keeps the wrist training complication and the Next-list "Training"
    // summary available even on a week with nothing logged yet (empty rings
    // toward the goal), matching how macros always show once a target exists.
    guard rings.contains(where: { $0.value > 0 || $0.goal != nil }) else { return nil }
    return TrainingRingsWire(rings: rings)
  }

  // MARK: - Fasting (wrist macro complication morph)

  /// The phone-only "Track fasting" preference key. Mirrors
  /// `SettingsKey.nutritionTrackFasting`, which lives in the app target out of
  /// SeptenaCore's reach; both read `UserDefaults.standard`, so the raw key is
  /// the contract. When off, the wrist always shows macros, never a fast.
  private static let trackFastingDefaultsKey = "septena.nutrition.trackFasting"

  /// The last fast we published this process, kept so a transient empty read
  /// can't blank the wrist mid-fast (see `buildFasting`). Reset to nil whenever a
  /// *real* read says the user isn't fasting, so breaking a fast clears it at once.
  @MainActor private static var lastFasting: FastingWire?

  /// The live fast for the watch macro complication — present only when the user
  /// tracks fasting *and* a fast is currently running, so the complication morphs
  /// into a fasting face exactly as the phone's Nutrition tile does
  /// (`WeekDashboardView.nutritionDomainData`). Same `computeFastingState` inputs
  /// (from the shared stats builder, scanning just today + yesterday — all the
  /// live state needs) and the same target source (`MacrosConfig.fasting.min`,
  /// falling back to the default band).
  @MainActor
  private static func buildFasting(context: ModelContext) -> FastingWire? {
    guard UserDefaults.standard.bool(forKey: trackFastingDefaultsKey) else {
      lastFasting = nil
      return nil
    }
    let stats = ChecklistMirror.buildNutritionStatsResponse(context: context, days: 2)
    let inputs = FastingStateInputs(
      todayLatestMeal: stats.todayLatestMeal,
      todayMealCount: stats.todayMealCount ?? 0,
      yesterdayLastMeal: stats.yesterdayLastMeal)
    let now = Date()
    guard case .fasting(_, let since, let totalMin) = computeFastingState(inputs: inputs, now: now)
    else {
      // Not fasting per this read. A read that actually saw meals (`daily`
      // non-empty) is trustworthy — "fed" means the fast is genuinely over, so
      // clear and publish macros. But an *empty* read (the SwiftData fetch came
      // back with nothing — transiently, or before a CloudKit absorb finished)
      // would also land here and wrongly blank a running fast: the very flap
      // where the wrist drops to "0 nutrients, no fast" while the phone still
      // shows it. On an empty read, preserve the last known fast instead of
      // overwriting the complication with zeroes. The 48h cap stops a stale fast
      // from lingering if the empty reads never resolve.
      if stats.daily.isEmpty, let last = lastFasting,
         now.timeIntervalSince(last.since) < 48 * 3600 {
        return last
      }
      lastFasting = nil
      return nil
    }

    let targetH = NutritionPrefs.loadMacrosConfig()?.fasting?.min ?? FastingDefaults.targetMinH
    // The Fasting metric's authored color, resolved exactly as the phone's
    // Nutrition surfaces do: the user's per-tile override else the MacroCatalog
    // default — so the wrist ring matches the phone.
    let tiles = MacroCatalog.reconcile(
      SettingsMirror.loadSettings(context: context)?.nutrition?.macroTiles
        ?? MacroCatalog.defaultTilePrefs())
    let colorHex = tiles.first(where: { $0.id == "fasting" })?.colorHex
      ?? MacroCatalog.byID["fasting"]?.defaultColorHex

    let wire = FastingWire(
      since: now.addingTimeInterval(-Double(totalMin) * 60),
      sinceLabel: since,
      targetHours: max(targetH, 1),
      colorHex: colorHex)
    lastFasting = wire
    return wire
  }

  // MARK: - Capture catalogs (wrist quick-inputs)

  /// In-stock grocery list cap, so a large pantry can't bloat the snapshot the
  /// watch reads on every fetch.
  private static let groceriesCap = 100

  /// The user's active medications for the wrist "mark taken" menu, in their
  /// saved order. `detail` is the strength ("500 mg") else the form, so the row
  /// can disambiguate two meds with the same name.
  @MainActor
  private static func buildMedications(context: ModelContext) -> [MedicationWire] {
    let rows = (try? context.fetch(FetchDescriptor<MedicationDefinitionEntity>(
      predicate: #Predicate { !$0.archived },
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    return rows.map { m in
      var detail: String? = nil
      if let v = m.strengthValue {
        // Trim a trailing ".0" so "500.0 mg" reads "500 mg".
        let num = v == v.rounded() ? String(Int(v)) : String(v)
        detail = m.strengthUnit.map { "\(num) \($0)" } ?? num
      } else if let form = m.form, !form.isEmpty {
        detail = form
      }
      return MedicationWire(id: m.id, name: m.title, detail: detail)
    }
  }

  /// The user's active symptom catalog for the wrist severity menu, in saved order.
  @MainActor
  private static func buildSymptoms(context: ModelContext) -> [SymptomWire] {
    let rows = (try? context.fetch(FetchDescriptor<SymptomDefinitionEntity>(
      predicate: #Predicate { !$0.archived },
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    return rows.map { SymptomWire(id: $0.id, name: $0.title, emoji: $0.emoji) }
  }

  /// The user's in-stock grocery items for the wrist "mark low" menu, in saved
  /// order. Only items currently `low == false` — marking low is the wrist
  /// action, so an already-low item has nothing to do here.
  @MainActor
  private static func buildGroceries(context: ModelContext) -> [GroceryWire] {
    let rows = (try? context.fetch(FetchDescriptor<GroceryItemEntity>(
      predicate: #Predicate { !$0.low },
      sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    return rows.prefix(groceriesCap).map {
      GroceryWire(id: $0.id, name: $0.name,
                  emoji: $0.emoji.isEmpty ? nil : $0.emoji, category: $0.category)
    }
  }

  private static func save(payload: Data, rhythmPayload: Data? = nil, date: String) async {
    let db = CKContainer(identifier: containerID).privateCloudDatabase
    let id = CKRecord.ID(recordName: recordName)   // default zone
    do {
      let record = (try? await db.record(for: id))
        ?? CKRecord(recordType: recordType, recordID: id)
      record["payload"]   = payload as CKRecordValue
      record["date"]      = date as CKRecordValue
      record["updatedAt"] = Date() as CKRecordValue
      // Additive field — older records / clients without it just skip the wheel.
      if let rhythmPayload { record["rhythmPayload"] = rhythmPayload as CKRecordValue }
      try await db.save(record)
    } catch {
      // Best-effort — the next publish() call reconciles.
    }
  }
}
