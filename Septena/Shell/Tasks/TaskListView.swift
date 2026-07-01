import SwiftUI
import SwiftData
import EventKit  // optional calendar agenda woven into Today / Upcoming
#if canImport(AppKit)
import AppKit  // NSEvent.modifierFlags for ⌘/⇧-click selection
#endif

// One screen per filter (Today / Inbox / Upcoming / Anytime / Logbook / Project / Area).
// Read-through cache: views render from SwiftData immediately, then refresh
// from the server in the background and fold the response back in.

struct TaskListView: View {
  /// Task write-path: applies optimistic SwiftData changes, enqueues
  /// CloudKit-backed ops. Every mutation in this view routes through here
  /// instead of `client.*` so the UI never blocks on the network and
  /// offline edits survive an app restart.
  @Environment(TaskMutator.self) private var mutator
  /// CloudKit engine. The SwiftData mirror is refreshed by the engine and
  /// `load()` re-reads from that local mirror.
  @Environment(CKEngine.self) private var ckEngine
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @Environment(\.a11yMotion) private var motion
  @Environment(\.usesPushNavigation) private var usesPushNavigation
  /// App-root celebration layer — only used by the day-cleared `.arc`
  /// (see `TaskCelebration`). Optional: hosts outside the root env keep
  /// the haptic and skip the visual.
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  @Environment(DayClock.self) private var clock
  let filter: TaskFilter
  /// True when this view is laid out *inside* another detail screen
  /// (Project / Area detail). Suppresses the screen title and top-bar chrome
  /// so the parent owns identity. Pushed as its own screen → leave `false`.
  var embedded: Bool = false
  /// When set on an Area page, hides tasks that belong to a project so the
  /// area list shows only area-direct work (projects live in the parent view).
  var excludeProjectedTasks: Bool = false
  /// Optional content rendered as the first row(s) of the underlying List
  /// when `embedded` is true. Lets Project / Area detail screens place their
  /// title + notes (and any project roll-up) *inside* the scrolling list, so
  /// the header scrolls away with the rows instead of pinning at the top.
  let embeddedHeader: () -> AnyView

  @AppStorage(SettingsKey.todayShowCompleted) private var todayShowCompleted: Bool = true
  /// Things-style grouped Today (area / project sections) vs a single flat
  /// list under Inbox with list subtitles and due-first ordering.
  @AppStorage(SettingsKey.todayGroupByList) private var todayGroupByList: Bool = true
  /// Opt-in: weave the day's calendar events into Today and Upcoming (Things-
  /// style). Only ever populated for those two filters, and only when calendar
  /// access is already granted (Settings → Integrations) — see `load()`.
  @AppStorage(SettingsKey.tasksShowCalendarEvents) private var showCalendarEvents: Bool = true
  /// The fetched calendar events for the current filter's window. `todayEvents()`
  /// on Today; the next 30 days on Upcoming; empty everywhere else.
  @State private var calendarEvents: [EKEvent] = []

  // Items/review/doneToday are filter-scoped. We store them alongside the
  // filter they correspond to; when the current `filter` doesn't match the
  // stored filter (a section swap just happened, .onChange hasn't run yet),
  // the getters fall back to the SwiftData cache for the *current* filter —
  // so body always reads a value that matches what's on screen. This kills
  // the one-frame "wrong filter's data" / "Nothing here yet" flash that
  // happens when @State lags behind a prop change.
  @State private var itemsStorage: [SeptenaTask] = []
  @State private var reviewStorage: [SeptenaTask] = []
  @State private var doneTodayStorage: [SeptenaTask] = []
  @State private var triageStorage: [SeptenaTask] = []
  @State private var storageFilter: TaskFilter? = nil

  @State private var areas: [Area]
  @State private var projects: [Project]

  /// Which area/project cluster (if any) is currently the hovered drop
  /// target during a drag. All rows + header sharing the same key light
  /// up together, so the whole cluster reads as one landing zone — not
  /// just whatever row the pointer happens to be over.

  /// Filters we've successfully loaded from the network at least once.
  /// Gates the "Nothing here yet" empty state so it never flashes during
  /// a section swap — only after a real network response confirms emptiness.
  @State private var loadedFilters: Set<TaskFilter> = []

  init<H: View>(
    filter: TaskFilter,
    embedded: Bool = false,
    excludeProjectedTasks: Bool = false,
    @ViewBuilder embeddedHeader: @escaping () -> H
  ) {
    self.filter = filter
    self.embedded = embedded
    self.excludeProjectedTasks = excludeProjectedTasks
    self.embeddedHeader = { AnyView(embeddedHeader()) }
    // Memoized: this init re-runs on every parent render (the values are
    // discarded for installed views), so a per-construction fetch was waste.
    let structure = StructureCache.snapshot(in: LocalStore.shared.container.mainContext)
    _areas = State(initialValue: structure.areas)
    _projects = State(initialValue: structure.projects)
  }

  init(
    filter: TaskFilter,
    embedded: Bool = false,
    excludeProjectedTasks: Bool = false
  ) {
    self.filter = filter
    self.embedded = embedded
    self.excludeProjectedTasks = excludeProjectedTasks
    self.embeddedHeader = { AnyView(EmptyView()) }
    // Memoized — see the generic init above.
    let structure = StructureCache.snapshot(in: LocalStore.shared.container.mainContext)
    _areas = State(initialValue: structure.areas)
    _projects = State(initialValue: structure.projects)
  }

  private var items: [SeptenaTask] {
    get {
      storageFilter == filter
        ? itemsStorage
        : LocalCache.tasks(in: LocalStore.shared.container.mainContext, filter: filter)
    }
    nonmutating set {
      itemsStorage = newValue
      storageFilter = filter
    }
  }

  private var review: [SeptenaTask] {
    get { storageFilter == filter ? reviewStorage : [] }
    nonmutating set { reviewStorage = newValue; storageFilter = filter }
  }

  /// The Inbox — the unratified layer rendered as a section above Today (only on
  /// the Today view; see `triageSection`). Backed by `triageStorage` (populated
  /// in `load()` with the same settle-preservation as `items`), with a live
  /// fallback for the pre-load frame. Like `visibleItems`, a just-checked row
  /// stays in the set while it settles (`status == .open || isSettling`) so
  /// completing an Inbox suggestion lingers struck-through and fades in place
  /// rather than vanishing instantly. See docs/TRIAGE_BAND_SPEC.md.
  private var triageItems: [SeptenaTask] {
    guard filter == .today else { return [] }
    let base = storageFilter == filter
      ? triageStorage
      : LocalCache.tasks(in: LocalStore.shared.container.mainContext, filter: .triage)
    return base.filter { $0.status == .open || settle.isSettling($0.id) }
  }

  /// Review tasks that genuinely rolled in overnight — i.e. were scheduled
  /// for a date strictly before today. Items the user scheduled *for* today
  /// (scheduled == today) or that are merely due today don't count as "new"
  /// because the user just placed them; the banner shouldn't nag about those.
  private var rolledInReview: [SeptenaTask] {
    let today = clock.today
    return review.filter { task in
      guard let s = task.scheduled, !s.isEmpty else { return false }
      return String(s.prefix(10)) < today
    }
  }

  private var doneToday: [SeptenaTask] {
    get { storageFilter == filter ? doneTodayStorage : [] }
    nonmutating set { doneTodayStorage = newValue; storageFilter = filter }
  }

  @State private var isLoading = false
  @State private var errorMessage: String?

  /// IDs of tasks completed during this view's lifetime. On Project / Area
  /// pages we want to hide historical completions but keep just-completed
  /// rows visible until the user navigates away (matches the reference design).
  @State private var sessionDoneIds: Set<String> = []

  /// Drives the "linger → fade" beat after a check (see `SettleStore`). Keeps
  /// a just-completed row in place for a moment, then fades it out where it
  /// sits instead of yanking it the instant you tap.
  @State private var settle = SettleStore()
  /// One-shot amber flash when a task is pinned to Today (row wash + checkbox pulse).
  @State private var promoteFlash = PromoteFlashStore()
  @State private var toastStore = SeptenaToastStore()

  /// Scroll anchor for the foot (or empty-list top) "New task" quick-add row.
  private static let quickAddScrollID = "task-quick-add"
  @State private var scrollToTargetID: String?
  @State private var scrollToTargetTick = 0

  /// Unified selection — the single source of truth for the keyboard cursor
  /// and multi-select batch operations, bound straight to `List(selection:)`
  /// on both platforms. macOS: native click / ⌘-click / ⇧-click / ↑↓.
  /// iOS: native edit-mode multi-select (the `EditButton` drives `editMode`,
  /// and tapping rows toggles the native selection circles).
  @State private var selection: Set<String> = []

  #if os(iOS)
  /// iOS edit-mode environment key (unavailable on macOS). Vestigial now that
  /// multi-select and manual reorder are gone — kept only so the few remaining
  /// `editMode`-clearing safety calls compile.
  @Environment(\.editMode) private var editMode
  /// Compact (iPhone) vs regular (iPad) — picks the touch tap-to-edit model
  /// vs the pointer+keyboard selection model in `usesSelectionModel`.
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  // The full task editor — Things-style EXPAND-IN-PLACE. Opening a row
  // (tap / Return / double-click / ⌘R / ⓘ / "Edit Details…") sets this to the
  // task's id; that row then renders the editor (title + When / Deadline / List
  // / Notes / Repeat pills + the agent conversation) inline, growing the row,
  // instead of a separate drawer. The editor reuses `TaskComposerCard` in its
  // `.inline` presentation, so the form is literally the same component the
  // create-drawer uses. Folding the row autosaves (see `collapseEdit`).
  @State private var expandedEditId: String?
  /// Inline-create placeholders (`deferPush` drafts) — purged on fold when the
  /// title never got a non-empty commit.
  @State private var draftEditIds: Set<String> = []
  /// Foot/top "New task" capture in progress — the draft renders in the quick-add
  /// slot instead of duplicating above the trigger.
  @State private var quickAddDraftId: String?
  /// Keeps the empty-list top quick-add anchored while its draft is open (the
  /// list stops being "empty" the moment the draft exists).
  @State private var quickAddDraftAtTop = false
  /// Which Today group owns an in-flight capture draft — Inbox foot line vs a
  /// specific area / project section opened from its header "+".
  private enum QuickAddGroupTarget: Equatable {
    case inbox
    case area(String)
    case project(String)
  }
  @State private var quickAddGroupTarget: QuickAddGroupTarget?
  /// Shared namespace for the title hero-glide: the closed row's title and the
  /// open inline editor's title field carry the same `matchedGeometryEffect` id,
  /// so on expand/collapse the title moves between the two positions instead of
  /// cross-fading. See `CheckableRow.titleMatchID` / `editTitleMatchID`.
  @Namespace private var editTitleNS

  // Upcoming-only: the multi-day grid has no single list context, so ⌘N / + fall
  // back to the drawer composer (pick a day). Every other creatable list spawns
  // a `deferPush` draft row and opens the inline expand-in-place editor.
  @State private var creating = false

  // MARK: - Inline editing (the Reminders/Things "type-a-line" model)
  //
  // Title editing and quick-create are one behavior: an editable title field.
  // Renaming an existing row swaps its `Text(title)` for a `TextField`;
  // creating is the always-present quick-add line at the foot of the list. The
  // full composer (When / Deadline / List / Notes / Repeat) stays one gesture
  // away — a double-click (macOS) or the row's ⓘ Details button (iOS) — for the
  // attributes the inline field can't express.

  /// The keyboard-cursor target for the inline fields. `.row(id)` is a row
  /// being renamed in place; `.newRow` is the quick-add line.
  enum InlineFocus: Hashable {
    case row(String)
    case newRow
  }
  @FocusState private var inlineFocus: InlineFocus?
  /// The task whose title is being renamed in place (nil → none). Its row
  /// renders the inline editor instead of the static `TaskRow`.
  @State private var editingTitleId: String?
  /// Working buffer for the in-place rename; seeded from the task on begin,
  /// committed (or discarded) on submit / blur / Esc.
  @State private var titleDraft: String = ""

  /// Whether the Inbox section (on the Today view) is folded. Expanded by
  /// default; the header shows the count either way.
  @State private var inboxCollapsed = false

  /// Project / area ids whose completed-task foldout is expanded. Collapsed by
  /// default; persisted across relaunches (Things-style per-list memory).
  @AppStorage("septena.tasks.projectLoggedExpanded") private var scopeLoggedExpandedData: Data = Data()
  private var scopeLoggedExpandedIds: Set<String> {
    (try? JSONDecoder().decode(Set<String>.self, from: scopeLoggedExpandedData)) ?? []
  }
  private var scopeLoggedFilterId: String? {
    switch filter {
    case .project(let id), .area(let id): return id
    default: return nil
    }
  }
  private var isScopeLoggedExpanded: Bool {
    guard let id = scopeLoggedFilterId else { return false }
    return scopeLoggedExpandedIds.contains(id)
  }
  /// Completed tasks for the current project or area page — done only, not
  /// settling (settling rows stay in the open list until they fade), newest first.
  /// Area pages honour `excludeProjectedTasks` so only area-direct work appears.
  private var loggedScopeItems: [SeptenaTask] {
    guard scopeLoggedFilterId != nil else { return [] }
    var result = items.filter { $0.status == .done && !settle.isSettling($0.id) }
    if excludeProjectedTasks { result = result.filter { $0.project == nil } }
    return result.sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
  }
  private func toggleScopeLoggedExpanded() {
    guard let id = scopeLoggedFilterId else { return }
    Haptics.tick()
    var set = scopeLoggedExpandedIds
    if set.contains(id) { set.remove(id) } else { set.insert(id) }
    withAnimation(.easeInOut(duration: 0.2)) {
      scopeLoggedExpandedData = (try? JSONEncoder().encode(set)) ?? Data()
    }
  }

  // When picker. Use a single Identifiable item so the sheet's kind
  // is intrinsic to the presentation — avoids stale-state races where
  // tapping "When" could open the prior "Deadline" pane.
  @State private var whenSheet: WhenSheet?
  enum WhenKind { case deadline, scheduled }
  struct WhenSheet: Identifiable {
    let id: String
    let taskIds: [String]
    let kind: WhenKind
    init(taskIds: [String], kind: WhenKind) {
      self.taskIds = taskIds
      self.kind = kind
      self.id = "\(taskIds.joined(separator: ","))|\(kind == .deadline ? "due" : "sched")"
    }
  }

  // Move picker
  @State private var showingMoveSheet = false
  @State private var moveTargetIds: [String] = []

  // Repeat picker
  @State private var showingRepeatSheet = false
  @State private var repeatTargetId: String?

  /// True while iOS edit mode is active — rows show native selection circles
  /// and a tap toggles membership instead of opening the editor. Always false
  /// on macOS (no edit mode; click selection is direct).
  private var isEditMode: Bool {
    #if os(iOS)
    return editMode?.wrappedValue.isEditing ?? false
    #else
    return false
    #endif
  }

  /// What `rowActionsMenu` operates on — a single row or the current multi-
  /// selection when the interacted row is part of it.
  // Internal (not fileprivate) so the shared `TaskRowActions` modifier — used
  // on the Next surface — can drive the same `TaskListRowContextMenu`.
  enum ActionTarget {
    case single(SeptenaTask)
    case bulk([SeptenaTask])

    var tasks: [SeptenaTask] {
      switch self {
      case .single(let t): return [t]
      case .bulk(let ts): return ts
      }
    }

    var ids: [String] { tasks.map(\.id) }

    var isBulk: Bool {
      if case .bulk = self { return true }
      return false
    }

    var count: Int { tasks.count }
  }

  private var selectionScope: ListSelectionScope<String> {
    ListSelectionScope(selection: selection, orderedIDs: keyboardOrderedTaskIds)
  }

  private func orderedActionIDs() -> [String] {
    selectionScope.actionIDs
  }

  private func actionTarget(for task: SeptenaTask) -> ActionTarget {
    if let resolved = SelectionActionTarget.resolve(
      interactedID: task.id,
      scope: selectionScope,
      item: { currentTask(id: $0) }
    ) {
      switch resolved {
      case .single(let t): return .single(t)
      case .bulk(let ts): return .bulk(ts)
      }
    }
    return .single(task)
  }

  private func dragPayload(for task: SeptenaTask) -> TaskDragIDs {
    if selection.contains(task.id), selection.count > 1 {
      return TaskDragIDs(ids: orderedActionIDs())
    }
    return TaskDragIDs(ids: [task.id])
  }


  // Local semantic sorter — populates a "→ Suggested" chip on Inbox rows.
  @State private var suggestionEngine = SuggestionEngine.shared
  /// Per-row top filing suggestion — snapshotted in `load()` from the same
  /// `filingRankedSuggestions` path as the context menu. Held in @State (not
  /// read live off the @Observable engine) so the row chip renders reliably.
  @State private var filingSuggestions: [String: SuggestionEngine.Suggestion] = [:]

  /// done / (done + open) per project, mirroring the sidebar's aggregate so the
  /// project pie glyph in mixed-list headers (Today / Unscheduled) reads the
  /// real completion ratio. Cancelled tasks count toward neither side.
  /// Snapshotted in `load()` from the full local corpus, since `items` is
  /// filter-scoped and never holds a project's done rows.
  @State private var progressByProject: [String: Double] = [:]

  // "You have N new to-dos" banner — compact start-of-day welcome that
  // surfaces tasks rolling in from scheduled-past or due-today. Dismissed
  // per-day via UserDefaults (local only); reappears the next morning.
  // Cross-device same-day dismissal sync is in the backlog.
  @State private var newTodosDismissed: Bool = false

  var body: some View {
    let content = taskList
      .environment(promoteFlash)
      .septenaToastStore(toastStore)
      .modifier(TaskListModalPresenter(
        whenSheet: $whenSheet,
        showingMoveSheet: $showingMoveSheet,
        moveTargetIds: $moveTargetIds,
        showingRepeatSheet: $showingRepeatSheet,
        repeatTargetId: $repeatTargetId,
        areas: areas,
        projects: projects,
        currentTask: currentTask,
        currentScheduled: currentScheduled,
        currentDeadline: currentDeadline,
        currentRecurrence: currentRecurrence,
        applyWhen: applyWhenToSelection,
        applyMove: applyMoveToSelection,
        applyRecurrence: applyRecurrence
      ))
    let withSnackbar = content.septenaToastOverlay(store: toastStore)
    // Publish row actions to the menu bar via FocusedValues — macOS ONLY.
    // The "Task" CommandMenu in App.swift reads these and owns the keyboard
    // shortcuts (⌘N, ⌘T, ⌘S, ⌘⇧D, ⌘⌫, ⌘.). On iPadOS, publishing a focused
    // SCENE value from inside a NavigationSplitView detail re-enters the focus
    // arbiter and writes `\.taskActions` multiple times per frame, spinning the
    // main thread until the watchdog kills the app ("FocusedValue update tried
    // to update multiple times per frame", then a silent SIGKILL — no Swift
    // trace). The iPad keyboard-HUD menu entries aren't worth a launch crash;
    // gestures and the `+` button are unaffected. macOS keeps the full menu.
    #if os(macOS)
    return withSnackbar.focusedSceneValue(\.taskActions, TaskActions(
      newTask: { nav.shouldStartCreating = true },
      toggleToday: selection.isEmpty ? nil : toggleTodayForSelected,
      openWhen: selection.isEmpty ? nil : openWhenForSelected,
      openDeadline: selection.isEmpty ? nil : openDeadlineForSelected,
      openMove: selection.isEmpty ? nil : openMoveForSelected,
      toggleComplete: selection.isEmpty ? nil : toggleSelected,
      delete: selection.isEmpty ? nil : deleteSelected,
      clearSchedule: selection.isEmpty ? nil : clearScheduleForSelected,
      editDetails: editDetailsSelectedAction,
      duplicate: duplicateSelectedAction,
      copy: copySelectedAction
    ))
    #else
    // `focusedSceneValue` spins the iPad focus arbiter (see comment above).
    // Modifier shortcuts still register from a zero-size button in the
    // hierarchy — same pattern as the Week dashboard's time-travel keys.
    return withSnackbar
      .background {
        if filter != .recentlyDeleted {
          Group {
            Button("", action: editSelected)
              .keyboardShortcut(TaskRowShortcuts.editDetails)
            Button("", action: copySelected)
              .keyboardShortcut(TaskRowShortcuts.copy)
            Button("", action: duplicateSelected)
              .keyboardShortcut(TaskRowShortcuts.duplicate)
            Button("", action: toggleSelected)
              .keyboardShortcut(TaskRowShortcuts.markComplete)
            Button("", action: toggleTodayForSelected)
              .keyboardShortcut(TaskRowShortcuts.toggleToday)
            Button("", action: openWhenForSelected)
              .keyboardShortcut(TaskRowShortcuts.when)
            Button("", action: openDeadlineForSelected)
              .keyboardShortcut(TaskRowShortcuts.deadline)
            Button("", action: openMoveForSelected)
              .keyboardShortcut(TaskRowShortcuts.move)
            Button("", action: clearScheduleForSelected)
              .keyboardShortcut(TaskRowShortcuts.clearSchedule)
            Button("", action: deleteSelected)
              .keyboardShortcut(TaskRowShortcuts.delete)
          }
          .opacity(0)
          .accessibilityHidden(true)
        }
      }
    #endif
  }

  private var taskList: some View {
    taskListContent
    // Deep task-list rhythm runs denser than the drawer's: task rows read
    // `rowVInset` for their top/bottom padding, tightened here to Things-3
    // density. Drawer/log rows keep the default (airier) `Theme.rowVPadding`.
    // (List styling, the neutral-tint, the paper background + clear-on-tap, and
    // keyboard nav now all live inside `SelectableScrollList`.)
    .environment(\.rowVInset, Theme.rowVPaddingTight)
    .scrollDismissesKeyboard(.interactively)
    .toolbar {
      // Embedded (Project/Area detail) keeps a local "+" on iPhone only; on iPad
      // the window overlay's "+" is always the source of truth.
      #if os(iOS)
      if embedded && filter != .recentlyDeleted && !usesPushNavigation {
        ToolbarItem(placement: .primaryAction) {
          TaskListNewTaskButton()
        }
      }
      #else
      if embedded && filter != .recentlyDeleted {
        ToolbarItem(placement: .primaryAction) {
          TaskListNewTaskButton()
        }
      }
      #endif
    }
    // Unified chrome (docs/PAGE_CHROME_SPEC.md): standalone task lists get the
    // constant gear (→ Settings) and a contextual "+" (new task). On iPad
    // regular the "+" merges with the sidebar's "···" in the tab bar; on iPhone
    // a pushed list shows gear + "+" in its own nav bar.
    .modifier(TaskListStandaloneChrome(embedded: embedded, recentlyDeleted: filter == .recentlyDeleted))
    // (Keyboard navigation — ↑↓ traversal, Return/Space/Esc, focus reclaim —
    // is owned by `SelectableScrollList`; the `+` toolbar button and ⌘N still
    // open the composer via `shouldStartCreating` → `openContextualQuickAdd()`.)
    // Only attach top-level nav chrome on the standalone tab versions.
    // Embedded uses (Project / Area detail wraps) inherit chrome from parent
    // — adding modifiers here would create duplicate back buttons.
    .modifier(TopLevelChromeModifier(showChrome: !embedded))
    .alert("Error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    // Re-load on every appearance so completed tasks (kept visible in-place
    // while the user is on the screen) drop off when they return.
    .onAppear {
      // Refresh the woven calendar agenda SYNCHRONOUSLY on appear so the
      // woven agenda is right on the first frame instead of popping in a
      // beat later when the async load() resolves. This is the fresh-instance
      // case: arriving at Today from a Project/Area page (a different view
      // type) builds a brand-new TaskListView, so `.onChange(of: filter)`
      // never fires and `calendarEvents` would otherwise stay empty until the
      // load lands — a visible layout jump.
      refreshCalendarEvents()
      Task { await load() }
    }
    // CKSyncEngine fires .septenaTasksChanged at the end of every fetch
    // batch — including pushes from other devices and the foreground
    // bootstrap fetch. Without this, the list only refreshes when the
    // view re-appears (i.e. you have to navigate away and back).
    // Debounced: a single mutation can fan out several `.septenaTasksChanged`
    // posts (local save + CK batch + Spotlight). Coalesce like the sidebar.
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)
      .debounce(for: .seconds(0.3), scheduler: RunLoop.main)) { _ in
      Task { await load() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaStructureChanged)
      .debounce(for: .seconds(0.3), scheduler: RunLoop.main)) { _ in
      Task { await load() }
    }
    // EventKit fires this when calendar data changes (an event added/edited in
    // Calendar, a remote calendar sync). Re-read so the woven agenda stays live
    // without leaving and returning to the list. A plain re-fetch — no task load.
    .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
      refreshCalendarEvents()
    }
    // Flipping the opt-in in Settings should land immediately — fetch on, clear
    // off — without waiting for the next load.
    .onChange(of: showCalendarEvents) { _, _ in refreshCalendarEvents() }
    .onChange(of: clock.today) { _, _ in
      guard filter == .today else { return }
      Task { await load() }
    }
    // Filter swaps reuse this same view (no .id(route) at the App level for
    // .filter cases). `items` is a computed property that already returns
    // the right data for `filter` synchronously, so we only need to clear
    // session-scoped state and re-trigger the network refresh.
    .onChange(of: filter) { _, _ in
      sessionDoneIds = []
      settle.cancelAll()
      clearSelection()
      expandedEditId = nil
      draftEditIds = []
      quickAddDraftId = nil
      quickAddDraftAtTop = false
      quickAddGroupTarget = nil
      // Drop any inline edit/quick-add in flight — the buffers belong to the
      // list we're leaving, not the one we're switching to.
      editingTitleId = nil
      titleDraft = ""
      inlineFocus = nil
      // Re-fetch the woven calendar agenda SYNCHRONOUSLY, in the same
      // transaction as the filter change. The view is reused across filter
      // swaps, so without this the body re-renders for the new filter while
      // `calendarEvents` still holds the PREVIOUS filter's events — e.g.
      // Upcoming→Today briefly renders all 30 days of upcoming events as
      // today's agenda, then snaps when the async load() resolves. That stale
      // frame is the "weird rebuild between screens". Mirrors the synchronous
      // correctness the `items`/`storageFilter` getter already gives the rows.
      refreshCalendarEvents()
      Task { await load() }
    }
    // Leaving reorder edit mode drops the selection so nothing stale lingers.
    .onChange(of: isEditMode) { _, editing in
      if !editing { selection.removeAll() }
    }
    // Consume the global "start a new task" trigger (⌘N / + / sidebar menu) by
    // opening the contextual inline quick-add (Inbox on Today, foot line on
    // project/area, composer on Upcoming).
    .onChange(of: nav.shouldStartCreating) { _, _ in
      guard nav.shouldStartCreating else { return }
      nav.shouldStartCreating = false
      openContextualQuickAdd()
    }
    .onAppear {
      if nav.shouldStartCreating {
        nav.shouldStartCreating = false
        openContextualQuickAdd()
      }
    }
    // The composer — used for BOTH create (tab + / ⌘N / sidebar) and edit (row
    // tap / (i) button). The app's standard adaptive edit drawer (sheet on
    // iPhone, inspector on iPad/macOS). Commits through `TaskDraft` so the
    // Things-style scheduled/today/list mapping lives in one place.
    .taskComposerDrawer(isPresented: composerBinding) {
      if let mode = composerMode {
        TaskComposerCard(
          mode: mode,
          areas: areas,
          projects: projects,
          accent: theme.color(for: "tasks"),
          onDone: {
            if case .edit(let task) = mode { repatchTask(id: task.id) }
            Task { await load() }
          }
        )
      }
    }
  }

  /// The drawer composer is Upcoming-only — every other creatable list spawns
  /// a `deferPush` draft and opens the inline expand-in-place editor. EDITING an
  /// existing task expands inline in its row (`expandedEditId`), not here.
  private var composerMode: TaskComposerCard.Mode? {
    if creating { return .create(filter) }
    return nil
  }
  /// True while the create drawer is up. (Editing is inline — see
  /// `expandedEditId` / `listInputActive`.)
  private var composerIsOpen: Bool { creating }
  private var composerBinding: Binding<Bool> {
    Binding(get: { composerIsOpen }, set: { if !$0 { closeComposer() } })
  }
  private func closeComposer() {
    creating = false
  }

  /// Spawn a new task in this list's context and open the Things-style inline
  /// editor on it. Creatable lists insert a local `deferPush` draft (no CloudKit
  /// push until the title commits) at the foot of the list; Upcoming falls back
  /// to the drawer composer.
  private func startCreate(areaId: String? = nil, projectId: String? = nil) {
    guard filter != .recentlyDeleted else { return }
    guard allowsInlineCreate else {
      withAnimation(.snappy(duration: 0.25)) {
        expandedEditId = nil
        creating = true
      }
      return
    }
    if expandedEditId != nil { collapseEdit() }
    inlineFocus = nil
    editingTitleId = nil
    var seed = TaskDraft(filter: filter)
    if let projectId {
      seed.projectId = projectId
      quickAddGroupTarget = .project(projectId)
    } else if let areaId {
      seed.areaId = areaId
      quickAddGroupTarget = .area(areaId)
    } else if filter == .today {
      quickAddGroupTarget = .inbox
    } else {
      quickAddGroupTarget = nil
    }
    let task = seed.create(via: mutator, deferPush: true, atBottom: true)
    draftEditIds.insert(task.id)
    quickAddDraftAtTop = showsQuickAddAtTop
    quickAddDraftId = task.id
    withAnimation(.snappy(duration: 0.22)) {
      items.append(task)
      beginEdit(task)
    }
    scrollToTargetID = Self.quickAddScrollID
    scrollToTargetTick += 1
    AddInfoSection.tasks.notifyTilesChanged()
  }

  /// ⌘N / + / sidebar "New To-Do" — open the list's contextual "New task"
  /// capture row (Inbox on Today, foot line on project/area/unscheduled, composer
  /// on Upcoming). Re-tapping while a capture is already open scrolls back to it.
  private func openContextualQuickAdd() {
    guard filter != .recentlyDeleted else { return }
    if quickAddDraftId != nil {
      scrollToTargetID = Self.quickAddScrollID
      scrollToTargetTick += 1
      return
    }
    if filter == .today && inboxCollapsed {
      withAnimation(.easeInOut(duration: 0.2)) { inboxCollapsed = false }
    }
    switch filter {
    case .area(let id):    startCreate(areaId: id)
    case .project(let id): startCreate(projectId: id)
    default:               startCreate()
    }
  }

  // MARK: - Inline editing

  /// Whether this list accepts an inline quick-add line. Logbook (completed) and
  /// Recently Deleted are read-only histories. Upcoming is excluded too: it's a
  /// multi-day grouped grid with no single target day, so a foot-of-list line
  /// would just dump every capture onto "tomorrow" regardless of context — use
  /// the `+`/⌘N composer there (it lets you pick the day).
  private var allowsInlineCreate: Bool {
    switch filter {
    case .logbook, .recentlyDeleted, .upcoming: return false
    default:                                    return true
    }
  }

  /// Open a task for editing — Things-style expand-in-place on every platform.
  /// The row grows to host the full inline editor (`TaskComposerCard(.inline)`);
  /// folding it autosaves. This works in a `SelectableScrollList` (not a native
  /// `List`) precisely because the container can host an inline-editable
  /// `TextField` on macOS without the List focus/selection corruption.
  private func beginEdit(_ task: SeptenaTask) {
    // Drop any focused quick-add line so its keyboard doesn't fight the editor.
    inlineFocus = nil
    withAnimation(.snappy(duration: 0.22)) {
      selection = [task.id]
      expandedEditId = task.id
    }
  }

  /// Fold the inline editor shut (its `.onDisappear` autosaves). Called by the
  /// editor's close hook (Return-to-save), Esc, and whenever we leave the list.
  ///
  /// Closing KEEPS the just-closed task selected so its row indicator stays put
  /// — the single reliable rule across every close path (Return, Esc, even a
  /// click on empty paper, which would otherwise have cleared the selection a
  /// beat before this runs). The one exception: if the user closed by selecting
  /// a DIFFERENT row, we respect that new selection instead of yanking it back.
  private func collapseEdit(purgingDrafts: Bool = true) {
    let closingId = expandedEditId
    if let closingId { clearQuickAddCaptureSlot(for: closingId) }
    withAnimation(.snappy(duration: 0.22)) {
      expandedEditId = nil
      if let closingId, selection.isEmpty || selection == [closingId] {
        selection = [closingId]
      }
    }
    guard purgingDrafts, let closingId, draftEditIds.contains(closingId) else { return }
    let id = closingId
    draftEditIds.remove(id)
    // Defer one beat so the editor's `.onDisappear` autosave lands first.
    DispatchQueue.main.async { purgeDraftIfEmpty(id: id) }
  }

  /// Drop an inline-create placeholder that never received a title.
  private func purgeDraftIfEmpty(id: String) {
    let trimmed = currentTask(id: id)?.title
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard trimmed.isEmpty else { return }
    clearQuickAddCaptureSlot(for: id)
    mutator.purge(id: id)
    removeLocally(id: id)
    selection.remove(id)
    Task { await load() }
  }

  /// The in-flight capture draft, if any — rendered in the quick-add slot.
  private var quickAddCaptureTask: SeptenaTask? {
    guard let id = quickAddDraftId else { return nil }
    return currentTask(id: id)
  }

  /// Hide a foot/top capture draft from the normal row enumeration — it lives
  /// in `quickAddLine()` until the editor folds.
  private func excludingQuickAddCapture(_ tasks: [SeptenaTask]) -> [SeptenaTask] {
    guard let id = quickAddDraftId else { return tasks }
    return tasks.filter { $0.id != id }
  }

  private func clearQuickAddCaptureSlot(for id: String) {
    guard quickAddDraftId == id else { return }
    quickAddDraftId = nil
    quickAddDraftAtTop = false
    quickAddGroupTarget = nil
  }

  /// True on grouped Today when area / project headers should expose a "+".
  private var showsGroupedHeaderQuickAdd: Bool {
    filter == .today && todayGroupByList && allowsInlineCreate
  }

  /// Inbox foot quick-add: always visible on Today; only hosts the editor when
  /// the capture draft targets Inbox (not a section opened from a header "+").
  private var showsQuickAddInInbox: Bool {
    filter == .today && allowsInlineCreate
  }

  private var quickAddInInboxShowsEditor: Bool {
    guard quickAddDraftId != nil else { return false }
    return quickAddGroupTarget == nil || quickAddGroupTarget == .inbox
  }

  private func showsQuickAddInArea(_ areaId: String) -> Bool {
    guard case .area(let id)? = quickAddGroupTarget else { return false }
    return id == areaId
  }

  private func showsQuickAddInProject(_ projectId: String) -> Bool {
    guard case .project(let id)? = quickAddGroupTarget else { return false }
    return id == projectId
  }

  /// Commit a rename whose field just lost the cursor (keyboard dismissed,
  /// tapped empty space / the quick-add line) — the iOS analog of Esc/Return,
  /// so a half-typed rename is never silently dropped. Row→row switches are
  /// already pre-committed in `beginEdit`, so this only fires for focus leaving
  /// the inline rows entirely.
  private func commitRenameOnFocusLoss(from old: InlineFocus?) {
    guard case .row(let id)? = old, editingTitleId == id,
          inlineFocus != .row(id), let task = currentTask(id: id) else { return }
    commitRename(task)
  }

  /// Commit an in-place rename: write the trimmed title only when it actually
  /// changed and isn't empty, then leave edit mode. An emptied title is treated
  /// as "no change" (we never blank a task by erasing its line) — the row keeps
  /// its old title.
  private func commitRename(_ task: SeptenaTask) {
    let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty && trimmed != task.title {
      mutator.update(id: task.id, title: trimmed)
      patchLocally(id: task.id, title: trimmed)
      Task { await load() }
    }
    endRename()
  }

  /// Abandon an in-place rename without writing (Esc / focus lost with no
  /// commit). The row reverts to its stored title.
  private func endRename() {
    editingTitleId = nil
    if case .row = inlineFocus { inlineFocus = nil }
  }

  /// Move keyboard focus into the quick-add line — retained for call sites that
  /// still route footer gestures through this name; opens the inline editor.
  private func focusNewTask() { startCreate() }

  private var taskListContent: some View {
    // ONE container on every platform: a `SelectableScrollList`
    // (ScrollView/LazyVStack) that re-earns native `List(selection:)`'s
    // selection + keyboard nav while — unlike `List` — letting a row host an
    // inline-editable `TextField` on macOS without corrupting focus/selection.
    // `selection` stays the single source of truth; the neutral capsule is the
    // same `SelectableListRowBackground` the List drew, so rows look identical.
    //   • Mac / iPad: click / ⌘-click / ⇧-click select, ↑↓ traverse, the cursor
    //     row stays on-screen; double-click (Mac) / tap (touch) opens the editor.
    //   • iPhone: tap opens the editor; no selection chrome (`selectable=false`).
    SelectableScrollList(
      selection: $selection,
      orderedIDs: keyboardOrderedTaskIds,
      // Suppress the list's Space/Return/arrows (and reclaim focus on release)
      // whenever a field owns the keyboard: the open composer, an inline rename,
      // or the quick-add line.
      inputActive: listInputActive,
      selectable: usesSelectionModel,
      onActivate: activateRow,
      onToggle: toggleRow,
      onClear: { clearSelection() },
      scrollToTick: scrollToTargetTick,
      scrollToID: scrollToTargetID,
      canvasFill: listCanvasFill,
      iPadTabBarInsetOwnPadding: iPadTabBarInsetOwnPadding,
      wideContentGutter: TaskCardMetrics.margin
    ) {
      taskListHeader
      taskListRows
      // The quick-add line lives in the Inbox section on Today (see
      // `triageSection`). Single-card lists (project / area / triage) tuck it
      // inside the open-task card via `cardedRows(appendQuickAdd:)`. Grouped
      // lists (Anytime) get a foot solo card here instead.
      if showsQuickAddAtFoot && !attachesQuickAddToVisibleCard { quickAddFootCard }
      scopeLoggedSection()
      taskListFooter
    }
    // Commit a rename the moment its field loses the cursor — the iOS analog of
    // Esc/Return (no hardware Esc there). Row→row switches are pre-committed in
    // `beginEdit`; this catches focus going to the quick-add line or to nil.
    .onChange(of: inlineFocus) { old, _ in commitRenameOnFocusLoss(from: old) }
    // Click-away collapses the inline editor (Things-style) — selecting any
    // OTHER row folds the open editor, autosaving it. While editing, the list's
    // arrow keys are suppressed (`listInputActive`), so selection only moves via
    // an explicit click on a different row.
    .onChange(of: selection) { _, sel in
      if let id = expandedEditId, !sel.contains(id) { collapseEdit() }
    }
    #if os(macOS)
    // Esc fallback when the list itself holds focus (the inline field owns Esc
    // while editing — see InlineTaskRow; the container's own Esc handler clears a
    // selection). This catches the in-between: a half-typed rename whose field
    // lost focus, or a focused quick-add line.
    //   editing → COMMIT the rename (safer than cancel) · quick-add → blur.
    .onExitCommand {
      if let id = editingTitleId, let task = currentTask(id: id) { commitRename(task) }
      else if inlineFocus != nil { inlineFocus = nil }
      else { clearSelection() }
    }
    #endif
    #if os(macOS)
    .onCopyCommand {
      guard usesSelectionModel else { return [] }
      let ids = orderedActionIDs()
      guard !ids.isEmpty else { return [] }
      let text = ids.compactMap { currentTask(id: $0)?.title }.joined(separator: "\n")
      guard !text.isEmpty else { return [] }
      return [NSItemProvider(object: text as NSString)]
    }
    #endif
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if usesSelectionModel, selectionScope.isMulti, filter != .recentlyDeleted {
        taskBatchActionBar
      }
    }
  }

  private var taskBatchActionBar: some View {
    HStack(spacing: 16) {
      Text("\(selectionScope.count) selected")
        .font(.septenaMeta)
        .foregroundStyle(Theme.inkSecondary)
      Spacer(minLength: 0)
      Button("Copy") { copyTasks(orderedActionIDs()) }
      Button("Move") { openMoveForSelected() }
      Button("Complete") { toggleSelected() }
      Button("Delete", role: .destructive) { deleteSelected() }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 10)
    .background(.bar)
  }

  /// True while a field/editor owns the keyboard — the composer drawer, an
  /// inline rename in progress, or a focused quick-add/rename line. Drives the
  /// `SelectableScrollList`'s key-suppression + focus-reclaim.
  private var listInputActive: Bool {
    composerIsOpen || expandedEditId != nil || editingTitleId != nil || inlineFocus != nil
  }

  /// iPad split detail: reserve the floating chrome bar on the `ScrollView`
  /// itself (`SelectableScrollList`). Standalone and embedded lists share the
  /// same top inset; only iPhone compact pushed lists opt out (they use nav-bar
  /// chrome instead).
  private var iPadTabBarInsetOwnPadding: CGFloat? {
    #if os(iOS)
    guard usesPushNavigation else { return nil }
    // Title / embedded header rows already pad 12pt from the top.
    return 12
    #else
    return nil
    #endif
  }

  /// Whether the list runs the pointer+keyboard selection model (Mac always;
  /// iPad regular width) or the touch tap-to-edit model (iPhone compact).
  private var usesSelectionModel: Bool {
    #if os(macOS)
    return true
    #else
    return hSize == .regular
    #endif
  }

  /// Return / double-click(Mac) / tap(touch) on a row → open it for editing.
  /// Multi-select has no single primary action, so Return no-ops there.
  private func activateRow(_ id: String) {
    guard selection.count <= 1 else { return }
    guard let task = currentTask(id: id) else { return }
    beginEdit(task)
  }

  /// Space on the cursor row → toggle complete (all selected rows when multi).
  private func toggleRow(_ id: String) {
    let ids = orderedActionIDsForKeyboard(fallback: id)
    for sid in ids {
      guard let task = currentTask(id: sid) else { continue }
      toggle(task)
    }
  }

  private func orderedActionIDsForKeyboard(fallback: String) -> [String] {
    let scoped = orderedActionIDs()
    return scoped.isEmpty ? [fallback] : scoped
  }

  /// True once this filter's data has loaded and there are no rows to show.
  private var showsEmptyTaskList: Bool {
    loadedFilters.contains(filter) && visibleItems.isEmpty && review.isEmpty
      && doneToday.isEmpty && triageItems.isEmpty && !isLoading
  }

  /// Inline quick-add under the title when a creatable list is empty. Today
  /// hosts capture in the Inbox section instead (see `triageSection`).
  private var showsQuickAddAtTop: Bool {
    filter != .today && allowsInlineCreate && (showsEmptyTaskList || quickAddDraftAtTop)
  }

  /// Things-style foot quick-add once the list has content. Today captures
  /// through the Inbox card, not at the foot of the full day list.
  private var showsQuickAddAtFoot: Bool {
    filter != .today && allowsInlineCreate && !showsEmptyTaskList && !quickAddDraftAtTop
  }

  /// Project / area / triage pages render one open-task card — the foot
  /// quick-add belongs inside it, not on the gray canvas below.
  private var attachesQuickAddToVisibleCard: Bool {
    showsQuickAddAtFoot && usesSingleOpenTaskCard
  }

  private var usesSingleOpenTaskCard: Bool {
    switch filter {
    case .project, .area, .triage: return true
    default:                        return false
    }
  }

  @ViewBuilder
  private var taskListHeader: some View {
    titleRow
    todayCalendarRow
    newTodosBannerRow
    remindersRow
    if showsQuickAddAtTop { quickAddTopRow }
    emptyStateRow
  }

  /// The Inbox — the unratified layer (agent proposals + loose captures) —
  /// rendered as a normal section on top of Today, styled exactly like the area
  /// sections below: a `groupHeader` title and standard task rows (checkbox,
  /// swipe, context menu). Triage *is* the normal task interaction — complete,
  /// open to edit, or move/schedule via swipe/menu (each acknowledges an agent
  /// row, clearing it from the Inbox). See docs/TRIAGE_BAND_SPEC.md.
  @ViewBuilder
  private var triageSection: some View {
    // "Inbox" on Today = agent proposals (triageItems, today==false) + loose
    // manually-added tasks (today==true, no project/area). Both are unclassified
    // work — the Inbox header should appear for either source. The quick-add line
    // always lives at the foot of this card (capture drops into the band).
    if filter == .today {
      let looseToday = (items + review).filter {
        $0.project == nil && $0.area == nil && ($0.status == .open || settle.isSettling($0.id))
      }
      let allInbox = excludingQuickAddCapture(triageItems + looseToday)
      if allowsInlineCreate || !allInbox.isEmpty || quickAddDraftId != nil {
        Section {
          if !inboxCollapsed {
            cardedRows(allInbox,
                       quickMenu: { filingSuggestions[$0.id] != nil },
                       appendQuickAdd: showsQuickAddInInbox,
                       quickAddShowsEditor: quickAddInInboxShowsEditor)
          }
        } header: {
          inboxHeader(count: allInbox.count)
        }
      }
    }
  }

  /// Foldable Inbox header — see `foldableSectionHeader`.
  @ViewBuilder
  private func inboxHeader(count: Int) -> some View {
    foldableSectionHeader(icon: "tray.full", title: "Inbox", count: count,
                          isCollapsed: inboxCollapsed) {
      inboxCollapsed.toggle()
    }
  }

  /// A foldable section header — same anatomy as the area `groupHeader` (icon
  /// column, title, hairline) plus a live count and a fold chevron. Tapping
  /// anywhere on it toggles the section. Used by the Inbox on Today.
  @ViewBuilder
  private func foldableSectionHeader(icon: String, title: String, count: Int? = nil,
                                     isCollapsed: Bool, showsHairline: Bool = true,
                                     onToggle: @escaping () -> Void) -> some View {
    #if os(macOS)
    let headerTopPadding: CGFloat = 24
    #else
    let headerTopPadding: CGFloat = 18
    #endif
    Button {
      Haptics.tick()
      withAnimation(.easeInOut(duration: 0.2)) { onToggle() }
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: Theme.iconTextGap) {
          Image(systemName: icon)
            .scaledFont(size: 16)
            .foregroundStyle(Theme.iconMuted)
            .frame(width: Theme.checkboxTap, alignment: .center)
          Text(title)
            .scaledFont(size: Theme.groupHeaderFontSize, weight: .semibold)
            .foregroundStyle(Theme.inkPrimary)
          if let count, count > 0 {
            Text("\(count)")
              .scaledFont(size: Theme.groupHeaderFontSize, weight: .regular)
              .monospacedDigit()
              .foregroundStyle(Theme.inkSecondary)
          }
          Spacer()
          Image(systemName: "chevron.down")
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(Theme.iconMuted)
            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
        }
        // Park the icon column over the carded rows below, exactly like the
        // area/project headers.
        .padding(.leading, TaskCardMetrics.headerLeading)
        .padding(.trailing, TaskCardMetrics.margin)
        .padding(.top, headerTopPadding)
        .padding(.bottom, 8)
        // No hairline — the band's rows sit in a card now, so a rule here would
        // read as the orphaned underline the flat list used to have.
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainHoverRowButtonStyle())
    .textCase(nil)
    .selectionDisabled()
  }

  /// Every task list now rides in grouped cards on the gray canvas — the same
  /// surface as the sidebar / Next homes and every section destination. A flat
  /// single-group list (a project / area / logbook) is simply one card on the
  /// canvas.
  private var listCanvasFill: Color { Theme.groupedBackground }

  @ViewBuilder
  private var taskListRows: some View {
    switch filter {
    case .today:
      triageSection
      if todayGroupByList {
        groupedOpenItems
      } else {
        ungroupedOpenItems
      }
    case .unscheduled:
      reviewRows
      groupedOpenItems
    case .upcoming:
      reviewRows
      groupedUpcomingItems
    case .recentlyDeleted:
      visibleRows
    default:
      reviewRows
      visibleRows
    }
  }

  // Bottom breathing room + a tap-to-dismiss target for empty space. The
  // floating keyboard accessory / batch bar are `.safeAreaInset`s, so the
  // scroll content already insets for them while editing — this is just a
  // tidy end-of-list margin, not the 240pt dead-zone it used to be.
  private var taskListFooter: some View {
    Color.clear
      .frame(minHeight: 96)
      .contentShape(Rectangle())
      // A single tap on the empty space below the list clears the selection;
      // a double-click in that blank space drops the cursor onto the quick-add
      // line (the macOS "double-click empty space to add" affordance).
      #if os(macOS)
      .simultaneousGesture(TapGesture(count: 2).onEnded { startCreate() })
      .simultaneousGesture(TapGesture(count: 1).onEnded { clearSelection() })
      #else
      .onTapGesture { clearSelection() }
      #endif
      .asListRow()
  }

  @ViewBuilder
  private var titleRow: some View {
    if !embedded {
      // The title IS the navigation dropdown (Things-style): tapping it opens
      // the full destination menu so you can jump anywhere without the sidebar.
      // The menu trigger is intrinsic-width; the Spacer fills the row so the
      // title stays left-aligned without widening the dropdown to full width.
      HStack(spacing: 0) {
        TaskNavMenu {
          ScreenTitleMenuLabel(icon: titleIcon, iconTint: titleTint, title: filter.title)
        }
        Spacer(minLength: 0)
      }
      .plainListChrome()
    } else {
      embeddedHeader()
        .plainListChrome()
    }
  }

  @ViewBuilder
  private var newTodosBannerRow: some View {
    if filter == .today && !rolledInReview.isEmpty && !newTodosDismissed {
      newTodosBanner(count: rolledInReview.count)
        .plainListChrome()
    }
  }

  @ViewBuilder
  private var remindersRow: some View {
    if filter == .today {
      // Pending Apple Reminders are unratified captures too — surface them in
      // the triage zone on Today, but only when something's actually pending
      // (no setup CTAs here, so an unconfigured user sees nothing).
      RemindersInboxSection(onImported: { Task { await load() } }, showsSetupCTAs: false)
        .plainListChrome()
    }
  }

  @ViewBuilder
  private var emptyStateRow: some View {
    // Today with an empty day still shows the Inbox card + quick-add — no
    // redundant "Nothing here yet" under it.
    if showsEmptyTaskList && !(filter == .today && allowsInlineCreate) {
      if filter == .recentlyDeleted {
        ContentUnavailableView(
          "No Recently Deleted Tasks",
          systemImage: titleIcon,
          description: Text("Deleted tasks appear here for 30 days before being permanently removed.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .plainListChrome()
      } else {
        ContentUnavailableView(
          "Nothing here yet",
          systemImage: titleIcon,
          description: Text(
            showsQuickAddAtTop
              ? "Type above to add your first task."
              : "Tap + or double-click below to add a task."
          )
        )
        .frame(maxWidth: .infinity)
        .padding(.top, showsQuickAddAtTop ? 24 : 40)
        .plainListChrome()
      }
    }
  }

  private var reviewRows: some View {
    cardedRows(review)
  }

  private var visibleRows: some View {
    cardedRows(visibleItems,
               quickMenu: { filingSuggestions[$0.id] != nil },
               appendQuickAdd: attachesQuickAddToVisibleCard)
  }

  /// Things-style footer on project / area pages: a quiet link that expands
  /// completed tasks for this list. Reuses `row(_:)` so checkboxes and context
  /// menus match the open list.
  @ViewBuilder
  private func scopeLoggedSection() -> some View {
    if scopeLoggedFilterId != nil, !loggedScopeItems.isEmpty {
      scopeLoggedToggleRow
      if isScopeLoggedExpanded {
        cardedRows(loggedScopeItems)
      }
    }
  }

  private var scopeLoggedToggleLabel: String {
    let count = loggedScopeItems.count
    if isScopeLoggedExpanded {
      return String(localized: "Hide \(count) logged items",
                    comment: "Project/area footer — collapse completed tasks (plural)")
    }
    return String(localized: "Show \(count) logged items",
                  comment: "Project/area footer — expand completed tasks (plural)")
  }

  private var scopeLoggedToggleRow: some View {
    Button {
      toggleScopeLoggedExpanded()
    } label: {
      Text(scopeLoggedToggleLabel)
        .font(.septenaMeta)
        .monospacedDigit()
        .foregroundStyle(Theme.inkSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.hPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    .buttonStyle(PlainHoverRowButtonStyle())
    .asListRow()
  }

  /// Active project ids belonging to `areaId` — filing scope on area pages.
  private func childProjectIds(in areaId: String) -> Set<String> {
    Set(projects.filter { $0.area == areaId && $0.status == .active }.map(\.id))
  }

  /// Existing deadline for a target task, so the picker sheet can
  /// pre-fill its date and show "Update Deadline" / "Remove Deadline".
  private func currentDeadline(for id: String?) -> Date? {
    guard let id else { return nil }
    let pool = items + review + doneToday
    return pool.first(where: { $0.id == id })?.deadline.flatMap(SeptenaDate.parse)
  }

  /// Existing scheduled date for a target task, so the picker sheet can
  /// pre-fill its date and show "Update Date" / "No Date".
  private func currentScheduled(for id: String?) -> Date? {
    guard let id else { return nil }
    let pool = items + review + doneToday
    return pool.first(where: { $0.id == id })?.scheduled.flatMap(SeptenaDate.parse)
  }

  /// Existing recurrence rule for a target task, so RecurrencePickerSheet
  /// can pre-fill its controls and show "Update Repeat" / "Don't Repeat".
  private func currentRecurrence(for id: String?) -> Recurrence? {
    guard let id else { return nil }
    let pool = items + review + doneToday
    return pool.first(where: { $0.id == id })?.recurrence
  }

  private func currentTask(id: String?) -> SeptenaTask? {
    guard let id else { return nil }
    // Include `triageItems` — the Inbox rows on Today are real, selectable rows
    // but live outside `items`. Omitting them meant a selected Inbox task
    // couldn't be resolved, so keyboard commands fell back to the first row of
    // the first project/area (the "Space/⌘T acts on the wrong task" bug).
    return (triageItems + items + review + doneToday).first(where: { $0.id == id })
  }

  // MARK: - Keyboard navigation

  /// Flat ordered list of task IDs in the same order they're rendered.
  /// Drives ↑/↓ and ⌘↑/⌘↓ traversal.
  private var keyboardOrderedTaskIds: [String] {
    switch filter {
    case .today:
      // Inbox section = agent proposals + loose today tasks, rendered above
      // the main list. Classified tasks follow — grouped or flat per setting.
      let todayPool = items + review
      let looseToday = todayPool.filter { $0.project == nil && $0.area == nil }
      let classified = todayPool.filter { $0.project != nil || $0.area != nil }
      let classifiedIds: [String]
      if todayGroupByList {
        classifiedIds = orderedFromGroupedOpen(pool: classified)
      } else {
        classifiedIds = classified
          .filter { $0.status == .open || settle.isSettling($0.id) }
          .sorted(by: SeptenaTask.compareNextPageOrder)
          .map(\.id)
      }
      return triageItems.map(\.id) + looseToday.map(\.id) + classifiedIds
    case .unscheduled:
      return review.map(\.id) + orderedFromGroupedOpen(pool: items)
    case .upcoming:
      return review.map(\.id) + upcomingBuckets().flatMap { $0.tasks.map(\.id) }
    case .project, .area:
      var ids = review.map(\.id) + visibleItems.map(\.id)
      if isScopeLoggedExpanded {
        ids.append(contentsOf: loggedScopeItems.map(\.id))
      }
      return ids
    default:
      return review.map(\.id) + visibleItems.map(\.id)
    }
  }

  /// Mirrors the rendering order of `groupedOpenItems` so arrow keys traverse
  /// rows in exactly the order the user sees them.
  private func orderedFromGroupedOpen(pool: [SeptenaTask]) -> [String] {
    let byProject = Dictionary(grouping: pool.filter { $0.project != nil },
                               by: { $0.project! })
    let byArea = Dictionary(grouping: pool.filter { $0.project == nil && $0.area != nil },
                            by: { $0.area! })
    let loose = pool.filter { $0.project == nil && $0.area == nil }
    var ids: [String] = loose.map(\.id)
    for area in areas {
      ids.append(contentsOf: (byArea[area.id] ?? []).map(\.id))
      for project in projects.filter({ $0.area == area.id }) {
        ids.append(contentsOf: (byProject[project.id] ?? []).map(\.id))
      }
    }
    for project in projects.filter({ $0.area == nil }) {
      ids.append(contentsOf: (byProject[project.id] ?? []).map(\.id))
    }
    return ids
  }

  /// ⌘R — open the inline editor for the focused row. iPad resolves via
  /// `effectiveSelectionId`; macOS menu command uses explicit selection only.
  private func editSelected() {
    guard expandedEditId == nil, editingTitleId == nil, inlineFocus == nil,
          !composerIsOpen, whenSheet == nil, !showingMoveSheet, !showingRepeatSheet,
          !nav.showQuickFind,
          let id = effectiveSelectionId(),
          let task = currentTask(id: id), task.status != .done
    else { return }
    beginEdit(task)
  }

  #if os(macOS)
  /// The action behind the ⌘R "Edit Details…" menu command. Nil — so the menu
  /// item disables and ⌘R falls through — when a text field / picker sheet is
  /// active or no plain open row is selected. Uses an EXPLICIT selection (not
  /// `effectiveSelectionId`'s first-row fallback).
  private var editDetailsSelectedAction: (() -> Void)? {
    guard expandedEditId == nil, editingTitleId == nil, inlineFocus == nil,
          !composerIsOpen, whenSheet == nil, !showingMoveSheet, !showingRepeatSheet,
          !nav.showQuickFind,
          selection.count == 1,
          let id = selection.first(where: { currentTask(id: $0) != nil }),
          let task = currentTask(id: id), task.status != .done
    else { return nil }
    return { beginEdit(task) }
  }

  /// The action behind the ⌘D "Duplicate" menu command. Nil — so the menu item
  /// disables — while an editor / picker sheet is active, in Recently Deleted,
  /// or when no resolvable row is selected. Uses an EXPLICIT selection (not the
  /// first-row fallback) so ⌘D only ever clones the row the user picked.
  private var duplicateSelectedAction: (() -> Void)? {
    guard expandedEditId == nil, editingTitleId == nil, inlineFocus == nil,
          !composerIsOpen, whenSheet == nil, !showingMoveSheet, !showingRepeatSheet,
          !nav.showQuickFind, filter != .recentlyDeleted,
          !orderedActionIDs().isEmpty
    else { return nil }
    return { duplicate(orderedActionIDs()) }
  }

  private var copySelectedAction: (() -> Void)? {
    guard expandedEditId == nil, editingTitleId == nil, inlineFocus == nil,
          !composerIsOpen, whenSheet == nil, !showingMoveSheet, !showingRepeatSheet,
          !nav.showQuickFind, filter != .recentlyDeleted,
          !orderedActionIDs().isEmpty
    else { return nil }
    return { copyTasks(orderedActionIDs()) }
  }
  #endif

  private func copyTasks(_ ids: [String]) {
    let titles = ids.compactMap { currentTask(id: $0)?.title }
    guard !titles.isEmpty else { return }
    SeptenaPasteboard.copy(titles.joined(separator: "\n"))
    Haptics.tick()
  }

  /// Clone task(s) into brand-new ones (new ids) carrying the same fields.
  private func duplicate(_ ids: [String]) {
    guard !ids.isEmpty else { return }
    Haptics.tick()
    var lastCopyId: String?
    for id in ids {
      guard let task = currentTask(id: id) else { continue }
      let copy = mutator.create(
        title: task.title,
        area: task.area,
        project: task.project,
        scheduled: SeptenaDate.parse(task.scheduled),
        deadline: SeptenaDate.parse(task.deadline),
        today: task.today,
        notes: task.notes
      )
      if let rule = task.recurrence {
        mutator.setRecurrence(id: copy.id, recurrence: rule)
      }
      lastCopyId = copy.id
    }
    guard let lastCopyId else { return }
    Task {
      await load()
      selectOnly(lastCopyId)
    }
  }

  private func toggleSelected() {
    let ids = orderedActionIDs()
    guard !ids.isEmpty else { return }
    for id in ids {
      guard let t = currentTask(id: id) else { continue }
      toggle(t)
    }
  }

  /// Resolve the row a single-target keyboard shortcut should act on: a
  /// selected row when there is one, otherwise the first row in the list
  /// (so the first ⌘T after launch isn't a silent no-op). Sets `selection`
  /// as a side effect so the highlight follows.
  private func effectiveSelectionId() -> String? {
    if let id = selection.first(where: { currentTask(id: $0) != nil }) { return id }
    guard let first = keyboardOrderedTaskIds.first else { return nil }
    selectOnly(first)
    return first
  }

  /// ⌘T — flip the task's "today" flag. Same action as the context-menu
  /// entry, just keyboard-driven on the currently selected row.
  private func toggleTodayForSelected() {
    let ids = orderedActionIDs()
    guard !ids.isEmpty else { return }
    let tasks = ids.compactMap { currentTask(id: $0) }
    guard !tasks.isEmpty else { return }
    if tasks.allSatisfy(\.isOnToday) {
      applyRemoveFromToday(ids)
    } else {
      Haptics.tick()
      promoteToToday(ids.filter { !(currentTask(id: $0)?.isOnToday ?? false) })
      for id in ids { mutator.acknowledge(id: id) }
      Task { await load() }
    }
  }

  /// Context menu / ⌘T "Remove from Today" — clears every arrived Today signal
  /// via the mutator, then drops ratified rows off the in-memory Today buckets
  /// immediately (same pattern as delete's `removeLocally`) before the async
  /// reload lands.
  private func applyRemoveFromToday(_ ids: [String]) {
    Haptics.tick()
    for id in ids {
      mutator.removeFromToday(id: id)
      mutator.acknowledge(id: id)
    }
    if filter == .today {
      func drop(_ list: inout [SeptenaTask]) {
        list.removeAll { ids.contains($0.id) }
      }
      drop(&items); drop(&review); drop(&doneToday)
    }
    Task { await load() }
  }

  /// Pin tasks to Today and play the amber promote flash on each row.
  private func promoteToToday(_ ids: [String]) {
    for id in ids {
      mutator.moveToToday(id: id, today: true)
      promoteFlash.flash(id)
    }
  }

  /// ⌘S — open the When (schedule) picker for the focused row.
  private func openWhenForSelected() {
    let ids = orderedActionIDs()
    guard !ids.isEmpty else { return }
    whenSheet = WhenSheet(taskIds: ids, kind: .scheduled)
  }

  /// ⌘⇧D — open the Deadline picker for the focused row(s).
  private func openDeadlineForSelected() {
    let ids = orderedActionIDs()
    guard !ids.isEmpty else { return }
    whenSheet = WhenSheet(taskIds: ids, kind: .deadline)
  }

  /// ⌘M — open the Move destination picker for the focused row(s).
  private func openMoveForSelected() {
    guard filter != .recentlyDeleted else { return }
    let ids = orderedActionIDs()
    guard !ids.isEmpty else { return }
    moveTargetIds = ids
    showingMoveSheet = true
  }

  /// ⌘⌫ — delete every selected row.
  private func deleteSelected() {
    let ids = orderedActionIDs()
    guard !ids.isEmpty else { return }
    Haptics.warning()
    clearSelection()
    for id in ids { applyDelete(id) }
  }

  /// ⌘. — clear schedule + today, sending the row back to Anytime.
  private func clearScheduleForSelected() {
    let ids = orderedActionIDs()
    guard !ids.isEmpty else { return }
    for id in ids {
      applyWhen(id: id, kind: .scheduled, date: nil)
    }
  }

  private func copySelected() {
    copyTasks(orderedActionIDs())
  }

  /// ⌘D — duplicate the focused row(s).
  private func duplicateSelected() {
    guard filter != .recentlyDeleted else { return }
    duplicate(orderedActionIDs())
  }

  private func applyRecurrence(id: String, rule: Recurrence?) {
    Haptics.tick()
    mutator.setRecurrence(id: id, recurrence: rule)
    Task { await load() }
  }

  private func applyCancel(_ id: String) {
    Haptics.warning()
    // Cancellation settles exactly like completion: the row lingers in place
    // for the beat (struck through + dimmed), then fades out and lives on in
    // the Logbook alongside completed work. Open the settle window BEFORE the
    // status flip so the row stays put while it lingers — see `toggle` for the
    // ordering rationale (the pool filter is `status == .open || isSettling`).
    // The mutator durably enqueues the server-side cancel; if push ultimately
    // fails the next pull will surface server truth.
    settle.schedule(id) {
      motion.run(Theme.Motion.settle) { settle.endSettle(id) }
    }
    motion.run(Theme.Motion.settle) { flipStatus(id: id, to: .cancelled) }
    sessionDoneIds.insert(id)
    mutator.cancel(id: id)
  }

  private func applyDelete(_ id: String) {
    Haptics.warning()
    let title = currentTask(id: id)?.title ?? ""
    // Remove from the visible buckets immediately — the row is filtered
    // from LocalCache via `pendingDeletion`, but the in-memory @State
    // arrays power the current screen and have to be poked separately.
    removeLocally(id: id)
    mutator.delete(id: id)
    // Show undo snackbar (not in the Recently Deleted view — there the
    // gesture is always intentional and Restore is a first-class action).
    guard filter != .recentlyDeleted else { return }
    showToast(title.isEmpty ? "Task deleted" : "\"\(title)\" deleted") {
      mutator.restore(id: id)
      Task { await load() }
    }
  }

  /// Present the bottom snackbar. The overlay's `.task(id:)` owns the
  /// auto-dismiss; this just sets the payload (a fresh id restarts the clock).
  private func showToast(_ message: String, undo: (() -> Void)? = nil) {
    toastStore.show(message, undo: undo)
  }

  /// Persist title/notes from the Details pane. No-op when both fields
  /// match the current task — avoids a spurious round-trip when the user
  /// opens Details just to glance.
  private func applyTitleNotes(id: String, title: String, notes: String) {
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    if let current = currentTask(id: id),
       current.title == trimmed,
       (current.notes ?? "") == notes {
      return
    }
    patchLocally(id: id, title: trimmed, notes: notes)
    mutator.update(id: id, title: trimmed, notes: notes)
    Task { await load() }
  }

  private struct MoveSnapshot {
    let id: String
    let prevArea: String?
    let prevProject: String?
    let wasInTriage: Bool
  }

  private func applyMoveCore(id: String, areaId: String?, projectId: String?) -> MoveSnapshot? {
    guard let task = currentTask(id: id) else { return nil }
    let prevArea = task.area
    let prevProject = task.project
    let wasInTriage = task.isInTriageBand
    let chosenKind: SuggestionEngine.Suggestion.Kind? =
      projectId != nil ? .project : (areaId != nil ? .area : nil)
    let chosenId = projectId ?? areaId
    recordImplicitRejectionIfMismatch(task: task,
                                      chosenKind: chosenKind,
                                      chosenId: chosenId)
    if projectId != nil {
      mutator.moveToProject(id: id, project: projectId)
    } else {
      mutator.moveToArea(id: id, area: areaId)
      mutator.moveToProject(id: id, project: nil)
    }
    mutator.acknowledge(id: id)
    if filter == .today, wasInTriage { promoteFlash.flash(id) }
    return MoveSnapshot(id: id, prevArea: prevArea, prevProject: prevProject, wasInTriage: wasInTriage)
  }

  private func undoMove(_ snapshots: [MoveSnapshot]) {
    for snap in snapshots {
      if let prevProject = snap.prevProject {
        mutator.moveToProject(id: snap.id, project: prevProject)
      } else {
        mutator.moveToArea(id: snap.id, area: snap.prevArea)
        mutator.moveToProject(id: snap.id, project: nil)
      }
      if snap.wasInTriage { mutator.moveToToday(id: snap.id, today: false) }
    }
    Task { await load() }
  }

  private func destinationName(areaId: String?, projectId: String?) -> String {
    projectId.flatMap { pid in projects.first { $0.id == pid }?.title }
      ?? areaId.flatMap { aid in areas.first { $0.id == aid }?.title }
      ?? "No Project"
  }

  private func applyMove(id: String, areaId: String?, projectId: String?) {
    Haptics.tick()
    guard let snap = applyMoveCore(id: id, areaId: areaId, projectId: projectId) else { return }
    Task { await load() }
    let destName = destinationName(areaId: areaId, projectId: projectId)
    showToast("Moved to \(destName)") { undoMove([snap]) }
  }

  private func applyMove(_ ids: [String], areaId: String?, projectId: String?) {
    guard !ids.isEmpty else { return }
    Haptics.tick()
    let snaps = ids.compactMap { applyMoveCore(id: $0, areaId: areaId, projectId: projectId) }
    guard !snaps.isEmpty else { return }
    Task { await load() }
    let destName = destinationName(areaId: areaId, projectId: projectId)
    let message = snaps.count == 1
      ? "Moved to \(destName)"
      : "Moved \(snaps.count) tasks to \(destName)"
    showToast(message) { undoMove(snaps) }
  }

  private func applyMoveToSelection(_ ids: [String], areaId: String?, projectId: String?) {
    applyMove(ids, areaId: areaId, projectId: projectId)
  }

  private func applyWhenToSelection(_ ids: [String], kind: WhenKind, date: Date?) {
    guard !ids.isEmpty else { return }
    for id in ids { applyWhen(id: id, kind: kind, date: date) }
  }

  // MARK: - Row

  /// The unit every list section renders: either the normal selectable row, or
  /// — when this is the task being edited — the inline expand-in-place editor.
  /// The editor is rendered WITHOUT `asTaskRow`'s selection gestures so its
  /// title field / pills receive clicks directly (a selectable wrapper would
  /// intercept them); it's still `.id`-tagged so `ScrollViewReader` can keep it
  /// on-screen as it grows.
  @ViewBuilder
  private func taskRow(_ task: SeptenaTask, quickMenu: Bool = false) -> some View {
    if expandedEditId == task.id {
      expandedEditorRow(task)
    } else {
      row(task, quickMenu: quickMenu)
        .asTaskRow(id: task.id, isSelected: selection.contains(task.id))
    }
  }

  /// The Things-style inline editor that replaces a row while it's open: the
  /// shared `TaskComposerCard` form, hosted `.inline` (no scaffold, no inner
  /// scroll), on a neutral highlighted card. Folding it (Return, opening another
  /// row, leaving the list) autosaves via the card's `.onDisappear`.
  private func expandedEditorRow(_ task: SeptenaTask) -> some View {
    TaskComposerCard(
      mode: .edit(task),
      areas: areas,
      projects: projects,
      accent: theme.color(for: "tasks"),
      presentation: .inline,
      onClose: { collapseEdit() },
      onToggleComplete: { toggle(task) },
      titleMatchID: "edit-title-\(task.id)",
      checkboxMatchID: "edit-checkbox-\(task.id)",
      heroMatchNS: editTitleNS,
      heroMatchIsSource: expandedEditId == task.id,
      showsTodayIndicator: filter != .today,
      onDone: {
        if draftEditIds.contains(task.id) { draftEditIds.remove(task.id) }
        clearQuickAddCaptureSlot(for: task.id)
        repatchTask(id: task.id)
        Task { await load() }
      }
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    // No own card or screen margin: the surrounding `TaskCardChrome` slice paints
    // the card surface + margin (and sets `rowHInset`), so the editor simply
    // expands the row IN PLACE inside the group card instead of floating as a
    // separate rounded box. Vertical inset lives in `TaskComposerCard` (same
    // `rowVInset` as closed rows).
    .id(task.id)
    .transition(.opacity)
    #if os(macOS)
    // Esc folds the editor but LEAVES the task selected — `collapseEdit` only
    // clears `expandedEditId`, never `selection` (which is already [task.id]).
    // Handling it here, on the row that hosts the focused field, intercepts Esc
    // before it reaches the container's `.onExitCommand` (which would clear the
    // selection), so the now-closed task stays highlighted.
    .onExitCommand { collapseEdit() }
    #endif
    .septenaOnRightClick {
      if !selection.contains(task.id) { selectOnly(task.id) }
    }
    .contextMenu { taskContextMenu(for: task) }
  }

  @ViewBuilder
  private func row(_ task: SeptenaTask, quickMenu: Bool = false) -> some View {
    // No swipe actions and no inline "⋯" button on task rows (removed by
    // request — completion is the checkbox; everything else is the deep-press /
    // right-click `.contextMenu`). `quickMenu` still gates the one-tap "file
    // here" suggestion capsule, now threaded into the row as the inboard-most
    // trailing accessory (left of the date) rather than appended at the edge.
    rowContent(task, accessory: quickMenu ? suggestionCapsule(for: task) : nil)
    // Drag a row (or the whole selection) to a sidebar area/project to re-home
    // it. `.draggable` pairs with the sidebar's `.dropDestination(for:)`; the
    // explicit preview is a compact title pill.
    #if os(macOS)
    .draggable(dragPayload(for: task)) {
      let payload = dragPayload(for: task)
      if payload.ids.count > 1 {
        Text("\(payload.ids.count) tasks")
          .scaledFont(size: 13, weight: .medium)
          .lineLimit(1)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      } else {
        Text(task.title)
          .scaledFont(size: 13)
          .lineLimit(1)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      }
    }
    #endif
  }

  /// The one-tap "file here" capsule — same top pick as the context menu's
  /// "Suggested" section (snapshotted in `load()`). Nil when the classifier
  /// has nothing to offer. Tapping files the task + acknowledges.
  private func suggestionCapsule(for task: SeptenaTask) -> AnyView? {
    guard let suggestion = filingChipSuggestion(for: task) else { return nil }
    return AnyView(
      Button {
        applySuggestion(task: task, suggestion: suggestion)
      } label: {
        HStack(spacing: 3) {
          Image(systemName: suggestion.kind == .project ? "number" : "folder")
            .scaledFont(size: 10, weight: .semibold)
          Text(suggestion.title)
            .scaledFont(size: 12, weight: .medium)
            .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.mutedSurface))
        .foregroundStyle(Theme.inkSecondary)
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .inlineHover(capsule: true)
      .fixedSize()
      .accessibilityLabel("File in \(suggestion.title)")
    )
  }

  @ViewBuilder
  private func rowContent(_ task: SeptenaTask, accessory: AnyView? = nil) -> some View {
    if editingTitleId == task.id {
      inlineEditRow(task)
    } else {
      staticRow(task, accessory: accessory)
    }
  }

  /// The canonical closed row — checkbox + title + subtitle/date — plus the
  /// open/select gestures. Tapping it begins an in-place rename (iOS) or selects
  /// (macOS); the full composer is one gesture further (double-click / ⓘ).
  private func staticRow(_ task: SeptenaTask, accessory: AnyView? = nil) -> some View {
    // Suppress the project / area subtitle when the surrounding context already
    // shows it: a project page suppresses both; an area page suppresses area; a
    // Today / Unscheduled group renders project/area cluster headers above each
    // group. Upcoming groups by date, so the chip stays.
    let suppressProject: Bool = {
      switch filter {
      case .project, .unscheduled: return true
      case .today:                 return todayGroupByList
      default:                      return false
      }
    }()
    let suppressArea: Bool = {
      switch filter {
      case .project, .area, .unscheduled: return true
      case .today:                        return todayGroupByList
      default:                           return false
      }
    }()
    return TaskRow(
      task: task,
      accent: theme.color(for: "tasks"),
      areas: areas,
      projects: projects,
      suppressProject: suppressProject,
      suppressArea: suppressArea,
      showsTodayIndicator: filter != .today,
      isListSelected: selection.contains(task.id),
      accessory: accessory,
      titleMatchID: "edit-title-\(task.id)",
      checkboxMatchID: "edit-checkbox-\(task.id)",
      heroMatchNS: editTitleNS,
      heroMatchIsSource: expandedEditId != task.id,
      onToggle: { toggle(task) },
      onTap: nil
    )
    // Fade on insert/removal. The fade only plays inside an animated
    // transaction; every settle-driven removal runs through `motion.run`, so
    // Reduce Motion still gets an instant (un-animated) drop.
    .transition(.opacity)
    // Open + selection gestures live on `selectableScrollRow` (applied via
    // `asTaskRow`): tap → open (touch), single-click → select / double-click →
    // open (Mac). `activateRow` routes "open" to `beginEdit` (the Things-style
    // expand-in-place editor). The checkbox Button consumes its own taps, so
    // tapping it toggles without also opening. Only right-click + the context
    // menu remain row-local.
    .septenaOnRightClick {
      if !selection.contains(task.id) { selectOnly(task.id) }
    }
    .contextMenu { taskContextMenu(for: task) }
  }

  /// In-place title rename — the same row chrome with the title swapped for a
  /// `TextField`. Return / blur commits; Esc (macOS) discards; the ⓘ button
  /// commits then escalates to the full composer for the attributes the line
  /// can't express. Reuses `TaskCheckbox` so the checkbox alignment and the
  /// row metrics match the static row exactly.
  private func inlineEditRow(_ task: SeptenaTask) -> some View {
    InlineTaskRow(
      text: $titleDraft,
      placeholder: "Task name",
      accent: theme.color(for: "tasks"),
      isDone: task.status == .done,
      // Neutral checkbox while editing — the Today-yellow checkbox means
      // "promoted to Today" in other lists, so wearing it here would misread.
      isToday: false,
      focus: $inlineFocus,
      focusValue: .row(task.id),
      showsDetails: true,
      onToggle: { toggle(task) },
      onCommit: { commitRename(task) },
      // Esc commits too (safer than a cancel path that can leave a half-torn-down
      // field with selected text) — it's just another way to finish, like Return
      // or clicking away. `commitRename` writes only if the title actually changed.
      onCancel: { commitRename(task) },
      onOpenDetails: {
        commitRename(task)
        beginEdit(task)
      }
    )
    .transition(.opacity)
    .septenaOnRightClick {
      if !selection.contains(task.id) { selectOnly(task.id) }
    }
    .contextMenu { taskContextMenu(for: task) }
  }

  /// Foot quick-add for grouped lists (Anytime) — its own card on the canvas.
  @ViewBuilder
  private var quickAddFootCard: some View {
    if allowsInlineCreate {
      quickAddLine()
        .asListRow()
        .taskCardChrome(.solo)
    }
  }

  /// Header quick-add when a creatable list is empty (sits above the empty state).
  @ViewBuilder
  private var quickAddTopRow: some View {
    if allowsInlineCreate {
      if usesSingleOpenTaskCard {
        quickAddLine()
          .asListRow()
          .taskCardChrome(.solo)
      } else {
        quickAddLine().asListRow()
      }
    }
  }

  /// Foot/top capture slot — a tappable "New task" row until tapped, then the
  /// same inline editor the trigger would have opened (one row, not two).
  @ViewBuilder
  private func quickAddLine(showsEditor: Bool = true) -> some View {
    if showsEditor,
       let task = quickAddCaptureTask, expandedEditId == task.id {
      taskRow(task)
        .id(Self.quickAddScrollID)
    } else {
      QuickAddTriggerRow(action: { startCreate() })
        .id(Self.quickAddScrollID)
    }
  }

  /// Single source of truth for per-row actions. Used by the per-row
  /// `.contextMenu` AND the batch action bar — `target` selects which.
  /// Folding both callers through here means new actions land in both
  /// surfaces at once.
  @ViewBuilder
  private func rowActionsMenu(target: ActionTarget) -> some View {
    if filter == .recentlyDeleted {
      // Recently Deleted: only Restore and Delete Permanently — no scheduling,
      // no move, no normal task lifecycle actions apply to trashed rows.
      Button {
        for id in target.ids {
          mutator.restore(id: id)
          removeLocally(id: id)
        }
        Task { await load() }
      } label: {
        Label("Restore", systemImage: "arrow.uturn.backward")
      }
      Divider()
      Button(role: .destructive) {
        Haptics.warning()
        for id in target.ids {
          removeLocally(id: id)
          mutator.purge(id: id)
        }
      } label: {
        Label("Delete Permanently", systemImage: "trash")
      }
    } else {
      TaskListRowContextMenu(
        target: target,
        filter: filter,
        rankedSuggestions: rankedSuggestions(for: target),
        onCopy: { target in copyTasks(target.ids) },
        onDuplicate: { target in duplicate(target.ids) },
        onOpenDetail: { task in beginEdit(task) },
        onApplySuggestion: applySuggestion,
        onMoveToToday: { ids, today in
          if today {
            Haptics.tick()
            promoteToToday(ids)
            for id in ids { mutator.acknowledge(id: id) }
            Task { await load() }
          } else {
            applyRemoveFromToday(ids)
          }
        },
        onOpenWhen: { target in
          whenSheet = WhenSheet(taskIds: target.ids, kind: .scheduled)
        },
        onOpenDeadline: { target in
          whenSheet = WhenSheet(taskIds: target.ids, kind: .deadline)
        },
        onOpenMove: { target in
          moveTargetIds = target.ids
          showingMoveSheet = true
        },
        onMoveTo: { target, areaId, projectId in
          Haptics.pick()
          applyMove(target.ids, areaId: areaId, projectId: projectId)
        },
        moveAreas: areas,
        moveTopProjects: projects.filter { $0.area == nil && $0.status == .active },
        onOpenRepeat: { task in
          repeatTargetId = task.id
          showingRepeatSheet = true
        },
        onCancel: { ids in
          for id in ids { applyCancel(id) }
        },
        onDelete: { target in
          Haptics.warning()
          for id in target.ids { applyDelete(id) }
        }
      )
    }
  }

  @ViewBuilder
  private func taskContextMenu(for task: SeptenaTask) -> some View {
    rowActionsMenu(target: actionTarget(for: task))
  }

  /// Ranked filing picks for one open task — single source for the context
  /// menu's "Suggested" section and the one-tap row chip (chip uses `.first`).
  /// Only two flows: Inbox → area/project, and area-direct → child project.
  /// Tasks already filed into a project are never repositioned.
  private func filingRankedSuggestions(for task: SeptenaTask) -> [SuggestionEngine.Suggestion]? {
    guard TaskRowFlags.filingSuggestionsEnabled else { return nil }
    guard task.status == .open else { return nil }
    guard filter != .logbook && filter != .recentlyDeleted else { return nil }
    guard task.project == nil else { return nil }

    // Inbox (triage band): inbox → area or project.
    if task.isInTriageBand {
      if let top = suggestionEngine.topSuggestion(for: task.id) {
        let ranked = suggestionEngine.suggestions[task.id] ?? [top]
        return suggestionAlreadyMatches(task, ranked.first) ? nil : ranked
      }
      guard let s = suggestionEngine.suggest(forText: task.title) else { return nil }
      return suggestionAlreadyMatches(task, s) ? nil : [s]
    }

    // Area page: area-direct → child project only.
    if case .area(let areaId) = filter, task.area == areaId {
      let scope = SuggestionEngine.SuggestionScope.projects(childProjectIds(in: areaId))
      let ranked = suggestionEngine.rankedSuggestions(forText: task.title, scope: scope)
      guard let top = ranked.first else { return nil }
      return suggestionAlreadyMatches(task, top) ? nil : ranked
    }

    return nil
  }

  private func rankedSuggestions(for target: ActionTarget) -> [SuggestionEngine.Suggestion]? {
    guard case let .single(task) = target else { return nil }
    return filingRankedSuggestions(for: task)
  }

  private func suggestionAlreadyMatches(_ task: SeptenaTask,
                                        _ suggestion: SuggestionEngine.Suggestion?) -> Bool {
    guard let suggestion else { return false }
    return (suggestion.kind == .area && task.area == suggestion.id)
      || (suggestion.kind == .project && task.project == suggestion.id)
  }

  // MARK: - Selection
  //
  // `selection` (a Set<String>) is bound to `List(selection:)` on both
  // platforms and is the single source of truth. macOS drives it natively
  // (click / ⌘ / ⇧ / arrows); iOS via native edit mode (EditButton). Every
  // deselect path funnels through `clearSelection` so iOS edit mode can never
  // desync from an empty selection.

  /// Replace the selection with exactly one row. Used by right-click to make the
  /// context-menu target unambiguous; ordinary click / ⌘-click / ⇧-click / ↑↓
  /// selection is now handled natively by `List(selection:)`.
  private func selectOnly(_ id: String) {
    selection = [id]
  }

  /// Deselect everything — the single "clear selection" entry point used by
  /// every deselect path.
  private func clearSelection() {
    selection.removeAll()
    #if os(iOS)
    editMode?.wrappedValue = .inactive
    #endif
  }


  private func applySuggestion(task: SeptenaTask,
                               suggestion: SuggestionEngine.Suggestion) {
    Haptics.tick()
    // Capture the prior filing BEFORE the move so Undo can put it back.
    let prevArea = task.area
    let prevProject = task.project
    let wasInTriage = task.isInTriageBand
    recordImplicitRejectionIfMismatch(task: task,
                                      chosenKind: suggestion.kind,
                                      chosenId: suggestion.id)
    suggestionEngine.clearSuggestion(for: task.id)
    switch suggestion.kind {
    case .area:
      mutator.moveToArea(id: task.id, area: suggestion.id)
    case .project:
      mutator.moveToProject(id: task.id, project: suggestion.id)
    }
    // Filing is engagement — clears the agent cue so the row leaves the Inbox.
    mutator.acknowledge(id: task.id)
    if filter == .today, wasInTriage { promoteFlash.flash(task.id) }
    Task { await load() }

    showToast("Moved to \(suggestion.title)") {
      if let prevProject {
        mutator.moveToProject(id: task.id, project: prevProject)
      } else {
        mutator.moveToArea(id: task.id, area: prevArea)
        mutator.moveToProject(id: task.id, project: nil)
      }
      if wasInTriage { mutator.moveToToday(id: task.id, today: false) }
      Task { await load() }
    }
  }

  /// The one-tap row chip — same top pick as the context menu (snapshotted in `load()`).
  private func filingChipSuggestion(for task: SeptenaTask) -> SuggestionEngine.Suggestion? {
    filingSuggestions[task.id]
  }

  /// Top filing pick for implicit "not this" learning.
  private func topFilingSuggestion(for task: SeptenaTask) -> SuggestionEngine.Suggestion? {
    filingSuggestions[task.id] ?? filingRankedSuggestions(for: task)?.first
  }

  /// Implicit "Not this" — fires when the user moves the task somewhere
  /// other than the engine's top pick (via the menu's alternates, "Other…",
  /// the context menu's Move, or any other path that calls applyMove).
  /// Records the top suggestion as a rejection for this target so similar
  /// future tasks won't pick it.
  private func recordImplicitRejectionIfMismatch(task: SeptenaTask,
                                                 chosenKind: SuggestionEngine.Suggestion.Kind?,
                                                 chosenId: String?) {
    guard let top = topFilingSuggestion(for: task) else { return }
    if let chosenId, top.kind == chosenKind, top.id == chosenId { return }
    let text = [task.title,
                task.notes?.trimmingCharacters(in: .whitespacesAndNewlines)]
      .compactMap { $0?.isEmpty == false ? $0 : nil }
      .joined(separator: ". ")
    suggestionEngine.recordRejection(taskText: text,
                                     targetKind: top.kind,
                                     targetId: top.id)
  }

  // MARK: - List row helpers

  /// Strip List's default insets/separator/background so our rows draw the
  /// way they did inside the old LazyVStack. Applied to every row in the
  /// body and inside grouped helpers.
  @ViewBuilder
  private func sectionHeader(_ text: String) -> some View {
    Text(text)
      .font(.septenaSectionTitle)
      .foregroundStyle(Theme.inkPrimary)
      .padding(.horizontal, Theme.hPadding)
      .padding(.top, Theme.sectionSpacing)
      .padding(.bottom, 6)
  }

  // MARK: - Today open tasks (grouped vs flat)

  /// Classified Today tasks (assigned to an area or project) as one untitled
  /// card — Inbox stays above; each row shows its list as a subtitle.
  @ViewBuilder
  private var ungroupedOpenItems: some View {
    let base = items + review
    let pool = base.filter { $0.status == .open || settle.isSettling($0.id) }
    let classified = pool
      .filter { $0.project != nil || $0.area != nil }
      .sorted(by: SeptenaTask.compareNextPageOrder)
    cardedRows(classified)
  }

  /// Renders `items` clustered by their project (preferred) or area, using
  /// real SwiftUI sections so group titles are headers, not selectable rows.
  @ViewBuilder
  private var groupedOpenItems: some View {
    let base = (filter == .today) ? items + review : items
    // Drop finished rows (completed or cancelled) except those still settling
    // (just checked / just cancelled), so a finished task lingers for the beat
    // then fades — instead of sitting struck through until the next reload.
    let pool = base.filter { $0.status == .open || settle.isSettling($0.id) }
    let byProject = Dictionary(grouping: pool.filter { $0.project != nil },
                               by: { $0.project! })
    let byArea = Dictionary(grouping: pool.filter { $0.project == nil && $0.area != nil },
                            by: { $0.area! })
    let loose = excludingQuickAddCapture(
      pool.filter { $0.project == nil && $0.area == nil }
    )

    // Loose tasks on Today are merged into the Inbox section above (triageSection).
    // For other filters (Unscheduled, Area, etc.) show them headerless as before.
    if filter != .today, !loose.isEmpty {
      cardedRows(loose)
    }

    // Areas in sidebar order: direct-area tasks, then each project's tasks.
    ForEach(areas) { area in
      let areaTasks = byArea[area.id] ?? []
      if !areaTasks.isEmpty {
        Section {
          cardedRows(areaTasks,
                     appendQuickAdd: showsQuickAddInArea(area.id),
                     quickAddShowsEditor: true)
        } header: {
          groupHeader(icon: "square.stack.3d.up.fill",
                      title: area.title,
                      areaEmoji: area.emoji,
                      onTap: { nav.path = [.area(area)] },
                      onAdd: showsGroupedHeaderQuickAdd
                        ? { startCreate(areaId: area.id) } : nil)
        }
      }
      ForEach(projects.filter { $0.area == area.id }) { project in
        if let tasks = byProject[project.id], !tasks.isEmpty {
          Section {
            cardedRows(tasks,
                       appendQuickAdd: showsQuickAddInProject(project.id),
                       quickAddShowsEditor: true)
          } header: {
            groupHeader(icon: nil,
                        title: project.title,
                        projectProgress: progressByProject[project.id],
                        onTap: { nav.path = [.project(project)] },
                        onAdd: showsGroupedHeaderQuickAdd
                          ? { startCreate(projectId: project.id) } : nil)
          }
        }
      }
    }

    // Top-level projects (no area).
    ForEach(projects.filter { $0.area == nil }) { project in
      if let tasks = byProject[project.id], !tasks.isEmpty {
        Section {
          cardedRows(tasks,
                     appendQuickAdd: showsQuickAddInProject(project.id),
                     quickAddShowsEditor: true)
        } header: {
          groupHeader(icon: nil,
                      title: project.title,
                      projectProgress: progressByProject[project.id],
                      onTap: { nav.path = [.project(project)] },
                      onAdd: showsGroupedHeaderQuickAdd
                        ? { startCreate(projectId: project.id) } : nil)
        }
      }
    }
  }

  /// Emit a run of task rows as one continuous grouped card — each row carries a
  /// slice of the card (`TaskCardChrome`), first/last round the outer corners.
  /// Kept a flat `ForEach` (no wrapping container) so every row stays a direct
  /// child of the scroll list and the selection / drag / keyboard wiring is
  /// untouched. The open inline editor takes its slice too, so it expands the row
  /// in place inside the card rather than floating as a separate box.
  @ViewBuilder
  private func cardedRows(_ tasks: [SeptenaTask],
                          quickMenu: ((SeptenaTask) -> Bool)? = nil,
                          appendQuickAdd: Bool = false,
                          quickAddShowsEditor: Bool = true) -> some View {
    let rows = excludingQuickAddCapture(tasks)
    let cardCount = rows.count + (appendQuickAdd ? 1 : 0)
    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, task in
      taskRow(task, quickMenu: quickMenu?(task) ?? false)
        .taskCardChrome(TaskCardPosition(index: idx, count: cardCount),
                        // The open editor keeps the plain card surface (a clean
                        // editing field), not the gray selection fill.
                        isSelected: selection.contains(task.id) && expandedEditId != task.id)
    }
    if appendQuickAdd {
      quickAddLine(showsEditor: quickAddShowsEditor)
        .asListRow()
        .taskCardChrome(TaskCardPosition(index: rows.count, count: cardCount))
    }
  }

  /// Filters applied client-side before rendering:
  /// - `excludeProjectedTasks` keeps the Area page focused on loose work.
  /// - Completed tasks are hidden everywhere (a just-completed row lingers via
  ///   the settle exception below, then fades in place and is gone — it lives
  ///   on in the dedicated Logbook). Only the Logbook view itself keeps them.
  private var visibleItems: [SeptenaTask] {
    // `items` already arrives in manual order (LocalCache orders by
    // `TaskOrder.key`), so we never re-sort here — a task stays exactly where
    // the user dragged it. We only filter: optionally hide project-bucketed
    // rows, and hide historical completions (keeping a just-checked row
    // visible while it settles so it fades in place rather than vanishing).
    var result = items
    if excludeProjectedTasks { result = result.filter { $0.project == nil } }
    if hideHistoricalDone {
      result = result.filter { $0.status == .open || settle.isSettling($0.id) }
    }
    return result
  }

  private var hideHistoricalDone: Bool {
    switch filter {
    // Every open-work list hides done tasks (a just-completed one lingers via
    // the settle exception in `visibleItems`, then fades). Only the Logbook and
    // Recently Deleted — whose whole job is showing finished/trashed tasks — keep them.
    case .project, .area, .unscheduled, .upcoming, .triage: return true
    case .today:
      return !todayShowCompleted
    case .logbook, .recentlyDeleted: return false
    }
  }

  /// Drop target is applied at the callsite (on the outer list cell),
  /// not here — see `row(_:)` comment for why.
  @ViewBuilder
  private func groupHeader(icon: String?,
                           title: String,
                           areaEmoji: String? = nil,
                           projectProgress: Double? = nil,
                           onTap: (() -> Void)? = nil,
                           onAdd: (() -> Void)? = nil) -> some View {
    groupHeaderBody(icon: icon, title: title, areaEmoji: areaEmoji,
                    projectProgress: projectProgress, onTap: onTap, onAdd: onAdd)
      .textCase(nil)
      .selectionDisabled()
  }

  private func groupHeaderBody(icon: String?, title: String,
                               areaEmoji: String? = nil,
                               projectProgress: Double? = nil,
                               onTap: (() -> Void)? = nil,
                               onAdd: (() -> Void)? = nil) -> some View {
    // Same icon column width and same icon→text gap as task rows so
    // every icon sits at one X and every text starts at one X.
    #if os(macOS)
    let headerTopPadding: CGFloat = 24
    let titleLeadingCorrection: CGFloat = -6
    #else
    // Whitespace IS the group break (no hairline). The card below already adds
    // `groupGap` underneath itself, so the header's own top padding sits on top
    // of that — together they give each cluster room to breathe.
    let headerTopPadding: CGFloat = 18
    // Cancel GroupHeaderLabel's internal 6pt leading so the tappable title lands
    // at the same X as task-row text.
    let titleLeadingCorrection: CGFloat = -4
    #endif
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.iconTextGap) {
        if icon == "square.stack.3d.up.fill" {
          // Area dot is intentionally bumped past task-row icon size — it's a
          // section header, not an inline glyph, and the larger circle reads as
          // a chapter marker. A user emoji takes the dot's place.
          AreaIcon(tint: Theme.inkSecondary, diameter: 21, lineWidth: 1.5, emoji: areaEmoji)
            .frame(width: Theme.checkboxTap, alignment: .center)
        } else if icon != nil {
          Image(systemName: icon!)
            .scaledFont(size: 16)
            .foregroundStyle(Theme.iconMuted)
            .frame(width: Theme.checkboxTap, alignment: .center)
        } else {
          ProjectProgressIcon(progress: projectProgress ?? 0, tint: Theme.inkSecondary, diameter: 14)
            .frame(width: Theme.checkboxTap, alignment: .center)
        }
        // Tappable target is JUST the title (+ chevron) — not the whole row.
        // The Spacer keeps the rest of the row visually aligned but inert, so
        // clicks in empty horizontal space don't navigate.
        if let onTap {
          GroupHeaderLabel(title: title, hasChevron: true, action: onTap)
            .padding(.leading, titleLeadingCorrection)
        } else {
          Text(title)
            .scaledFont(size: Theme.groupHeaderFontSize, weight: .semibold)
            .foregroundStyle(Theme.inkPrimary)
        }
        Spacer()
        if let onAdd {
          HeaderQuickAddButton(accessibilityLabel: "Add task to \(title)",
                               action: onAdd,
                               accent: theme.color(for: "tasks"),
                               placement: .scrollGroupHeader,
                               hapticOnTap: true)
        }
      }
      // Park the header's icon column at the same X as the row checkbox below it
      // (card margin + in-card content inset); trailing matches the card margin.
      .padding(.leading, TaskCardMetrics.headerLeading)
      .padding(.trailing, TaskCardMetrics.margin)
      // ~2 lines of whitespace above each project/area cluster header so
      // groups visually break apart in mixed list views (Unscheduled, Today,
      // Upcoming). Without this gap, a header reads as the next row of the
      // previous group instead of the start of a new one.
      .padding(.top, headerTopPadding)
      .padding(.bottom, 8)
      // No hairline beneath cluster headers — a rule over flat ungrouped rows
      // read as an orphaned underline (the list looked "broken"). Things-style:
      // the bold header plus the generous top whitespace is the group break;
      // whitespace separates, not a line.
    }
  }

  // MARK: - Calendar events (woven agenda)

  /// Stable agenda order for a day's events: all-day items first (they frame the
  /// day), then timed events by start. Used by both Today and each Upcoming day.
  private func sortedEvents(_ events: [EKEvent]) -> [EKEvent] {
    events.sorted { a, b in
      if a.isAllDay != b.isAllDay { return a.isAllDay }   // all-day first
      return a.startDate < b.startDate
    }
  }

  /// The day's events as a *single* condensed list row (a tight VStack), not one
  /// list row per event — iOS `List` enforces a ~44pt minimum height per row, so
  /// per-event rows balloon into a very airy block. As one row the internal
  /// spacing is ours, giving the calm, dense Things-style strip.
  @ViewBuilder
  private func calendarEventsBlock(_ events: [EKEvent]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(sortedEvents(events), id: \.calendarRowID) { event in
        CalendarEventRow(event: event, fallback: theme.color(for: "calendar"))
      }
    }
    .asListRow()
  }

  /// The YYYY-MM-DD day keys an event occupies within the Upcoming window —
  /// every day from its start through its end, clamped to [today, today+30].
  /// A single-day or timed event yields one key; a multi-day all-day event
  /// yields one per day it spans, so it repeats down the list like in Calendar.
  private func upcomingDayKeys(for event: EKEvent) -> [String] {
    let cal = Calendar.current
    let today = SeptenaDate.startOfDay(for: clock.today) ?? cal.startOfDay(for: clock.now)
    guard let start = event.startDate,
          let windowEnd = cal.date(byAdding: .day, value: 30, to: today) else { return [] }
    // All-day end dates land on the next day's midnight (exclusive); pull back a
    // moment so a single-day all-day event doesn't bleed onto the following day.
    var endRef = event.endDate ?? start
    if event.isAllDay, endRef == cal.startOfDay(for: endRef) {
      endRef = endRef.addingTimeInterval(-1)
    }
    var day = max(cal.startOfDay(for: start), today)
    let lastDay = min(cal.startOfDay(for: endRef), windowEnd)
    var keys: [String] = []
    while day <= lastDay {
      if let key = SeptenaDate.format(day) { keys.append(key) }
      guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return keys
  }

  /// Today's calendar agenda — quiet text on the gray canvas, tucked directly
  /// under the screen title. White cards are reserved for tasks.
  @ViewBuilder
  private var todayCalendarRow: some View {
    if filter == .today, showCalendarEvents, !calendarEvents.isEmpty {
      calendarEventsBlock(calendarEvents)
        .environment(\.rowHInset, TaskCardMetrics.contentInset)
        .padding(.horizontal, TaskCardMetrics.margin)
        .padding(.bottom, 8)
        .plainListChrome()
    }
  }

  // MARK: - Upcoming grouping (by date)

  /// Buckets upcoming items by their scheduled (or due) date, in the order
  /// dates first appear in `items`. Date headers are non-tappable.
  @ViewBuilder
  private var groupedUpcomingItems: some View {
    let buckets = upcomingBuckets()
    ForEach(buckets, id: \.key) { bucket in
      Section {
        // The day's calendar events frame it first (the agenda), then the tasks
        // scheduled for that day — matching Today, where the agenda sits on top.
        if !bucket.events.isEmpty {
          calendarEventsBlock(bucket.events).taskCardChrome(.solo)
        }
        cardedRows(bucket.tasks)
      } header: {
        groupHeader(icon: "calendar", title: bucket.label)
      }
    }
  }

  private struct DateBucket {
    let key: String        // YYYY-MM-DD
    let label: String
    let tasks: [SeptenaTask]
    let events: [EKEvent]
  }

  /// Buckets the upcoming list by day, merging the **union** of task-days and
  /// calendar event-days so a day with only events (e.g. an all-day "off") still
  /// gets a row — Things-style. Days are sorted ascending (event-only days can
  /// land anywhere among task days, so first-seen order no longer suffices).
  private func upcomingBuckets() -> [DateBucket] {
    let today = clock.today
    var tasksByDay: [String: [SeptenaTask]] = [:]
    for task in items {
      // Drop finished rows (completed or cancelled) except those still
      // settling, so a just-checked / just-cancelled upcoming task lingers for
      // the beat then fades (matches every other open-work list).
      if task.status != .open && !settle.isSettling(task.id) { continue }
      // Bucket on the date that actually places the task in the *future* —
      // Things shows an overdue task under Today, never under its stale past
      // day. A task enters Upcoming on either `scheduled` OR `deadline` being
      // future (see LocalCache `.upcoming`), so a past `scheduled` paired with
      // a future `deadline` must bucket on the deadline, not the elapsed
      // scheduled day. Picking the earliest future of the two keeps it off any
      // past-dated header.
      let key = [task.scheduled, task.deadline]
        .compactMap { $0 }
        .filter { $0 > today }
        .min()
      guard let key else { continue }
      tasksByDay[key, default: []].append(task)
    }

    var eventsByDay: [String: [EKEvent]] = [:]
    if showCalendarEvents {
      for event in calendarEvents {
        // A multi-day event (e.g. an all-day "off" spanning a long weekend)
        // shows on every day it covers, not just its start day.
        for key in upcomingDayKeys(for: event) {
          eventsByDay[key, default: []].append(event)
        }
      }
    }

    let days = Set(tasksByDay.keys).union(eventsByDay.keys).sorted()
    return days.map { key in
      DateBucket(key: key,
                 label: dateHeaderLabel(key),
                 tasks: tasksByDay[key] ?? [],
                 events: eventsByDay[key] ?? [])
    }
  }

  private func dateHeaderLabel(_ ymd: String) -> String {
    guard let date = SeptenaDate.parse(ymd) else { return ymd }
    return SeptenaDate.scheduleHeaderLabel(for: date)
  }

  // MARK: - Keyboard accessory (iOS)

  // MARK: - When picker apply

  private func applyWhen(id: String, kind: WhenKind, date: Date?) {
    Haptics.tick()
    switch kind {
    case .deadline:
      mutator.setDeadline(id: id, date: date)
    case .scheduled:
      // Things-style mapping:
      //   • "Today" → pin to today (today=true), clear any scheduled date.
      //     This makes the task appear under Today's pinned items, not
      //     in the "review/scheduled-past" section.
      //   • Future date → today=false + scheduled=date. Server auto-
      //     surfaces the task on Today when that date arrives.
      //   • Nil ("No Date") → clear both flags.
      if let d = date {
        if Calendar.current.isDateInToday(d) {
          mutator.schedule(id: id, date: nil)
          promoteToToday([id])
        } else {
          mutator.moveToToday(id: id, today: false)
          mutator.schedule(id: id, date: d)
          // Deferring drops the row off Today; confirm where it landed. No
          // Undo — re-opening the When picker is the natural reversal.
          showToast("Deferred to \(SeptenaDate.scheduleHeaderLabel(for: d))")
        }
      } else {
        mutator.schedule(id: id, date: nil)
        mutator.moveToToday(id: id, today: false)
      }
    }
    // Scheduling is engagement — clear the agent cue so a dated proposal leaves
    // the Inbox. No-op for non-agent / already-seen rows.
    mutator.acknowledge(id: id)
    Task { await load() }
  }

  // MARK: - Toggle done

  /// Toggle the checkbox optimistically — flip status in-place so the row
  /// shows checked without disappearing. Server filters out completed tasks
  /// from inbox/today/upcoming/unscheduled views, so they're gone the next
  /// time the screen reloads (which happens when you leave & return).
  private func toggle(_ task: SeptenaTask) {
    let newStatus: TaskStatus = task.status == .done ? .open : .done
    if newStatus == .open { Haptics.tap() }

    // Completion never relocates a row. We open the settle window BEFORE the
    // status flip so the row stays put while it lingers — `settle.isSettling(id)`
    // keeps it visible (see `visibleItems` and the grouped pool) and `load()`
    // preserves settling rows, so the `.septenaTasksChanged` this completion
    // posts can't yank it. After the beat the settle clears and the row fades
    // out IN PLACE and is gone (it lives on in the dedicated Logbook);
    // `endSettle` inside the animated transaction lets that removal play
    // `.transition(.opacity)` and rows below slide up.
    // Uncomplete cancels the pending fade.
    //
    // Order matters: the pool filter is `status != .done || settle.isSettling`.
    // The status flip is an @State mutation wrapped in `withAnimation`, while
    // `settling` lives on the separate @Observable `SettleStore` and commits in
    // its own (un-animated) transaction. If we flipped first, SwiftUI could
    // paint one frame where status == .done but settling == false — the pool
    // would drop the row, the rows below would animate up over the settle beat,
    // then snap back when `settling` lands a frame later. Marking the row
    // settling first means there is no `done && !settling` frame: an open row is
    // always in the pool, and a done-and-settling row is too, so the row never
    // leaves it across the two transactions.
    if newStatus == .done {
      settle.schedule(task.id) {
        motion.run(Theme.Motion.settle) { settle.endSettle(task.id) }
      }
    } else {
      settle.cancel(task.id)
    }

    motion.run(Theme.Motion.settle) { flipStatus(id: task.id, to: newStatus) }

    // Context-scaled completion haptic (see `TaskCelebration`): runs after
    // the flip so "was that the last open Today task?" reads the new state.
    // Only the Today screen can see the whole Today set; elsewhere a
    // today-flagged task settles without claiming to have cleared the day.
    if newStatus == .done {
      let clearedToday = filter == .today
        && !items.contains { $0.status == .open }
        && !review.contains { $0.status == .open }
      TaskCelebration.completed(isToday: task.isOnToday || filter == .today,
                                clearedToday: clearedToday,
                                accent: theme.color(for: "tasks"),
                                logCommit: logCommit)
    }
    if newStatus == .done { sessionDoneIds.insert(task.id) }
    else                  { sessionDoneIds.remove(task.id) }

    if newStatus == .done {
      mutator.complete(id: task.id)
    } else {
      mutator.uncomplete(id: task.id)
    }
    // Toggling status is engagement — clear the agent cue. No-ops for
    // non-agent / already-seen rows, so this is safe to call unconditionally.
    mutator.acknowledge(id: task.id)
  }

  /// Mutate the matching task in any of the visible buckets so the row
  /// re-renders with the new status without a server round-trip.
  private func flipStatus(id: String, to newStatus: TaskStatus) {
    func apply(_ list: inout [SeptenaTask]) {
      if let i = list.firstIndex(where: { $0.id == id }) {
        list[i].status = newStatus
      }
    }
    // Include `triageStorage` so checking an Inbox row flips it to done in
    // place; the settle window then keeps it visible (struck-through) until it
    // fades — see `triageItems`.
    apply(&items); apply(&review); apply(&doneToday); apply(&triageStorage)
  }

  /// Drop the matching task from every visible bucket. Paired with
  /// `TaskMutator.delete(...)` — the SwiftData row carries `pendingDeletion`
  /// so LocalCache hides it, but the in-memory @State arrays power the
  /// currently rendered screen and have to be poked separately.
  private func removeLocally(id: String) {
    func drop(_ list: inout [SeptenaTask]) {
      list.removeAll { $0.id == id }
    }
    drop(&items); drop(&review); drop(&doneToday); drop(&triageStorage)
  }

  /// Mutate title/notes on a visible row immediately — the same pattern as
  /// `flipStatus` / `removeLocally`. The mutator + async `load()` still run,
  /// but the closed row must repaint on the very next frame after the inline
  /// editor folds, not after a round-trip through `LocalCache`.
  private func patchLocally(id: String, title: String? = nil, notes: String? = nil) {
    func apply(_ list: inout [SeptenaTask]) {
      guard let i = list.firstIndex(where: { $0.id == id }) else { return }
      if let title { list[i].title = title }
      if let notes { list[i].notes = notes.isEmpty ? nil : notes }
    }
    apply(&items); apply(&review); apply(&doneToday); apply(&triageStorage)
  }

  /// Re-read one task from the local mirror and patch the visible buckets.
  /// Called from composer `onDone` after `persist()` has saved.
  private func repatchTask(id: String) {
    var descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    guard let entity = try? modelContext.fetch(descriptor).first else { return }
    patchLocally(id: id, title: entity.title, notes: entity.notes)
  }

  // MARK: - Load

  /// Merge `fresh` with any row from `prior` that's mid-settle (just checked,
  /// lingering for the fade) but which the fresh read dropped — the Today /
  /// Inbox queries exclude done tasks, and completing one posts
  /// `.septenaTasksChanged`, which reloads us. Without this a completion would
  /// yank its own row before it could fade. Each lingering row is reinserted at
  /// the slot it held in `prior` (anchored after its nearest still-present
  /// predecessor) rather than appended, so it fades out in place instead of
  /// jumping to the bottom — the "moves down" jump we're avoiding. `prior` order
  /// makes earlier insertions valid anchors for adjacent lingering rows. The
  /// settle timer (or a reload / filter swap, which cancels it) clears these
  /// out; we never `cancelAll()` here for the same reason.
  private func preservingSettling(fresh: [SeptenaTask], prior: [SeptenaTask]) -> [SeptenaTask] {
    let freshIDs = Set(fresh.map(\.id))
    let lingering = prior.filter { settle.isSettling($0.id) && !freshIDs.contains($0.id) }
    var merged = fresh
    for task in lingering {
      guard let priorIndex = prior.firstIndex(where: { $0.id == task.id }) else { continue }
      var insertAt = 0
      for i in stride(from: priorIndex - 1, through: 0, by: -1) {
        if let anchor = merged.firstIndex(where: { $0.id == prior[i].id }) {
          insertAt = anchor + 1
          break
        }
      }
      merged.insert(task, at: min(insertAt, merged.count))
    }
    return merged
  }

  /// Ghost-check remote completions: a row that was open on screen a moment ago
  /// and has *just been completed by another device* should animate exactly
  /// like a local tap rather than silently disappear. We route it through the
  /// very same settle window a tap uses — flip the prior row to `.done` (so the
  /// box fills and the title strikes through on the next render; `TaskCheckbox`
  /// replays its visual feel off `isDone`) and open its settle window so it
  /// lingers, then fades out in place. Silent on purpose: we never call
  /// `TaskCelebration`, so a passive sync doesn't buzz the haptics (the feel
  /// itself is haptic-free). Rows the user is mid-settling locally, or already
  /// completed this session, are left alone.
  ///
  /// A just-completed row shows up in the fresh read two different ways, so we
  /// detect both: the drop-done filters (Today / Inbox / Upcoming) make it
  /// *vanish*, while project / area views keep every status, so it's *present
  /// but flipped to done*. The present case is read straight from `fresh` in
  /// memory; only the vanished ids hit the store (they might instead be
  /// deferred / deleted / rescheduled), so an ordinary reload stays a no-op.
  ///
  /// Returns `prior` with the ghosted rows flipped to done (so
  /// `preservingSettling` can re-anchor any that vanished) plus the ids it
  /// ghosted — empty means there's nothing new to animate.
  private func ghostCheckRemoteCompletions(prior: [SeptenaTask], fresh: [SeptenaTask])
    -> (rows: [SeptenaTask], ghosted: Set<String>) {
    let candidates = prior.filter {
      $0.status == .open && !settle.isSettling($0.id) && !sessionDoneIds.contains($0.id)
    }
    guard !candidates.isEmpty else { return (prior, []) }
    let freshByID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var done = Set<String>()
    var vanished = Set<String>()
    for c in candidates {
      if let f = freshByID[c.id] { if f.status == .done { done.insert(c.id) } }
      else { vanished.insert(c.id) }
    }
    if !vanished.isEmpty {
      done.formUnion(LocalCache.completedIDs(among: vanished, in: modelContext))
    }
    guard !done.isEmpty else { return (prior, []) }
    var rows = prior
    for id in done {
      // Same finalize as `toggle()` — `endSettle` inside the animated
      // transaction so the row fades and siblings slide up.
      settle.schedule(id) {
        self.motion.run(Theme.Motion.settle) { self.settle.endSettle(id) }
      }
      sessionDoneIds.insert(id)
      if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].status = .done }
    }
    return (rows, done)
  }

  private func load() async {
    // Cache was already painted in init(); only show the loading state when
    // we have literally nothing to render (first ever launch, cache miss).
    if items.isEmpty { isLoading = true }
    defer { isLoading = false }

    // CloudKit is the only backend. Pull fresh from CK via the engine
    // (its callbacks fold incoming records into SwiftData and post
    // .septenaTasksChanged), then read from the local mirror.
    SeptenaLog.info("[TaskList] load filter=\(String(describing: filter)) route=cloudKit")
    // Do NOT call ckEngine.fetchChanges() here. Fetches are owned by:
    //   • CKEngine.start()              — cold-launch bootstrap
    //   • App.swift scenePhase=active   — foreground refresh
    //   • CKEngine.handleRemoteNotification — silent push
    //   • Settings → "Re-sync to iCloud" — manual recovery
    // Calling fetchChanges() from inside a load() invoked by
    // .onReceive(.septenaTasksChanged) re-enters the delegate while
    // we're still inside applyDidFinishBatch — CKSyncEngine asserts.
    // The mirror is already up to date by the time the notification
    // fires, so a plain re-read is correct.
    let prior = items
    let local = LocalCache.tasks(in: modelContext, filter: filter)
    let ghost = ghostCheckRemoteCompletions(prior: prior, fresh: local)
    let merged = preservingSettling(fresh: local, prior: ghost.rows)
    // Animate only when a remote completion needs the in-place strike+fade;
    // an ordinary reload assigns without a transaction (no spurious motion).
    if ghost.ghosted.isEmpty { items = merged }
    else { motion.run(Theme.Motion.settle) { items = merged } }
    review = []
    doneToday = []
    loadedFilters.insert(filter)
    // Projects + areas live in SwiftData (mirrored by CKSyncEngine), so
    // the local cache is authoritative — no network round-trip needed.
    projects = LocalCache.projects(in: modelContext)
    areas = LocalCache.areas(in: modelContext)
    // Per-project completion ratio for the project pie glyph in mixed-list
    // headers — computed from the full corpus (not the filter-scoped `items`,
    // which omits a project's done rows). Mirrors SidebarView's aggregate.
    do {
      var done: [String: Int] = [:]
      var total: [String: Int] = [:]
      for t in LocalCache.tasksWithProject(in: modelContext) {
        guard let pid = t.project else { continue }
        switch t.status {
        case .done: done[pid, default: 0] += 1; total[pid, default: 0] += 1
        case .open: total[pid, default: 0] += 1
        case .cancelled: break
        }
      }
      progressByProject = total.reduce(into: [:]) { acc, kv in
        acc[kv.key] = Double(done[kv.key] ?? 0) / Double(kv.value)
      }
    }
    // Refresh the inbox suggestion engine from local data. LocalCache
    // returns every status, so the engine sees the full corpus for
    // ranking.
    // Today's triage band gets the richer per-task ranked suggestions; area
    // pages train the model on load so area-direct rows can classify into
    // child projects on demand. Other views never surface filing picks.
    if filter == .today {
      // Re-read the Inbox and merge back any just-checked row that's still
      // settling (the `.triage` query drops done tasks), so an accepted
      // suggestion lingers struck-through and fades in place like every other
      // completed row — same preservation `items` gets above.
      let localTriage = LocalCache.tasks(in: modelContext, filter: .triage)
      let triageGhost = ghostCheckRemoteCompletions(prior: triageStorage,
                                                    fresh: localTriage)
      let mergedTriage = preservingSettling(fresh: localTriage, prior: triageGhost.rows)
      if triageGhost.ghosted.isEmpty { triageStorage = mergedTriage }
      else { motion.run(Theme.Motion.settle) { triageStorage = mergedTriage } }
      // The Inbox lives on the Today view now (the triage rows), so classify
      // the live open rows — that's what powers the one-tap "file here"
      // suggestion chip and the implicit "not this" learning. refresh also
      // primes the model for the composer's on-keystroke suggest().
      if TaskRowFlags.filingSuggestionsEnabled {
        let training = LocalCache.trainingTasks(in: modelContext)
        suggestionEngine.refresh(inbox: localTriage,
                                 allTasks: training,
                                 projects: projects,
                                 areas: areas)
      }
    } else {
      triageStorage = []
    }
    if TaskRowFlags.filingSuggestionsEnabled,
       filter != .today && filter != .logbook && filter != .recentlyDeleted {
      suggestionEngine.prepare(allTasks: LocalCache.trainingTasks(in: modelContext),
                               projects: projects,
                               areas: areas)
    }
    // Snapshot the menu's top filing pick per visible open row so the chip
    // matches the context menu (same `filingRankedSuggestions` path).
    var freshSuggestions: [String: SuggestionEngine.Suggestion] = [:]
    if TaskRowFlags.filingSuggestionsEnabled,
       filter != .logbook && filter != .recentlyDeleted {
      var seen = Set<String>()
      let candidates = (triageItems + items + review).filter {
        ($0.status == .open || settle.isSettling($0.id)) && seen.insert($0.id).inserted
      }
      for t in candidates {
        if let top = filingRankedSuggestions(for: t)?.first {
          freshSuggestions[t.id] = top
        }
      }
    }
    filingSuggestions = freshSuggestions
    // Refresh dismissed state — banner reappears next day automatically.
    if filter == .today {
      let last = UserDefaults.standard.string(forKey: "septena.newTodos.dismissedDate")
      newTodosDismissed = (last == clock.today)
    }
    refreshCalendarEvents()
    SeptenaLog.info("[TaskList] load done count=\(items.count)")
  }

  /// Pull the day's calendar events for the lists that show them (Today,
  /// Upcoming). No-ops to empty when the feature is off, access isn't granted,
  /// or this isn't one of those lists — so the rest of the view can render
  /// straight from `calendarEvents` without re-checking. `CalendarBridge` is
  /// `@MainActor`, same as this method, so the read is a direct call.
  private func refreshCalendarEvents() {
    guard showCalendarEvents,
          filter == .today || filter == .upcoming,
          CalendarBridge.shared.access == .granted
    else {
      if !calendarEvents.isEmpty { calendarEvents = [] }
      return
    }
    calendarEvents = filter == .today
      ? CalendarBridge.shared.remainingTodayEvents()
      : CalendarBridge.shared.upcomingEvents(days: 30)
  }

  // MARK: - New-to-dos banner

  /// Soft-yellow "You have N new to-dos" banner — compact start-of-day
  /// notice that surfaces tasks scheduled for past dates rolling into Today.
  /// Tapping OK persists today's date so it stays dismissed for the rest of
  /// the day; reappears tomorrow.
  @ViewBuilder
  private func newTodosBanner(count: Int) -> some View {
    // Colors lean on system + adapt: a soft yellow tint that reads as
    // attention in light mode and isn't glare-bright in dark mode.
    // Text and button label use Color.primary so contrast follows the
    // user's interface style.
    HStack(spacing: 12) {
      HStack(spacing: 0) {
        Text("You have ")
        Text("\(count)").fontWeight(.bold)
        Text(count == 1 ? " new to-do" : " new to-dos")
      }
      .scaledFont(size: 14)
      .foregroundStyle(.primary)
      Spacer()
      Button {
        Haptics.tick()
        UserDefaults.standard.set(clock.today, forKey: "septena.newTodos.dismissedDate")
        motion.run(.easeOut(duration: 0.2)) { newTodosDismissed = true }
      } label: {
        Text("OK")
          .scaledFont(size: 13, weight: .semibold)
          .foregroundStyle(.primary)
          .padding(.horizontal, 14)
          .padding(.vertical, 6)
          .background(
            Color.yellow.opacity(0.55),
            in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
          )
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      Color.yellow.opacity(0.20),
      in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
    )
    // Match the row selection-pill's effective inset (Theme.hPadding - 6) so
    // the banner and the highlighted row align edge-to-edge.
    .padding(.horizontal, Theme.hPadding - 6)
    .padding(.bottom, 12)
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  // MARK: - Title chrome

  // Canonical destination icon (single source: `Route`), shared with the
  // sidebar smart-list rows and the title dropdown.
  private var titleIcon: String { Route.filter(filter).icon }

  private var titleTint: Color {
    .secondary
  }

}

/// Compact tappable target for area / project section headers inside a list.
/// Wraps just the title (and optional chevron) so the click target matches the
/// visible text rather than the whole row width. Background wash on hover only.
private struct GroupHeaderLabel: View {
  let title: String
  let hasChevron: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title)
          .scaledFont(size: Theme.groupHeaderFontSize, weight: .semibold)
          .foregroundStyle(Theme.inkPrimary)
        if hasChevron {
          Image(systemName: "chevron.right")
            .scaledFont(size: Theme.groupHeaderFontSize - 6, weight: .semibold)
            .foregroundStyle(Theme.iconMuted)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Area/project headers are pointer-only affordances: clickable to drill
    // into the section, but kept OUT of the keyboard focus chain so ↑/↓ and
    // Tab traverse only task rows. Without this, the header Button steals a
    // focus stop between every group.
    .focusable(false)
    .inlineHover(cornerRadius: 6)
  }
}

/// Prominent "+" for creating a task — shared between the local nav toolbar
/// (iPhone / macOS) and the iPad TabView trailing slot.
struct TaskListNewTaskButton: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme

  var body: some View {
    Button {
      SeptenaLog.info("[Create] + button tapped")
      nav.shouldStartCreating = true
    } label: {
      Image(systemName: "plus")
    }
    .buttonStyle(.glassProminent)
    .tint(theme.color(for: "tasks"))
    .accessibilityLabel("New Task")
  }
}

/// Standalone TaskListView (its own tab pane) gets the unified page chrome:
/// the constant gear (→ Settings) plus a contextual "+" (new task) that merges
/// with the sidebar's "···" on iPad regular. Embedded uses (Project/Area detail
/// wraps) inherit the parent's chrome and opt out — they keep a plain local "+".
private struct TaskListStandaloneChrome: ViewModifier {
  @Environment(NavigationState.self) private var nav
  #if os(iOS)
  @Environment(\.usesPushNavigation) private var usesPushNavigation
  #endif
  let embedded: Bool
  let recentlyDeleted: Bool

  func body(content: Content) -> some View {
    #if os(iOS)
    if usesPushNavigation {
      // iPad regular: the Tasks SIDEBAR publishes the window-level chrome
      // (gear/···/+); the detail must NOT also publish (it would clobber the
      // sidebar's entry). The bar inset lives on `SelectableScrollList`'s
      // `ScrollView` via `iPadTabBarInsetOwnPadding`.
      content
    } else if embedded {
      content
    } else {
      content.pageChrome(
        id: "tasks",
        title: "Tasks",
        add: recentlyDeleted ? nil : .action { nav.shouldStartCreating = true }
      )
    }
    #else
    if embedded {
      content
    } else {
      // macOS: the sidebar toolbar has no gear, so the detail provides it.
      content.pageChrome(
        id: "tasks",
        title: "Tasks",
        add: recentlyDeleted ? nil : .action { nav.shouldStartCreating = true }
      )
    }
    #endif
  }
}

/// Encapsulates the standalone-tab nav chrome so we can opt out cleanly
/// when TaskListView is embedded inside a detail page.
private struct TopLevelChromeModifier: ViewModifier {
  let showChrome: Bool

  func body(content: Content) -> some View {
    if showChrome {
      content
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    } else {
      content
    }
  }
}


// Internal so the shared `TaskRowActions` modifier can host the same
// When / Deadline / Move / Repeat picker sheets on the Next surface.
struct TaskListModalPresenter: ViewModifier {
  @Binding var whenSheet: TaskListView.WhenSheet?
  @Binding var showingMoveSheet: Bool
  @Binding var moveTargetIds: [String]
  @Binding var showingRepeatSheet: Bool
  @Binding var repeatTargetId: String?

  let areas: [Area]
  let projects: [Project]
  let currentTask: (String?) -> SeptenaTask?
  let currentScheduled: (String?) -> Date?
  let currentDeadline: (String?) -> Date?
  let currentRecurrence: (String?) -> Recurrence?
  let applyWhen: ([String], TaskListView.WhenKind, Date?) -> Void
  let applyMove: ([String], String?, String?) -> Void
  let applyRecurrence: (String, Recurrence?) -> Void

  func body(content: Content) -> some View {
    content
      .sheet(item: $whenSheet) { sheet in
        let firstId = sheet.taskIds.first
        let bulk = sheet.taskIds.count > 1
        switch sheet.kind {
        case .scheduled:
          DatePickerSheet(
            title: bulk ? "When (\(sheet.taskIds.count) tasks)" : "When",
            initialDate: currentScheduled(firstId),
            setLabel: "Set Date",
            updateLabel: "Update Date",
            clearLabel: "No Date"
          ) { date in
            applyWhen(sheet.taskIds, .scheduled, date)
          }
          .presentationDetents([.height(DatePickerSheet.sheetHeight), .large])
          .presentationBackground(.thinMaterial)
          .presentationCornerRadius(Theme.cornerRadius)
        case .deadline:
          DatePickerSheet(
            title: bulk ? "Deadline (\(sheet.taskIds.count) tasks)" : "Deadline",
            initialDate: currentDeadline(firstId),
            setLabel: "Set Deadline",
            updateLabel: "Update Deadline",
            clearLabel: "Remove Deadline"
          ) { date in
            applyWhen(sheet.taskIds, .deadline, date)
          }
          .presentationDetents([.height(DatePickerSheet.sheetHeight), .large])
          .presentationBackground(.thinMaterial)
          .presentationCornerRadius(Theme.cornerRadius)
        }
      }
      .sheet(isPresented: $showingMoveSheet) {
        let firstId = moveTargetIds.first
        let target = currentTask(firstId)
        MovePickerSheet(
          areas: areas,
          projects: projects,
          currentAreaId: target?.area,
          currentProjectId: target?.project,
          bulkCount: moveTargetIds.count
        ) { areaId, projectId in
          let ids = moveTargetIds
          if !ids.isEmpty {
            applyMove(ids, areaId, projectId)
          }
          moveTargetIds = []
        }
        .presentationDetents([.large, .medium])
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(Theme.cornerRadius)
      }
      .sheet(isPresented: $showingRepeatSheet) {
        RecurrencePickerSheet(initial: currentRecurrence(repeatTargetId)) { rule in
          if let id = repeatTargetId {
            applyRecurrence(id, rule)
          }
          repeatTargetId = nil
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(Theme.cornerRadius)
      }
  }
}

// Internal (shared with `TaskRowActions`) so the Next surface renders the
// exact same per-row task menu as the Tasks list — single source of truth.
struct TaskListRowContextMenu: View {
  let target: TaskListView.ActionTarget
  let filter: TaskFilter
  let rankedSuggestions: [SuggestionEngine.Suggestion]?
  let onCopy: (TaskListView.ActionTarget) -> Void
  let onDuplicate: (TaskListView.ActionTarget) -> Void
  let onOpenDetail: (SeptenaTask) -> Void
  let onApplySuggestion: (SeptenaTask, SuggestionEngine.Suggestion) -> Void
  let onMoveToToday: ([String], Bool) -> Void
  let onOpenWhen: (TaskListView.ActionTarget) -> Void
  let onOpenDeadline: (TaskListView.ActionTarget) -> Void
  let onOpenMove: (TaskListView.ActionTarget) -> Void
  /// Move a task straight to a destination from the inline submenu, skipping the
  /// sheet. `areaId`/`projectId` follow `MovePickerSheet.onPick` semantics
  /// (both nil = Inbox; area only; or a project under its area).
  let onMoveTo: (TaskListView.ActionTarget, _ areaId: String?, _ projectId: String?) -> Void
  /// Destinations surfaced inline. Areas + top-level (no-area) projects only —
  /// a bounded set; projects-under-areas stay behind "More…".
  let moveAreas: [Area]
  let moveTopProjects: [Project]
  let onOpenRepeat: (SeptenaTask) -> Void
  let onCancel: ([String]) -> Void
  let onDelete: (TaskListView.ActionTarget) -> Void

  private var count: Int { target.count }

  var body: some View {
    if case let .single(task) = target {
      Button {
        onOpenDetail(task)
      } label: {
        Label("Edit Details…", systemImage: "info.circle")
      }
      .keyboardShortcut(TaskRowShortcuts.editDetails)

      Button {
        onCopy(target)
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      }

      Divider()
    } else if target.isBulk {
      Button {
        onCopy(target)
      } label: {
        Label("Copy \(count) Titles", systemImage: "doc.on.doc")
      }

      Divider()
    }

    if let rankedSuggestions,
       case let .single(task) = target {
      Section("Suggested") {
        ForEach(Array(rankedSuggestions.enumerated()), id: \.element) { _, suggestion in
          Button {
            onApplySuggestion(task, suggestion)
          } label: {
            Label("Move to \(suggestion.title)",
                  systemImage: suggestion.kind == .area ? "tray" : "folder")
          }
        }
      }
      Divider()
    }

    if todayAction == .remove {
      Button {
        onMoveToToday(target.ids, false)
      } label: {
        Label(todayRemoveLabel, systemImage: "sun.min")
      }
      .keyboardShortcut(TaskRowShortcuts.toggleToday)
    } else if todayAction == .add {
      Button {
        onMoveToToday(target.ids, true)
      } label: {
        Label(todayAddLabel, systemImage: "sun.max.fill")
      }
      .keyboardShortcut(TaskRowShortcuts.toggleToday)
    }

    Button {
      onOpenWhen(target)
    } label: {
      Label(whenLabel, systemImage: "calendar")
    }
    .keyboardShortcut(TaskRowShortcuts.when)

    Button {
      onOpenDeadline(target)
    } label: {
      Label(deadlineLabel, systemImage: "flag")
    }
    .keyboardShortcut(TaskRowShortcuts.deadline)

    Menu {
      Button {
        onMoveTo(target, nil, nil)
      } label: {
        Label("Inbox", systemImage: "tray")
      }
      if !moveAreas.isEmpty || !moveTopProjects.isEmpty {
        Divider()
        ForEach(moveAreas) { area in
          Button {
            onMoveTo(target, area.id, nil)
          } label: {
            if let emoji = area.emoji, !emoji.isEmpty {
              Text("\(emoji)  \(area.title)")
            } else {
              Text(area.title)
            }
          }
        }
        ForEach(moveTopProjects) { project in
          Button {
            onMoveTo(target, nil, project.id)
          } label: {
            Label(project.title, systemImage: "folder")
          }
        }
      }
      Divider()
      Button {
        onOpenMove(target)
      } label: {
        Label("More…", systemImage: "ellipsis")
      }
    } label: {
      Label(moveLabel, systemImage: "folder")
    }
    .keyboardShortcut(TaskRowShortcuts.move)

    if case let .single(task) = target {
      Button {
        onOpenRepeat(task)
      } label: {
        Label("Repeat…", systemImage: "repeat")
      }
    }

    Button {
      onDuplicate(target)
    } label: {
      Label(duplicateLabel, systemImage: "plus.square.on.square")
    }
    .keyboardShortcut(TaskRowShortcuts.duplicate)

    Divider()

    Button {
      onCancel(target.ids)
    } label: {
      Label(cancelLabel, systemImage: "xmark.circle")
    }

    Divider()

    Button(role: .destructive) {
      onDelete(target)
    } label: {
      Label(deleteLabel, systemImage: "trash")
    }
    .keyboardShortcut(TaskRowShortcuts.delete)
  }

  private enum TodayAction { case add, remove }

  private var todayAction: TodayAction? {
    switch target {
    case .single(let task):
      if task.isOnToday { return .remove }
      if filter != .today { return .add }
      return nil
    case .bulk(let tasks):
      if tasks.allSatisfy(\.isOnToday) { return .remove }
      if filter != .today, tasks.contains(where: { !$0.isOnToday }) { return .add }
      return nil
    }
  }

  private var todayAddLabel: String {
    count > 1 ? "Move \(count) to Today" : "Move to Today"
  }

  private var todayRemoveLabel: String {
    count > 1 ? "Remove \(count) from Today" : "Remove from Today"
  }

  private var whenLabel: String {
    count > 1 ? "When… (\(count) tasks)" : "When…"
  }

  private var deadlineLabel: String {
    count > 1 ? "Deadline… (\(count) tasks)" : "Deadline…"
  }

  private var moveLabel: String {
    count > 1 ? "Move \(count) Tasks" : "Move"
  }

  private var duplicateLabel: String {
    count > 1 ? "Duplicate \(count) Tasks" : "Duplicate"
  }

  private var cancelLabel: String {
    count > 1 ? "Cancel \(count) Tasks" : "Cancel Task"
  }

  private var deleteLabel: String {
    count > 1 ? "Delete \(count) Tasks" : "Delete"
  }
}


// MARK: - Focused values for the menu-bar "Task" commands
//
// TaskListView publishes a `TaskActions` value while it's the focused
// scene; the CommandMenu reads it via `@FocusedValue` and exposes each
// action as a real menu item with its keyboard shortcut. This replaces
// the older pattern of attaching hidden `Button(...)`s in `.background()`,
// which gave us shortcuts but no menu visibility.

struct TaskActions {
  var newTask: () -> Void
  var toggleToday: (() -> Void)?
  var openWhen: (() -> Void)?
  var openDeadline: (() -> Void)?
  var openMove: (() -> Void)?
  /// Toggles done/open on the selected row(s) — same handler as Space.
  var toggleComplete: (() -> Void)?
  var delete: (() -> Void)?
  var clearSchedule: (() -> Void)?
  var editDetails: (() -> Void)?
  var duplicate: (() -> Void)?
  var copy: (() -> Void)?
}

private struct TaskActionsKey: FocusedValueKey {
  typealias Value = TaskActions
}

extension FocusedValues {
  var taskActions: TaskActions? {
    get { self[TaskActionsKey.self] }
    set { self[TaskActionsKey.self] = newValue }
  }
}

// MARK: - Grouped-card chrome (sectioned task lists)
//
// On the sectioned lists (Today / Unscheduled) rows ride in rounded cards on the
// gray canvas — the same grouped-card look as the sidebar / Next homes (a flat
// white list read as "broken" once it had section headers, and whitespace alone
// couldn't carry the grouping on the phone). Each row paints a slice of its
// group's card behind itself; only the first/last row in a group round their
// outer corners, so a run of rows reads as ONE continuous card with hairline
// separators between them. The rows are NOT nested in a container — they stay
// direct children of the scroll list, so selection / drag / keyboard nav are
// completely untouched.

enum TaskCardPosition {
  case solo, top, middle, bottom
  init(index: Int, count: Int) {
    if count <= 1            { self = .solo }
    else if index == 0       { self = .top }
    else if index == count-1 { self = .bottom }
    else                     { self = .middle }
  }
}

/// Card geometry, shared by the row chrome, the group headers, and the inline
/// editor so all three line up and match every other grouped page in the app.
enum TaskCardMetrics {
  /// Card margin off the screen edge — the app-wide page gutter (sidebar / Next /
  /// every section destination use this, so the task cards sit at the same X).
  static let margin = Theme.pageGutter
  /// Row content inset INSIDE the card — the same value `DrawerSection` lowers
  /// its rows to, so a task row's checkbox/title sit where a drawer card's do.
  static let contentInset = Theme.Spacing.xl
  static let radius: CGFloat = 14
  /// Leading X of the title column, measured from the card's inner edge.
  static let separatorInset = contentInset + Theme.checkboxTap + Theme.iconTextGap
  /// Leading X of a row's checkbox (and so the group header's icon, which is the
  /// same `checkboxTap`-wide column) from the screen edge: the card margin plus
  /// the in-card content inset. Headers park their icon here so it sits exactly
  /// over the checkbox below.
  static let headerLeading = margin + contentInset
  /// Gap below each card so consecutive cards don't jam together. Headed groups
  /// add their header's top padding on top of this.
  static let groupGap = Theme.Spacing.sm
}

private struct TaskCardChrome: ViewModifier {
  let position: TaskCardPosition
  var isSelected: Bool = false
  @State private var hovered = false

  func body(content: Content) -> some View {
    let r = TaskCardMetrics.radius
    let topR = (position == .top || position == .solo) ? r : 0
    let botR = (position == .bottom || position == .solo) ? r : 0
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: topR, bottomLeadingRadius: botR,
      bottomTrailingRadius: botR, topTrailingRadius: topR,
      style: .continuous)
    content
      // Row content rides at the card's inner inset (matches DrawerSection rows).
      .environment(\.rowHInset, TaskCardMetrics.contentInset)
      .background(alignment: .bottom) {
        ZStack(alignment: .bottom) {
          // The selected row's highlight IS the cell fill — edge-to-edge within
          // the card, taking the card's own corners (only the first/last row
          // round) — so it reads as "this row is selected", not a rounded capsule
          // floating on top of the row.
          shape
            .fill(isSelected ? Theme.listSelectionFill : Theme.cardSurface)
          // Pointer hover — faint background wash only, suppressed while selected.
          if hovered && !isSelected {
            shape.fill(Color.primary.opacity(Theme.pointerHoverOpacity))
          }
          // Hairline between rows, dropped against a selected cell (native lists
          // hide the rule adjacent to the highlight).
          if (position == .top || position == .middle) && !isSelected {
            Rectangle()
              .fill(Theme.border)
              .frame(height: 0.5)
              .padding(.leading, TaskCardMetrics.separatorInset)
          }
        }
      }
      // Card margin off the screen edge (content shifts in with it).
      .padding(.horizontal, TaskCardMetrics.margin)
      // Only the last row of a card carries the gap, so the rows within a card
      // stay flush (one continuous card) while groups separate.
      .padding(.bottom, (position == .bottom || position == .solo) ? TaskCardMetrics.groupGap : 0)
      .onHover { hovered = $0 }
  }
}

extension View {
  func taskCardChrome(_ position: TaskCardPosition, isSelected: Bool = false) -> some View {
    modifier(TaskCardChrome(position: position, isSelected: isSelected))
  }
}

// MARK: - List row chrome helper
//
// Every row we draw inside the List should opt out of the default
// separator / row background / row insets so our existing row composition
// (selection pill, padding, full-bleed action icons) lines up exactly the
// way it did inside the old LazyVStack. Non-task rows also opt out of List
// selection so keyboard traversal lands only on tagged task rows.
// Used in `body` directly and inside the grouping helpers.

extension View {
  // The Tasks list renders in a `SelectableScrollList` (ScrollView/LazyVStack)
  // on EVERY platform now — never a native `List`. That's the only way to host
  // an inline-editable row on macOS without the List focus/selection
  // corruption, and keeping one container across iPhone/iPad/Mac is what makes
  // the editing model "identical components" everywhere. These three helpers
  // therefore drop all the old `List`-cell chrome (separators / row insets /
  // selection suppression) — a LazyVStack row is just a full-width view.

  /// A non-selectable full-bleed row (footer spacer, quick-add line, headers).
  func asListRow() -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
  }

  /// A selectable task row — neutral capsule highlight, `.isSelected` a11y, and
  /// click/tap selection routed through the container (see `selectableScrollRow`).
  func asTaskRow(id: String, isSelected: Bool) -> some View {
    selectableScrollRow(id: id, isSelected: isSelected)
  }

  /// A non-selectable decorative row (section hairlines, banners, empty states).
  func plainListChrome() -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Inline editable task line
//
// The shared atom behind in-place rename rows. The quick-add footer is now a
// separate `QuickAddTriggerRow` that opens the full inline editor.

private struct QuickAddTriggerRow: View {
  let action: () -> Void
  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset

  var body: some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
        TaskCheckbox(isDone: false, dashed: TaskRowFlags.languageV2,
                     isToday: false, onToggle: {})
          .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
        Text("New task")
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, rowHInset)
      .padding(.vertical, rowVInset)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("New task")
  }
}

// MARK: - Inline rename row

private struct InlineTaskRow: View {
  @Binding var text: String
  let placeholder: String
  let accent: Color
  let isDone: Bool
  var isToday: Bool = false
  var dashed: Bool = false
  @FocusState.Binding var focus: TaskListView.InlineFocus?
  let focusValue: TaskListView.InlineFocus
  /// Show the trailing ⓘ Details button (rename rows on iOS use it to escalate
  /// to the full composer; the quick-add line doesn't).
  var showsDetails: Bool = false
  /// Rename rows grow to match wrapped static titles; the quick-add line stays
  /// one row tall (a vertical-axis field reserves blank lines above the placeholder).
  var allowsMultiline: Bool = true
  let onToggle: () -> Void
  let onCommit: () -> Void
  let onCancel: () -> Void
  var onOpenDetails: (() -> Void)? = nil

  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(isDone: isDone, dashed: dashed, isToday: isToday, onToggle: onToggle)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      titleField
        .frame(maxWidth: .infinity, alignment: .leading)

      if showsDetails, let onOpenDetails {
        Button(action: onOpenDetails) {
          Image(systemName: "info.circle")
            .font(.body)
            .foregroundStyle(accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit details")
      }
    }
    .padding(.horizontal, rowHInset)
    .padding(.vertical, rowVInset)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var titleField: some View {
    Group {
      if allowsMultiline {
        TextField(placeholder, text: $text, axis: .vertical)
          .lineLimit(1...4)
      } else {
        TextField(placeholder, text: $text)
          .lineLimit(1)
      }
    }
    .textFieldStyle(.plain)
    .font(.septenaTaskTitle)
    .foregroundStyle(Theme.inkPrimary)
    .focused($focus, equals: focusValue)
    .submitLabel(.done)
    .onSubmit(onCommit)
    #if os(iOS)
    // A vertical-axis TextField wraps long titles (so the editor grows to
    // match the now-multiline static row), but on iOS the Return key inserts
    // a newline instead of firing `.onSubmit`. We want Return to COMMIT, as
    // it did single-line: catch the inserted newline, strip it, and commit.
    // Soft visual wraps don't insert "\n", so only a real Return triggers this.
    .onChange(of: text) { _, newValue in
      guard allowsMultiline, newValue.contains("\n") else { return }
      text = newValue.replacingOccurrences(of: "\n", with: "")
      onCommit()
    }
    #endif
    #if os(macOS)
    // Return saves. `.onSubmit` alone leaks Return to the sidebar (it acts as
    // the NavigationSplitView default action), so we ALSO catch Return as a
    // direct key press on the focused field and CONSUME it (`.handled`) so it
    // commits here and never reaches the sidebar.
    .onKeyPress(.return) { onCommit(); return .handled }
    // Esc finishes the edit via `onCancel` (rename → COMMIT, quick-add →
    // blur) — committing is safer than a discard path. The macOS field
    // editor swallows Esc before `.onExitCommand` fires, so we catch it as a
    // key press on the field (a key text input doesn't consume); this tears
    // the field down, taking its select-all highlight with it. `.onExitCommand`
    // is kept as a redundant fallback (idempotent).
    .onKeyPress(.escape) { onCancel(); return .handled }
    .onExitCommand(perform: onCancel)
    #endif
  }
}
