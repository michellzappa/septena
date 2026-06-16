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

  /// Compute on the main actor (SwiftData read), then save off-main. Best-effort:
  /// a failed write is retried by the next mutation / foreground. Prefer
  /// `schedule` from mutation paths so rapid edits don't each pay the full cost.
  @MainActor
  static func publish(context: ModelContext, date: String = SeptenaDate.today) {
    // The full Next feed (suggestions + tasks/chores/habits/supplements in the
    // user's saved section order) comes from the one shared builder, so the
    // watch snapshot can never diverge from the app's Next list.
    let items = NextFeed.flat(context: context, date: date)
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
    if !kindRows.isEmpty {
      let todaysEvents = (try? context.fetch(FetchDescriptor<IntakeEventEntity>(
        predicate: #Predicate { $0.date == date }))) ?? []
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
            .init(token: $0.token, label: $0.label, symbol: $0.symbol,
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
    // training-ring complication. Nil when nothing's been logged this week.
    let trainingRings = buildTrainingRings(context: context)
    let response = NextItemsResponse(date: date, bucket: "", items: items,
                                     lingerHabits: lingerHabits,
                                     lingerSupplements: lingerSupplements,
                                     sectionColors: sectionColors,
                                     intakeKinds: intakeKinds.isEmpty ? nil : intakeKinds,
                                     topMeals: topMeals.isEmpty ? nil : topMeals,
                                     nutritionRings: nutritionRings,
                                     trainingRings: trainingRings)
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

  // MARK: - Training rings (wrist training complication)

  /// This week's (trailing-7-day) strength / cardio / session totals vs targets.
  /// Values + targets come from `TrainingMetrics`; targets prefer a real goal and
  /// fall back to the built-in defaults (12 hard sets, 150 cardio min, 4 sessions).
  /// Strength volume is `sets × difficulty weight` (hard/max = 1, moderate =
  /// 0.5); cardio is summed `durationMin`; a session is a distinct training day.
  /// Returns nil when nothing was logged this week.
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
    guard rings.contains(where: { $0.value > 0 }) else { return nil }
    return TrainingRingsWire(rings: rings)
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
