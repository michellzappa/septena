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
  case hydration
  case groceries, body, gut
  case intake
  case mood
  case symptoms
  case medications
  case activity
  case github
  case insights
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
  // Optional: lets the tile quick-add fire the commit flourish over the
  // dashboard. nil-safe (skips the visual) for hosts without the root env.
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?
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
  @AppStorage(SettingsKey.homepageShowWelcome)
  private var showWelcome: Bool = true
  /// "Today at a glance" between the greeting and the layout grid: the
  /// circular Day dial hero, the linear timeline strip, or hidden
  /// (`DayViewStyle`, Settings ▸ Home).
  @AppStorage(SettingsKey.homepageDayView)
  private var dayViewRaw: String = DayViewStyle.dial.rawValue
  @AppStorage(SettingsKey.welcomeDataAware)
  private var welcomeDataAware: Bool = false
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
  /// Whether sections open as a pushed full pane vs. a modal bottom sheet.
  /// Single source of truth, resolved once at the app root — see
  /// `\.usesPushNavigation`.
  @Environment(\.usesPushNavigation) private var usesPushNavigation

  /// Live width of the timeline's container, measured below. Drives the
  /// wide-layout treatment (cap the rail, span the full day) without
  /// leaning on `horizontalSizeClass` — so a resizable macOS window and a
  /// narrow iPad split view both get the right call from actual pixels.
  @State private var timelineWidth: CGFloat = 0

  /// Past this offered width the timeline stops stretching edge-to-edge
  /// (capped at `timelineMaxWidth`, centered) and shows the whole 0–24h
  /// day rather than only the wake→bedtime window.
  private static let wideTimelineThreshold: CGFloat = 600
  private static let timelineMaxWidth: CGFloat = 760

  /// History window for every tile's mirror read. Tiles that only show the
  /// trailing week slice this down themselves (`.suffix(7)`); the heatmap
  /// layout wants the full span.
  private static let historyDays = 90

  /// Cached `yyyy-MM-dd` formatter. `body`-reachable helpers (`sinceDate`
  /// via `weeklySessionCount`, the weight series) used to allocate a fresh
  /// `DateFormatter` on every render — expensive; this shares one.
  private static let ymdFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()
  /// Sections the background `reader` handles — everything except tasks,
  /// whose persistence layer is `@MainActor` (tasks read via `refreshTasks`
  /// on the main actor). `loadAll` reads these plus tasks; `.septenaDataChanged`
  /// reloads just these (tasks have their own `.septenaTasksChanged` path).
  private static let mirrorSections = Set(DashSection.allCases).subtracting([.tasks])
  private static let dataChangeSections = mirrorSections

  /// Off-main SwiftData reader. Owns a background `ModelContext`, so the
  /// dashboard's mirror reads no longer block the main thread. Held in
  /// `@State` so it survives view re-creation (it isn't observed).
  @State private var reader = DashboardReader(modelContainer: LocalStore.shared.container)

  /// Precomputed display data for the data-heavy tiles (Training/Body/GitHub),
  /// refreshed by `recomputeDerived()` when their inputs change — keeps the
  /// reshaping out of the render path. See the `Derived` struct.
  @State private var derived = Derived()

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
  /// Intake (consumables) — one tile per kind. Local SwiftData, so loaded via
  /// MirrorReader on `.septenaDataChanged`, OUTSIDE the ≤4-parallel HTTP loadAll.
  @State private var intakeTiles: [IntakeTileDTO] = []
  /// Tracker page presented from a tile tap (push on regular, sheet on compact).
  @State private var intakeKindDest: IntakeKindRef? = nil
  @State private var bodyRows: [WithingsRow] = []
  /// GitHub contribution calendar (read-only, per-device token). Drives the
  /// GitHub tile's commit counts; the destination view fetches its own copy.
  @State private var githubContributions: GitHubContributions = .empty
  @State private var gutToday: GutDayResponse? = nil
  @State private var gutHistory: [GutHistoryPoint] = []
  @State private var moodToday: MoodDayResponse? = nil
  @State private var moodHistory: [MoodHistoryPoint] = []
  /// True while the dashboard QuickAdd is presenting AddMoodPage as a
  /// standalone sheet (separate from `sheetDest` because Mood needs both
  /// the destination route and the standalone check-in flow).
  @State private var presentingMoodCheckin = false
  /// Drives the Tasks-tile "Create in Inbox…" composer, popped in place.
  @State private var creatingTask = false
  /// Hydration tile state. Today's total ml + a 90-day daily series
  /// (oldest→newest). Derived from Nutrition's water entries — Hydration
  /// owns no entity (see HydrationPlugin / ChecklistMirror.loadHydrationDailyMl).
  @State private var hydrationToday: Int = 0
  @State private var hydrationHistory: [Int] = []
  /// Daily target shared with HydrationDestinationView via the same
  /// AppStorage key, so the tile's progress matches the section's.
  @AppStorage("hydration.dailyTargetMl") private var hydrationTargetMl: Int = 2000
  @State private var sheetDest: WeekDestination? = nil
  /// Today-scoped collections kept in state so DayTimelineView can read
  /// them. NextItemsModel already covers habits/supplements/chores and
  /// today's intake/gut live in their respective `*Today`
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
    if let v = ResponseCache.load([WithingsRow].self, forKey: CacheKey.bodyRows) { _bodyRows = State(initialValue: v) }
    if let v = ResponseCache.load(GitHubContributions.self, forKey: CacheKey.github) { _githubContributions = State(initialValue: v) }
    if let v = ResponseCache.load(GutDayResponse.self, forKey: CacheKey.gutToday) { _gutToday = State(initialValue: v) }
    if let v = ResponseCache.load([GutHistoryPoint].self, forKey: CacheKey.gutHistory) { _gutHistory = State(initialValue: v) }
    if let v = ResponseCache.load(MoodDayResponse.self, forKey: CacheKey.moodToday) { _moodToday = State(initialValue: v) }
    if let v = ResponseCache.load([MoodHistoryPoint].self, forKey: CacheKey.moodHistory) { _moodHistory = State(initialValue: v) }
    if let v = ResponseCache.load([Int].self, forKey: CacheKey.hydrationHistory) {
      _hydrationHistory = State(initialValue: v)
      _hydrationToday = State(initialValue: v.last ?? 0)
    }
    if let v = ResponseCache.load([ExerciseEntry].self, forKey: CacheKey.recentTraining) { _recentTraining = State(initialValue: v) }
    if let v = ResponseCache.load(MacroColors.self, forKey: CacheKey.macroColors) { _macroColors = State(initialValue: v) }
    // Prime the derived tile cache from disk so the heavy tiles render with
    // real data on the very first frame (session types arrive later and
    // trigger a recompute). Mirrors the cache loads above.
    _derived = State(initialValue: Self.computeDerived(
      recentTraining: ResponseCache.load([ExerciseEntry].self, forKey: CacheKey.recentTraining) ?? [],
      sessionTypes: [],
      github: ResponseCache.load(GitHubContributions.self, forKey: CacheKey.github) ?? .empty,
      bodyRows: ResponseCache.load([WithingsRow].self, forKey: CacheKey.bodyRows) ?? []))
  }

  /// iPhone compact: a single fixed column. iPad regular & macOS: adaptive —
  /// packs as many ~280pt tiles as fit, so a narrow Stage Manager / split
  /// window stays at 2 columns while a full-screen 13" iPad or a wide Mac
  /// window gets 4–5. LazyVGrid reflows on resize. (Previously iPad was
  /// hard-pinned to 3 columns regardless of width, which cramped narrow
  /// regular-width windows and under-filled wide ones.)
  private var columns: [GridItem] {
    #if os(iOS)
    if hSize == .regular {
      return [GridItem(.adaptive(minimum: 280), spacing: Theme.tileGap)]
    }
    return [GridItem(.flexible(), spacing: Theme.tileGap)]
    #else
    return [GridItem(.adaptive(minimum: 280), spacing: Theme.tileGap)]
    #endif
  }

  var body: some View {
    WeekDashboardScreen(
      currentDay: clock.today,
      onInitialLoad: {
        paintFromCache()
        await loadAll()
      },
      onTaskChange: {
        // A task mutation only touches the Tasks tile — reload just that,
        // not all ~20 sections. This is the per-toggle hitch fix.
        Task { await refresh([.tasks]) }
      },
      onDayChange: {
        Task { await loadAll() }
      },
      onDataChange: { note in
        if let keys = note.changedSections {
          // Scoped local mutation — reload only the touched tiles. A change
          // with no dashboard tile (goals, coach, milestones) is a no-op
          // here; intake has its own `.septenaDataChanged` listener below.
          let sections = Set(keys.compactMap(DashSection.init(sectionKey:)))
          guard !sections.isEmpty else { return }
          Task { await refresh(sections) }
        } else {
          // Unscoped — CK batch arrival or settings-level change. Re-read
          // every mirror-backed tile, same as before scoping existed.
          Task { await repaintAllMirrors() }
        }
      },
      onTileChange: { section in
        repaint(section: section)
        Task { await refresh(section: section) }
      },
      toolbar: { homeToolbar }
    ) {
      ZStack {
        VStack(spacing: Theme.sectionSpacing) {
          #if DEBUG
          debugTimeTravelBar
          #endif
          ClaudeReconnectBanner()
          if showWelcome {
            // Self-observes DayClock so the 60s `now` tick re-renders only the
            // header, not the whole tile grid. (Reading `clock.now` here in the
            // parent body would invalidate every tile each minute.)
            WelcomeHeaderSection(dataAware: welcomeDataAware,
                                 todayTaskCount: taskCounts?.todayCount ?? 0,
                                 dailies: dailies)
          }
          // The day view — today at a glance, circular or linear. The dial
          // is skipped in Wheel mode (whose body is already this dial) so
          // the dashboard never shows two.
          switch DayViewStyle(rawValue: dayViewRaw) ?? .dial {
          case .dial:
            if currentLayoutMode != .wheel {
              DayDialHero(visibleSections: Set(visibleDomains.map(\.rawValue)),
                          sleepNights: ouraNights)
            }
          case .linear:
            todayTimeline
          case .hidden:
            EmptyView()
          }
          layoutBody
        }
        .septenaSurface()
        #if DEBUG
        // Hidden keyboard shortcuts: ⟨ / ⟩ (the comma/period keys) step the
        // homepage back/forward a day through the last week, driving
        // DayClock so the dial + tiles re-render for that day. Zero-size so
        // they never show; they work whenever the window is key.
        .background {
          Group {
            Button("") { stepDebugDay(-1) }.keyboardShortcut(",", modifiers: [])
            Button("") { stepDebugDay(+1) }.keyboardShortcut(".", modifiers: [])
            // Shift variants (the literal ⟨ ⟩ glyphs) too, for muscle memory.
            Button("") { stepDebugDay(-1) }.keyboardShortcut("<", modifiers: [])
            Button("") { stepDebugDay(+1) }.keyboardShortcut(">", modifiers: [])
          }
          .opacity(0)
          .accessibilityHidden(true)
        }
        #endif
        // While a compact drawer floats over the dashboard the content behind
        // it goes inert. The drawer's backdrop is translucent, not dimmed, and
        // `presentationBackgroundInteraction` keeps it live — so without this a
        // background tap falls *through* and fires the tile/button underneath
        // instead of dismissing. Inert content leaves the transparent layer
        // below as the only hit target on the backdrop.
        .allowsHitTesting(!compactDrawerOpen)

        // A tap anywhere on the backdrop dismisses the drawer — standard
        // popover-style tap-away. Compact only; on push navigation there's no
        // floating drawer to dismiss.
        if compactDrawerOpen {
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture { dismissCompactDrawer() }
        }
      }
      // Regular width (iPad / macOS): a section opens as a pushed full
      // pane *inside* the dashboard's NavigationStack — a real screen with
      // a back button, not a floating modal drawer. `pushDest` is nil on
      // compact, so only the bottom-sheet path below fires there.
      .navigationDestination(item: pushDest) { dest in
        pushedContent(for: dest)
      }
      .navigationDestination(item: intakeKindPushBinding) { ref in
        IntakeKindPageView(kindID: ref.value)
      }
      .task { await reloadIntake() }
      .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
        guard note.affectsSection("intake") else { return }
        Task { await reloadIntake() }
      }
    }
    // Compact (iPhone): navigation into a module is a bottom-sheet slide-
    // over so the dashboard stays visually present underneath.
    .sheet(item: sheetDestBinding) { dest in
      sheetContent(for: dest)
    }
    .sheet(item: intakeKindSheetBinding) { ref in
      NavigationStack { IntakeKindPageView(kindID: ref.value) }
        .sectionDrawerPresentation()
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
    ToolbarItem(placement: .topBarTrailing) { insightsToolbarButton }
    #else
    ToolbarItem(placement: .primaryAction) { homeMenu }
    ToolbarItem(placement: .primaryAction) { SyncIndicator() }
    ToolbarItem(placement: .primaryAction) { insightsToolbarButton }
    #endif
  }

  /// Insights entry point — toolbar button (not a body tile/card: Insights
  /// has no per-day series, so it belongs in the dashboard's chrome, not its
  /// section content). Opens the full explorer. Insights is no longer a
  /// catalog section, so this is always present — the Septena+ gate lives
  /// inside the destination.
  private var insightsToolbarButton: some View {
    Button {
      logInsightsOpen("toolbar tapped")
      open(.insights)
    } label: {
      Image(systemName: "chart.dots.scatter")
    }
    .accessibilityLabel("Insights")
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
      // gray toolbar circle — no double ring.
      Image(systemName: "ellipsis")
    }
    .accessibilityLabel("More")
  }

  /// Drives the `.navigationDestination` push. Mirrors `sheetDest` only
  /// when pushing, and stays nil otherwise so the sheet path owns
  /// presentation on compact. Tile taps set `sheetDest` via `open(_:)`, which
  /// feeds whichever of these two bindings is currently active.
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

  /// A compact bottom-sheet drawer — a section (`sheetDest`) or a tracker page
  /// (`intakeKindDest`) — is floating over the dashboard. Gates the backdrop's
  /// hit-testing so a tap-away dismisses instead of firing a tile underneath.
  private var compactDrawerOpen: Bool {
    !usesPushNavigation && (sheetDest != nil || intakeKindDest != nil)
  }

  /// Closes whichever compact drawer is open (tap-away on the backdrop).
  private func dismissCompactDrawer() {
    sheetDest = nil
    intakeKindDest = nil
  }

  // MARK: - Intake kind deep-open
  //
  // A tracker tile opens ITS page directly (no switcher hop) — same
  // push-on-regular / sheet-on-compact split as `sheetDest`, but carrying a
  // kind id (WeekDestination is a string enum and can't).

  struct IntakeKindRef: Identifiable, Hashable {
    let value: String
    var id: String { value }
  }

  private var intakeKindPushBinding: Binding<IntakeKindRef?> {
    Binding(
      get: { usesPushNavigation ? intakeKindDest : nil },
      set: { if usesPushNavigation { intakeKindDest = $0 } }
    )
  }

  private var intakeKindSheetBinding: Binding<IntakeKindRef?> {
    Binding(
      get: { usesPushNavigation ? nil : intakeKindDest },
      set: { if !usesPushNavigation { intakeKindDest = $0 } }
    )
  }

  /// Mirror of `open(_:)` for tracker pages — same drawer tap-away rule.
  private func openIntakeKind(_ id: String) {
    guard usesPushNavigation || (sheetDest == nil && intakeKindDest == nil) else {
      sheetDest = nil
      intakeKindDest = nil
      return
    }
    intakeKindDest = IntakeKindRef(value: id)
  }

  /// Pushed-pane content: the plugin destination rendered *bare*, with no
  /// extra `NavigationStack` or fixed frame — the dashboard's own stack
  /// hosts it, supplying the back button, and the section's `SectionDrawer`
  /// supplies its title + "+" toolbar. This is what turns "floating drawer"
  /// into "real screen" on iPad / macOS.
  @ViewBuilder
  private func pushedContent(for dest: WeekDestination) -> some View {
    switch dest {
    case .insights:
      InsightsDestinationView()
    default:
      if let view = SectionRegistry.plugin(forKey: dest.rawValue)?.destinationView() {
        view
      } else {
        EmptyView()
      }
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
      switch dest {
      case .insights:
        InsightsDestinationView()
      default:
        if let view = SectionRegistry.plugin(forKey: dest.rawValue)?.destinationView() {
          view
        } else {
          EmptyView()
        }
      }
    }
    // All sheet/presentation chrome (detents, translucent background, glass
    // surface style) lives in one owner so the drawer look can't drift between
    // here and SectionDrawer.
    .sectionDrawerPresentation()
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
    static let bodyRows           = "week.bodyRows"
    static let github             = "week.github"
    static let gutToday           = "week.gutToday"
    static let gutHistory         = "week.gutHistory"
    static let moodToday          = "week.moodToday"
    static let moodHistory        = "week.moodHistory"
    static let hydrationHistory   = "week.hydrationHistory"
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
    if let v = ResponseCache.load([WithingsRow].self, forKey: CacheKey.bodyRows) { bodyRows = v }
    if let v = ResponseCache.load(GitHubContributions.self, forKey: CacheKey.github) { githubContributions = v }
    if let v = ResponseCache.load(GutDayResponse.self, forKey: CacheKey.gutToday) { gutToday = v }
    if let v = ResponseCache.load([GutHistoryPoint].self, forKey: CacheKey.gutHistory) { gutHistory = v }
    if let v = ResponseCache.load(MoodDayResponse.self, forKey: CacheKey.moodToday) { moodToday = v }
    if let v = ResponseCache.load([MoodHistoryPoint].self, forKey: CacheKey.moodHistory) { moodHistory = v }
    if let v = ResponseCache.load([Int].self, forKey: CacheKey.hydrationHistory) {
      hydrationHistory = v
      hydrationToday = v.last ?? 0
    }
    if let v = ResponseCache.load([ExerciseEntry].self, forKey: CacheKey.recentTraining) { recentTraining = v }
    if let v = ResponseCache.load(MacroColors.self, forKey: CacheKey.macroColors) { macroColors = v }
    // Heavy tiles read from `derived`, so prime it from the cache-loaded
    // inputs before first paint (session types arrive later via menu extras).
    recomputeDerived()
  }

  /// Full reload: read every section off-main via `DashboardReader` in one
  /// pass, apply on the main actor, then layer in the network-backed tiles.
  /// Each applied value is mirrored to `ResponseCache` so the next cold
  /// launch repaints from disk before the reload lands.
  private func loadAll() async {
    let snap = await reader.read(Self.mirrorSections,
                                 today: SeptenaDate.today,
                                 days: Self.historyDays)
    apply(snap, Self.mirrorSections)
    await refreshTasks()
    await dailies.load()
    loadMenuExtras()
    await loadNetwork()
  }

  /// Assign a reader `Snapshot` to the tile `@State` and mirror each value
  /// to `ResponseCache`, scoped to the sections that were read. The single
  /// place mirror data lands in the view — `loadAll` and every scoped
  /// refresh share it.
  @MainActor
  private func apply(_ s: DashboardReader.Snapshot, _ sections: Set<DashSection>) {
    if sections.contains(.habits) {
      habitHistory = s.habitHistory
      ResponseCache.save(s.habitHistory, forKey: CacheKey.habitHistory)
    }
    if sections.contains(.chores) {
      choreHistory = s.choreHistory
      ResponseCache.save(s.choreHistory, forKey: CacheKey.choreHistory)
    }
    if sections.contains(.supplements) {
      supplementHistory = s.supplementHistory
      ResponseCache.save(s.supplementHistory, forKey: CacheKey.supplementHistory)
    }
    if sections.contains(.training) {
      cardio = s.cardio
      trainingSessionDates = Set(s.trainingEntries.map(\.date))
      recentTraining = s.trainingEntries
      if let c = s.cardio { ResponseCache.save(c, forKey: CacheKey.cardio) }
      ResponseCache.save(trainingSessionDates, forKey: CacheKey.trainingDates)
      ResponseCache.save(s.trainingEntries, forKey: CacheKey.recentTraining)
    }
    if sections.contains(.nutrition) {
      if let ns = s.nutritionStats {
        nutritionStats = ns
        ResponseCache.save(ns, forKey: CacheKey.nutritionStats)
      }
      todayNutrition = s.todayNutrition
      todayProteinSum = s.todayNutrition.reduce(0) { $0 + $1.proteinG }
      todayKcalSum    = s.todayNutrition.reduce(0) { $0 + $1.kcal }
      ResponseCache.save(s.todayNutrition, forKey: CacheKey.todayNutrition)
      if let nt = s.nutritionTarget {
        nutritionTarget = nt
        ResponseCache.save(nt, forKey: CacheKey.nutritionTarget)
      }
      if let mc = s.macroColors {
        macroColors = mc
        ResponseCache.save(mc, forKey: CacheKey.macroColors)
      }
    }
    if sections.contains(.groceries) {
      groceries = s.groceries
      ResponseCache.save(s.groceries, forKey: CacheKey.groceries)
    }
    if sections.contains(.gut) {
      if let d = s.gutToday {
        gutToday = d
        ResponseCache.save(d, forKey: CacheKey.gutToday)
      }
      gutHistory = s.gutHistory
      ResponseCache.save(s.gutHistory, forKey: CacheKey.gutHistory)
    }
    if sections.contains(.mood) {
      if let d = s.moodToday {
        moodToday = d
        ResponseCache.save(d, forKey: CacheKey.moodToday)
      }
      moodHistory = s.moodHistory
      ResponseCache.save(s.moodHistory, forKey: CacheKey.moodHistory)
    }
    if sections.contains(.hydration) {
      hydrationHistory = s.hydrationHistory
      hydrationToday = s.hydrationHistory.last ?? 0
      ResponseCache.save(s.hydrationHistory, forKey: CacheKey.hydrationHistory)
    }
    // Training inputs (recentTraining) may have changed — refresh the cache.
    if sections.contains(.training) { recomputeDerived() }
  }

  /// Reload a scoped set of sections and apply. Mirror-backed sections read
  /// off-main via `reader`; tasks read on the main actor (their persistence
  /// layer is `@MainActor`). Every change-driven refresh path funnels here.
  private func refresh(_ sections: Set<DashSection>) async {
    guard !sections.isEmpty else { return }
    let mirror = sections.intersection(Self.mirrorSections)
    if !mirror.isEmpty {
      let snap = await reader.read(mirror,
                                   today: SeptenaDate.today,
                                   days: Self.historyDays)
      apply(snap, mirror)
    }
    if sections.contains(.tasks) {
      await refreshTasks()
    }
    // The "today" items model mirrors habits/supplements/chores — keep it
    // in step when any of those reloaded.
    if !sections.isDisjoint(with: [.habits, .chores, .supplements]) {
      await dailies.load()
    }
  }

  /// Reload the Tasks tile on the main actor. `TaskReads` → `LocalCache` is
  /// `@MainActor`, so unlike the mirror sections this can't go through the
  /// background reader. Scoped to tasks, it's cheap — a single tile, not the
  /// whole dashboard.
  @MainActor
  private func refreshTasks() async {
    let ctx = LocalStore.shared.container.mainContext
    async let countsTask = TaskReads.counts(context: ctx)
    let history = TaskReads.tasksHistory(days: Self.historyDays, context: ctx)
    async let listTask = TaskReads.list(view: "logbook", days: 1, context: ctx)
    let counts = await countsTask
    taskCounts = counts
    ResponseCache.save(counts, forKey: CacheKey.taskCounts)
    tasksHistory = history
    ResponseCache.save(history, forKey: CacheKey.tasksHistory)
    let items = await listTask.items
    completedTasks = items
    ResponseCache.save(items, forKey: CacheKey.completedTasks)
  }

  /// Network-backed tiles (Oura, Withings, GitHub, HealthKit). Kept off the
  /// mirror path and capped at ≤2 concurrent HTTP calls — past ~4 the shared
  /// URLSession path has heap-corrupted at launch, so GitHub stays sequential.
  private func loadNetwork() async {
    async let ouraTask = OuraProvider.shared.fetchHistory(days: Self.historyDays)
    async let withingsTask = WithingsProvider.shared.fetchHistory(days: Self.historyDays)
    if let o = try? await ouraTask {
      ouraNights = o
      ResponseCache.save(o, forKey: CacheKey.ouraNights)
    }
    if let w = try? await withingsTask {
      let sorted = w.sorted { $0.date > $1.date }
      bodyRows = sorted
      ResponseCache.save(sorted, forKey: CacheKey.bodyRows)
    }
    if GitHubProvider.shared.hasToken,
       let gh = try? await GitHubProvider.shared.fetchContributions(days: 365) {
      githubContributions = gh
      ResponseCache.save(gh, forKey: CacheKey.github)
    }
    await HealthKitBridge.shared.refresh()
    // Body (Withings) + GitHub inputs just landed — refresh the tile cache.
    recomputeDerived()
  }

  /// QuickAdd-menu-only data, loaded on its own hop so it never blocks the
  /// tiles' first paint (the menus need it only when opened).
  private func loadMenuExtras() {
    Task {
      let m = await reader.menuExtras(today: SeptenaDate.today)
      nutritionHistory = m.nutritionHistory
      trainingSessionTypes = m.trainingSessionTypes
      trainingSuggestedId = m.trainingSuggestedId
      trainingDaysAgo = m.trainingDaysAgo
      // Training effort classification depends on the session-type catalog
      // that just loaded — recompute so the Training tile reflects it.
      recomputeDerived()
    }
  }

  // MARK: - Per-section refresh (quick-add fast path)
  //
  // Triggered by `Notification.Name.tilesDidChange` posted from any
  // Add*Page after a successful commit. We do two things, scoped to the
  // touched section so the rest of the dashboard stays put:
  //
  //   1. `repaint(section:)`  — synchronous read from ResponseCache.
  //      Picks up any optimistic blob the Add page wrote (e.g. an intake
  //      bumps `sessionCount` locally before the outbox drains).
  //   2. `refresh(section:)`  — async refetch of just that section's
  //      endpoints. Reconciles with the server once the outbox drains.
  //
  // Animation lives on the tile components (`.animation(.snappy, value:)`
  // inside `ModuleTile`), so any @State assignment here tweens for free.

  private func repaint(section: AddInfoSection) {
    switch section {
    case .gut:
      if let v = ResponseCache.load(GutDayResponse.self, forKey: CacheKey.gutToday) {
        gutToday = v
      }
      if let v = ResponseCache.load([GutHistoryPoint].self, forKey: CacheKey.gutHistory) {
        gutHistory = v
      }
    case .nutrition:
      // Cache-only optimistic repaint (no main-thread SwiftData) — the
      // async `refresh` that follows reloads from the mirror off-main.
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
    await refresh([DashSection(section)])
  }

  /// Re-read every CK-backed tile from its SwiftData mirror. Triggered
  /// by `.septenaDataChanged` so CK fetch arrivals (push, periodic, or
  /// cross-device writes) repaint the dashboard. Tasks have their own
  /// `.septenaTasksChanged` path and are skipped here.
  private func repaintAllMirrors() async {
    // CK fetch landed for non-task domains — reload every mirror-backed
    // section in one off-main pass. Tasks have their own change path
    // (`.septenaTasksChanged`); mood + hydration ride along here now.
    await refresh(Self.dataChangeSections)
  }

  private func sinceDate(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
    return Self.ymdFormatter.string(from: d)
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
    let isWide = timelineWidth >= Self.wideTimelineThreshold
    // Respect enabled sections, same as the rhythm wheel — a disabled section
    // contributes nothing to the rail. Calendar isn't a toggleable section, so
    // it stays (gated only by calendar access).
    let enabled = Set(visibleDomains.map(\.rawValue))
    let extraEvents = todayTimelineExtraEvents(enabled: enabled)
    func on(_ key: String) -> Bool { enabled.contains(key) }
    return WeekDashboardTimelineCard(
      date: clock.today,
      oura: on("sleep") ? ouraNights.first : nil,
      nutrition: on("nutrition") ? todayNutrition : [],
      gut: on("gut") ? (gutToday?.entries ?? []) : [],
      mood: on("mood") ? (moodToday?.entries ?? []) : [],
      habits: on("habits") ? dailies.habits : [],
      supplements: on("supplements") ? dailies.supplements : [],
      chores: on("chores") ? dailies.chores : [],
      training: on("training") ? recentTraining : [],
      tasks: on("tasks") ? completedTasks : [],
      extras: extraEvents,
      calendar: dailies.calendarEvents,
      macroColors: macroColors,
      fullDay: isWide
    )
    // Cap the width on wide layouts so the rail doesn't stretch into an
    // unreadable hairline-per-hour; centered in the VStack. Compact stays
    // edge-to-edge. `timelineMaxWidth` > `wideTimelineThreshold`, so the
    // measured-width feedback below settles instead of oscillating.
    .frame(maxWidth: isWide ? Self.timelineMaxWidth : .infinity)
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear { timelineWidth = geo.size.width }
          .onChange(of: geo.size.width) { _, w in timelineWidth = w }
      }
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

  #if DEBUG
  // MARK: - Debug time travel

  /// A compact strip (debug builds only) showing which day the homepage is
  /// rendering and stepping it through the last week — for inspecting
  /// SolarClock + past-day data. Tappable ⟨ ⟩ mirror the comma/period
  /// keyboard shortcuts; everything drives `DayClock.debugDayOffset`, so the
  /// dial and tiles all follow.
  @ViewBuilder private var debugTimeTravelBar: some View {
    let off = clock.debugDayOffset
    HStack(spacing: 10) {
      Button { stepDebugDay(-1) } label: { Image(systemName: "chevron.left") }
        .disabled(off <= -6)
      Text(debugDayLabel)
        .font(.septenaMeta)
        .foregroundStyle(off == 0 ? Theme.inkSecondary : Theme.todayAccent)
        .frame(minWidth: 150)
      Button { stepDebugDay(+1) } label: { Image(systemName: "chevron.right") }
        .disabled(off >= 0)
      if off != 0 {
        Button { stepDebugDay(-off) } label: { Text("Today").font(.septenaMeta) }
      }
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .background(Capsule().fill(Theme.secondaryGroupedBackground))
    .overlay(Capsule().strokeBorder(Theme.inkSecondary.opacity(0.15)))
    .frame(maxWidth: .infinity)
  }

  private var debugDayLabel: String {
    let date = SeptenaDate.parse(clock.today) ?? Date()
    let f = DateFormatter()
    f.dateFormat = "EEE d MMM"
    let off = clock.debugDayOffset
    let tail = off == 0 ? " · today  ⟨ ⟩" : "  (\(off)d)"
    return f.string(from: date) + tail
  }

  /// Step the homepage's day, clamped to the last 7 days (today … −6).
  private func stepDebugDay(_ delta: Int) {
    let next = max(-6, min(0, clock.debugDayOffset + delta))
    if next != clock.debugDayOffset { clock.debugDayOffset = next }
  }
  #endif

  /// Renders the homepage body for the currently-selected layout mode.
  /// Three renderers, all reading from `HomepageDomainData`. (Correlations
  /// is no longer a layout mode — it's the Insights destination.)
  @ViewBuilder
  private var layoutBody: some View {
    switch currentLayoutMode {
    case .tiles:
      LazyVGrid(columns: columns, spacing: Theme.tileGap) {
        tiles
      }
    case .dense:
      DenseHomepageView(
        items: visibleDomainData,
        onTap: handleDomainTap,
        menuContent: { item in quickAddMenu(for: item) }
      )
    case .heatmap:
      HeatmapHomepageView(
        items: visibleDomainData,
        onTap: handleDomainTap,
        menuContent: { item in quickAddMenu(for: item) }
      )
    case .rings:
      RingsHomepageView(
        items: visibleDomainData,
        onTap: handleDomainTap,
        menuContent: { item in quickAddMenu(for: item) }
      )
    case .wheel:
      RhythmHomepageView(
        items: visibleDomainData,
        sleepNights: ouraNights,
        onTap: handleDomainTap,
        menuContent: { item in quickAddMenu(for: item) }
      )
    }
  }

  /// Domain data array in canonical order, filtered by server visibility
  /// + dropping any domain whose builder returned `nil` (currently only
  /// Activity-on-Mac when HealthKit is unavailable). Future renderers
  /// (Heatmap, List) consume this same property.
  private var visibleDomainData: [HomepageDomainData] {
    visibleDomains.flatMap { domain -> [HomepageDomainData] in
      // Intake expands to one entry per kind here too, so Dense / Heatmap /
      // Rings / Wheel show per-tracker rows, not a single aggregate.
      if domain == .intake, !intakeTiles.isEmpty {
        return intakeTiles.map(intakeKindDomainData)
      }
      return domainData(for: domain).map { [$0] } ?? []
    }
  }

  private func intakeKindDomainData(_ t: IntakeTileDTO) -> HomepageDomainData {
    let accent = AdaptiveColor.adaptive(t.color) ?? theme.color(for: "intake")
    var stats: [DomainStat] = [.init(label: "Today", value: "\(t.todayCount)")]
    if IntakeObjective.emphasizesStreak(t.objective),
       let days = intakeDaysSince(t.lastEventAt), days >= 1 {
      stats.append(.init(label: IntakeObjective.streakLabel(t.objective), value: "\(days)d"))
    }
    return HomepageDomainData(
      domain: .intake,
      itemID: "intake:\(t.id)",
      iconSymbol: t.symbol,
      title: t.name,
      accent: accent,
      headline: "\(t.todayCount) today",
      headlineStats: stats,
      progress: nil,
      history: .bars(t.dailyCounts),
      tap: .openIntakeKind(t.id)
    )
  }

  /// Single tap router for `HomepageDomainData.tap` actions. Phase 3
  /// renderers don't know about `sheetDest` or `tabSelection` — they
  /// call back here, mirroring the per-tile gestures the Tiles mode
  /// wires up inline.
  private func handleDomainTap(_ tap: DomainTapAction) {
    switch tap {
    case .openSheet(let dest):     open(dest)
    case .switchToTasksTab:        openTasksFromTile()
    case .openIntakeKind(let id):  openIntakeKind(id)
    }
  }

  /// Single entry point for "open a section from a homepage tile." On
  /// push-nav widths (iPad / macOS) the dashboard is covered by the pushed
  /// pane, so a direct set is fine. On compact the section is a bottom-sheet
  /// The drawer presents with background interaction enabled, so a tile
  /// *under* an open drawer stays tappable. We follow the standard
  /// popover/menu convention: while a drawer is open, a tap on the background
  /// or another tile just *dismisses* the current one — the tap is consumed,
  /// not forwarded to open a new section. (On iPad/macOS push navigation
  /// there's no overlay to dismiss, so swap to the tapped section directly.)
  private func open(_ dest: WeekDestination) {
    if dest == .insights {
      logInsightsOpen("open requested usesPushNavigation=\(usesPushNavigation) sheetDest=\(sheetDest?.rawValue ?? "nil")")
    }
    guard usesPushNavigation || sheetDest == nil else {
      if dest == .insights {
        logInsightsOpen("compact drawer already open; dismissed existing drawer")
      }
      sheetDest = nil
      return
    }
    sheetDest = dest
    if dest == .insights {
      logInsightsOpen("presentation state set")
    }
  }

  private func logInsightsOpen(_ message: String) {
    let line = "[Insights] \(message)"
    SeptenaLog.info(line)
    #if DEBUG
    print(line)
    #endif
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
    case .drawer: open(.tasks)
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
  /// Per-item variant for the Dense/Heatmap/Rings/Wheel rows: intake rows
  /// (one per tracker) get THEIR tracker's container-aware menu; every other
  /// row falls through to the per-domain menu.
  @ViewBuilder
  private func quickAddMenu(for item: HomepageDomainData) -> some View {
    if item.domain == .intake,
       let kindID = item.itemID?.split(separator: ":").last.map(String.init),
       let tile = intakeTiles.first(where: { $0.id == kindID }) {
      intakeQuickAddMenu(for: tile)
    } else {
      quickAddMenu(for: item.domain)
    }
  }

  @ViewBuilder
  private func quickAddMenu(for domain: HomepageDomain) -> some View {
    switch domain {
    case .tasks:       tasksQuickAddMenu
    case .habits:      habitsQuickAddMenu
    case .training:    trainingQuickAddMenu
    case .chores:      choresQuickAddMenu
    case .supplements: supplementsQuickAddMenu
    case .nutrition:   nutritionQuickAddMenu
    case .hydration:   hydrationQuickAddMenu
    case .groceries:   groceriesQuickAddMenu
    case .gut:         gutQuickAddMenu
    case .mood:        moodQuickAddMenu
    case .sleep, .body, .activity, .github, .intake, .symptoms, .medications:
      EmptyView()
    }
  }

  // MARK: - Tiles
  //
  // Order and visibility both come from Settings (`settingsStore.sections`),
  // and the resolved list is the same across every layout mode
  // (Tiles / Dense / Heatmap). User reorders in Settings → Sections →
  // all three modes update. The only fallback (cold launch, before the
  // section mirror hydrates) is the `SectionManifest` catalog order — no
  // separate hardcoded list. See `visibleDomains`.

  @ViewBuilder
  private var tiles: some View {
    ForEach(tileItems) { item in
      tileView(for: item)
    }
  }

  /// One grid cell per item. Intake is flattened HERE — each kind becomes its
  /// own top-level item, so it lands in its own grid cell (a nested ForEach
  /// returned from `tile(for:)` would collapse into a single cell instead).
  private var tileItems: [HomeTileItem] {
    visibleDomains.flatMap { domain -> [HomeTileItem] in
      guard domain == .intake else { return [.domain(domain)] }
      return intakeTiles.isEmpty ? [.domain(.intake)] : intakeTiles.map { .intakeKind($0) }
    }
  }

  @ViewBuilder
  private func tileView(for item: HomeTileItem) -> some View {
    switch item {
    case .domain(let d):     tile(for: d)
    case .intakeKind(let t): intakeKindTile(t)
    }
  }

  private enum HomeTileItem: Identifiable {
    case domain(HomepageDomain)
    case intakeKind(IntakeTileDTO)
    var id: String {
      switch self {
      case .domain(let d):     return d.rawValue
      case .intakeKind(let t): return "intake:\(t.id)"
      }
    }
  }

  /// Domain order + visibility, driven by Settings so reordering in
  /// Settings → Sections applies uniformly to every layout mode. Section
  /// keys we don't recognise as a `HomepageDomain` (e.g. `"calendar"`,
  /// which is surfaced inline in the Next tab) are dropped.
  ///
  /// Cold-launch fallback (before the section mirror hydrates) is the
  /// `SectionManifest` catalog order, filtered to dashboard-capable
  /// sections — the manifest is the single source of truth for section
  /// order, so there's no hardcoded list to keep in sync.
  private var visibleDomains: [HomepageDomain] {
    let enabledKeys = settingsStore.sections.filter(\.isEnabled).map(\.key)
    guard !enabledKeys.isEmpty else {
      return SectionManifest.all
        .filter(\.supportsDashboard)
        .compactMap { HomepageDomain(rawValue: $0.key) }
    }
    // Dedup: a domain renders once even if the section appears twice in the
    // enabled set (a duplicate SectionEntity would otherwise double its tiles —
    // and double *every* intake tracker, since intake expands per kind).
    var seen = Set<HomepageDomain>()
    return enabledKeys.compactMap { HomepageDomain(rawValue: $0) }
      .filter { seen.insert($0).inserted }
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
    case .hydration:   hydrationTile
    case .groceries:   groceriesTile
    case .intake:      intakeEmptyTile  // only reached when there are no kinds
    case .body:        bodyTile
    case .gut:         gutTile
    case .mood:        moodTile
    case .symptoms:    symptomsTile
    case .medications: medicationsTile
    case .activity:    activityTile
    case .github:      githubTile
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
    case .hydration:   return hydrationDomainData()
    case .groceries:   return groceriesDomainData()
    case .intake:      return intakeDomainData()
    case .body:        return bodyDomainData()
    case .gut:         return gutDomainData()
    case .mood:        return moodDomainData()
    case .symptoms:    return symptomsDomainData()
    case .medications: return medicationsDomainData()
    case .activity:    return activityDomainData()
    case .github:      return githubDomainData()
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
      title: String(localized: "Tasks", comment: "Section name"),
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
      title: String(localized: "Habits", comment: "Section name"),
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

  // MARK: Unified training "effort"
  //
  // Strength volume (weight×sets×reps, in the thousands) and cardio
  // minutes (tens) can't share an axis — cardio gets crushed to an
  // invisible sliver, so a real 25-min session looks like nothing
  // happened. Fix: convert every modality to one comparable unit —
  // **effort-minutes** — so any session visibly moves the needle.
  // Yoga/mobility is classified on its own so it counts as effort but
  // never inflates the cardio (Z2) totals.

  /// Classify one entry's modality and its effort-minute contribution.
  /// Static + `sessionTypes` passed in so it runs inside `computeDerived`
  /// off the render path.
  private static func effortContribution(for e: ExerciseEntry,
                                         sessionTypes: [SessionTypeConfig])
    -> (kind: SessionKind, minutes: Double)
  {
    // Resolve modality: prefer the routine's configured kind, fall back
    // to the seed mapping, then refine an ambiguous `.mixed` from fields.
    var kind = sessionTypes
      .first { $0.id.caseInsensitiveCompare(e.session) == .orderedSame }?.kind
      ?? SessionKind.defaulted(for: e.session)
    // Yoga/mobility can hide inside a mixed or mislabeled routine — catch
    // it by exercise name so it never lands in the cardio bucket.
    if let ex = e.exercise?.lowercased(),
       ex.contains("yoga") || ex.contains("stretch") || ex.contains("mobility") {
      kind = .mobility
    }
    if kind == .mixed {
      let looksCardio = (e.distanceM ?? 0) > 0
        || ((e.durationMin ?? 0) > 0 && e.weight == nil)
      kind = looksCardio ? .cardio : .strength
    }

    let dur = e.durationMin ?? 0
    switch kind {
    case .cardio:
      if dur > 0 { return (.cardio, dur) }
      // Distance-only run/ride: estimate ~6 min/km so it still counts.
      if let m = e.distanceM, m > 0 { return (.cardio, m / 1000.0 * 6.0) }
      return (.cardio, 0)
    case .mobility:
      // Yoga is time-based; counts as effort, never as cardio/Z2.
      return (.mobility, dur)
    case .strength, .mixed:
      if dur > 0 { return (.strength, dur) }
      // No clock on a lift → estimate from set count (~3.5 min/set incl.
      // rest). Reps/weight don't change wall-clock effort.
      if let s = e.sets.flatMap(Int.init), s > 0 {
        return (.strength, Double(s) * 3.5)
      }
      return (.strength, 0)
    }
  }

  /// Daily effort-minutes split into the two series the training
  /// visualization already uses: `cardio` keeps its own band, while
  /// `strengthLike` folds strength + mobility/yoga together (yoga counts
  /// as effort but never as cardio). Keyed by ISO date.
  private static func effortByDate(_ entries: [ExerciseEntry],
                                   sessionTypes: [SessionTypeConfig])
    -> (strengthLike: [String: Double], cardio: [String: Double])
  {
    var strengthLike: [String: Double] = [:]
    var cardio: [String: Double] = [:]
    for e in entries {
      let c = effortContribution(for: e, sessionTypes: sessionTypes)
      guard c.minutes > 0 else { continue }
      if c.kind == .cardio {
        cardio[e.date, default: 0] += c.minutes
      } else {
        strengthLike[e.date, default: 0] += c.minutes
      }
    }
    return (strengthLike, cardio)
  }

  // MARK: - Derived tile cache
  //
  // The three data-heavy tiles (Training, Body, GitHub) used to reshape
  // their series *inside* the view body — iterating every training entry,
  // every weigh-in, and building a 366-day date array on each render. That
  // ran for every visible tile on every redraw (taps, logs, scroll), which
  // is what made the homepage janky. Compute it ONCE whenever the underlying
  // data changes (`recomputeDerived`); the tiles just read the cached result.
  struct Derived {
    var trainStrengthBars7: [Int] = []
    var trainCardioBars7: [Int] = []
    var trainStrengthSeries90: [Double] = []
    var trainCardioSeries90: [Double] = []
    var weightActual30: [Double?] = []
    var githubCounts90: [Int] = []
    var githubStreak: Int = 0
  }

  static func computeDerived(
    recentTraining: [ExerciseEntry],
    sessionTypes: [SessionTypeConfig],
    github: GitHubContributions,
    bodyRows: [WithingsRow]
  ) -> Derived {
    var d = Derived()
    let cal = Calendar.current
    let fmt = ymdFormatter
    let now = Date()
    func dayKeys(_ n: Int) -> [String] {
      (0..<n).reversed().compactMap {
        cal.date(byAdding: .day, value: -$0, to: now).map(fmt.string(from:))
      }
    }
    let d7 = dayKeys(7)
    let d90 = dayKeys(90)

    // Training effort → normalized 7-day bars (tile) + raw 90-day series (domain).
    let effort = effortByDate(recentTraining, sessionTypes: sessionTypes)
    let maxS = max(1, d7.map { effort.strengthLike[$0] ?? 0 }.max() ?? 0)
    let maxC = max(1, d7.map { effort.cardio[$0] ?? 0 }.max() ?? 0)
    d.trainStrengthBars7 = d7.map { Int(((effort.strengthLike[$0] ?? 0) / maxS) * 50) }
    d.trainCardioBars7   = d7.map { Int(((effort.cardio[$0]       ?? 0) / maxC) * 50) }
    d.trainStrengthSeries90 = d90.map { effort.strengthLike[$0] ?? 0 }
    d.trainCardioSeries90   = d90.map { effort.cardio[$0] ?? 0 }

    // GitHub daily counts (90d) + current streak (consecutive days back).
    let gByDate = Dictionary(github.days.map { ($0.date, $0.count) },
                             uniquingKeysWith: { a, _ in a })
    d.githubCounts90 = d90.map { gByDate[$0] ?? 0 }
    var streak = 0
    for day in dayKeys(366).reversed() {
      if (gByDate[day] ?? 0) > 0 { streak += 1 } else { break }
    }
    d.githubStreak = streak

    // Body — actual weigh-ins for the last 30 days (nil on gap days).
    var wByDate: [String: Double] = [:]
    for r in bodyRows { if let w = r.weightKg { wByDate[r.date] = w } }
    let startToday = cal.startOfDay(for: now)
    d.weightActual30 = (0..<30).reversed().map { off -> Double? in
      guard let dd = cal.date(byAdding: .day, value: -off, to: startToday) else { return nil }
      return wByDate[fmt.string(from: dd)]
    }
    return d
  }

  /// Recompute the derived tile cache from current state — cheap relative to
  /// reshaping per-render. Called whenever Training / Body / GitHub inputs land.
  @MainActor
  private func recomputeDerived() {
    derived = Self.computeDerived(
      recentTraining: recentTraining,
      sessionTypes: trainingSessionTypes,
      github: githubContributions,
      bodyRows: bodyRows)
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
    // Series come from the precomputed cache (90-day effort-minutes, both
    // in the same unit so cardio isn't crushed under strength volume; yoga
    // folds into strength-like). Same `.stackedBars` visualization as before.
    let strengthSeries = derived.trainStrengthSeries90
    let cardioSeries = derived.trainCardioSeries90
    return HomepageDomainData(
      domain: .training,
      title: String(localized: "Training", comment: "Section name"),
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
      title: String(localized: "Chores", comment: "Section name"),
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
      title: String(localized: "Supplements", comment: "Section name"),
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
      title: String(localized: "Sleep", comment: "Section name"),
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
        title: String(localized: "Nutrition", comment: "Section name"),
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
      title: String(localized: "Nutrition", comment: "Section name"),
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
      title: String(localized: "Groceries", comment: "Section name"),
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

  private func bodyDomainData() -> HomepageDomainData {
    let latest = bodyRows.first
    let weight = latest?.weightKg
    let fat = latest?.fatPct
    let actualSeries = derived.weightActual30
    let present = actualSeries.compactMap { $0 }
    let avg = present.isEmpty ? 0.0 : present.reduce(0, +) / Double(present.count)
    let centeredValues: [Double?] = actualSeries.map { $0.map { $0 - avg } }
    let fatTarget: Double = 18
    return HomepageDomainData(
      domain: .body,
      title: String(localized: "Body", comment: "Section name"),
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

  // MARK: - GitHub
  //
  // Read-only contribution tile. `githubContributions` is the per-device
  // GraphQL fetch (Keychain token, no CloudKit); the tile shows daily
  // commit counts and the destination view owns the year heatmap. When the
  // user hasn't connected GitHub the series is all-zero and the tile reads
  // "0 this week" — same honest empty state as Sleep without Oura.

  // GitHub daily counts + streak are precomputed in `computeDerived`
  // (off the render path) and read via `derived.githubCounts90` /
  // `derived.githubStreak`.

  private func githubDomainData() -> HomepageDomainData {
    let counts = derived.githubCounts90
    let today = counts.last ?? 0
    let week = counts.suffix(7).reduce(0, +)
    let streak = derived.githubStreak
    return HomepageDomainData(
      domain: .github,
      title: String(localized: "GitHub", comment: "Section name"),
      accent: theme.color(for: "github"),
      headline: today > 0 ? "\(today) today · \(week) this week" : "\(week) this week",
      headlineStats: [
        .init(label: "Today", value: "\(today)"),
        .init(label: "Streak", value: "\(streak)", unit: "d"),
        .init(label: "Year", value: "\(githubContributions.total)"),
      ],
      progress: nil,
      history: .bars(counts),
      tap: .openSheet(.github)
    )
  }

  // GitHub — daily commit counts; 7-day histogram in the tile, full year
  // in the destination's heatmap.
  private var githubTile: some View {
    let counts = derived.githubCounts90
    let today = counts.last ?? 0
    let week = counts.suffix(7).reduce(0, +)
    let streak = derived.githubStreak
    let bars = Array(counts.suffix(7))
    return Button { open(.github) } label: {
      ModuleTile(
        title: String(localized: "GitHub", comment: "Section name"),
        accent: theme.color(for: "github"),
        stats: [
          .init(label: "Today", value: "\(today)"),
          .init(label: "Streak", value: "\(streak)", unit: "d"),
          .init(label: "Week", value: "\(week)")
        ],
        history: .init(label: "Commits (7d)", values: bars)
      )
    }
    .buttonStyle(.plain)
  }


  private func gutDomainData() -> HomepageDomainData {
    let count = gutToday?.movementCount ?? 0
    let avgBristol = Self.avgBristol(gutToday?.entries ?? [])
    let bars = gutHistory.map { $0.movements }
    let dailyTarget = 2
    return HomepageDomainData(
      domain: .gut,
      title: String(localized: "Gut", comment: "Section name"),
      accent: theme.color(for: "gut"),
      headline: "\(count)",
      headlineStats: [
        .init(label: "Today", value: "\(count)"),
        .init(label: "Avg Bristol",
              value: avgBristol.map { String(format: "%.1f", $0) } ?? "—"),
      ],
      progress: .init(label: "Today / typical",
                      current: Double(min(count, dailyTarget)),
                      target: Double(dailyTarget)),
      history: .bars(bars.isEmpty ? Array(repeating: 0, count: 90) : bars),
      tap: .openSheet(.gut)
    )
  }

  private var symptomsTile: some View {
    let data = symptomsDomainData()
    return Button { open(.symptoms) } label: {
      ModuleTile(
        title: data.title,
        accent: data.accent,
        stats: data.headlineStats.map { .init(label: $0.label, value: $0.value, unit: $0.unit) },
        history: .init(label: "Severity (7d)", values: symptomsHistory(days: 7))
      )
    }
    .buttonStyle(.plain)
  }

  private func symptomsDomainData() -> HomepageDomainData {
    let today = SeptenaDate.today
    let rows = fetchSymptoms(from: lastNDays(Self.historyDays).first ?? today, to: today)
    let todayRows = rows.filter { $0.date == today }
    let peak = todayRows.map(\.severity).max() ?? 0
    let avg = todayRows.isEmpty
      ? 0
      : Double(todayRows.reduce(0) { $0 + $1.severity }) / Double(todayRows.count)
    let history = symptomsHistory(days: Self.historyDays)
    return HomepageDomainData(
      domain: .symptoms,
      title: String(localized: "Symptoms", comment: "Section name"),
      accent: theme.color(for: "symptoms"),
      headline: "\(todayRows.count) · peak \(peak)",
      headlineStats: [
        .init(label: "Today", value: "\(todayRows.count)"),
        .init(label: "Peak", value: "\(peak)", unit: "/10"),
        .init(label: "Average", value: avg.decimalString(1), unit: "/10"),
      ],
      progress: .init(label: "Peak severity", current: Double(peak), target: 10, unit: "/10"),
      history: .bars(history),
      tap: .openSheet(.symptoms)
    )
  }

  private func symptomsHistory(days: Int) -> [Int] {
    let dates = lastNDays(days)
    guard let start = dates.first, let end = dates.last else { return [] }
    let rows = fetchSymptoms(from: start, to: end)
    let grouped = Dictionary(grouping: rows, by: \.date)
    return dates.map { grouped[$0]?.map(\.severity).max() ?? 0 }
  }

  private func fetchSymptoms(from start: String, to end: String) -> [SymptomEventEntity] {
    let descriptor = FetchDescriptor<SymptomEventEntity>(
      predicate: #Predicate { $0.date >= start && $0.date <= end }
    )
    return (try? modelContext.fetch(descriptor)) ?? []
  }

  private func todayTimelineExtraEvents(enabled: Set<String>) -> [DayTimelineExtraEvent] {
    var out: [DayTimelineExtraEvent] = []
    if enabled.contains("symptoms") {
      out += fetchSymptoms(from: clock.today, to: clock.today).map {
        DayTimelineExtraEvent(
          id: $0.id,
          date: $0.date,
          time: EventTimestamp.hhmm(from: $0.occurredAt),
          sectionKey: "symptoms")
      }
    }
    if enabled.contains("medications") {
      out += fetchMedicationDoses(from: clock.today, to: clock.today).map {
        DayTimelineExtraEvent(
          id: $0.id,
          date: $0.date,
          time: EventTimestamp.hhmm(from: $0.occurredAt),
          sectionKey: "medications")
      }
    }
    return out
  }

  private var medicationsTile: some View {
    let data = medicationsDomainData()
    return Button { open(.medications) } label: {
      ModuleTile(
        title: data.title,
        accent: data.accent,
        stats: data.headlineStats.map { .init(label: $0.label, value: $0.value, unit: $0.unit) },
        progress: data.progress.map {
          .init(label: $0.label, current: $0.current, target: $0.target, unit: $0.unit ?? "")
        },
        history: .init(label: "Taken (7d)", values: medicationsHistory(days: 7))
      )
    }
    .buttonStyle(.plain)
  }

  private func medicationsDomainData() -> HomepageDomainData {
    let today = SeptenaDate.today
    let active = fetchMedicationDefinitions().filter { !$0.archived }
    let rows = fetchMedicationDoses(from: lastNDays(Self.historyDays).first ?? today, to: today)
    let todayRows = rows.filter { $0.date == today }
    let taken = todayRows.filter { $0.status == "taken" }.count
    let skipped = todayRows.filter { $0.status == "skipped" || $0.status == "missed" }.count
    let routine = active.filter { ($0.scheduleKind ?? "daily") == "daily" }
    let target = max(routine.count, 1)
    return HomepageDomainData(
      domain: .medications,
      title: String(localized: "Medications", comment: "Section name"),
      accent: theme.color(for: "medications"),
      headline: routine.isEmpty ? "\(taken) taken" : "\(taken)/\(routine.count) taken",
      headlineStats: [
        .init(label: "Taken", value: "\(taken)"),
        .init(label: "Skipped", value: "\(skipped)"),
        .init(label: "Active", value: "\(active.count)"),
      ],
      progress: routine.isEmpty ? nil : .init(label: "Taken today", current: Double(min(taken, target)), target: Double(target)),
      history: .bars(medicationsHistory(days: Self.historyDays)),
      tap: .openSheet(.medications)
    )
  }

  private func medicationsHistory(days: Int) -> [Int] {
    let dates = lastNDays(days)
    guard let start = dates.first, let end = dates.last else { return [] }
    let rows = fetchMedicationDoses(from: start, to: end).filter { $0.status == "taken" }
    let grouped = Dictionary(grouping: rows, by: \.date)
    return dates.map { grouped[$0]?.count ?? 0 }
  }

  private func fetchMedicationDefinitions() -> [MedicationDefinitionEntity] {
    (try? modelContext.fetch(FetchDescriptor<MedicationDefinitionEntity>())) ?? []
  }

  private func fetchMedicationDoses(from start: String, to end: String) -> [MedicationDoseEventEntity] {
    let descriptor = FetchDescriptor<MedicationDoseEventEntity>(
      predicate: #Predicate { $0.date >= start && $0.date <= end }
    )
    return (try? modelContext.fetch(descriptor)) ?? []
  }

  private func activityDomainData() -> HomepageDomainData? {
    guard let snap = activitySnapshot() else { return nil }
    let stepsTarget = 8000
    return HomepageDomainData(
      domain: .activity,
      title: String(localized: "Activity", comment: "Section name"),
      accent: theme.color(for: "activity"),
      headline: "\(snap.steps) steps · \(snap.exMin) min",
      headlineStats: [
        .init(label: "Steps", value: "\(snap.steps)"),
        .init(label: "Active",
              value: "\(Int(snap.kcal))",
              unit: "kcal"),
        .init(label: "Exercise",
              value: "\(snap.exMin)",
              unit: "m"),
      ],
      progress: .init(label: "Steps target",
                      current: Double(min(snap.steps, stepsTarget)),
                      target: Double(stepsTarget)),
      // The heatmap / dense layouts render the full window, so feed the
      // 90-day step series from the synced entity — NOT `snap.bars`, which is
      // only the trailing 7 days the tile histogram needs. (This is why the
      // drawer showed full history but the heatmap looked near-empty.)
      history: .bars(activityStepBars(days: Self.historyDays)),
      tap: .openSheet(.activity)
    )
  }

  /// Steps per day for the trailing `days`, oldest → newest, gap-filled with
  /// 0, drawn from the persisted `ActivityDayEntity` rows. Feeds the homepage
  /// heatmap/dense modes (90-day window) the same way other sections do.
  private func activityStepBars(days: Int) -> [Int] {
    let keys = lastNDays(days)
    let rows = fetchActivityDays(from: keys.first ?? "", to: keys.last ?? "")
    let byDate = Dictionary(rows.map { ($0.date, $0.stepCount ?? 0) },
                            uniquingKeysWith: { a, _ in a })
    return keys.map { byDate[$0] ?? 0 }
  }

  /// Today's numbers + trailing-7-day step bars for the Activity surfaces.
  /// Prefers the live HealthKit snapshot on iOS; falls back to the synced
  /// `ActivityDayEntity` rows so macOS (no HealthKit) and a cold cache still
  /// render. Returns nil only when there's genuinely nothing to show.
  private struct ActivitySnapshot {
    let steps: Int
    let kcal: Double
    let exMin: Int
    let bars: [Int]   // trailing 7 days, oldest → newest
  }

  private func activitySnapshot() -> ActivitySnapshot? {
    let bridge = HealthKitBridge.shared
    let dates = lastNDays(7)
    let rows = fetchActivityDays(from: dates.first ?? "", to: dates.last ?? "")
    guard bridge.isAvailable || !rows.isEmpty else { return nil }
    let byDate = Dictionary(rows.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
    let today = dates.last ?? SeptenaDate.today
    let todayRow = byDate[today]
    let steps = bridge.isAvailable ? bridge.stepsToday           : (todayRow?.stepCount ?? 0)
    let kcal  = bridge.isAvailable ? bridge.activeKcalToday      : (todayRow?.activeKcal ?? 0)
    let exMin = bridge.isAvailable ? bridge.exerciseMinutesToday : (todayRow?.exerciseMinutes ?? 0)
    let bars  = bridge.isAvailable ? Array(bridge.stepsHistory.suffix(7))
                                   : dates.map { byDate[$0]?.stepCount ?? 0 }
    return ActivitySnapshot(steps: steps, kcal: kcal, exMin: exMin, bars: bars)
  }

  private func fetchActivityDays(from start: String, to end: String) -> [ActivityDayEntity] {
    let descriptor = FetchDescriptor<ActivityDayEntity>(
      predicate: #Predicate { $0.date >= start && $0.date <= end }
    )
    return (try? modelContext.fetch(descriptor)) ?? []
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
        // Pop the composer right here over the homepage — no tab switch /
        // navigation into the Tasks list first.
        creatingTask = true
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
    .onTapGesture { open(.habits) }
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
  // histogram bars stack strength-like effort (full accent) and cardio
  // effort (lighter shade) per day — both in effort-minutes, with yoga
  // folded into strength-like rather than cardio. Each series is normalized
  // to its own 7-day max ×50 so a peak day fills the chart.
  private var trainingTile: some View {
    let accent = theme.color(for: "training")
    // Same fix as `trainingDomainData`: stats are trailing 7 days so
    // they read sensibly against the weekly Z2 target. Tile bar chart
    // still renders 7 days regardless via `lastSevenDays`.
    let sessionCount = weeklySessionCount
    let minutes = Int(cardio?.daily.last?.rolling7d ?? 0)
    let target = cardio?.targetWeeklyMin ?? 150

    let strengthBars = derived.trainStrengthBars7
    let cardioBars   = derived.trainCardioBars7

    return WeekTrainingTile(
      accent: accent,
      sessionCount: sessionCount,
      minutes: minutes,
      target: target,
      strengthBars: strengthBars,
      cardioBars: cardioBars
    )
    .contentShape(Rectangle())
    .onTapGesture { open(.training) }
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
    let fmt = Self.ymdFormatter
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
    .onTapGesture { open(.chores) }
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
    .onTapGesture { open(.supplements) }
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
    return Button { open(.sleep) } label: {
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
    .onTapGesture { open(.groceries) }
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

  // MARK: - Intake (consumables) tiles
  //
  // One host section, one tile per kind (Option C). `tile(for: .intake)`
  // returns N tiles (the grid flattens the nested ForEach), so no change to
  // the `tiles` loop. Tapping opens the kind switcher; each kind page owns its
  // container-aware quick-add. Non-Tiles layout modes show one aggregate row
  // via `intakeDomainData()`. See docs/CONSUMABLES_PLAN.md.

  private func intakeKindTile(_ t: IntakeTileDTO) -> some View {
    let accent = AdaptiveColor.adaptive(t.color) ?? theme.color(for: "intake")
    var stats: [ModuleTile.Stat] = [.init(label: "Today", value: "\(t.todayCount)")]
    if t.showsAmount, t.todayAmount > 0 {
      stats.append(.init(label: "Total",
                         value: String(format: "%.1f", t.todayAmount),
                         unit: t.unit))
    }
    // Reduce/quit trackers headline their days-since-last streak ("12d clean").
    if IntakeObjective.emphasizesStreak(t.objective),
       let days = intakeDaysSince(t.lastEventAt), days >= 1 {
      stats.append(.init(label: IntakeObjective.streakLabel(t.objective), value: "\(days)d"))
    }
    let bars = Array(t.dailyCounts.suffix(7))
    return ModuleTile(title: t.name, accent: accent, stats: stats,
                      history: .init(label: "7-day",
                                     values: bars.isEmpty ? Array(repeating: 0, count: 7) : bars))
      .contentShape(Rectangle())
      .onTapGesture { openIntakeKind(t.id) }
      .contextMenu { intakeQuickAddMenu(for: t) }
  }

  /// Long-press quick-add for a tracker tile — the same container-aware
  /// choices its kind page builds (Continue (Hit N) / New capsule / methods),
  /// logging directly like the caffeine tile menu does.
  @ViewBuilder
  private func intakeQuickAddMenu(for t: IntakeTileDTO) -> some View {
    let methods = t.methods.map {
      ConsumableContainer.Method(token: $0.token, label: $0.label,
                                 symbol: $0.symbol, usesContainer: $0.usesContainer)
    }
    let choices = ConsumableContainer.choices(
      lastCount: t.lastContainerCount,
      containerCap: t.containerCap,
      containerNoun: t.containerNoun ?? "container",
      countNoun: t.countNoun ?? "use",
      methods: methods)
    ForEach(choices, id: \.value) { choice in
      Button {
        commitIntake(t, value: choice.value)
      } label: {
        Label("Log \(choice.label)", systemImage: choice.symbol ?? "plus.circle")
      }
    }
  }

  private func commitIntake(_ t: IntakeTileDTO, value: String) {
    let (token, count) = ConsumableContainer.parse(value: value)
    let method = t.methods.first { $0.token == token }
    SeptenaServices.shared.intakeMutator.addEntry(
      kindID: t.id,
      date: clock.today,
      time: EventTimestamp.hhmm(from: clock.now),
      method: token,
      amount: t.showsAmount ? method?.defaultAmount : nil,
      count: count)
    Haptics.success()
  }

  private func intakeDaysSince(_ date: Date?) -> Int? {
    guard let date else { return nil }
    let cal = Calendar.current
    return cal.dateComponents([.day],
                              from: cal.startOfDay(for: date),
                              to: cal.startOfDay(for: clock.now)).day
  }

  /// Shown when the section is enabled but has no kinds yet — keeps the
  /// destination reachable so the user can create their first tracker.
  private var intakeEmptyTile: some View {
    ModuleTile(title: SectionManifest.byKey["intake"]?.defaultLabel ?? "Intake",
               accent: theme.color(for: "intake"),
               stats: [.init(label: "Trackers", value: "0")])
      .contentShape(Rectangle())
      .onTapGesture { open(.intake) }
  }

  /// Aggregate row for the non-Tiles layout modes (Dense / Heatmap / Rings /
  /// Wheel), which consume `visibleDomainData` rather than `tile(for:)`.
  private func intakeDomainData() -> HomepageDomainData {
    let totalToday = intakeTiles.reduce(0) { $0 + $1.todayCount }
    return HomepageDomainData(
      domain: .intake,
      title: SectionManifest.byKey["intake"]?.defaultLabel ?? "Intake",
      accent: theme.color(for: "intake"),
      headline: "\(intakeTiles.count) trackers · \(totalToday) today",
      headlineStats: [
        .init(label: "Trackers", value: "\(intakeTiles.count)"),
        .init(label: "Today", value: "\(totalToday)"),
      ],
      progress: nil,
      history: nil,
      tap: .openSheet(.intake)
    )
  }

  private func reloadIntake() async {
    let date = clock.today
    intakeTiles = await MirrorReader.shared.read { IntakeReader.loadTiles(context: $0, date: date) }
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
    let actualSeriesFull = derived.weightActual30
    let actualSeries = Array(actualSeriesFull.suffix(7))
    let present = actualSeries.compactMap { $0 }
    let avg = present.isEmpty ? 0.0 : present.reduce(0, +) / Double(present.count)
    let centeredValues: [Double?] = actualSeries.map { $0.map { $0 - avg } }
    // Body-fat percentage tracked against a soft 18% target (single number,
    // overrideable later via Settings.targets.fat_min_pct).
    let fatTarget: Double = 18
    return Button { open(.body) } label: {
      ModuleTile(
        title: String(localized: "Body", comment: "Section name"),
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
    let avgBristol = Self.avgBristol(gutToday?.entries ?? [])
    let bars = Array(gutHistory.map { $0.movements }.suffix(7))
    let dailyTarget = 2
    return ModuleTile(
      title: String(localized: "Gut", comment: "Section name"),
      accent: accent,
      stats: [
        .init(label: "Today",       value: "\(count)"),
        .init(label: "Avg Bristol", value: avgBristol.map { String(format: "%.1f", $0) } ?? "—")
      ],
      progress: .init(label: "Today / typical",
                      current: Double(min(count, dailyTarget)),
                      target: Double(dailyTarget)),
      history: .init(label: "7-day movements",
                     values: bars.isEmpty
                       ? Array(repeating: 0, count: 7) : bars)
    )
    .contentShape(Rectangle())
    .onTapGesture { open(.gut) }
    .contextMenu { gutQuickAddMenu }
  }

  // Bristol scale is a fixed 7-item enum — the menu IS the complete UX,
  // no "More…" sheet fallback. Matches AddGutPage's commit semantics;
  // the full editor lives in GutDestinationView.
  @ViewBuilder private var gutQuickAddMenu: some View {
    let hasLast = !(gutToday?.entries.isEmpty ?? true)
    GutQuickAddMenu(
      recentBristolTypes: GutBristolRecorder.recentTypes,
      onCommit: { bristol in commitGut(bristol: bristol) },
      hasLastEntry: hasLast,
      onEditLast: hasLast ? { open(.gut) } : nil
    )
  }

  /// Mean Bristol score across today's movements, or nil when none logged.
  private static func avgBristol(_ entries: [GutEntry]) -> Double? {
    guard !entries.isEmpty else { return nil }
    return Double(entries.reduce(0) { $0 + $1.bristol }) / Double(entries.count)
  }

  private func commitGut(bristol: Int) {
    SectionLog.newLog(section: "gut", accent: theme.color(for: "gut"),
                      logCommit: logCommit) {
      SeptenaServices.shared.gutMutator.addEntry(
        date: SeptenaDate.today, time: SeptenaDate.nowHHMM, bristol: bristol)
      GutBristolRecorder.record(bristol)
      AddInfoSection.gut.notifyTilesChanged()
    }
  }

  // Activity — Apple Health, on-device. Skips entirely when HealthKit
  // isn't available (Mac). Real per-day step bars from the last 7 days.
  @ViewBuilder
  private var activityTile: some View {
    Group {
      if let snap = activitySnapshot() {
        let accent = theme.color(for: "activity")
        let stepsTarget = 8000
        Button { open(.activity) } label: {
          ModuleTile(
            title: String(localized: "Activity", comment: "Section name"),
            accent: accent,
            stats: [
              .init(label: "Steps",    value: "\(snap.steps)"),
              .init(label: "Active",   value: "\(Int(snap.kcal))", unit: "kcal"),
              .init(label: "Exercise", value: "\(snap.exMin)", unit: "m")
            ],
            progress: .init(label: "Steps target",
                            current: Double(min(snap.steps, stepsTarget)),
                            target: Double(stepsTarget)),
            history: .init(label: "7-day steps",
                           values: snap.bars)
          )
        }
        .buttonStyle(.plain)
      }
    }
  }

  // Settings is reached from the sidebar (and ⌘, on macOS) — it's an
  // app-level surface, not a Week tile, and not on this toolbar.

  // The 30-day actual-weigh-in series (no carry-forward) is precomputed in
  // `computeDerived` off the render path and read via `derived.weightActual30`.

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
        title: String(localized: "Nutrition", comment: "Section name"),
        accent: accent,
        stats: [
          .init(label: "Fasting", value: fastingDurationText(totalMin: totalMin)),
          .init(label: "Since", value: since)
        ],
        progress: fastingProgressRow(totalMin: totalMin),
        history: .init(label: "7-day fasts (h)", values: fastingHoursBars())
      )
      .contentShape(Rectangle())
      .onTapGesture { open(.nutrition) }
      .contextMenu { nutritionQuickAddMenu }
    } else {
      let proteinTarget = nutritionTarget?.protein.min ?? 150
      let bars = Array((nutritionStats?.daily.map { Int($0.proteinG) }
                ?? Array(repeating: 0, count: 7)).suffix(7))
      ModuleTile(
        title: String(localized: "Nutrition", comment: "Section name"),
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
      .onTapGesture { open(.nutrition) }
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
    NutritionPlugin.commitMeal(
      loggedAt: .now,
      accent: theme.color(for: "nutrition"),
      announce: "Logged \(entry.foods.first ?? "meal").",
      logCommit: logCommit
    ) {
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
    }
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
      title: String(localized: "Mood", comment: "Section name"),
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
    .onTapGesture { open(.mood) }
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
    // Tasks-tile "Create in Inbox…" — the composer, as the standard edit drawer.
    .taskComposerDrawer(isPresented: $creatingTask) {
      TaskComposerCard(
        mode: .create(.inbox),
        areas: LocalCache.areas(in: modelContext),
        projects: LocalCache.projects(in: modelContext),
        accent: theme.color(for: "tasks"),
        onDone: { Task { await refreshTasks() } }
      )
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
      title: String(localized: "Mood", comment: "Section name"),
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
    await refresh([.mood])
  }

  // MARK: - Hydration

  // Hydration — today's water total vs the daily target + a 7-day intake
  // histogram. Backed by Nutrition's water entries (no entity of its own),
  // so like Mood it routes around `AddInfoSection` and refreshes itself
  // after a quick-add commit.
  private var hydrationTile: some View {
    let accent = theme.color(for: "hydration")
    let bars = Array(hydrationHistory.suffix(7))
    return ModuleTile(
      title: String(localized: "Hydration", comment: "Section name"),
      accent: accent,
      stats: [
        .init(label: "Today",  value: "\(hydrationToday)", unit: "ml"),
        .init(label: "Target", value: "\(hydrationTargetMl)", unit: "ml"),
      ],
      progress: .init(label: "Today / target",
                      current: Double(min(hydrationToday, hydrationTargetMl)),
                      target: Double(max(hydrationTargetMl, 1)),
                      unit: "ml"),
      history: .init(label: "7-day intake",
                     values: bars.isEmpty
                       ? Array(repeating: 0, count: 7) : bars)
    )
    .contentShape(Rectangle())
    .onTapGesture { open(.hydration) }
    .contextMenu { hydrationQuickAddMenu }
  }

  /// Preset glasses commit a water-only Nutrition entry at the current
  /// time. Custom amounts live in the destination view's sheet — the
  /// menu keeps to the three calibrated presets for one-tap logging.
  @ViewBuilder private var hydrationQuickAddMenu: some View {
    ForEach([250, 330, 500], id: \.self) { ml in
      Button {
        commitHydration(ml: ml)
      } label: {
        Label("Add \(ml) ml", systemImage: "drop.fill")
      }
    }
  }

  private func hydrationDomainData() -> HomepageDomainData {
    HomepageDomainData(
      domain: .hydration,
      title: String(localized: "Hydration", comment: "Section name"),
      accent: theme.color(for: "hydration"),
      headline: "\(hydrationToday) of \(hydrationTargetMl) ml",
      headlineStats: [
        .init(label: "Today",  value: "\(hydrationToday)", unit: "ml"),
        .init(label: "Target", value: "\(hydrationTargetMl)", unit: "ml"),
      ],
      progress: .init(label: "Today / target",
                      current: Double(min(hydrationToday, hydrationTargetMl)),
                      target: Double(max(hydrationTargetMl, 1)),
                      unit: "ml"),
      history: .bars(hydrationHistory.isEmpty
                       ? Array(repeating: 0, count: 90) : hydrationHistory),
      tap: .openSheet(.hydration)
    )
  }

  /// Log a glass from the tile's quick-add menu. Mirrors the destination
  /// view's commit exactly: ONLY the glass that crosses today's target gets
  /// the canvas (`.fill`, once a day); every other glass commits quietly
  /// (tick + announce — water is too frequent to celebrate). Then
  /// self-refreshes the tile.
  ///
  /// The crossing check reads today's REAL total from the local mirror, not
  /// `hydrationToday` — that display state is seeded from a cache whose
  /// "today" can be yesterday (launch after rollover) and lags drawer logs,
  /// which mis-fired the once-a-day flood on ordinary glasses.
  private func commitHydration(ml: Int) {
    let accent = theme.color(for: "hydration")
    let dayStart = Calendar.current.startOfDay(for: clock.now)
    let todayMl = HydrationPlugin.waterMl(onDayStarting: dayStart, in: modelContext)
    let crossed = hydrationTargetMl > 0
      && todayMl < hydrationTargetMl
      && todayMl + ml >= hydrationTargetMl
    let write = {
      _ = SeptenaServices.shared.nutritionMutator.addEntry(
        loggedAt: .now,
        emoji: "💧",
        foods: HydrationPlugin.waterFoodsMarker,
        mealType: nil,
        source: "manual",
        waterMl: Double(ml)
      )
      Task { await refreshHydration() }
    }
    if crossed {
      SectionLog.newLog(
        section: "hydration",
        accent: accent,
        motion: .fill,
        intensity: 1.4,
        announce: "Hydration goal reached — \(todayMl + ml) of \(hydrationTargetMl) ml.",
        logCommit: logCommit,
        write: write
      )
    } else {
      SectionLog.quietLog(announce: "Logged \(ml) ml of water.", write: write)
    }
  }

  /// Reload hydration state after an in-app commit. Hydration doesn't
  /// route through `AddInfoSection.notifyTilesChanged`, so — like Mood —
  /// it refreshes itself from the Nutrition mirror.
  private func refreshHydration() async {
    await refresh([.hydration])
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
  let onTaskChange: () -> Void
  let onDayChange: () -> Void
  /// Receives the `.septenaDataChanged` notification itself so the owner
  /// can scope the reload to `note.changedSections` (nil = refresh all).
  let onDataChange: (Notification) -> Void
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
      //   • top-left "…" menu (dashboard layout + Settings)
      // Search lives in the Tasks sidebar, not the dashboard chrome.
      .toolbar { toolbar() }
      // Two-phase load: paint cached blobs synchronously so tiles +
      // histograms appear immediately on cold launch, then kick off the
      // network refresh in the background.
      .task {
        await onInitialLoad()
      }
      // CK fetch landed (push or foreground refresh) — repaint so today's
      // task counts reflect mutations from other devices.
      .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
        onTaskChange()
      }
      // CK fetch batch landed for any non-task domain (push, periodic
      // fetch, or a write on another device). Refresh every CK-backed
      // tile from its SwiftData mirror. Without this, the dashboard
      // stays stuck on whatever `loadAll` saw at cold launch — entries
      // logged on another device never repaint until the user visits
      // the section.
      .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
        onDataChange(note)
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
  let nutrition: [NutritionEntry]
  let gut: [GutEntry]
  let mood: [MoodEntry]
  let habits: [HabitDayItem]
  let supplements: [SupplementDayItem]
  let chores: [ChoreItem]
  let training: [ExerciseEntry]
  let tasks: [SeptenaTask]
  let extras: [DayTimelineExtraEvent]
  let calendar: [EKEvent]
  let macroColors: MacroColors?
  var fullDay: Bool = false

  var body: some View {
    DayTimelineView(
      date: date,
      oura: oura,
      nutrition: nutrition,
      gut: gut,
      mood: mood,
      habits: habits,
      supplements: supplements,
      chores: chores,
      training: training,
      tasks: tasks,
      extras: extras,
      calendar: calendar,
      macroColors: macroColors,
      fullDay: fullDay
    )
    // Skip the body (day re-clustering) when none of the inputs changed —
    // the dashboard re-renders far more often than the timeline data moves.
    .equatable()
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
      title: String(localized: "Tasks", comment: "Section name"),
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
      title: String(localized: "Habits", comment: "Section name"),
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
      title: String(localized: "Training", comment: "Section name"),
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
      title: String(localized: "Chores", comment: "Section name"),
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
      title: String(localized: "Supplements", comment: "Section name"),
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
      title: String(localized: "Sleep", comment: "Section name"),
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
      title: String(localized: "Groceries", comment: "Section name"),
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

// MARK: - Claude reconnect banner
//
// Subtle, non-modal cue on the homepage shown only when the Claude gateway
// token has gone stale (the app never auto-pops the Apple sign-in). Tapping
// it is an explicit user action, so presenting the sign-in here is expected.
private struct ClaudeReconnectBanner: View {
  @State private var provider = ClaudeGatewayProvider.shared

  var body: some View {
    if provider.isEnabled && provider.needsReauth {
      Button {
        Task { await provider.refreshNow() }
      } label: {
        HStack(spacing: 8) {
          Circle()
            .fill(Color.claudeAccent)
            .frame(width: 7, height: 7)
          Text("Reconnect")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.claudeAccent)
          Text("Claude session expired")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(-1)
          Spacer(minLength: 8)
          if provider.isRefreshing {
            ProgressView().controlSize(.small)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
      }
      .buttonStyle(.plain)
    }
  }
}
