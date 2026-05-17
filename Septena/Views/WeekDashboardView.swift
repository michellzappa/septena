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
        VStack(alignment: .leading, spacing: 20) {
          header
          tiles
          comingSoon
        }
        .padding(.horizontal)
        .padding(.top)
        .padding(.bottom, 80)
      }
      .navigationBarHidden(true)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Week")
        .font(.largeTitle.bold())
      Text("Last 7 days · your shape across modules")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var tiles: some View {
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)],
              spacing: 12) {
      ModuleTile(title: "Tasks",    snapshot: "5 today · 2 late",
                 accent: .blue,    history: [3, 5, 2, 7, 4, 6, 5])
      ModuleTile(title: "Habits",   snapshot: "4 of 6 done",
                 accent: .green,   history: [6, 6, 5, 6, 4, 6, 4])
      ModuleTile(title: "Training", snapshot: "Legs · 45 min",
                 accent: .orange,  history: [0, 1, 0, 1, 0, 0, 1])
      ModuleTile(title: "Chores",   snapshot: "2 due today",
                 accent: .purple,  history: [2, 1, 3, 2, 1, 2, 4])
      ModuleTile(title: "Sleep",    snapshot: "7h 12m avg",
                 accent: .indigo,  history: [7, 6, 8, 7, 7, 8, 6])
      ModuleTile(title: "Nutrition", snapshot: "2,100 kcal · 130g P",
                 accent: .pink,    history: [3, 2, 3, 3, 4, 2, 3])
    }
  }

  private var comingSoon: some View {
    Text("Per-day timeline rows land in Phase 2 — for now, tiles are mock data and inert.")
      .font(.footnote)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.top, 8)
  }
}
