import SwiftUI

struct WeekTasksTile: View {
  let accent: Color
  let openToday: Int
  let toSort: Int
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
        .init(label: "Inbox", value: "\(toSort)"),
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

struct WeekHabitsTile: View {
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

struct WeekTrainingTile: View {
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

struct WeekChoresTile: View {
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

struct WeekSupplementsTile: View {
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

struct WeekSleepTile: View {
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

struct WeekGroceriesTile: View {
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
