import SwiftUI

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
  @State private var todayNutrition: NutritionEntry? = nil
  @State private var todayProteinSum: Double = 0
  @State private var todayKcalSum: Double = 0
  @State private var nutritionTarget: MacrosConfig? = nil
  @State private var airSummary: AirSummary? = nil
  @State private var airHistory: [AirHistoryPoint] = []
  @State private var groceries: [GroceryItem] = []

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
        LazyVGrid(columns: columns, spacing: 14) {
          tiles
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 80)
      }
      .background(Color(.systemGroupedBackground))
      // Tab bar already labels this view; no large title needed.
      .toolbar(.hidden, for: .navigationBar)
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
  }

  private func sinceDate(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
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
  }

  // Tasks — live counts from /api/tasks/counts. No history endpoint yet
  // (would need /api/tasks/history) so the histogram stays mocked.
  private var tasksTile: some View {
    let today = taskCounts.map { $0.todayCount + $0.reviewCount } ?? 0
    let inbox = taskCounts?.inboxCount ?? 0
    let upcoming = taskCounts?.upcomingCount ?? 0
    return ModuleTile(
      title: "Tasks",
      accent: theme.color(for: "tasks"),
      stats: [.init(label: "Today",    value: "\(today)"),
              .init(label: "Inbox",    value: "\(inbox)"),
              .init(label: "Upcoming", value: "\(upcoming)")],
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
    let accent = theme.color(for: "chores")
    return NavigationLink(value: WeekDestination.chores) {
      ModuleTile(
        title: "Chores",
        accent: accent,
        stats: [
          .init(label: "Due today", value: "\(dueToday)"),
          .init(label: "Overdue",   value: "\(overdue)")
        ],
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
    return NavigationLink(value: WeekDestination.air) {
      ModuleTile(
        title: "Air",
        accent: accent,
        stats: [
          .init(label: "CO2", value: latest.map { "\($0)" } ?? "—", unit: "ppm"),
          .init(label: "Over 1000", value: "\(todayOver)", unit: "m")
        ],
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
