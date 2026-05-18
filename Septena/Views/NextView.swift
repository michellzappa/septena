import SwiftUI

// Dedicated screen for the daily "next" strip: chores, habits, supplements.
// Pulled out of Today so Today stays focused on tasks (mirrors the web app).

struct NextView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock

  @State private var model = NextItemsModel()
  @State private var tasksModel = TodayTasksModel()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        // Title removed — the tab bar already labels this view.

        if model.hasLoaded && !model.hasAnyOpen && !model.hasAnyDone
            && tasksModel.openTasks.isEmpty {
          Text("Nothing here yet")
            .font(.septenaMeta)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 40)
        }

        TodayTasksSection(model: tasksModel)

        NextOpenSection(model: model)

        if model.hasAnyDone {
          Text("Done Today")
            .font(.septenaSectionTitle)
            .foregroundStyle(Theme.inkPrimary)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, Theme.sectionSpacing)
            .padding(.bottom, 6)
          NextDoneSection(model: model)
        }

        Spacer(minLength: 140)
      }
    }
    .background(Theme.paperBackground)
    .septenaInlineTitle()
    .task {
      model.paintFromCache()
      tasksModel.paintFromCache()
      async let a: () = model.load(client: client)
      async let b: () = tasksModel.load(client: client)
      _ = await (a, b)
    }
    .refreshable {
      async let a: () = model.load(client: client)
      async let b: () = tasksModel.load(client: client)
      _ = await (a, b)
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
        async let a: () = model.load(client: client)
        async let b: () = tasksModel.load(client: client)
        _ = await (a, b)
      }
    }
  }
}
