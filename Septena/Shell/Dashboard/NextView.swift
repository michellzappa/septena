import SwiftUI
import SwiftData

// Dedicated screen for the daily "next" strip: chores, habits, supplements.
// Pulled out of Today so Today stays focused on tasks (mirrors the web app).

struct NextView: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  @Environment(\.modelContext) private var modelContext
  // Write boundaries for keyboard-driven Return / Space activation. The trio
  // (chores / habits / supplements) flips through the ChecklistMutator; tasks
  // toggle through the TaskMutator — the same paths the row buttons use.
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(\.a11yMotion) private var motion
  @Environment(NavigationState.self) private var nav

  /// iOS presents Settings as a local sheet so the deep-link target
  /// (`initialDestination`) is honored; macOS opens the dedicated window via
  /// `nav` (the generic RootTabView sheet doesn't forward a destination).
  @State private var showSettings = false
  @State private var settingsTarget: SettingsView.SettingsDestination?

  /// Open Settings to `dest` (or the root when nil), mirroring the pattern in
  /// `InsightsDestination`: a contextual window on macOS, a local sheet on iOS.
  private func openSettings(_ dest: SettingsView.SettingsDestination?) {
    #if os(macOS)
    nav.settingsDestination = dest
    nav.showSettings = true
    #else
    settingsTarget = dest
    showSettings = true
    #endif
  }

  @State private var model = NextItemsModel()
  @State private var tasksModel = TodayTasksModel()
  @State private var suggestionsModel = NextSuggestionsModel()
  @State private var doneModel = NextDoneModel()

  /// The keyboard cursor / native row highlight — bound straight to
  /// `List(selection:)` so ↑↓ traverse every tagged row across all sections,
  /// exactly like the Tasks tab. Return activates the row (open a task / toggle
  /// the trio), Space toggles, Escape clears. Each row is `.tag`'d with a
  /// `NextRowTag` kind-prefixed id so the cursor maps back to an action.
  @State private var selection: Set<String> = []

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

  // MARK: - Keyboard activation

  /// The single selected row, when exactly one is highlighted. Multi-select
  /// (⌘/⇧-click) has no single primary action, so Return/Space no-op there.
  private var selectedTag: String? {
    selection.count == 1 ? selection.first : nil
  }

  /// Return: open the row's primary surface. A task opens its composer; a trio
  /// item (chore / habit / supplement) has no editor, so its primary action is
  /// the check itself. Suggestions / done-log rows are read-through here.
  private func activateSelection() {
    guard let tag = selectedTag else { return }
    let (kind, id) = NextRowTag.split(tag)
    switch kind {
    case "task":
      if let t = tasksModel.openTasks.first(where: { $0.id == id }) { editingTask = t }
    default:
      toggleTrio(kind: kind, id: id)
    }
  }

  /// Space: toggle the row's done state without opening anything — including a
  /// task (the trio already toggles as its primary action).
  private func toggleSelection() {
    guard let tag = selectedTag else { return }
    let (kind, id) = NextRowTag.split(tag)
    if kind == "task" {
      if let t = tasksModel.openTasks.first(where: { $0.id == id }) {
        tasksModel.toggle(t, mutator: taskMutator, motion: motion)
      }
    } else {
      toggleTrio(kind: kind, id: id)
    }
  }

  /// Flip a chore / habit / supplement through its model mutator — the same
  /// optimistic write the row's checkbox button performs.
  private func toggleTrio(kind: String, id: String) {
    switch kind {
    case "chore":
      guard let c = model.openChores.first(where: { $0.id == id }) else { return }
      if model.completedChores.contains(c.id) {
        model.uncompleteChore(c, mutator: checklistMutator)
      } else {
        model.completeChore(c, mutator: checklistMutator, motion: motion)
      }
    case "habit":
      if let h = model.openHabits.first(where: { $0.id == id }) {
        model.toggleHabit(h, mutator: checklistMutator, motion: motion)
      }
    case "supp":
      if let s = model.openSupplements.first(where: { $0.id == id }) {
        model.toggleSupplement(s, mutator: checklistMutator, motion: motion)
      }
    default:
      break
    }
  }

  var body: some View {
    // A native grouped List, the same container the Coach landing uses, so the
    // two home tabs read as one family: each block is a `Section` with a tinted
    // header over native grouped cells (was a ScrollView of hand-rolled "pill"
    // cards). Single-column by design — the old wide-screen masonry is gone.
    List(selection: $selection) {
      // Title removed — the tab bar already labels this view.

      if model.hasLoaded && !model.hasAnyOpen && !hasAnyDone
          && tasksModel.openTasks.isEmpty
          && suggestionsModel.suggestions.isEmpty {
        Section {
          Text("Nothing here yet")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      NextSuggestionsSection(model: suggestionsModel)

      // Tasks / chores / habits / supplements render in the user's saved
      // section order (one order, shared with the homepage) — see
      // NextOpenSection.orderedKeys.
      NextOpenSection(model: model, tasksModel: tasksModel,
                      areas: areas, projects: projects,
                      onOpenTask: { editingTask = $0 },
                      selectedTaskId: editingTask?.id)

      // A chronological log of everything finished today — the trio the
      // user just ticked off (lingers struck-through above, then lands
      // here newest-first) plus passive logs (caffeine, meals, mood, …).
      if hasAnyDone {
        NextDoneSection(model: model, passive: doneModel.events)
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #else
    .listStyle(.inset)
    #endif
    // Keyboard navigation, mirroring the Tasks tab: the List is focusable so
    // ↑↓ move the native selection cursor across every tagged row; Return
    // activates, Space toggles, Escape clears. Suppressed while the task
    // composer owns the keyboard (editorOpen) so its fields keep Return/Space.
    .modifier(NextKeyboardModifier(
      hasSelection: !selection.isEmpty,
      editorOpen: editingTask != nil,
      onReturn: activateSelection,
      onSpace: toggleSelection,
      onEscape: { selection = [] }
    ))
    .septenaInlineTitle()
    // The "…" overflow: a quick jump to the Next-specific preferences
    // (suggestions, carry-over, which sections appear) and to global Settings.
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button {
            openSettings(.nextFeed)
          } label: {
            Label("Next Settings", systemImage: "arrow.forward.circle")
          }
          Button {
            openSettings(nil)
          } label: {
            Label("Settings", systemImage: "gearshape")
          }
        } label: {
          Label("More", systemImage: "ellipsis.circle")
        }
      }
    }
    #if os(iOS)
    .sheet(isPresented: $showSettings) {
      SettingsView(initialDestination: settingsTarget)
    }
    #endif
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

/// Makes the Next `List` keyboard-driven, mirroring the Tasks tab's modifier:
/// the list takes focus (so ↑↓ run native `List(selection:)` traversal) and
/// Return / Space / Escape map to the page's activation handlers. Focus is
/// re-claimed when the task composer closes so the cursor survives an edit.
private struct NextKeyboardModifier: ViewModifier {
  let hasSelection: Bool
  let editorOpen: Bool
  let onReturn: () -> Void
  let onSpace: () -> Void
  let onEscape: () -> Void

  @FocusState private var listFocused: Bool

  func body(content: Content) -> some View {
    content
      .focusable()
      .focused($listFocused)
      .focusEffectDisabled()
      .onAppear { listFocused = true }
      .onChange(of: editorOpen) { _, open in
        guard !open else { return }
        DispatchQueue.main.async { listFocused = true }
      }
      .onKeyPress(.return) {
        guard !editorOpen, hasSelection else { return .ignored }
        onReturn()
        return .handled
      }
      .onKeyPress(.space) {
        guard !editorOpen, hasSelection else { return .ignored }
        onSpace()
        return .handled
      }
      .onKeyPress(.escape) {
        guard !editorOpen, hasSelection else { return .ignored }
        onEscape()
        return .handled
      }
  }
}
