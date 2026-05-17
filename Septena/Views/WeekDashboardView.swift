import SwiftUI
import EventKit

// Week module — the synthesizing dashboard. Each module gets a tile that
// (a) renders live stats / histogram for that module and (b) pushes into
// the module's full destination on tap. Tiles for modules that don't yet
// have a Swift mini-app stay mocked + inert until those are built — but
// every accent comes from SectionTheme so colors match the user's
// server-configured Septena palette today.

enum WeekDestination: Hashable {
  case habits
  case chores
  case training
  case supplements
  case sleep
  case nutrition
  case air
  case groceries
  case calendar
  case caffeine
  case cannabis
  case body
  case gut
  case settings
  case activity
}

struct WeekDashboardView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
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
  @State private var ouraNights: [OuraNight] = []
  @State private var nutritionStats: NutritionStatsResponse? = nil
  @State private var todayProteinSum: Double = 0
  @State private var todayKcalSum: Double = 0
  @State private var nutritionTarget: MacrosConfig? = nil
  @State private var airSummary: AirSummary? = nil
  @State private var airHistory: [AirHistoryPoint] = []
  @State private var groceries: [GroceryItem] = []
  @State private var calendarEvents: [EKEvent] = []
  @State private var caffeineToday: CaffeineDayResponse? = nil
  @State private var caffeineHistory: [CaffeineHistoryPoint] = []
  @State private var cannabisToday: CannabisDayResponse? = nil
  @State private var cannabisHistory: [CannabisHistoryPoint] = []
  @State private var bodyRows: [WithingsRow] = []
  @State private var gutToday: GutDayResponse? = nil
  @State private var gutHistory: [GutHistoryPoint] = []
  @State private var settings: AppSettings? = nil
  /// Today-scoped collections kept in state so DayTimelineView can read
  /// them. NextItemsModel already covers habits/supplements/chores and
  /// today's caffeine/cannabis/gut live in their respective `*Today`
  /// state vars; only nutrition + recent training need fresh stash.
  @State private var todayNutrition: [NutritionEntry] = []
  @State private var recentTraining: [ExerciseEntry] = []

  /// 1 column on iPhone (compact), 3 on iPad / Mac (regular). LazyVGrid
  /// reflows automatically on rotation; tiles keep their internal layout.
  private var columns: [GridItem] {
    let count: Int
    #if os(iOS)
    count = (hSize == .regular) ? 3 : 1
    #else
    count = 3
    #endif
    return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
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
      .background(Color(.systemGroupedBackground))
      // Tab bar already labels this view; keep the nav bar present with
      // an empty inline title so iOS still renders the scroll-edge blur
      // (content fades to bg material as it scrolls under the top).
      .navigationTitle("")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarBackground(.regularMaterial, for: .navigationBar)
      #endif
      .navigationDestination(for: WeekDestination.self) { dest in
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
        case .settings:    SettingsDestinationView()
        case .activity:    ActivityDestinationView()
        }
      }
      .task { await loadAll() }
      .refreshable { await loadAll() }
    }
  }

  /// Fan out the per-tile fetches in parallel. NextItemsModel covers today's
  /// habits / chores / supplements (used by every "today" stat on the page);
  /// the two history endpoints provide the 7-day histograms.
  private func loadAll() async {
    async let _ = dailies.load(client: client)
    async let hh = try? await client.habitsHistory(days: 7)
    async let ch = try? await client.choresHistory(days: 7)
    async let car = try? await client.trainingCardioHistory(days: 7)
    async let ents = try? await client.trainingEntries(since: sinceDate(daysBack: 7))
    async let sh = try? await client.supplementsHistory(days: 7)
    async let tc = try? await client.counts()
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
    airSummary = asRes
    airHistory = ahRes?.daily ?? []
    if let g = gRes { groceries = g }
    // Local-only — CalendarBridge sync; no network. Drains permission +
    // returns whatever's currently in the user's calendars.
    calendarEvents = CalendarBridge.shared.upcomingEvents(days: 7)
    if let h { habitHistory = h.daily.map { $0.done } }
    if let c { choreHistory = c.daily.map { $0.completed } }
    cardio = ca
    if let e { trainingSessionDates = Set(e.map(\.date)) }
    if let s { supplementHistory = s.daily.map { $0.done } }
    taskCounts = t
    if let o { ouraNights = o }
    nutritionStats = ns
    nutritionTarget = nt
    let today = SeptenaDate.today
    let todayEntries = (ne ?? []).filter { $0.date == today }
    todayProteinSum = todayEntries.reduce(0) { $0 + $1.proteinG }
    todayKcalSum    = todayEntries.reduce(0) { $0 + $1.kcal }
    todayNutrition = todayEntries
    recentTraining = e ?? []
    // Caffeine + Cannabis — second wave so the heavier core fetches above
    // render their tiles first.
    async let cafToday = try? await client.caffeineDay(date: SeptenaDate.today)
    async let cafHist  = try? await client.caffeineHistory(days: 7)
    async let cnbToday = try? await client.cannabisDay(date: SeptenaDate.today)
    async let cnbHist  = try? await client.cannabisHistory(days: 7)
    let (cafT, cafH, cnbT, cnbH) = await (cafToday, cafHist, cnbToday, cnbHist)
    caffeineToday = cafT
    caffeineHistory = cafH?.daily ?? []
    cannabisToday = cnbT
    cannabisHistory = cnbH?.daily ?? []
    async let wRows = try? await client.withingsHistory(days: 14)
    async let gutT  = try? await client.gutDay(date: SeptenaDate.today)
    async let gutH  = try? await client.gutHistory(days: 7)
    async let cfg  = try? await client.settings()
    let (wR, gT, gH, cfgRes) = await (wRows, gutT, gutH, cfg)
    bodyRows = wR ?? []
    gutToday = gT
    gutHistory = gH?.daily ?? []
    settings = cfgRes
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
      training: recentTraining
    )
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        .fill(Color(.secondarySystemGroupedBackground))
    )
  }

  // MARK: - Tiles

  @ViewBuilder
  private var tiles: some View {
    tasksTile
    habitsTile
    trainingTile
    choresTile
    supplementsTile
    sleepTile
    nutritionTile
    airTile
    groceriesTile
    calendarTile
    caffeineTile
    cannabisTile
    bodyTile
    gutTile
    activityTile
    settingsTile
  }

  // Tasks — live counts from /api/tasks/counts. No history endpoint yet
  // (would need /api/tasks/history) so the histogram stays mocked.
  private var tasksTile: some View {
    let today = taskCounts.map { $0.todayCount + $0.reviewCount } ?? 0
    let inbox = taskCounts?.inboxCount ?? 0
    let upcoming = taskCounts?.upcomingCount ?? 0
    let open = taskCounts?.openCount ?? 0
    return ModuleTile(
      title: "Tasks",
      accent: theme.color(for: "tasks"),
      stats: [.init(label: "Today",    value: "\(today)"),
              .init(label: "Inbox",    value: "\(inbox)"),
              .init(label: "Upcoming", value: "\(upcoming)")],
      // Today's share of the open backlog — gives a sense of immediate
      // load against everything still queued. Defaults to a full bar
      // when open is unknown, so the empty state doesn't read as 0%.
      progress: .init(label: "Today / open",
                      current: Double(today),
                      target: Double(max(open, today, 1))),
      history: .init(label: "7-day completions",
                     values: Array(repeating: max(today, 1), count: 7))
    )
  }

  private var habitsTile: some View {
    let total = dailies.habits.count
    let done = dailies.habits.filter { $0.done }.count
    let skipped = dailies.habits.filter { $0.skipped }.count
    let accent = theme.color(for: "habits")
    return NavigationLink(value: WeekDestination.habits) {
      ModuleTile(
        title: "Habits",
        accent: accent,
        stats: [
          .init(label: "Today",   value: "\(done)/\(max(total, 0))"),
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
    return NavigationLink(value: WeekDestination.training) {
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
    let dueToday = dailies.chores.filter { $0.daysOverdue == 0 }.count
    let overdue  = dailies.chores.filter { $0.daysOverdue > 0 }.count
    let done = dailies.completedChores.count
    let total = dueToday + overdue + done
    let accent = theme.color(for: "chores")
    return NavigationLink(value: WeekDestination.chores) {
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
    return NavigationLink(value: WeekDestination.supplements) {
      ModuleTile(
        title: "Supplements",
        accent: accent,
        stats: [.init(label: "Today", value: "\(done)/\(max(total, 0))")],
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
    let bars = ouraNights.reversed().map { Int(($0.totalH ?? 0) * 10) } // tenths-of-hour for resolution
    return NavigationLink(value: WeekDestination.sleep) {
      ModuleTile(
        title: "Sleep",
        accent: accent,
        stats: [
          .init(label: "Last night", value: formatHoursShort(lastH), unit: "h"),
          .init(label: "Score",      value: score)
        ],
        progress: .init(label: "Target", current: lastH, target: 8, unit: "h"),
        history: .init(label: "7-day hours",
                       values: bars.isEmpty
                         ? Array(repeating: 0, count: 7) : bars)
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
    return NavigationLink(value: WeekDestination.air) {
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
    return NavigationLink(value: WeekDestination.groceries) {
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

  // Calendar — local EventKit feed; no FastAPI involved. Stats: today's
  // event count + next event title. Histogram shows events per upcoming
  // day so the shape of the week is visible at a glance.
  private var calendarTile: some View {
    let accent = theme.color(for: "calendar")
    let cal = Calendar.current
    let todayCount = calendarEvents.filter { cal.isDateInToday($0.startDate) }.count
    let next = calendarEvents.first { $0.endDate > Date() }
    let nextLabel = next.map { e in
      let f = DateFormatter(); f.dateFormat = "HH:mm"
      let title = (e.title?.isEmpty == false ? e.title! : "(Untitled)")
      return "\(title) · \(f.string(from: e.startDate))"
    } ?? "Nothing scheduled"
    var bars: [Int] = Array(repeating: 0, count: 7)
    for e in calendarEvents {
      let days = cal.dateComponents([.day],
                                    from: cal.startOfDay(for: Date()),
                                    to: cal.startOfDay(for: e.startDate)).day ?? 0
      if (0..<7).contains(days) { bars[days] += 1 }
    }
    // Soft cap of 8 events/day reads as a "busy day" budget.
    return NavigationLink(value: WeekDestination.calendar) {
      ModuleTile(
        title: "Calendar",
        accent: accent,
        stats: [.init(label: "Today", value: "\(todayCount)"),
                .init(label: "Next",  value: nextLabel)],
        progress: .init(label: "Today's load",
                        current: Double(min(todayCount, 8)),
                        target: 8),
        history: .init(label: "Next 7 days", values: bars)
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
    return NavigationLink(value: WeekDestination.caffeine) {
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
    return NavigationLink(value: WeekDestination.cannabis) {
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
  private var bodyTile: some View {
    let accent = theme.color(for: "body")
    let latest = bodyRows.first
    let weight = latest?.weightKg
    let fat    = latest?.fatPct
    // Server returns newest-first; reverse for chronological bars.
    // Subtract a floor (min of the series) so the histogram emphasizes
    // change rather than absolute mass.
    let reversed = bodyRows.reversed().compactMap { $0.weightKg }
    let floor = reversed.min() ?? 0
    let bars = reversed.map { Int((($0 - floor) * 10).rounded()) }
    // Body-fat percentage tracked against a soft 18% target (single number,
    // overrideable later via Settings.targets.fat_min_pct).
    let fatTarget: Double = 18
    return NavigationLink(value: WeekDestination.body) {
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
        history: .init(label: "Trend (last \(bars.count))",
                       values: bars.isEmpty
                         ? Array(repeating: 0, count: 7) : bars)
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
    return NavigationLink(value: WeekDestination.gut) {
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
      NavigationLink(value: WeekDestination.activity) {
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

  // Settings — single-stat tile that bears the section accent and
  // confirms the iOS app loaded the server config. Histogram is purely
  // decorative (number of configured targets per category).
  private var settingsTile: some View {
    let accent = theme.color(for: "settings")
    let loaded = settings != nil
    let count = settings?.sectionOrder?.count ?? 0
    let theme_ = settings?.theme?.capitalized ?? "—"
    return NavigationLink(value: WeekDestination.settings) {
      ModuleTile(
        title: "Settings",
        accent: accent,
        stats: [
          .init(label: "Sections", value: "\(count)"),
          .init(label: "Theme",    value: theme_)
        ],
        progress: .init(label: "Config loaded",
                        current: loaded ? 1 : 0,
                        target: 1),
        history: .init(label: "Status",
                       values: Array(repeating: loaded ? 1 : 0, count: 7))
      )
    }
    .buttonStyle(.plain)
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
    return NavigationLink(value: WeekDestination.nutrition) {
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
