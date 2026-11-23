import SwiftUI
import SwiftData
import EventKit  // optional calendar agenda woven into Today / Upcoming
import UniformTypeIdentifiers
import CloudKit  // CKAccountStatus for the signed-out empty state
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
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  @Environment(CKEngine.self) private var ckEngine
  @Environment(\.modelContext) private var modelContext
  @Environment(\.a11yMotion) private var motion
  @Environment(\.usesPushNavigation) private var usesPushNavigation
  @Environment(\.scenePhase) private var scenePhase
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
  /// Global switch: show faded tasks inside projects and areas (collapsed
  /// toggleable section starting open when enabled).
  @AppStorage(SettingsKey.tasksShowFaded) private var showFadedInLists: Bool =
    RegistrySettings.Defaults.tasksShowFaded
  /// Things-style grouped Today (area / project sections) vs a single flat
  /// list under Inbox with list subtitles and due-first ordering.
  @AppStorage(SettingsKey.todayGroupByList) private var todayGroupByList: Bool = true
  /// Opt-in: weave the day's calendar events into Today and Upcoming (Things-
  /// style). Only ever populated for those two filters, and only when calendar
  /// access is already granted (Settings → Integrations) — see `load()`.
  @AppStorage(SettingsKey.tasksShowCalendarEvents) private var showCalendarEvents: Bool = RegistrySettings.Defaults.tasksShowCalendarEvents
  #if os(iOS)
  @AppStorage(SettingsKey.tasksSwipeLeadingAction) private var swipeLeadingActionRaw: String = TaskSwipeLeadingAction.today.rawValue
  #endif
  /// The fetched calendar events for the current filter's window. `todayEvents()`
  /// on Today; the next 30 days on Upcoming; empty everywhere else.
  /// The list's derived-data layer (calendar agenda, filing suggestions,
  /// project progress). See `TaskListModel` — concerns move here one at a time
  /// per docs/TASK_LIST_OBSERVATION_PLAN.md.
  @State private var model = TaskListModel()

  // Items are filter-scoped. We store them alongside the
  // filter they correspond to; when the current `filter` doesn't match the
  // stored filter (a section swap just happened, .onChange hasn't run yet),
  // the getters fall back to the SwiftData cache for the *current* filter —
  // so body always reads a value that matches what's on screen. This kills
  // the one-frame "wrong filter's data" / "Nothing here yet" flash that
  // happens when @State lags behind a prop change.
  @State private var itemsStorage: [SeptenaTask] = []
  @State private var triageStorage: [SeptenaTask] = []
  @State private var fadedScopeStorage: [SeptenaTask] = []
  @State private var storageFilter: TaskFilter? = nil
  /// The archive is deliberately incremental: 1,000 completed tasks should
  /// not be decoded, sorted, and rendered just to open the Logbook.
  private static let logbookPageSize = 100
  @State private var logbookLimit = logbookPageSize
  /// A task search can target an older completed row outside the initial
  /// archive page. Expand only for that explicit reveal; normal Logbook opens
  /// keep their bounded, fast materialization path.
  @State private var logbookRevealAll = false

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
    let structure = Self.launchStructure(filter: filter, embedded: embedded)
      ?? StructureCache.snapshot(in: LocalStore.shared.container.mainContext)
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
    let structure = Self.launchStructure(filter: filter, embedded: embedded)
      ?? StructureCache.snapshot(in: LocalStore.shared.container.mainContext)
    _areas = State(initialValue: structure.areas)
    _projects = State(initialValue: structure.projects)
  }

  private var items: [SeptenaTask] {
    get {
      storageFilter == filter
        ? itemsStorage
        : launchSnapshot?.today ?? localTasks()
    }
    nonmutating set {
      itemsStorage = newValue
      storageFilter = filter
    }
  }

  /// The visible archive window. All other filters stay unbounded because
  /// their task sets are actionable lists rather than long-lived history.
  private func localTasks() -> [SeptenaTask] {
    LocalCache.tasks(
      in: modelContext,
      filter: filter,
      limit: filter == .logbook && !logbookRevealAll ? logbookLimit : nil
    )
  }

  // MARK: Launch snapshot (#82, docs/LAUNCH_PERF.md)

  /// Before the first task list frame on a cold launch, standalone Today
  /// reads its rows from the Today snapshot file, not from SwiftData. Same
  /// view, same rows, so the first `load()` swaps to the live list with no
  /// visible change. nil on every other list, after the first frame, and
  /// when the snapshot is from another day.
  private var launchSnapshot: TodaySnapshotStore.Rows? {
    guard filter == .today, !embedded, storageFilter != filter else { return nil }
    return TodaySnapshotStore.launchRows(day: clock.today)
  }

  /// `init` runs before the environment exists, so it checks the day with
  /// `SeptenaDate.today` (what `DayClock` starts with).
  private static func launchStructure(filter: TaskFilter, embedded: Bool)
    -> (areas: [Area], projects: [Project])? {
    guard filter == .today, !embedded,
          let rows = TodaySnapshotStore.launchRows(day: SeptenaDate.today) else { return nil }
    return (rows.areas, rows.projects)
  }

  /// Skeleton rows instead of an empty Today while the account's first pull
  /// has not landed (signed in on a new device). The pre-load frame already
  /// reads the store, so this is the only time Today has nothing to draw and
  /// is still loading. Signed out, offline (a pull error) or an empty
  /// account after the pull: the normal empty Today.
  @ViewBuilder
  private var todaySkeleton: some View {
    if !embedded, visibleItems.isEmpty, triageItems.isEmpty, awaitingFirstPull {
      TaskSkeletonRows().asListRow()
    }
  }

  private var awaitingFirstPull: Bool {
    #if SEPTASK
    let sync = TaskSyncEngine.shared
    return sync.signedIn && sync.since == 0 && sync.lastPull == nil && sync.lastError == nil
    #else
    // Septena Life says "Getting your data" (`emptyStateRow`).
    return false
    #endif
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
      : launchSnapshot?.inbox
        ?? LocalCache.tasks(in: LocalStore.shared.container.mainContext, filter: .triage)
    return base.filter { $0.status == .open || model.settle.isSettling($0.id) }
  }

  @State private var isLoading = false
  @State private var errorMessage: String?
  /// Every user action and sync notification used to schedule its own complete
  /// local-store rebuild. A short generation debounce collapses a burst into
  /// the newest read while keeping optimistic row patches immediate.
  @State private var loadGeneration: UInt = 0
  /// A background refresh (`.septenaTasksChanged` / `.septenaStructureChanged`)
  /// arrived while an inline editor / quick-add / composer owned the keyboard.
  /// Reassigning `items` under an open editor re-diffs the `LazyVStack` and drops
  /// the field's first-responder mid-keystroke (the "type one char, lose focus"
  /// bug — the create that opens the quick-add posts its own change notification
  /// whose debounced reload lands just as you start typing). So we hold the
  /// reload here and run it once the editor folds (`listInputActive` falling
  /// edge), the way Things/Reminders never reshuffle the list while you type.
  @State private var pendingReloadWhileEditing = false


  /// One-shot amber flash when a task is pinned to Today (row wash + checkbox pulse).
  @State private var promoteFlash = PromoteFlashStore()
  @State private var toastStore = SeptenaToastStore()

  /// Scroll anchor for the foot (or empty-list top) "New task" quick-add row.
  private static let quickAddScrollID = "task-quick-add"
  @State private var scrollToTargetID: String?
  @State private var scrollToTargetTick = 0

  /// Unified selection — the single source of truth for the keyboard cursor and
  /// multi-select batch operations. Bound to `SelectableScrollList(selection:)`,
  /// which reproduces the `List(selection:)` contract (click / ⌘-click /
  /// ⇧-click / ↑↓) on a container that can also host the inline editor. NOT a
  /// native `List` — see the header of `SelectableScrollList.swift` for why.
  @State private var selection: Set<String> = []
  #if os(iOS)
  /// Active when the user enters multi-select via swipe-to-select on touch
  /// (`docs/MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md` §4). Kept distinct from
  /// `!selection.isEmpty` so a single iPad trackpad cursor click doesn't flip
  /// taps into multi-select toggles.
  @State private var isTouchSelecting = false
  /// In-window Quick-Drop Project Tray sprung open by hovering a dragged task
  /// stack over the Move button on compact iPhone (Phase M3).
  @State private var showingQuickDropTray = false
  #endif

  private var touchSelectionActive: Bool {
    #if os(iOS)
    isTouchSelecting
    #else
    false
    #endif
  }

  private var allowsTouchMultiSelect: Bool {
    #if os(iOS)
    filter != .recentlyDeleted && expandedEditId == nil
    #else
    false
    #endif
  }

  #if os(iOS)
  /// iOS edit-mode environment key (unavailable on macOS). Vestigial now that
  /// multi-select and manual reorder are gone — kept only so the few remaining
  /// `editMode`-clearing safety calls compile.
  @Environment(\.editMode) private var editMode
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

  /// Drop destinations inside the Today list itself. Sidebar drops are still
  /// handled by `SidebarTaskDrop`; this covers compact iPhone/iPad and the
  /// visible Today groups on regular canvases.
  private enum TodayDropTarget: Equatable {
    case inbox
    case area(String)
    case project(String)
  }
  /// Project section dividers ("headings"). A pending create (into this
  /// project id), a pending rename (this heading), and a pending delete
  /// (this heading, dissolving its members). All routed through standard
  /// `.alert` / `.confirmationDialog` — no inline-TextField-in-List (the macOS
  /// selectable-row focus trap). See docs/ORDERING_AND_HEADINGS_PLAN.md.
  @State private var headingCreateProject: String?
  @State private var headingRenameTarget: SeptenaTask?
  @State private var headingDeleteTarget: SeptenaTask?
  @State private var headingDraftTitle: String = ""
  /// Confirmation target for swipe "Delete Permanently" in Recently Deleted
  /// (`docs/IOS_SWIPE_ACTIONS_SPEC.md` §2 — permanent delete has no undo).
  @State private var permanentDeleteConfirmTask: SeptenaTask?
  /// Pending "Clear Logged…" on a project or area page (issue #208): the
  /// completed ids the logged footer counted when the menu opened, plus the
  /// registry prompt copy that names the page and that exact count.
  @State private var clearLoggedRequest: ClearLoggedRequest?

  private var isSwipeEditModeActive: Bool {
    #if os(iOS)
    return editMode?.wrappedValue.isEditing == true
    #else
    return false
    #endif
  }
  // The title/checkbox hero-glide (`matchedGeometryEffect`) was removed: it
  // ANIMATED the title's position between the closed row and the inline editor,
  // and because a `Text` and a `TextField` never sit at a pixel-identical
  // baseline, that glide is exactly what made the title travel (down-then-up on
  // open, down again on blur). Opening the editor now cross-fades opacity in
  // place — no position animation — so the title cannot move. The residual
  // static `Text`↔`TextField` baseline gap is absorbed by the field's own
  // `.offset` compensation (see `TaskComposerCard.titleField`).

  // Upcoming-only: the multi-day grid has no single list context, so ⌘N / + fall
  // back to the drawer composer (pick a day). Every other creatable list spawns
  // a `deferPush` draft row and opens the inline expand-in-place editor.
  @State private var creating = false

  // MARK: - Inline editing (the Reminders/Things "type-a-line" model)
  //
  // Title editing and quick-create are one behavior: an editable title field.
  // Editing an existing row expands it in place into the shared composer
  // (`expandedEditId`); creating spawns a `deferPush` draft and opens that same
  // inline composer on it. There is no separate in-row rename field — the
  // composer owns title editing on every surface (see `beginEdit` / `startCreate`).

  /// macOS can turn a double-click into "select row" followed by "activate row".
  /// If that selection just closed a different editor, consume the paired
  /// activation so the first click sequence only saves/folds the open editor.
  @State private var suppressActivationAfterSelectionCloseId: String?

  /// True between this list's `onAppear` and `onDisappear`. Several task lists
  /// stay mounted at once (Septask's iPhone tabs, a list under a pushed one), so
  /// the app-global one-shots (`nav.shouldStartCreating`,
  /// `nav.pendingTaskReveal`) are consumed only by the list on screen. A hidden
  /// list used to eat them.
  @State private var isOnScreen = false

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
    var result = items.filter { $0.status == .done && !model.settle.isSettling($0.id) }
    if excludeProjectedTasks { result = result.filter { $0.project == nil } }
    return result.sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
  }
  private func toggleScopeLoggedExpanded() {
    guard let id = scopeLoggedFilterId else { return }
    Haptics.tick()
    var set = scopeLoggedExpandedIds
    if set.contains(id) { set.remove(id) } else { set.insert(id) }
    a11yAnimate(.easeInOut(duration: 0.2)) {
      scopeLoggedExpandedData = (try? JSONEncoder().encode(set)) ?? Data()
    }
  }

  /// Project / area ids whose faded-task section was collapsed by hand.
  /// Starts expanded while `showFadedInLists` is on (mirrors Today's completed
  /// footer: the global setting promises faded tasks are shown).
  @AppStorage("septena.tasks.projectFadedCollapsed") private var scopeFadedCollapsedData: Data = Data()
  private var scopeFadedCollapsedIds: Set<String> {
    (try? JSONDecoder().decode(Set<String>.self, from: scopeFadedCollapsedData)) ?? []
  }
  private var isScopeFadedExpanded: Bool {
    guard let id = scopeLoggedFilterId else { return false }
    return !scopeFadedCollapsedIds.contains(id)
  }
  private var fadedScopeItems: [SeptenaTask] {
    guard showFadedInLists, scopeLoggedFilterId != nil else { return [] }
    if storageFilter == filter { return fadedScopeStorage }
    return LocalCache.fadedTasks(in: modelContext, scope: filter)
  }
  private func toggleScopeFadedExpanded() {
    guard let id = scopeLoggedFilterId else { return }
    Haptics.tick()
    var set = scopeFadedCollapsedIds
    if set.contains(id) { set.remove(id) } else { set.insert(id) }
    a11yAnimate(.easeInOut(duration: 0.2)) {
      scopeFadedCollapsedData = (try? JSONEncoder().encode(set)) ?? Data()
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
  @State private var reminderTargetId: String?
  @State private var tagsTargetIds: [String] = []
  @State private var starredOnlyFilter = false
  @State private var selectedTagIDs: Set<String> = []
  @State private var tagsByID: [String: TaskTag] = [:]
  @State private var checklistCounts: [String: (done: Int, total: Int)] = [:]

  /// Pending Things-style choice when a fixed-schedule repeating task is
  /// moved. The date picker dismisses before this appears, so the decision is
  /// a separate, reliable state transition instead of a race between sheets.
  @State private var reschedulePrompt: FixedReschedulePrompt?

  private struct FixedReschedulePrompt: Identifiable {
    let id: String
    let taskIDs: [String]
    let date: Date?

    init(taskIDs: [String], date: Date?) {
      self.id = "\(taskIDs.joined(separator: ","))|\(SeptenaDate.format(date) ?? "none")"
      self.taskIDs = taskIDs
      self.date = date
    }
  }

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

  /// The scope every task command acts on. Get started steps are list rows
  /// (they take selection, arrows, Return and ⌘K) but never tasks, so their
  /// ids are left out here: move, delete, schedule, copy and the rest find
  /// nothing to act on when only steps are selected.
  private var selectionScope: ListSelectionScope<String> {
    ListSelectionScope(selection: selection.filter { TaskNoticeStep.stepID(fromSelection: $0) == nil },
                       orderedIDs: keyboardOrderedTaskIds)
  }

  /// A task (or the New task line) is selected, not only Get started steps.
  /// Gates the task commands' menu and shortcut entries.
  private var hasTaskSelection: Bool {
    selection.contains { TaskNoticeStep.stepID(fromSelection: $0) == nil }
  }

  /// The selected Get started steps, in list order.
  private var selectedNoticeSteps: [TaskNoticeStep] {
    todayNoticeSteps.filter { selection.contains($0.selectionID) }
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
  /// Per-row top filing suggestion — the "→ Suggested" capsule. Rebuilt by
  /// `refreshFilingSuggestions()` in the second pass of every `load()`, one
  /// frame after the rows publish (docs/LAUNCH_PERF.md). Held in @State (not
  /// read live off the @Observable engine) so the row chip renders reliably.

  /// done / (done + open) per project, mirroring the sidebar's aggregate so the
  /// project pie glyph in mixed-list headers (Today / Unscheduled) reads the
  /// real completion ratio. Cancelled tasks count toward neither side.
  /// Snapshotted in `load()` from the full local corpus, since `items` is
  /// filter-scoped and never holds a project's done rows.

  /// Bumped when a notice is dismissed, so `noticesRow` re-reads
  /// `TaskNotices` (which owns the dismissal state).
  /// Bumped after a dismiss or a ticked checklist step so `cachedTodayNotices`
  /// re-evaluates without running SwiftData queries inside `body`.
  @State private var noticeEpoch = 0
  @State private var cachedTodayNotices: [TaskNotice] = []
  /// Non-nil presents the Weekly Sweep sheet (`docs/TASK_FADE_SPEC.md` §5).
  @State private var sweepSheetTasks: [SeptenaTask]? = nil
  /// Non-nil presents the Plus sheet for this upsell moment (spec §3.2).
  @State private var plusSheetUpsell: String? = nil
  /// One group-title line of space above the logged footer (scales with
  /// Dynamic Type like the titles it matches).
  @ScaledMetric(relativeTo: .headline) private var loggedFooterGap: CGFloat = 34

  var body: some View {
    // Launch signpost (docs/LAUNCH_PERF.md). One-shot: a no-op after the
    // first call, so it costs a lock read on later renders.
    if filter == .today { LaunchTrace.milestone("launch.firstTodayBody") }
    let content = taskList
      .environment(promoteFlash)
      .septenaToastStore(toastStore)
      .modifier(TaskListModalPresenter(
        whenSheet: $whenSheet,
        showingMoveSheet: $showingMoveSheet,
        moveTargetIds: $moveTargetIds,
        showingRepeatSheet: $showingRepeatSheet,
        repeatTargetId: $repeatTargetId,
        reminderTargetId: $reminderTargetId,
        tagsTargetIds: $tagsTargetIds,
        areas: areas,
        projects: projects,
        currentTask: currentTask,
        currentScheduled: currentScheduled,
        currentDeadline: currentDeadline,
        currentRecurrence: currentRecurrence,
        applyWhen: applyWhenToSelection,
        applyMove: applyMoveToSelection,
        applyRecurrence: applyRecurrence,
        applyRecurrencePaused: { id, paused in
          Haptics.tick()
          mutator.setRecurrencePaused(id: id, paused: paused)
          Task { await load() }
        },
        applyReminder: applyReminder
      ))
      .sheet(isPresented: Binding(
        get: { sweepSheetTasks != nil },
        set: { if !$0 { sweepSheetTasks = nil } }
      )) {
        if let tasks = sweepSheetTasks {
          TaskFadeSweepSheet(tasks: tasks, areas: areas, projects: projects) {
            sweepSheetTasks = nil
            noticeEpoch += 1
            Task { await load() }
          }
        }
      }
      #if SEPTASK
      .sheet(isPresented: Binding(
        get: { plusSheetUpsell != nil },
        set: { if !$0 { plusSheetUpsell = nil } }
      )) {
        SeptaskPlusSheet(upsellID: plusSheetUpsell)
      }
      #endif
      .confirmationDialog(
        RegistryPrompts.prompt("rescheduleFixedRepeat").title,
        isPresented: Binding(
          get: { reschedulePrompt != nil },
          set: { if !$0 { reschedulePrompt = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button(RegistryPrompts.prompt("rescheduleFixedRepeat").optionTitle("exception")) {
          guard let prompt = reschedulePrompt else { return }
          reschedulePrompt = nil
          for id in prompt.taskIDs {
            applyScheduledWhen(id: id, date: prompt.date, mode: .makeException)
          }
        }
        Button(RegistryPrompts.prompt("rescheduleFixedRepeat").optionTitle("updateRule")) {
          guard let prompt = reschedulePrompt else { return }
          reschedulePrompt = nil
          for id in prompt.taskIDs {
            applyScheduledWhen(id: id, date: prompt.date, mode: .updateRule)
          }
        }
        Button(RegistryPrompts.cancelTitle, role: .cancel) { reschedulePrompt = nil }
      } message: {
        Text(RegistryPrompts.prompt("rescheduleFixedRepeat").message)
      }
    // A rolled-back save is reported here, on the surface where a lost task is
    // noticed. NOT the snackbar below it: that is a one-line auto-dismissing
    // confirmation with an Undo, and a lost write is neither confirmable nor
    // undoable — a notice the user can miss would just reproduce the original
    // "it silently didn't save" complaint.
    let withSnackbar = content.storeHealthAlert().septenaToastOverlay(store: toastStore)
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
      newTask: { openContextualQuickAdd() },
      toggleToday: !hasTaskSelection ? nil : toggleTodayForSelected,
      openWhen: !hasTaskSelection ? nil : openWhenForSelected,
      openDeadline: !hasTaskSelection ? nil : openDeadlineForSelected,
      openMove: !hasTaskSelection ? nil : openMoveForSelected,
      toggleComplete: selection.isEmpty ? nil : toggleSelected,
      cancel: !hasTaskSelection ? nil : cancelSelected,
      delete: !hasTaskSelection ? nil : deleteSelected,
      clearSchedule: !hasTaskSelection ? nil : clearScheduleForSelected,
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
        if rowCommandShortcutsEnabled {
          // Rendered from the registry (`RegistryActions`, the row commands
          // `TaskActions` serves) so this list can't drift from the macOS
          // menu. The titles are real, which is what the hold-⌘ HUD labels
          // each row with.
          let actions = iPadRowCommandActions
          ForEach(TaskActions.rowCommandIds, id: \.self) { id in
            let action = actions.handler(for: id)
            let title = RegistryActions.title(id)
            if let shortcut = RegistryActions.shortcut(for: id) {
              Button(title) { action?() }
                .keyboardShortcut(shortcut.keyboardShortcut)
                .disabled(action == nil)
              ForEach(Array(shortcut.alternates.enumerated()), id: \.offset) { _, alternate in
                Button(title) { action?() }
                  .keyboardShortcut(alternate.keyboardShortcut)
                  .disabled(action == nil)
              }
            }
          }
          .opacity(0)
          .accessibilityHidden(true)
        }
      }
    #endif
  }

  #if !os(macOS)
  /// The same handler set macOS publishes through `focusedSceneValue`, built
  /// here for the iPad hidden-button path (which exists because publishing a
  /// focused scene value from a split-view detail SIGKILLs iPad — see above).
  private var iPadRowCommandActions: TaskActions {
    TaskActions(
      newTask: { openContextualQuickAdd() },
      toggleToday: !hasTaskSelection ? nil : toggleTodayForSelected,
      openWhen: !hasTaskSelection ? nil : openWhenForSelected,
      openDeadline: !hasTaskSelection ? nil : openDeadlineForSelected,
      openMove: !hasTaskSelection ? nil : openMoveForSelected,
      toggleComplete: selection.isEmpty ? nil : toggleSelected,
      cancel: !hasTaskSelection ? nil : cancelSelected,
      delete: !hasTaskSelection ? nil : deleteSelected,
      clearSchedule: !hasTaskSelection ? nil : clearScheduleForSelected,
      editDetails: editDetailsSelectedAction,
      duplicate: duplicateSelectedAction,
      copy: copySelectedAction
    )
  }
  #endif

  private var showsEmbeddedNewTaskToolbar: Bool {
    #if os(iOS) && SEPTASK
    // Compact iPhone Septena uses the canonical bottom-right Magic Plus orb
    // for creation; top-right stays Search (and Project's overflow menu).
    // Split layouts (iPad / unfolded Duo) have no Magic Plus orb, so embedded
    // Area/Project lists keep the toolbar "+" there.
    embedded && filter != .recentlyDeleted && filter != .faded && usesPushNavigation
    #elseif os(iOS)
    embedded && filter != .recentlyDeleted && filter != .faded && !usesPushNavigation
    #else
    embedded && filter != .recentlyDeleted && filter != .faded
    #endif
  }

  private var taskListChromed: some View {
    taskListContent
    // Deep task-list rhythm runs denser than the drawer's: task rows read
    // `rowVInset` for their top/bottom padding, tightened here to Things-3
    // density. Drawer/log rows keep the default (airier) `Theme.rowVPadding`.
    // (List styling, the neutral-tint, the paper background + clear-on-tap, and
    // keyboard nav now all live inside `SelectableScrollList`.)
    .environment(\.rowVInset, Theme.rowVPaddingTight)
    .scrollDismissesKeyboard(.interactively)
    .modifier(TaskListToolbarChrome(showsEmbeddedNewTask: showsEmbeddedNewTaskToolbar,
                                    onNew: { handleExternalCreateTrigger() }))
    // Unified chrome (docs/PAGE_CHROME_SPEC.md): standalone task lists get the
    // constant gear (→ Settings) and a contextual "+" (new task). On iPad
    // regular the "+" merges with the sidebar's "···" in the tab bar; on iPhone
    // a pushed list shows gear + "+" in its own nav bar.
    .modifier(TaskListStandaloneChrome(embedded: embedded,
                                       recentlyDeleted: filter == .recentlyDeleted || filter == .faded,
                                       onNew: { handleExternalCreateTrigger() }))
    // (Keyboard navigation — ↑↓ traversal, Return/Esc, focus reclaim —
    // is owned by `SelectableScrollList`; the `+` toolbar button and ⌘N still
    // open the composer via `shouldStartCreating` → `openContextualQuickAdd()`.)
    // Only attach top-level nav chrome on the standalone tab versions.
    // Embedded uses (Project / Area detail wraps) inherit chrome from parent
    // — adding modifiers here would create duplicate back buttons.
    .modifier(TopLevelChromeModifier(showChrome: !embedded))
  }

  // The modifier chain is split across `taskListChromed`, `taskListDialogs`,
  // `taskListLoading` and `taskList` so each type-checks in reasonable time (one chain hit
  // the compiler's limit on iOS).
  private var taskListDialogs: some View {
    taskListChromed
    .alert(RegistryPrompts.errorTitle, isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button(RegistryPrompts.errorConfirmTitle, role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    // Section (heading) create — a standard alert TextField, never an inline
    // row field (the macOS selectable-List focus trap). See ORDERING_AND_HEADINGS_PLAN.
    .alert(RegistryPrompts.textPrompt("newSection").title, isPresented: Binding(
      get: { headingCreateProject != nil },
      set: { if !$0 { headingCreateProject = nil } }
    )) {
      TextField(RegistryPrompts.textPrompt("newSection").placeholder, text: $headingDraftTitle)
      Button(RegistryPrompts.textPrompt("newSection").confirmTitle) {
        if let pid = headingCreateProject { commitHeadingCreate(title: headingDraftTitle, project: pid) }
        headingCreateProject = nil
      }
      Button(RegistryPrompts.cancelTitle, role: .cancel) { headingCreateProject = nil }
    }
    .alert(RegistryPrompts.textPrompt("renameSection").title, isPresented: Binding(
      get: { headingRenameTarget != nil },
      set: { if !$0 { headingRenameTarget = nil } }
    )) {
      TextField(RegistryPrompts.textPrompt("renameSection").placeholder, text: $headingDraftTitle)
      Button(RegistryPrompts.textPrompt("renameSection").confirmTitle) {
        if let h = headingRenameTarget { commitHeadingRename(h, title: headingDraftTitle) }
        headingRenameTarget = nil
      }
      Button(RegistryPrompts.cancelTitle, role: .cancel) { headingRenameTarget = nil }
    }
    .confirmationDialog(
      RegistryPrompts.prompt("deleteSection").title,
      isPresented: Binding(
        get: { headingDeleteTarget != nil },
        set: { if !$0 { headingDeleteTarget = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(RegistryPrompts.prompt("deleteSection").confirmTitle ?? "", role: .destructive) {
        if let h = headingDeleteTarget { mutator.delete(id: h.id); Task { await load() } }
        headingDeleteTarget = nil
      }
      Button(RegistryPrompts.cancelTitle, role: .cancel) { headingDeleteTarget = nil }
    } message: {
      Text(RegistryPrompts.prompt("deleteSection").message)
    }
    // Registry `clearLogged`, the same copy the AppKit shell's sheet shows.
    .confirmationDialog(
      clearLoggedRequest?.copy.title ?? "",
      isPresented: Binding(
        get: { clearLoggedRequest != nil },
        set: { if !$0 { clearLoggedRequest = nil } }
      ),
      titleVisibility: .visible,
      presenting: clearLoggedRequest
    ) { request in
      Button(request.copy.confirmTitle ?? "", role: .destructive) {
        commitClearLogged(ids: request.ids)
        clearLoggedRequest = nil
      }
      Button(RegistryPrompts.cancelTitle, role: .cancel) { clearLoggedRequest = nil }
    } message: { request in
      Text(request.copy.message)
    }
    .alert(
      RegistryPrompts.deletePermanently(count: 1).title,
      isPresented: Binding(
        get: { permanentDeleteConfirmTask != nil },
        set: { if !$0 { permanentDeleteConfirmTask = nil } }
      )
    ) {
      Button(RegistryPrompts.deletePermanently(count: 1).confirmTitle ?? "", role: .destructive) {
        if let t = permanentDeleteConfirmTask {
          Haptics.warning()
          removeLocally(id: t.id)
          mutator.purge(id: t.id)
        }
        permanentDeleteConfirmTask = nil
      }
      Button(RegistryPrompts.cancelTitle, role: .cancel) { permanentDeleteConfirmTask = nil }
    } message: {
      Text(RegistryPrompts.deletePermanently(count: 1).message)
    }
  }

  private var taskListLoading: some View {
    taskListDialogs
    // Re-load on every appearance so completed tasks (kept visible in-place
    // while the user is on the screen) drop off when they return.
    .onAppear {
      // Refresh the woven calendar agenda SYNCHRONOUSLY on appear so the
      // woven agenda is right on the first frame instead of popping in a
      // beat later when the async load() resolves. This is the fresh-instance
      // case: arriving at Today from a Project/Area page (a different view
      // type) builds a brand-new TaskListView, so `.onChange(of: filter)`
      // never fires and `model.calendarEvents` would otherwise stay empty until the
      // load lands — a visible layout jump.
      //
      // Except on the launch frame (docs/LAUNCH_PERF.md): before the first
      // task list frame is drawn, the agenda waits for `performLoad`'s second
      // pass, so EventKit never sits in front of the first Today frame.
      if LaunchPhase.shared.firstFrameDrawn { refreshCalendarEvents() }
      // The draft sweep writes, so it waits for the first frame and for the
      // services (a no-op wait after launch).
      Task {
        await LaunchPhase.shared.waitForFirstFrame()
        await SeptenaServices.shared.start()
        Self.sweepAbandonedDraftsOnce(using: mutator, in: modelContext)
      }
      Task { await load() }
    }
    // CKSyncEngine fires .septenaTasksChanged at the end of every fetch
    // batch — including pushes from other devices and the foreground
    // bootstrap fetch. Without this, the list only refreshes when the
    // view re-appears (i.e. you have to navigate away and back).
    // Coalesced: a single mutation can fan out several `.septenaTasksChanged`
    // posts (local save + sync batch + Spotlight). The coalescing lives in
    // `load()`'s generation counter (@State), NOT in a Combine `.debounce`
    // here: `onReceive` resubscribes whenever the body re-evaluates, and a
    // resubscription silently drops a debounced event still waiting out its
    // window. On an iOS foreground the body re-evaluates right after the
    // pull's post (scene phase, and every sync run writes the observed
    // `TaskSyncEngine.signedIn`), so the pulled change never reached the
    // list until a restart.
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)
      .filter { taskChangeMayAffectCurrentList($0) }) { _ in
      reloadOrDeferWhileEditing(coalescing: true)
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaStructureChanged)) { _ in
      reloadOrDeferWhileEditing(coalescing: true)
    }
    .onReceive(NotificationCenter.default.publisher(for: .septaskSettingsPulled)) { _ in
      // Synced notice state (Get started, rolled-in dismissal) arrived from
      // another device — re-evaluate Today's notices immediately.
      noticeEpoch += 1
      refreshTodayNotices()
    }
    // The moment an inline editor / quick-add / composer folds, catch up on any
    // background refresh we held back so the list never reshuffles under a
    // focused title field (the "type one char, lose focus" bug).
    .onChange(of: listInputActive) { _, active in
      if !active { flushDeferredReloadIfNeeded() }
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
    .onChange(of: showFadedInLists) { _, _ in Task { await load() } }
    .onChange(of: clock.today) { _, _ in
      guard filter == .today else { return }
      Task { await load() }
    }
  }

  private var taskList: some View {
    taskListLoading
    // Filter swaps reuse this same view (no .id(route) at the App level for
    // .filter cases). `items` is a computed property that already returns
    // the right data for `filter` synchronously, so we only need to clear
    // session-scoped state and re-trigger the network refresh.
    .onChange(of: filter) { old, _ in
      if old == .logbook {
        logbookLimit = Self.logbookPageSize
        logbookRevealAll = false
      }
      model.resetSession()
      clearSelection()
      expandedEditId = nil
      // Drop the inline-create placeholders this filter owned BEFORE forgetting
      // them. An inline add inserts a real, empty-titled TaskEntity up front
      // (`startCreate` → `deferPush`), and the editor's `onVanish` is what
      // normally purges it when nothing was typed — but `onVanish` checks
      // `draftEditIds`, which this clear had already emptied. Switching lists
      // with a capture line open therefore stranded a titleless row in the
      // store, where it renders as a blank Inbox task and counts toward every
      // Inbox badge. Only EMPTY drafts are dropped: `purgeDraftIfEmpty` leaves
      // anything the user actually typed alone.
      for id in draftEditIds { purgeDraftIfEmpty(id: id) }
      draftEditIds = []
      quickAddDraftId = nil
      quickAddDraftAtTop = false
      quickAddGroupTarget = nil
      pendingReloadWhileEditing = false
      // Re-fetch the woven calendar agenda SYNCHRONOUSLY, in the same
      // transaction as the filter change. The view is reused across filter
      // swaps, so without this the body re-renders for the new filter while
      // `model.calendarEvents` still holds the PREVIOUS filter's events — e.g.
      // Upcoming→Today briefly renders all 30 days of upcoming events as
      // today's agenda, then snaps when the async load() resolves. That stale
      // frame is the "weird rebuild between screens". Mirrors the synchronous
      // correctness the `items`/`storageFilter` getter already gives the rows.
      refreshCalendarEvents()
      hydrateFilterStorageIfNeeded()
      refreshTodayNotices()
      Task { await load() }
    }
    .onChange(of: nav.pendingTaskReveal) { _, _ in
      consumePendingTaskReveal()
    }
    // Leaving reorder edit mode drops the selection so nothing stale lingers.
    .onChange(of: isEditMode) { _, editing in
      if !editing { selection.removeAll() }
    }
    // Consume the global "start a new task" trigger (⌘N / + / sidebar menu) by
    // opening the contextual inline quick-add (Inbox on Today, foot line on
    // project/area, composer on Upcoming).
    .onChange(of: nav.shouldStartCreating) { _, _ in
      consumeStartCreatingRequest()
    }
    .onChange(of: nav.shouldCreateHeading) { _, want in
      guard want, isOnScreen, case .project(let pid) = filter else { return }
      nav.shouldCreateHeading = false
      headingDraftTitle = ""
      headingCreateProject = pid
    }
    .onAppear(perform: didAppearOnScreen)
    .onDisappear {
      isOnScreen = false
      #if os(iOS)
      showingQuickDropTray = false
      if isTouchSelecting {
        nav.isTaskMultiSelectActive = false
      }
      #endif
    }
    #if os(iOS)
    .toolbar {
      if isTouchSelecting {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { clearSelection() }
            .fontWeight(.semibold)
        }
      }
    }
    .onChange(of: isTouchSelecting) { _, _ in
      syncMultiSelectChrome()
    }
    #endif
    .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
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
            reloadOrDeferWhileEditing()
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
  /// editor on it. Creatable lists insert a local `deferPush` placeholder (no
  /// CloudKit push until the title commits) at the foot of the list. The shared
  /// composer still treats this as CREATE, not edit, so its behavior is in
  /// lockstep with the drawer composer. Upcoming falls back to the drawer.
  private func startCreate(areaId: String? = nil, projectId: String? = nil) {
    guard filter != .recentlyDeleted, filter != .repeating, filter != .review, filter != .agent else { return }
    // One press: fold (and so save) whatever editor is open, then start the
    // new task. This used to stop after the fold, so "+" while editing took
    // two presses.
    closeActiveEditIfNeeded()
    if filter == .upcoming {
      let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: clock.now) ?? clock.now
      _ = createInlineDraftAtDrop(scheduledDate: tomorrow, fromDrag: false)
      return
    }
    guard allowsInlineCreate else {
      a11yAnimate(.snappy(duration: 0.25)) {
        expandedEditId = nil
        creating = true
      }
      return
    }
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
    model.noteCreated(task.id)
    draftEditIds.insert(task.id)
    quickAddDraftAtTop = showsQuickAddAtTop
    quickAddDraftId = task.id
    a11yAnimate(.snappy(duration: 0.22)) {
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
    // One press: save + fold the open editor (a capture line included: its
    // typed title lives in the editor, not the store, so only its own teardown
    // can save it) and start the new task. `startCreate` does the fold. A blank
    // open line is dropped by that teardown and replaced by the new one.
    if filter == .today && inboxCollapsed {
      a11yAnimate(.easeInOut(duration: 0.2)) { inboxCollapsed = false }
    }
    switch filter {
    case .area(let id):    startCreate(areaId: id)
    case .project(let id): startCreate(projectId: id)
    default:               startCreate()
    }
  }

  /// Pull to refresh: the foreground CloudKit fetch, then a mirror re-read.
  private func refreshFromCloud() async {
    try? await ckEngine.fetchChanges()
    await load()
  }

  /// First frame on screen: claim the app-global one-shots meant for the
  /// visible list (see `isOnScreen`).
  private func didAppearOnScreen() {
    isOnScreen = true
    hydrateFilterStorageIfNeeded()
    refreshTodayNotices()
    flushDeferredReloadIfNeeded()
    syncMultiSelectChrome()
    consumeStartCreatingRequest()
    consumePendingTaskReveal()
  }

  /// Hydrates `itemsStorage` once on filter arrival so the `items` getter never
  /// re-runs `LocalCache.tasks(...)` multiple times per frame while waiting for
  /// the coalesced async `load()`. Preserves the cold-launch Today snapshot (#82).
  private func hydrateFilterStorageIfNeeded() {
    guard storageFilter != filter else { return }
    if filter == .today, !embedded, !LaunchPhase.shared.firstFrameDrawn,
       let snap = TodaySnapshotStore.launchRows(day: clock.today) {
      itemsStorage = snap.today
      storageFilter = filter
      return
    }
    itemsStorage = localTasks()
    storageFilter = filter
  }

  private func refreshTodayNotices() {
    guard filter == .today else {
      if !cachedTodayNotices.isEmpty { cachedTodayNotices = [] }
      return
    }
    let next = TaskNotices.today(pool: items, requiresSignIn: requiresSignIn,
                                 today: clock.today, context: modelContext)
    if next != cachedTodayNotices {
      cachedTodayNotices = next
    }
  }

  /// Backgrounding is where an empty inline-create placeholder gets stranded
  /// (the app is killed before the editor folds). Fold an open draft now so its
  /// own teardown saves typed text or drops the blank row, and drop any other
  /// blank draft. `sweepAbandonedDraftsOnce` catches what a kill still leaves.
  private func handleScenePhase(_ phase: ScenePhase) {
    guard phase == .background else { return }
    // The open draft is left to its editor's teardown: its typed title is in
    // the editor, not the store yet, so purging it here would lose it.
    let open = expandedEditId
    if let open, draftEditIds.contains(open) { collapseEdit() }
    for id in draftEditIds where id != open { purgeDraftIfEmpty(id: id) }
    draftEditIds = draftEditIds.filter { $0 == open }
  }

  /// External "+" / ⌘N trigger. On iOS, tapping "+" while an inline editor is
  /// already open closes that editor instead of jumping into a new editor mode.
  private func handleExternalCreateTrigger() {
    #if os(iOS)
    if closeActiveEditIfNeeded() { return }
    #endif
    openContextualQuickAdd()
  }

  /// Consume the app-global create request from both first appearance and
  /// subsequent command deliveries. Keeping this imperative work outside the
  /// already-large SwiftUI modifier expression also gives every target the
  /// same small, compiler-friendly entry point.
  private func consumeStartCreatingRequest() {
    // Only the list on screen answers. A hidden list (another tab, or the list
    // under a pushed one) used to consume the flag and open a draft nobody saw.
    // An unanswered request expires on its own (`NavigationState.requestNewTask`).
    guard isOnScreen, nav.shouldStartCreating else { return }
    nav.shouldStartCreating = false
    handleExternalCreateTrigger()
  }

  // MARK: - Inline editing

  /// Whether this list accepts an inline quick-add line. Logbook (completed) and
  /// Recently Deleted are read-only histories. Upcoming is excluded too: it's a
  /// multi-day grouped grid with no single target day, so a foot-of-list line
  /// would just dump every capture onto "tomorrow" regardless of context — use
  /// the `+`/⌘N composer there (it lets you pick the day).
  private var allowsInlineCreate: Bool {
    switch filter {
    case .logbook, .faded, .recentlyDeleted, .upcoming, .repeating, .review, .agent: return false
    default:                                    return true
    }
  }

  /// Open a task for editing — Things-style expand-in-place on every platform.
  /// The row grows to host the full inline editor (`TaskComposerCard(.inline)`);
  /// folding it autosaves. This works in a `SelectableScrollList` (not a native
  /// `List`) precisely because the container can host an inline-editable
  /// `TextField` on macOS without the List focus/selection corruption.
  private func beginEdit(_ task: SeptenaTask) {
    // Opening a row while another is open folds (and so saves) the other and
    // opens this one in the SAME tap. This used to stop after the fold, which
    // (with select-first on iPad) made switching rows cost three taps.
    if let open = expandedEditId, open != task.id { collapseEdit() }
    if composerIsOpen { closeComposer() }
    // Open INSTANTLY — no animated transaction. An animated open cross-faded the
    // closed `Text` row and the editor `TextField` row (both carry
    // `.transition(.opacity)`): the dim mid-fade was the "flash", and the spring
    // animated the residual `Text`↔`TextField` baseline delta as visible title
    // travel. With no animation, neither transition plays, so the title swaps in
    // place — the equal title band (`CheckableRow.titleBandHeight`) keeps its
    // position identical, giving no flash and no move.
    selection = [task.id]
    expandedEditId = task.id
  }

  /// Fold the inline editor shut (its `.onDisappear` autosaves). Called by the
  /// editor's close hook (Return-to-save), Esc, and whenever we leave the list.
  ///
  /// Closing KEEPS the just-closed task selected so its row indicator stays put
  /// — the single reliable rule across every close path (Return, Esc, even a
  /// click on empty paper, which would otherwise have cleared the selection a
  /// beat before this runs). The one exception: if the user closed by selecting
  /// a DIFFERENT row, we respect that new selection instead of yanking it back.
  private func collapseEdit() {
    let closingId = expandedEditId
    if let closingId { clearQuickAddCaptureSlot(for: closingId) }
    // Close INSTANTLY too — a matching, un-animated fold so the editor→closed
    // swap doesn't cross-fade (the "flash" on blur) or animate the baseline
    // delta (the drop). See `beginEdit`.
    expandedEditId = nil
    if usesSelectionModel {
      if let closingId, selection.isEmpty || selection == [closingId] {
        selection = [closingId]
      }
    } else if let closingId {
      // iPhone has no selection model: a row left selected after its editor
      // folds kept the grey selection fill with nothing to show for it.
      selection.remove(closingId)
    }
    // Dropping an untouched inline-create draft is owned by the editor's
    // `onVanish` (fired right after its autosave on teardown) — never a timed
    // guess here, which used to front-run the animation-delayed autosave and
    // purge a task the user had just typed.
  }

  /// Close whichever task-editing surface is active and let its normal save path
  /// run. Returns true when the caller should consume the tap/command that caused
  /// the close instead of also performing its own action.
  @discardableResult
  private func closeActiveEditIfNeeded(except targetID: String? = nil) -> Bool {
    if let id = expandedEditId, id != targetID {
      collapseEdit()
      return true
    }
    if composerIsOpen {
      closeComposer()
      return true
    }
    return false
  }

  private func closeEditOrClearSelection() {
    guard !closeActiveEditIfNeeded() else { return }
    clearSelection()
  }

  /// Drop an inline-create placeholder that never received a title.
  ///
  /// The title comes from the STORE, not from `currentTask`. `currentTask`
  /// reads the list that is rendered right now, so on a filter swap (where the
  /// new filter's rows are already in `items`) a draft the user had typed into
  /// resolves to nil — and a nil title reads as empty, which would purge real
  /// work. A row that is genuinely gone from the store returns nil here too and
  /// needs no purge, so the point read is right in both directions.
  private func purgeDraftIfEmpty(id: String) {
    guard let stored = LocalCache.task(id: id, in: modelContext) else { return }
    let trimmed = stored.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty else { return }
    // "No title in the store" is not proof the user typed nothing. A write
    // that `StoreHealth` rolled back leaves exactly this state, and purging on
    // it hard-deleted typed work with no trash entry. The mutator remembers
    // the ids whose last write did not land, so this sweep — which runs a
    // runloop away from the composer and cannot ask the write itself — fails
    // closed and leaves the row for the user to retype or delete.
    guard !mutator.lastWriteFailed(id: id) else {
      SeptenaLog.error(
        "[Tasks] draft id=\(id) reads untitled after a failed write — keeping the row", nil)
      return
    }
    clearQuickAddCaptureSlot(for: id)
    mutator.purge(id: id)
    removeLocally(id: id)
    selection.remove(id)
    Task { await load() }
  }

  @MainActor private static var didSweepAbandonedDrafts = false

  /// Once per launch: drop inline-create placeholders a previous run left
  /// behind (the app was killed with a blank "New task" line open). Such a row
  /// has an empty title and was never pushed to CloudKit (no system fields), so
  /// it exists on this device only and nothing else references it. `purge`, not
  /// `delete`: a blank draft is not user data and must not land in Recently
  /// Deleted. Headings are skipped (they are never blank drafts).
  @MainActor
  static func sweepAbandonedDraftsOnce(using mutator: TaskMutator, in context: ModelContext) {
    guard !didSweepAbandonedDrafts else { return }
    didSweepAbandonedDrafts = true
    let blank = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.title == "" && $0.deletedAt == nil }
    ))) ?? []
    let ids = blank
      .filter { $0.cloudKitSystemFields == nil && !$0.isHeading }
      .map(\.id)
    for id in ids { mutator.purge(id: id) }
    if !ids.isEmpty {
      SeptenaLog.info("[TaskList] swept \(ids.count) abandoned blank draft(s)")
    }
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

  /// Area / project group headers on Today stay clean (no trailing `+` button —
  /// capture happens via Magic Plus / New task / ⌘N, matching AppKit).
  private var showsGroupedHeaderQuickAdd: Bool { false }

  /// Compact iPhone Septena uses the floating Magic Plus orb instead of an idle
  /// "New task" trigger row in Inbox — the capture slot mounts only while an
  /// inline draft is actively open.
  private var usesMagicPlusInsteadOfInboxTrigger: Bool {
    #if os(iOS) && SEPTASK
    !usesPushNavigation
    #else
    false
    #endif
  }

  /// Inbox foot quick-add: always visible on Today (Mac/iPad); on iPhone
  /// Septena, only mounts while an Inbox inline draft is actively open.
  private var showsQuickAddInInbox: Bool {
    guard filter == .today && allowsInlineCreate else { return false }
    if usesMagicPlusInsteadOfInboxTrigger {
      return quickAddInInboxShowsEditor
    }
    return true
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
      selectable: usesSelectionModel || touchSelectionActive,
      toggleOnTap: touchSelectionActive,
      onActivate: activateRow,
      onClear: { closeEditOrClearSelection() },
      onMoveShortcut: openMoveForSelected,
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
      scopeFadedSection()
      scopeLoggedSection()
      taskListFooter
    }
    // Snapshot rows are inert (#82): a tap must not act on a row read from
    // the launch file. The first load swaps in the live rows a few frames on.
    .allowsHitTesting(launchSnapshot == nil)
    // Click-away collapses the inline editor (Things-style) — selecting any
    // OTHER row folds the open editor, autosaving it. While editing, the list's
    // arrow keys are suppressed (`listInputActive`), so selection only moves via
    // an explicit click on a different row.
    .onChange(of: selection) { _, sel in
      #if os(iOS)
      if sel.isEmpty && isTouchSelecting {
        isTouchSelecting = false
      }
      syncMultiSelectChrome()
      #endif
      if let suppressed = suppressActivationAfterSelectionCloseId,
         !sel.contains(suppressed) {
        suppressActivationAfterSelectionCloseId = nil
      }
      if let id = expandedEditId, !sel.contains(id) {
        // macOS only: a double-click arrives as "select" then "activate", and
        // the select already folded the editor; swallow the paired activate.
        // iPad has no such pair, and suppressing there cost an extra tap.
        #if os(macOS)
        suppressActivationAfterSelectionCloseId = sel.count == 1 ? sel.first : nil
        #endif
        collapseEdit()
      }
    }
    #if os(iOS)
    // Pull to refresh runs the same CloudKit fetch the app runs on foreground,
    // then re-reads the mirror. (`load()` itself must never fetch: it runs
    // inside the sync delegate's change notification — see `performLoad`.)
    .refreshable { await refreshFromCloud() }
    #endif
    #if os(macOS)
    // Esc when the list itself holds focus just clears the selection. An open
    // inline editor owns Esc itself (the composer saves and closes), so
    // this only fires when no editor is up.
    .onExitCommand { clearSelection() }
    #endif
    #if os(macOS)
    .onCopyCommand {
      guard usesSelectionModel, !listInputActive,
            let text = copyPayload(for: orderedActionIDs()) else { return [] }
      return [NSItemProvider(object: text as NSString)]
    }
    #endif
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if filter != .recentlyDeleted &&
          ((touchSelectionActive && selectionScope.count > 0) ||
           (usesSelectionModel && selectionScope.isMulti)) {
        taskBatchActionBar
      }
    }
    #if os(iOS)
    .overlay {
      if showingQuickDropTray {
        QuickDropProjectTray(
          areas: areas,
          projects: projects,
          projectProgress: model.progressByProject,
          onDropInbox: { ids in
            applyMove(ids, areaId: nil, projectId: nil)
            return true
          },
          onDropToday: { ids in
            let moving = ids.filter { !(currentTask(id: $0)?.isOnToday ?? false) }
            guard !moving.isEmpty else { return false }
            Haptics.tick()
            promoteToToday(moving)
            for id in ids { mutator.acknowledge(id: id) }
            if touchSelectionActive { clearSelection() }
            Task { await load() }
            return true
          },
          onDropArea: { ids, areaId in
            applyMove(ids, areaId: areaId, projectId: nil)
            return true
          },
          onDropProject: { ids, projectId in
            applyMove(ids, areaId: nil, projectId: projectId)
            return true
          },
          onDismiss: {
            a11yAnimate(.snappy(duration: 0.2)) {
              showingQuickDropTray = false
            }
          }
        )
      }
    }
    #endif
  }

  private var allSelectedAreToday: Bool {
    let tasks = orderedActionIDs().compactMap { currentTask(id: $0) }
    return !tasks.isEmpty && tasks.allSatisfy(\.isOnToday)
  }

  private var allSelectableVisibleSelected: Bool {
    let selectableIDs = selectableVisibleTaskIDs
    return !selectableIDs.isEmpty && selectableIDs.allSatisfy { selection.contains($0) }
  }

  private var selectableVisibleTaskIDs: [String] {
    keyboardOrderedTaskIds.filter { id in
      id != Self.quickAddScrollID && TaskNoticeStep.stepID(fromSelection: id) == nil
    }
  }

  @ViewBuilder
  private var taskBatchActionBar: some View {
    #if os(iOS)
    if touchSelectionActive {
      touchMultiSelectBar
    } else {
      desktopBatchActionBar
    }
    #else
    desktopBatchActionBar
    #endif
  }

  #if os(iOS)
  private var touchMultiSelectBar: some View {
    HStack(spacing: 4) {
      Text("\(selectionScope.count) selected")
        .font(.septenaMeta.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(Theme.inkSecondary)
        .lineLimit(1)
        .padding(.leading, 4)

      Spacer(minLength: 4)

      Button { openWhenForSelected() } label: {
        Label(RegistrySurfaces.taskAttribute("when").label, systemImage: "calendar")
          .labelStyle(.iconOnly)
          .frame(width: 40, height: 38)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Schedule selected tasks")

      Button { openMoveForSelected() } label: {
        Label(RegistryActions.title("task.move", .short), systemImage: "arrow.right.circle")
          .labelStyle(.iconOnly)
          .frame(width: 40, height: 38)
          .contentShape(Rectangle())
      }
      .modifier(TaskSpringLoadMoveDrop(
        enabled: !usesPushNavigation,
        onSpringLoad: {
          a11yAnimate(.snappy(duration: 0.22)) {
            showingQuickDropTray = true
          }
        },
        onDirectDrop: { ids in
          moveTargetIds = ids
          showingMoveSheet = true
        }
      ))
      .accessibilityLabel("Move selected tasks")

      Button { toggleSelected() } label: {
        Label("Complete", systemImage: "checkmark.circle")
          .labelStyle(.iconOnly)
          .frame(width: 40, height: 38)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Complete selected tasks")

      Button(role: .destructive) { deleteSelected() } label: {
        Label("Delete", systemImage: "trash")
          .labelStyle(.iconOnly)
          .frame(width: 40, height: 38)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Delete selected tasks")

      Menu {
        Button {
          toggleTodayForSelected()
        } label: {
          Label(allSelectedAreToday ? RegistryActions.title("task.toggleToday", .remove) : RegistryActions.title("task.toggleToday", .add),
                systemImage: allSelectedAreToday ? "sun.max" : "sun.max.fill")
        }
        Button {
          copyTasks(orderedActionIDs())
          clearSelection()
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        Button {
          selectAllOrClearVisibleTasks()
        } label: {
          Label(allSelectableVisibleSelected ? "Deselect All" : "Select All",
                systemImage: allSelectableVisibleSelected ? "checklist.unchecked" : "checklist")
        }
        Divider()
        Button(role: .destructive) {
          cancelSelected()
        } label: {
          Label(RegistryActions.title("task.cancel", .plural), systemImage: "xmark.circle")
        }
      } label: {
        Label("More", systemImage: "ellipsis.circle")
          .labelStyle(.iconOnly)
          .frame(width: 40, height: 38)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("More batch actions")
    }
    .font(.system(size: 18, weight: .regular))
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: Capsule())
    .overlay(
      Capsule()
        .strokeBorder(Theme.border, lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    .padding(.horizontal, Theme.pageGutter)
    .padding(.bottom, 8)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }
  #endif

  private var desktopBatchActionBar: some View {
    HStack(spacing: 16) {
      Text("\(selectionScope.count) selected")
        .font(.septenaMeta)
        .foregroundStyle(Theme.inkSecondary)
      Spacer(minLength: 0)
      Button(RegistrySurfaces.taskAttribute("when").label) { openWhenForSelected() }
      Button("Copy") { copyTasks(orderedActionIDs()) }
      Button(RegistryActions.title("task.move", .short)) { openMoveForSelected() }
      Button("Complete") { toggleSelected() }
      Button("Delete", role: .destructive) { deleteSelected() }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 10)
    .background(.bar)
  }

  /// True while an inline task editor is expanded in this list.
  private var isInlineEditing: Bool { expandedEditId != nil }

  /// True while a field/editor owns the keyboard — the composer drawer or an
  /// expanded inline editor. Drives the `SelectableScrollList`'s key-suppression
  /// + focus-reclaim.
  private var listInputActive: Bool {
    composerIsOpen || expandedEditId != nil
  }

  /// Row-level command shortcuts should only exist while the list owns input.
  /// When a task editor or inline text field is active, native text editing
  /// commands (Copy, Paste, Select All) must stay with the focused control.
  private var rowCommandShortcutsEnabled: Bool {
    filter != .recentlyDeleted
      && !listInputActive
      && whenSheet == nil
      && !showingMoveSheet
      && !showingRepeatSheet
      && !nav.showQuickFind
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
  /// dual-regular iPad / unfolded iPhone Duo) or the touch tap-to-edit model
  /// (compact iPhone and compact-height landscape phone).
  private var usesSelectionModel: Bool {
    #if os(macOS)
    return true
    #else
    return usesPushNavigation
    #endif
  }

  /// Return / double-click(Mac) / tap(touch) on a row → open it for editing.
  /// Multi-select has no single primary action, so Return no-ops there.
  ///
  /// The quick-add "New task" row is a selectable row too (see `quickAddLine`):
  /// activating it spawns a fresh draft and opens its inline editor — the DRY
  /// twin of clicking the row, so keyboard (Return) and pointer (double-click /
  /// tap) share one path.
  private func activateRow(_ id: String) {
    #if os(iOS)
    // On iOS, tapping outside an open inline editor only closes it — never
    // transitions into another task editor or quick-add editor.
    if expandedEditId != nil {
      collapseEdit()
      return
    }
    #endif
    if suppressActivationAfterSelectionCloseId == id {
      suppressActivationAfterSelectionCloseId = nil
      return
    }
    if id == Self.quickAddScrollID {
      startCreate()  // folds any open editor first, same press
      return
    }
    // A Get started step: Return, a double-click or a tap does the step.
    if let stepID = TaskNoticeStep.stepID(fromSelection: id) {
      openNoticeStep(stepID)
      return
    }
    guard selection.count <= 1 else { return }
    guard let task = currentTask(id: id) else { return }
    beginEdit(task)
  }

  /// True once this filter's data has loaded and there are no rows to show.
  private var showsEmptyTaskList: Bool {
    loadedFilters.contains(filter) && visibleItems.isEmpty
      && triageItems.isEmpty && !isLoading
  }

  /// Inline quick-add under the title when a creatable list is empty. Today
  /// hosts capture in the Inbox section instead (see `triageSection`).
  private var showsQuickAddAtTop: Bool {
    if usesMagicPlusInsteadOfInboxTrigger && filter == .triage {
      return quickAddDraftAtTop && quickAddDraftId != nil
    }
    return filter != .today && allowsInlineCreate && (showsEmptyTaskList || quickAddDraftAtTop)
  }

  /// Things-style foot quick-add once the list has content. Today captures
  /// through the Inbox card, not at the foot of the full day list.
  private var showsQuickAddAtFoot: Bool {
    if usesMagicPlusInsteadOfInboxTrigger && filter == .triage {
      return !quickAddDraftAtTop && quickAddDraftId != nil
    }
    return filter != .today && allowsInlineCreate && !showsEmptyTaskList && !quickAddDraftAtTop
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
    noticesRow
    todayCalendarRow
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
      let allInbox = renderedTodayInboxRows
      if showsQuickAddInInbox || !allInbox.isEmpty {
        Section {
          if !inboxCollapsed {
            cardedRows(allInbox,
                       quickMenu: { model.filingSuggestions[$0.id] != nil },
                       appendQuickAdd: showsQuickAddInInbox,
                       quickAddShowsEditor: quickAddInInboxShowsEditor,
                       moveDropTarget: .inbox,
                       magicContext: "Inbox")
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
    foldableSectionHeader(icon: "tray.full", title: TaskFilter.triage.title, count: count,
                          isCollapsed: inboxCollapsed) {
      inboxCollapsed.toggle()
    }
    .modifier(todayMoveDrop(.inbox))
    .magicPlusSectionDrop(id: "mp-inbox-header", kind: .taskSection(label: "New Task in Inbox")) {
      _ = handleTodayMoveDrop(ids: TaskDragIDs.newTask.ids, target: .inbox)
    }
    .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
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
      if closeActiveEditIfNeeded() { return }
      Haptics.tick()
      a11yAnimate(.easeInOut(duration: 0.2)) { onToggle() }
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: Theme.iconTextGap) {
          Image(systemName: icon)
            .scaledFont(size: 16)
            .foregroundStyle(Theme.iconMuted)
            .frame(width: Theme.checkboxTap, alignment: .center)
            .offset(x: -Theme.checkboxLeadingNudge)
          Text(title).sectionGroupHeaderTitleStyle()
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

  /// Type-erased per branch on purpose. Spelled out, this switch's result
  /// type nests every row builder's full generic type, and resolving that
  /// type at runtime recursed deep enough to overflow the main thread's
  /// stack at launch on iPhone (EXC_BAD_ACCESS in swift_getTypeByMangledName,
  /// 2026-11-19). `AnyView` at this one seam caps the depth; the rows inside
  /// keep their concrete types.
  private var showsStarFilterPill: Bool {
    switch filter {
    case .starred, .logbook, .recentlyDeleted, .faded:
      return false
    case .today:
      return (items + triageItems).contains { $0.starred && $0.status == .open }
    default:
      return items.contains { $0.starred && $0.status == .open }
    }
  }

  /// Tags actually present on tasks in the current list — progressive
  /// disclosure: zero tags on tasks in this list => zero tag bar chrome
  /// (`docs/TAGS_SPEC.md` §3).
  private var availableTagsInList: [TaskTag] {
    guard filter != .recentlyDeleted else { return [] }
    var presentIDs = Set<String>()
    for task in items {
      for tid in task.tags { presentIDs.insert(tid) }
    }
    if filter == .today {
      for task in triageItems {
        for tid in task.tags { presentIDs.insert(tid) }
      }
    }
    guard !presentIDs.isEmpty else { return [] }
    return presentIDs
      .compactMap { tagsByID[$0] }
      .sorted { lhs, rhs in
        let lp = lhs.position ?? Int.max
        let rp = rhs.position ?? Int.max
        if lp != rp { return lp < rp }
        let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if cmp != .orderedSame { return cmp == .orderedAscending }
        return lhs.id < rhs.id
      }
  }

  @ViewBuilder
  private var starFilterBar: some View {
    let listTags = availableTagsInList
    let hasActiveFilter = (starredOnlyFilter && showsStarFilterPill) || !selectedTagIDs.isEmpty
    if showsStarFilterPill || !listTags.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          if showsStarFilterPill {
            SelectableChip(isSelected: starredOnlyFilter, tint: Theme.todayAccent, onCanvas: true) {
              Haptics.tick()
              a11yAnimate(.snappy(duration: 0.18)) { starredOnlyFilter.toggle() }
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "star.fill")
                  .scaledFont(size: 11)
                Text(TaskFilter.starred.title)
              }
            }
          }
          ForEach(listTags) { tag in
            let isOn = selectedTagIDs.contains(tag.id)
            SelectableChip(isSelected: isOn,
                           tint: tag.color != nil ? TagColorPalette.color(for: tag.color) : theme.color(for: "tasks"),
                           onCanvas: true) {
              Haptics.tick()
              a11yAnimate(.snappy(duration: 0.18)) {
                if isOn { selectedTagIDs.remove(tag.id) }
                else { selectedTagIDs.insert(tag.id) }
              }
            } label: {
              HStack(spacing: 4) {
                if tag.color != nil {
                  Circle()
                    .fill(TagColorPalette.color(for: tag.color))
                    .frame(width: 6, height: 6)
                }
                Text(tag.name)
              }
            }
          }
          if hasActiveFilter {
            Button {
              Haptics.tick()
              a11yAnimate(.snappy(duration: 0.18)) {
                starredOnlyFilter = false
                selectedTagIDs.removeAll()
              }
            } label: {
              Text("Clear")
                .font(.septenaCaption)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, TaskCardMetrics.margin)
      }
      .padding(.top, 4)
      .padding(.bottom, 6)
    }
  }

  private var taskListRows: AnyView {
    switch filter {
    case .today:
      if todayGroupByList {
        return AnyView(Group {
          AnyView(starFilterBar)
          AnyView(triageSection)
          AnyView(groupedOpenItems)
          AnyView(todaySkeleton)
        })
      }
      // `Group`, not a stack: the rows stay direct children of the lazy
      // stack (AnyView forwards the view list), so laziness and per-row
      // identity hold. No lifecycle modifiers hang off this Group.
      return AnyView(Group {
        AnyView(starFilterBar)
        AnyView(triageSection)
        AnyView(ungroupedOpenItems)
        AnyView(todaySkeleton)
      })
    case .unscheduled, .starred:
      return AnyView(Group {
        AnyView(starFilterBar)
        AnyView(groupedOpenItems)
      })
    case .upcoming:
      return AnyView(Group {
        AnyView(starFilterBar)
        AnyView(groupedUpcomingItems)
      })
    case .project:
      return AnyView(Group {
        AnyView(starFilterBar)
        AnyView(projectGroupedRows)
      })
    case .review:
      return AnyView(Group {
        AnyView(starFilterBar)
        AnyView(reviewRows)
      })
    case .agent:
      return AnyView(Group {
        AnyView(starFilterBar)
        AnyView(agentStageRows)
      })
    default:
      return AnyView(Group {
        AnyView(starFilterBar)
        AnyView(visibleRows)
      })
    }
  }

  // Bottom breathing room + a tap-to-dismiss target for empty space. The
  // floating keyboard accessory / batch bar are `.safeAreaInset`s, so the
  // scroll content already insets for them while editing — this is just a
  // tidy end-of-list margin, not the 240pt dead-zone it used to be.
  @ViewBuilder
  private var taskListFooter: some View {
    if filter == .logbook, items.count == logbookLimit {
      Button("Show \(Self.logbookPageSize) More") {
        logbookLimit += Self.logbookPageSize
        Task { await load() }
      }
      .buttonStyle(PlainHoverRowButtonStyle())
      .font(.septenaMeta)
      .foregroundStyle(Theme.inkSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, TaskCardMetrics.headerLeading)
      .padding(.vertical, 12)
      .asListRow()
      .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
    }

    Color.clear
      .frame(minHeight: 96)
      .contentShape(Rectangle())
      // A single tap on the empty space below the list clears the selection;
      // a double-click in that blank space drops the cursor onto the quick-add
      // line (the macOS "double-click empty space to add" affordance).
      #if os(macOS)
      .simultaneousGesture(TapGesture(count: 2).onEnded {
        if closeActiveEditIfNeeded() { return }
        startCreate()
      })
      .simultaneousGesture(TapGesture(count: 1).onEnded { closeEditOrClearSelection() })
      #else
      .onTapGesture { closeEditOrClearSelection() }
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
      .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
    } else {
      embeddedHeader()
        .plainListChrome()
        .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
    }
  }

  /// Today's notices (sign in, rolled in, an explainer), decided once in
  /// `TaskNotices` and read the same way by the AppKit list.
  @ViewBuilder
  private var noticesRow: some View {
    if filter == .today {
      ForEach(todayNotices) { notice in
        TaskListNotice(
          kind: notice.kind,
          symbol: notice.symbol,
          title: Text(notice.title),
          detail: notice.detail.map { Text($0) },
          onDismiss: notice.dismissible ? { dismissNotice(notice.id) } : nil,
          headsCard: !notice.steps.isEmpty
        ) {
          noticeAction(notice)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .plainListChrome()
        .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
        noticeStepRows(notice.steps)
      }
    } else if filter == .faded, !visibleItems.isEmpty {
      let pile = TaskNotices.fadedPile
      TaskListNotice(
        kind: pile.kind,
        symbol: pile.symbol,
        title: Text(pile.title),
        detail: pile.detail.map { Text($0) },
        onDismiss: nil
      ) {
        Button(pile.primaryTitle ?? "") {
          sweepSheetTasks = visibleItems
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .plainListChrome()
      .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
    }
  }

  /// Today's notices, cached outside `body` so rendering never runs synchronous
  /// SwiftData queries on the main thread.
  private var todayNotices: [TaskNotice] {
    guard filter == .today else { return [] }
    return cachedTodayNotices
  }

  /// The Get started steps on screen, in render order.
  private var todayNoticeSteps: [TaskNoticeStep] {
    todayNotices.flatMap(\.steps)
  }

  /// The Get started steps as rows of this list, on the card their notice
  /// heads: the same selection, arrow keys, Return (open), ⌘K (tick), tap
  /// and card slice as a task row. Kept a flat `ForEach` so each row is a
  /// direct child of the scroll list, like `cardedRows`.
  @ViewBuilder
  private func noticeStepRows(_ steps: [TaskNoticeStep]) -> some View {
    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
      // The notice header is the card's first slice.
      let position = TaskCardPosition(index: index + 1, count: steps.count + 1)
      let isSelected = selection.contains(step.selectionID)
      TaskNoticeStepRow(step: step, onToggle: { toggleNoticeStep(step) })
        .asTaskRow(id: step.selectionID, isSelected: isSelected, isComplete: step.done)
        .taskCardChrome(position, isSelected: isSelected)
        .taskCardContextMenu(position) { noticeStepMenu(step) }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
    }
  }

  /// The step row's menu: what Return and ⌘K do, and hiding the checklist.
  /// Nothing from the task menu applies to a step.
  @ViewBuilder
  private func noticeStepMenu(_ step: TaskNoticeStep) -> some View {
    Button {
      openNoticeStep(step.id)
    } label: {
      Label(String(localized: "Open", comment: "Get started step menu"),
            systemImage: "arrow.up.forward")
    }
    Button {
      toggleNoticeStep(step)
    } label: {
      if step.done {
        Label(RegistryActions.title("notice.toggleStep", .active),
              systemImage: "circle")
      } else {
        Label(RegistryActions.title("notice.toggleStep"),
              systemImage: "checkmark.circle")
      }
    }
    Divider()
    Button {
      dismissNotice(.getStarted)
    } label: {
      Label(RegistryActions.title("notice.hideGetStarted"),
            systemImage: "eye.slash")
    }
  }

  /// Only prompt to sign back in when this device previously held a backend
  /// account and its session ended. A fresh install with no account is a
  /// first-class free mode (docs/SYNC_SUBSCRIPTION_SPEC.md §3, §7) and never
  /// shows a sign-in banner on Today.
  private var requiresSignIn: Bool {
    #if SEPTASK
    let sync = TaskSyncEngine.shared
    return !sync.signedIn && sync.hadAccount
    #else
    false
    #endif
  }

  @ViewBuilder
  private func noticeAction(_ notice: TaskNotice) -> some View {
    if notice.id == .weeklySweep {
      Button(notice.primaryTitle ?? "") {
        let candidates = TaskNotices.sweepCandidates(context: modelContext)
        if !candidates.isEmpty { sweepSheetTasks = candidates }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    #if SEPTASK
    if notice.id == .signIn { SeptaskSignInButton(compact: true) }
    if let upsell = notice.upsellID {
      Button(notice.primaryTitle ?? RegistryPlans.Paywall.seePlus) {
        // Opening the sheet from the notice marks the moment seen.
        TaskNotices.markUpsellSeen(upsell, context: modelContext)
        plusSheetUpsell = upsell
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    #endif
  }

  /// Ticks or unticks a Get started step by hand, like a task's checkbox.
  private func toggleNoticeStep(_ step: TaskNoticeStep) {
    Haptics.tick()
    TaskNotices.toggleStep(step)
    motion.run(.easeOut(duration: 0.2)) { noticeEpoch += 1; refreshTodayNotices() }
  }

  /// Does a Get started step: opens the Settings page that sets it up, or
  /// starts a new task.
  private func openNoticeStep(_ id: TaskNoticeStep.ID) {
    switch id {
    case .addTask:
      startCreate()
    case .connectAI, .importTasks:
      #if SEPTASK
      let pageID = id == .connectAI
        ? RegistrySettings.PageID.claudePairing
        : RegistrySettings.PageID.importExport
      SeptaskSettingsLink.request(pageID)
      nav.showSettings = true
      #endif
    }
  }

  private func dismissNotice(_ id: TaskNotice.ID) {
    TaskNotices.dismiss(id, today: clock.today, context: modelContext)
    motion.run(.easeOut(duration: 0.2)) { noticeEpoch += 1; refreshTodayNotices() }
  }

  @ViewBuilder
  private var remindersRow: some View {
    // Not on the launch frame: the Reminders mirror reads EventKit, so it
    // mounts once the first Today frame is drawn (docs/LAUNCH_PERF.md).
    if filter == .today && LaunchPhase.shared.firstFrameDrawn {
      // Pending Apple Reminders are unratified captures too — surface them in
      // the triage zone on Today, but only when something's actually pending
      // (no setup CTAs here, so an unconfigured user sees nothing).
      RemindersInboxSection(onImported: { Task { await load() } }, showsSetupCTAs: false)
        .plainListChrome()
        .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
    }
  }

  @ViewBuilder
  private var emptyStateRow: some View {
    #if SEPTASK
    settledEmptyStateRow
    #else
    // A first sync on a new device pulls the whole account down. Until it
    // lands the list is empty for a reason that has nothing to do with the
    // user, so say that instead of "Nothing here yet" — and say it even where
    // there IS an inline capture affordance, since the emptiness is what
    // misleads, not the missing button.
    if showsEmptyTaskList && iCloudSignedOut {
      // No iCloud account: the first sync can never start, so "Getting your
      // data" would spin forever. Say what is actually missing.
      ContentUnavailableView {
        Label("Sign in to iCloud", systemImage: "icloud.slash")
      } description: {
        Text("Your tasks sync through iCloud. Sign in from the Settings app to see them here.")
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 40)
      .plainListChrome()
    } else if showsEmptyTaskList && ckEngine.isBootstrapping {
      ContentUnavailableView {
        Label("Getting your data", systemImage: "icloud.and.arrow.down")
      } description: {
        Text(ckEngine.bootstrapStatusText)
          .monospacedDigit()
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 40)
      .plainListChrome()
    } else {
      settledEmptyStateRow
    }
    #endif
  }

  /// No usable iCloud account on this device (signed out, or blocked by a
  /// restriction). `CKEngine` keeps `accountStatus` current.
  private var iCloudSignedOut: Bool {
    ckEngine.accountStatus == .noAccount || ckEngine.accountStatus == .restricted
  }

  @ViewBuilder
  private var settledEmptyStateRow: some View {
    // A creatable list that's empty already offers a "New task" line (Today's
    // Inbox card, or the top quick-add on a project / area) — the big "Nothing
    // here yet" card under it is redundant, and on an area that only holds
    // projects it's plain wrong (the area isn't empty). Show the empty state
    // only where there's no inline capture affordance (Logbook, Recently
    // Deleted, Upcoming).
    // Copy is the registry's (`registry/destinations.json` `emptyTitle` /
    // `emptyDetail`, `genericEmptyState` for a project or an area), the same
    // words the AppKit list shows.
    if showsEmptyTaskList && !allowsInlineCreate {
      ContentUnavailableView(
        filter.emptyTitle,
        systemImage: titleIcon,
        description: Text(
          filter.registryDestination == nil && showsQuickAddAtTop
            ? RegistryDestinations.GenericEmpty.detail
            : filter.emptyDetail
        )
      )
      .frame(maxWidth: .infinity)
      .padding(.top, showsQuickAddAtTop ? 24 : 40)
      .plainListChrome()
    }
  }

  private var visibleRows: some View {
    cardedRows(visibleItems,
               quickMenu: { model.filingSuggestions[$0.id] != nil },
               appendQuickAdd: attachesQuickAddToVisibleCard,
               reorderable: isManuallyOrderedList)
  }

  /// Review stage rows (`needs_verify`, #87): each row carries Accept and Send
  /// back right in the list, and expands into the full composer on tap.
  @ViewBuilder
  private var reviewRows: some View {
    let rows = visibleItems
    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, task in
      let position = TaskCardPosition(index: idx, count: rows.count)
      if expandedEditId == task.id {
        taskRow(task, quickMenu: false)
          .taskCardChrome(position, isSelected: false, isEditing: true)
          .zIndex(1)
      } else {
        ReviewTaskRow(
          task: task,
          isSelected: selection.contains(task.id),
          onOpen: {
            #if os(iOS)
            if closeActiveEditIfNeeded() { return }
            #endif
            beginEdit(task)
          },
          onAccept: {
            Haptics.tick()
            let previousNote = task.conversation.endStateNote
            mutator.complete(id: task.id)
            mutator.acknowledge(id: task.id)
            TaskUndo.recordAcceptReview(id: task.id, previousNote: previousNote, mutator: mutator)
            Task { await load() }
          },
          onSendBack: { note in
            Haptics.tick()
            let before = task.conversation
            mutator.sendBackConvo(id: task.id, note: note)
            let after = mutator.conversation(id: task.id) ?? before
            TaskUndo.recordSendBack(id: task.id, before: before, after: after, mutator: mutator)
            Task { await load() }
          }
        )
        .asListRow()
        .taskCardChrome(position, isSelected: selection.contains(task.id))
        .taskCardContextMenu(position) { taskContextMenu(for: task) }
        .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
      }
    }
  }

  /// Agent smart list (docs/TASK_FACTORY_SPEC.md §3): one section per
  /// `AgentStage`, in registry order, headers only above non-empty stages.
  /// Stage titles and symbols come from `registry/destinations.json`.
  @ViewBuilder
  private var agentStageRows: some View {
    // A claim lease is backend wall-clock time, not the app's day (same
    // rule as `deriveConvo`), so the stage reads the real clock.
    let now = Date()
    let byStage = Dictionary(grouping: visibleItems) {
      $0.conversation.agentStage(at: now) ?? .queued
    }
    ForEach(AgentStage.allCases, id: \.self) { stage in
      if let tasks = byStage[stage], !tasks.isEmpty {
        Section {
          cardedRows(tasks)
        } header: {
          groupHeader(icon: stage.group?.sfSymbol ?? "circle",
                      title: stage.group?.title ?? stage.rawValue)
        }
      }
    }
  }

  /// True where the rendered order IS the manual `TaskOrder.key` order —
  /// project / area pages and the Inbox. Today reorders too, in its own order
  /// (`orderLane`, #66; wired per card in `cardedRows`). Upcoming and history
  /// views are never reorder targets.
  private var isManuallyOrderedList: Bool {
    switch filter {
    case .project, .area, .triage: return true
    default: return false
    }
  }

  /// Persist a manual-order drop: give `ids` positions that place them at
  /// `insertion` within `sequence` — which must ALREADY exclude the dragged rows.
  ///
  /// Fractional ordering normally just writes the midpoint slots. When the gap
  /// between two neighbors is too small to subdivide (dozens of drops into the
  /// same slot exhausts `Double` precision), those slots no longer sort strictly
  /// between their neighbors, so the whole sequence is re-spaced at
  /// `TaskOrder.gap` steps instead.
  ///
  /// Every reorder path shares this so none can forget the fallback.
  /// `handleHeadingDrop` did forget it, and could write positions that don't
  /// sort where the drop indicator promised — a heading silently landing in the
  /// wrong place once a project's headings had been shuffled enough.
  private func applyManualOrder(ids: [String], into sequence: [SeptenaTask], at insertion: Int) {
    let lane = orderLane
    let above = insertion > 0 ? sequence[insertion - 1].orderKey(in: lane) : nil
    let below = insertion < sequence.count ? sequence[insertion].orderKey(in: lane) : nil
    let slots = TaskOrder.positions(count: ids.count, above: above, below: below)
    let strictlyPlaced =
      zip(slots, slots.dropFirst()).allSatisfy { $0 < $1 }
      && (above.map { slots.first! > $0 } ?? true)
      && (below.map { slots.last! < $0 } ?? true)
    if strictlyPlaced {
      for (id, pos) in zip(ids, slots) { mutator.reorder(id: id, toPosition: pos, in: lane) }
      return
    }
    var final = sequence.map(\.id)
    final.insert(contentsOf: ids, at: insertion)
    let base = sequence.first?.orderKey(in: lane) ?? TaskOrder.gap
    for (i, id) in final.enumerated() {
      let pos = base + TaskOrder.gap * Double(i)
      mutator.reorder(id: id, toPosition: pos == 0 ? TaskOrder.gap / 2 : pos, in: lane)
    }
  }

  /// The manual order this list shows and a reorder writes: Today has its
  /// own (`todayPosition`), so reordering Today never moves a task in its
  /// area / project list (#66).
  private var orderLane: TaskOrderLane { filter == .today ? .today : .list }

  /// A reorder drop landed on `target`: insert the dragged ids above (`before`)
  /// or below it and persist new manual positions via the mutator. Neighbors
  /// are read from the rendered order with the dragged rows removed, so a drop
  /// one slot away from the original spot computes against the right keys.
  ///
  /// Today (#66): `refileTo` is the Today group the target row sits in. A
  /// row dragged in from another group is filed into it first (the old
  /// group drop), then placed in Today's own order. `visibleItems` is Today
  /// in that order, and each group is a run of it, so the global neighbours
  /// place the row right in its group too. A target outside that order (a
  /// triage-band row in the Inbox card) only files.
  /// Spawn a deferred inline-create draft positioned directly at a Magic Plus
  /// drop target (between two rows, under a project heading, in a Today group,
  /// in an Anytime group, or on an Upcoming day) and open its inline composer
  /// right on that spot.
  private func createInlineDraftAtDrop(
    areaId: String? = nil,
    projectId: String? = nil,
    headingId: String? = nil,
    scheduledDate: Date? = nil,
    insertInto sequence: [SeptenaTask]? = nil,
    at insertion: Int? = nil,
    fromDrag: Bool = true
  ) -> Bool {
    closeActiveEditIfNeeded()
    var seed = TaskDraft(filter: filter)
    if let projectId {
      seed.projectId = projectId
      seed.areaId = nil
    } else if let areaId {
      seed.areaId = areaId
      seed.projectId = nil
    }
    if let scheduledDate {
      seed.setScheduled(scheduledDate)
    }
    let draft = seed.create(via: mutator, deferPush: true, atBottom: true)
    if let headingId {
      mutator.setHeading(id: draft.id, heading: headingId)
    }
    if let sequence, let insertion {
      applyManualOrder(ids: [draft.id], into: sequence, at: insertion)
    }
    model.noteCreated(draft.id)
    draftEditIds.insert(draft.id)
    Haptics.tick()
    AddInfoSection.tasks.notifyTilesChanged()
    Task {
      await load()
      if let loaded = items.first(where: { $0.id == draft.id }) {
        beginEdit(loaded)
      } else {
        beginEdit(draft)
      }
      scrollToTargetID = draft.id
      scrollToTargetTick += 1
    }
    return true
  }

  private func handleReorderDrop(ids: [String], target: SeptenaTask, before: Bool,
                                 refileTo group: TodayDropTarget? = nil) -> Bool {
    if TaskDragIDs.isNewTaskPayload(ids) {
      let remaining = excludingQuickAddCapture(visibleItems)
      let destination = group.map(todayDropDestination)
      if let targetIdx = remaining.firstIndex(where: { $0.id == target.id }) {
        return createInlineDraftAtDrop(
          areaId: destination?.areaId,
          projectId: destination?.projectId,
          insertInto: remaining,
          at: before ? targetIdx : targetIdx + 1
        )
      }
      return createInlineDraftAtDrop(
        areaId: destination?.areaId,
        projectId: destination?.projectId
      )
    }
    let dragged = Set(ids)
    guard !ids.isEmpty, !dragged.contains(target.id) else { return false }
    let remaining = excludingQuickAddCapture(visibleItems).filter { !dragged.contains($0.id) }
    guard let targetIdx = remaining.firstIndex(where: { $0.id == target.id }) else {
      return group.map { handleTodayMoveDrop(ids: ids, target: $0) } ?? false
    }
    // Snapshot every row the drop can rewrite (a renumber touches the whole
    // sequence), so shake / ⌘Z puts the old order back.
    let undoBefore = TaskUndo.reorderSnapshot(of: remaining.map(\.id) + ids, lane: orderLane,
                                              in: modelContext)
    if let group { _ = handleTodayMoveDrop(ids: ids, target: group) }
    applyManualOrder(ids: ids, into: remaining,
                     at: before ? targetIdx : targetIdx + 1)
    TaskUndo.recordReorder(undoBefore, context: modelContext, mutator: mutator)
    Haptics.tick()
    if touchSelectionActive { clearSelection() }
    Task { await load() }
    return true
  }

  // MARK: - Project headings (section dividers — docs/ORDERING_AND_HEADINGS_PLAN.md)

  /// The section-divider rows for the current project, in manual order. Empty
  /// for every non-project filter (headings only live inside a project).
  private var projectHeadingList: [SeptenaTask] {
    guard case .project(let pid) = filter else { return [] }
    return LocalCache.headings(inProject: pid, in: LocalStore.shared.container.mainContext)
  }

  private var projectHeadingIds: Set<String> { Set(projectHeadingList.map(\.id)) }

  /// Project detail, partitioned by heading: the un-headed block first (with
  /// the foot quick-add), then each heading as a divider row followed by its
  /// member tasks. Tasks whose `heading` points at a since-deleted divider fall
  /// back into the un-headed block. Headings never appear anywhere else (see
  /// `TaskEntity.isHeading`).
  @ViewBuilder
  private var projectGroupedRows: some View {
    let headings = projectHeadingList
    let headingIds = Set(headings.map(\.id))
    let unheaded = visibleItems.filter { t in
      guard let h = t.heading else { return true }
      return !headingIds.contains(h)
    }
    cardedRows(unheaded,
               quickMenu: { model.filingSuggestions[$0.id] != nil },
               appendQuickAdd: attachesQuickAddToVisibleCard,
               reorderable: true,
               grouped: true)
    ForEach(headings) { heading in
      headingRow(heading)
      let members = visibleItems.filter { $0.heading == heading.id }
      cardedRows(members, reorderable: true, grouped: true, magicContext: heading.title)
    }
    addSectionButton
  }

  /// A section-divider row: the heading title styled like a group header, but a
  /// real draggable row + drop target (reorder headings, or drop tasks onto it
  /// to file them under it) with a Rename / New Task / Delete context menu.
  private func headingRow(_ heading: SeptenaTask) -> some View {
    // Match the Today area/project group header (`groupHeaderBody`): same title
    // style + same top padding, and an empty leading icon column so the section
    // title lands at the SAME X as those headers (and the task text below it),
    // instead of floating further left.
    #if os(macOS)
    let headingTopPadding: CGFloat = 24
    #else
    let headingTopPadding: CGFloat = 18
    #endif
    return HStack(spacing: Theme.iconTextGap) {
      Color.clear
        .frame(width: Theme.checkboxTap)
        .offset(x: -Theme.checkboxLeadingNudge)
      Text(heading.title).sectionGroupHeaderTitleStyle()
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.top, headingTopPadding)
    .padding(.bottom, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .asListRow()
    .selectionDisabled()
    .draggable(TaskDragIDs(ids: [heading.id])) {
      Text(heading.title)
        .scaledFont(size: 13, weight: .medium)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    .modifier(TaskReorderDrop(perform: { ids, before in
      handleHeadingDrop(ids: ids, targetHeading: heading, before: before)
    }))
    .magicPlusSectionDrop(id: "mp-heading-\(heading.id)",
                          kind: .taskSection(label: "New Task in \(heading.title)")) {
      _ = handleHeadingDrop(ids: TaskDragIDs.newTask.ids, targetHeading: heading, before: true)
    }
    .contextMenu { headingContextMenu(heading) }
    .taskRowSwipeActions(
      id: "heading-\(heading.id)",
      enabled: !isInlineEditing && !selectionScope.isMulti && !isSwipeEditModeActive,
      leading: [],
      allowsLeadingFullSwipe: false,
      trailing: [
        TaskRowSwipeAction(
          id: "delete-heading",
          title: String(localized: "Delete", comment: "Swipe action delete section heading"),
          systemImage: "trash",
          tint: .red,
          role: .destructive
        ) {
          headingDeleteTarget = heading
        },
        TaskRowSwipeAction(
          id: "rename-heading",
          title: RegistryActions.title("section.rename"),
          systemImage: "pencil",
          tint: .blue
        ) {
          headingDraftTitle = heading.title
          headingRenameTarget = heading
        }
      ],
      allowsTrailingFullSwipe: false
    )
    .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
  }

  @ViewBuilder
  private func headingContextMenu(_ heading: SeptenaTask) -> some View {
    // Registry `project.heading`, the same menu the AppKit shell renders.
    RegistryMenuContent(nodes: RegistryMenuResolver.resolve(
      RegistryActions.menu("project.heading")) { id in
        switch id {
        case "section.rename":
          return .init {
            headingDraftTitle = heading.title
            headingRenameTarget = heading
          }
        case "section.newTask": return .init { startCreateUnderHeading(heading) }
        case "section.delete": return .init { headingDeleteTarget = heading }
        default: return nil
        }
      })
  }

  /// Quiet Things-style "+ Add Section" affordance at the foot of a project.
  private var addSectionButton: some View {
    Button {
      guard case .project(let pid) = filter else { return }
      headingDraftTitle = ""
      headingCreateProject = pid
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "plus")
        Text("Add Section")
      }
      .font(.septenaMeta)
      .foregroundStyle(Theme.inkSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Theme.hPadding)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainHoverRowButtonStyle())
    .asListRow()
    .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
  }

  /// A reorder drop inside a project's grouped list. The drop target is a task
  /// row: the dragged rows join the target's group (`heading`) and take manual
  /// positions around the target within that group. Cross-group filing falls
  /// out of reading `target.heading` — no separate "move to section" gesture.
  private func handleGroupedTaskDrop(ids: [String], target: SeptenaTask, before: Bool) -> Bool {
    if TaskDragIDs.isNewTaskPayload(ids) {
      guard !projectHeadingIds.contains(target.id) else { return false }
      let group = target.heading
      let groupRows = visibleItems.filter { $0.heading == group }
      let targetIdx = groupRows.firstIndex(where: { $0.id == target.id })
      return createInlineDraftAtDrop(
        headingId: group,
        insertInto: targetIdx != nil ? groupRows : nil,
        at: targetIdx.map { before ? $0 : $0 + 1 }
      )
    }
    let dragged = Set(ids)
    guard !ids.isEmpty, !dragged.contains(target.id) else { return false }
    // A heading dragged onto a task isn't meaningful — headings drop on headings.
    guard !projectHeadingIds.contains(target.id) else { return false }
    let group = target.heading   // destination group; nil = un-headed block
    let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let groupRows = visibleItems.filter { $0.heading == group && !dragged.contains($0.id) }
    guard let targetIdx = groupRows.firstIndex(where: { $0.id == target.id }) else { return false }
    for id in ids where byId[id]?.heading != group {
      mutator.setHeading(id: id, heading: group)
    }
    applyManualOrder(ids: ids, into: groupRows,
                     at: before ? targetIdx : targetIdx + 1)
    Haptics.tick()
    if touchSelectionActive { clearSelection() }
    Task { await load() }
    return true
  }

  /// A drop landed on a heading row. Headings dragged here reorder among the
  /// project's headings; tasks dragged here file under the heading (at its top).
  private func handleHeadingDrop(ids: [String], targetHeading: SeptenaTask, before: Bool) -> Bool {
    if TaskDragIDs.isNewTaskPayload(ids) {
      let members = visibleItems.filter { $0.heading == targetHeading.id }
      return createInlineDraftAtDrop(
        headingId: targetHeading.id,
        insertInto: members,
        at: 0
      )
    }
    let dragged = Set(ids)
    guard !ids.isEmpty, !dragged.contains(targetHeading.id) else { return false }
    let headingIds = projectHeadingIds
    if ids.allSatisfy({ headingIds.contains($0) }) {
      // Reorder headings among themselves.
      let remaining = projectHeadingList.filter { !dragged.contains($0.id) }
      guard let ti = remaining.firstIndex(where: { $0.id == targetHeading.id }) else { return false }
      let undoBefore = TaskUndo.positions(of: remaining.map(\.id) + ids, in: modelContext)
      applyManualOrder(ids: ids, into: remaining, at: before ? ti : ti + 1)
      TaskUndo.recordReorder(before: undoBefore, context: modelContext, mutator: mutator)
    } else {
      // Tasks dropped onto the label → file under this heading, above its first member.
      let members = visibleItems.filter { $0.heading == targetHeading.id && !dragged.contains($0.id) }
      // Heading + position ride in the filing snapshot, so one undo puts the
      // rows back where they were filed.
      let undoBefore = filingSnapshots(ids)
      for id in ids { mutator.setHeading(id: id, heading: targetHeading.id) }
      applyManualOrder(ids: ids, into: members, at: 0)
      TaskUndo.recordMove(before: undoBefore, context: modelContext, mutator: mutator)
    }
    Haptics.tick()
    if touchSelectionActive { clearSelection() }
    Task { await load() }
    return true
  }

  /// Create a heading in the current project, then re-file the tasks the alert
  /// carried (create) — used by the "Add Section" flow and rename.
  private func commitHeadingCreate(title: String, project: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    mutator.createHeading(title: trimmed, project: project)
    Task { await load() }
  }

  private func commitHeadingRename(_ heading: SeptenaTask, title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != heading.title else { return }
    mutator.update(id: heading.id, title: trimmed, notes: nil)
    Task { await load() }
  }

  /// "New Task in Section": spawn an inline-create draft already filed under the
  /// heading, so the row appears in that group as you type.
  private func startCreateUnderHeading(_ heading: SeptenaTask) {
    guard case .project(let pid) = filter else { return }
    guard !closeActiveEditIfNeeded() else { return }
    let draft = mutator.create(title: "", project: pid, source: TaskSource.app,
                               deferPush: true, atBottom: true)
    mutator.setHeading(id: draft.id, heading: heading.id)
    draftEditIds.insert(draft.id)
    Task {
      await load()
      selectOnly(draft.id)
      expandedEditId = draft.id
    }
  }

  /// Things-style footer on project / area pages: a quiet link that expands
  /// Faded tasks for this project or area, shown when Settings ▸ Lists ▸ Show
  /// faded tasks is on. Starts open; tapping the footer folds/unfolds per list.
  @ViewBuilder
  private func scopeFadedSection() -> some View {
    if scopeLoggedFilterId != nil, !fadedScopeItems.isEmpty {
      scopeFadedToggleRow
      if isScopeFadedExpanded {
        cardedRows(fadedScopeItems)
      }
    }
  }

  private var scopeFadedToggleLabel: String {
    let count = fadedScopeItems.count
    if isScopeFadedExpanded {
      return count == 1
        ? String(localized: "Hide 1 faded item",
                 comment: "Project/area footer — collapse faded tasks (singular)")
        : String(localized: "Hide \(count) faded items",
                 comment: "Project/area footer — collapse faded tasks (plural)")
    }
    return count == 1
      ? String(localized: "Show 1 faded item",
               comment: "Project/area footer — expand faded tasks (singular)")
      : String(localized: "Show \(count) faded items",
               comment: "Project/area footer — expand faded tasks (plural)")
  }

  private var scopeFadedToggleRow: some View {
    Button {
      if closeActiveEditIfNeeded() { return }
      toggleScopeFadedExpanded()
    } label: {
      Text(scopeFadedToggleLabel)
        .font(.septenaMeta)
        .monospacedDigit()
        .foregroundStyle(Theme.inkSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, TaskCardMetrics.headerLeading)
        .padding(.trailing, TaskCardMetrics.margin)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    .buttonStyle(PlainHoverRowButtonStyle())
    .padding(.top, loggedFooterGap)
    .asListRow()
    .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
  }

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
      if closeActiveEditIfNeeded() { return }
      toggleScopeLoggedExpanded()
    } label: {
      Text(scopeLoggedToggleLabel)
        .font(.septenaMeta)
        .monospacedDigit()
        .foregroundStyle(Theme.inkSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Sit the footer link on the cards' content column (over the row
        // checkboxes), not the wider page gutter, so it reads as part of the
        // list rather than a stray link at a different indent.
        .padding(.leading, TaskCardMetrics.headerLeading)
        .padding(.trailing, TaskCardMetrics.margin)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    .buttonStyle(PlainHoverRowButtonStyle())
    // Long press / right-click: registry `scope.loggedFooter` ("Clear
    // Logged…"), the same menu the AppKit footer row shows.
    .contextMenu { scopeLoggedContextMenu }
    // Blank band above the footer as tall as a group title, so it reads as
    // its own section, not glued to the last task (mz, 2026-11-20). Outside
    // the button, so the gap isn't a tap target.
    .padding(.top, loggedFooterGap)
    .asListRow()
    .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
  }

  @ViewBuilder
  private var scopeLoggedContextMenu: some View {
    RegistryMenuContent(nodes: RegistryMenuResolver.resolve(
      RegistryActions.menu("scope.loggedFooter")) { id in
        guard id == "logged.clear" else { return nil }
        return .init { requestClearLogged() }
      })
  }

  /// The project's or area's own name for the clear prompt. Falls back to the
  /// generic "Project" / "Area" label when the row is not in the snapshot.
  private var scopeDisplayName: String {
    let name: String?
    switch filter {
    case .project(let id): name = projects.first { $0.id == id }?.title
    case .area(let id): name = areas.first { $0.id == id }?.title
    default: name = nil
    }
    guard let name, !name.isEmpty else { return filter.title }
    return name
  }

  /// Ask before clearing. The ids are the footer's own set (done only, not
  /// settling, area pages area-direct only), so other projects and areas
  /// keep their logged items.
  private func requestClearLogged() {
    if closeActiveEditIfNeeded() { return }
    let ids = loggedScopeItems.map(\.id)
    guard !ids.isEmpty else { return }
    clearLoggedRequest = ClearLoggedRequest(
      ids: ids,
      copy: RegistryPrompts.clearLogged(count: ids.count, name: scopeDisplayName))
  }

  /// Soft-delete the logged items to Recently Deleted (30-day recovery). Undo
  /// is recorded here, at the gesture, never in the mutator. The toast undoes
  /// this batch only, same ticket pattern as `applyDelete`.
  private func commitClearLogged(ids: [String]) {
    guard !ids.isEmpty else { return }
    Haptics.warning()
    for id in ids {
      removeLocally(id: id)
      mutator.delete(id: id)
    }
    TaskUndo.recordDelete(ids: ids, mutator: mutator)
    let ticket = TaskUndoTicket()
    showToast(RegistryToasts.deletedBulk(count: ids.count)) {
      ticket.undo { for id in ids { mutator.restore(id: id) } }
      Task { await load() }
    }
  }

  /// Active project ids belonging to `areaId` — filing scope on area pages.
  private func childProjectIds(in areaId: String) -> Set<String> {
    Set(projects.filter { $0.area == areaId && $0.status == .active }.map(\.id))
  }

  /// Existing deadline for a target task, so the picker sheet can
  /// pre-fill its date and show "Update Deadline" / "Remove Deadline".
  private func currentDeadline(for id: String?) -> Date? {
    guard let id else { return nil }
    let pool = items
    return pool.first(where: { $0.id == id })?.deadline.flatMap(SeptenaDate.parse)
  }

  /// Existing scheduled date for a target task, so the picker sheet can
  /// pre-fill its date and show "Update Date" / "No Date".
  private func currentScheduled(for id: String?) -> Date? {
    guard let id else { return nil }
    let pool = items
    return pool.first(where: { $0.id == id })?.scheduled.flatMap(SeptenaDate.parse)
  }

  /// Existing recurrence rule for a target task, so RecurrencePickerSheet
  /// can pre-fill its controls and show "Update Repeat" / "Don't Repeat".
  private func currentRecurrence(for id: String?) -> Recurrence? {
    guard let id else { return nil }
    let pool = items
    return pool.first(where: { $0.id == id })?.recurrence
  }

  private func currentTask(id: String?) -> SeptenaTask? {
    guard let id else { return nil }
    // Include `triageItems` and `fadedScopeItems` — Inbox rows on Today and
    // faded rows in projects/areas are real, selectable rows outside `items`.
    return (triageItems + items + fadedScopeItems).first(where: { $0.id == id })
  }

  // MARK: - Keyboard navigation

  /// True when the "New task" trigger is currently a selectable row (i.e. no
  /// capture draft is already in flight — while one is, the slot hosts the
  /// inline editor, whose real task id is already in the order). When true its
  /// sentinel id joins `keyboardOrderedTaskIds` at the trigger's render position
  /// so ↑/↓ can land on it and Return activates it (see `activateRow`).
  private var showsQuickAddTriggerRow: Bool {
    if usesMagicPlusInsteadOfInboxTrigger && (filter == .today || filter == .triage) {
      return false
    }
    return allowsInlineCreate && quickAddDraftId == nil
  }

  /// The sentinel id for the quick-add trigger, or empty when it isn't shown.
  private var quickAddOrderedIds: [String] {
    showsQuickAddTriggerRow ? [Self.quickAddScrollID] : []
  }

  /// The exact visible task rows in Today's Inbox. Keep this separate from the
  /// classified-list pool so pointer rendering and keyboard traversal cannot
  /// drift when a completed row settles or the Inbox is folded.
  private var todayOpenTaskPool: [SeptenaTask] {
    chipFiltered(items).filter { $0.status == .open || model.settle.isSettling($0.id) }
  }

  private var todayLooseInboxRows: [SeptenaTask] {
    todayOpenTaskPool.filter(\.isUnfiled)
  }

  private var renderedTodayInboxRows: [SeptenaTask] {
    excludingQuickAddCapture(chipFiltered(triageItems) + todayLooseInboxRows)
  }

  /// `quickAddLine` replaces the sentinel with the real draft row while the
  /// Inbox editor is active. A draft created from an area/project header stays
  /// in that classified group instead, so it never occupies the Inbox cursor.
  private var todayInboxKeyboardIDs: [String] {
    guard !inboxCollapsed else { return [] }
    var ids = renderedTodayInboxRows.map(\.id)
    if let draft = quickAddCaptureTask,
       quickAddGroupTarget == nil || quickAddGroupTarget == .inbox {
      ids.append(draft.id)
    } else {
      ids.append(contentsOf: quickAddOrderedIds)
    }
    return ids
  }

  /// Flat ordered list of task IDs in the same order they're rendered.
  /// Drives ↑/↓ and ⌘↑/⌘↓ traversal. The quick-add trigger (`quickAddOrderedIds`)
  /// is spliced in at the render position of its "New task" row.
  private var keyboardOrderedTaskIds: [String] {
    switch filter {
    case .today:
      // Inbox section = agent proposals + loose today tasks, rendered above
      // the main list. The quick-add line sits at the foot of the Inbox card,
      // so its sentinel follows the loose rows. Classified tasks follow —
      // grouped or flat per setting.
      let classified = todayOpenTaskPool.filter { $0.project != nil || $0.area != nil }
      let classifiedIds: [String]
      if todayGroupByList {
        classifiedIds = orderedFromGroupedOpen(pool: classified)
      } else {
        // Same sequence `ungroupedOpenItems` renders: by list, Today's own
        // order inside each list (#66).
        classifiedIds = orderedFromGroupedOpen(pool: classified)
      }
      // The Get started steps sit above everything, under their notice.
      return todayNoticeSteps.map(\.selectionID) + todayInboxKeyboardIDs + classifiedIds
    case .unscheduled, .starred:
      return orderedFromGroupedOpen(pool: items) + quickAddOrderedIds
    case .upcoming:
      // Upcoming has no inline trigger (`allowsInlineCreate` false) → sentinel empty.
      return upcomingBuckets().flatMap { $0.tasks.map(\.id) }
    case .project, .area:
      // Foot-of-card quick-add sits after the open rows, before the faded & logged scopes.
      var ids = visibleItems.map(\.id) + quickAddOrderedIds
      if isScopeFadedExpanded {
        ids.append(contentsOf: fadedScopeItems.map(\.id))
      }
      if isScopeLoggedExpanded {
        ids.append(contentsOf: loggedScopeItems.map(\.id))
      }
      return ids
    default:
      return visibleItems.map(\.id) + quickAddOrderedIds
    }
  }

  /// Mirrors the rendering order of `groupedOpenItems` so arrow keys traverse
  /// rows in exactly the order the user sees them.
  private func orderedFromGroupedOpen(pool: [SeptenaTask]) -> [String] {
    TaskListOrder.byList(pool, areas: areas, projects: projects).map(\.id)
  }

  /// ⌘R — open the inline editor for the focused row. iPad resolves via
  /// `effectiveSelectionId`; macOS menu command uses explicit selection only.
  private func editSelected() {
    guard expandedEditId == nil,
          !composerIsOpen, whenSheet == nil, !showingMoveSheet, !showingRepeatSheet,
          !nav.showQuickFind,
          let id = effectiveSelectionId(),
          let task = currentTask(id: id), task.status != .done
    else { return }
    beginEdit(task)
  }

  // These three resolve a command to a handler-or-nil for the CURRENT selection.
  // Both command surfaces use them — the macOS `focusedSceneValue` menu and the
  // iPad hidden-shortcut buttons (`iPadRowCommandActions`) — so they are not
  // platform-gated: a nil handler is what disables the item on either surface.
  /// The action behind the ⌘R "Edit Details…" menu command. Nil — so the menu
  /// item disables and ⌘R falls through — when a text field / picker sheet is
  /// active or no plain open row is selected. Uses an EXPLICIT selection (not
  /// `effectiveSelectionId`'s first-row fallback).
  private var editDetailsSelectedAction: (() -> Void)? {
    guard expandedEditId == nil,
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
    guard expandedEditId == nil,
          !composerIsOpen, whenSheet == nil, !showingMoveSheet, !showingRepeatSheet,
          !nav.showQuickFind, filter != .recentlyDeleted,
          !orderedActionIDs().isEmpty
    else { return nil }
    return { duplicate(orderedActionIDs()) }
  }

  private var copySelectedAction: (() -> Void)? {
    guard expandedEditId == nil,
          !composerIsOpen, whenSheet == nil, !showingMoveSheet, !showingRepeatSheet,
          !nav.showQuickFind, filter != .recentlyDeleted,
          !orderedActionIDs().isEmpty
    else { return nil }
    return { copyTasks(orderedActionIDs()) }
  }

  /// The pasteboard text for a set of task ids — one title per line. The single
  /// definition of what copying a task yields, shared by the ⌘C command path
  /// (`copyTasks`, which writes the pasteboard directly) and macOS's
  /// `.onCopyCommand` (which must hand back an item provider instead). The two
  /// used to spell the same join out separately.
  private func copyPayload(for ids: [String]) -> String? {
    let titles = ids.compactMap { currentTask(id: $0)?.title }
    guard !titles.isEmpty else { return nil }
    return titles.joined(separator: "\n")
  }

  private func copyTasks(_ ids: [String]) {
    guard let text = copyPayload(for: ids) else { return }
    SeptenaPasteboard.copy(text)
    Haptics.tick()
  }

  /// Clone task(s) into brand-new ones (new ids) carrying the same fields.
  private func duplicate(_ ids: [String]) {
    guard !ids.isEmpty else { return }
    Haptics.tick()
    var lastCopyId: String?
    for id in ids {
      guard let task = currentTask(id: id) else { continue }
      let copy = mutator.duplicate(task)
      model.noteCreated(copy.id)
      lastCopyId = copy.id
    }
    guard let lastCopyId else { return }
    Task {
      await load()
      selectOnly(lastCopyId)
    }
  }

  private func toggleSelected() {
    // ⌘K on Get started steps ticks them (or unticks them, when every
    // selected step is already done), like completing tasks.
    let steps = selectedNoticeSteps
    if !steps.isEmpty {
      let reopen = steps.allSatisfy(\.done)
      Haptics.tick()
      for step in steps {
        if reopen { TaskNotices.reopenStep(step.id) } else { TaskNotices.completeStep(step.id) }
      }
      motion.run(.easeOut(duration: 0.2)) { noticeEpoch += 1; refreshTodayNotices() }
    }
    let ids = orderedActionIDs()
    guard !ids.isEmpty else { return }
    for id in ids {
      guard let t = currentTask(id: id) else { continue }
      toggle(t)
    }
    if touchSelectionActive { clearSelection() }
  }

  /// Resolve the row a single-target keyboard shortcut should act on: a
  /// selected row when there is one, otherwise the first row in the list
  /// (so the first ⌘T after launch isn't a silent no-op). Sets `selection`
  /// as a side effect so the highlight follows.
  private func effectiveSelectionId() -> String? {
    if let id = selection.first(where: { currentTask(id: $0) != nil }) { return id }
    // Never a Get started step: no task command applies to one.
    guard let first = keyboardOrderedTaskIds.first(where: {
      TaskNoticeStep.stepID(fromSelection: $0) == nil
    }) else { return nil }
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
    if touchSelectionActive { clearSelection() }
  }

  /// Context menu / ⌘T "Remove from Today" — clears every arrived Today signal
  /// via the mutator, then drops ratified rows off the in-memory Today buckets
  /// immediately (same pattern as delete's `removeLocally`) before the async
  /// reload lands.
  private func applyRemoveFromToday(_ ids: [String]) {
    Haptics.tick()
    let undoBefore = scheduleSnapshots(ids)
    for id in ids {
      mutator.removeFromToday(id: id)
      mutator.acknowledge(id: id)
    }
    TaskUndo.recordScheduleChange(
      name: RegistryActions.title("task.toggleToday", .remove),
      before: undoBefore, context: modelContext, mutator: mutator)
    if filter == .today {
      func drop(_ list: inout [SeptenaTask]) {
        list.removeAll { ids.contains($0.id) }
      }
      drop(&items)
    }
    Task { await load() }
  }

  /// Pin tasks to Today and play the amber promote flash on each row.
  private func promoteToToday(_ ids: [String]) {
    let undoBefore = scheduleSnapshots(ids)
    for id in ids {
      mutator.moveToToday(id: id, today: true)
      promoteFlash.flash(id)
    }
    // Recorded here rather than at each caller so no entry point can forget.
    // `applyScheduledWhen` also records around its whole body; both land in
    // one undo group because `TaskUndo.manager.groupsByEvent` is true, so a
    // single gesture stays a single ⌘Z.
    TaskUndo.recordScheduleChange(
      name: RegistryActions.title("task.toggleToday", .add),
      before: undoBefore, context: modelContext, mutator: mutator)
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

  /// ⌘M / ⌘⇧M — open the Move destination picker for the focused row(s).
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

  /// ⌥⌘K — retire the selected row(s) as cancelled. Selection is NOT cleared
  /// (unlike delete): a cancelled row keeps its place through the settle beat,
  /// so the row you acted on stays the row under the cursor.
  private func cancelSelected() {
    let ids = orderedActionIDs()
    guard !ids.isEmpty else { return }
    for id in ids { applyCancel(id) }
    if touchSelectionActive { clearSelection() }
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
    recordingSchedule(String(localized: "Change Repeat", comment: "Undo action name"),
                      [id]) {
      mutator.setRecurrence(id: id, recurrence: rule)
    }
    Task { await load() }
  }

  private func applyReminder(id: String, reminder: TaskReminder?) {
    Haptics.tick()
    recordingSchedule(String(localized: "Change Reminder", comment: "Undo action name"),
                      [id]) {
      mutator.setReminder(id: id, reminder: reminder)
    }
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
    model.settle.schedule(id) {
      motion.run(Theme.Motion.settle) { model.settle.endSettle(id) }
    }
    motion.run(Theme.Motion.settle) { flipStatus(id: id, to: .cancelled) }
    model.noteCompleted(id, done: true)
    mutator.cancel(id: id)
    // Shake / ⌘Z reopens it, same inverse the Mac shell uses.
    TaskUndo.recordCancel(ids: [id], mutator: mutator)
  }

  private func applyDelete(_ id: String) {
    Haptics.warning()
    let title = currentTask(id: id)?.title ?? ""
    // Remove from the visible buckets immediately — the row is filtered
    // from LocalCache via `pendingDeletion`, but the in-memory @State
    // arrays power the current screen and have to be poked separately.
    removeLocally(id: id)
    mutator.delete(id: id)
    TaskUndo.recordDelete(ids: [id], mutator: mutator)
    // Show undo snackbar (not in the Recently Deleted view — there the
    // gesture is always intentional and Restore is a first-class action).
    guard filter != .recentlyDeleted else { return }
    // The toast undoes THIS delete only. While the delete is still the newest
    // entry it goes through the shared stack (so the toast and ⌘Z agree and no
    // stale entry is left); once anything newer landed, a plain
    // `TaskUndo.undo()` would take back that newer action instead, so the
    // ticket restores the row directly.
    let ticket = TaskUndoTicket()
    showToast(RegistryToasts.deletedSingle(title: title)) {
      ticket.undo { mutator.restore(id: id) }
      Task { await load() }
    }
  }

  /// Present the bottom snackbar. The overlay's `.task(id:)` owns the
  /// auto-dismiss; this just sets the payload (a fresh id restarts the clock).
  private func showToast(_ message: String, undo: (() -> Void)? = nil) {
    toastStore.show(message, undo: undo)
  }

  /// Re-home one task. Returns false when the row is gone. Undo is recorded by
  /// the caller around the whole batch (`applyMove`), from store snapshots.
  @discardableResult
  private func applyMoveCore(id: String, areaId: String?, projectId: String?) -> Bool {
    guard let task = currentTask(id: id) else { return false }
    let wasInTriage = task.isInTriageBand
    let chosenKind: SuggestionEngine.Suggestion.Kind? =
      projectId != nil ? .project : (areaId != nil ? .area : nil)
    let chosenId = projectId ?? areaId
    recordImplicitRejectionIfMismatch(task: task,
                                      chosenKind: chosenKind,
                                      chosenId: chosenId)
    // One save per task, the same call the AppKit shell makes: the project
    // wins over the area, and Inbox (both nil) clears area, project and
    // heading together.
    mutator.moveToList(id: id, area: areaId, project: projectId)
    mutator.acknowledge(id: id)
    if filter == .today, wasInTriage { promoteFlash.flash(id) }
    return true
  }

  /// True when `task` already lives where a move to (`areaId`, `projectId`)
  /// would put it. Such a move is a no-op: no write, no toast, no undo step.
  private func isTask(_ task: SeptenaTask, alreadyAt areaId: String?, _ projectId: String?) -> Bool {
    if let projectId { return task.project == projectId }
    return task.project == nil && task.area == areaId
  }

  /// Filing state as stored right now, for `TaskUndo.recordMove`.
  private func filingSnapshots(_ ids: [String]) -> [TaskUndo.FilingSnapshot] {
    ids.compactMap { LocalCache.task(id: $0, in: modelContext) }
      .map(TaskUndo.FilingSnapshot.init)
  }

  private func destinationName(areaId: String?, projectId: String?) -> String {
    projectId.flatMap { pid in projects.first { $0.id == pid }?.title }
      ?? areaId.flatMap { aid in areas.first { $0.id == aid }?.title }
      ?? TaskFilter.triage.title
  }

  private func applyMove(id: String, areaId: String?, projectId: String?) {
    applyMove([id], areaId: areaId, projectId: projectId)
  }

  /// Every move from this list (context menu, Move sheet, Today-group drop)
  /// lands on the shared undo stack, and the toast's Undo goes through the
  /// same entry, so the toast, shake and ⌘Z all reverse the same thing.
  private func applyMove(_ ids: [String], areaId: String?, projectId: String?) {
    let ids = ids.filter { id in
      guard let task = currentTask(id: id) else { return false }
      return !isTask(task, alreadyAt: areaId, projectId)
    }
    guard !ids.isEmpty else { return }
    Haptics.tick()
    let before = filingSnapshots(ids)
    // Apply in reverse so `TaskOrder.topPosition` lands `ids[0]` at the very
    // top followed by `ids[1]`, `ids[2]`, ... preserving visible selection order.
    var movedSet: Set<String> = []
    for id in ids.reversed() {
      if applyMoveCore(id: id, areaId: areaId, projectId: projectId) {
        movedSet.insert(id)
      }
    }
    let moved = ids.filter { movedSet.contains($0) }
    guard !moved.isEmpty else { return }
    let undoBefore = before.filter { movedSet.contains($0.id) }
    TaskUndo.recordMove(before: undoBefore, context: modelContext, mutator: mutator)
    if touchSelectionActive { clearSelection() }
    let ticket = TaskUndoTicket()
    Task { await load() }
    let destName = destinationName(areaId: areaId, projectId: projectId)
    let message = RegistryToasts.movedBulk(count: moved.count, destination: destName)
    showToast(message) {
      ticket.undo { TaskUndo.restore(undoBefore, using: mutator) }
      Task { await load() }
    }
  }

  private func applyMoveToSelection(_ ids: [String], areaId: String?, projectId: String?) {
    applyMove(ids, areaId: areaId, projectId: projectId)
  }

  private func todayDropDestination(_ target: TodayDropTarget) -> (areaId: String?, projectId: String?) {
    switch target {
    case .inbox:
      return (nil, nil)
    case .area(let areaId):
      return (areaId, nil)
    case .project(let projectId):
      return (nil, projectId)
    }
  }

  private func isTask(_ task: SeptenaTask, alreadyIn target: TodayDropTarget) -> Bool {
    switch target {
    case .inbox:
      return task.isUnfiled
    case .area(let areaId):
      return task.project == nil && task.area == areaId
    case .project(let projectId):
      return task.project == projectId
    }
  }

  private func handleTodayMoveDrop(ids: [String], target: TodayDropTarget) -> Bool {
    guard filter == .today else { return false }
    if TaskDragIDs.isNewTaskPayload(ids) {
      if target == .inbox && inboxCollapsed {
        a11yAnimate(.easeInOut(duration: 0.2)) { inboxCollapsed = false }
      }
      let destination = todayDropDestination(target)
      let groupRows = excludingQuickAddCapture(visibleItems).filter { isTask($0, alreadyIn: target) }
      return createInlineDraftAtDrop(
        areaId: destination.areaId,
        projectId: destination.projectId,
        insertInto: groupRows.isEmpty ? nil : groupRows,
        at: groupRows.isEmpty ? nil : 0
      )
    }
    let moving = ids.filter { id in
      guard let task = currentTask(id: id), !task.isHeading else { return false }
      return !isTask(task, alreadyIn: target)
    }
    guard !moving.isEmpty else { return false }
    let destination = todayDropDestination(target)
    applyMove(moving, areaId: destination.areaId, projectId: destination.projectId)
    return true
  }

  private func todayMoveDrop(_ target: TodayDropTarget?) -> TaskMoveDrop {
    TaskMoveDrop(perform: target.map { target in
      { ids in handleTodayMoveDrop(ids: ids, target: target) }
    })
  }

  private func handleUpcomingDateDrop(ids: [String], dateKey: String) -> Bool {
    guard filter == .upcoming, let date = SeptenaDate.parse(dateKey) else { return false }
    if TaskDragIDs.isNewTaskPayload(ids) {
      return createInlineDraftAtDrop(scheduledDate: date)
    }
    applyWhenToSelection(ids, kind: .scheduled, date: date)
    return true
  }

  private func handleGroupedListMoveDrop(ids: [String], areaId: String?, projectId: String?) -> Bool {
    if TaskDragIDs.isNewTaskPayload(ids) {
      return createInlineDraftAtDrop(areaId: areaId, projectId: projectId)
    }
    applyMove(ids, areaId: areaId, projectId: projectId)
    return true
  }

  private func applyWhenToSelection(_ ids: [String], kind: WhenKind, date: Date?) {
    guard !ids.isEmpty else { return }
    guard kind == .scheduled, let date else {
      for id in ids { applyWhen(id: id, kind: kind, date: date) }
      if touchSelectionActive { clearSelection() }
      return
    }

    let movedFixedIDs = ids.filter { id in
      guard let task = currentTask(id: id), let rule = task.recurrence,
            !rule.afterCompletion else { return false }
      return SeptenaDate.format(date) != task.scheduled
    }
    if !movedFixedIDs.isEmpty {
      reschedulePrompt = FixedReschedulePrompt(taskIDs: ids, date: date)
      if touchSelectionActive { clearSelection() }
      return
    }
    for id in ids { applyWhen(id: id, kind: kind, date: date) }
    if touchSelectionActive { clearSelection() }
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
        .asTaskRow(id: task.id,
                   isSelected: selection.contains(task.id),
                   isComplete: task.status == .done)
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
      deferredCreate: draftEditIds.contains(task.id),
      onClose: { collapseEdit() },
      onToggleComplete: { toggle(task) },
      titleMatchID: "edit-title-\(task.id)",
      checkboxMatchID: "edit-checkbox-\(task.id)",
      heroMatchNS: nil, // hero-glide removed — see note by former `editTitleNS`
      heroMatchIsSource: expandedEditId == task.id,
      showsTodayIndicator: filter != .today,
      onDone: {
        if draftEditIds.contains(task.id) { draftEditIds.remove(task.id) }
        clearQuickAddCaptureSlot(for: task.id)
        repatchTask(id: task.id)
        // persistOnce can run mid-edit: the inline host is a LazyVStack, so
        // `.onDisappear` fires when the row merely wraps or scrolls out of the
        // materialization window. A full `load()` here would re-diff the list
        // under a focused title field and drop the caret at the end.
        reloadOrDeferWhileEditing()
      },
      // Fired after the editor's autosave has run on teardown: if this was an
      // inline-create draft the autosave left untouched (no title), drop it now.
      // Deterministically ordered after the save (same `.onDisappear`), so a
      // typed-then-tapped-away task is committed, not purged.
      onVanish: {
        // `.onDisappear` fires for a row that merely scrolled out of the
        // `LazyVStack`'s materialization window, not just for a real fold — so
        // check that the editor is actually closed before treating this as
        // teardown. Without the guard, a brand-new draft the user hadn't typed
        // into yet could be purged out from under them mid-edit.
        guard expandedEditId != task.id else { return }
        guard draftEditIds.contains(task.id) else { return }
        draftEditIds.remove(task.id)
        purgeDraftIfEmpty(id: task.id)
      }
    )
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    // No own card or screen margin: the surrounding `TaskCardChrome` slice paints
    // the card surface + margin (and sets `rowHInset`), so the editor simply
    // expands the row IN PLACE inside the group card instead of floating as a
    // separate rounded box. Vertical inset lives in `TaskComposerCard` (same
    // `rowVInset` as closed rows).
    .id(task.id)
    .transition(.opacity)
    // `TaskComposerCard` owns Escape: it saves and folds the row, the same as
    // tapping away. The selection remains on the closed row afterwards.
    .septenaOnRightClick {
      if !selection.contains(task.id) { selectOnly(task.id) }
    }
    // The context menu is attached by the caller, after the card chrome
    // (`cardedRows` / `quickAddLine`), so the lift carries the card.
  }

  @ViewBuilder
  private func row(_ task: SeptenaTask, quickMenu: Bool = false) -> some View {
    // No inline "⋯" button on task rows (completion is the checkbox; iOS adds
    // horizontal swipe actions via `.taskRowSwipeActions` in `cardedRows`; deep-
    // press / right-click `.contextMenu` carries the full menu). `quickMenu`
    // still gates the one-tap "file here" suggestion capsule, now threaded into
    // the row as the inboard-most trailing accessory (left of the date).
    staticRow(task, accessory: filter == .faded
              ? keepFadedCapsule(for: task)
              : (quickMenu ? suggestionCapsule(for: task) : nil))
    .taskRowSwipe(
      allowSelect: allowsTouchMultiSelect,
      isSelected: selection.contains(task.id),
      onToggleSelect: { toggleTouchSelection(task.id) },
      leadingAction: leadingSwipeAction(for: task)
    )
    // Drag a row (or the whole selection) to a sidebar area/project to re-home
    // it, onto an Area's project card, or between rows of a manually-ordered
    // list to reorder. `.draggable` pairs with `SidebarTaskDrop`, `TaskMoveDrop`,
    // and `TaskReorderDrop`. On iOS the lift starts from the system long-press
    // drag (UIKit arbitrates it against tap, horizontal swipe-to-select, and
    // context-menu gestures).
    .draggable(dragPayload(for: task)) {
      let payload = dragPayload(for: task)
      TaskDragStackPreview(
        title: task.title,
        count: payload.ids.count,
        accent: theme.color(for: "tasks")
      )
    }
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

  /// One-tap "Keep" capsule shown on each row in the Faded pile
  /// (`docs/TASK_FADE_SPEC.md` §4). Brings the task back to its list in one
  /// undoable gesture.
  private func keepFadedCapsule(for task: SeptenaTask) -> AnyView? {
    AnyView(
      Button {
        keepFadedTasks([task.id])
      } label: {
        Text(RegistryActions.title("task.keepFaded"))
          .scaledFont(size: 12, weight: .medium)
          .lineLimit(1)
          .padding(.horizontal, 10)
          .padding(.vertical, 3)
          .background(Capsule().fill(Theme.mutedSurface))
          .foregroundStyle(Theme.inkPrimary)
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .inlineHover(capsule: true)
      .fixedSize()
      .accessibilityLabel(String(localized: "Keep \(task.title)", comment: "Faded pile keep button accessibility"))
    )
  }

  private func keepFadedTasks(_ ids: [String]) {
    let snapshots = ids.compactMap { currentTask(id: $0) }.map(TaskUndo.FadedSnapshot.init)
    guard !snapshots.isEmpty else { return }
    Haptics.tick()
    mutator.keepFaded(ids: snapshots.map(\.id))
    TaskUndo.recordKeepFaded(before: snapshots, mutator: mutator)
    for id in snapshots.map(\.id) { removeLocally(id: id) }
    Task { await load() }
  }

  private func dropFadedTasks(_ ids: [String]) {
    let snapshots = ids.compactMap { currentTask(id: $0) }.map(TaskUndo.FadedSnapshot.init)
    guard !snapshots.isEmpty else { return }
    Haptics.warning()
    mutator.dropFaded(ids: snapshots.map(\.id))
    TaskUndo.recordSweepDrop(before: snapshots, mutator: mutator)
    for id in snapshots.map(\.id) { removeLocally(id: id) }
    Task { await load() }
  }

  /// The canonical closed row — checkbox + title + subtitle/date — plus the
  /// open/select gestures. Tapping it opens the expand-in-place composer (touch)
  /// or selects (macOS, opening on double-click).
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
      showsFadedIndicator: filter != .faded,
      isListSelected: selection.contains(task.id),
      checkboxDimmed: touchSelectionActive,
      accessory: accessory,
      checklistSummary: checklistCounts[task.id],
      tagChips: LocalCache.resolvedTags(for: task, tagsByID: tagsByID),
      titleMatchID: "edit-title-\(task.id)",
      checkboxMatchID: "edit-checkbox-\(task.id)",
      heroMatchNS: nil, // hero-glide removed — see note by former `editTitleNS`
      heroMatchIsSource: expandedEditId != task.id,
      onToggle: {
        if touchSelectionActive {
          Haptics.tap()
          toggleTouchSelection(task.id)
        } else {
          toggle(task)
        }
      },
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
    // No `.contextMenu` here: `cardedRows` attaches it after the card chrome,
    // so the iOS lift carries the card background, not just the text.
  }

  /// Foot quick-add for grouped lists (Anytime) — its own card on the canvas.
  @ViewBuilder
  private var quickAddFootCard: some View {
    if allowsInlineCreate {
      let isEditingHere = quickAddCaptureTask.map { expandedEditId == $0.id } == true
      quickAddLine()
        .asListRow()
        .taskCardChrome(.solo,
                        isSelected: isEditingHere ? false : selection.contains(Self.quickAddScrollID),
                        isEditing: isEditingHere)
        .zIndex(isEditingHere ? 1 : 0)
        .inlineEditDimmed(isInlineEditing && !isEditingHere, onDismiss: collapseEdit)
    }
  }

  /// Header quick-add when a creatable list is empty (sits above the empty state).
  @ViewBuilder
  private var quickAddTopRow: some View {
    if allowsInlineCreate {
      let isEditingHere = quickAddCaptureTask.map { expandedEditId == $0.id } == true
      if usesSingleOpenTaskCard || isEditingHere {
        quickAddLine()
          .asListRow()
          .taskCardChrome(.solo,
                          isSelected: isEditingHere ? false : selection.contains(Self.quickAddScrollID),
                          isEditing: isEditingHere)
          .zIndex(isEditingHere ? 1 : 0)
          .inlineEditDimmed(isInlineEditing && !isEditingHere, onDismiss: collapseEdit)
      } else {
        quickAddLine()
          .asListRow()
          .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
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
        // The capture slot's open editor keeps its menu. Its card chrome is
        // applied by the caller, which also carries the trigger row (no menu).
        .contextMenu { taskContextMenu(for: task) }
    } else if quickAddDraftId == nil {
      // The primary trigger is a first-class *selectable* row: it carries the
      // quick-add sentinel id (also in `keyboardOrderedTaskIds`), so arrow-nav
      // lands on it and click / double-click / tap / Return all route through
      // the container's `onActivate` → `activateRow` → `startCreate()`. The
      // `asTaskRow` id doubles as the scroll target, so no extra `.id` needed.
      QuickAddTriggerRow()
        .asTaskRow(id: Self.quickAddScrollID,
                   isSelected: selection.contains(Self.quickAddScrollID))
    } else {
      // A capture is in flight in ANOTHER slot (grouped Today: the header "+"
      // hosts the editor in its area/project section while the Inbox keeps its
      // trigger row). This one is NOT keyboard-reachable (absent from
      // `keyboardOrderedTaskIds` while a draft exists) and must NOT carry the
      // scroll id — if it did, `startCreate`'s force-scroll resolves to the
      // Inbox row at the top, the viewport jumps away, and the LazyVStack tears
      // down the just-opened editor (purging the empty draft via `onVanish`). A
      // plain tap is enough for this rare secondary slot.
      QuickAddTriggerRow()
        .contentShape(Rectangle())
        .onTapGesture { startCreate() }
    }
  }

  /// Single source of truth for per-row actions. Used by the per-row
  /// `.contextMenu` AND the batch action bar — `target` selects which.
  /// Folding both callers through here means new actions land in both
  /// surfaces at once.
  @ViewBuilder
  private func rowActionsMenu(target: ActionTarget) -> some View {
    if filter == .recentlyDeleted {
      // Recently Deleted (registry `task.recentlyDeleted`): only Restore and
      // Delete Permanently — no scheduling, no move, no normal task lifecycle
      // actions apply to trashed rows.
      RegistryMenuContent(nodes: RegistryMenuResolver.resolve(
        RegistryActions.menu("task.recentlyDeleted")) { id in
          switch id {
          case "task.restore":
            return .init {
              for id in target.ids {
                mutator.restore(id: id)
                removeLocally(id: id)
              }
              Task { await load() }
            }
          case "task.deletePermanently":
            return .init {
              Haptics.warning()
              for id in target.ids {
                removeLocally(id: id)
                mutator.purge(id: id)
              }
            }
          default: return nil
          }
        })
    } else if filter == .faded || (!target.tasks.isEmpty && target.tasks.allSatisfy(\.isFaded)) {
      // Faded pile (registry `task.faded`, `docs/TASK_FADE_SPEC.md` §4): Keep
      // restores to the task's original list with undo; Let Go cancels with
      // dropReason = "faded".
      RegistryMenuContent(nodes: RegistryMenuResolver.resolve(
        RegistryActions.menu("task.faded")) { id in
          switch id {
          case "task.keepFaded": return .init { keepFadedTasks(target.ids) }
          case "task.letGoFaded": return .init { dropFadedTasks(target.ids) }
          case "task.delete":
            return .init(variant: target.count > 1 ? .plural : .base) {
              Haptics.warning()
              for id in target.ids { applyDelete(id) }
            }
          default: return nil
          }
        })
    } else {
      TaskListRowContextMenu(
        target: target,
        filter: filter,
        rankedSuggestions: rankedSuggestions(for: target),
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
        onToggleStar: { ids, starred in
          Haptics.tick()
          recordingSchedule(starred
                            ? RegistryActions.title("task.toggleStar", .add)
                            : RegistryActions.title("task.toggleStar", .remove),
                            ids) {
            for id in ids { mutator.setStarred(id: id, starred: starred) }
          }
          Task { await load() }
        },
        onToggleComplete: { ids in
          for id in ids {
            if let task = currentTask(id: id) { toggle(task) }
          }
        },
        onOpenWhen: { target in
          whenSheet = WhenSheet(taskIds: target.ids, kind: .scheduled)
        },
        onOpenDeadline: { target in
          whenSheet = WhenSheet(taskIds: target.ids, kind: .deadline)
        },
        onOpenReminder: { task in
          reminderTargetId = task.id
        },
        onOpenTags: { target in
          tagsTargetIds = target.ids
        },
        onClearSchedule: { ids in
          for id in ids { applyWhen(id: id, kind: .scheduled, date: nil) }
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
        sections: sectionMoveTargets,
        onMoveToSection: { heading in fileIntoHeading(target.ids, heading: heading) },
        onOpenRepeat: { task in
          repeatTargetId = task.id
          showingRepeatSheet = true
        },
        onSetRepeatPaused: { ids, paused in
          Haptics.tick()
          for id in ids { mutator.setRecurrencePaused(id: id, paused: paused) }
          Task { await load() }
        },
        onCreateNextCopy: { task in
          Haptics.tick()
          _ = mutator.createNextOccurrence(id: task.id)
          Task { await load() }
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

  /// Leading iOS swipe actions (and VoiceOver accessibility actions) for a task
  /// row, sharing the exact same mutator/undo/haptic paths as `rowActionsMenu`
  /// (`docs/IOS_SWIPE_ACTIONS_SPEC.md` §2).
  private func swipeLeadingActions(for task: SeptenaTask) -> [TaskRowSwipeAction] {
    if filter == .recentlyDeleted {
      return [
        .registry("task.restore", tint: TaskRowSwipeAction.tint(for: "task.restore")) {
          Haptics.tick()
          mutator.restore(id: task.id)
          removeLocally(id: task.id)
          Task { await load() }
        }
      ]
    }
    if filter == .faded || task.isFaded {
      return [
        .registry("task.keepFaded", tint: TaskRowSwipeAction.tint(for: "task.keepFaded")) {
          keepFadedTasks([task.id])
        }
      ]
    }
    let isProposal = task.source == TaskSource.mcp && task.acknowledgedAt == nil
    // The registry's `swipeActions` slots; an agent proposal swaps the Today
    // slot for Accept.
    return TaskRowSwipeAction.leading { id in
      switch id {
      case "task.toggleToday":
        if isProposal {
          return TaskRowSwipeAction(
            id: "accept",
            title: String(localized: "Accept", comment: "Swipe action accept agent proposal"),
            systemImage: "checkmark",
            tint: .green
          ) {
            Haptics.tick()
            promoteToToday([task.id])
            mutator.acknowledge(id: task.id)
            Task { await load() }
          }
        }
        if task.isOnToday {
          return .registry(id, variant: .remove,
                           systemImage: RegistryIcons.sfSymbol(for: "action.today_remove"),
                           tint: .gray) {
            applyRemoveFromToday([task.id])
          }
        }
        return .registry(id, tint: TaskRowSwipeAction.tint(for: id)) {
          Haptics.tick()
          promoteToToday([task.id])
          mutator.acknowledge(id: task.id)
          Task { await load() }
        }
      case "task.when":
        return .registry(id, tint: TaskRowSwipeAction.tint(for: id)) {
          whenSheet = WhenSheet(taskIds: [task.id], kind: .scheduled)
        }
      default:
        return nil
      }
    }
  }

  /// Trailing iOS swipe actions (and VoiceOver accessibility actions) for a
  /// task row. Full swipe is intentionally disabled on destructive actions
  /// (`docs/IOS_SWIPE_ACTIONS_SPEC.md` §2).
  private func swipeTrailingActions(for task: SeptenaTask) -> [TaskRowSwipeAction] {
    if filter == .recentlyDeleted {
      return [
        .registry("task.deletePermanently", tint: TaskRowSwipeAction.tint(for: "task.deletePermanently")) {
          permanentDeleteConfirmTask = task
        }
      ]
    }
    if filter == .faded || task.isFaded {
      return [
        .registry("task.delete", tint: TaskRowSwipeAction.tint(for: "task.delete")) {
          Haptics.warning()
          applyDelete(task.id)
        },
        .registry("task.letGoFaded", tint: TaskRowSwipeAction.tint(for: "task.letGoFaded")) {
          dropFadedTasks([task.id])
        }
      ]
    }
    let isProposal = task.source == TaskSource.mcp && task.acknowledgedAt == nil
    return TaskRowSwipeAction.trailing { id in
      switch id {
      case "task.delete":
        let delete = {
          Haptics.warning()
          applyDelete(task.id)
        }
        if isProposal {
          return TaskRowSwipeAction(
            id: id,
            title: String(localized: "Dismiss", comment: "Swipe action dismiss agent proposal"),
            systemImage: RegistryActions.sfSymbols[id] ?? "trash",
            tint: .red,
            role: .destructive,
            perform: delete)
        }
        return .registry(id, tint: TaskRowSwipeAction.tint(for: id), perform: delete)
      case "task.move":
        return .registry(id, tint: TaskRowSwipeAction.tint(for: id)) {
          moveTargetIds = [task.id]
          showingMoveSheet = true
        }
      default:
        return nil
      }
    }
  }

  /// The headings Move to Section ▸ offers — the reliable, standard-macOS way
  /// to file a task into a project heading (drag-to-section also works, but
  /// pointer drag in a custom scroll list is finicky on macOS). Project pages
  /// only; the registry drops the empty submenu elsewhere.
  private var sectionMoveTargets: [SeptenaTask] {
    if case .project = filter { return projectHeadingList }
    return []
  }

  /// File `ids` under `heading` (nil = the un-headed block) at the foot of that
  /// group, so a menu-move lands where the user expects rather than wherever the
  /// task's old order key happens to sort.
  private func fileIntoHeading(_ ids: [String], heading: String?) {
    let members = visibleItems.filter { $0.heading == heading && !ids.contains($0.id) }
    let slots = TaskOrder.positions(count: ids.count, above: members.last?.orderKey, below: nil)
    for (id, pos) in zip(ids, slots) {
      mutator.setHeading(id: id, heading: heading)
      mutator.reorder(id: id, toPosition: pos)
    }
    Haptics.pick()
    Task { await load() }
  }

  /// Ranked filing picks for one open task — single source for the context
  /// menu's "Suggested" section and the one-tap row chip (chip uses `.first`).
  /// Only two flows: Inbox → area/project, and area-direct → child project.
  /// Tasks already filed into a project are never repositioned.
  /// A loose, manually-captured Inbox row on Today: no project/area, no dates,
  /// but `today == true` (so it renders in the Inbox card yet falls outside
  /// `isInTriageBand`, whose non-agent branch requires `!today`). Mirrors the
  /// `looseToday` population in `triageSection` so the filing capsule shows for
  /// self-added Inbox tasks too, not just agent proposals.
  private func isLooseTodayInboxCapture(_ task: SeptenaTask) -> Bool {
    TaskFilingSuggestions.isLooseTodayInboxCapture(task, filter: filter)
  }

  /// Ranked filing picks for a row. The RULES live in
  /// `TaskFilingSuggestions` so the AppKit shell renders the same capsule off
  /// the same gate — see that file for why a second copy is the drift we
  /// forbid.
  private func filingRankedSuggestions(for task: SeptenaTask) -> [SuggestionEngine.Suggestion]? {
    TaskFilingSuggestions.ranked(for: task, filter: filter, engine: suggestionEngine,
                                 childProjectIds: { childProjectIds(in: $0) })
  }

  /// The menu's Move ▸ "Suggested" item reads `.first`, which has to be the
  /// pick the row's chip shows (snapshotted in `load()`), not a fresh ranking
  /// that may have moved on since.
  private func rankedSuggestions(for target: ActionTarget) -> [SuggestionEngine.Suggestion]? {
    guard case let .single(task) = target else { return nil }
    let ranked = filingRankedSuggestions(for: task)
    guard let chip = filingChipSuggestion(for: task) else { return ranked }
    return [chip] + (ranked ?? []).filter { $0 != chip }
  }

  private func suggestionAlreadyMatches(_ task: SeptenaTask,
                                        _ suggestion: SuggestionEngine.Suggestion?) -> Bool {
    TaskFilingSuggestions.alreadyMatches(task, suggestion)
  }

  // MARK: - Selection
  //
  // `selection` (a Set<String>) is bound to `SelectableScrollList(selection:)`
  // on both platforms and is the single source of truth: the container drives
  // it from click / ⌘ / ⇧ / arrows, reproducing the `List(selection:)` contract.
  // Every deselect path funnels through `clearSelection` so iOS edit mode can
  // never desync from an empty selection.

  /// Replace the selection with exactly one row. Used by right-click to make the
  /// context-menu target unambiguous; ordinary click / ⌘-click / ⇧-click / ↑↓
  /// selection is handled by the container.
  private func selectOnly(_ id: String) {
    selection = [id]
  }

  /// Swipe-to-select (or checkbox/row tap while touch-selecting): toggles `id`
  /// in `selection`, entering touch multi-select mode if not already active and
  /// auto-exiting when the last selected row is deselected.
  private func toggleTouchSelection(_ id: String) {
    #if os(iOS)
    _ = closeActiveEditIfNeeded()
    if selection.contains(id) {
      selection.remove(id)
      if selection.isEmpty {
        isTouchSelecting = false
      }
    } else {
      isTouchSelecting = true
      selection.insert(id)
    }
    syncMultiSelectChrome()
    #endif
  }

  private func selectAllOrClearVisibleTasks() {
    let all = selectableVisibleTaskIDs
    guard !all.isEmpty else { return }
    if all.allSatisfy({ selection.contains($0) }) {
      clearSelection()
    } else {
      #if os(iOS)
      isTouchSelecting = true
      #endif
      selection = Set(all)
      syncMultiSelectChrome()
    }
  }

  private func syncMultiSelectChrome() {
    #if os(iOS)
    if isOnScreen {
      nav.isTaskMultiSelectActive = isTouchSelecting && !selection.isEmpty
    }
    #endif
  }

  /// Deselect everything — the single "clear selection" entry point used by
  /// every deselect path.
  private func clearSelection() {
    selection.removeAll()
    #if os(iOS)
    isTouchSelecting = false
    showingQuickDropTray = false
    editMode?.wrappedValue = .inactive
    nav.isTaskMultiSelectActive = false
    #endif
  }

  /// Leading (swipe-right) quick action for a task row on iOS/iPadOS
  /// (`docs/IOS_SWIPE_ACTIONS_SPEC.md` #132). Disabled while touch multi-select
  /// or an inline editor is active, and on section headings.
  private func leadingSwipeAction(for task: SeptenaTask) -> TaskRowLeadingSwipeAction? {
    #if os(iOS)
    guard !touchSelectionActive, expandedEditId == nil, !task.isHeading else { return nil }

    if filter == .recentlyDeleted {
      return TaskRowLeadingSwipeAction(
        title: RegistryActions.title("task.restore"),
        symbol: "arrow.uturn.backward.circle.fill",
        tint: Color.accentColor
      ) {
        Haptics.tick()
        mutator.restore(id: task.id)
        removeLocally(id: task.id)
        Task { await load() }
        showToast("Restored \(task.title)")
      }
    }

    if filter == .faded || task.isFaded {
      return TaskRowLeadingSwipeAction(
        title: RegistryActions.title("task.keepFaded"),
        symbol: "arrow.uturn.backward.circle.fill",
        tint: Color.accentColor
      ) {
        keepFadedTasks([task.id])
      }
    }

    // Inbox band — unacknowledged agent proposals: Accept / Keep into Today.
    if task.isInTriageBand, task.source == TaskSource.mcp, task.acknowledgedAt == nil {
      return TaskRowLeadingSwipeAction(
        title: "Accept",
        symbol: "checkmark.circle.fill",
        tint: Theme.todayAccent
      ) {
        Haptics.tick()
        let before = scheduleSnapshots([task.id])
        promoteToToday([task.id])
        mutator.acknowledge(id: task.id)
        let ticket = TaskUndoTicket()
        Task { await load() }
        showToast("Added to Today") {
          ticket.undo { TaskUndo.restore(before, using: mutator) }
          Task { await load() }
        }
      }
    }

    let configured = TaskSwipeLeadingAction(rawValue: swipeLeadingActionRaw) ?? .today
    switch configured {
    case .none:
      return nil

    case .today:
      if task.isOnToday {
        return TaskRowLeadingSwipeAction(
          title: RegistryActions.title("task.toggleToday", .remove),
          symbol: "sun.max",
          tint: Theme.inkSecondary
        ) {
          let before = scheduleSnapshots([task.id])
          applyRemoveFromToday([task.id])
          let ticket = TaskUndoTicket()
          showToast("Removed from Today") {
            ticket.undo { TaskUndo.restore(before, using: mutator) }
            Task { await load() }
          }
        }
      }
      return TaskRowLeadingSwipeAction(
        title: RegistryActions.title("task.toggleToday", .add),
        symbol: "sun.max.fill",
        tint: Theme.todayAccent
      ) {
        Haptics.tick()
        let before = scheduleSnapshots([task.id])
        promoteToToday([task.id])
        mutator.acknowledge(id: task.id)
        let ticket = TaskUndoTicket()
        Task { await load() }
        showToast("Added to Today") {
          ticket.undo { TaskUndo.restore(before, using: mutator) }
          Task { await load() }
        }
      }

    case .schedule:
      return TaskRowLeadingSwipeAction(
        title: RegistryActions.title("task.when", .short),
        symbol: "calendar",
        tint: Color.accentColor
      ) {
        Haptics.tap()
        whenSheet = WhenSheet(taskIds: [task.id], kind: .scheduled)
      }

    case .move:
      return TaskRowLeadingSwipeAction(
        title: RegistryActions.title("task.move", .short),
        symbol: "arrow.right.circle.fill",
        tint: Color.accentColor
      ) {
        Haptics.tap()
        moveTargetIds = [task.id]
        showingMoveSheet = true
      }

    case .star:
      let nextStarred = !task.starred
      return TaskRowLeadingSwipeAction(
        title: nextStarred ? RegistryActions.title("task.toggleStar", .add) : RegistryActions.title("task.toggleStar", .remove),
        symbol: nextStarred ? "star.fill" : "star.slash",
        tint: Theme.todayAccent
      ) {
        Haptics.tick()
        recordingSchedule(
          nextStarred
            ? RegistryActions.title("task.toggleStar", .add)
            : RegistryActions.title("task.toggleStar", .remove),
          [task.id]
        ) {
          mutator.setStarred(id: task.id, starred: nextStarred)
        }
        Task { await load() }
      }

    case .complete:
      return TaskRowLeadingSwipeAction(
        title: task.status == .done ? "Reopen" : "Complete",
        symbol: "checkmark.circle.fill",
        tint: Color.accentColor
      ) {
        toggle(task)
      }
    }
    #else
    return nil
    #endif
  }


  private func applySuggestion(task: SeptenaTask,
                               suggestion: SuggestionEngine.Suggestion) {
    Haptics.tick()
    // Capture the prior filing BEFORE the move so Undo can put it back.
    let undoBefore = filingSnapshots([task.id])
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
    // Same shared-stack undo as every other move (toast, shake and ⌘Z agree).
    TaskUndo.recordMove(before: undoBefore, context: modelContext, mutator: mutator)
    let ticket = TaskUndoTicket()
    Task { await load() }

    showToast(RegistryToasts.moved(destination: suggestion.title)) {
      ticket.undo { TaskUndo.restore(undoBefore, using: mutator) }
      Task { await load() }
    }
  }

  /// The one-tap row chip — same top pick as the context menu (snapshotted in `load()`).
  private func filingChipSuggestion(for task: SeptenaTask) -> SuggestionEngine.Suggestion? {
    model.filingSuggestions[task.id]
  }

  /// Top filing pick for implicit "not this" learning.
  private func topFilingSuggestion(for task: SeptenaTask) -> SuggestionEngine.Suggestion? {
    model.filingSuggestions[task.id] ?? filingRankedSuggestions(for: task)?.first
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
    let base = chipFiltered(items)
    let pool = base.filter { $0.status == .open || model.settle.isSettling($0.id) }
    // Sidebar order, not due-first: flat drops the headers, not the sequence
    // (`TaskListOrder.byList`, shared with `groupedOpenItems`' emission order
    // and Septask's AppKit list).
    let classified = TaskListOrder.byList(
      pool.filter { $0.project != nil || $0.area != nil },
      areas: areas, projects: projects)
    cardedRows(classified)
  }

  /// Renders `items` clustered by their project (preferred) or area, using
  /// real SwiftUI sections so group titles are headers, not selectable rows.
  @ViewBuilder
  private var groupedOpenItems: some View {
    let base = chipFiltered(items)
    // Drop finished rows (completed or cancelled) except those still settling
    // (just checked / just cancelled), so a finished task lingers for the beat
    // then fades — instead of sitting struck through until the next reload.
    let pool = base.filter { $0.status == .open || model.settle.isSettling($0.id) }
    let byProject = Dictionary(grouping: pool.filter { $0.project != nil },
                               by: { $0.project! })
    let byArea = Dictionary(grouping: pool.filter { $0.project == nil && $0.area != nil },
                            by: { $0.area! })
    let loose = excludingQuickAddCapture(pool.filter(\.isUnfiled))

    // Loose tasks on Today are merged into the Inbox section above (triageSection).
    // For other filters (Unscheduled, Area, etc.) show them headerless as before.
    if filter != .today, !loose.isEmpty {
      cardedRows(loose)
    }

    // Areas in sidebar order: direct-area tasks, then each project's tasks.
    ForEach(areas) { area in
      let areaDropTarget: TodayDropTarget? = filter == .today ? .area(area.id) : nil
      let areaCustomDrop: (([String]) -> Bool)? = filter == .today
        ? nil : { ids in handleGroupedListMoveDrop(ids: ids, areaId: area.id, projectId: nil) }
      let areaTasks = byArea[area.id] ?? []
      if !areaTasks.isEmpty {
        Section {
          cardedRows(areaTasks,
                     appendQuickAdd: showsQuickAddInArea(area.id),
                     quickAddShowsEditor: true,
                     moveDropTarget: areaDropTarget,
                     onDropIDs: areaCustomDrop,
                     magicContext: area.title)
        } header: {
          groupHeader(icon: "square.stack.3d.up.fill",
                      title: area.title,
                      areaEmoji: area.emoji,
                      onTap: {
                        if closeActiveEditIfNeeded() { return }
                        nav.go(to: .area(id: area.id))
                      },
                      onAdd: showsGroupedHeaderQuickAdd
                        ? { startCreate(areaId: area.id) } : nil,
                      moveDropTarget: areaDropTarget,
                      onDropIDs: areaCustomDrop,
                      magicDropId: "mp-area-\(area.id)")
        }
      }
      ForEach(projects.filter { $0.area == area.id }) { project in
        let projectDropTarget: TodayDropTarget? = filter == .today ? .project(project.id) : nil
        let projectCustomDrop: (([String]) -> Bool)? = filter == .today
          ? nil : { ids in handleGroupedListMoveDrop(ids: ids, areaId: nil, projectId: project.id) }
        if let tasks = byProject[project.id], !tasks.isEmpty {
          Section {
            cardedRows(tasks,
                       appendQuickAdd: showsQuickAddInProject(project.id),
                       quickAddShowsEditor: true,
                       moveDropTarget: projectDropTarget,
                       onDropIDs: projectCustomDrop,
                       magicContext: project.title)
          } header: {
            groupHeader(icon: nil,
                        title: project.title,
                        projectProgress: model.progressByProject[project.id],
                        onTap: {
                          if closeActiveEditIfNeeded() { return }
                          nav.go(to: .project(id: project.id))
                        },
                        onAdd: showsGroupedHeaderQuickAdd
                          ? { startCreate(projectId: project.id) } : nil,
                        moveDropTarget: projectDropTarget,
                        onDropIDs: projectCustomDrop,
                        magicDropId: "mp-proj-\(project.id)")
          }
        }
      }
    }

    // Top-level projects (no area).
    ForEach(projects.filter { $0.area == nil }) { project in
      let projectDropTarget: TodayDropTarget? = filter == .today ? .project(project.id) : nil
      let projectCustomDrop: (([String]) -> Bool)? = filter == .today
        ? nil : { ids in handleGroupedListMoveDrop(ids: ids, areaId: nil, projectId: project.id) }
      if let tasks = byProject[project.id], !tasks.isEmpty {
        Section {
          cardedRows(tasks,
                     appendQuickAdd: showsQuickAddInProject(project.id),
                     quickAddShowsEditor: true,
                     moveDropTarget: projectDropTarget,
                     onDropIDs: projectCustomDrop,
                     magicContext: project.title)
        } header: {
          groupHeader(icon: nil,
                      title: project.title,
                      projectProgress: model.progressByProject[project.id],
                      onTap: {
                        if closeActiveEditIfNeeded() { return }
                        nav.go(to: .project(id: project.id))
                      },
                      onAdd: showsGroupedHeaderQuickAdd
                        ? { startCreate(projectId: project.id) } : nil,
                      moveDropTarget: projectDropTarget,
                      onDropIDs: projectCustomDrop,
                      magicDropId: "mp-proj-\(project.id)")
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
                          quickAddShowsEditor: Bool = true,
                          reorderable: Bool = false,
                          grouped: Bool = false,
                          moveDropTarget: TodayDropTarget? = nil,
                          onDropIDs: (([String]) -> Bool)? = nil,
                          magicContext: String? = nil) -> some View {
    let rows = excludingQuickAddCapture(tasks)
    let cardCount = rows.count + (appendQuickAdd ? 1 : 0)
    // Today rows reorder in Today's own order (#66). The row's reorder drop
    // also files a row dragged in from another group, so the row-level
    // group drop steps aside (the group headers keep theirs).
    let todayReorder = filter == .today
    let rowMoveDrop = onDropIDs.map { TaskMoveDrop(perform: $0) }
      ?? todayMoveDrop(todayReorder ? nil : moveDropTarget)
    let canMagicRowDrop = reorderable || todayReorder
    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, task in
      let position = TaskCardPosition(index: idx, count: cardCount)
      let isExpanded = expandedEditId == task.id
      taskRow(task, quickMenu: quickMenu?(task) ?? false)
        .modifier(rowMoveDrop)
        .taskCardChrome(position,
                        // An open inline editor keeps the clean card surface
                        // instead of painting the whole editor in selection blue;
                        // on iOS it lifts as a rounded focus card while siblings
                        // fade back. Closed selected rows keep the selection fill.
                        isSelected: isExpanded ? false : selection.contains(task.id),
                        isEditing: isExpanded)
        .taskRowSwipeActions(
          id: task.id,
          enabled: !isExpanded && !isInlineEditing && !selectionScope.isMulti && !isSwipeEditModeActive,
          leading: swipeLeadingActions(for: task),
          allowsLeadingFullSwipe: true,
          trailing: swipeTrailingActions(for: task),
          allowsTrailingFullSwipe: false
        )
        // After the chrome, so the iOS lift preview includes the card
        // background, clipped to this row's slice of the card.
        .taskCardContextMenu(position) { taskContextMenu(for: task) }
        // After the chrome, so the drop target (and its targeting wash) spans
        // the full card slice the user sees, not just the inner row content.
        // In a project's grouped list a drop also re-files across headings
        // (`handleGroupedTaskDrop` reads the target row's group).
        .modifier(TaskReorderDrop(perform: canMagicRowDrop
          ? { ids, before in
              grouped
                ? handleGroupedTaskDrop(ids: ids, target: task, before: before)
                : handleReorderDrop(ids: ids, target: task, before: before,
                                    refileTo: todayReorder ? moveDropTarget : nil) }
          : nil))
        .magicPlusRowDrop(id: "mp-row-\(task.id)", context: magicContext, enabled: canMagicRowDrop) { before in
          let ids = TaskDragIDs.newTask.ids
          _ = grouped
            ? handleGroupedTaskDrop(ids: ids, target: task, before: before)
            : handleReorderDrop(ids: ids, target: task, before: before,
                                refileTo: todayReorder ? moveDropTarget : nil)
        }
        .modifier(MagicPlusOptionalSectionDrop(
          id: "mp-row-sec-\(task.id)",
          label: magicContext.map { "New Task · \($0)" } ?? "New Task",
          onDropIDs: canMagicRowDrop ? nil : onDropIDs
        ))
        .zIndex(isExpanded ? 1 : 0)
        .inlineEditDimmed(isInlineEditing && !isExpanded, onDismiss: collapseEdit)
    }
    if appendQuickAdd {
      let isEditingQuickAdd = quickAddShowsEditor
        && quickAddCaptureTask.map { expandedEditId == $0.id } == true
      quickAddLine(showsEditor: quickAddShowsEditor)
        .asListRow()
        // The quick-add trigger is a selectable row (it carries the sentinel id
        // and sits in `keyboardOrderedTaskIds`), so it has to paint the same
        // selection fill every other row does. Without `isSelected` here, ↑/↓
        // landed on it and NOTHING highlighted — the cursor effectively went
        // invisible for one row, which reads as "the New task line can't be
        // selected by keyboard" even though Return would have opened it.
        .taskCardChrome(TaskCardPosition(index: rows.count, count: cardCount),
                        isSelected: isEditingQuickAdd ? false : selection.contains(Self.quickAddScrollID),
                        isEditing: isEditingQuickAdd)
        .zIndex(isEditingQuickAdd ? 1 : 0)
        .inlineEditDimmed(isInlineEditing && !isEditingQuickAdd, onDismiss: collapseEdit)
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
      result = result.filter { $0.status == .open || model.settle.isSettling($0.id) }
    }
    return chipFiltered(result)
  }

  /// The Starred and tag chips in `starFilterBar`. Every row source a list
  /// renders goes through this — Today's Inbox and grouped cards read `items`
  /// and `triageItems` directly, and skipped the chips, so on Today the
  /// Starred chip did nothing.
  private func chipFiltered(_ tasks: [SeptenaTask]) -> [SeptenaTask] {
    var result = tasks
    if starredOnlyFilter && showsStarFilterPill {
      result = result.filter(\.starred)
    }
    if !selectedTagIDs.isEmpty {
      result = result.filter { selectedTagIDs.isSubset(of: Set($0.tags)) }
    }
    return result
  }

  private var hideHistoricalDone: Bool {
    switch filter {
    // Every open-work list hides done tasks (a just-completed one lingers via
    // the settle exception in `visibleItems`, then fades). Only the Logbook and
    // Recently Deleted — whose whole job is showing finished/trashed tasks — keep them.
    case .project, .area, .unscheduled, .starred, .upcoming, .triage, .repeating, .review, .agent, .faded: return true
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
                           onAdd: (() -> Void)? = nil,
                           moveDropTarget: TodayDropTarget? = nil,
                           onDropIDs: (([String]) -> Bool)? = nil,
                           magicDropId: String? = nil) -> some View {
    let dropModifier = onDropIDs.map { TaskMoveDrop(perform: $0) }
      ?? todayMoveDrop(moveDropTarget)
    let resolvedMagicDrop: (([String]) -> Bool)? = onDropIDs ?? moveDropTarget.map { target in
      { ids in handleTodayMoveDrop(ids: ids, target: target) }
    }
    return groupHeaderBody(icon: icon, title: title, areaEmoji: areaEmoji,
                           projectProgress: projectProgress, onTap: onTap, onAdd: onAdd)
      .textCase(nil)
      .selectionDisabled()
      .modifier(dropModifier)
      .modifier(MagicPlusOptionalSectionDrop(
        id: magicDropId ?? "mp-header-\(title)",
        label: "New Task · \(title)",
        onDropIDs: resolvedMagicDrop
      ))
      .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
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
            .offset(x: -Theme.checkboxLeadingNudge)
        } else if icon != nil {
          Image(systemName: icon!)
            .scaledFont(size: 16)
            .foregroundStyle(Theme.iconMuted)
            .frame(width: Theme.checkboxTap, alignment: .center)
            .offset(x: -Theme.checkboxLeadingNudge)
        } else {
          ProjectProgressIcon(progress: projectProgress ?? 0, tint: Theme.inkSecondary, diameter: 14)
            .frame(width: Theme.checkboxTap, alignment: .center)
            .offset(x: -Theme.checkboxLeadingNudge)
        }
        // Tappable target is JUST the title (+ chevron) — not the whole row.
        // The Spacer keeps the rest of the row visually aligned but inert, so
        // clicks in empty horizontal space don't navigate.
        if let onTap {
          GroupHeaderLabel(title: title, hasChevron: true, action: onTap)
            .padding(.leading, titleLeadingCorrection)
        } else {
          Text(title).sectionGroupHeaderTitleStyle()
        }
        Spacer()
        if let onAdd {
          HeaderQuickAddButton(accessibilityLabel: "Add task to \(title)",
                               action: onAdd,
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
        CalendarEventRow(event: event)
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

  /// Today's calendar agenda — an "Agenda" group header over one solo card,
  /// the same anatomy as every other Today group, each Upcoming day's events,
  /// and the Mac Today list (`SeptaskKitTaskList.agenda()`). It used to sit as
  /// bare text on the gray canvas, which read as floating between the cards.
  @ViewBuilder
  private var todayCalendarRow: some View {
    if filter == .today, showCalendarEvents, !model.calendarEvents.isEmpty {
      groupHeader(icon: "calendar",
                  title: String(localized: "Agenda", comment: "SeptaskKit: Today calendar group"))
        .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
      calendarEventsBlock(model.calendarEvents)
        .taskCardChrome(.solo)
        .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
    }
  }

  // MARK: - Upcoming grouping (by date)

  /// Buckets upcoming items by their scheduled (or due) date, in the order
  /// dates first appear in `items`. Date headers are non-tappable.
  @ViewBuilder
  private var groupedUpcomingItems: some View {
    let buckets = upcomingBuckets()
    ForEach(buckets, id: \.key) { bucket in
      let dropOnDay: ([String]) -> Bool = { ids in
        handleUpcomingDateDrop(ids: ids, dateKey: bucket.key)
      }
      Section {
        // The day's calendar events frame it first (the agenda), then the tasks
        // scheduled for that day — matching Today, where the agenda sits on top.
        if !bucket.events.isEmpty {
          calendarEventsBlock(bucket.events)
            .taskCardChrome(.solo)
            .inlineEditDimmed(isInlineEditing, onDismiss: collapseEdit)
        }
        cardedRows(bucket.tasks, onDropIDs: dropOnDay, magicContext: bucket.label)
      } header: {
        groupHeader(icon: "calendar", title: bucket.label,
                    onDropIDs: dropOnDay, magicDropId: "mp-upcoming-\(bucket.key)")
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
      if task.status != .open && !model.settle.isSettling(task.id) { continue }
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
      for event in model.calendarEvents {
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

  /// Scheduling fields as they stand right now, for `TaskUndo`. Read from the
  /// visible buckets (`currentTask`) rather than the store, so a row the user
  /// has optimistically edited in-session snapshots what they can actually see.
  private func scheduleSnapshots(_ ids: [String]) -> [TaskUndo.ScheduleSnapshot] {
    ids.compactMap { currentTask(id: $0) }.map(TaskUndo.ScheduleSnapshot.init)
  }

  /// Register the scheduling change `body` just made. The undo/redo pair is
  /// derived by re-reading the store afterwards — `schedule` / `setDeadline` /
  /// `removeFromToday` each carry their own Today side effects, and predicting
  /// them here would be a second copy of that logic (see `TaskUndo.restore`).
  private func recordingSchedule(_ name: String, _ ids: [String], _ body: () -> Void) {
    let before = scheduleSnapshots(ids)
    body()
    TaskUndo.recordScheduleChange(name: name, before: before,
                                  context: modelContext, mutator: mutator)
  }

  private func applyWhen(id: String, kind: WhenKind, date: Date?) {
    Haptics.tick()
    switch kind {
    case .deadline:
      recordingSchedule(String(localized: "Set Deadline", comment: "Undo action name"),
                        [id]) {
        mutator.setDeadline(id: id, date: date)
      }
    case .scheduled:
      // Things-style mapping:
      //   • "Today" → pin to today (today=true), clear any scheduled date.
      //     A pinned task is one the user placed here deliberately, so it
      //     never counts toward the "new to-dos" rolled-in banner.
      //   • Future date → today=false + scheduled=date. Server auto-
      //     surfaces the task on Today when that date arrives.
      //   • Nil ("No Date") → clear both flags.
      if let task = currentTask(id: id),
         let rule = task.recurrence,
         !rule.afterCompletion,
         date != nil,
         SeptenaDate.format(date) != task.scheduled {
        reschedulePrompt = FixedReschedulePrompt(taskIDs: [id], date: date)
        return
      }
      applyScheduledWhen(id: id, date: date, mode: .makeException)
      return
    }
    // Scheduling is engagement — clear the agent cue so a dated proposal leaves
    // the Inbox. No-op for non-agent / already-seen rows.
    mutator.acknowledge(id: id)
    Task { await load() }
  }

  /// Shared scheduled-date application used both by the ordinary date path
  /// and the fixed-repeat decision dialog. `reschedule` records the logical
  /// slot before the Today mapping clears the displayed date.
  private func applyScheduledWhen(id: String,
                                  date: Date?,
                                  mode: RecurrenceRescheduleMode) {
    let undoBefore = scheduleSnapshots([id])
    defer {
      TaskUndo.recordScheduleChange(
        name: String(localized: "Schedule Task", comment: "Undo action name"),
        before: undoBefore, context: modelContext, mutator: mutator)
    }
    if let d = date {
      if Calendar.current.isDateInToday(d) {
        mutator.reschedule(id: id, date: d, mode: mode)
        mutator.schedule(id: id, date: nil)
        promoteToToday([id])
      } else {
        mutator.moveToToday(id: id, today: false)
        mutator.reschedule(id: id, date: d, mode: mode)
        // Deferring drops the row off Today; confirm where it landed. No
        // Undo — re-opening the When picker is the natural reversal.
        showToast(RegistryToasts.deferred(to: d))
      }
    } else {
      mutator.reschedule(id: id, date: nil, mode: .makeException)
      mutator.moveToToday(id: id, today: false)
    }
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
    // status flip so the row stays put while it lingers — `model.settle.isSettling(id)`
    // keeps it visible (see `visibleItems` and the grouped pool) and `load()`
    // preserves settling rows, so the `.septenaTasksChanged` this completion
    // posts can't yank it. After the beat the settle clears and the row fades
    // out IN PLACE and is gone (it lives on in the dedicated Logbook);
    // `endSettle` inside the animated transaction lets that removal play
    // `.transition(.opacity)` and rows below slide up.
    // Uncomplete cancels the pending fade.
    //
    // Order matters: the pool filter is `status != .done || model.settle.isSettling`.
    // The status flip is an @State mutation wrapped in `a11yAnimate`, while
    // `settling` lives on the separate @Observable `SettleStore` and commits in
    // its own (un-animated) transaction. If we flipped first, SwiftUI could
    // paint one frame where status == .done but settling == false — the pool
    // would drop the row, the rows below would animate up over the settle beat,
    // then snap back when `settling` lands a frame later. Marking the row
    // settling first means there is no `done && !settling` frame: an open row is
    // always in the pool, and a done-and-settling row is too, so the row never
    // leaves it across the two transactions.
    if newStatus == .done {
      model.settle.schedule(task.id) {
        motion.run(Theme.Motion.settle) { model.settle.endSettle(task.id) }
      }
    } else {
      model.settle.cancel(task.id)
    }

    motion.run(Theme.Motion.settle) { flipStatus(id: task.id, to: newStatus) }

    // Context-scaled completion haptic (see `TaskCelebration`): runs after
    // the flip so "was that the last open Today task?" reads the new state.
    // Only the Today screen can see the whole Today set; elsewhere a
    // today-flagged task settles without claiming to have cleared the day.
    if newStatus == .done {
      let clearedToday = filter == .today
        && !items.contains { $0.status == .open }
      TaskCelebration.completed(isToday: task.isOnToday || filter == .today,
                                clearedToday: clearedToday,
                                accent: theme.color(for: "tasks"),
                                logCommit: logCommit)
    }
    model.noteCompleted(task.id, done: newStatus == .done)

    if newStatus == .done {
      mutator.complete(id: task.id)
    } else {
      mutator.uncomplete(id: task.id)
    }
    // The shared undo stack (`TaskUndo`) — this is what makes ⌘Z, shake, and
    // three-finger undo take back an accidental check on every surface, not
    // just the AppKit shell. `wasDone` is the state BEFORE the toggle.
    TaskUndo.recordCompletion(ids: [task.id],
                              wasDone: newStatus != .done,
                              mutator: mutator)
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
    apply(&items); apply(&triageStorage)
  }

  /// Drop the matching task from every visible bucket. Paired with
  /// `TaskMutator.delete(...)` — the SwiftData row carries `pendingDeletion`
  /// so LocalCache hides it, but the in-memory @State arrays power the
  /// currently rendered screen and have to be poked separately.
  private func removeLocally(id: String) {
    func drop(_ list: inout [SeptenaTask]) {
      list.removeAll { $0.id == id }
    }
    drop(&items); drop(&triageStorage); drop(&fadedScopeStorage)
  }

  /// Replace a visible row wholesale — the same pattern as `flipStatus` /
  /// `removeLocally`. The mutator + async `load()` still run, but the closed row
  /// must repaint on the very next frame after the inline editor folds, not
  /// after a round-trip through `LocalCache`.
  private func patchLocally(_ fresh: SeptenaTask) {
    func apply(_ list: inout [SeptenaTask]) {
      guard let i = list.firstIndex(where: { $0.id == fresh.id }) else { return }
      list[i] = fresh
    }
    apply(&items); apply(&triageStorage)
  }

  /// Re-read one task from the local mirror and patch the visible buckets.
  /// Called from composer `onDone` after `persist()` has saved.
  ///
  /// This replaces the WHOLE row DTO rather than just title/notes. Patching two
  /// fields left every other edited attribute (When, Deadline, Repeat, List) to
  /// be picked up only by the debounced `load()`, so a save reliably rendered a
  /// stale row for at least a beat — and not at all when that reload was held
  /// back by another open editor (`reloadOrDeferWhileEditing`).
  private func repatchTask(id: String) {
    var descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    guard let entity = try? modelContext.fetch(descriptor).first else { return }
    patchLocally(SeptenaTask(entity))
  }

  // MARK: - Load

  /// Apply a merge outcome, playing whichever beat it earned. Motion and the
  /// promote flash stay here — they're presentation; `TaskListModel.merge`
  /// owns the reconciliation itself.
  private func applyMerge(_ outcome: TaskListModel.MergeOutcome,
                          assign: ([SeptenaTask]) -> Void) {
    switch outcome.motion {
    case .settle:
      motion.run(Theme.Motion.settle) { assign(outcome.rows) }
    case .expand:
      RemoteTaskSync.flashTodayPromotes(ids: outcome.arrived, in: outcome.rows,
                                        via: promoteFlash)
      motion.run(Theme.Motion.expand) { assign(outcome.rows) }
    case .none:
      assign(outcome.rows)
    }
  }

  /// Open the linger-then-fade window for a row a merge just ghosted, finishing
  /// inside an animated transaction so the row fades and its siblings slide up
  /// — the same beat a local tap gets.
  private func openSettleWindow(_ id: String) {
    model.settle.schedule(id) {
      motion.run(Theme.Motion.settle) { model.settle.endSettle(id) }
    }
  }

  /// Rows the user created here this session — excluded from the remote-arrival
  /// beat, since the local create already animated its own append.
  private func ownCreateExclusions() -> Set<String> {
    var ids = model.sessionCreatedIds
    ids.formUnion(draftEditIds)
    if let quickAddDraftId { ids.insert(quickAddDraftId) }
    return ids
  }

  /// Reload the list UNLESS an editor owns the keyboard. Background refreshes
  /// (sibling/remote task changes, structure changes) must never replace `items`
  /// while an inline title field is focused — the array swap re-diffs the
  /// `LazyVStack` and steals first-responder mid-keystroke. Deferred reloads
  /// coalesce into a single `load()` when the editor folds (see
  /// `flushDeferredReloadIfNeeded`).
  ///
  /// `coalescing` waits the longer notification window (`notificationCoalesce`)
  /// so a burst of sync posts costs one rebuild.
  private func reloadOrDeferWhileEditing(coalescing: Bool = false) {
    // Hidden tabs (e.g. Upcoming/Tasks while viewing Today) stay quiet until
    // they return on screen (`didAppearOnScreen` flushes the deferred load).
    guard isOnScreen, !listInputActive else { pendingReloadWhileEditing = true; return }
    Task { await load(delay: coalescing ? Self.notificationCoalesce : Self.loadCoalesce) }
  }

  /// One run-loop beat for a user action; the old Combine debounce window for
  /// sync / structure notifications.
  private static let loadCoalesce: UInt64 = 75_000_000
  private static let notificationCoalesce: UInt64 = 300_000_000

  /// Run a reload that was held back while an editor was open. Fired on the
  /// `listInputActive` falling edge so the list catches up to any background
  /// changes the moment the field lets go of the keyboard.
  private func flushDeferredReloadIfNeeded() {
    guard pendingReloadWhileEditing, !listInputActive else { return }
    pendingReloadWhileEditing = false
    Task { await load() }
  }

  private func load(delay: UInt64 = loadCoalesce) async {
    loadGeneration &+= 1
    let generation = loadGeneration
    // Completion, filing, drag, and a CK batch frequently land together. The
    // cache already paints optimistically, so wait a single run-loop beat and
    // discard every superseded rebuild instead of scanning the task history N
    // times on the main actor.
    try? await Task.sleep(nanoseconds: delay)
    guard !Task.isCancelled, generation == loadGeneration else { return }
    performLoad()
  }

  private func performLoad() {
    // Cache was already painted in init(); only show the loading state when
    // we have literally nothing to render (first ever launch, cache miss).
    if items.isEmpty { isLoading = true }
    checklistCounts = LocalCache.checklistSummaryByTask(in: modelContext)
    tagsByID = LocalCache.tagsByID(in: modelContext)
    // Prune any selected tag filter whose tag was deleted or left this list.
    if !selectedTagIDs.isEmpty {
      let valid = Set(availableTagsInList.map(\.id))
      selectedTagIDs = selectedTagIDs.intersection(valid)
    }
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
    // Today and its triage band share one fetch of the open rows.
    let todayLists = filter == .today ? LocalCache.todayAndTriage(in: modelContext) : nil
    let outcome = model.merge(prior: items,
                             fresh: todayLists?.today ?? localTasks(),
                             context: modelContext,
                             animateArrivals: loadedFilters.contains(filter),
                             ownCreations: ownCreateExclusions(),
                             openSettleWindow: openSettleWindow)
    applyMerge(outcome) { items = $0 }
    loadedFilters.insert(filter)
    // Projects + areas live in SwiftData (mirrored by CKSyncEngine), so
    // the local cache is authoritative — no network round-trip needed.
    let structure = StructureCache.snapshot(in: modelContext)
    projects = structure.projects
    areas = structure.areas
    // Per-project completion ratio for the project pie glyph in mixed-list
    // headers. Aggregate raw entities rather than projecting the whole
    // historical corpus into row DTOs on every refresh.
    model.refreshProjectProgress(filter: filter, context: modelContext)
    if filter == .today {
      // Re-read the Inbox and merge back any just-checked row that's still
      // settling (the `.triage` query drops done tasks), so an accepted
      // suggestion lingers struck-through and fades in place like every other
      // completed row — same preservation `items` gets above.
      let triageOutcome = model.merge(
        prior: triageStorage,
        fresh: todayLists?.triage ?? LocalCache.tasks(in: modelContext, filter: .triage),
        context: modelContext,
        animateArrivals: loadedFilters.contains(filter),
        ownCreations: ownCreateExclusions(),
        openSettleWindow: openSettleWindow)
      applyMerge(triageOutcome) { triageStorage = $0 }
    } else {
      triageStorage = []
    }
    fadedScopeStorage = (showFadedInLists && scopeLoggedFilterId != nil)
      ? LocalCache.fadedTasks(in: modelContext, scope: filter)
      : []
    // Prune stale selection IDs (e.g. tasks moved out of this list via
    // SidebarTaskDrop or AreaDetailView project drop) so selection chrome
    // never lingers over vanished rows.
    if !selection.isEmpty {
      let visible = Set(keyboardOrderedTaskIds)
      let pruned = selection.intersection(visible)
      if pruned != selection {
        selection = pruned
        if pruned.isEmpty {
          clearSelection()
        }
      }
    }
    // A synced dismissal from another device lands on the next read.
    noticeEpoch &+= 1
    refreshTodayNotices()
    // Filing suggestions and the calendar agenda come one frame after the
    // rows (scheduleDecorationPass, docs/LAUNCH_PERF.md).
    consumePendingTaskReveal()
    if filter == .today { LaunchTrace.milestone("launch.todayLoadDone") }
    LaunchPhase.shared.noteRowsPublished()
    SeptenaLog.info("[TaskList] load done count=\(items.count)")
    scheduleDecorationPass()
  }

  /// The second pass of a load (docs/LAUNCH_PERF.md): the rows are already
  /// published, so the decorations that do not change which rows show wait
  /// one frame. A newer load supersedes this one and runs its own pass.
  private func scheduleDecorationPass() {
    let generation = loadGeneration
    Task {
      await LaunchPhase.nextFrame()
      guard generation == loadGeneration else { return }
      // Rebuild the Inbox filing-suggestion snapshot (the "→ Suggested"
      // capsule). The engine's model build is memoized, so a reload that
      // changed nothing does not retrain it.
      refreshFilingSuggestions()
      refreshCalendarEvents()
    }
  }

  /// Select and reveal a searched task only in the list that owns its route.
  /// Other still-mounted tab panes must leave the one-shot alone for the active
  /// destination to consume.
  private func consumePendingTaskReveal() {
    // On-screen only: Septask's iPhone tabs keep a second list for the same
    // route mounted (a hidden copy must leave the reveal to the visible one).
    guard isOnScreen,
          let reveal = nav.pendingTaskReveal,
          reveal.routeID == navigationRouteID else { return }

    if currentTask(id: reveal.taskID) != nil {
      selection = [reveal.taskID]
      scrollToTargetID = reveal.taskID
      scrollToTargetTick += 1
      nav.pendingTaskReveal = nil
      return
    }

    // Search can find a completed task beyond the first Logbook page. Do the
    // one intentionally-unbounded read needed to locate it, never on a normal
    // archive open.
    if filter == .logbook,
       !logbookRevealAll,
       LocalCache.taskMatches(id: reveal.taskID, filter: filter, in: modelContext) {
      logbookRevealAll = true
      Task { await load() }
      return
    }

    // The current mirror has finished loading this destination and the row no
    // longer belongs to it (for example, it was deleted or re-filed remotely).
    // Consume the request rather than leaving it to affect a later visit.
    if loadedFilters.contains(filter) {
      nav.pendingTaskReveal = nil
    }
  }

  private var navigationRouteID: String {
    switch filter {
    case .project(let id): return Route.project(id: id).id
    case .area(let id):    return Route.area(id: id).id
    default:               return Route.filter(filter).id
    }
  }

  /// Scoped local changes can skip an unrelated task list; unscoped CloudKit
  /// batches always repaint. A row already visible may have left the filter;
  /// a point-read catches a row that just entered it.
  private func taskChangeMayAffectCurrentList(_ note: Notification) -> Bool {
    guard let ids = note.changedTaskIDs else { return true }
    let visible = Set((triageItems + items).map(\.id))
    if !visible.isDisjoint(with: ids) { return true }
    return ids.contains { LocalCache.taskMatches(id: $0, filter: filter, in: modelContext) }
  }

  /// Pull the day's calendar events for the lists that weave them in. Owned by
  /// `TaskListModel`; kept as a one-line forwarder because several call sites
  /// (appear, filter swap, EventKit change) refresh it synchronously.
  private func refreshCalendarEvents() {
    model.refreshCalendarEvents(filter: filter, enabled: showCalendarEvents)
  }

  /// Rebuild the per-row filing-suggestion snapshot (the Inbox "→ Suggested"
  /// capsule). Owned by `TaskListModel`; primes the engine for every creatable
  /// list (so Area context menus still rank child projects on demand) while
  /// snapshotting inline capsules strictly on Inbox via `capsuleTop`.
  private func refreshFilingSuggestions() {
    var seen = Set<String>()
    let candidates = (triageItems + items).filter {
      ($0.status == .open || model.settle.isSettling($0.id)) && seen.insert($0.id).inserted
    }
    model.refreshFilingSuggestions(
      filter: filter,
      context: modelContext,
      engine: suggestionEngine,
      projects: projects,
      areas: areas,
      candidates: candidates,
      rankedTop: {
        TaskFilingSuggestions.capsuleTop(
          for: $0, filter: filter, engine: suggestionEngine,
          childProjectIds: { childProjectIds(in: $0) }
        )
      }
    )
  }

  // MARK: - Title chrome

  // Canonical destination icon (single source: `Route`), shared with the
  // sidebar smart-list rows and the title dropdown.
  private var titleIcon: String { Route.filter(filter).icon }

  private var titleTint: Color {
    .secondary
  }

}

/// One pending "Clear Logged…" confirmation: the task ids it will clear and
/// the prompt copy built for them (registry `clearLogged`).
private struct ClearLoggedRequest {
  let ids: [String]
  let copy: RegistryPromptCopy
}
