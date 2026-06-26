import SwiftUI
import SwiftData
#if os(macOS)
import AppKit  // NSEvent.modifierFlags for ⌘/⇧-click selection
#endif

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
  @State private var promoteFlash = PromoteFlashStore()

  /// Tapping a task row (or its "Edit Task" menu item) opens the composer in
  /// edit mode — the same card the Tasks tab uses, which embeds the agent
  /// conversation section. Hosted here at the page root so its docked inspector
  /// (iPad/macOS) attaches to the whole Next page; iPhone gets a sheet.
  @State private var editingTask: SeptenaTask?
  /// Quick-add: the Tasks section header's "+" opens the same composer in
  /// create mode (defaulting new tasks to Today, like the Tasks drawer's +).
  @State private var creating = false
  // "Done Today" editors — mood / gut / nutrition rows reopen their home
  // editor. Hosted HERE, on the `List` container, NOT inside `NextDoneSection`:
  // `adaptiveDetail` resolves to a macOS `.inspector`, and attaching that to a
  // `Section` collapses it (the rows render sideways instead of stacked). The
  // presentation must live outside the List, alongside the task composer.
  @State private var editingMood: MoodEntry?
  @State private var editingGut: GutEntry?
  @State private var editingNutrition: NutritionEntry?
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

  /// Drives the composer drawer from either a quick-add (`creating`) or a row
  /// edit (`editingTask`); clearing it (swipe-away / Cancel / Save) closes the
  /// editor and resets both flags.
  private var composerBinding: Binding<Bool> {
    Binding(get: { creating || editingTask != nil },
            set: { if !$0 { creating = false; editingTask = nil } })
  }

  /// Create vs. edit for the hosted composer card. Create wins if both are set
  /// (they never are — opening one clears the other).
  private var composerMode: TaskComposerCard.Mode? {
    if creating { return .create(.today) }
    if let task = editingTask { return .edit(task) }
    return nil
  }

  // MARK: - Done Today editing
  //
  // The Done log keeps only denormalized, Sendable `DoneEvent`s, so re-resolve
  // the live entity by id before opening its section's editor. `DoneEvent.id`
  // is "<prefix>-<entityID>"; the prefix differs from the section key for
  // nutrition ("nut-").

  private func doneEntityID(_ e: DoneEvent) -> String? {
    let prefix: String
    switch e.sectionKey {
    case "mood":      prefix = "mood-"
    case "gut":       prefix = "gut-"
    case "nutrition": prefix = "nut-"
    default: return nil
    }
    guard e.id.hasPrefix(prefix) else { return nil }
    return String(e.id.dropFirst(prefix.count))
  }

  private func beginEditDone(_ e: DoneEvent) {
    guard let id = doneEntityID(e) else { return }
    switch e.sectionKey {
    case "mood":
      editingMood = ChecklistMirror.loadMoodDay(context: modelContext, date: SeptenaDate.today)
        .entries.first { $0.id == id }
    case "gut":
      editingGut = ChecklistMirror.loadGutDay(context: modelContext, date: SeptenaDate.today)
        .entries.first { $0.id == id }
    case "nutrition":
      editingNutrition = ChecklistMirror.loadNutritionToday(context: modelContext)
        .first { $0.id == id }
    default: break
    }
  }

  // Delete through the section mutator (the write boundary); the feed refreshes
  // off the mutator's change notification, same as the open rows.
  private func deleteDone(_ e: DoneEvent) {
    guard let id = doneEntityID(e) else { return }
    Haptics.warning()
    switch e.sectionKey {
    case "mood":      SeptenaServices.shared.moodMutator.deleteEntry(id: id)
    case "gut":       SeptenaServices.shared.gutMutator.deleteEntry(id: id)
    case "nutrition": SeptenaServices.shared.nutritionMutator.deleteEntry(id: id)
    default: break
    }
  }

  // MARK: - macOS click selection

  /// Write the task row's selection from its tap gesture. A tap gesture on a
  /// `List` row defeats native click-selection, so we own it here (mirrors the
  /// Tasks tab's `clickSelect`): plain click selects only this row, ⌘-click
  /// toggles it, ⇧-click extends. No-op on iOS, where rows open on single tap.
  private func clickSelectTask(_ id: String) {
    #if os(macOS)
    let tag = NextRowTag.task(id)
    let mods = NSEvent.modifierFlags
    if mods.contains(.command) {
      if selection.contains(tag) { selection.remove(tag) } else { selection.insert(tag) }
    } else if mods.contains(.shift) {
      selection.insert(tag)
    } else {
      selection = [tag]
    }
    #endif
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
      if let t = tasksModel.openTasks.first(where: { $0.id == id }) { openForEdit(t) }
    default:
      toggleTrio(kind: kind, id: id)
    }
  }

  /// Open a task in the composer and pin the native selection to its row, so
  /// the keyboard cursor and the editing row stay in agreement (the row keeps
  /// its native `List(selection:)` highlight while its editor is open — no
  /// custom highlight; selection IS the anchor). Used by both a row tap and
  /// the keyboard Return path.
  private func openForEdit(_ task: SeptenaTask) {
    selection = [NextRowTag.task(task.id)]
    editingTask = task
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
                      onOpenTask: { openForEdit($0) },
                      onClickSelect: clickSelectTask,
                      onAddTask: { creating = true })

      // A chronological log of everything finished today — the trio the
      // user just ticked off (lingers struck-through above, then lands
      // here newest-first) plus passive logs (caffeine, meals, mood, …).
      if hasAnyDone {
        NextDoneSection(model: model, passive: doneModel.events,
                        onEdit: beginEditDone, onDelete: deleteDone)
      }
    }
    .environment(promoteFlash)
    #if os(iOS)
    .listStyle(.insetGrouped)
    #else
    .listStyle(.inset)
    #endif
    .septenaNeutralListSelection()
    // Keyboard navigation, the same shared contract the Tasks tab uses
    // (`listKeyboardNavigation`): the List is focusable so ↑↓ move the native
    // selection cursor across every tagged row; Return activates, Space
    // toggles, Escape clears. Suppressed while the task composer owns the
    // keyboard so its fields keep Return/Space.
    .listKeyboardNavigation(
      inputActive: editingTask != nil,
      hasSelection: !selection.isEmpty,
      onReturn: activateSelection,
      onSpace: toggleSelection,
      onEscape: { selection = [] }
    )
    .septenaInlineTitle()
    // Host the task composer at the page root so its inspector docks to the
    // whole Next page (iPad/macOS) and sheets on iPhone — the same adaptive
    // drawer the Tasks tab uses. Edit mode embeds the agent conversation.
    .taskComposerDrawer(isPresented: composerBinding) {
      if let mode = composerMode {
        TaskComposerCard(mode: mode, areas: areas, projects: projects,
                         accent: theme.color(for: "tasks"),
                         onDone: { Task { await tasksModel.load() } })
      }
    }
    // "Done Today" editors hosted on the List container (NOT inside the
    // section — see `editingMood` above). `adaptiveDetail` is a sheet on
    // iPhone, a docked inspector on iPad/macOS; the feed refreshes from each
    // mutator's change notification, so onSave/onDone are no-ops.
    .adaptiveDetail(item: $editingMood) { entry in
      EditMoodEntrySheet(date: SeptenaDate.today, original: entry, onSave: {})
    }
    .adaptiveDetail(item: $editingGut) { entry in
      EditGutEntrySheet(date: SeptenaDate.today, original: entry, onSave: { _ in })
    }
    .adaptiveDetail(item: $editingNutrition) { entry in
      EditNutritionEntrySheet(original: entry, onDone: {})
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

