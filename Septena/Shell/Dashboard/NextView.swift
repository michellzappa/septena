import SwiftUI

// Dedicated screen for the daily "next" strip: chores, habits, supplements.
// Pulled out of Today so Today stays focused on tasks (mirrors the web app).

struct NextView: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock

  @State private var model = NextItemsModel()
  @State private var tasksModel = TodayTasksModel()
  @State private var suggestionsModel = NextSuggestionsModel()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        // Title removed — the tab bar already labels this view.

        if model.hasLoaded && !model.hasAnyOpen
            && tasksModel.openTasks.isEmpty
            && suggestionsModel.suggestions.isEmpty {
          Text("Nothing here yet")
            .font(.septenaMeta)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 40)
        }

        NextSuggestionsSection(model: suggestionsModel)

        TodayTasksSection(model: tasksModel)

        NextOpenSection(model: model)

        // Completed chores/habits/supplements fade out in place after the
        // settle beat (no "Done" strip to slide down into) — same vanish
        // behaviour as today's tasks above.

        Spacer(minLength: 140)
      }
    }
    .background(Theme.paperBackground)
    .septenaInlineTitle()
    .task {
      model.paintFromCache()
      tasksModel.paintFromCache()
      suggestionsModel.paintFromCache()
      async let a: () = model.load()
      async let b: () = tasksModel.load()
      async let c: () = suggestionsModel.load()
      _ = await (a, b, c)
    }
    .refreshable {
      async let a: () = model.load()
      async let b: () = tasksModel.load()
      async let c: () = suggestionsModel.load()
      _ = await (a, b, c)
    }
    // Repaint when other surfaces (Tasks tab, menu bar, outbox drain)
    // mutate tasks so the Next checklist stays in sync.
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      tasksModel.refreshFromCache()
    }
    // Day rollover (midnight crossed while the app was alive, or session
    // resumed after midnight): refetch so habits/supplements/chores reflect
    // the new day's bucket and completion state.
    .onChange(of: clock.today) { _, _ in
      Task {
        async let a: () = model.load()
        async let b: () = tasksModel.load()
        async let c: () = suggestionsModel.load()
        _ = await (a, b, c)
      }
    }
  }
}
