import SwiftUI
import SwiftData

// Dedicated screen for the daily "next" strip: chores, habits, supplements.
// Pulled out of Today so Today stays focused on tasks (mirrors the web app).

struct NextView: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  @Environment(\.modelContext) private var modelContext

  @State private var model = NextItemsModel()
  @State private var tasksModel = TodayTasksModel()
  @State private var suggestionsModel = NextSuggestionsModel()
  @State private var doneModel = NextDoneModel()

  /// Tapping a task row (or its "Edit Task" menu item) opens the composer in
  /// edit mode — the same card the Tasks tab uses, which embeds the agent
  /// conversation section. Hosted here at the page root so its docked inspector
  /// (iPad/macOS) attaches to the whole Next page; iPhone gets a sheet.
  @State private var editingTask: SeptenaTask?
  /// Areas / projects backing the composer's List picker + each row's subtitle.
  /// Loaded once alongside the day's data (small, effectively static).
  @State private var areas: [Area] = []
  @State private var projects: [Project] = []

  /// Section keys whose `.septenaDataChanged` posts the suggestions engine
  /// actually consumes (`NextSuggestionsModel.computeAll`).
  private static let suggestionKeys: Set<String> =
    ["intake", "nutrition", "training", "mood"]
  /// Section keys the Done Today log (`NextDoneModel.collect`) reads. Same
  /// consumables, plus gut; tasks ride the separate `.septenaTasksChanged` path.
  private static let doneLogKeys: Set<String> =
    ["intake", "nutrition", "training", "mood", "gut"]

  /// Anything finished today — the trio's live done splits OR a passive log
  /// (caffeine, meals, mood, …). Drives both the empty state and whether the
  /// "Done Today" log renders.
  private var hasAnyDone: Bool { model.hasAnyDone || !doneModel.events.isEmpty }

  /// Drives the composer drawer from the optional `editingTask`; clearing it
  /// (swipe-away / Cancel / Save) closes the editor.
  private var composerBinding: Binding<Bool> {
    Binding(get: { editingTask != nil }, set: { if !$0 { editingTask = nil } })
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        // Title removed — the tab bar already labels this view.

        if model.hasLoaded && !model.hasAnyOpen && !hasAnyDone
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
        NextOpenSection(model: model, tasksModel: tasksModel,
                        onOpenTask: { editingTask = $0 },
                        selectedTaskId: editingTask?.id)

        // A chronological log of everything finished today — the trio the
        // user just ticked off (lingers struck-through above, then lands
        // here newest-first) plus passive logs (caffeine, meals, mood, …).
        if hasAnyDone {
          Text("Done Today")
            .font(.septenaSectionTitle)
            .foregroundStyle(Theme.inkPrimary)
            // Aligns with the row content inside the card below (rowHInset = Spacing.xl).
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.sectionSpacing)
            .padding(.bottom, 6)
          NextDoneSection(model: model, passive: doneModel.events)
        }

      }
      // Shared surface geometry (gutter + tab-bar clearance) so the rounded
      // section "pills" (see `nextSectionCard`) sit the same distance off
      // the screen edge as every other tab. `top: 0` because each section
      // pads its own top with `Theme.sectionSpacing` — conditionally hidden
      // sections must not leave gaps.
      .septenaSurface(top: 0)
    }
    .background(Theme.groupedBackground)
    .septenaInlineTitle()
    // Host the task composer at the page root so its inspector docks to the
    // whole Next page (iPad/macOS) and sheets on iPhone — the same adaptive
    // drawer the Tasks tab uses. Edit mode embeds the agent conversation.
    .taskComposerDrawer(isPresented: composerBinding) {
      if let task = editingTask {
        TaskComposerCard(mode: .edit(task), areas: areas, projects: projects,
                         accent: theme.color(for: "tasks"),
                         onDone: { tasksModel.refreshFromCache() })
      }
    }
    .task {
      areas = LocalCache.areas(in: modelContext)
      projects = LocalCache.projects(in: modelContext)
      model.paintFromCache()
      tasksModel.paintFromCache()
      suggestionsModel.paintFromCache()
      async let a: () = model.load()
      async let b: () = tasksModel.load()
      async let c: () = suggestionsModel.load()
      async let d: () = doneModel.load()
      _ = await (a, b, c, d)
    }
    // Repaint when other surfaces (Tasks tab, menu bar, outbox drain)
    // mutate tasks so the Next checklist stays in sync. A completed task also
    // lands in the Done Today log, so reload that too.
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      tasksModel.refreshFromCache()
      Task { await doneModel.load() }
    }
    // Passive logs (mood check-in, caffeine, meals, …) post .septenaDataChanged
    // via their mutators. Reload the suggestions so a just-logged mood daypart
    // drops its "How are you feeling?" prompt, and the done log so the entry
    // lands in "Done Today". Scoped: both `load()`s rerun the suggestions /
    // done engines over 14–30 days of history, so a post that touches neither
    // surface's inputs (a habit toggle, a grocery edit) must not trigger them.
    // An unscoped post (CK batch) has nil sections and passes both filters.
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      let forSuggestions = note.affectsAnySection(of: Self.suggestionKeys)
      let forDone = note.affectsAnySection(of: Self.doneLogKeys)
      guard forSuggestions || forDone else { return }
      Task {
        if forSuggestions { await suggestionsModel.load() }
        if forDone { await doneModel.load() }
      }
    }
    // Day rollover (midnight crossed while the app was alive, or session
    // resumed after midnight): refetch so habits/supplements/chores reflect
    // the new day's bucket and completion state.
    .onChange(of: clock.today) { _, _ in
      Task {
        async let a: () = model.load()
        async let b: () = tasksModel.load()
        async let c: () = suggestionsModel.load()
        async let d: () = doneModel.load()
        _ = await (a, b, c, d)
      }
    }
  }
}
