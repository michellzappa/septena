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
          // Match the other drawers' empty state: the message lives in a
          // rounded "pill" card (see `nextSectionCard`) rather than floating
          // bare on the grouped background.
          Text("Nothing here yet")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .nextSectionCard()
            .padding(.top, Theme.sectionSpacing)
        }

        NextSuggestionsSection(model: suggestionsModel)

        // Tasks / chores / habits / supplements render in the user's saved
        // section order (one order, shared with the homepage) — see
        // NextOpenSection.orderedKeys.
        NextOpenSection(model: model, tasksModel: tasksModel)

        // Completed chores/habits/supplements fade out in place after the
        // settle beat (no "Done" strip to slide down into) — same vanish
        // behaviour as today's tasks above.

        Spacer(minLength: 140)
      }
      // Match the Tasks / Goals drawers: ~20pt page inset so the rounded
      // section "pills" (see `nextSectionCard`) breathe against the light
      // grouped background instead of touching the screen edges.
      .padding(.horizontal, 20)
    }
    .background(Theme.groupedBackground)
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
