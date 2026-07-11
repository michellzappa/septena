import SwiftUI
import SwiftData
import EventKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

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
  /// "Today at a glance" at the top of the layout grid: the circular Day dial
  /// hero, the linear timeline strip, or hidden (`DayViewStyle`, Settings ▸
  /// Home).
  @AppStorage(SettingsKey.homepageDayView)
  private var dayViewRaw: String = DayViewStyle.dial.rawValue
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

  /// Live pinned goals — prepended to the section tile grid as first placements.
  @Query(filter: #Predicate<GoalEntity> { $0.pinned },
         sort: \GoalEntity.sortIndex) private var pinnedGoals: [GoalEntity]
  @State private var editingGoal: Goal? = nil
  @State private var goalEditSections: [SectionConfig] = []

  private var goalMutator: GoalMutator { SeptenaServices.shared.goalMutator }

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
  @State private var derived = DashboardTileDerived()

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
  /// Full intake editor presented from a tracker tile's "New entry…" row — the
  /// quick-add's full-input escape (mirrors Nutrition's "New meal…"). Holds the
  /// kind id; nil when closed.
  @State private var intakeEditorKind: IntakeEditorTarget? = nil
  /// Create-a-tracker wizard, presented from the empty-state tile. Intake has no
  /// monolithic section screen (each kind is its own tile → drawer), so the empty
  /// state goes straight to creation rather than a redundant kind-switcher list.
  @State private var creatingIntakeKind = false
  @State private var bodyRows: [WithingsRow] = []
  /// GitHub contribution calendar (read-only, per-device token). Drives the
  /// GitHub tile's commit counts; the destination view fetches its own copy.
  @State private var githubContributions: GitHubContributions = .empty
  /// Guards `loadNetwork` against overlapping runs so concurrent provider
  /// HTTP stays within the safe parallel ceiling.
  @State private var networkLoading = false
  /// Dashboard reads settle in several waves. Publish one final widget state
  /// instead of rebuilding and reloading every widget after each wave.
  @State private var widgetPublishGeneration: UInt = 0
  @State private var gutToday: GutDayResponse? = nil
  @State private var gutHistory: [GutHistoryPoint] = []
  @State private var moodToday: MoodDayResponse? = nil
  @State private var moodHistory: [MoodHistoryPoint] = []
  /// Drives the Tasks-tile "Create in Inbox…" composer, popped in place.
  @State private var creatingTask = false
  /// Bumped after a Symptoms/Medications tile quick-add. Those two tiles read
  /// their SwiftData mirror synchronously each body eval and route around
  /// `AddInfoSection`/`DashSection` (the scoped tile-refresh path), so a write
  /// alone won't repaint them — toggling this @State re-evaluates the body,
  /// which re-fetches the fresh count/severity. Mirrors how Mood/Hydration
  /// self-refresh after their own quick-adds.
  @State private var quickLogStamp = 0
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
    _derived = State(initialValue: DashboardTileBuilder.computeDerived(
      recentTraining: ResponseCache.load([ExerciseEntry].self, forKey: CacheKey.recentTraining) ?? [],
      sessionTypes: [],
      github: ResponseCache.load(GitHubContributions.self, forKey: CacheKey.github) ?? .empty,
      bodyRows: ResponseCache.load([WithingsRow].self, forKey: CacheKey.bodyRows) ?? [],
      now: Date()))
  }

  /// iPhone compact: two columns. iPad regular & macOS: adaptive —
  /// packs as many ~280pt tiles as fit, so a narrow Stage Manager / split
  /// window stays at 2 columns while a full-screen 13" iPad or a wide Mac
  /// window gets 4–5. LazyVGrid reflows on resize. (Previously iPad was
  /// hard-pinned to 3 columns regardless of width, which cramped narrow
  /// regular-width windows and under-filled wide ones.)
  private var columns: [GridItem] {
    #if os(iOS)
    if splitHomeLayout {
      // Beside the dial rail the tiles only get ~half the window — adaptive
      // packing crowds the heatmaps, so keep the right column a single
      // stacked column of full-width tiles.
      return [GridItem(.flexible(), spacing: Theme.tileGap)]
    }
    if hSize == .regular {
      return [GridItem(.adaptive(minimum: 280), spacing: Theme.tileGap)]
    }
    // Compact iPhone (portrait): two columns. A whole row per tile wasted
    // width — the numbers-and-histogram tile reads fine at half width and
    // matches the density of the other layout modes.
    return Array(repeating: GridItem(.flexible(), spacing: Theme.tileGap), count: 2)
    #else
    return [GridItem(.adaptive(minimum: 280), spacing: Theme.tileGap)]
    #endif
  }

  /// On a wide-enough iPhone — landscape on a Plus/Max, or an unfolded
  /// foldable, both of which report `.regular` width — float the day dial
  /// into a left rail with the tiles stacked beside it on the right, instead
  /// of the donut sitting alone above a full-width grid. iPhone-only on
  /// purpose: iPad and Mac keep their single-column-with-adaptive-grid home,
  /// so this is the one place we read the idiom rather than width alone.
  /// Only the circular `.dial` day view splits; the linear timeline and the
  /// hidden style stay in the single column (a narrow rail would squish the
  /// timeline).
  private var splitHomeLayout: Bool {
    #if os(iOS)
    guard UIDevice.current.userInterfaceIdiom == .phone, hSize == .regular
    else { return false }
    return (DayViewStyle(rawValue: dayViewRaw) ?? .dial) == .dial
    #else
    return false
    #endif
  }

  /// True where the iPad floating chrome bar reserves the top inset (iOS
  /// regular), so the page's own `pageTop` would double it.
  private var chromeBarReservesTop: Bool {
    #if os(iOS)
    hSize == .regular
    #else
    false
    #endif
  }

  /// Balanced breathing room above (chrome / `pageTop`) and below the dial.
  private var dialBreathingRoom: CGFloat {
    DialHeroMetrics.breathingRoom(chromeBarAbove: chromeBarReservesTop)
  }

  /// True when no section or intake page is pushed on iPad — drives hiding the
  /// window-level chrome overlay below the Today tab root.
  private var isNavigationAtRoot: Bool {
    sheetDest == nil && intakeKindDest == nil
  }

  /// Width of the left rail in the split iPhone layout — sized to seat the
  /// dial (diameter + its breathing room) without starving the tile column.
  private let heroRailWidth: CGFloat = 340

  /// The day view — circular dial, linear timeline, or hidden. Extracted so
  /// it can sit either atop the column or in the split layout's left rail.
  @ViewBuilder private var dayView: some View {
    switch DayViewStyle(rawValue: dayViewRaw) ?? .dial {
    case .dial:
      DayDialHero(visibleSections: Set(visibleDomains.map(\.rawValue)),
                  sleepNights: ouraNights)
    case .linear:
      todayTimeline
    case .hidden:
      EmptyView()
    }
  }

  /// Everything below (or, in the split layout, beside) the day view: the
  /// discovery card, the tile grid, and the optional closing line.
  @ViewBuilder private var rightColumnBody: some View {
    // Introduces the capabilities the welcome leaves out (Coach, Insights,
    // Apple Health) once the user is in the app. Self-gating: renders nothing
    // once everything's discovered or it's dismissed.
    DashboardDiscoveryCard(onOpen: open)
    layoutBody
    // Optional, off-by-default closing line — a quote that rotates through
    // the day. Always last; renders nothing when disabled.
    DailyMessageFooter()
  }

  var body: some View {
    WeekDashboardScreen(
      currentDay: clock.today,
      onInitialLoad: {
        paintFromCache()
        // Mirror reads + task counts run ~6–12s on a large account; don't hold
        // the screen's `.task` (or the main actor through `apply` /
        // `refreshTasks`) across that window — gestures freeze when launch work
        // and interaction overlap. Cached blobs already painted above.
        Task { await loadAll() }
      },
      onTaskChange: {
        // A task mutation only touches the Tasks tile — reload just that,
        // not all ~20 sections. This is the per-toggle hitch fix.
        Task { await refresh([.tasks]) }
      },
      onDayChange: {
        // Roll over every tile for the new day. Intake loads on a separate
        // path (`reloadIntake`) and isn't part of `loadAll`, so reload it
        // explicitly — otherwise its "N today" count stays stuck on
        // yesterday's events after midnight while the rest of the dash resets.
        Task { await loadAll() }
        Task { await reloadIntake() }
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
      menuExtra: { weekMenuExtra }
    ) {
      ZStack {
        VStack(spacing: Theme.sectionSpacing) {
          // iOS floats the reconnect cue as a glass pill beside the "…" in the
          // top bar (added in the screen's toolbar); macOS keeps it inline here
          // since its "…" menu lives top-right, not in a leading bar.
          #if os(macOS)
          ClaudeReconnectCue(.card)
          #endif
          if splitHomeLayout {
            // Wide iPhone (landscape / unfolded): dial in a left rail, the
            // discovery card + tiles + footer stacked in the right column.
            HStack(alignment: .top, spacing: Theme.sectionSpacing) {
              dayView
                .frame(width: heroRailWidth)
              VStack(spacing: Theme.sectionSpacing) {
                rightColumnBody
              }
            }
          } else {
            // Stack the dial above the grid with a gap that matches the chrome
            // inset above — iPad's 74pt bar vs the old uniform sectionSpacing
            // left the donut visually high in the sky wash.
            VStack(spacing: 0) {
              dayView
              rightColumnBody
                .padding(.top, dialBreathingRoom)
            }
          }
        }
        // On iPad the floating chrome bar already reserves the top space
        // (`PageChromeMetrics.iPadBarHeight`), so the page's own `pageTop` is
        // redundant there — drop it so Today's content sits at the same height
        // as the list tabs. iPhone keeps a tightened `pageTop`.
        // Today's tile grid is intentionally WIDE (adaptive multi-column on
        // iPad), so it opts out of the ~640 readable-column cap the list tabs
        // use — the scroll-level `septenaTabScrollInsets` horizontal inset is a
        // no-op on this ScrollView anyway. Its side breathing room comes from
        // `pageGutter` here on every size class (iPhone/iPad/Mac alike);
        // dropping it on iPad let the widgets run to the screen edge.
        .septenaSurface(top: chromeBarReservesTop ? 0 : dialBreathingRoom)
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
      .onChange(of: nav.pendingDashboardTile) { _, itemID in
        guard let itemID else { return }
        nav.pendingDashboardTile = nil
        handleWidgetDeepLink(itemID: itemID)
      }
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
        // A single tracker's log (coffee, matcha…) is content-light — medium.
        .sectionDrawerPresentation(shortInDemo: true)
    }
    .sheet(isPresented: $creatingIntakeKind) {
      IntakeKindWizard(onCreated: { _ in Task { await reloadIntake() } })
    }
    // Tasks-tile "Create in Inbox…" — the composer, as the standard edit drawer.
    // Anchored on the top-level screen (not the Tasks/Mood tile) so it presents
    // regardless of which tiles are enabled or materialized in the lazy grid.
    .taskComposerDrawer(isPresented: $creatingTask) {
      TaskComposerCard(
        mode: .create(.triage),
        areas: LocalCache.areas(in: modelContext),
        projects: LocalCache.projects(in: modelContext),
        accent: theme.color(for: "tasks"),
        onDone: { Task { await refreshTasks() } }
      )
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
      case .scan:
        NewNutritionEntrySheet(autoStartScan: true)
          #if os(iOS)
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
          #else
          .frame(width: 560, height: 600)
          #endif
      }
    }
    // The tracker tile's "New entry…" escape — the full intake editor for a
    // fresh entry (when / method / amount / variety / note), the same form the
    // section page uses. `original: nil` opens it blank.
    .sheet(item: $intakeEditorKind) { target in
      EditIntakeEntrySheet(kindID: target.kindID, date: clock.today, original: nil,
                           onSave: { Task { await reloadIntake() } })
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 560, height: 600)
        #endif
    }
    .iPadReportsNavDepth(id: "week", atRoot: isNavigationAtRoot)
  }

  /// Week's page-local rows for the "···" overflow menu (`.pageChrome`'s
  /// `localActions` — see docs/PAGE_CHROME_SPEC.md). The dashboard-layout
  /// switcher and Insights live here; Settings is the constant gear, not a menu
  /// row, and sync status isn't surfaced in the chrome.
  @ViewBuilder
  private var weekMenuExtra: some View {
    HomepageLayoutMenuSection()
    Divider()
    // Insights — folded in from the old top-right toolbar button. Insights has
    // no per-day series, so the menu is its natural home. (Free like the rest
    // of the app — no gate.)
    Button {
      logInsightsOpen("menu tapped")
      open(.insights)
    } label: {
      Label("Insights", systemImage: "chart.dots.scatter")
    }
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

  /// Identifies which tracker kind the full intake editor is open for. Distinct
  /// from `IntakeKindRef` (page navigation) so presenting the editor never
  /// collides with a pushed/sheeted kind page.
  struct IntakeEditorTarget: Identifiable, Hashable {
    let kindID: String
    var id: String { kindID }
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
    .sectionDrawerPresentation(shortInDemo: Self.shortDrawerSections.contains(dest.rawValue))
  }

  /// Sections whose drawer content is short enough that a full-height demo
  /// capture would be mostly empty — keep them at the medium detent.
  private static let shortDrawerSections: Set<String> = [
    "gut", "nutrition", "mood", "supplements", "habits",
  ]

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
    await PerfTrace.span("dash.loadAll") {
      let snap = await PerfTrace.span("dash.reader.read") {
        await reader.read(Self.mirrorSections,
                          today: clock.today,
                          days: Self.historyDays)
      }
      apply(snap, Self.mirrorSections)
      await PerfTrace.span("dash.refreshTasks") { await refreshTasks() }
      await PerfTrace.span("dash.dailies.load") {
        await dailies.load(today: clock.today, now: clock.now)
      }
      loadMenuExtras()
    }
    #if os(iOS)
    scheduleTileWidgetPublication()
    #endif

    // Network-backed tiles load on their own hop so a slow or variable
    // provider (Oura / Withings / GitHub / HealthKit) never gates the rest
    // of the dashboard. `paintFromCache()` already showed last-known values;
    // each tile reconciles when its provider lands. Coalesced via the guard
    // in `loadNetwork` so a rapid initial-load + day-change can't double the
    // in-flight HTTP past the safe cap.
    Task { await loadNetwork() }
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
    #if os(iOS)
    scheduleTileWidgetPublication()
    #endif
  }

  /// Reload a scoped set of sections and apply. Mirror-backed sections read
  /// off-main via `reader`; tasks read on the main actor (their persistence
  /// layer is `@MainActor`). Every change-driven refresh path funnels here.
  private func refresh(_ sections: Set<DashSection>) async {
    guard !sections.isEmpty else { return }
    let mirror = sections.intersection(Self.mirrorSections)
    if !mirror.isEmpty {
      let snap = await reader.read(mirror,
                                   today: clock.today,
                                   days: Self.historyDays)
      apply(snap, mirror)
    }
    if sections.contains(.tasks) {
      await refreshTasks()
    }
    // The "today" items model mirrors habits/supplements/chores — keep it
    // in step when any of those reloaded.
    if !sections.isDisjoint(with: [.habits, .chores, .supplements]) {
      await dailies.load(today: clock.today, now: clock.now)
    }
  }

  /// Reload the Tasks tile on the main actor. `TaskReads` → `LocalCache` is
  /// `@MainActor`, so unlike the mirror sections this can't go through the
  /// background reader. Scoped to tasks, it's cheap — a single tile, not the
  /// whole dashboard.
  @MainActor
  private func refreshTasks() async {
    let ctx = LocalStore.shared.container.mainContext
    async let statsTask = Task { @MainActor in
      TaskReads.dashboardStats(days: Self.historyDays, today: clock.today,
                               now: clock.now, context: ctx)
    }.value
    async let listTask = TaskReads.list(view: "logbook", days: 1,
                                        today: clock.today, now: clock.now,
                                        context: ctx)
    let (stats, listResult) = await (statsTask, listTask)
    taskCounts = stats.counts
    ResponseCache.save(stats.counts, forKey: CacheKey.taskCounts)
    tasksHistory = stats.history
    ResponseCache.save(stats.history, forKey: CacheKey.tasksHistory)
    completedTasks = listResult.items
    ResponseCache.save(listResult.items, forKey: CacheKey.completedTasks)
    #if os(iOS)
    scheduleTileWidgetPublication()
    #endif
  }

  /// Network-backed tiles (Oura, Withings, GitHub, HealthKit). Kept off the
  /// mirror path and capped at ≤2 concurrent HTTP calls — past ~4 the shared
  /// URLSession path has heap-corrupted at launch, so GitHub stays sequential.
  private func loadNetwork() async {
    // Coalesce overlapping runs (initial-load + day-change can both fire)
    // so concurrent HTTP stays within the safe ≤4-parallel ceiling.
    if networkLoading { return }
    networkLoading = true
    defer { networkLoading = false }
    // Oura + Withings in parallel (HTTP cap ≤2); each is timed independently
    // so the Perf log shows the per-provider latency that adds up to the stall.
    async let ouraTimed = PerfTrace.span("net.oura") {
      try? await OuraProvider.shared.fetchHistory(days: Self.historyDays)
    }
    async let withingsTimed = PerfTrace.span("net.withings") {
      try? await WithingsProvider.shared.fetchHistory(days: Self.historyDays)
    }
    if let o = await ouraTimed {
      ouraNights = o
      ResponseCache.save(o, forKey: CacheKey.ouraNights)
    }
    if let w = await withingsTimed {
      let sorted = w.sorted { $0.date > $1.date }
      bodyRows = sorted
      ResponseCache.save(sorted, forKey: CacheKey.bodyRows)
    }
    if GitHubProvider.shared.hasToken,
       let gh = await PerfTrace.span("net.github", "", {
         try? await GitHubProvider.shared.fetchContributions(days: 365)
       }) {
      githubContributions = gh
      ResponseCache.save(gh, forKey: CacheKey.github)
    }
    await PerfTrace.span("net.healthkit") { await HealthKitBridge.shared.refresh() }
    // Body (Withings) + GitHub inputs just landed — refresh the tile cache.
    recomputeDerived()
    #if os(iOS)
    scheduleTileWidgetPublication()
    #endif
  }

  /// QuickAdd-menu-only data, loaded on its own hop so it never blocks the
  /// tiles' first paint (the menus need it only when opened).
  private func loadMenuExtras() {
    Task {
      let m = await reader.menuExtras(today: clock.today, now: clock.now)
      nutritionHistory = m.nutritionHistory
      trainingSessionTypes = m.trainingSessionTypes
      trainingSuggestedId = m.trainingSuggestedId
      trainingDaysAgo = m.trainingDaysAgo
      // Training effort classification depends on the session-type catalog
      // that just loaded — recompute so the Training tile reflects it.
      recomputeDerived()
      #if os(iOS)
      scheduleTileWidgetPublication()
      #endif
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
    let anchor = SeptenaDate.startOfDay(for: clock.today) ?? clock.now
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: anchor) ?? anchor
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
    // Touch `quickLogStamp` so a Symptoms / Medications tile quick-add (which
    // bumps it) re-evaluates the body and re-fetches those SwiftData-backed
    // series — they aren't in the `.septenaDataChanged` reload path, and now
    // that every mode renders from `visibleDomainData` the dependency has to
    // live here rather than inside a per-section tile.
    let _ = quickLogStamp
    // One shared renderer drives all layout modes; pinned goals are prepended
    // to `visibleDomainData` as first placements in the same grid.
    HomepageTileLayout(
      mode: currentLayoutMode,
      items: visibleDomainData,
      columns: columns,
      onTap: handleDomainTap
    ) { item in
      quickAddMenu(for: item)
    }
    .task(id: pinnedGoals.count) {
      guard !pinnedGoals.isEmpty else { return }
      goalEditSections = SettingsMirror.loadSections(context: modelContext)
        .filter { $0.key != "goals" }
    }
    .sheet(item: $editingGoal) { goal in
      EditGoalSheet(
        goal: goal,
        availableSections: goalEditSections,
        theme: theme,
        mutator: goalMutator,
        onUpdate: { _ in },
        onDelete: { _ in }
      )
    }
  }

  /// Domain data array in canonical order, filtered by server visibility
  /// + dropping any domain whose builder returned `nil` (currently only
  /// Activity-on-Mac when HealthKit is unavailable). Future renderers
  /// (Heatmap, List) consume this same property.
  private var visibleDomainData: [HomepageDomainData] {
    let sectionTiles = visibleDomains.flatMap {
      DashboardTileBuilder.visibleItems(for: $0, ctx: tileContext, theme: theme)
    }
    let pinned = pinnedGoals.map {
      PinnedGoalTiles.domainData($0, theme: theme, context: modelContext,
                                 today: clock.today, now: clock.now)
    }
    return pinned + sectionTiles
  }

  private var tileContext: DashboardTileContext {
    DashboardTileContext(
      modelContext: modelContext,
      clockNow: clock.now,
      clockToday: clock.today,
      dailies: dailies,
      habitHistory: habitHistory,
      choreHistory: choreHistory,
      cardio: cardio,
      trainingSessionDates: trainingSessionDates,
      trainingSessionTypes: trainingSessionTypes,
      supplementHistory: supplementHistory,
      taskCounts: taskCounts,
      tasksHistory: tasksHistory,
      ouraNights: ouraNights,
      nutritionStats: nutritionStats,
      nutritionTrackFasting: nutritionTrackFasting,
      nutritionHeatmapMetricRaw: nutritionHeatmapMetricRaw,
      todayProteinSum: todayProteinSum,
      todayKcalSum: todayKcalSum,
      nutritionTarget: nutritionTarget,
      groceries: groceries,
      bodyRows: bodyRows,
      githubContributions: githubContributions,
      gutToday: gutToday,
      gutHistory: gutHistory,
      moodToday: moodToday,
      moodHistory: moodHistory,
      hydrationToday: hydrationToday,
      hydrationHistory: hydrationHistory,
      hydrationTargetMl: hydrationTargetMl,
      intakeTiles: intakeTiles,
      recentTraining: recentTraining,
      derived: derived
    )
  }

  #if os(iOS)
  private func scheduleTileWidgetPublication() {
    widgetPublishGeneration &+= 1
    let generation = widgetPublishGeneration
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled, generation == widgetPublishGeneration else { return }
      publishTileWidgetCatalog()
    }
  }

  private func publishTileWidgetCatalog() {
    let catalog = DashboardTileBuilder.buildCatalog(
      ctx: tileContext,
      theme: theme,
      visibleDomains: visibleDomains
    )
    let tilesChanged = TileWidgetSnapshotStore.saveIfChanged(catalog)
    let macroSnapshot = visibleDomains.contains(.nutrition)
      ? DashboardTileBuilder.buildMacroSnapshot(ctx: tileContext, theme: theme)
      : nil
    let macrosChanged = MacroWidgetSnapshotStore.saveIfChanged(macroSnapshot)
    let tasksChanged = TasksWidgetSnapshotStore.saveIfChanged(
      TasksWidgetBuilder.buildSnapshot(context: tileContext.modelContext)
    )
    if tilesChanged { WidgetCenter.shared.reloadTimelines(ofKind: "SectionTileWidget") }
    if macrosChanged { WidgetCenter.shared.reloadTimelines(ofKind: "MacrosWidget") }
    if tasksChanged { WidgetCenter.shared.reloadTimelines(ofKind: "TasksTodayWidget") }
  }
  #endif

  @MainActor
  private func recomputeDerived() {
    derived = DashboardTileBuilder.computeDerived(
      recentTraining: recentTraining,
      sessionTypes: trainingSessionTypes,
      github: githubContributions,
      bodyRows: bodyRows,
      now: clock.now)
  }

  func domainData(for domain: HomepageDomain) -> HomepageDomainData? {
    DashboardTileBuilder.domainData(for: domain, ctx: tileContext, theme: theme)
  }

  private func handleWidgetDeepLink(itemID: String) {
    if itemID == HomepageDomain.tasks.rawValue {
      openTasksFromTile()
      return
    }
    if itemID.hasPrefix("intake:") {
      openIntakeKind(String(itemID.dropFirst("intake:".count)))
      return
    }
    if let dest = WeekDestination(rawValue: itemID) {
      open(dest)
    }
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
    case .openGoal(let id):
      if let entity = pinnedGoals.first(where: { $0.id == id }) {
        editingGoal = Goal(entity)
      }
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

  private func unpinGoal(id: String) {
    goalMutator.setPinned(id: id, pinned: false)
    Haptics.tick()
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
    if let goalID = PinnedGoalTiles.goalID(from: item) {
      Button { unpinGoal(id: goalID) } label: {
        Label("Unpin from dashboard", systemImage: "pin.slash")
      }
    } else if item.domain == .intake,
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
    case .symptoms:    symptomsQuickAddMenu
    case .medications: medicationsQuickAddMenu
    case .sleep, .body, .activity, .github, .intake:
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
    AddInfoPalette.visibleDashboardDomains(
      sections: settingsStore.sections,
      mirroredFallback: SettingsMirror.loadSections(context: modelContext)
    )
  }



  @ViewBuilder private var symptomsQuickAddMenu: some View {
    SymptomsQuickAddMenu(
      symptoms: symptomQuickItems(),
      onLog: { id, severity in commitSymptom(symptomID: id, severity: severity) },
      onOpen: { open(.symptoms) }
    )
  }

  /// Recent-first symptoms for the quick-add menu: distinct symptoms logged in
  /// the trailing 30 days (most-recent first), then any remaining active
  /// definitions, capped so the menu stays scannable. Uncurated catalogs can be
  /// long, so recency is the better surface than raw sort order.
  private func symptomQuickItems() -> [SymptomQuickItem] {
    let defs = (try? modelContext.fetch(
      FetchDescriptor<SymptomDefinitionEntity>(
        sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    let active = defs.filter { !$0.archived }
    guard !active.isEmpty else { return [] }
    let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })

    let recent = fetchSymptoms(from: lastNDays(30).first ?? clock.today,
                               to: clock.today)
      .sorted { $0.occurredAt > $1.occurredAt }
    var seen = Set<String>()
    var ordered: [SymptomDefinitionEntity] = []
    for event in recent where seen.insert(event.symptomID).inserted {
      if let def = byID[event.symptomID] { ordered.append(def) }
    }
    for def in active where !seen.contains(def.id) {
      ordered.append(def)
      seen.insert(def.id)
    }
    return ordered.prefix(8).map {
      SymptomQuickItem(id: $0.id, title: symptomTitle($0))
    }
  }

  private func symptomTitle(_ def: SymptomDefinitionEntity) -> String {
    if let emoji = def.emoji, !emoji.isEmpty { return "\(emoji) \(def.title)" }
    return def.title
  }

  private func commitSymptom(symptomID: String, severity: Int) {
    SectionLog.newLog(section: "symptoms", accent: theme.color(for: "symptoms"),
                      announce: "Logged symptom.", logCommit: logCommit) {
      SeptenaServices.shared.symptomsMutator.addEvent(
        symptomID: symptomID,
        date: clock.today,
        time: EventTimestamp.hhmm(from: clock.now),
        severity: severity)
    }
    quickLogStamp += 1
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

  @ViewBuilder private var medicationsQuickAddMenu: some View {
    let active = fetchMedicationDefinitions().contains { !$0.archived }
    MedicationsQuickAddMenu(
      medications: medicationQuickItems(),
      emptyLabel: active ? "Nothing due right now" : "No medications yet",
      onTake: { item in commitMedicationTaken(item) },
      onOpen: { open(.medications) }
    )
  }

  /// Active meds still loggable right now. Daily meds drop once today's taken
  /// count reaches their target and are bucket-gated (anytime all day; a
  /// bucketed med shows once its window arrives). As-needed meds are always
  /// available. Mirrors the Supplements quick-add's "due now" semantics.
  private func medicationQuickItems() -> [MedicationQuickItem] {
    let today = clock.today
    let active = fetchMedicationDefinitions().filter { !$0.archived }
    guard !active.isEmpty else { return [] }
    let todayDoses = fetchMedicationDoses(from: today, to: today)
    var takenByMed: [String: Int] = [:]
    for dose in todayDoses where dose.status == "taken" {
      takenByMed[dose.medicationID, default: 0] += 1
    }
    let nowOrder = DayBucket.current.order
    return active.compactMap { def -> MedicationQuickItem? in
      if (def.scheduleKind ?? "daily") == "daily" {
        let target = max(def.targetDosesPerDay ?? 1, 1)
        if (takenByMed[def.id] ?? 0) >= target { return nil }
        if let raw = def.bucket, let bucket = DayBucket(rawValue: raw),
           bucket.order > nowOrder { return nil }
      }
      return MedicationQuickItem(id: def.id, title: def.title,
                                 detail: medicationDoseSummary(def))
    }
  }

  private func medicationDoseSummary(_ def: MedicationDefinitionEntity) -> String? {
    guard let value = def.defaultDoseValue else { return nil }
    let unit = def.defaultDoseUnit.map { " \($0)" } ?? ""
    return "\(value.decimalString(2))\(unit)"
  }

  private func commitMedicationTaken(_ item: MedicationQuickItem) {
    let def = fetchMedicationDefinitions().first { $0.id == item.id }
    SectionLog.newLog(section: "medications", accent: theme.color(for: "medications"),
                      announce: "Logged medication dose.", logCommit: logCommit) {
      SeptenaServices.shared.medicationsMutator.addDose(
        medicationID: item.id,
        date: clock.today,
        time: EventTimestamp.hhmm(from: clock.now),
        status: "taken",
        doseValue: def?.defaultDoseValue,
        doseUnit: def?.defaultDoseUnit)
    }
    quickLogStamp += 1
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


  /// Setting that decides whether tapping the Tasks tile drops a Today
  /// drawer (sheet) or jumps to the full Tasks tab. Default `drawer` so
  /// Tasks behaves like every other section tile.
  @AppStorage(SettingsKey.tasksOpenIn)
  private var tasksOpenInRaw: String = TasksOpenMode.drawer.rawValue

  /// Today's open tasks read straight from SwiftData (no network hop) —
  /// LocalCache mirrors the server's view=today filter, so this matches
  /// what the Tasks tab shows when you navigate in.
  private var todayOpenTasks: [SeptenaTask] {
    let resp = TaskReads.localList(
      view: "today", area: nil, project: nil, days: 1,
      today: clock.today, now: clock.now,
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

  @ViewBuilder private var habitsQuickAddMenu: some View {
    HabitsQuickAddMenu(
      habits: dailies.habits,
      buckets: dailies.habitBuckets,
      onComplete: { item in commitHabitToggle(item) },
      onOpen: { open(.habits) }
    )
  }


  private func commitHabitToggle(_ item: HabitDayItem) {
    dailies.toggleHabit(item, mutator: checklistMutator, motion: motion)
    AddInfoSection.habits.notifyTilesChanged()
    Haptics.tick()
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

  /// Last N ISO yyyy-MM-dd dates, oldest → newest. Used by the symptoms /
  /// medications / activity history helpers and `trainingDomainData`
  /// (90 days for the Heatmap mode).
  private func lastNDays(_ n: Int) -> [String] {
    let cal = Calendar.current
    let fmt = Self.ymdFormatter
    let anchor = SeptenaDate.startOfDay(for: clock.today) ?? clock.now
    return (0..<n).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: anchor).map(fmt.string(from:))
    }
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
      onComplete: { chore in commitChoreComplete(chore) },
      onOpen: { open(.chores) }
    )
  }

  private func commitChoreComplete(_ chore: ChoreItem) {
    dailies.completeChore(chore, mutator: checklistMutator, motion: motion)
    AddInfoSection.chores.notifyTilesChanged()
    Haptics.tick()
  }

  @ViewBuilder private var supplementsQuickAddMenu: some View {
    SupplementsQuickAddMenu(
      supplements: dailies.supplements,
      onToggle: { item in commitSupplementToggle(item) },
      onOpen: { open(.supplements) }
    )
  }

  private func commitSupplementToggle(_ item: SupplementDayItem) {
    dailies.toggleSupplement(item, mutator: checklistMutator, motion: motion)
    AddInfoSection.supplements.notifyTilesChanged()
    Haptics.tick()
  }

  @ViewBuilder private var groceriesQuickAddMenu: some View {
    GroceriesQuickAddMenu(
      items: groceries,
      onMarkLow: { item in commitGroceryMarkLow(item) },
      onOpen: { open(.groceries) }
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

  // MARK: - Intake (consumables) tiles
  //
  // One host section, one tile per kind (Option C). `tile(for: .intake)`
  // returns N tiles (the grid flattens the nested ForEach), so no change to
  // the `tiles` loop. Tapping opens the kind switcher; each kind page owns its
  // container-aware quick-add. Non-Tiles layout modes show one aggregate row
  // via `intakeDomainData()`. See docs/CONSUMABLES_PLAN.md.

  /// Long-press quick-add for a tracker tile — the same container-aware
  /// choices its kind page builds (Continue (Hit N) / New capsule / methods),
  /// logging directly like the caffeine tile menu does.
  @ViewBuilder
  private func intakeQuickAddMenu(for t: IntakeTileDTO) -> some View {
    let methods = t.methods.map {
      ConsumableContainer.Method(token: $0.token, label: $0.label,
                                 emoji: $0.emoji, usesContainer: $0.usesContainer)
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
        if let e = choice.emoji, !e.isEmpty {
          Label { Text("Log \(choice.label)") } icon: { Text(e) }
        } else {
          Label("Log \(choice.label)", systemImage: choice.symbol ?? "plus.circle")
        }
      }
    }
    Divider()
    Button {
      intakeEditorKind = IntakeEditorTarget(kindID: t.id)
    } label: {
      Label("New entry…", systemImage: "square.and.pencil")
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

  private func reloadIntake() async {
    let date = clock.today
    intakeTiles = await MirrorReader.shared.read { IntakeReader.loadTiles(context: $0, date: date) }
    #if os(iOS)
    scheduleTileWidgetPublication()
    #endif
  }

  // Bristol scale is a fixed 7-item enum — one tap logs a complete movement.
  // The trailing "Gut…" row opens the section, where the full editor (volume,
  // note, back-dated time) lives. Matches AddGutPage's commit semantics.
  @ViewBuilder private var gutQuickAddMenu: some View {
    GutQuickAddMenu(
      recentBristolTypes: GutBristolRecorder.recentTypes,
      onCommit: { bristol in commitGut(bristol: bristol) },
      onOpen: { open(.gut) }
    )
  }

  private func commitGut(bristol: Int) {
    SectionLog.newLog(section: "gut", accent: theme.color(for: "gut"),
                      logCommit: logCommit) {
      SeptenaServices.shared.gutMutator.addEntry(
        date: clock.today, time: EventTimestamp.hhmm(from: clock.now), bristol: bristol)
      GutBristolRecorder.record(bristol)
      AddInfoSection.gut.notifyTilesChanged()
    }
  }

  // Settings is reached from the sidebar (and ⌘, on macOS) — it's an
  // app-level surface, not a Week tile, and not on this toolbar.

  // The 30-day actual-weigh-in series (no carry-forward) is precomputed in
  // `computeDerived` off the render path and read via `derived.weightActual30`.

  @ViewBuilder private var nutritionQuickAddMenu: some View {
    NutritionQuickAddMenu(
      recommendations: NutritionRecommendations.topRecommended(
        from: nutritionHistory, now: clock.now, limit: 3),
      onSearch: { nutritionSheet = .search },
      onScan: { nutritionSheet = .scan },
      onInput: { nutritionSheet = .newEntry },
      onCommit: { meal in commitNutritionDuplicate(meal) }
    )
  }

  /// Duplicate a meal at the current time via NutritionMutator.
  private func commitNutritionDuplicate(_ entry: NutritionEntry) {
    NutritionCommit.commitMeal(
      loggedAt: .now,
      today: clock.today,
      accent: theme.color(for: "nutrition"),
      announce: "Logged \(entry.foods.first ?? "meal").",
      logCommit: logCommit
    ) {
      NutritionRelogging.addDuplicate(entry)
      AddInfoSection.nutrition.notifyTilesChanged()
    }
  }

  // MARK: - Mood

  @ViewBuilder private var moodQuickAddMenu: some View {
    MoodQuickAddMenu(onLog: { commitMood($0) },
                     onCheckIn: { nav.showMoodCheckin = true })
  }

  private func commitMood(_ emotion: MoodEmotion) {
    SeptenaServices.shared.moodMutator.logEntry(
      date: clock.today,
      time: EventTimestamp.hhmm(from: clock.now),
      quadrant: emotion.quadrant.rawValue,
      arousal: emotion.arousal,
      valence: emotion.valence,
      emotion: emotion.word)
    Haptics.success()
    // A tile quick-log now celebrates like a sheet check-in: fire the same
    // affect-matched, wordless flourish AddMoodPage plays (motion chosen by
    // the logged quadrant, accent = quadrant color). Fired at the app root;
    // the overlay honors Reduce Motion + the logging-animations opt-out.
    logCommit?.fire(.flourish(motion: emotion.quadrant.commitMotion,
                              accent: emotion.quadrant.color, intensity: 1))
    Task { await refreshMood() }
  }


  /// Reload mood state after an in-app commit (the AddMoodPage sheet on
  /// the dashboard tile). Mirrors the `refresh(section:)` pattern that
  /// other domains use via tilesDidChange notifications — Mood doesn't
  /// route through AddInfoSection so it refreshes itself.
  private func refreshMood() async {
    await refresh([.mood])
  }

  // MARK: - Hydration

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
    Divider()
    // Custom amounts + target live in the section's "Quick add" card.
    Button { open(.hydration) } label: {
      Label("Hydration…", systemImage: "ellipsis")
    }
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
        canvas: true,
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
