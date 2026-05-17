import SwiftUI

// Week module — the synthesizing dashboard. Each module gets a tile that
// (a) renders live stats / histogram for that module and (b) pushes into
// the module's full destination on tap. Tiles for modules that don't yet
// have a Swift mini-app stay mocked + inert until those are built.

enum WeekDestination: Hashable {
  case habits
}

struct WeekDashboardView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var habits = NextItemsModel()

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 14) {
          tiles
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 80)
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Week")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.large)
      #endif
      .navigationDestination(for: WeekDestination.self) { dest in
        switch dest {
        case .habits: HabitsDestinationView()
        }
      }
      .task { await habits.load(client: client) }
      .refreshable { await habits.load(client: client) }
    }
  }

  // MARK: - Tiles

  @ViewBuilder
  private var tiles: some View {
    tasksTile
    habitsTile
    trainingTile
    choresTile
    sleepTile
    nutritionTile
  }

  // Tasks — real backend not wired yet; counts plumbed in next phase.
  private var tasksTile: some View {
    ModuleTile(
      title: "Tasks",
      accent: .blue,
      stats: [.init(label: "Today",   value: "5"),
              .init(label: "Late",    value: "2"),
              .init(label: "Inbox",   value: "11")],
      progress: .init(label: "Week complete", current: 18, target: 28),
      history: .init(label: "7-day completions", values: [3, 5, 2, 7, 4, 6, 5])
    )
  }

  // Habits — real data from NextItemsModel.habits (today only). 7-day
  // history is a placeholder until the client gains /api/habits/history.
  private var habitsTile: some View {
    let total = habits.habits.count
    let done = habits.habits.filter { $0.done }.count
    let skipped = habits.habits.filter { $0.skipped }.count
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
        history: .init(label: "7-day adherence",
                       values: Array(repeating: max(done, 1), count: 7))
      )
    }
    .buttonStyle(.plain)
  }

  private var trainingTile: some View {
    ModuleTile(
      title: "Training",
      accent: .orange,
      stats: [.init(label: "Sessions", value: "5/7"),
              .init(label: "Z2 min",   value: "115", unit: "m")],
      progress: .init(label: "Z2 cardio", current: 115, target: 150, unit: "m"),
      history: .init(label: "7-day effort", values: [0, 45, 0, 30, 0, 0, 40])
    )
  }

  private var choresTile: some View {
    ModuleTile(
      title: "Chores",
      accent: .purple,
      stats: [.init(label: "Due today", value: "2"),
              .init(label: "Overdue",   value: "0")],
      history: .init(label: "7-day done", values: [2, 1, 3, 2, 1, 2, 4])
    )
  }

  private var sleepTile: some View {
    ModuleTile(
      title: "Sleep",
      accent: .indigo,
      stats: [.init(label: "Last night", value: "7:12", unit: "h"),
              .init(label: "Avg",        value: "7:08", unit: "h")],
      progress: .init(label: "Target", current: 7.2, target: 8, unit: "h"),
      history: .init(label: "7-day hours", values: [7, 6, 8, 7, 7, 8, 6])
    )
  }

  private var nutritionTile: some View {
    ModuleTile(
      title: "Nutrition",
      accent: .pink,
      stats: [.init(label: "Protein", value: "50", unit: "g"),
              .init(label: "Kcal",    value: "855")],
      progress: .init(label: "Today's protein", current: 50, target: 150, unit: "g"),
      history: .init(label: "7-day protein", values: [120, 130, 140, 160, 80, 145, 60])
    )
  }
}
