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
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(TabSelection.self) private var tabSelection
  @Environment(NavigationState.self) private var nav
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
  /// Done Today log fold — collapsed by default; persists across relaunches.
  @AppStorage("septena.next.doneTodayCollapsed") private var doneTodayCollapsed = true

  /// The keyboard cursor / native row highlight — bound straight to
  /// `List(selection:)` so ↑↓ traverse every tagged row across all sections,
  /// exactly like the Tasks tab. Return activates the row (open a task / toggle
  /// the trio), Space toggles, Escape clears. Each row is `.tag`'d with a
  /// `NextRowTag` kind-prefixed id so the cursor maps back to an action.
  @State private var selection: Set<String> = []
  @State private var promoteFlash = PromoteFlashStore()
  @State private var toastStore = SeptenaToastStore()

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
  @AppStorage(NextLinger.supplementsKey) private var lingerSupplements = NextLinger.supplementsDefault
  @AppStorage(NextLinger.habitsKey) private var lingerHabits = NextLinger.habitsDefault

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

  /// True while any modal editor owns the keyboard — suppresses list key bindings.
  private var keyboardInputActive: Bool {
    creating || editingTask != nil
      || editingMood != nil || editingGut != nil || editingNutrition != nil
  }

  /// True when this surface is the frontmost list (Next tab or Tasks ▸ Next).
  private var keyboardNavActive: Bool {
    tabSelection.current == .next || nav.path.last == .next
  }

  /// Every tagged row in display order — suggestions, open checklist blocks,
  /// then the Done Today log. ↑↓ traverse the full list.
  private var keyboardOrderedRowTags: [String] {
    var tags: [String] = []
    let visibleSuggestions = suggestionsModel.suggestions
      .filter { !suggestionsModel.skipped.contains($0.id) }
    tags += visibleSuggestions.map { NextRowTag.suggestion($0.id) }

    for key in NextFeed.nextSectionKeys(from: settingsStore.sections) {
      switch key {
      case "tasks":
        if !tasksModel.openTasks.isEmpty {
          tags += tasksModel.openTasks.map { NextRowTag.task($0.id) }
        }
      case "chores":
        if !model.openChores.isEmpty {
          tags += model.openChores.map { NextRowTag.chore($0.id) }
        }
      case "habits":
        let habits = model.openHabits.filter {
          DayBucket.isDueNow(bucketKey: $0.bucket, linger: lingerHabits)
        }
        if !habits.isEmpty { tags += habits.map { NextRowTag.habit($0.id) } }
      case "supplements":
        let supps = model.openSupplements.filter {
          DayBucket.isDueNow(bucketKey: $0.bucket, linger: lingerSupplements)
        }
        if !supps.isEmpty { tags += supps.map { NextRowTag.supplement($0.id) } }
      default:
        break
      }
    }

    if hasAnyDone, !doneTodayCollapsed {
      tags += NextDoneEvents.merged(model: model, passive: doneModel.events,
                                    lingeringTaskIDs: tasksModel.lingeringDoneTaskIDs)
        .map { NextRowTag.done($0.id) }
    }
    return tags
  }

  /// macOS Task-menu ⌘K — nil unless a single togglable row is selected.
  private var publishedNextListActions: NextListActions? {
    guard keyboardNavActive, !keyboardInputActive, let tag = selectedTag else { return nil }
    let kind = NextRowTag.split(tag).kind
    guard kind != "sugg", kind != "done" else { return nil }
    return NextListActions(toggleComplete: toggleSelection)
  }

  private static let editableDoneKeys: Set<String> = ["mood", "gut", "nutrition"]

  private func doneEvent(id: String) -> DoneEvent? {
    NextDoneEvents.merged(model: model, passive: doneModel.events,
                          lingeringTaskIDs: tasksModel.lingeringDoneTaskIDs)
      .first { $0.id == id }
  }

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
      editingMood = ChecklistMirror.loadMoodDay(context: modelContext, date: clock.today)
        .entries.first { $0.id == id }
    case "gut":
      editingGut = ChecklistMirror.loadGutDay(context: modelContext, date: clock.today)
        .entries.first { $0.id == id }
    case "nutrition":
      editingNutrition = ChecklistMirror.loadNutritionToday(context: modelContext, today: clock.today)
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

  /// Resolve the row Return / Space should act on — the lone selection, or the
  /// first visible row (mirrors the Tasks list's `effectiveSelectionId`).
  private func effectiveSelectedTag() -> String? {
    if let tag = selectedTag { return tag }
    guard let first = keyboardOrderedRowTags.first else { return nil }
    selection = [first]
    return first
  }

  /// Return: open the row's primary surface. A task opens its composer; a trio
  /// item (chore / habit / supplement) has no editor, so its primary action is
  /// the check itself. Suggestions / done-log rows are read-through here.
  private func activateSelection() {
    guard let tag = effectiveSelectedTag() else { return }
    let (kind, id) = NextRowTag.split(tag)
    switch kind {
    case "task":
      if let t = tasksModel.openTasks.first(where: { $0.id == id }) { openForEdit(t) }
    case "sugg":
      if let s = suggestionsModel.suggestions.first(where: { $0.id == id }) {
        performSuggestion(s)
      }
    case "done":
      if let e = doneEvent(id: id), Self.editableDoneKeys.contains(e.sectionKey) {
        beginEditDone(e)
      }
    case "chore", "habit", "supp":
      toggleTrio(kind: kind, id: id)
    default:
      break
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

  /// Return on a suggestion row — same routing as tapping the row.
  private func performSuggestion(_ suggestion: NextSuggestion) {
    Haptics.tap()
    switch suggestion.kind {
    case .fastBreak:
      nav.presentAddInfo(section: .nutrition)
    case .mood:
      nav.showMoodCheckin = true
    case .training:
      nav.showTrainingSession = true
    case .intake:
      break
    }
  }

  /// Space: toggle the row's done state without opening anything — including a
  /// task (the trio already toggles as its primary action).
  private func toggleSelection() {
    guard let tag = effectiveSelectedTag() else { return }
    let (kind, id) = NextRowTag.split(tag)
    guard kind != "sugg", kind != "done" else { return }
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
            #if os(macOS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .taskCardChrome(.solo)
            #endif
        } header: {
          EmptyView()
        }
      }

      NextSuggestionsSection(model: suggestionsModel, selection: selection)

      // Tasks / chores / habits / supplements render in the user's saved
      // section order (one order, shared with the homepage) — see
      // NextOpenSection.orderedKeys.
      NextOpenSection(model: model, tasksModel: tasksModel,
                      selection: selection,
                      areas: areas, projects: projects,
                      onOpenTask: { openForEdit($0) },
                      onClickSelect: clickSelectTask,
                      onAddTask: { creating = true })

      // A chronological log of everything finished today — the trio the
      // user just ticked off (lingers struck-through above, then lands
      // here newest-first) plus passive logs (caffeine, meals, mood, …).
      if hasAnyDone {
        NextDoneSection(model: model, passive: doneModel.events,
                        lingeringTaskIDs: tasksModel.lingeringDoneTaskIDs,
                        isCollapsed: $doneTodayCollapsed,
                        selection: selection,
                        onEdit: beginEditDone, onDelete: deleteDone)
      }
    }
    .environment(promoteFlash)
    .septenaToastStore(toastStore)
    #if os(iOS)
    // Match the Tasks sidebar exactly: insetGrouped cells over the soft gray
    // grouped background (was Theme.paperBackground = white, which left the
    // white cells reading as "white on white"), with the same tightened
    // section rhythm so the two home tabs feel like one family.
    .listStyle(.insetGrouped)
    .listSectionSpacing(18)
    #else
    // Plain list + per-row `taskCardChrome` — the same grouped-card surface
    // the Tasks tab paints via `SelectableScrollList`. Native `.inset` draws
    // square section boxes; we own the card shape ourselves.
    .listStyle(.plain)
    .padding(.bottom, Theme.pageBottom)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background {
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture { selection = [] }
    }
    #endif
    #if os(macOS)
    .septenaTabPage(
      id: "next",
      title: "Next",
      localActions: {
        AnyView(
          Button {
            nav.settingsDestination = .nextFeed
            nav.showSettings = true
          } label: {
            Label("Next Settings", systemImage: "arrow.forward.circle")
          }
        )
      },
      add: .addInfo,
      wideContentGutter: TaskCardMetrics.margin
    )
    #else
    .septenaTabPage(
      id: "next",
      title: "Next",
      localActions: {
        AnyView(
          Button {
            nav.settingsDestination = .nextFeed
            nav.showSettings = true
          } label: {
            Label("Next Settings", systemImage: "arrow.forward.circle")
          }
        )
      },
      add: .addInfo
    )
    #endif
    .septenaNeutralListSelection()
    // Keyboard navigation, the same shared contract the Tasks tab uses
    // (`listKeyboardNavigation`): the List is focusable so ↑↓ move the native
    // selection cursor across every tagged row; Return activates, Space
    // toggles, Escape clears. Suppressed while a modal editor owns the
    // keyboard so its fields keep Return/Space.
    .listKeyboardNavigation(
      inputActive: keyboardInputActive,
      isActive: keyboardNavActive,
      hasSelection: !selection.isEmpty,
      onReturn: activateSelection,
      onSpace: toggleSelection,
      onEscape: { selection = [] }
    )
    .septenaOnEscape { selection = [] }
    #if os(macOS)
    // Publish checklist toggle to the Task menu (⌘K) while Next is focused.
    // Task-list-only items stay disabled because `taskActions` is nil here.
    .focusedSceneValue(\.nextListActions, publishedNextListActions)
    #endif
    .septenaInlineTitle()
    .septenaToastOverlay(store: toastStore)
    // Host the task composer at the page root so its inspector docks to the
    // whole Next page (iPad/macOS) and sheets on iPhone — the same adaptive
    // drawer the Tasks tab uses. Edit mode embeds the agent conversation.
    .taskComposerDrawer(isPresented: composerBinding) {
      if let mode = composerMode {
        TaskComposerCard(mode: mode, areas: areas, projects: projects,
                         accent: theme.color(for: "tasks"),
                         onDone: { Task { await tasksModel.load(today: clock.today, now: clock.now) } })
      }
    }
    // "Done Today" editors hosted on the List container (NOT inside the
    // section — see `editingMood` above). `adaptiveDetail` is a sheet on
    // iPhone, a docked inspector on iPad/macOS; the feed refreshes from each
    // mutator's change notification, so onSave/onDone are no-ops.
    .adaptiveDetail(item: $editingMood) { entry in
      EditMoodEntrySheet(date: clock.today, original: entry, onSave: {})
    }
    .adaptiveDetail(item: $editingGut) { entry in
      EditGutEntrySheet(date: clock.today, original: entry, onSave: { _ in })
    }
    .adaptiveDetail(item: $editingNutrition) { entry in
      EditNutritionEntrySheet(original: entry, onDone: {})
    }
    .task {
      areas = LocalCache.areas(in: modelContext)
      projects = LocalCache.projects(in: modelContext)
      model.paintFromCache(today: clock.today)
      tasksModel.paintFromCache()
      suggestionsModel.paintFromCache(today: clock.today)
      async let a: () = model.load(today: clock.today)
      async let b: () = tasksModel.load(today: clock.today, now: clock.now)
      async let c: () = suggestionsModel.load(now: clock.now)
      async let d: () = doneModel.load(today: clock.today, now: clock.now)
      _ = await (a, b, c, d)
    }
    // Repaint when other surfaces (Tasks tab, menu bar, outbox drain)
    // mutate tasks so the Next checklist stays in sync. A completed task also
    // lands in the Done Today log, so reload that too.
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      tasksModel.refreshFromCache(motion: motion, promoteFlash: promoteFlash)
      Task { await doneModel.load(today: clock.today, now: clock.now) }
    }
    // Passive logs (mood check-in, caffeine, meals, …) post scoped
    // `.septenaDataChanged` via their mutators — reload suggestions / done
    // only when the touched section feeds those engines. Inbound CloudKit
    // batches post unscoped and reload every Next feed model from the mirror
    // (habits / supplements / chores included — they don't ride `doneModel`).
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      if note.isCloudKitBatch {
        Task {
          async let a: () = model.load(today: clock.today)
          async let b: () = suggestionsModel.load(now: clock.now)
          async let c: () = doneModel.load(today: clock.today, now: clock.now)
          _ = await (a, b, c)
        }
        return
      }
      let forSuggestions = note.affectsAnySection(of: Self.suggestionKeys)
      let forDone = note.affectsAnySection(of: Self.doneLogKeys)
      guard forSuggestions || forDone else { return }
      Task {
        if forSuggestions { await suggestionsModel.load(now: clock.now) }
        if forDone { await doneModel.load(today: clock.today, now: clock.now) }
      }
    }
    // Day rollover (midnight crossed while the app was alive, or session
    // resumed after midnight): refetch so habits/supplements/chores reflect
    // the new day's bucket and completion state.
    .onChange(of: clock.today) { _, _ in
      Task {
        async let a: () = model.load(today: clock.today)
        async let b: () = tasksModel.load(today: clock.today, now: clock.now)
        async let c: () = suggestionsModel.load(now: clock.now)
        async let d: () = doneModel.load(today: clock.today, now: clock.now)
        _ = await (a, b, c, d)
      }
    }
    .iPadReportsNavDepth(id: "next", atRoot: true)
  }
}

