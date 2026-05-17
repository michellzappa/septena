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
    let (h, c, ca, e, s) = await (hh, ch, car, ents, sh)
    if let h { habitHistory = h.daily.map { $0.done } }
    if let c { choreHistory = c.daily.map { $0.completed } }
    cardio = ca
    if let e { trainingSessionDates = Set(e.map(\.date)) }
    if let s { supplementHistory = s.daily.map { $0.done } }
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
  }

  private var tasksTile: some View {
    ModuleTile(
      title: "Tasks",
      accent: theme.color(for: "tasks"),
      stats: [.init(label: "Today",   value: "5"),
              .init(label: "Late",    value: "2"),
              .init(label: "Inbox",   value: "11")],
      progress: .init(label: "Week complete", current: 18, target: 28),
      history: .init(label: "7-day completions", values: [3, 5, 2, 7, 4, 6, 5])
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

  private var sleepTile: some View {
    ModuleTile(
      title: "Sleep",
      accent: theme.color(for: "sleep"),
      stats: [.init(label: "Last night", value: "7:12", unit: "h"),
              .init(label: "Avg",        value: "7:08", unit: "h")],
      progress: .init(label: "Target", current: 7.2, target: 8, unit: "h"),
      history: .init(label: "7-day hours", values: [7, 6, 8, 7, 7, 8, 6])
    )
  }

  private var nutritionTile: some View {
    ModuleTile(
      title: "Nutrition",
      accent: theme.color(for: "nutrition"),
      stats: [.init(label: "Protein", value: "50", unit: "g"),
              .init(label: "Kcal",    value: "855")],
      progress: .init(label: "Today's protein", current: 50, target: 150, unit: "g"),
      history: .init(label: "7-day protein", values: [120, 130, 140, 160, 80, 145, 60])
    )
  }
}
