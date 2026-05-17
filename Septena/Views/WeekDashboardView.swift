import SwiftUI

// Week module — the synthesizing 7-day lens. v1 shows a grid of module
// tiles (mocked data) above where the per-day timeline rows will live.
// Tiles eventually deep-link into their module's full destination; for
// now they're inert. Mirrors septena-app's `WeekDashboard` in spirit:
// a single scroll that orients the user across everything.

struct WeekDashboardView: View {
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
      // Gray canvas, white tiles — matches the insetGrouped pattern that
      // Reminders / Settings use, and keeps Week consistent with the
      // standard iOS section-list look the Tasks tab will adopt.
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Week")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.large)
      #endif
    }
  }

  private var tiles: some View {
    VStack(spacing: 14) {
      ModuleTile(
        title: "Tasks",
        accent: .blue,
        stats: [.init(label: "Today",   value: "5"),
                .init(label: "Late",    value: "2"),
                .init(label: "Inbox",   value: "11")],
        progress: .init(label: "Week complete", current: 18, target: 28),
        history: .init(label: "7-day completions", values: [3, 5, 2, 7, 4, 6, 5]),
        action: .init(systemImage: "plus") {}
      )
      ModuleTile(
        title: "Habits",
        accent: .green,
        stats: [.init(label: "Today",   value: "4/6"),
                .init(label: "Streak",  value: "12", unit: "d")],
        progress: .init(label: "Today", current: 4, target: 6),
        history: .init(label: "7-day adherence", values: [6, 6, 5, 6, 4, 6, 4]),
        action: .init(systemImage: "checkmark") {}
      )
      ModuleTile(
        title: "Training",
        accent: .orange,
        stats: [.init(label: "Sessions", value: "5/7"),
                .init(label: "Z2 min",   value: "115", unit: "m")],
        progress: .init(label: "Z2 cardio", current: 115, target: 150, unit: "m"),
        history: .init(label: "7-day effort", values: [0, 45, 0, 30, 0, 0, 40]),
        action: .init(systemImage: "play.fill") {}
      )
      ModuleTile(
        title: "Chores",
        accent: .purple,
        stats: [.init(label: "Due today", value: "2"),
                .init(label: "Overdue",   value: "0")],
        history: .init(label: "7-day done", values: [2, 1, 3, 2, 1, 2, 4]),
        action: .init(systemImage: "checkmark") {}
      )
      ModuleTile(
        title: "Sleep",
        accent: .indigo,
        stats: [.init(label: "Last night", value: "7:12", unit: "h"),
                .init(label: "Avg",        value: "7:08", unit: "h")],
        progress: .init(label: "Target", current: 7.2, target: 8, unit: "h"),
        history: .init(label: "7-day hours", values: [7, 6, 8, 7, 7, 8, 6])
      )
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
}
