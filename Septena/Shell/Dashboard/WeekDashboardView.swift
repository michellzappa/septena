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

/// Sub-sheets presented from the Nutrition QuickAdd menu. Separate state
/// from `sheetDest` (destination views) so each affordance is self-contained.
enum NutritionSheet: Hashable, Identifiable {
  case search        // history search modal
  case newEntry      // blank meal-form sheet

  var id: Self { self }
}

struct WeekDashboardView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(SectionTheme.self) private var theme
  @Environment(TabSelection.self) private var tabSelection
  @Environment(NavigationState.self) private var nav
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(DayClock.self) private var clock
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  @State private var dailies = NextItemsModel()
  @State private var habitHistory: [Int] = Array(repeating: 0, count: 7)
  @State private var choreHistory: [Int] = Array(repeating: 0, count: 7)
  @State private var cardio: CardioHistoryResponse? = nil
  @State private var trainingSessionDates: Set<String> = []
  /// Session-type catalog + recency for the Training QuickAdd menu.
  /// Loaded in the background Task alongside other menu-only fetches.
  @State private var trainingSessionTypes: [SessionTypeConfig] = []
  @State private var trainingSuggestedId: String? = nil
  @State private var trainingDaysAgo: [String: Int] = [:]
  @State private var supplementHistory: [Int] = Array(repeating: 0, count: 7)
  @State private var taskCounts: TasksCounts? = nil
  @State private var tasksHistory: TasksHistory? = nil
  @State private var completedTasks: [SeptenaTask] = []
  @State private var ouraNights: [OuraNight] = []
  @State private var nutritionStats: NutritionStatsResponse? = nil
  @State private var todayProteinSum: Double = 0
  @State private var todayKcalSum: Double = 0
  @State private var nutritionTarget: MacrosConfig? = nil
  /// 30-day meal history — feeds both the QuickAdd menu's recommendations
  /// and the NutritionSearchSheet's full searchable list. Loaded in the
  /// background Task after the second-wave dashboard fetches settle.
  @State private var nutritionHistory: [NutritionEntry] = []
  /// Which Nutrition sub-sheet is currently presented from the menu.
  @State private var nutritionSheet: NutritionSheet? = nil
  @State private var airSummary: AirSummary? = nil
  @State private var airHistory: [AirHistoryPoint] = []
  @State private var groceries: [GroceryItem] = []
  @State private var caffeineToday: CaffeineDayResponse? = nil
  @State private var caffeineHistory: [CaffeineHistoryPoint] = []
  @State private var caffeineLastEntry: CaffeineTimePoint? = nil
  @State private var cannabisToday: CannabisDayResponse? = nil
  @State private var cannabisHistory: [CannabisHistoryPoint] = []
  @State private var cannabisUsesPerCapsule: Int = 3
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
  /// Fasting band color for DayTimelineView — sourced from
  /// `settings.nutrition.macro_colors`, same accent the Nutrition mini-app
  /// renders the fasting tile in.
  @State private var macroColors: MacroColors? = nil

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
      // Consistent home-page chrome across Week / Next / Tasks:
      //   • top-left "…" menu (Settings today; room to grow)
      //   • top-right magnifyingglass → universal Quick Find sheet
      .toolbar { homeToolbar }
      // Two-phase load: paint cached blobs synchronously so tiles +
      // histograms appear immediately on cold launch, then kick off the
      // network refresh in the background. Pull-to-refresh skips the
      // cache step since it's a manual "I want fresh data now" gesture.
      .task {
        paintFromCache()
        await loadAll()
      }
      .refreshable { await loadAll() }
      // CK fetch landed (push, foreground refresh, or pull-to-refresh on
      // any other surface) — repaint so today's task counts reflect
      // mutations from other devices.
      .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
        Task { await loadAll() }
      }
      // Day rollover: the dashboard is the most date-sensitive surface
      // (today's timeline, today's totals, 7-day windows ending today).
      // Refetch everything when `clock.today` flips.
      .onChange(of: clock.today) { _, _ in
        Task { await loadAll() }
      }
      // Quick-add finished — repaint just that tile from cache (instant,
      // for sections that wrote optimistic state) and refetch its
      // endpoints in the background to reconcile with the server. Scoped
      // to the touched section so the rest of the dashboard stays put.
      .onReceive(NotificationCenter.default.publisher(for: .tilesDidChange)) { note in
        guard let key = note.userInfo?[TileChangeKey.section] as? String,
              let section = AddInfoSection(rawValue: key) else { return }
        repaint(section: section)
        Task { await refresh(section: section) }
      }
    }
    // Sheets, not pushes — iPhone navigation into module destinations
    // is a bottom-sheet slide-over so the dashboard stays visually
    // present underneath. iPad / Mac render this just as well.
    //
    // Attached OUTSIDE the NavigationStack on purpose: `.refreshable`
    // inside publishes `\.refresh` into the env, and SwiftUI sheet
    // contents inherit env from the view they're attached to. Hosting
    // `.sheet` on the NavigationStack itself (not on the ScrollView
    // beside `.refreshable`) keeps the sheet's attachment point outside
    // the refreshable's scope, so drawers don't inherit a pull-to-
    // refresh gesture that re-runs Week's loader.
    .sheet(item: $sheetDest) { dest in
      sheetContent(for: dest)
    }
    .sheet(item: $nutritionSheet) { sheet in
      switch sheet {
      case .search:
        NutritionSearchSheet(entries: nutritionHistory)
          #if os(iOS)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
          #else
          .frame(width: 560, height: 600)
          #endif
      case .newEntry:
        NewNutritionEntrySheet()
          #if os(iOS)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
          #else
          .frame(width: 560, height: 600)
          #endif
      }
    }
  }

  @ToolbarContentBuilder
  private var homeToolbar: some ToolbarContent {
    #if os(iOS)
    ToolbarItem(placement: .topBarLeading) { homeMenu }
    ToolbarItem(placement: .topBarTrailing) { homeSearch }
    #else
    ToolbarItem(placement: .primaryAction) { homeMenu }
    ToolbarItem(placement: .primaryAction) { homeSearch }
    #endif
  }

  private var homeMenu: some View {
    Menu {
      Button {
        nav.showSettings = true
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .accessibilityLabel("More")
  }

  private var homeSearch: some View {
    Button { nav.showQuickFind = true } label: {
      Image(systemName: "magnifyingglass")
    }
    .accessibilityLabel("Search")
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
    .presentationDetents([.medium, .large])
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
    static let macroColors        = "week.macroColors"
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
    if let v = ResponseCache.load(MacroColors.self, forKey: CacheKey.macroColors) { macroColors = v }
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
    async let tc = try? await TaskReads.counts(
      client: client, context: LocalStore.shared.container.mainContext)
    let th: TasksHistory? = TaskReads.tasksHistory(
      days: 7, context: LocalStore.shared.container.mainContext)
    async let tl = try? await TaskReads.list(
      view: "logbook", days: 1,
      client: client, context: LocalStore.shared.container.mainContext)
    async let on = try? await client.ouraHistory(days: 7)
    async let nstats = try? await client.nutritionStats(days: 7)
    async let nents = try? await client.nutritionEntries(since: SeptenaDate.today)
    async let ntarget = try? await client.nutritionMacrosConfig()
    async let asum = try? await client.airSummary()
    async let ahist = try? await client.airHistory(days: 7)
    async let groc = try? await client.groceries()
    async let appSettings = try? await client.settings()
    let (h, c, ca, e, s, t, o) = await (hh, ch, car, ents, sh, tc, on)
    let (ns, ne, nt) = await (nstats, nents, ntarget)
    let (asRes, ahRes, gRes) = await (asum, ahist, groc)
    if let colors = (await appSettings)?.nutrition?.macroColors {
      macroColors = colors
      ResponseCache.save(colors, forKey: CacheKey.macroColors)
    }
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
    if let thRes = th {
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

    // QuickAdd menu preset data — fire-and-forget on a separate Task so it
    // doesn't block the rest of `loadAll()`. Adding these to the second
    // wave's parallel `async let` group triggered "freed pointer was not
    // the last allocation" heap corruption mid-launch (a SeptenaClient /
    // URLSession concurrency edge past ~4 simultaneous calls); doing them
    // inline-but-sequential here would block tile rendering if any one
    // request stalls. The dashboard tiles don't need this data for first
    // paint, only when the user opens a context menu.
    Task { @MainActor [client] in
      // Caffeine: only the last entry is needed (Repeat is the menu's
      // only contextual action — bean-picking lives in the sheet).
      if let entries = try? await client.caffeineEntries(days: 7),
         let last = entries.entries.last {
        caffeineLastEntry = last
      }
      // Cannabis: usesPerCapsule is the only field the smart menu reads
      // (to know when the current capsule is exhausted). Strain list is
      // not consumed by the menu anymore.
      if let cnbCfg = try? await client.cannabisConfig() {
        cannabisUsesPerCapsule = max(1, cnbCfg.usesPerCapsule)
      }
      // Nutrition: 30-day meal history feeds the menu's "Recommended"
      // scoring and the NutritionSearchSheet's full searchable list.
      let since = SeptenaDate.format(
        Calendar.current.date(byAdding: .day, value: -30, to: .now)
      ) ?? SeptenaDate.today
      if let entries = try? await client.nutritionEntries(since: since) {
        nutritionHistory = entries
      }
      // Training: session-type catalog + suggested + daysAgo. Feeds the
      // menu's "Start: {suggested}" row and the "Recent" section. All
      // three come from existing endpoints — no new server work needed.
      if let types = try? await client.sessionTypes() {
        trainingSessionTypes = types
      }
      if let resp = try? await client.suggestedWorkout() {
        trainingSuggestedId = resp.suggested?.type
        trainingDaysAgo = resp.daysAgo
      }
    }
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

  // MARK: - Per-section refresh (quick-add fast path)
  //
  // Triggered by `Notification.Name.tilesDidChange` posted from any
  // Add*Page after a successful commit. We do two things, scoped to the
  // touched section so the rest of the dashboard stays put:
  //
  //   1. `repaint(section:)`  — synchronous read from ResponseCache.
  //      Picks up any optimistic blob the Add page wrote (e.g. cannabis
  //      bumps `sessionCount` locally before the outbox drains).
  //   2. `refresh(section:)`  — async refetch of just that section's
  //      endpoints. Reconciles with the server once the outbox drains.
  //
  // Animation lives on the tile components (`.animation(.snappy, value:)`
  // inside `ModuleTile`), so any @State assignment here tweens for free.

  private func repaint(section: AddInfoSection) {
    switch section {
    case .cannabis:
      if let v = ResponseCache.load(CannabisDayResponse.self, forKey: CacheKey.cannabisToday) {
        cannabisToday = v
      }
      if let v = ResponseCache.load([CannabisHistoryPoint].self, forKey: CacheKey.cannabisHistory) {
        cannabisHistory = v
      }
    case .caffeine:
      if let v = ResponseCache.load(CaffeineDayResponse.self, forKey: CacheKey.caffeineToday) {
        caffeineToday = v
      }
      if let v = ResponseCache.load([CaffeineHistoryPoint].self, forKey: CacheKey.caffeineHistory) {
        caffeineHistory = v
      }
    case .gut:
      if let v = ResponseCache.load(GutDayResponse.self, forKey: CacheKey.gutToday) {
        gutToday = v
      }
      if let v = ResponseCache.load([GutHistoryPoint].self, forKey: CacheKey.gutHistory) {
        gutHistory = v
      }
    case .nutrition:
      if let v = ResponseCache.load([NutritionEntry].self, forKey: CacheKey.todayNutrition) {
        todayNutrition = v
        todayProteinSum = v.reduce(0) { $0 + $1.proteinG }
        todayKcalSum    = v.reduce(0) { $0 + $1.kcal }
      }
      if let v = ResponseCache.load(NutritionStatsResponse.self, forKey: CacheKey.nutritionStats) {
        nutritionStats = v
      }
    case .habits:
      if let v = ResponseCache.load([Int].self, forKey: CacheKey.habitHistory) { habitHistory = v }
    case .chores:
      if let v = ResponseCache.load([Int].self, forKey: CacheKey.choreHistory) { choreHistory = v }
    case .supplements:
      if let v = ResponseCache.load([Int].self, forKey: CacheKey.supplementHistory) { supplementHistory = v }
    case .groceries:
      if let v = ResponseCache.load([GroceryItem].self, forKey: CacheKey.groceries) { groceries = v }
    case .tasks:
      if let v = ResponseCache.load(TasksCounts.self, forKey: CacheKey.taskCounts) { taskCounts = v }
      if let v = ResponseCache.load(TasksHistory.self, forKey: CacheKey.tasksHistory) { tasksHistory = v }
      if let v = ResponseCache.load([SeptenaTask].self, forKey: CacheKey.completedTasks) { completedTasks = v }
    case .training:
      // Training has no in-place optimistic cache write today — the Add
      // page is a navigation shim. Repaint is a no-op; `refresh` will
      // pull fresh server state when (eventually) the session lands.
      break
    }
  }

  private func refresh(section: AddInfoSection) async {
    switch section {
    case .cannabis:
      async let day  = try? await client.cannabisDay(date: SeptenaDate.today)
      async let hist = try? await client.cannabisHistory(days: 7)
      if let d = await day {
        cannabisToday = d
        ResponseCache.save(d, forKey: CacheKey.cannabisToday)
      }
      if let h = (await hist)?.daily {
        cannabisHistory = h
        ResponseCache.save(h, forKey: CacheKey.cannabisHistory)
      }
    case .caffeine:
      async let day  = try? await client.caffeineDay(date: SeptenaDate.today)
      async let hist = try? await client.caffeineHistory(days: 7)
      if let d = await day {
        caffeineToday = d
        ResponseCache.save(d, forKey: CacheKey.caffeineToday)
      }
      if let h = (await hist)?.daily {
        caffeineHistory = h
        ResponseCache.save(h, forKey: CacheKey.caffeineHistory)
      }
    case .gut:
      async let day  = try? await client.gutDay(date: SeptenaDate.today)
      async let hist = try? await client.gutHistory(days: 7)
      if let d = await day {
        gutToday = d
        ResponseCache.save(d, forKey: CacheKey.gutToday)
      }
      if let h = (await hist)?.daily {
        gutHistory = h
        ResponseCache.save(h, forKey: CacheKey.gutHistory)
      }
    case .nutrition:
      async let ents  = try? await client.nutritionEntries(since: SeptenaDate.today)
      async let stats = try? await client.nutritionStats(days: 7)
      if let e = await ents {
        let today = SeptenaDate.today
        let todays = e.filter { $0.date == today }
        todayNutrition = todays
        todayProteinSum = todays.reduce(0) { $0 + $1.proteinG }
        todayKcalSum    = todays.reduce(0) { $0 + $1.kcal }
        ResponseCache.save(todays, forKey: CacheKey.todayNutrition)
      }
      if let s = await stats {
        nutritionStats = s
        ResponseCache.save(s, forKey: CacheKey.nutritionStats)
      }
    case .habits:
      async let _ = dailies.load(client: client)
      if let h = try? await client.habitsHistory(days: 7) {
        habitHistory = h.daily.map { $0.done }
        ResponseCache.save(habitHistory, forKey: CacheKey.habitHistory)
      }
    case .chores:
      async let _ = dailies.load(client: client)
      if let c = try? await client.choresHistory(days: 7) {
        choreHistory = c.daily.map { $0.completed }
        ResponseCache.save(choreHistory, forKey: CacheKey.choreHistory)
      }
    case .supplements:
      async let _ = dailies.load(client: client)
      if let s = try? await client.supplementsHistory(days: 7) {
        supplementHistory = s.daily.map { $0.done }
        ResponseCache.save(supplementHistory, forKey: CacheKey.supplementHistory)
      }
    case .groceries:
      if let g = try? await client.groceries() {
        groceries = g
        ResponseCache.save(g, forKey: CacheKey.groceries)
      }
    case .tasks:
      async let tc = try? await TaskReads.counts(
        client: client, context: LocalStore.shared.container.mainContext)
      let th: TasksHistory? = TaskReads.tasksHistory(
        days: 7, context: LocalStore.shared.container.mainContext)
      async let tl = try? await TaskReads.list(
        view: "logbook", days: 1,
        client: client, context: LocalStore.shared.container.mainContext)
      if let t = await tc {
        taskCounts = t
        ResponseCache.save(t, forKey: CacheKey.taskCounts)
      }
      if let t = th {
        tasksHistory = t
        ResponseCache.save(t, forKey: CacheKey.tasksHistory)
      }
      if let items = (await tl)?.items {
        completedTasks = items
        ResponseCache.save(items, forKey: CacheKey.completedTasks)
      }
    case .training:
      async let car  = try? await client.trainingCardioHistory(days: 7)
      async let ents = try? await client.trainingEntries(since: sinceDate(daysBack: 7))
      if let c = await car {
        cardio = c
        ResponseCache.save(c, forKey: CacheKey.cardio)
      }
      if let e = await ents {
        trainingSessionDates = Set(e.map(\.date))
        recentTraining = e
        ResponseCache.save(trainingSessionDates, forKey: CacheKey.trainingDates)
        ResponseCache.save(e, forKey: CacheKey.recentTraining)
      }
    }
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
      date: clock.today,
      oura: ouraNights.first,
      caffeine: caffeineToday?.entries ?? [],
      cannabis: cannabisToday?.entries ?? [],
      nutrition: todayNutrition,
      gut: gutToday?.entries ?? [],
      habits: dailies.habits,
      supplements: dailies.supplements,
      chores: dailies.chores,
      training: recentTraining,
      tasks: completedTasks,
      calendar: dailies.calendarEvents,
      macroColors: macroColors
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
    return ModuleTile(
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
    .contentShape(Rectangle())
    .onTapGesture { tabSelection.current = .tasks }
    .contextMenu { tasksQuickAddMenu }
  }

  /// Today's open tasks read straight from SwiftData (no network hop) —
  /// LocalCache mirrors the server's view=today filter, so this matches
  /// what the Tasks tab shows when you navigate in.
  private var todayOpenTasks: [SeptenaTask] {
    let resp = TaskReads.localList(
      view: "today", area: nil, project: nil, days: 1,
      context: LocalStore.shared.container.mainContext
    )
    return resp.items.filter { $0.status != .done }
  }

  @ViewBuilder private var tasksQuickAddMenu: some View {
    TasksQuickAddMenu(
      todayTasks: todayOpenTasks,
      onCreateInInbox: {
        tabSelection.current = .tasks
        nav.path = [.filter(.inbox)]
        // Trip the "start inline create" flag — TaskListView consumes
        // and clears it on its next render. Mirrors the sidebar's
        // "New To-Do" path so create flows always look the same.
        nav.shouldStartCreating = true
      },
      onGoToInbox: {
        tabSelection.current = .tasks
        nav.path = [.filter(.inbox)]
      },
      onGoToToday: {
        tabSelection.current = .tasks
        nav.path = [.filter(.today)]
      },
      onCheckOff: { task in
        Haptics.success()
        taskMutator.complete(id: task.id)
      }
    )
  }

  private var habitsTile: some View {
    let total = dailies.habits.count
    let done = dailies.habits.filter { $0.done }.count
    let skipped = dailies.habits.filter { $0.skipped }.count
    let accent = theme.color(for: "habits")
    return ModuleTile(
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
    .contentShape(Rectangle())
    .onTapGesture { sheetDest = .habits }
    .contextMenu { habitsQuickAddMenu }
  }

  @ViewBuilder private var habitsQuickAddMenu: some View {
    HabitsQuickAddMenu(
      habits: dailies.habits,
      buckets: dailies.habitBuckets,
      onComplete: { item in commitHabitToggle(item) }
    )
  }


  private func commitHabitToggle(_ item: HabitDayItem) {
    outbox.enqueue(method: "POST", path: "/api/habits/toggle",
                   body: ["habit_id": item.id,
                          "date": SeptenaDate.today,
                          "done": true],
                   kind: "habits.toggle")
    // Track in `actedHabits` so NextItemsSection keeps the row in place
    // (struck through) rather than hopping to "done" mid-flick. The menu's
    // own filter still sees `.done = false` here, so a rapid re-open could
    // show the same habit until the next refresh — acceptable for a
    // close-on-tap menu and matches the existing AddHabitPage pattern.
    dailies.actedHabits.insert(item.id)
    AddInfoSection.habits.notifyTilesChanged()
    Haptics.tick()
  }

  // Training — sessions count derived from unique dates in the last 7
  // days of entries; Z2 minutes and target come from the cardio endpoint;
  // histogram bars stack strength volume (full accent) and cardio minutes
  // (lighter shade) per day, mirroring the webapp's training overview.
  // Each series is normalized to its own 7-day max ×50 so a peak day fills
  // the chart and a half-sized bar reads as ~half that week's effort.
  private var trainingTile: some View {
    let accent = theme.color(for: "training")
    let sessionCount = trainingSessionDates.count
    let minutes = cardio?.daily.reduce(0) { $0 + $1.minutes } ?? 0
    let target = cardio?.targetWeeklyMin ?? 150

    let days = lastSevenDays
    var strengthByDate: [String: Double] = [:]
    var cardioByDate: [String: Double] = [:]
    for e in recentTraining {
      let isCardio = (e.distanceM ?? 0) > 0
        || ((e.durationMin ?? 0) > 0 && e.weight == nil)
      if isCardio {
        if let d = e.durationMin, d > 0 {
          cardioByDate[e.date, default: 0] += d
        }
      } else if let w = e.weight, w > 0,
                let s = e.sets.flatMap(Int.init), s > 0,
                let r = e.reps.flatMap(Int.init), r > 0 {
        strengthByDate[e.date, default: 0] += w * Double(s * r)
      }
    }
    let maxS = max(1, days.map { strengthByDate[$0] ?? 0 }.max() ?? 0)
    let maxC = max(1, days.map { cardioByDate[$0] ?? 0 }.max() ?? 0)
    let strengthBars = days.map { Int(((strengthByDate[$0] ?? 0) / maxS) * 50) }
    let cardioBars   = days.map { Int(((cardioByDate[$0]   ?? 0) / maxC) * 50) }

    return ModuleTile(
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
      history: .init(label: "7-day effort",
                     values: strengthBars,
                     secondaryValues: cardioBars)
    )
    .contentShape(Rectangle())
    .onTapGesture { sheetDest = .training }
    .contextMenu { trainingQuickAddMenu }
  }

  @ViewBuilder private var trainingQuickAddMenu: some View {
    TrainingQuickAddMenu(
      sessionTypes: trainingSessionTypes,
      suggestedId: trainingSuggestedId,
      daysAgo: trainingDaysAgo,
      onStart: { typeId in
        // Empty id = "no suggestion, open the picker" — leave pendingType
        // nil so TrainingSessionView shows its picker. Otherwise pass the
        // chosen id through nav so the sheet auto-starts the draft.
        if !typeId.isEmpty {
          nav.pendingTrainingType = typeId
        }
        nav.showTrainingSession = true
      }
    )
  }

  /// Last 7 ISO yyyy-MM-dd dates, oldest → newest. Used to align the
  /// training tile's two-series histogram so absent days still render as
  /// zero-height bars instead of being collapsed out of the chart.
  private var lastSevenDays: [String] {
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    return (0..<7).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: Date()).map(fmt.string(from:))
    }
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
    return ModuleTile(
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
    .contentShape(Rectangle())
    .onTapGesture { sheetDest = .chores }
    .contextMenu { choresQuickAddMenu }
  }

  /// Chores already toggled this session — hidden from both menus so we
  /// don't re-show them mid-flick. `completedChores` is the same session
  /// set NextItemsSection uses; matching it keeps the two surfaces aligned.
  private var pendingChores: [ChoreItem] {
    dailies.chores.filter { !dailies.completedChores.contains($0.id) }
  }

  @ViewBuilder private var choresQuickAddMenu: some View {
    ChoresQuickAddMenu(
      chores: pendingChores,
      onComplete: { chore in commitChoreComplete(chore) }
    )
  }

  private func commitChoreComplete(_ chore: ChoreItem) {
    outbox.enqueue(method: "POST", path: "/api/chores/complete",
                   body: ["chore_id": chore.id, "date": SeptenaDate.today],
                   kind: "chores.complete")
    dailies.completedChores.insert(chore.id)
    AddInfoSection.chores.notifyTilesChanged()
    Haptics.tick()
  }

  // Supplements — live taken/total today plus 7-day adherence histogram.
  private var supplementsTile: some View {
    let total = dailies.supplements.count
    let done = dailies.supplements.filter { $0.done }.count
    let accent = theme.color(for: "supplements")
    return ModuleTile(
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
    .contentShape(Rectangle())
    .onTapGesture { sheetDest = .supplements }
    .contextMenu { supplementsQuickAddMenu }
  }

  @ViewBuilder private var supplementsQuickAddMenu: some View {
    SupplementsQuickAddMenu(
      supplements: dailies.supplements,
      onToggle: { item in commitSupplementToggle(item) }
    )
  }

  private func commitSupplementToggle(_ item: SupplementDayItem) {
    outbox.enqueue(method: "POST", path: "/api/supplements/toggle",
                   body: ["supplement_id": item.id,
                          "date": SeptenaDate.today,
                          "done": true],
                   kind: "supplements.toggle")
    dailies.actedSupplements.insert(item.id)
    AddInfoSection.supplements.notifyTilesChanged()
    Haptics.tick()
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
    let boughtPerDay = groceriesBoughtPerDay()
    let totalBought7d = boughtPerDay.reduce(0, +)
    return ModuleTile(
      title: "Groceries",
      accent: accent,
      stats: [
        .init(label: "Need",       value: "\(lowCount)"),
        .init(label: "7-day buys", value: "\(totalBought7d)")
      ],
      progress: groceries.isEmpty ? nil : .init(
        label: "Stocked",
        current: Double(stocked),
        target: Double(max(groceries.count, 1))
      ),
      history: .init(label: "Bought (7d)", values: boughtPerDay)
    )
    .contentShape(Rectangle())
    .onTapGesture { sheetDest = .groceries }
    .contextMenu { groceriesQuickAddMenu }
  }

  @ViewBuilder private var groceriesQuickAddMenu: some View {
    GroceriesQuickAddMenu(
      items: groceries,
      onMarkLow: { item in commitGroceryMarkLow(item) }
    )
  }

  private func commitGroceryMarkLow(_ item: GroceryItem) {
    outbox.enqueue(method: "PATCH", path: "/api/groceries/item/\(item.id)",
                   body: ["low": true], kind: "groceries.patch")
    // Optimistic local flip so the same menu re-opened a moment later
    // doesn't re-list the item under "stocked." Matches the optimistic
    // patterns in other tile menus (acted sets in NextItemsModel).
    if let idx = groceries.firstIndex(where: { $0.id == item.id }) {
      groceries[idx].low = true
    }
    AddInfoSection.groceries.notifyTilesChanged()
    Haptics.tick()
  }

  /// Items bought per day for the last 7 days (oldest → newest, today last),
  /// derived from each item's `lastBought` date.
  private func groceriesBoughtPerDay() -> [Int] {
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    let today = cal.startOfDay(for: Date())
    var counts = Array(repeating: 0, count: 7)
    for item in groceries {
      guard let lb = item.lastBought, let d = fmt.date(from: lb) else { continue }
      let diff = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: today).day ?? Int.max
      if diff >= 0 && diff < 7 { counts[6 - diff] += 1 }
    }
    return counts
  }

  // Caffeine — today's session count + grams; 7-day session histogram.
  private var caffeineTile: some View {
    let accent = theme.color(for: "caffeine")
    let sessions = caffeineToday?.sessionCount ?? 0
    let grams = caffeineToday?.totalG ?? 0
    let bars = caffeineHistory.map { $0.sessions }
    let dailyLimit = 3   // soft default until Settings.targets is wired
    return ModuleTile(
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
    .contentShape(Rectangle())
    .onTapGesture { sheetDest = .caffeine }
    .contextMenu { caffeineQuickAddMenu }
  }

  @ViewBuilder private var caffeineQuickAddMenu: some View {
    CaffeineQuickAddMenu(
      lastEntry: caffeineLastEntry,
      onCommit: { method, beans, grams in
        commitCaffeine(method: method, beans: beans, grams: grams)
      },
      onEditLast: caffeineLastEntry == nil ? nil : { sheetDest = .caffeine }
    )
  }

  private func commitCaffeine(method: String, beans: String?, grams: Double?) {
    var body: [String: Any] = [
      "date": SeptenaDate.today,
      "time": nowHHMM(),
      "method": method,
      "timezone": TimeZone.current.identifier,
    ]
    if let beans { body["beans"] = beans }
    if let grams { body["grams"] = grams }
    outbox.enqueue(method: "POST", path: "/api/caffeine/entry",
                   body: body, kind: "caffeine.add")
    AddInfoSection.caffeine.notifyTilesChanged()
    Haptics.tick()
  }

  // Cannabis — same shape as caffeine.
  private var cannabisTile: some View {
    let accent = theme.color(for: "cannabis")
    let sessions = cannabisToday?.sessionCount ?? 0
    let grams = cannabisToday?.totalG ?? 0
    let bars = cannabisHistory.map { $0.sessions }
    let dailyLimit = 2
    return ModuleTile(
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
    .contentShape(Rectangle())
    .onTapGesture { sheetDest = .cannabis }
    .contextMenu { cannabisQuickAddMenu }
  }

  /// Last vape entry from today's cached entries — `nil` when there's no
  /// vape today, in which case the menu defaults to "Continue · Hit 1".
  /// We deliberately don't widen to a multi-day lookback: that would require
  /// an extra fetch on every dashboard load to populate one menu row, and
  /// the cost/value isn't worth it. Power users who want yesterday's strain
  /// can hit "More…".
  private var lastCannabisVape: CannabisEntry? {
    cannabisToday?.entries.reversed().first { $0.method == "vape" }
  }

  /// Edit-last opens the destination view (rather
  /// than threading an EditCannabisEntrySheet through the dashboard)
  /// since the destination already has that affordance.
  @ViewBuilder private var cannabisQuickAddMenu: some View {
    CannabisQuickAddMenu(
      lastVape: lastCannabisVape,
      usesPerCapsule: cannabisUsesPerCapsule,
      onCommit: { method, strain, hit in
        commitCannabis(method: method, strain: strain, hit: hit)
      },
      onEditLast: lastCannabisVape == nil ? nil : { sheetDest = .cannabis }
    )
  }

  private func commitCannabis(method: String, strain: String?, hit: Int?) {
    let time = nowHHMM()
    var body: [String: Any] = [
      "date": SeptenaDate.today,
      "time": time,
      "method": method,
    ]
    if let strain { body["strain"] = strain }
    if let hit { body["hit"] = hit }
    outbox.enqueue(method: "POST", path: "/api/cannabis/entry",
                   body: body, kind: "cannabis.add")
    appendCannabisToCache(method: method, strain: strain, hit: hit, time: time)
    AddInfoSection.cannabis.notifyTilesChanged()
    Haptics.tick()
  }

  /// Optimistic cache update — mirrors AddCannabisPage.appendToCache so the
  /// "Continue · Hit N" counter advances immediately when the user opens
  /// the menu again before the outbox has drained to the server.
  private func appendCannabisToCache(method: String, strain: String?, hit: Int?, time: String) {
    let newEntry = CannabisEntry(
      id: "pending-\(UUID().uuidString)",
      time: time,
      method: method,
      strain: strain,
      hit: hit,
      grams: nil,
      note: nil,
      effect: nil
    )
    let prior = ResponseCache.load(CannabisDayResponse.self, forKey: CacheKey.cannabisToday)
    let next = (prior?.entries ?? []) + [newEntry]
    let updated = CannabisDayResponse(
      date: prior?.date ?? SeptenaDate.today,
      entries: next,
      sessionCount: (prior?.sessionCount ?? 0) + 1,
      totalG: prior?.totalG
    )
    ResponseCache.save(updated, forKey: CacheKey.cannabisToday)
    cannabisToday = updated
  }

  // Body — latest Withings weigh-in + bidirectional weight chart.
  // Only actual weigh-in days produce bars; gaps stay nil so carry-forward
  // values don't collapse everything to zero deviation.
  private var bodyTile: some View {
    let accent = theme.color(for: "body")
    let latest = bodyRows.first
    let weight = latest?.weightKg
    let fat    = latest?.fatPct
    let actualSeries = weeklyWeightActual()
    let present = actualSeries.compactMap { $0 }
    let avg = present.isEmpty ? 0.0 : present.reduce(0, +) / Double(present.count)
    let centeredValues: [Double?] = actualSeries.map { $0.map { $0 - avg } }
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
        centeredHistory: .init(label: "Weight vs avg (7d)", values: centeredValues)
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
    return ModuleTile(
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
    .contentShape(Rectangle())
    .onTapGesture { sheetDest = .gut }
    .contextMenu { gutQuickAddMenu }
  }

  // Bristol scale is a fixed 7-item enum — the menu IS the complete UX,
  // no "More…" sheet fallback. Matches AddGutPage's commit semantics:
  // `blood: 0` by default; full editor lives in GutDestinationView.
  @ViewBuilder private var gutQuickAddMenu: some View {
    let hasLast = !(gutToday?.entries.isEmpty ?? true)
    GutQuickAddMenu(
      recentBristolTypes: GutBristolRecorder.recentTypes,
      onCommit: { bristol in commitGut(bristol: bristol) },
      hasLastEntry: hasLast,
      onEditLast: hasLast ? { sheetDest = .gut } : nil
    )
  }

  private func commitGut(bristol: Int) {
    outbox.enqueue(method: "POST", path: "/api/gut/entry",
                   body: ["date": SeptenaDate.today,
                          "time": nowHHMM(),
                          "bristol": bristol,
                          "blood": 0],
                   kind: "gut.add")
    GutBristolRecorder.record(bristol)
    AddInfoSection.gut.notifyTilesChanged()
    Haptics.tick()
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

  /// Last 7 calendar days with actual weigh-ins only — no carry-forward.
  /// Days without a measurement are nil so the centered chart shows stubs
  /// rather than collapsing to zero deviation.
  private func weeklyWeightActual() -> [Double?] {
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    var byDate: [String: Double] = [:]
    for r in bodyRows { if let w = r.weightKg { byDate[r.date] = w } }
    let today = cal.startOfDay(for: Date())
    return (0..<7).reversed().map { offset -> Double? in
      guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
      return byDate[fmt.string(from: d)]
    }
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
    return ModuleTile(
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
    .contentShape(Rectangle())
    .onTapGesture { sheetDest = .nutrition }
    .contextMenu { nutritionQuickAddMenu }
  }

  @ViewBuilder private var nutritionQuickAddMenu: some View {
    NutritionQuickAddMenu(
      recommendations: NutritionRecommendations.topRecommended(
        from: nutritionHistory, limit: 3),
      onSearch: { nutritionSheet = .search },
      onInput: { nutritionSheet = .newEntry },
      onCommit: { meal in commitNutritionDuplicate(meal) }
    )
  }

  /// POST a fresh nutrition entry mirroring the meal's macros + emoji at
  /// the current time. Same payload as AddNutritionPage.duplicate so the
  /// server treats this menu commit identically to the palette one.
  private func commitNutritionDuplicate(_ entry: NutritionEntry) {
    var body: [String: Any] = [
      "date": SeptenaDate.today,
      "time": nowHHMM(),
      "foods": entry.foods,
      "protein_g": entry.proteinG,
      "fat_g": entry.fatG,
      "carbs_g": entry.carbsG,
      "kcal": entry.kcal,
    ]
    if let fiberG = entry.fiberG { body["fiber_g"] = fiberG }
    if let emoji = entry.emoji { body["emoji"] = emoji }
    outbox.enqueue(method: "POST", path: "/api/nutrition/entries",
                   body: body, kind: "nutrition.add")
    AddInfoSection.nutrition.notifyTilesChanged()
    Haptics.tick()
  }
}
