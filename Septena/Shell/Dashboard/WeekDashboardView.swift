import SwiftUI
import SwiftData
import EventKit

// Week module — the synthesizing dashboard. Each module gets a tile that
// (a) renders live stats / histogram for that module and (b) pushes into
// the module's full destination on tap. Tiles for modules that don't yet
// have a Swift mini-app stay mocked + inert until those are built — but
// every accent comes from SectionTheme so colors match the user's
// server-configured Septena palette today.

enum WeekDestination: String, Hashable, Identifiable {
  case habits, chores, training, supplements, sleep, nutrition
  case groceries, caffeine, cannabis, body, gut
  case mood
  case activity
  /// Tasks-as-drawer. Mirrors every other section's bottom-sheet behaviour
  /// for users who prefer not to lose the homepage when they peek at today.
  /// The full Tasks tab is still reachable via the long-press menu and via
  /// the Settings > Tasks > Open in picker.
  case tasks

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
  @Environment(\.modelContext) private var modelContext
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(SectionTheme.self) private var theme
  @Environment(TabSelection.self) private var tabSelection
  @Environment(NavigationState.self) private var nav
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(DayClock.self) private var clock
  /// In-progress training draft (if any). Powers the "Resume {label}"
  /// row at the top of the Training quickadd menu — same affordance
  /// `TrainingDestinationView.activeSessionSection` shows at the top
  /// of the Training pane, surfaced one navigation hop earlier.
  @Environment(TrainingDraftStore.self) private var trainingDraft
  /// Which renderer the homepage uses. Phase 2: only `.tiles` is wired
  /// to real content; the other modes render a "Coming soon" placeholder
  /// that resets back to Tiles. Phases 3-5 land the actual renderers.
  @AppStorage(SettingsKey.homepageLayout)
  private var homepageLayoutRaw: String = HomepageLayoutMode.tiles.rawValue
  @AppStorage(SettingsKey.homepageShowTodayTimeline)
  private var showTodayTimeline: Bool = true
  @AppStorage(SettingsKey.homepageShowWelcome)
  private var showWelcome: Bool = true
  /// Fasting tracking master toggle + heatmap metric preference. When
  /// off, both the tile and the heatmap render protein like before;
  /// when on, the tile morphs based on the live `FastingState` and the
  /// heatmap encodes whichever metric the user picked in Settings.
  @AppStorage(SettingsKey.nutritionTrackFasting)
  private var nutritionTrackFasting: Bool = false
  @AppStorage(SettingsKey.nutritionHeatmapMetric)
  private var nutritionHeatmapMetricRaw: String = NutritionHeatmapMetric.protein.rawValue
  @Environment(\.a11yMotion) private var motion
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  @State private var dailies = NextItemsModel()
  @State private var habitHistory: [Int] = Array(repeating: 0, count: 90)
  @State private var choreHistory: [Int] = Array(repeating: 0, count: 90)
  @State private var cardio: CardioHistoryResponse? = nil
  @State private var trainingSessionDates: Set<String> = []
  /// Session-type catalog + recency for the Training QuickAdd menu.
  /// Loaded in the background Task alongside other menu-only fetches.
  @State private var trainingSessionTypes: [SessionTypeConfig] = []
  @State private var trainingSuggestedId: String? = nil
  @State private var trainingDaysAgo: [String: Int] = [:]
  @State private var supplementHistory: [Int] = Array(repeating: 0, count: 90)
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
  @State private var groceries: [GroceryItem] = []
  @State private var caffeineToday: CaffeineDayResponse? = nil
  @State private var caffeineHistory: [CaffeineHistoryPoint] = []
  @State private var caffeineLastEntry: CaffeineTimePoint? = nil
  @State private var cannabisToday: CannabisDayResponse? = nil
  @State private var cannabisHistory: [CannabisHistoryPoint] = []
  @State private var cannabisUsesPerCapsule: Int = 3
  @State private var cannabisLastVape: CannabisEntry? = nil
  @State private var bodyRows: [WithingsRow] = []
  @State private var gutToday: GutDayResponse? = nil
  @State private var gutHistory: [GutHistoryPoint] = []
  @State private var moodToday: MoodDayResponse? = nil
  @State private var moodHistory: [MoodHistoryPoint] = []
  /// True while the dashboard QuickAdd is presenting AddMoodPage as a
  /// standalone sheet (separate from `sheetDest` because Mood needs both
  /// the destination route and the standalone check-in flow).
  @State private var presentingMoodCheckin = false
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

  /// Prime every tile's `@State` from disk *before* the first body render.
  /// Without this, SwiftUI shows the literal defaults (zero-filled
  /// histograms, nil summaries) for a frame until `.task`'s `paintFromCache`
  /// fires. Reads are UserDefaults blobs — fast and safe to do in init.
  init() {
    if let v = ResponseCache.load([Int].self, forKey: CacheKey.habitHistory) { _habitHistory = State(initialValue: v) }
    if let v = ResponseCache.load([Int].self, forKey: CacheKey.choreHistory) { _choreHistory = State(initialValue: v) }
    if let v = ResponseCache.load(CardioHistoryResponse.self, forKey: CacheKey.cardio) { _cardio = State(initialValue: v) }
    if let v = ResponseCache.load(Set<String>.self, forKey: CacheKey.trainingDates) { _trainingSessionDates = State(initialValue: v) }
    if let v = ResponseCache.load([Int].self, forKey: CacheKey.supplementHistory) { _supplementHistory = State(initialValue: v) }
    if let v = ResponseCache.load(TasksCounts.self, forKey: CacheKey.taskCounts) { _taskCounts = State(initialValue: v) }
    if let v = ResponseCache.load(TasksHistory.self, forKey: CacheKey.tasksHistory) { _tasksHistory = State(initialValue: v) }
    if let v = ResponseCache.load([SeptenaTask].self, forKey: CacheKey.completedTasks) { _completedTasks = State(initialValue: v) }
    if let v = ResponseCache.load([OuraNight].self, forKey: CacheKey.ouraNights) { _ouraNights = State(initialValue: v) }
    if let v = ResponseCache.load(NutritionStatsResponse.self, forKey: CacheKey.nutritionStats) { _nutritionStats = State(initialValue: v) }
    if let v = ResponseCache.load(MacrosConfig.self, forKey: CacheKey.nutritionTarget) { _nutritionTarget = State(initialValue: v) }
    if let v = ResponseCache.load([NutritionEntry].self, forKey: CacheKey.todayNutrition) {
      _todayNutrition = State(initialValue: v)
      _todayProteinSum = State(initialValue: v.reduce(0) { $0 + $1.proteinG })
      _todayKcalSum    = State(initialValue: v.reduce(0) { $0 + $1.kcal })
    }
    if let v = ResponseCache.load([GroceryItem].self, forKey: CacheKey.groceries) { _groceries = State(initialValue: v) }
    if let v = ResponseCache.load(CaffeineDayResponse.self, forKey: CacheKey.caffeineToday) { _caffeineToday = State(initialValue: v) }
    if let v = ResponseCache.load([CaffeineHistoryPoint].self, forKey: CacheKey.caffeineHistory) { _caffeineHistory = State(initialValue: v) }
    if let v = ResponseCache.load(CannabisDayResponse.self, forKey: CacheKey.cannabisToday) { _cannabisToday = State(initialValue: v) }
    if let v = ResponseCache.load([CannabisHistoryPoint].self, forKey: CacheKey.cannabisHistory) { _cannabisHistory = State(initialValue: v) }
    if let v = ResponseCache.load([WithingsRow].self, forKey: CacheKey.bodyRows) { _bodyRows = State(initialValue: v) }
    if let v = ResponseCache.load(GutDayResponse.self, forKey: CacheKey.gutToday) { _gutToday = State(initialValue: v) }
    if let v = ResponseCache.load([GutHistoryPoint].self, forKey: CacheKey.gutHistory) { _gutHistory = State(initialValue: v) }
    if let v = ResponseCache.load(MoodDayResponse.self, forKey: CacheKey.moodToday) { _moodToday = State(initialValue: v) }
    if let v = ResponseCache.load([MoodHistoryPoint].self, forKey: CacheKey.moodHistory) { _moodHistory = State(initialValue: v) }
    if let v = ResponseCache.load([ExerciseEntry].self, forKey: CacheKey.recentTraining) { _recentTraining = State(initialValue: v) }
    if let v = ResponseCache.load(MacroColors.self, forKey: CacheKey.macroColors) { _macroColors = State(initialValue: v) }
  }

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
    WeekDashboardScreen(
      currentDay: clock.today,
      onInitialLoad: {
        paintFromCache()
        await loadAll()
      },
      onRefresh: loadAll,
      onTaskChange: {
        Task { await loadAll() }
      },
      onDayChange: {
        Task { await loadAll() }
      },
      onDataChange: {
        Task { await repaintAllMirrors() }
      },
      onTileChange: { section in
        repaint(section: section)
        Task { await refresh(section: section) }
      },
      toolbar: { homeToolbar }
    ) {
      VStack(spacing: 18) {
        if showWelcome { WelcomeHeader(now: clock.now) }
        if showTodayTimeline { todayTimeline }
        layoutBody
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.top, 12)
      .padding(.bottom, 80)
      // Regular width (iPad / macOS): a section opens as a pushed full
      // pane *inside* the dashboard's NavigationStack — a real screen with
      // a back button, not a floating modal drawer. `pushDest` is nil on
      // compact, so only the bottom-sheet path below fires there.
      .navigationDestination(item: pushDest) { dest in
        pushedContent(for: dest)
      }
    }
    // Compact (iPhone): navigation into a module is a bottom-sheet slide-
    // over so the dashboard stays visually present underneath.
    //
    // Attached OUTSIDE the NavigationStack on purpose: `.refreshable`
    // inside publishes `\.refresh` into the env, and SwiftUI sheet
    // contents inherit env from the view they're attached to. Hosting
    // `.sheet` on the NavigationStack itself (not on the ScrollView
    // beside `.refreshable`) keeps the sheet's attachment point outside
    // the refreshable's scope, so drawers don't inherit a pull-to-
    // refresh gesture that re-runs Week's loader.
    .sheet(item: sheetDestBinding) { dest in
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
    ToolbarItem(placement: .topBarTrailing) { SyncIndicator() }
    ToolbarItem(placement: .topBarTrailing) { homeSearch }
    #else
    ToolbarItem(placement: .primaryAction) { homeMenu }
    ToolbarItem(placement: .primaryAction) { SyncIndicator() }
    ToolbarItem(placement: .primaryAction) { homeSearch }
    #endif
  }

  private var homeMenu: some View {
    Menu {
      Picker(selection: Binding(
        get: { currentLayoutMode },
        set: { homepageLayoutRaw = $0.rawValue }
      )) {
        ForEach(HomepageLayoutMode.allCases) { mode in
          Label(mode.title, systemImage: mode.icon).tag(mode)
        }
      } label: {
        Text("Dashboard")
      }
      .pickerStyle(.inline)
      Divider()
      Button {
        nav.showSettings = true
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
    } label: {
      // Bare glyph (not `ellipsis.circle`) so it sits on the system's
      // gray toolbar circle exactly like the search button — no double
      // ring.
      Image(systemName: "ellipsis")
    }
    .accessibilityLabel("More")
  }

  private var homeSearch: some View {
    Button { nav.showQuickFind = true } label: {
      Image(systemName: "magnifyingglass")
    }
    .accessibilityLabel("Search")
  }

  /// True when sections should open as a pushed full pane rather than a
  /// modal bottom sheet — i.e. anywhere with room for it. macOS always;
  /// iOS only at regular width (iPad full-screen / large multitasking),
  /// so a compact iPad window correctly falls back to the bottom sheet.
  private var usesPushNavigation: Bool {
    #if os(macOS)
    return true
    #else
    return hSize == .regular
    #endif
  }

  /// Drives the `.navigationDestination` push. Mirrors `sheetDest` only
  /// when pushing, and stays nil otherwise so the sheet path owns
  /// presentation on compact. Every `sheetDest = .foo` tap site flows
  /// through whichever of these two bindings is currently active.
  private var pushDest: Binding<WeekDestination?> {
    Binding(
      get: { usesPushNavigation ? sheetDest : nil },
      set: { if usesPushNavigation { sheetDest = $0 } }
    )
  }

  /// Drives the bottom-sheet. The inverse of `pushDest`.
  private var sheetDestBinding: Binding<WeekDestination?> {
    Binding(
      get: { usesPushNavigation ? nil : sheetDest },
      set: { if !usesPushNavigation { sheetDest = $0 } }
    )
  }

  /// Pushed-pane content: the plugin destination rendered *bare*, with no
  /// extra `NavigationStack` or fixed frame — the dashboard's own stack
  /// hosts it, supplying the back button, and the section's `SectionDrawer`
  /// supplies its title + "+" toolbar. This is what turns "floating drawer"
  /// into "real screen" on iPad / macOS.
  @ViewBuilder
  private func pushedContent(for dest: WeekDestination) -> some View {
    if let view = SectionRegistry.plugin(forKey: dest.rawValue)?.destinationView() {
      view
    } else {
      EmptyView()
    }
  }

  /// Each module's destination wrapped in its own NavigationStack so
  /// nav titles render inside the sheet. Medium + large detents on
  /// iPhone so the user can pull up to full height; iPad / Mac use the
  /// system default (large).
  @ViewBuilder
  private func sheetContent(for dest: WeekDestination) -> some View {
    NavigationStack {
      // Plugin-driven destination. Every WeekDestination maps to a section
      // plugin's `destinationView()` (Tasks included, via the shared
      // SectionDrawer). Calendar is an integration, not a section — its data
      // surfaces inline in Today/Next, so it has no dedicated view here.
      if let view = SectionRegistry.plugin(forKey: dest.rawValue)?.destinationView() {
        view
      } else {
        EmptyView()
      }
    }
    #if os(iOS)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    #else
    .frame(width: 560, height: 600)
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
    static let groceries          = "week.groceries"
    static let caffeineToday      = "week.caffeineToday"
    static let caffeineHistory    = "week.caffeineHistory"
    static let cannabisToday      = "week.cannabisToday"
    static let cannabisHistory    = "week.cannabisHistory"
    static let bodyRows           = "week.bodyRows"
    static let gutToday           = "week.gutToday"
    static let gutHistory         = "week.gutHistory"
    static let moodToday          = "week.moodToday"
    static let moodHistory        = "week.moodHistory"
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
    if let v = ResponseCache.load([GroceryItem].self, forKey: CacheKey.groceries) { groceries = v }
    if let v = ResponseCache.load(CaffeineDayResponse.self, forKey: CacheKey.caffeineToday) { caffeineToday = v }
    if let v = ResponseCache.load([CaffeineHistoryPoint].self, forKey: CacheKey.caffeineHistory) { caffeineHistory = v }
    if let v = ResponseCache.load(CannabisDayResponse.self, forKey: CacheKey.cannabisToday) { cannabisToday = v }
    if let v = ResponseCache.load([CannabisHistoryPoint].self, forKey: CacheKey.cannabisHistory) { cannabisHistory = v }
    if let v = ResponseCache.load([WithingsRow].self, forKey: CacheKey.bodyRows) { bodyRows = v }
    if let v = ResponseCache.load(GutDayResponse.self, forKey: CacheKey.gutToday) { gutToday = v }
    if let v = ResponseCache.load([GutHistoryPoint].self, forKey: CacheKey.gutHistory) { gutHistory = v }
    if let v = ResponseCache.load(MoodDayResponse.self, forKey: CacheKey.moodToday) { moodToday = v }
    if let v = ResponseCache.load([MoodHistoryPoint].self, forKey: CacheKey.moodHistory) { moodHistory = v }
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
    async let _ = dailies.load()
    // Habits / Supplements / Chores / Settings come from the CloudKit-
    // backed local mirror — no FastAPI round-trip.
    let ctx = LocalStore.shared.container.mainContext
    // History window: 30 days so the Heatmap layout mode has a meaningful
    // strip width. Tile-mode bar charts render the same arrays and now
    // show 30 thinner bars instead of 7 — visually denser but still
    // readable. If a particular tile feels cramped, slice `.suffix(7)`
    // in just that tile's builder.
    let h: HabitHistoryResponse? = ChecklistMirror.loadHabitsHistory(context: ctx, days: 90)
    let c: ChoreHistoryResponse? = ChecklistMirror.loadChoresHistory(context: ctx, days: 90)
    let s: SupplementHistoryResponse? = ChecklistMirror.loadSupplementsHistory(context: ctx, days: 90)
    let appSettings: AppSettings? = SettingsMirror.loadSettings(context: ctx)
    let ca: CardioHistoryResponse? = ChecklistMirror.loadTrainingCardioHistory(context: ctx, days: 90)
    let e: [ExerciseEntry]? = ChecklistMirror.loadTrainingEntries(context: ctx, since: sinceDate(daysBack: 90))
    async let tc = TaskReads.counts(
      context: LocalStore.shared.container.mainContext)
    let th: TasksHistory? = TaskReads.tasksHistory(
      days: 90, context: LocalStore.shared.container.mainContext)
    async let tl = TaskReads.list(
      view: "logbook", days: 1,
      context: LocalStore.shared.container.mainContext)
    async let on = try? await OuraProvider.shared.fetchHistory(days: 90)
    let ns: NutritionStatsResponse? = ChecklistMirror.buildNutritionStatsResponse(context: modelContext, days: 90)
    let ne: [NutritionEntry]? = ChecklistMirror.loadNutritionToday(context: modelContext)
    let nt: MacrosConfig? = NutritionPrefs.loadMacrosConfig()
    let gRes: [GroceryItem]? = ChecklistMirror.loadGroceryItems(context: modelContext)
    let (t, o) = await (tc, on)
    if let colors = appSettings?.nutrition?.macroColors {
      macroColors = colors
      ResponseCache.save(colors, forKey: CacheKey.macroColors)
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
    taskCounts = t
    ResponseCache.save(t, forKey: CacheKey.taskCounts)
    if let thRes = th {
      tasksHistory = thRes
      ResponseCache.save(thRes, forKey: CacheKey.tasksHistory)
    }
    do {
      let items = await tl.items
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
    // Caffeine + Cannabis — read from local SwiftData (CK-synced) so the
    // dashboard renders instantly from the mirror without a network hop.
    let cafT: CaffeineDayResponse? = ChecklistMirror.loadCaffeineDay(context: modelContext, date: SeptenaDate.today)
    let cafH: CaffeineHistoryResponse? = ChecklistMirror.loadCaffeineHistory(context: modelContext, days: 90)
    let cnbT: CannabisDayResponse? = ChecklistMirror.loadCannabisDay(context: modelContext, date: SeptenaDate.today)
    let cnbH: CannabisHistoryResponse? = ChecklistMirror.loadCannabisHistory(context: modelContext, days: 90)

    // QuickAdd menu preset data — fire-and-forget on a separate Task so it
    // doesn't block the rest of `loadAll()`. Adding these to the second
    // wave's parallel `async let` group triggered "freed pointer was not
    // the last allocation" heap corruption mid-launch (a SeptenaClient /
    // URLSession concurrency edge past ~4 simultaneous calls); doing them
    // inline-but-sequential here would block tile rendering if any one
    // request stalls. The dashboard tiles don't need this data for first
    // paint, only when the user opens a context menu.
    Task { @MainActor in
      // Caffeine: only the last entry is needed (Repeat is the menu's
      // only contextual action — bean-picking lives in the sheet).
      // Pull from local SwiftData; CK has the canonical history now.
      let recentDescriptor = FetchDescriptor<CaffeineEventEntity>(
        sortBy: [SortDescriptor(\.date, order: .reverse), SortDescriptor(\.time, order: .reverse)]
      )
      if let last = (try? modelContext.fetch(recentDescriptor))?.first {
        let hh = last.time.split(separator: ":").first.flatMap { Int($0) } ?? 0
        let mm = last.time.split(separator: ":").dropFirst().first.flatMap { Int($0) } ?? 0
        caffeineLastEntry = CaffeineTimePoint(date: last.date,
                                              time: last.time,
                                              hour: Double(hh) + Double(mm) / 60.0,
                                              method: last.method,
                                              beans: last.beans,
                                              grams: last.grams)
      }
      // Cannabis: usesPerCapsule is a constant on CK (3 uses × 0.05g).
      cannabisUsesPerCapsule = 3
      // Last vape across all days — drives the "Continue · Hit N / Strain"
      // row even when there's been no vape today. Mirrors the webapp's
      // 30-day lookback (we just take the latest, no day cap needed since
      // SwiftData is local).
      let lastVapeDescriptor = FetchDescriptor<CannabisEventEntity>(
        predicate: #Predicate { $0.method == "vape" },
        sortBy: [SortDescriptor(\.date, order: .reverse), SortDescriptor(\.time, order: .reverse)]
      )
      if let last = (try? modelContext.fetch(lastVapeDescriptor))?.first {
        cannabisLastVape = CannabisEntry(id: last.id, time: last.time, method: last.method,
                                         strain: last.strain, hit: last.hit, grams: last.grams,
                                         note: last.note, effect: last.effect)
      }
      // Nutrition: 30-day meal history feeds the menu's "Recommended"
      // scoring and the NutritionSearchSheet's full searchable list.
      let since = SeptenaDate.format(
        Calendar.current.date(byAdding: .day, value: -30, to: .now)
      ) ?? SeptenaDate.today
      nutritionHistory = ChecklistMirror.loadNutritionEntries(context: modelContext, since: since)
      // Training: session-type catalog + suggested + daysAgo. Feeds the
      // menu's "Start: {suggested}" row and the "Recent" section. All
      // three come from existing endpoints — no new server work needed.
      trainingSessionTypes = ChecklistMirror.loadSessionTypes(context: modelContext)
      let resp = ChecklistMirror.loadSuggestedWorkout(context: modelContext)
      trainingSuggestedId = resp.suggested?.type
      trainingDaysAgo = resp.daysAgo
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
    async let wRows = try? await WithingsProvider.shared.fetchHistory(days: 90)
    let gT: GutDayResponse? = ChecklistMirror.loadGutDay(context: modelContext, date: SeptenaDate.today)
    let gH: GutHistoryResponse? = ChecklistMirror.loadGutHistory(context: modelContext, days: 90)
    let mT: MoodDayResponse = ChecklistMirror.loadMoodDay(context: modelContext, date: SeptenaDate.today)
    let mH: MoodHistoryResponse = ChecklistMirror.loadMoodHistory(context: modelContext, days: 90)
    moodToday = mT
    ResponseCache.save(mT, forKey: CacheKey.moodToday)
    moodHistory = mH.daily
    ResponseCache.save(mH.daily, forKey: CacheKey.moodHistory)
    let wR = await wRows
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
      let repaintToday = ChecklistMirror.loadNutritionToday(context: modelContext)
      todayNutrition = repaintToday
      todayProteinSum = repaintToday.reduce(0) { $0 + $1.proteinG }
      todayKcalSum    = repaintToday.reduce(0) { $0 + $1.kcal }
      nutritionStats = ChecklistMirror.buildNutritionStatsResponse(context: modelContext, days: 90)
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
      let d = ChecklistMirror.loadCannabisDay(context: modelContext, date: SeptenaDate.today)
      cannabisToday = d
      ResponseCache.save(d, forKey: CacheKey.cannabisToday)
      let h = ChecklistMirror.loadCannabisHistory(context: modelContext, days: 90).daily
      cannabisHistory = h
      ResponseCache.save(h, forKey: CacheKey.cannabisHistory)
    case .caffeine:
      let d = ChecklistMirror.loadCaffeineDay(context: modelContext, date: SeptenaDate.today)
      caffeineToday = d
      ResponseCache.save(d, forKey: CacheKey.caffeineToday)
      let h = ChecklistMirror.loadCaffeineHistory(context: modelContext, days: 90).daily
      caffeineHistory = h
      ResponseCache.save(h, forKey: CacheKey.caffeineHistory)
    case .gut:
      let d = ChecklistMirror.loadGutDay(context: modelContext, date: SeptenaDate.today)
      gutToday = d
      ResponseCache.save(d, forKey: CacheKey.gutToday)
      let h = ChecklistMirror.loadGutHistory(context: modelContext, days: 90).daily
      gutHistory = h
      ResponseCache.save(h, forKey: CacheKey.gutHistory)
    case .nutrition:
      let todays = ChecklistMirror.loadNutritionToday(context: modelContext)
      todayNutrition = todays
      todayProteinSum = todays.reduce(0) { $0 + $1.proteinG }
      todayKcalSum    = todays.reduce(0) { $0 + $1.kcal }
      ResponseCache.save(todays, forKey: CacheKey.todayNutrition)
      let s = ChecklistMirror.buildNutritionStatsResponse(context: modelContext, days: 90)
      nutritionStats = s
      ResponseCache.save(s, forKey: CacheKey.nutritionStats)
    case .habits:
      async let _ = dailies.load()
      let h = ChecklistMirror.loadHabitsHistory(
        context: LocalStore.shared.container.mainContext, days: 90)
      habitHistory = h.daily.map { $0.done }
      ResponseCache.save(habitHistory, forKey: CacheKey.habitHistory)
    case .chores:
      async let _ = dailies.load()
      let c = ChecklistMirror.loadChoresHistory(
        context: LocalStore.shared.container.mainContext, days: 90)
      choreHistory = c.daily.map { $0.completed }
      ResponseCache.save(choreHistory, forKey: CacheKey.choreHistory)
    case .supplements:
      async let _ = dailies.load()
      let s = ChecklistMirror.loadSupplementsHistory(
        context: LocalStore.shared.container.mainContext, days: 90)
      supplementHistory = s.daily.map { $0.done }
      ResponseCache.save(supplementHistory, forKey: CacheKey.supplementHistory)
    case .groceries:
      let g = ChecklistMirror.loadGroceryItems(context: modelContext)
      groceries = g
      ResponseCache.save(g, forKey: CacheKey.groceries)
    case .tasks:
      async let tc = TaskReads.counts(
        context: LocalStore.shared.container.mainContext)
      let th: TasksHistory? = TaskReads.tasksHistory(
        days: 90, context: LocalStore.shared.container.mainContext)
      async let tl = TaskReads.list(
        view: "logbook", days: 1,
        context: LocalStore.shared.container.mainContext)
      let t = await tc
      taskCounts = t
      ResponseCache.save(t, forKey: CacheKey.taskCounts)
      if let th {
        tasksHistory = th
        ResponseCache.save(th, forKey: CacheKey.tasksHistory)
      }
      let items = await tl.items
      completedTasks = items
      ResponseCache.save(items, forKey: CacheKey.completedTasks)
    case .training:
      let c = ChecklistMirror.loadTrainingCardioHistory(context: modelContext, days: 90)
      cardio = c
      ResponseCache.save(c, forKey: CacheKey.cardio)
      let e = ChecklistMirror.loadTrainingEntries(context: modelContext,
                                                  since: sinceDate(daysBack: 90))
      trainingSessionDates = Set(e.map(\.date))
      recentTraining = e
      ResponseCache.save(trainingSessionDates, forKey: CacheKey.trainingDates)
      ResponseCache.save(e, forKey: CacheKey.recentTraining)
    }
  }

  /// Re-read every CK-backed tile from its SwiftData mirror. Triggered
  /// by `.septenaDataChanged` so CK fetch arrivals (push, periodic, or
  /// cross-device writes) repaint the dashboard. Tasks have their own
  /// `.septenaTasksChanged` path and are skipped here.
  private func repaintAllMirrors() async {
    for section in AddInfoSection.allCases where section != .tasks {
      await refresh(section: section)
    }
  }

  private func sinceDate(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
  }

  /// Sessions in the trailing 7 days, derived from the full 90-day
  /// `trainingSessionDates` set. Lexicographic compare on ISO
  /// `yyyy-MM-dd` strings is correct ordering, no Date parse needed.
  private var weeklySessionCount: Int {
    let cutoff = sinceDate(daysBack: 7)
    return trainingSessionDates.filter { $0 >= cutoff }.count
  }

  // MARK: - Today timeline (single row above the tile grid)

  private var todayTimeline: some View {
    WeekDashboardTimelineCard(
      date: clock.today,
      oura: ouraNights.first,
      caffeine: caffeineToday?.entries ?? [],
      cannabis: cannabisToday?.entries ?? [],
      nutrition: todayNutrition,
      gut: gutToday?.entries ?? [],
      mood: moodToday?.entries ?? [],
      habits: dailies.habits,
      supplements: dailies.supplements,
      chores: dailies.chores,
      training: recentTraining,
      tasks: completedTasks,
      calendar: dailies.calendarEvents,
      macroColors: macroColors
    )
    // The timeline is the ambient, read-only glance at today; tapping it
    // routes to Next — the single unified "today page" (things to do up
    // top, things done at the bottom) — rather than a parallel log sheet.
    .onTapGesture {
      Haptics.tap()
      tabSelection.current = .next
    }
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Opens Next")
  }

  // MARK: - Layout mode dispatch

  /// Resolved layout mode from `@AppStorage`. Falls back to `.tiles`
  /// for unknown raw values (e.g. a future build wrote a case this
  /// build doesn't know about).
  private var currentLayoutMode: HomepageLayoutMode {
    HomepageLayoutMode(rawValue: homepageLayoutRaw) ?? .tiles
  }

  /// Renders the homepage body for the currently-selected layout mode.
  /// Phase 2: only `.tiles` is implemented; the other modes render the
  /// shared "Coming soon" placeholder. Phases 3-5 swap each case out
  /// for a real renderer reading from `HomepageDomainData`.
  @ViewBuilder
  private var layoutBody: some View {
    switch currentLayoutMode {
    case .tiles:
      LazyVGrid(columns: columns, spacing: 14) {
        tiles
      }
    case .dense:
      DenseHomepageView(
        items: visibleDomainData,
        onTap: handleDomainTap,
        menuContent: { domain in quickAddMenu(for: domain) }
      )
    case .heatmap:
      HeatmapHomepageView(
        items: visibleDomainData,
        onTap: handleDomainTap,
        menuContent: { domain in quickAddMenu(for: domain) }
      )
    case .correlations:
      CorrelationsHomepageView()
    }
  }

  /// Domain data array in canonical order, filtered by server visibility
  /// + dropping any domain whose builder returned `nil` (currently only
  /// Activity-on-Mac when HealthKit is unavailable). Future renderers
  /// (Heatmap, List) consume this same property.
  private var visibleDomainData: [HomepageDomainData] {
    visibleDomains.compactMap { domainData(for: $0) }
  }

  /// Single tap router for `HomepageDomainData.tap` actions. Phase 3
  /// renderers don't know about `sheetDest` or `tabSelection` — they
  /// call back here, mirroring the per-tile gestures the Tiles mode
  /// wires up inline.
  private func handleDomainTap(_ tap: DomainTapAction) {
    switch tap {
    case .openSheet(let dest):     sheetDest = dest
    case .switchToTasksTab:        openTasksFromTile()
    }
  }

  /// Single entry point for "user tapped the Tasks tile on the homepage."
  /// Every dashboard layout (Tiles direct tap, Dense + Heatmap via
  /// `DomainTapAction.switchToTasksTab`) routes through here so the
  /// Settings > Tasks > Open in picker is honoured uniformly. The
  /// `tasksQuickAddMenu` long-press items intentionally bypass this —
  /// they're explicit "jump to Inbox/Today filter" actions, not a
  /// generic "open Tasks."
  private func openTasksFromTile() {
    switch TasksOpenMode(rawValue: tasksOpenInRaw) ?? .drawer {
    case .drawer: sheetDest = .tasks
    case .tab:    tabSelection.current = .tasks
    }
  }

  /// Per-domain quickadd menu, surfaced as a `.contextMenu` on the
  /// Dense and Heatmap rows. Mirrors the same menus the Tiles renderer
  /// attaches inline (`habitsQuickAddMenu`, `caffeineQuickAddMenu`,
  /// etc.). Domains without a quickadd affordance (sleep, body,
  /// activity) return `EmptyView`, which SwiftUI silently suppresses
  /// — so those rows show no menu on long-press / right-click rather
  /// than an empty popover.
  @ViewBuilder
  private func quickAddMenu(for domain: HomepageDomain) -> some View {
    switch domain {
    case .tasks:       tasksQuickAddMenu
    case .habits:      habitsQuickAddMenu
    case .training:    trainingQuickAddMenu
    case .chores:      choresQuickAddMenu
    case .supplements: supplementsQuickAddMenu
    case .nutrition:   nutritionQuickAddMenu
    case .groceries:   groceriesQuickAddMenu
    case .caffeine:    caffeineQuickAddMenu
    case .cannabis:    cannabisQuickAddMenu
    case .gut:         gutQuickAddMenu
    case .mood:        moodQuickAddMenu
    case .sleep, .body, .activity:
      EmptyView()
    }
  }

  // MARK: - Tiles
  //
  // Order and visibility both come from Settings (`settingsStore.sections`),
  // and the resolved list is the same across every layout mode
  // (Tiles / Dense / Heatmap). User reorders in Settings → Sections →
  // all three modes update. `HomepageDomain.defaultOrder` is only the
  // cold-launch fallback before the section list has loaded.

  @ViewBuilder
  private var tiles: some View {
    ForEach(visibleDomains) { domain in
      tile(for: domain)
    }
  }

  /// Domain order + visibility, driven by Settings so reordering in
  /// Settings → Sections applies uniformly to every layout mode.
  /// Falls back to `HomepageDomain.defaultOrder` only on cold launch /
  /// load failure. Section keys we don't recognise as a
  /// `HomepageDomain` (e.g. `"calendar"`, which is surfaced inline in
  /// the Next tab) are dropped.
  private var visibleDomains: [HomepageDomain] {
    let enabledKeys = settingsStore.sections.filter(\.isEnabled).map(\.key)
    guard !enabledKeys.isEmpty else { return HomepageDomain.defaultOrder }
    return enabledKeys.compactMap { HomepageDomain(rawValue: $0) }
  }

  @ViewBuilder
  private func tile(for domain: HomepageDomain) -> some View {
    switch domain {
    case .tasks:       tasksTile
    case .habits:      habitsTile
    case .training:    trainingTile
    case .chores:      choresTile
    case .supplements: supplementsTile
    case .sleep:       sleepTile
    case .nutrition:   nutritionTile
    case .groceries:   groceriesTile
    case .caffeine:    caffeineTile
    case .cannabis:    cannabisTile
    case .body:        bodyTile
    case .gut:         gutTile
    case .mood:        moodTile
    case .activity:    activityTile
    }
  }

  // MARK: - Mode-agnostic domain data
  //
  // Phase 1b: every domain produces a `HomepageDomainData` from the
  // same @State the bespoke `Week*Tile` views read from. The current
  // Tiles renderer doesn't consume this yet — it's the contract future
  // modes (Dense / Heatmap / List) will read from. Keeping the
  // construction in one place per domain means the four modes can't
  // drift on what "today's number" means.
  //
  // Returns `nil` only for Activity when HealthKit isn't available
  // (matches the current tile's behaviour of rendering EmptyView).
  func domainData(for domain: HomepageDomain) -> HomepageDomainData? {
    switch domain {
    case .tasks:       return tasksDomainData()
    case .habits:      return habitsDomainData()
    case .training:    return trainingDomainData()
    case .chores:      return choresDomainData()
    case .supplements: return supplementsDomainData()
    case .sleep:       return sleepDomainData()
    case .nutrition:   return nutritionDomainData()
    case .groceries:   return groceriesDomainData()
    case .caffeine:    return caffeineDomainData()
    case .cannabis:    return cannabisDomainData()
    case .body:        return bodyDomainData()
    case .gut:         return gutDomainData()
    case .mood:        return moodDomainData()
    case .activity:    return activityDomainData()
    }
  }

  private func tasksDomainData() -> HomepageDomainData {
    let openToday = taskCounts.map { $0.todayCount + $0.reviewCount } ?? 0
    let inbox = taskCounts?.inboxCount ?? 0
    let upcoming = taskCounts?.upcomingCount ?? 0
    let doneToday = tasksHistory?.daily.last?.done ?? 0
    let totalToday = doneToday + openToday
    let bars = tasksHistory?.daily.map(\.done) ?? []
    return HomepageDomainData(
      domain: .tasks,
      title: "Tasks",
      accent: theme.color(for: "tasks"),
      headline: "\(openToday) open · \(doneToday)/\(totalToday) done",
      headlineStats: [
        .init(label: "Today", value: "\(openToday)"),
        .init(label: "Inbox", value: "\(inbox)"),
        .init(label: "Upcoming", value: "\(upcoming)"),
      ],
      progress: .init(label: "Done today",
                      current: Double(doneToday),
                      target: Double(max(totalToday, 1))),
      history: .bars(bars),
      tap: .switchToTasksTab
    )
  }

  private func habitsDomainData() -> HomepageDomainData {
    let total = dailies.habits.count
    let done = dailies.habits.filter { $0.done }.count
    let skipped = dailies.habits.filter { $0.skipped }.count
    return HomepageDomainData(
      domain: .habits,
      title: "Habits",
      accent: theme.color(for: "habits"),
      headline: skipped > 0
        ? "\(done)/\(total) · \(skipped) skipped"
        : "\(done)/\(total)",
      headlineStats: [
        .init(label: "Done", value: "\(done)"),
        .init(label: "Skipped", value: "\(skipped)"),
        .init(label: "Total", value: "\(total)"),
      ],
      progress: .init(label: "Today",
                      current: Double(done),
                      target: Double(max(total, 1))),
      history: .bars(habitHistory),
      tap: .openSheet(.habits)
    )
  }

  private func trainingDomainData() -> HomepageDomainData {
    // Sessions + Z2 minutes are always **trailing 7 days** so they read
    // sensibly against the weekly target (`targetWeeklyMin`, default
    // 150). The training data window is 90 days for the heatmap strip,
    // but the headline / progress are weekly stats — independent of the
    // history-series window.
    let sessionCount = weeklySessionCount
    let minutes = Int(cardio?.daily.last?.rolling7d ?? 0)
    let target = cardio?.targetWeeklyMin ?? 150
    // Domain data drives Heatmap mode, which needs the long window —
    // the tile (which uses `lastSevenDays`) stays at 7 by design.
    let days = lastNDays(90)
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
    let strengthSeries = days.map { strengthByDate[$0] ?? 0 }
    let cardioSeries = days.map { cardioByDate[$0] ?? 0 }
    return HomepageDomainData(
      domain: .training,
      title: "Training",
      accent: theme.color(for: "training"),
      headline: "\(sessionCount) sessions · \(minutes)/\(target) min",
      headlineStats: [
        .init(label: "Sessions", value: "\(sessionCount)"),
        .init(label: "Z2", value: "\(minutes)", unit: "min"),
      ],
      progress: .init(label: "Weekly Z2",
                      current: Double(minutes),
                      target: Double(max(target, 1)),
                      unit: "min"),
      history: .stackedBars(primary: strengthSeries, secondary: cardioSeries),
      tap: .openSheet(.training),
      // Training spikes hard on rest days (zero) and peaks on session
      // days. The Dense sparkline smooths to a trailing-7d average —
      // same reason Apple Watch's Exercise ring shows weekly load,
      // not point samples. Heatmap mode keeps daily cells.
      smoothSparkline: true
    )
  }

  private func choresDomainData() -> HomepageDomainData {
    let todayISO = SeptenaDate.today
    let serverDoneIDs = Set(dailies.chores
                              .filter { $0.lastCompleted == todayISO }
                              .map(\.id))
    let doneIDs = serverDoneIDs.union(dailies.completedChores)
    let dueToday = dailies.chores.filter {
      $0.daysOverdue == 0 && !doneIDs.contains($0.id)
    }.count
    let overdue = dailies.chores.filter {
      $0.daysOverdue > 0 && !doneIDs.contains($0.id)
    }.count
    let done = doneIDs.count
    let total = dueToday + overdue + done
    return HomepageDomainData(
      domain: .chores,
      title: "Chores",
      accent: theme.color(for: "chores"),
      headline: overdue > 0
        ? "\(done)/\(total) · \(overdue) overdue"
        : "\(done)/\(total)",
      headlineStats: [
        .init(label: "Due", value: "\(dueToday)"),
        .init(label: "Overdue", value: "\(overdue)"),
        .init(label: "Done", value: "\(done)"),
      ],
      progress: .init(label: "Today",
                      current: Double(done),
                      target: Double(max(total, 1))),
      history: .bars(choreHistory),
      tap: .openSheet(.chores)
    )
  }

  private func supplementsDomainData() -> HomepageDomainData {
    let total = dailies.supplements.count
    let done = dailies.supplements.filter { $0.done }.count
    return HomepageDomainData(
      domain: .supplements,
      title: "Supplements",
      accent: theme.color(for: "supplements"),
      headline: "\(done)/\(total)",
      headlineStats: [
        .init(label: "Done", value: "\(done)"),
        .init(label: "Total", value: "\(total)"),
      ],
      progress: .init(label: "Today",
                      current: Double(done),
                      target: Double(max(total, 1))),
      history: .bars(supplementHistory),
      tap: .openSheet(.supplements)
    )
  }

  private func sleepDomainData() -> HomepageDomainData {
    let last = ouraNights.first
    let lastH = last?.totalH ?? 0
    let score = last?.sleepScore.map { "\($0)" } ?? "—"
    // Oura only records completed nights, so the array ends at yesterday.
    // Append a 0 for today (no sleep recorded yet) so buildLevelMap anchors
    // bars[0] to today-90 instead of today-89, giving the week-rounded first
    // column's Monday cell an actual data entry rather than a phantom gap.
    let bars = ouraNights.reversed().map { $0.sleepScore ?? 0 } + [0]
    return HomepageDomainData(
      domain: .sleep,
      title: "Sleep",
      accent: theme.color(for: "sleep"),
      headline: lastH > 0
        ? "\(formatHoursShort(lastH)) · score \(score)"
        : "—",
      headlineStats: [
        .init(label: "Hours", value: formatHoursShort(lastH)),
        .init(label: "Score", value: score),
      ],
      progress: nil,
      history: .bars(bars),
      tap: .openSheet(.sleep),
      trailingTodayPending: true,
      autoscaleSparkline: true
    )
  }

  private func nutritionDomainData() -> HomepageDomainData {
    let accent = theme.color(for: "nutrition")
    let state = currentFastingState(now: Date())
    let metric = NutritionHeatmapMetric(rawValue: nutritionHeatmapMetricRaw) ?? .protein

    // History series: heatmap metric preference wins for any mode that
    // reads `history` (Dense, Heatmap). Tiles use `nutritionTile` and
    // ignore this. Only honor the "fasting" pick when the master
    // toggle is on, otherwise the picker preference is dormant.
    let history: HistorySeries = {
      if nutritionTrackFasting, metric == .fasting {
        let windows = nutritionStats?.fasting ?? []
        let hours = windows.map { Int(($0.hours ?? 0).rounded()) }
        return .bars(hours.isEmpty ? Array(repeating: 0, count: 90) : hours)
      }
      let bars = nutritionStats?.daily.map { Int($0.proteinG) }
                ?? Array(repeating: 0, count: 90)
      return .bars(bars)
    }()

    if nutritionTrackFasting, case .fasting(_, let since, let totalMin) = state {
      let targetMin = nutritionTarget?.fasting?.min ?? FastingDefaults.targetMinH
      let h = totalMin / 60, m = totalMin % 60
      return HomepageDomainData(
        domain: .nutrition,
        title: "Nutrition",
        accent: accent,
        headline: "\(h)h \(m)m fasting · since \(since)",
        headlineStats: [
          .init(label: "Fasting", value: "\(h)h \(m)m"),
          .init(label: "Since", value: since),
        ],
        progress: .init(label: "Fast vs target",
                        current: min(Double(totalMin) / 60, targetMin),
                        target: max(targetMin, 1),
                        unit: "h"),
        history: history,
        tap: .openSheet(.nutrition)
      )
    }

    let proteinTarget = nutritionTarget?.protein.min ?? 150
    return HomepageDomainData(
      domain: .nutrition,
      title: "Nutrition",
      accent: accent,
      headline: "\(Int(todayProteinSum))g protein · \(Int(todayKcalSum)) kcal",
      headlineStats: [
        .init(label: "Protein", value: "\(Int(todayProteinSum))", unit: "g"),
        .init(label: "Kcal", value: "\(Int(todayKcalSum))"),
      ],
      progress: .init(label: "Today's protein",
                      current: todayProteinSum,
                      target: max(proteinTarget, 1),
                      unit: "g"),
      history: history,
      tap: .openSheet(.nutrition)
    )
  }

  private func groceriesDomainData() -> HomepageDomainData {
    let lowCount = groceries.filter { $0.low }.count
    let stocked = groceries.count - lowCount
    let missingPerDay = groceriesMissingPerDay()
    return HomepageDomainData(
      domain: .groceries,
      title: "Groceries",
      accent: theme.color(for: "groceries"),
      headline: lowCount > 0
        ? "\(lowCount) low · \(stocked) stocked"
        : "\(stocked) stocked",
      headlineStats: [
        .init(label: "Low", value: "\(lowCount)"),
        .init(label: "Stocked", value: "\(stocked)"),
        .init(label: "Items", value: "\(groceries.count)"),
      ],
      progress: groceries.isEmpty ? nil : DomainProgress(
        label: "Stocked",
        current: Double(stocked),
        target: Double(groceries.count)
      ),
      history: .bars(missingPerDay),
      tap: .openSheet(.groceries)
    )
  }

  private func caffeineDomainData() -> HomepageDomainData {
    let sessions = caffeineToday?.sessionCount ?? 0
    let grams = caffeineToday?.totalG ?? 0
    let bars = caffeineHistory.map { $0.sessions }
    let dailyLimit = 3
    return HomepageDomainData(
      domain: .caffeine,
      title: "Caffeine",
      accent: theme.color(for: "caffeine"),
      headline: "\(sessions) · \(String(format: "%.1f", grams))g",
      headlineStats: [
        .init(label: "Today", value: "\(sessions)"),
        .init(label: "Grams", value: String(format: "%.1f", grams), unit: "g"),
      ],
      progress: .init(label: "Today / limit",
                      current: Double(min(sessions, dailyLimit)),
                      target: Double(dailyLimit)),
      history: .bars(bars.isEmpty ? Array(repeating: 0, count: 90) : bars),
      tap: .openSheet(.caffeine)
    )
  }

  private func cannabisDomainData() -> HomepageDomainData {
    let sessions = cannabisToday?.sessionCount ?? 0
    let grams = cannabisToday?.totalG ?? 0
    let bars = cannabisHistory.map { $0.sessions }
    let dailyLimit = 2
    return HomepageDomainData(
      domain: .cannabis,
      title: "Cannabis",
      accent: theme.color(for: "cannabis"),
      headline: "\(sessions) · \(String(format: "%.2f", grams))g",
      headlineStats: [
        .init(label: "Today", value: "\(sessions)"),
        .init(label: "Grams", value: String(format: "%.2f", grams), unit: "g"),
      ],
      progress: .init(label: "Today / limit",
                      current: Double(min(sessions, dailyLimit)),
                      target: Double(dailyLimit)),
      history: .bars(bars.isEmpty ? Array(repeating: 0, count: 90) : bars),
      tap: .openSheet(.cannabis)
    )
  }

  private func bodyDomainData() -> HomepageDomainData {
    let latest = bodyRows.first
    let weight = latest?.weightKg
    let fat = latest?.fatPct
    let actualSeries = weeklyWeightActual()
    let present = actualSeries.compactMap { $0 }
    let avg = present.isEmpty ? 0.0 : present.reduce(0, +) / Double(present.count)
    let centeredValues: [Double?] = actualSeries.map { $0.map { $0 - avg } }
    let fatTarget: Double = 18
    return HomepageDomainData(
      domain: .body,
      title: "Body",
      accent: theme.color(for: "body"),
      headline: {
        let parts = [
          weight.map { String(format: "%.1f kg", $0) },
          fat.map { String(format: "%.1f%%", $0) },
        ].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
      }(),
      headlineStats: [
        .init(label: "Weight",
              value: weight.map { String(format: "%.1f", $0) } ?? "—",
              unit: "kg"),
        .init(label: "Fat",
              value: fat.map { String(format: "%.1f", $0) } ?? "—",
              unit: "%"),
      ],
      progress: .init(label: "Body fat target",
                      current: fat.map { min($0, fatTarget * 2) } ?? 0,
                      target: fatTarget,
                      unit: "%"),
      history: .centered(values: centeredValues, baseline: avg),
      tap: .openSheet(.body)
    )
  }

  private func gutDomainData() -> HomepageDomainData {
    let count = gutToday?.movementCount ?? 0
    let discomfort = gutToday?.totalDiscomfortH ?? 0
    let bars = gutHistory.map { $0.movements }
    let dailyTarget = 2
    return HomepageDomainData(
      domain: .gut,
      title: "Gut",
      accent: theme.color(for: "gut"),
      headline: discomfort > 0
        ? "\(count) · \(String(format: "%.1f", discomfort))h disc."
        : "\(count)",
      headlineStats: [
        .init(label: "Today", value: "\(count)"),
        .init(label: "Discomfort",
              value: String(format: "%.1f", discomfort),
              unit: "h"),
      ],
      progress: .init(label: "Today / typical",
                      current: Double(min(count, dailyTarget)),
                      target: Double(dailyTarget)),
      history: .bars(bars.isEmpty ? Array(repeating: 0, count: 90) : bars),
      tap: .openSheet(.gut)
    )
  }

  private func activityDomainData() -> HomepageDomainData? {
    let bridge = HealthKitBridge.shared
    guard bridge.isAvailable else { return nil }
    let stepsTarget = 8000
    return HomepageDomainData(
      domain: .activity,
      title: "Activity",
      accent: theme.color(for: "activity"),
      headline: "\(bridge.stepsToday) steps · \(bridge.exerciseMinutesToday) min",
      headlineStats: [
        .init(label: "Steps", value: "\(bridge.stepsToday)"),
        .init(label: "Active",
              value: "\(Int(bridge.activeKcalToday))",
              unit: "kcal"),
        .init(label: "Exercise",
              value: "\(bridge.exerciseMinutesToday)",
              unit: "m"),
      ],
      progress: .init(label: "Steps target",
                      current: Double(min(bridge.stepsToday, stepsTarget)),
                      target: Double(stepsTarget)),
      history: .bars(bridge.stepsHistory),
      tap: .openSheet(.activity)
    )
  }

  /// Setting that decides whether tapping the Tasks tile drops a Today
  /// drawer (sheet) or jumps to the full Tasks tab. Default `drawer` so
  /// Tasks behaves like every other section tile.
  @AppStorage(SettingsKey.tasksOpenIn)
  private var tasksOpenInRaw: String = TasksOpenMode.drawer.rawValue

  // Tasks — live counts from /api/tasks/counts and per-day completion
  // history from /api/tasks/history. Tap behaviour is user-configurable
  // via Settings > Tasks > Open in: drawer (default, like other sections)
  // or the Tasks tab.
  private var tasksTile: some View {
    let openToday = taskCounts.map { $0.todayCount + $0.reviewCount } ?? 0
    let inbox = taskCounts?.inboxCount ?? 0
    let upcoming = taskCounts?.upcomingCount ?? 0
    let doneToday = tasksHistory?.daily.last?.done ?? 0
    let totalToday = doneToday + openToday
    // Tile histograms render at 7 days regardless of the underlying
    // loader window (90d for Heatmap + Dense). At ~150pt tile width,
    // 90 bars compress into invisibility. Sparkline mode reads from
    // the full @State arrays via `HomepageDomainData`, so this slice
    // is tile-mode-only.
    let bars = Array((tasksHistory?.daily.map(\.done) ?? []).suffix(7))
    return WeekTasksTile(
      accent: theme.color(for: "tasks"),
      openToday: openToday,
      inbox: inbox,
      upcoming: upcoming,
      doneToday: doneToday,
      totalToday: totalToday,
      bars: bars
    )
    .contentShape(Rectangle())
    .onTapGesture { openTasksFromTile() }
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
        // Trip the "start inline create" flag on the next runloop so
        // the tab/filter swap settles first. Same-tick mutation would
        // let TaskListView's .onAppear (tab becoming visible) AND
        // .onChange(shouldStartCreating) both fire, each calling
        // startDraft and creating duplicate tasks; the filter onChange
        // would then clobber editingTaskId so neither row stays in the
        // inline editor.
        DispatchQueue.main.async {
          nav.shouldStartCreating = true
        }
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
    return WeekHabitsTile(
      accent: theme.color(for: "habits"),
      done: done,
      skipped: skipped,
      total: total,
      history: Array(habitHistory.suffix(7))
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
    dailies.toggleHabit(item, mutator: checklistMutator, motion: motion)
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
    // Same fix as `trainingDomainData`: stats are trailing 7 days so
    // they read sensibly against the weekly Z2 target. Tile bar chart
    // still renders 7 days regardless via `lastSevenDays`.
    let sessionCount = weeklySessionCount
    let minutes = Int(cardio?.daily.last?.rolling7d ?? 0)
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

    return WeekTrainingTile(
      accent: accent,
      sessionCount: sessionCount,
      minutes: minutes,
      target: target,
      strengthBars: strengthBars,
      cardioBars: cardioBars
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
      activeDraft: trainingDraft.draft,
      onStart: { typeId in
        // Empty id = "no suggestion, open the picker" — leave pendingType
        // nil so TrainingSessionView shows its picker. Otherwise pass the
        // chosen id through nav so the sheet auto-starts the draft.
        if !typeId.isEmpty {
          nav.pendingTrainingType = typeId
        }
        nav.showTrainingSession = true
      },
      onResume: {
        // Resume = open the sheet without setting `pendingTrainingType`.
        // TrainingSessionView's auto-start logic only fires when
        // `store.draft == nil`, so with a live draft the sheet just
        // shows it.
        nav.showTrainingSession = true
      }
    )
  }

  /// Last 7 ISO yyyy-MM-dd dates, oldest → newest. Used to align the
  /// training tile's two-series histogram so absent days still render
  /// as zero-height bars instead of being collapsed out of the chart.
  /// Stays at 7 — the training tile's bar chart was designed for it
  /// and looked cramped at 30. The longer-window training domain data
  /// uses `lastNDays(_:)` directly.
  private var lastSevenDays: [String] { lastNDays(7) }

  /// Last N ISO yyyy-MM-dd dates, oldest → newest. Generalisation of
  /// `lastSevenDays` for callers that need a longer window — currently
  /// `trainingDomainData` (90 days for the Heatmap mode).
  private func lastNDays(_ n: Int) -> [String] {
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    return (0..<n).reversed().compactMap { offset in
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
    return WeekChoresTile(
      accent: theme.color(for: "chores"),
      dueToday: dueToday,
      overdue: overdue,
      done: done,
      total: total,
      history: Array(choreHistory.suffix(7))
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
    dailies.completeChore(chore, mutator: checklistMutator, motion: motion)
    AddInfoSection.chores.notifyTilesChanged()
    Haptics.tick()
  }

  // Supplements — live taken/total today plus 7-day adherence histogram.
  private var supplementsTile: some View {
    let total = dailies.supplements.count
    let done = dailies.supplements.filter { $0.done }.count
    return WeekSupplementsTile(
      accent: theme.color(for: "supplements"),
      done: done,
      total: total,
      history: Array(supplementHistory.suffix(7))
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
    dailies.toggleSupplement(item, mutator: checklistMutator, motion: motion)
    AddInfoSection.supplements.notifyTilesChanged()
    Haptics.tick()
  }

  // Sleep — Oura-backed. Last night's total + score; 7-day hours
  // histogram. Reverse the server order so the bar furthest right is
  // most-recent.
  private var sleepTile: some View {
    let last = ouraNights.first
    let lastH = last?.totalH ?? 0
    let score = last?.sleepScore.map { "\($0)" } ?? "—"
    let bars = Array(ouraNights.reversed().map { $0.sleepScore ?? 0 }.suffix(7))
    return Button { sheetDest = .sleep } label: {
      WeekSleepTile(
        accent: theme.color(for: "sleep"),
        lastHoursText: formatHoursShort(lastH),
        lastHours: lastH,
        score: score,
        bars: bars
      )
    }
    .buttonStyle(.plain)
  }

  // Groceries — what's running low, as the headline stat.
  private var groceriesTile: some View {
    let lowCount = groceries.filter { $0.low }.count
    let stocked = groceries.count - lowCount
    let missingPerDay = groceriesMissingPerDay()
    return WeekGroceriesTile(
      accent: theme.color(for: "groceries"),
      lowCount: lowCount,
      stocked: stocked,
      totalItems: groceries.count,
      missingPerDay: missingPerDay
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
    SeptenaServices.shared.groceryMutator.setLow(id: item.id, low: true)
    // Refresh the tile state from SwiftData so the same menu re-opened a
    // moment later doesn't re-list this item under "stocked."
    groceries = ChecklistMirror.loadGroceryItems(context: modelContext)
    AddInfoSection.groceries.notifyTilesChanged()
    Haptics.tick()
  }

  /// Items bought per day for the last 30 days (oldest → newest, today
  /// last), derived from each item's `lastBought` date. Bumped from 7
  /// → 30 in Phase 4b for the Heatmap mode strip.
  /// Trailing 30-day series of "items missing (low) per day."
  ///
  /// Stock level is state, not a daily event, so there's nothing to
  /// reconstruct from the current snapshot. Instead we stamp today's
  /// missing count into `GroceryStockHistory` on each load and read the
  /// accumulated series back — the strip fills in going forward and
  /// today's bar is always exact.
  private func groceriesMissingPerDay() -> [Int] {
    let missingToday = groceries.filter { $0.low }.count
    GroceryStockHistory.record(missing: missingToday)
    return GroceryStockHistory.series(days: 30)
  }

  // Caffeine — today's session count + grams; 7-day session histogram.
  private var caffeineTile: some View {
    let accent = theme.color(for: "caffeine")
    let sessions = caffeineToday?.sessionCount ?? 0
    let grams = caffeineToday?.totalG ?? 0
    let bars = Array(caffeineHistory.map { $0.sessions }.suffix(7))
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
    SeptenaServices.shared.caffeineMutator.addEntry(
      date: SeptenaDate.today, time: nowHHMM(),
      method: method, beans: beans, grams: grams)
    AddInfoSection.caffeine.notifyTilesChanged()
    Haptics.tick()
  }

  // Cannabis — same shape as caffeine.
  private var cannabisTile: some View {
    let accent = theme.color(for: "cannabis")
    let sessions = cannabisToday?.sessionCount ?? 0
    let grams = cannabisToday?.totalG ?? 0
    let bars = Array(cannabisHistory.map { $0.sessions }.suffix(7))
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

  /// Last vape entry across all days — mirrors the webapp's 30-day lookback
  /// so yesterday's strain/capsule is visible on the menu when there's been
  /// no vape today. Populated by `loadAll()` via a SwiftData fetch and
  /// refreshed after each commit so the "Continue · Hit N" counter advances.
  private var lastCannabisVape: CannabisEntry? {
    cannabisToday?.entries.reversed().first { $0.method == "vape" } ?? cannabisLastVape
  }

  /// Edit-last opens the destination view (rather
  /// than threading an EditCannabisEntrySheet through the dashboard)
  /// since the destination already has that affordance.
  @ViewBuilder private var cannabisQuickAddMenu: some View {
    CannabisQuickAddMenu(
      lastVape: lastCannabisVape,
      usesPerCapsule: cannabisUsesPerCapsule,
      onCommit: { method, hit in
        commitCannabis(method: method, hit: hit)
      },
      onEditLast: lastCannabisVape == nil ? nil : { sheetDest = .cannabis }
    )
  }

  private func commitCannabis(method: String, hit: Int?) {
    SeptenaServices.shared.cannabisMutator.addEntry(
      date: SeptenaDate.today, time: nowHHMM(),
      method: method, hit: hit)
    // Refresh tile state from the freshly-mutated SwiftData store so the
    // "Continue · Hit N" counter advances immediately.
    cannabisToday = ChecklistMirror.loadCannabisDay(context: modelContext, date: SeptenaDate.today)
    ResponseCache.save(cannabisToday, forKey: CacheKey.cannabisToday)
    AddInfoSection.cannabis.notifyTilesChanged()
    Haptics.tick()
  }

  // Body — latest Withings weigh-in + bidirectional weight chart.
  // Only actual weigh-in days produce bars; gaps stay nil so carry-forward
  // values don't collapse everything to zero deviation.
  private var bodyTile: some View {
    let accent = theme.color(for: "body")
    let latest = bodyRows.first
    let weight = latest?.weightKg
    let fat    = latest?.fatPct
    // Tile chart is a 7-day window; the full 90-day series lives on
    // `bodyDomainData` for Sparkline / Heatmap modes.
    let actualSeriesFull = weeklyWeightActual()
    let actualSeries = Array(actualSeriesFull.suffix(7))
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
    let bars = Array(gutHistory.map { $0.movements }.suffix(7))
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
    SeptenaServices.shared.gutMutator.addEntry(
      date: SeptenaDate.today, time: nowHHMM(), bristol: bristol)
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
                         values: Array(bridge.stepsHistory.suffix(7)))
        )
      }
      .buttonStyle(.plain)
    }
  }

  // Settings is reached from the sidebar (and ⌘, on macOS) — it's an
  // app-level surface, not a Week tile, and not on this toolbar.

  /// Last 30 calendar days oldest→newest (today rightmost) of
  /// carry-forward weights from `bodyRows`. A day with no weigh-in
  /// inherits the most recent prior weight; days before the first ever
  /// weigh-in are nil. Bumped from 7 → 30 in Phase 4b.
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
    for offset in (0..<30).reversed() {
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

  /// Last 30 calendar days with actual weigh-ins only — no
  /// carry-forward. Days without a measurement are nil so the centered
  /// chart shows stubs rather than collapsing to zero deviation. Bumped
  /// from 7 → 30 in Phase 4b.
  private func weeklyWeightActual() -> [Double?] {
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    var byDate: [String: Double] = [:]
    for r in bodyRows { if let w = r.weightKg { byDate[r.date] = w } }
    let today = cal.startOfDay(for: Date())
    return (0..<30).reversed().map { offset -> Double? in
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
  //
  // When fasting tracking is on and the live state machine reports a
  // fasting window, the tile morphs: headline becomes the live timer,
  // progress tracks the target fasting band, and the history becomes
  // 7-day completed-fast hours instead of protein grams.
  private var nutritionTile: some View {
    // TimelineView lets the live timer minute-tick while the tile is
    // visible; the rest of the tile re-renders harmlessly each minute.
    TimelineView(.periodic(from: .now, by: 60)) { ctx in
      nutritionTileBody(now: ctx.date)
    }
  }

  @ViewBuilder
  private func nutritionTileBody(now: Date) -> some View {
    let accent = theme.color(for: "nutrition")
    let state = currentFastingState(now: now)
    if nutritionTrackFasting, case .fasting(_, let since, let totalMin) = state {
      ModuleTile(
        title: "Nutrition",
        accent: accent,
        stats: [
          .init(label: "Fasting", value: fastingDurationText(totalMin: totalMin)),
          .init(label: "Since", value: since)
        ],
        progress: fastingProgressRow(totalMin: totalMin),
        history: .init(label: "7-day fasts (h)", values: fastingHoursBars())
      )
      .contentShape(Rectangle())
      .onTapGesture { sheetDest = .nutrition }
      .contextMenu { nutritionQuickAddMenu }
    } else {
      let proteinTarget = nutritionTarget?.protein.min ?? 150
      let bars = Array((nutritionStats?.daily.map { Int($0.proteinG) }
                ?? Array(repeating: 0, count: 7)).suffix(7))
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
      .contentShape(Rectangle())
      .onTapGesture { sheetDest = .nutrition }
      .contextMenu { nutritionQuickAddMenu }
    }
  }

  /// Live fasting state derived from `nutritionStats`. Returns `.fed`
  /// when tracking is off or the stats payload isn't loaded yet, so
  /// callers can branch with a single switch.
  private func currentFastingState(now: Date) -> FastingState {
    guard let stats = nutritionStats else { return .fed }
    let inputs = FastingStateInputs(
      todayLatestMeal: stats.todayLatestMeal,
      todayMealCount: stats.todayMealCount ?? 0,
      yesterdayLastMeal: stats.yesterdayLastMeal
    )
    return computeFastingState(inputs: inputs, now: now)
  }

  private func fastingDurationText(totalMin: Int) -> String {
    "\(totalMin / 60)h \(totalMin % 60)m"
  }

  /// Progress bar fills toward the user's target fasting minimum (the
  /// short end of the band). Once past it, the bar shows full but the
  /// timer keeps counting in the headline.
  private func fastingProgressRow(totalMin: Int) -> ModuleTile.ProgressBar {
    let targetMin = nutritionTarget?.fasting?.min ?? FastingDefaults.targetMinH
    let hours = Double(totalMin) / 60
    return .init(
      label: "Fast vs target",
      current: min(hours, targetMin),
      target: max(targetMin, 1),
      unit: "h"
    )
  }

  /// Last-7 completed-fast hours, oldest→newest. Gaps (sparse-log
  /// days where the heuristic couldn't anchor a window) collapse to 0
  /// — the bar just renders short rather than disappearing.
  private func fastingHoursBars() -> [Int] {
    let windows = nutritionStats?.fasting ?? []
    let last7 = windows.suffix(7)
    let bars = last7.map { Int(($0.hours ?? 0).rounded()) }
    if bars.count < 7 {
      return Array(repeating: 0, count: 7 - bars.count) + bars
    }
    return bars
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

  /// Duplicate a meal at the current time via NutritionMutator.
  private func commitNutritionDuplicate(_ entry: NutritionEntry) {
    SeptenaServices.shared.nutritionMutator.addEntry(
      loggedAt: Date.now,
      emoji: entry.emoji,
      foods: entry.foods,
      proteinG: entry.proteinG,
      fatG: entry.fatG,
      carbsG: entry.carbsG,
      fiberG: entry.fiberG,
      kcal: entry.kcal
    )
    AddInfoSection.nutrition.notifyTilesChanged()
    Haptics.tick()
  }

  // MARK: - Mood

  // Mood — today's check-in count + last-7-day log bars. Bars are the
  // raw log count per day; color stays neutral on the bar itself (the
  // detail color story lives inside MoodDestinationView).
  private var moodTile: some View {
    let accent = theme.color(for: "mood")
    let today = moodToday?.logCount ?? 0
    let bars = Array(moodHistory.map { $0.logs }.suffix(7))
    return ModuleTile(
      title: "Mood",
      accent: accent,
      stats: [
        .init(label: "Today",  value: "\(today)"),
        .init(label: "Target", value: "3"),
      ],
      progress: .init(label: "Today / target",
                      current: Double(min(today, 3)),
                      target: 3),
      history: .init(label: "7-day check-ins",
                     values: bars.isEmpty
                       ? Array(repeating: 0, count: 7) : bars)
    )
    .contentShape(Rectangle())
    .onTapGesture { sheetDest = .mood }
    .contextMenu { moodQuickAddMenu }
    .sheet(isPresented: $presentingMoodCheckin) {
      AddMoodPage(onLogged: {
        Task { await refreshMood() }
      })
      #if os(iOS)
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      #endif
    }
  }

  @ViewBuilder private var moodQuickAddMenu: some View {
    MoodQuickAddMenu(onCheckIn: { presentingMoodCheckin = true })
  }

  private func moodDomainData() -> HomepageDomainData {
    let today = moodToday?.logCount ?? 0
    let bars = moodHistory.map { $0.logs }
    return HomepageDomainData(
      domain: .mood,
      title: "Mood",
      accent: theme.color(for: "mood"),
      headline: "\(today) of 3 today",
      headlineStats: [
        .init(label: "Today",  value: "\(today)"),
        .init(label: "Target", value: "3"),
      ],
      progress: .init(label: "Today / target",
                      current: Double(min(today, 3)),
                      target: 3),
      history: .bars(bars.isEmpty ? Array(repeating: 0, count: 90) : bars),
      tap: .openSheet(.mood)
    )
  }

  /// Reload mood state after an in-app commit (the AddMoodPage sheet on
  /// the dashboard tile). Mirrors the `refresh(section:)` pattern that
  /// other domains use via tilesDidChange notifications — Mood doesn't
  /// route through AddInfoSection so it refreshes itself.
  private func refreshMood() async {
    let d = ChecklistMirror.loadMoodDay(context: modelContext, date: SeptenaDate.today)
    moodToday = d
    ResponseCache.save(d, forKey: CacheKey.moodToday)
    let h = ChecklistMirror.loadMoodHistory(context: modelContext, days: 90).daily
    moodHistory = h
    ResponseCache.save(h, forKey: CacheKey.moodHistory)
  }
}

/// Empty-state shown when the user has selected a layout mode whose
/// renderer hasn't been built yet. Mirrors the system
/// `ContentUnavailableView` shape but stays plain `VStack` so the same
/// view renders cleanly inside the existing `LazyVGrid`'s parent stack
/// without an iOS-version gate.
private struct ComingSoonLayoutPlaceholder: View {
  let mode: HomepageLayoutMode
  let onUseTiles: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: mode.icon)
        .scaledFont(size: 44, weight: .regular, relativeTo: .largeTitle)
        .foregroundStyle(.secondary)
      Text("\(mode.title) layout — coming soon")
        .font(.septenaCardTitle)
      Text(mode.summary)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
      Button("Use Tiles", action: onUseTiles)
        .buttonStyle(.bordered)
        .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 48)
  }
}

private struct WeekDashboardScreen<CurrentDay: Equatable, Toolbar: ToolbarContent, Content: View>: View {
  let currentDay: CurrentDay
  let onInitialLoad: () async -> Void
  let onRefresh: () async -> Void
  let onTaskChange: () -> Void
  let onDayChange: () -> Void
  let onDataChange: () -> Void
  let onTileChange: (AddInfoSection) -> Void
  @ToolbarContentBuilder let toolbar: () -> Toolbar
  @ViewBuilder let content: () -> Content

  var body: some View {
    NavigationStack {
      ScrollView {
        content()
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
      .toolbar { toolbar() }
      // Two-phase load: paint cached blobs synchronously so tiles +
      // histograms appear immediately on cold launch, then kick off the
      // network refresh in the background. Pull-to-refresh skips the
      // cache step since it's a manual "I want fresh data now" gesture.
      .task {
        await onInitialLoad()
      }
      .refreshable {
        await onRefresh()
      }
      // CK fetch landed (push, foreground refresh, or pull-to-refresh on
      // any other surface) — repaint so today's task counts reflect
      // mutations from other devices.
      .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
        onTaskChange()
      }
      // CK fetch batch landed for any non-task domain (push, periodic
      // fetch, or a write on another device). Refresh every CK-backed
      // tile from its SwiftData mirror. Without this, the dashboard
      // stays stuck on whatever `loadAll` saw at cold launch — entries
      // logged on another device never repaint until the user pulls to
      // refresh or visits the section.
      .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
        onDataChange()
      }
      // Day rollover: the dashboard is the most date-sensitive surface
      // (today's timeline, today's totals, 7-day windows ending today).
      // Refetch everything when `clock.today` flips.
      .onChange(of: currentDay) { _, _ in
        onDayChange()
      }
      // Quick-add finished — repaint just that tile from cache (instant,
      // for sections that wrote optimistic state) and refetch its
      // endpoints in the background to reconcile with the server. Scoped
      // to the touched section so the rest of the dashboard stays put.
      .onReceive(NotificationCenter.default.publisher(for: .tilesDidChange)) { note in
        guard let key = note.userInfo?[TileChangeKey.section] as? String,
              let section = AddInfoSection(rawValue: key) else { return }
        onTileChange(section)
      }
    }
  }
}

private struct WeekDashboardTimelineCard: View {
  let date: String
  let oura: OuraNight?
  let caffeine: [CaffeineEntry]
  let cannabis: [CannabisEntry]
  let nutrition: [NutritionEntry]
  let gut: [GutEntry]
  let mood: [MoodEntry]
  let habits: [HabitDayItem]
  let supplements: [SupplementDayItem]
  let chores: [ChoreItem]
  let training: [ExerciseEntry]
  let tasks: [SeptenaTask]
  let calendar: [EKEvent]
  let macroColors: MacroColors?

  var body: some View {
    DayTimelineView(
      date: date,
      oura: oura,
      caffeine: caffeine,
      cannabis: cannabis,
      nutrition: nutrition,
      gut: gut,
      mood: mood,
      habits: habits,
      supplements: supplements,
      chores: chores,
      training: training,
      tasks: tasks,
      calendar: calendar,
      macroColors: macroColors
    )
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Theme.secondaryGroupedBackground)
    )
  }
}

private struct WeekTasksTile: View {
  let accent: Color
  let openToday: Int
  let inbox: Int
  let upcoming: Int
  let doneToday: Int
  let totalToday: Int
  let bars: [Int]

  var body: some View {
    ModuleTile(
      title: "Tasks",
      accent: accent,
      stats: [
        .init(label: "Today", value: "\(openToday)"),
        .init(label: "Inbox", value: "\(inbox)"),
        .init(label: "Upcoming", value: "\(upcoming)")
      ],
      progress: .init(
        label: "Done / today",
        current: Double(doneToday),
        target: Double(max(totalToday, 1))
      ),
      history: bars.isEmpty ? nil : .init(label: "7-day completions", values: bars)
    )
  }
}

private struct WeekHabitsTile: View {
  let accent: Color
  let done: Int
  let skipped: Int
  let total: Int
  let history: [Int]

  var body: some View {
    ModuleTile(
      title: "Habits",
      accent: accent,
      stats: [
        .init(label: "Today", value: "\(done)"),
        .init(label: "Skipped", value: "\(skipped)")
      ],
      progress: .init(
        label: "Today's progress",
        current: Double(done),
        target: Double(max(total, 1))
      ),
      history: .init(label: "7-day adherence", values: history)
    )
  }
}

private struct WeekTrainingTile: View {
  let accent: Color
  let sessionCount: Int
  let minutes: Int
  let target: Int
  let strengthBars: [Int]
  let cardioBars: [Int]

  var body: some View {
    ModuleTile(
      title: "Training",
      accent: accent,
      stats: [
        .init(label: "Sessions", value: "\(sessionCount)/7"),
        .init(label: "Z2 min", value: "\(minutes)", unit: "m")
      ],
      progress: .init(
        label: "Z2 cardio",
        current: Double(minutes),
        target: Double(max(target, 1)),
        unit: "m"
      ),
      history: .init(
        label: "7-day effort",
        values: strengthBars,
        secondaryValues: cardioBars
      )
    )
  }
}

private struct WeekChoresTile: View {
  let accent: Color
  let dueToday: Int
  let overdue: Int
  let done: Int
  let total: Int
  let history: [Int]

  var body: some View {
    ModuleTile(
      title: "Chores",
      accent: accent,
      stats: [
        .init(label: "Due today", value: "\(dueToday)"),
        .init(label: "Overdue", value: "\(overdue)")
      ],
      progress: .init(
        label: "Today done",
        current: Double(done),
        target: Double(max(total, 1))
      ),
      history: .init(label: "7-day done", values: history)
    )
  }
}

private struct WeekSupplementsTile: View {
  let accent: Color
  let done: Int
  let total: Int
  let history: [Int]

  var body: some View {
    ModuleTile(
      title: "Supplements",
      accent: accent,
      stats: [.init(label: "Today", value: "\(done)")],
      progress: .init(
        label: "Today's stack",
        current: Double(done),
        target: Double(max(total, 1))
      ),
      history: .init(label: "7-day adherence", values: history)
    )
  }
}

private struct WeekSleepTile: View {
  let accent: Color
  let lastHoursText: String
  let lastHours: Double
  let score: String
  let bars: [Int]

  var body: some View {
    ModuleTile(
      title: "Sleep",
      accent: accent,
      stats: [
        .init(label: "Last night", value: lastHoursText, unit: "h"),
        .init(label: "Score", value: score)
      ],
      progress: .init(label: "Target", current: lastHours, target: 8, unit: "h"),
      history: .init(
        label: "7-day score",
        values: bars.isEmpty ? Array(repeating: 0, count: 90) : bars,
        ceiling: 100
      )
    )
  }
}

private struct WeekGroceriesTile: View {
  let accent: Color
  let lowCount: Int
  let stocked: Int
  let totalItems: Int
  /// Trailing 30-day "items missing per day" series.
  let missingPerDay: [Int]

  var body: some View {
    ModuleTile(
      title: "Groceries",
      accent: accent,
      stats: [
        .init(label: "Low", value: "\(lowCount)"),
        .init(label: "Stocked", value: "\(stocked)")
      ],
      progress: totalItems == 0 ? nil : .init(
        label: "Stocked",
        current: Double(stocked),
        target: Double(max(totalItems, 1))
      ),
      history: .init(label: "Missing (30d)", values: missingPerDay)
    )
  }
}

/// Daily snapshot store for grocery stock level.
///
/// A grocery item's `low` flag is *state*, not an event — there is no
/// per-day activity to plot the way there is for caffeine sessions or
/// tasks completed. So the only honest day-based series is "how many
/// items were missing (low) on day D." We can't reconstruct that from
/// the current snapshot alone (we'd need every low↔stocked transition
/// date, which isn't stored), so instead we record today's count each
/// time the dashboard loads and let the series fill in going forward.
///
/// Gaps (days the app wasn't opened) carry forward the last known
/// count rather than collapsing to 0 — stock level persists whether or
/// not you looked at it, so a quiet day is "same as yesterday," not
/// "suddenly nothing missing."
enum GroceryStockHistory {
  private static let key = "groceries.missingHistory.v1"
  private static let retentionDays = 120

  private static let fmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  private static func load() -> [String: Int] {
    UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
  }

  private static func save(_ map: [String: Int]) {
    UserDefaults.standard.set(map, forKey: key)
  }

  /// Stamp today's missing count. Cheap and idempotent — only writes
  /// when the value actually changes, so calling it on every render is
  /// fine. Prunes entries older than `retentionDays`.
  static func record(missing: Int, on date: Date = Date()) {
    let today = fmt.string(from: Calendar.current.startOfDay(for: date))
    var map = load()
    if map[today] == missing { return }
    map[today] = missing

    if let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: date) {
      let cutoffKey = fmt.string(from: Calendar.current.startOfDay(for: cutoff))
      map = map.filter { $0.key >= cutoffKey }
    }
    save(map)
  }

  /// Trailing `days`-long series of missing counts, oldest-first, last
  /// element = today. Gaps carry forward the most recent prior count;
  /// days before the first-ever snapshot read as 0 (we genuinely have
  /// no data, and don't fabricate it).
  static func series(days: Int, asOf date: Date = Date()) -> [Int] {
    let map = load()
    let cal = Calendar.current
    let today = cal.startOfDay(for: date)
    var last = 0
    var started = false
    var out: [Int] = []
    out.reserveCapacity(days)
    for back in stride(from: days - 1, through: 0, by: -1) {
      guard let d = cal.date(byAdding: .day, value: -back, to: today) else { continue }
      if let v = map[fmt.string(from: d)] {
        last = v
        started = true
        out.append(v)
      } else {
        out.append(started ? last : 0)
      }
    }
    return out
  }
}
