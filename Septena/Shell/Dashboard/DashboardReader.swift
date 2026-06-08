import SwiftData
import Foundation

/// The dashboard surfaces a section per domain. `DashSection` is the unit
/// the reader/apply pair works in: a scoped reload (a single tile changed)
/// touches one case; a full reload (`loadAll`) touches `allCases`.
enum DashSection: CaseIterable {
  case habits, chores, supplements, training, tasks
  case nutrition, groceries, caffeine, cannabis, gut, mood, hydration

  /// Map a capture section (the unit tile quick-adds notify in) onto the
  /// dashboard's read unit. `AddInfoSection` has no mood/hydration cases —
  /// those route around it (see `refreshMood` / `refreshHydration`).
  init(_ section: AddInfoSection) {
    switch section {
    case .habits:      self = .habits
    case .chores:      self = .chores
    case .supplements: self = .supplements
    case .training:    self = .training
    case .tasks:       self = .tasks
    case .nutrition:   self = .nutrition
    case .groceries:   self = .groceries
    case .caffeine:    self = .caffeine
    case .cannabis:    self = .cannabis
    case .gut:         self = .gut
    }
  }
}

/// Off-main SwiftData reader for the Week dashboard.
///
/// `@ModelActor` gives this its own background `ModelContext`, so the ~20
/// mirror reads the dashboard needs run off the main thread instead of
/// blocking it the way `loadAll` did when it read the view's main context
/// inline. Every method returns Sendable value DTOs — the same `Codable`
/// types `ResponseCache` persists — so SwiftData entities never escape the
/// actor's context. (This is deliberately a *separate* context, never the
/// app's `mainContext`; reading the main context off its actor is the
/// race `TaskReads`' `MainActor.run` guards against.)
@ModelActor
actor DashboardReader {
  /// View-ready result of a read. Histories are already mapped to the
  /// `[Int]` shapes the tiles render, so `apply` is a straight assignment
  /// pass. Only the requested sections' fields are populated; the caller
  /// passes the same `Set<DashSection>` to `apply` to know which to read.
  struct Snapshot {
    var habitHistory: [Int] = []
    var choreHistory: [Int] = []
    var supplementHistory: [Int] = []
    var cardio: CardioHistoryResponse?
    var trainingEntries: [ExerciseEntry] = []
    var nutritionStats: NutritionStatsResponse?
    var todayNutrition: [NutritionEntry] = []
    var nutritionTarget: MacrosConfig?
    var macroColors: MacroColors?
    var groceries: [GroceryItem] = []
    var caffeineToday: CaffeineDayResponse?
    var caffeineHistory: [CaffeineHistoryPoint] = []
    var cannabisToday: CannabisDayResponse?
    var cannabisHistory: [CannabisHistoryPoint] = []
    var gutToday: GutDayResponse?
    var gutHistory: [GutHistoryPoint] = []
    var moodToday: MoodDayResponse?
    var moodHistory: [MoodHistoryPoint] = []
    var hydrationHistory: [Int] = []
  }

  /// QuickAdd-menu-only data — the last consumable entry, recommendation
  /// inputs, the session catalog. Loaded on a separate hop because the
  /// tiles don't need it for first paint (only when a context menu opens).
  struct MenuExtras {
    var caffeineLastEntry: CaffeineTimePoint?
    var cannabisUsesPerCapsule: Int = 3
    var cannabisLastVape: CannabisEntry?
    var nutritionHistory: [NutritionEntry] = []
    var trainingSessionTypes: [SessionTypeConfig] = []
    var trainingSuggestedId: String?
    var trainingDaysAgo: [String: Int] = [:]
  }

  /// Read the requested sections off the main thread. The single source of
  /// truth for mirror → view-ready shaping; both the full load and every
  /// scoped refresh funnel through here.
  func read(_ sections: Set<DashSection>, today: String, days: Int) -> Snapshot {
    var s = Snapshot()
    let ctx = modelContext
    if sections.contains(.habits) {
      s.habitHistory = ChecklistMirror.loadHabitsHistory(context: ctx, days: days).daily.map { $0.done }
    }
    if sections.contains(.chores) {
      s.choreHistory = ChecklistMirror.loadChoresHistory(context: ctx, days: days).daily.map { $0.completed }
    }
    if sections.contains(.supplements) {
      s.supplementHistory = ChecklistMirror.loadSupplementsHistory(context: ctx, days: days).daily.map { $0.done }
    }
    if sections.contains(.training) {
      s.cardio = ChecklistMirror.loadTrainingCardioHistory(context: ctx, days: days)
      s.trainingEntries = ChecklistMirror.loadTrainingEntries(context: ctx, since: Self.sinceString(daysBack: days))
    }
    // Tasks are intentionally absent: `TaskReads` → `LocalCache` is
    // `@MainActor` (the core persistence layer's contract), so the view
    // reads them on the main actor via `refreshTasks()`. Everything here
    // goes through `context.fetch` directly and is safe off-main.
    if sections.contains(.nutrition) {
      s.nutritionStats = ChecklistMirror.buildNutritionStatsResponse(context: ctx, days: days)
      s.todayNutrition = ChecklistMirror.loadNutritionToday(context: ctx)
      s.nutritionTarget = NutritionPrefs.loadMacrosConfig()
      s.macroColors = SettingsMirror.loadSettings(context: ctx)?.nutrition?.macroColors
    }
    if sections.contains(.groceries) {
      s.groceries = ChecklistMirror.loadGroceryItems(context: ctx)
    }
    if sections.contains(.caffeine) {
      s.caffeineToday = ChecklistMirror.loadCaffeineDay(context: ctx, date: today)
      s.caffeineHistory = ChecklistMirror.loadCaffeineHistory(context: ctx, days: days).daily
    }
    if sections.contains(.cannabis) {
      s.cannabisToday = ChecklistMirror.loadCannabisDay(context: ctx, date: today)
      s.cannabisHistory = ChecklistMirror.loadCannabisHistory(context: ctx, days: days).daily
    }
    if sections.contains(.gut) {
      s.gutToday = ChecklistMirror.loadGutDay(context: ctx, date: today)
      s.gutHistory = ChecklistMirror.loadGutHistory(context: ctx, days: days).daily
    }
    if sections.contains(.mood) {
      s.moodToday = ChecklistMirror.loadMoodDay(context: ctx, date: today)
      s.moodHistory = ChecklistMirror.loadMoodHistory(context: ctx, days: days).daily
    }
    if sections.contains(.hydration) {
      s.hydrationHistory = ChecklistMirror.loadHydrationDailyMl(context: ctx, days: days)
    }
    return s
  }

  /// Second-wave QuickAdd menu data. Reads the two raw event entities
  /// directly (only the latest of each is needed) and the recommendation
  /// inputs, all on the actor's context.
  func menuExtras(today: String) -> MenuExtras {
    var m = MenuExtras()
    let ctx = modelContext

    // Caffeine: only the last entry powers the menu's Repeat action.
    let lastCaffeine = FetchDescriptor<CaffeineEventEntity>(
      sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
    )
    if let last = (try? ctx.fetch(lastCaffeine))?.first {
      let hhmm = EventTimestamp.hhmm(from: last.occurredAt)
      let hh = hhmm.split(separator: ":").first.flatMap { Int($0) } ?? 0
      let mm = hhmm.split(separator: ":").dropFirst().first.flatMap { Int($0) } ?? 0
      m.caffeineLastEntry = CaffeineTimePoint(date: last.date,
                                              time: hhmm,
                                              hour: Double(hh) + Double(mm) / 60.0,
                                              method: last.method,
                                              beans: last.beans,
                                              grams: last.grams)
    }
    // Cannabis: latest vape across all days drives the "Continue" row.
    let lastVape = FetchDescriptor<CannabisEventEntity>(
      predicate: #Predicate { $0.method == "vape" },
      sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
    )
    if let last = (try? ctx.fetch(lastVape))?.first {
      m.cannabisLastVape = CannabisEntry(id: last.id, time: EventTimestamp.hhmm(from: last.occurredAt), method: last.method,
                                         strain: last.strain, hit: last.hit, grams: last.grams,
                                         note: last.note)
    }
    // Nutrition: 30-day meal history feeds menu recommendations + search.
    let since = SeptenaDate.format(
      Calendar.current.date(byAdding: .day, value: -30, to: Date())
    ) ?? today
    m.nutritionHistory = ChecklistMirror.loadNutritionEntries(context: ctx, since: since)
    // Training: session catalog + suggested + recency.
    m.trainingSessionTypes = ChecklistMirror.loadSessionTypes(context: ctx)
    let resp = ChecklistMirror.loadSuggestedWorkout(context: ctx)
    m.trainingSuggestedId = resp.suggested?.type
    m.trainingDaysAgo = resp.daysAgo
    return m
  }

  /// `yyyy-MM-dd` for `daysBack` days ago — the string boundary the
  /// training mirror reads filter on.
  private static func sinceString(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
  }
}
