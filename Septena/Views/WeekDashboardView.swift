import SwiftUI

// Week module — the synthesizing dashboard. Each module gets a tile that
// (a) renders live stats / histogram for that module and (b) pushes into
// the module's full destination on tap. Tiles for modules that don't yet
// have a Swift mini-app stay mocked + inert until those are built — but
// every accent comes from SectionTheme so colors match the user's
// server-configured Septena palette today.

enum WeekDestination: String, Hashable, Identifiable {
  case habits, chores, training, supplements, sleep, nutrition
  case air, groceries, calendar, caffeine, cannabis, body, gut
  case activity

  var id: String { rawValue }
}

struct WeekDashboardView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(TabSelection.self) private var tabSelection
  @Environment(NavigationState.self) private var nav
  @Environment(SettingsStore.self) private var settingsStore
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  @State private var dailies = NextItemsModel()
  @State private var habitHistory: [Int] = Array(repeating: 0, count: 7)
  @State private var choreHistory: [Int] = Array(repeating: 0, count: 7)
  @State private var cardio: CardioHistoryResponse? = nil
  @State private var trainingSessionDates: Set<String> = []
  @State private var supplementHistory: [Int] = Array(repeating: 0, count: 7)
  @State private var taskCounts: TasksCounts? = nil
  @State private var tasksHistory: TasksHistory? = nil
  @State private var completedTasks: [SeptenaTask] = []
  @State private var ouraNights: [OuraNight] = []
  @State private var nutritionStats: NutritionStatsResponse? = nil
  @State private var todayProteinSum: Double = 0
  @State private var todayKcalSum: Double = 0
  @State private var nutritionTarget: MacrosConfig? = nil
  @State private var airSummary: AirSummary? = nil
  @State private var airHistory: [AirHistoryPoint] = []
  @State private var groceries: [GroceryItem] = []
  @State private var caffeineToday: CaffeineDayResponse? = nil
  @State private var caffeineHistory: [CaffeineHistoryPoint] = []
  @State private var cannabisToday: CannabisDayResponse? = nil
  @State private var cannabisHistory: [CannabisHistoryPoint] = []
  @State private var bodyRows: [WithingsRow] = []
  @State private var gutToday: GutDayResponse? = nil
  @State private var gutHistory: [GutHistoryPoint] = []
  @State private var sheetDest: WeekDestination? = nil
  /// Today-scoped collections kept in state so DayTimelineView can read
  /// them. NextItemsModel already covers habits/supplements/chores and
  /// today's caffeine/cannabis/gut live in their respective `*Today`
  /// state vars; only nutrition + recent training need fresh stash.
  @State private var todayNutrition: [NutritionEntry] = []
  @State private var recentTraining: [ExerciseEntry] = []

  /// iPhone compact: 1 column. iPad regular: 3 columns.
  /// macOS: adaptive — packs as many ~280pt tiles as fit, so wider windows
  /// get 4 or 5 columns automatically. LazyVGrid reflows on resize.
  private var columns: [GridItem] {
    #if os(iOS)
    let count = (hSize == .regular) ? 3 : 1
    return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    #else
    return [GridItem(.adaptive(minimum: 280), spacing: 14)]
    #endif
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 18) {
          todayTimeline
          LazyVGrid(columns: columns, spacing: 14) {
            tiles
          }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 80)
      }
      .background(Theme.groupedBackground)
      // Tab bar already labels this view. Keep the nav bar present so
      // iOS's default scroll-edge effect kicks in (content fades to bg
      // material as it scrolls under the top — same shape as the
      // bottom tab bar). No .toolbarBackground override — the default
      // transparent-until-scrolled state is exactly what we want.
      .navigationTitle("")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      // Standard top-right gear opens the unified, app-global Settings
      // sheet (same one as ⌘, on macOS / the sidebar row). Week is the
      // natural homepage, so it's the natural place to put it.
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button { nav.showAddInfo = true } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("Add Info")
          .keyboardShortcut("k", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
          Button { nav.showSettings = true } label: {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("Settings")
        }
      }
      // Sheets, not pushes — iPhone navigation into module destinations
      // is a bottom-sheet slide-over so the dashboard stays visually
      // present underneath. iPad / Mac render this just as well.
      .sheet(item: $sheetDest) { dest in
        sheetContent(for: dest)
      }
      // Two-phase load: paint cached blobs synchronously so tiles +
      // histograms appear immediately on cold launch, then kick off the
      // network refresh in the background. Pull-to-refresh skips the
      // cache step since it's a manual "I want fresh data now" gesture.
      .task {
        paintFromCache()
        await loadAll()
      }
      .refreshable { await loadAll() }
    }
  }

  /// Each module's destination wrapped in its own NavigationStack so
  /// nav titles render inside the sheet. Medium + large detents on
  /// iPhone so the user can pull up to full height; iPad / Mac use the
  /// system default (large).
  @ViewBuilder
  private func sheetContent(for dest: WeekDestination) -> some View {
    NavigationStack {
      switch dest {
      case .habits:      HabitsDestinationView()
      case .chores:      ChoresDestinationView()
      case .training:    TrainingDestinationView()
      case .supplements: SupplementsDestinationView()
      case .sleep:       SleepDestinationView()
      case .nutrition:   NutritionDestinationView()
      case .air:         AirDestinationView()
      case .groceries:   GroceriesDestinationView()
      case .calendar:    CalendarDestinationView()
      case .caffeine:    CaffeineDestinationView()
      case .cannabis:    CannabisDestinationView()
      case .body:        BodyDestinationView()
      case .gut:         GutDestinationView()
      case .activity:    ActivityDestinationView()
      }
    }
    #if os(iOS)
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    #endif
  }

  // MARK: - Cache keys
  //
  // Each tile's data is cached under a stable key so cold launch paints
  // from disk before the network round-trip completes. Keys are scoped
  // `week.<state-var-name>` so different views don't collide.
  private enum CacheKey {
    static let habitHistory       = "week.habitHistory"
    static let choreHistory       = "week.choreHistory"
    static let cardio             = "week.cardio"
    static let trainingDates      = "week.trainingSessionDates"
    static let supplementHistory  = "week.supplementHistory"
    static let taskCounts         = "week.taskCounts"
    static let tasksHistory       = "week.tasksHistory"
    static let completedTasks     = "week.completedTasks"
    static let ouraNights         = "week.ouraNights"
    static let nutritionStats     = "week.nutritionStats"
    static let nutritionTarget    = "week.nutritionTarget"
    static let todayNutrition     = "week.todayNutrition"
    static let airSummary         = "week.airSummary"
    static let airHistory         = "week.airHistory"
    static let groceries          = "week.groceries"
    static let caffeineToday      = "week.caffeineToday"
    static let caffeineHistory    = "week.caffeineHistory"
    static let cannabisToday      = "week.cannabisToday"
    static let cannabisHistory    = "week.cannabisHistory"
    static let bodyRows           = "week.bodyRows"
    static let gutToday           = "week.gutToday"
    static let gutHistory         = "week.gutHistory"
    static let recentTraining     = "week.recentTraining"
  }

  /// Read every tile's last-known data out of disk-cached blobs and
  /// assign to @State. Runs synchronously at the top of `.task` so the
  /// dashboard renders with real numbers on cold launch — no flash of
  /// empty histograms while the network catches up.
  private func paintFromCache() {
    if let v = ResponseCache.load([Int].self, forKey: CacheKey.habitHistory) { habitHistory = v }
    if let v = ResponseCache.load([Int].self, forKey: CacheKey.choreHistory) { choreHistory = v }
    if let v = ResponseCache.load(CardioHistoryResponse.self, forKey: CacheKey.cardio) { cardio = v }
    if let v = ResponseCache.load(Set<String>.self, forKey: CacheKey.trainingDates) { trainingSessionDates = v }
    if let v = ResponseCache.load([Int].self, forKey: CacheKey.supplementHistory) { supplementHistory = v }
    if let v = ResponseCache.load(TasksCounts.self, forKey: CacheKey.taskCounts) { taskCounts = v }
    if let v = ResponseCache.load(TasksHistory.self, forKey: CacheKey.tasksHistory) { tasksHistory = v }
    if let v = ResponseCache.load([SeptenaTask].self, forKey: CacheKey.completedTasks) { completedTasks = v }
    if let v = ResponseCache.load([OuraNight].self, forKey: CacheKey.ouraNights) { ouraNights = v }
    if let v = ResponseCache.load(NutritionStatsResponse.self, forKey: CacheKey.nutritionStats) { nutritionStats = v }
    if let v = ResponseCache.load(MacrosConfig.self, forKey: CacheKey.nutritionTarget) { nutritionTarget = v }
    if let v = ResponseCache.load([NutritionEntry].self, forKey: CacheKey.todayNutrition) {
      todayNutrition = v
      todayProteinSum = v.reduce(0) { $0 + $1.proteinG }
      todayKcalSum    = v.reduce(0) { $0 + $1.kcal }
    }
    if let v = ResponseCache.load(AirSummary.self, forKey: CacheKey.airSummary) { airSummary = v }
    if let v = ResponseCache.load([AirHistoryPoint].self, forKey: CacheKey.airHistory) { airHistory = v }
    if let v = ResponseCache.load([GroceryItem].self, forKey: CacheKey.groceries) { groceries = v }
    if let v = ResponseCache.load(CaffeineDayResponse.self, forKey: CacheKey.caffeineToday) { caffeineToday = v }
    if let v = ResponseCache.load([CaffeineHistoryPoint].self, forKey: CacheKey.caffeineHistory) { caffeineHistory = v }
    if let v = ResponseCache.load(CannabisDayResponse.self, forKey: CacheKey.cannabisToday) { cannabisToday = v }
    if let v = ResponseCache.load([CannabisHistoryPoint].self, forKey: CacheKey.cannabisHistory) { cannabisHistory = v }
    if let v = ResponseCache.load([WithingsRow].self, forKey: CacheKey.bodyRows) { bodyRows = v }
    if let v = ResponseCache.load(GutDayResponse.self, forKey: CacheKey.gutToday) { gutToday = v }
    if let v = ResponseCache.load([GutHistoryPoint].self, forKey: CacheKey.gutHistory) { gutHistory = v }
    if let v = ResponseCache.load([ExerciseEntry].self, forKey: CacheKey.recentTraining) { recentTraining = v }
  }

  /// Fan out the per-tile fetches in parallel. NextItemsModel covers today's
  /// habits / chores / supplements (used by every "today" stat on the page);
  /// the two history endpoints provide the 7-day histograms.
  ///
  /// Every successful response is mirrored to ResponseCache so the next
  /// cold launch repaints from disk. Failures leave both the @State and
  /// the cached blob alone — last-known-good wins until the next refresh.
  private func loadAll() async {
    async let _ = dailies.load(client: client)
    async let hh = try? await client.habitsHistory(days: 7)
    async let ch = try? await client.choresHistory(days: 7)
    async let car = try? await client.trainingCardioHistory(days: 7)
    async let ents = try? await client.trainingEntries(since: sinceDate(daysBack: 7))
    async let sh = try? await client.supplementsHistory(days: 7)
    async let tc = try? await client.counts()
    async let th = try? await client.tasksHistory(days: 7)
    async let tl = try? await client.list(view: "logbook", days: 1)
    async let on = try? await client.ouraHistory(days: 7)
    async let nstats = try? await client.nutritionStats(days: 7)
    async let nents = try? await client.nutritionEntries(since: SeptenaDate.today)
    async let ntarget = try? await client.nutritionMacrosConfig()
    async let asum = try? await client.airSummary()
    async let ahist = try? await client.airHistory(days: 7)
    async let groc = try? await client.groceries()
    let (h, c, ca, e, s, t, o) = await (hh, ch, car, ents, sh, tc, on)
    let (ns, ne, nt) = await (nstats, nents, ntarget)
    let (asRes, ahRes, gRes) = await (asum, ahist, groc)
    if let asRes {
      airSummary = asRes
      ResponseCache.save(asRes, forKey: CacheKey.airSummary)
    }
    if let ah = ahRes?.daily {
      airHistory = ah
      ResponseCache.save(ah, forKey: CacheKey.airHistory)
    }
    if let g = gRes {
      groceries = g
      ResponseCache.save(g, forKey: CacheKey.groceries)
    }
    if let h {
      habitHistory = h.daily.map { $0.done }
      ResponseCache.save(habitHistory, forKey: CacheKey.habitHistory)
    }
    if let c {
      choreHistory = c.daily.map { $0.completed }
      ResponseCache.save(choreHistory, forKey: CacheKey.choreHistory)
    }
    if let ca {
      cardio = ca
      ResponseCache.save(ca, forKey: CacheKey.cardio)
    }
    if let e {
      trainingSessionDates = Set(e.map(\.date))
      ResponseCache.save(trainingSessionDates, forKey: CacheKey.trainingDates)
    }
    if let s {
      supplementHistory = s.daily.map { $0.done }
      ResponseCache.save(supplementHistory, forKey: CacheKey.supplementHistory)
    }
    if let t {
      taskCounts = t
      ResponseCache.save(t, forKey: CacheKey.taskCounts)
    }
    if let thRes = await th {
      tasksHistory = thRes
      ResponseCache.save(thRes, forKey: CacheKey.tasksHistory)
    }
    if let items = (await tl)?.items {
      completedTasks = items
      ResponseCache.save(items, forKey: CacheKey.completedTasks)
    }
    if let o {
      ouraNights = o
      ResponseCache.save(o, forKey: CacheKey.ouraNights)
    }
    if let ns {
      nutritionStats = ns
      ResponseCache.save(ns, forKey: CacheKey.nutritionStats)
    }
    if let nt {
      nutritionTarget = nt
      ResponseCache.save(nt, forKey: CacheKey.nutritionTarget)
    }
    if let ne {
      let today = SeptenaDate.today
      let todayEntries = ne.filter { $0.date == today }
      todayProteinSum = todayEntries.reduce(0) { $0 + $1.proteinG }
      todayKcalSum    = todayEntries.reduce(0) { $0 + $1.kcal }
      todayNutrition = todayEntries
      ResponseCache.save(todayEntries, forKey: CacheKey.todayNutrition)
    }
    if let e {
      recentTraining = e
      ResponseCache.save(e, forKey: CacheKey.recentTraining)
    }
    // Caffeine + Cannabis — second wave so the heavier core fetches above
    // render their tiles first.
    async let cafToday = try? await client.caffeineDay(date: SeptenaDate.today)
    async let cafHist  = try? await client.caffeineHistory(days: 7)
    async let cnbToday = try? await client.cannabisDay(date: SeptenaDate.today)
    async let cnbHist  = try? await client.cannabisHistory(days: 7)
    let (cafT, cafH, cnbT, cnbH) = await (cafToday, cafHist, cnbToday, cnbHist)
    if let cafT {
      caffeineToday = cafT
      ResponseCache.save(cafT, forKey: CacheKey.caffeineToday)
    }
    if let ch = cafH?.daily {
      caffeineHistory = ch
      ResponseCache.save(ch, forKey: CacheKey.caffeineHistory)
    }
    if let cnbT {
      cannabisToday = cnbT
      ResponseCache.save(cnbT, forKey: CacheKey.cannabisToday)
    }
    if let cnh = cnbH?.daily {
      cannabisHistory = cnh
      ResponseCache.save(cnh, forKey: CacheKey.cannabisHistory)
    }
    async let wRows = try? await client.withingsHistory(days: 14)
    async let gutT  = try? await client.gutDay(date: SeptenaDate.today)
    async let gutH  = try? await client.gutHistory(days: 7)
    let (wR, gT, gH) = await (wRows, gutT, gutH)
    if let wR {
      let sorted = wR.sorted { $0.date > $1.date }
      bodyRows = sorted
      ResponseCache.save(sorted, forKey: CacheKey.bodyRows)
    }
    if let gT {
      gutToday = gT
      ResponseCache.save(gT, forKey: CacheKey.gutToday)
    }
    if let gh = gH?.daily {
      gutHistory = gh
      ResponseCache.save(gh, forKey: CacheKey.gutHistory)
    }
    // HealthKit — on-device, no FastAPI. Mac builds short-circuit.
    await HealthKitBridge.shared.refresh()
  }

  private func sinceDate(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
  }

  // MARK: - Today timeline (single row above the tile grid)

  private var todayTimeline: some View {
    DayTimelineView(
      date: SeptenaDate.today,
      oura: ouraNights.first,
      caffeine: caffeineToday?.entries ?? [],
      cannabis: cannabisToday?.entries ?? [],
      nutrition: todayNutrition,
      gut: gutToday?.entries ?? [],
      habits: dailies.habits,
      supplements: dailies.supplements,
      chores: dailies.chores,
      training: recentTraining,
      tasks: completedTasks
    )
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.secondaryGroupedBackground)
    )
  }

  // MARK: - Tiles
  //
  // Order is driven by `/api/sections` (the same list Settings shows) so
  // the homepage and Settings always agree. Each section key dispatches
  // to its tile; unknown keys are skipped. If the sections list hasn't
  // loaded yet, fall back to the legacy static order so the dashboard
  // never renders empty.

  @ViewBuilder
  private var tiles: some View {
    if settingsStore.sections.isEmpty {
      legacyTileOrder
    } else {
      ForEach(settingsStore.sections, id: \.key) { sec in
        tile(for: sec.key)
      }
    }
  }

  @ViewBuilder
  private func tile(for key: String) -> some View {
    switch key {
    case "tasks":       tasksTile
    case "habits":      habitsTile
    case "training":    trainingTile
    case "chores":      choresTile
    case "supplements": supplementsTile
    case "sleep":       sleepTile
    case "nutrition":   nutritionTile
    case "air":         airTile
    case "groceries":   groceriesTile
    // Calendar is surfaced inline in the Next tab (mirroring the webapp's
    // /api/calendar/day integration), not as a standalone tile.
    case "calendar":    EmptyView()
    case "caffeine":    caffeineTile
    case "cannabis":    cannabisTile
    case "body":        bodyTile
    case "gut":         gutTile
    case "activity":    activityTile
    default:            EmptyView()
    }
  }

  @ViewBuilder
  private var legacyTileOrder: some View {
    tasksTile
    habitsTile
    trainingTile
    choresTile
    supplementsTile
    sleepTile
    nutritionTile
    airTile
    groceriesTile
    caffeineTile
    cannabisTile
    bodyTile
    gutTile
    activityTile
  }

  // Tasks — live counts from /api/tasks/counts and per-day completion
  // history from /api/tasks/history. Tapping the tile switches to the
  // Tasks tab (the full task app); other tiles open a sheet, but Tasks
  // has its own dedicated tab already.
  private var tasksTile: some View {
    let openToday = taskCounts.map { $0.todayCount + $0.reviewCount } ?? 0
    let inbox = taskCounts?.inboxCount ?? 0
    let upcoming = taskCounts?.upcomingCount ?? 0
    let doneToday = tasksHistory?.daily.last?.done ?? 0
    let totalToday = doneToday + openToday
    let bars = tasksHistory?.daily.map(\.done) ?? []
    return Button { tabSelection.current = .tasks } label: {
      ModuleTile(
        title: "Tasks",
        accent: theme.color(for: "tasks"),
        stats: [.init(label: "Today",    value: "\(openToday)"),
                .init(label: "Inbox",    value: "\(inbox)"),
                .init(label: "Upcoming", value: "\(upcoming)")],
        // Today's completion progress: done so far vs. everything
        // scheduled for today (done + still open). Defaults to a full
        // bar when there's nothing today, so the empty state doesn't
        // read as 0%.
        progress: .init(label: "Done / today",
                        current: Double(doneToday),
                        target: Double(max(totalToday, 1))),
        history: bars.isEmpty
          ? nil
          : .init(label: "7-day completions", values: bars)
      )
    }
    .buttonStyle(.plain)
  }

  private var habitsTile: some View {
    let total = dailies.habits.count
    let done = dailies.habits.filter { $0.done }.count
    let skipped = dailies.habits.filter { $0.skipped }.count
    let accent = theme.color(for: "habits")
    return Button { sheetDest = .habits } label: {
      ModuleTile(
        title: "Habits",
        accent: accent,
        stats: [
          .init(label: "Today",   value: "\(done)"),
          .init(label: "Skipped", value: "\(skipped)")
        ],
        progress: .init(
          label: "Today's progress",
          current: Double(done),
          target: Double(max(total, 1))
        ),
        history: .init(label: "7-day adherence", values: habitHistory)
      )
    }
    .buttonStyle(.plain)
  }

  // Training — sessions count derived from unique dates in the last 7
  // days of entries; Z2 minutes and target come from the cardio endpoint;
  // histogram bars are per-day cardio minutes.
  private var trainingTile: some View {
    let accent = theme.color(for: "training")
    let sessionCount = trainingSessionDates.count
    let minutes = cardio?.daily.reduce(0) { $0 + $1.minutes } ?? 0
    let target = cardio?.targetWeeklyMin ?? 150
    let bars = cardio?.daily.map { $0.minutes } ?? Array(repeating: 0, count: 7)
    return Button { sheetDest = .training } label: {
      ModuleTile(
        title: "Training",
        accent: accent,
        stats: [
          .init(label: "Sessions", value: "\(sessionCount)/7"),
          .init(label: "Z2 min",   value: "\(minutes)", unit: "m")
        ],
        progress: .init(
          label: "Z2 cardio",
          current: Double(minutes),
          target: Double(max(target, 1)),
          unit: "m"
        ),
        history: .init(label: "7-day effort", values: bars)
      )
    }
    .buttonStyle(.plain)
  }

  private var choresTile: some View {
    // "Done today" needs to count chores already completed earlier in the
    // day (server has them with `last_completed == today`) plus anything
    // toggled in this session (`completedChores`). Without the server
    // half, the count is always 0 on a fresh launch.
    let todayISO = SeptenaDate.today
    let serverDoneIDs = Set(dailies.chores
                              .filter { $0.lastCompleted == todayISO }
                              .map(\.id))
    let doneIDs = serverDoneIDs.union(dailies.completedChores)
    let dueToday = dailies.chores.filter {
      $0.daysOverdue == 0 && !doneIDs.contains($0.id)
    }.count
    let overdue  = dailies.chores.filter {
      $0.daysOverdue > 0 && !doneIDs.contains($0.id)
    }.count
    let done = doneIDs.count
    let total = dueToday + overdue + done
    let accent = theme.color(for: "chores")
    return Button { sheetDest = .chores } label: {
      ModuleTile(
        title: "Chores",
        accent: accent,
        stats: [
          .init(label: "Due today", value: "\(dueToday)"),
          .init(label: "Overdue",   value: "\(overdue)")
        ],
        progress: .init(label: "Today done",
                        current: Double(done),
                        target: Double(max(total, 1))),
        history: .init(label: "7-day done", values: choreHistory)
      )
    }
    .buttonStyle(.plain)
  }

  // Supplements — live taken/total today plus 7-day adherence histogram.
  private var supplementsTile: some View {
    let total = dailies.supplements.count
    let done = dailies.supplements.filter { $0.done }.count
    let accent = theme.color(for: "supplements")
    return Button { sheetDest = .supplements } label: {
      ModuleTile(
        title: "Supplements",
        accent: accent,
        stats: [.init(label: "Today", value: "\(done)")],
        progress: .init(
          label: "Today's stack",
          current: Double(done),
          target: Double(max(total, 1))
        ),
        history: .init(label: "7-day adherence", values: supplementHistory)
      )
    }
    .buttonStyle(.plain)
  }

  // Sleep — Oura-backed. Last night's total + score; 7-day hours
  // histogram. Reverse the server order so the bar furthest right is
  // most-recent.
  private var sleepTile: some View {
    let accent = theme.color(for: "sleep")
    let last = ouraNights.first
    let lastH = last?.totalH ?? 0
    let score = last?.sleepScore.map { "\($0)" } ?? "—"
    // Score-out-of-100 bars matched to the webapp: each bar runs to a
    // constant ceiling of 100, with the score in full accent and the
    // gap-to-100 in a lighter tone so the actual score reads at a glance.
    let bars = ouraNights.reversed().map { $0.sleepScore ?? 0 }
    return Button { sheetDest = .sleep } label: {
      ModuleTile(
        title: "Sleep",
        accent: accent,
        stats: [
          .init(label: "Last night", value: formatHoursShort(lastH), unit: "h"),
          .init(label: "Score",      value: score)
        ],
        progress: .init(label: "Target", current: lastH, target: 8, unit: "h"),
        history: .init(label: "7-day score",
                       values: bars.isEmpty
                         ? Array(repeating: 0, count: 7) : bars,
                       ceiling: 100)
      )
    }
    .buttonStyle(.plain)
  }

  // Air — latest CO2 with band-derived accent; 7-day CO2 average bars.
  private var airTile: some View {
    let accent = theme.color(for: "air")
    let latest = airSummary?.latest?.co2Ppm.map { Int($0) }
    let todayOver = airSummary?.today.minutesOver1000 ?? 0
    let bars = airHistory.map { Int($0.co2Avg ?? 0) }
    // Progress is "air-quality budget" — every minute over 1000 ppm
    // eats into a soft 60-minute daily allowance.
    let budget = 60
    return Button { sheetDest = .air } label: {
      ModuleTile(
        title: "Air",
        accent: accent,
        stats: [
          .init(label: "CO2", value: latest.map { "\($0)" } ?? "—", unit: "ppm"),
          .init(label: "Over 1000", value: "\(todayOver)", unit: "m")
        ],
        progress: .init(label: "Bad-air budget",
                        current: Double(min(todayOver, budget)),
                        target: Double(budget),
                        unit: "m"),
        history: .init(label: "7-day CO2 avg",
                       values: bars.isEmpty
                         ? Array(repeating: 0, count: 7) : bars)
      )
    }
    .buttonStyle(.plain)
  }

  // Groceries — shopping-list size as the headline stat.
  private var groceriesTile: some View {
    let accent = theme.color(for: "groceries")
    let lowCount = groceries.filter { $0.low }.count
    let stocked = groceries.count - lowCount
    return Button { sheetDest = .groceries } label: {
      ModuleTile(
        title: "Groceries",
        accent: accent,
        stats: [
          .init(label: "Low",     value: "\(lowCount)"),
          .init(label: "Stocked", value: "\(stocked)")
        ],
        progress: groceries.isEmpty ? nil : .init(
          label: "Stocked",
          current: Double(stocked),
          target: Double(max(groceries.count, 1))
        ),
        history: .init(label: "Shopping list",
                       values: Array(repeating: max(lowCount, 1), count: 7))
      )
    }
    .buttonStyle(.plain)
  }

  // Caffeine — today's session count + grams; 7-day session histogram.
  private var caffeineTile: some View {
    let accent = theme.color(for: "caffeine")
    let sessions = caffeineToday?.sessionCount ?? 0
    let grams = caffeineToday?.totalG ?? 0
    let bars = caffeineHistory.map { $0.sessions }
    let dailyLimit = 3   // soft default until Settings.targets is wired
    return Button { sheetDest = .caffeine } label: {
      ModuleTile(
        title: "Caffeine",
        accent: accent,
        stats: [
          .init(label: "Today", value: "\(sessions)"),
          .init(label: "Grams", value: String(format: "%.1f", grams), unit: "g")
        ],
        progress: .init(label: "Today / limit",
                        current: Double(min(sessions, dailyLimit)),
                        target: Double(dailyLimit)),
        history: .init(label: "7-day sessions",
                       values: bars.isEmpty
                         ? Array(repeating: 0, count: 7) : bars)
      )
    }
    .buttonStyle(.plain)
  }

  // Cannabis — same shape as caffeine.
  private var cannabisTile: some View {
    let accent = theme.color(for: "cannabis")
    let sessions = cannabisToday?.sessionCount ?? 0
    let grams = cannabisToday?.totalG ?? 0
    let bars = cannabisHistory.map { $0.sessions }
    let dailyLimit = 2
    return Button { sheetDest = .cannabis } label: {
      ModuleTile(
        title: "Cannabis",
        accent: accent,
        stats: [
          .init(label: "Today", value: "\(sessions)"),
          .init(label: "Grams", value: String(format: "%.2f", grams), unit: "g")
        ],
        progress: .init(label: "Today / limit",
                        current: Double(min(sessions, dailyLimit)),
                        target: Double(dailyLimit)),
        history: .init(label: "7-day sessions",
                       values: bars.isEmpty
                         ? Array(repeating: 0, count: 7) : bars)
      )
    }
    .buttonStyle(.plain)
  }

  // Body — latest Withings weigh-in + weight-trend bars. Bars use
  // tenths-of-kg above a floor so small variation is still visible.
  // Always 7 bars, today rightmost; gaps carry-forward the last weigh-in
  // so the trend line stays continuous on days without a measurement.
  private var bodyTile: some View {
    let accent = theme.color(for: "body")
    let latest = bodyRows.first
    let weight = latest?.weightKg
    let fat    = latest?.fatPct
    let series = weeklyWeightSeries()
    let nonZero = series.compactMap { $0 }
    let floor = nonZero.min() ?? 0
    let bars = series.map { w -> Int in
      guard let w else { return 0 }
      return Int(((w - floor) * 10).rounded())
    }
    // Body-fat percentage tracked against a soft 18% target (single number,
    // overrideable later via Settings.targets.fat_min_pct).
    let fatTarget: Double = 18
    return Button { sheetDest = .body } label: {
      ModuleTile(
        title: "Body",
        accent: accent,
        stats: [
          .init(label: "Weight", value: weight.map { String(format: "%.1f", $0) } ?? "—", unit: "kg"),
          .init(label: "Fat",    value: fat.map { String(format: "%.1f", $0) } ?? "—", unit: "%")
        ],
        progress: .init(label: "Body fat target",
                        current: fat.map { min($0, fatTarget * 2) } ?? 0,
                        target: fatTarget,
                        unit: "%"),
        history: .init(label: "7-day trend", values: bars)
      )
    }
    .buttonStyle(.plain)
  }

  // Gut — today's movement count + last-7-day movement bars.
  private var gutTile: some View {
    let accent = theme.color(for: "gut")
    let count = gutToday?.movementCount ?? 0
    let discomfort = gutToday?.totalDiscomfortH ?? 0
    let bars = gutHistory.map { $0.movements }
    let dailyTarget = 2
    return Button { sheetDest = .gut } label: {
      ModuleTile(
        title: "Gut",
        accent: accent,
        stats: [
          .init(label: "Today",      value: "\(count)"),
          .init(label: "Discomfort", value: String(format: "%.1f", discomfort), unit: "h")
        ],
        progress: .init(label: "Today / typical",
                        current: Double(min(count, dailyTarget)),
                        target: Double(dailyTarget)),
        history: .init(label: "7-day movements",
                       values: bars.isEmpty
                         ? Array(repeating: 0, count: 7) : bars)
      )
    }
    .buttonStyle(.plain)
  }

  // Activity — Apple Health, on-device. Skips entirely when HealthKit
  // isn't available (Mac). Real per-day step bars from the last 7 days.
  @ViewBuilder
  private var activityTile: some View {
    let bridge = HealthKitBridge.shared
    if bridge.isAvailable {
      let accent = theme.color(for: "activity")
      let stepsTarget = 8000
      Button { sheetDest = .activity } label: {
        ModuleTile(
          title: "Activity",
          accent: accent,
          stats: [
            .init(label: "Steps",    value: "\(bridge.stepsToday)"),
            .init(label: "Active",   value: "\(Int(bridge.activeKcalToday))", unit: "kcal"),
            .init(label: "Exercise", value: "\(bridge.exerciseMinutesToday)", unit: "m")
          ],
          progress: .init(label: "Steps target",
                          current: Double(min(bridge.stepsToday, stepsTarget)),
                          target: Double(stepsTarget)),
          history: .init(label: "7-day steps",
                         values: bridge.stepsHistory)
        )
      }
      .buttonStyle(.plain)
    }
  }

  // Settings is reached from the sidebar (and ⌘, on macOS) — it's an
  // app-level surface, not a Week tile, and not on this toolbar.

  /// Last 7 calendar days oldest→newest (today rightmost) of carry-forward
  /// weights from `bodyRows`. A day with no weigh-in inherits the most
  /// recent prior weight; days before the first ever weigh-in are nil.
  private func weeklyWeightSeries() -> [Double?] {
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    // Map date → weight for fast lookup. bodyRows is newest-first; weights
    // may be nil on partial rows so filter those out.
    var byDate: [String: Double] = [:]
    for r in bodyRows { if let w = r.weightKg { byDate[r.date] = w } }
    // Sorted ascending dates of known weights, for carry-forward search.
    let knownDates = byDate.keys.sorted()
    var out: [Double?] = []
    let today = cal.startOfDay(for: Date())
    for offset in (0..<7).reversed() {
      let d = cal.date(byAdding: .day, value: -offset, to: today) ?? today
      let key = fmt.string(from: d)
      if let exact = byDate[key] {
        out.append(exact)
      } else if let prior = knownDates.last(where: { $0 <= key }) {
        out.append(byDate[prior])
      } else {
        out.append(nil)
      }
    }
    return out
  }

  /// 7.2 → "7:12" — compact h:mm form for the tile.
  private func formatHoursShort(_ h: Double) -> String {
    let total = Int((h * 60).rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  // Nutrition — today's protein + kcal from today's entries; histogram
  // is per-day protein from /api/nutrition/stats; progress bar uses the
  // user's protein target from /api/nutrition/macros-config.
  private var nutritionTile: some View {
    let accent = theme.color(for: "nutrition")
    let proteinTarget = nutritionTarget?.protein.min ?? 150
    let bars = nutritionStats?.daily.map { Int($0.proteinG) }
              ?? Array(repeating: 0, count: 7)
    return Button { sheetDest = .nutrition } label: {
      ModuleTile(
        title: "Nutrition",
        accent: accent,
        stats: [
          .init(label: "Protein", value: "\(Int(todayProteinSum))", unit: "g"),
          .init(label: "Kcal",    value: "\(Int(todayKcalSum))")
        ],
        progress: .init(label: "Today's protein",
                        current: todayProteinSum,
                        target: max(proteinTarget, 1),
                        unit: "g"),
        history: .init(label: "7-day protein", values: bars)
      )
    }
    .buttonStyle(.plain)
  }
}
