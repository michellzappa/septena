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
  /// App-root celebration layer — only used by the day-cleared `.arc`
  /// (see `TaskCelebration`). Optional: hosts outside the root env keep
  /// the haptic and skip the visual.
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

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
    let today = SeptenaDate.today
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
  #endif

  /// Selection binding handed to `List` — the keyboard-nav cursor.
  private var listSelection: Binding<Set<String>>? { $selection }


  // The full task editor — a standard detail drawer (When / Deadline / List /
  // Notes / Repeat + the agent conversation). Hosted by `.adaptiveDetail` —
  // sheet on iPhone, docked inspector on iPad/macOS — like every other section.
  // Reached for the attributes the inline title field can't express: a
  // double-click (macOS), the inline row's ⓘ Details button, or "Edit Details…"
  // in the context menu. Plain title edits stay inline (see `beginEdit`).
  @State private var editingDetail: SeptenaTask?

  // Drives the focused "New Task" compose modal opened by the `+` toolbar
  // button (and ⌘N, and the sidebar "New To-Do"). A dedicated composer — not
  // the app-wide capture / quick-find sheet — so creating from a list lands
  // the task in that list's context with no search surface in the way.
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
  /// Working buffer for the quick-add line. Commit creates a task in this
  /// list's context and re-focuses the line for rapid entry.
  @State private var newTaskText: String = ""

  /// Whether the Inbox section (on the Today view) is folded. Expanded by
  /// default; the header shows the count either way.
  @State private var inboxCollapsed = false
  /// Folds today's woven calendar agenda away — same gesture as the Inbox, but
  /// the choice sticks **for the day**: we persist the date it was folded on, so
  /// fold once and it stays folded across reloads / relaunches until tomorrow,
  /// when the stored date no longer matches `SeptenaDate.today` and it reopens.
  @AppStorage("septena.tasks.calendarFoldedOn") private var calendarFoldedOn = ""
  private var calendarCollapsed: Bool { calendarFoldedOn == SeptenaDate.today }
  private func toggleCalendarFold() {
    calendarFoldedOn = calendarCollapsed ? "" : SeptenaDate.today
  }

  // When picker. Use a single Identifiable item so the sheet's kind
  // is intrinsic to the presentation — avoids stale-state races where
  // tapping "When" could open the prior "Deadline" pane.
  @State private var whenSheet: WhenSheet?
  enum WhenKind { case deadline, scheduled }
  struct WhenSheet: Identifiable {
    let id: String   // composite of taskId + kind so reopening a kind re-presents cleanly
    let taskId: String
    let kind: WhenKind
    init(taskId: String, kind: WhenKind) {
      self.taskId = taskId
      self.kind = kind
      self.id = "\(taskId)|\(kind == .deadline ? "due" : "sched")"
    }
  }

  // Move picker
  @State private var showingMoveSheet = false
  @State private var moveTargetId: String?

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

  /// What `rowActionsMenu` operates on — always a single task now (the per-row
  /// context menu). Kept as a one-case enum so the menu builder's call sites
  /// stay stable.
  // Internal (not fileprivate) so the shared `TaskRowActions` modifier — used
  // on the Next surface — can drive the same `TaskListRowContextMenu`.
  enum ActionTarget {
    case single(SeptenaTask)
    var ids: [String] {
      switch self {
      case .single(let t): return [t.id]
      }
    }
    var isBulk: Bool { false }
  }


  // Local semantic sorter — populates a "→ Suggested" chip on Inbox rows.
  @State private var suggestionEngine = SuggestionEngine.shared
  /// Per-row Inbox "file here" suggestions, snapshotted in `load()` (keyed by
  /// task id). Held in @State — not read live off the engine — so the row chip
  /// reliably renders on load (see `load()`).
  @State private var inboxSuggestions: [String: SuggestionEngine.Suggestion] = [:]

  // "You have N new to-dos" banner — compact start-of-day welcome that
  // surfaces tasks rolling in from scheduled-past or due-today. Dismissed
  // per-day via UserDefaults (local only); reappears the next morning.
  // Cross-device same-day dismissal sync is in the backlog.
  @State private var newTodosDismissed: Bool =
    UserDefaults.standard.string(forKey: "septena.newTodos.dismissedDate") == SeptenaDate.today

  // Transient bottom snackbar — a confirmation (delete / move / defer) with an
  // optional Undo. The lifecycle is driven by a `.task(id:)` on the overlay so
  // SwiftUI owns the dismiss timer (a manually-held `Task` could be orphaned by
  // a body re-evaluation, which is why an earlier version flickered out early).
  @State private var toast: TaskToast?

  private struct TaskToast: Identifiable {
    let id = UUID()
    var message: String
    var duration: Double = 7
    var undo: (() -> Void)?
  }

  var body: some View {
    let base = taskList
      .modifier(TaskListModalPresenter(
        whenSheet: $whenSheet,
        showingMoveSheet: $showingMoveSheet,
        moveTargetId: $moveTargetId,
        showingRepeatSheet: $showingRepeatSheet,
        repeatTargetId: $repeatTargetId,
        areas: areas,
        projects: projects,
        currentTask: currentTask,
        currentScheduled: currentScheduled,
        currentDeadline: currentDeadline,
        currentRecurrence: currentRecurrence,
        applyWhen: applyWhen,
        applyMove: applyMove,
        applyRecurrence: applyRecurrence
      ))
    let withSnackbar = base.overlay(alignment: .bottom) {
      deleteSnackbar
    }
    .animation(.snappy, value: toast?.id)
    // SwiftUI-owned dismiss timer: re-runs whenever the toast id changes
    // (new toast restarts the clock; Undo / nil cancels the pending sleep).
    .task(id: toast?.id) {
      guard let seconds = toast?.duration else { return }
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      toast = nil
    }
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
      toggleToday: toggleTodayForSelected,
      openWhen: openWhenForSelected,
      openDeadline: openDeadlineForSelected,
      toggleComplete: selection.isEmpty ? nil : toggleSelected,
      delete: selection.isEmpty ? nil : deleteSelected,
      clearSchedule: selection.isEmpty ? nil : clearScheduleForSelected,
      rename: renameSelectedAction
    ))
    #else
    return withSnackbar
    #endif
  }

  @ViewBuilder
  private var deleteSnackbar: some View {
    if let toast {
      HStack(spacing: 12) {
        Text(toast.message)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(1)
        if let undo = toast.undo {
          Spacer(minLength: 0)
          Button("Undo") {
            undo()
            self.toast = nil
          }
          .font(.callout.weight(.semibold))
          .tint(.accentColor)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .padding(.horizontal, 20)
      .padding(.bottom, 16)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  private var taskList: some View {
    taskListContent
    // macOS: `.inset` gives the modern content-list look — a rounded, inset
    // selection capsule (Reminders / Notes / Mail), consistent with the
    // sidebar's `.sidebar` style — instead of `.plain`'s full-bleed square bar.
    // iOS keeps `.plain`: the standard edge-to-edge task list (selection there
    // is edit-mode circles, not a row highlight).
    #if os(macOS)
    .listStyle(.inset)
    // Keep the selection capsule neutral-gray, not the system blue accent —
    // accent colors are reserved to carry section meaning in this app, so a
    // blue highlight would read as a (meaningless) tint. `.tint` here only
    // recolors the selection; row icons set their own explicit colors.
    .tint(Theme.selectionNeutral)
    #else
    .listStyle(.plain)
    #endif
    .scrollContentBackground(.hidden)
    // Deep task-list rhythm runs denser than the drawer's: task rows read
    // `rowVInset` for their top/bottom padding, tightened here to Things-3
    // density. Drawer/log rows keep the default (airier) `Theme.rowVPadding`.
    .environment(\.rowVInset, Theme.rowVPaddingTight)
    #if os(macOS)
    // Clicking blank space (the paper behind the rows) clears the selection.
    // Rows sit above this background, so row clicks never reach it — only
    // empty gutters and the area below the last row deselect.
    .background(
      Theme.paperBackground
        .contentShape(Rectangle())
        .onTapGesture { clearSelection() }
    )
    #else
    .background(Theme.paperBackground)
    #endif
    .scrollDismissesKeyboard(.interactively)
    .toolbar {
      // No + button in the Recently Deleted view — you can't create trashed tasks.
      if filter != .recentlyDeleted {
        ToolbarItem(placement: .primaryAction) {
          // Identical to the drawer's action button (`DrawerActionButton`): a
          // plain Button + `.glassProminent` + section tint, so the system draws
          // the same prominent accent circle — no custom circle-in-a-pill.
          Button {
            SeptenaLog.info("[Create] + button tapped filter=\(String(describing: filter))")
            nav.shouldStartCreating = true
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.glassProminent)
          .tint(theme.color(for: "tasks"))
          .accessibilityLabel("New Task")
        }
      }
    }
    // The `+` toolbar button (and ⌘N, and the sidebar "New To-Do") open the
    // focused new-task composer via `shouldStartCreating` → `startCreate()`.
    .listKeyboardNavigation(
      inputActive: composerIsOpen,
      hasSelection: !selection.isEmpty,
      onReturn: openSelectedForEdit,
      onSpace: toggleSelected,
      onEscape: { clearSelection() }
    )
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
      // Calendar section is right on the first frame instead of popping in a
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
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      Task { await load() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaStructureChanged)) { _ in
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
    // Filter swaps reuse this same view (no .id(route) at the App level for
    // .filter cases). `items` is a computed property that already returns
    // the right data for `filter` synchronously, so we only need to clear
    // session-scoped state and re-trigger the network refresh.
    .onChange(of: filter) { _, _ in
      sessionDoneIds = []
      settle.cancelAll()
      clearSelection()
      editingDetail = nil
      // Drop any inline edit/quick-add in flight — the buffers belong to the
      // list we're leaving, not the one we're switching to.
      editingTitleId = nil
      titleDraft = ""
      newTaskText = ""
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
    // opening the focused new-task composer, scoped to the current list.
    .onChange(of: nav.shouldStartCreating) { _, _ in
      guard nav.shouldStartCreating else { return }
      nav.shouldStartCreating = false
      startCreate()
    }
    .onAppear {
      if nav.shouldStartCreating {
        nav.shouldStartCreating = false
        startCreate()
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
          onDone: { Task { await load() } }
        )
      }
    }
  }

  /// The composer presents create when `+`/⌘N is tripped, otherwise edit when
  /// a row is opened. The scrim blocks list taps while open, so the two are
  /// naturally mutually exclusive.
  private var composerMode: TaskComposerCard.Mode? {
    if creating { return .create(filter) }
    if let task = editingDetail { return .edit(task) }
    return nil
  }
  private var composerIsOpen: Bool { creating || editingDetail != nil }
  private var composerBinding: Binding<Bool> {
    Binding(get: { composerIsOpen }, set: { if !$0 { closeComposer() } })
  }
  private func closeComposer() {
    creating = false
    editingDetail = nil
  }

  /// Open the floating new-task capture card (`QuickTaskCapture`) for the
  /// current list. Unlike the app-wide capture sheet, this is a plain compose
  /// field — title + the list it lands in — with no search/quick-find surface;
  /// it commits on submit, so there are no leftover placeholder rows.
  private func startCreate() {
    withAnimation(.snappy(duration: 0.25)) {
      editingDetail = nil
      creating = true
    }
  }

  // MARK: - Inline editing

  /// Whether this list accepts an inline quick-add line. Logbook (completed) and
  /// Recently Deleted are read-only histories. Upcoming is excluded too: it's a
  /// multi-day grouped grid with no single target day, so a foot-of-list line
  /// would just dump every capture onto "tomorrow" regardless of context — use
  /// the `+`/⌘N composer there (it lets you pick the day). Today hosts no foot
  /// line either; its captures go through the composer as well.
  private var allowsInlineCreate: Bool {
    switch filter {
    case .logbook, .recentlyDeleted, .upcoming: return false
    default:                                    return true
    }
  }

  /// Begin renaming a task.
  ///
  /// macOS: rename in the COMPOSER, never inline. Swapping a focusable
  /// `TextField` into a selectable `List` row and removing it corrupts the
  /// List's focus/selection on macOS (clicks + arrows die afterward, the field's
  /// selected text lingers) — an unwinnable fight with SwiftUI's `List`. The
  /// composer is a separate inspector where the title field's focus/Return/Esc
  /// behave, and the List stays pure-native and unbroken.
  ///
  /// iOS: inline rename in place (no NavigationSplitView focus war there).
  private func beginEdit(_ task: SeptenaTask) {
    #if os(macOS)
    editingDetail = task
    #else
    guard task.status != .done else { editingDetail = task; return }
    if let prevId = editingTitleId, prevId != task.id,
       let prev = currentTask(id: prevId) {
      commitRename(prev)
    }
    newTaskText = ""
    titleDraft = task.title
    editingTitleId = task.id
    selection = [task.id]
    // Focus on the next runloop so the field (which appears this same update,
    // as the row swaps from static → editing) is mounted before we focus it —
    // a synchronous set is otherwise dropped before it joins the responder chain.
    DispatchQueue.main.async { inlineFocus = .row(task.id) }
    #endif
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

  /// Move keyboard focus into the quick-add line (the macOS empty-space
  /// double-click and the iOS "+ New task" tap both land here).
  private func focusNewTask() {
    guard allowsInlineCreate else { return }
    if let prevId = editingTitleId, let prev = currentTask(id: prevId) {
      commitRename(prev)
    }
    DispatchQueue.main.async { inlineFocus = .newRow }
  }

  /// Commit the quick-add line: create a task in this list's context (reusing
  /// the composer's `TaskDraft(filter:)` placement mapping so a row added on
  /// Today lands on Today, on a project lands in that project, etc.), clear the
  /// buffer, and keep the cursor on the line for rapid back-to-back entry.
  private func commitNewTask() {
    let trimmed = newTaskText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { inlineFocus = nil; return }
    // On Today the quick-add line lives in the Inbox section, so it captures a
    // LOOSE task (no Today pin / date / list) — an unratified Inbox item, not a
    // committed-today one. `.triage` seeds nothing, so the task lands in the
    // triage band. Every other list files into its own context (project / area /
    // a tomorrow date for Upcoming) via the normal seed.
    var draft = TaskDraft(filter: filter == .today ? .triage : filter)
    draft.title = trimmed
    draft.create(via: mutator)
    AddInfoSection.tasks.notifyTilesChanged()
    newTaskText = ""
    Task { await load() }
    // Re-assert focus so the next title can be typed immediately (Reminders'
    // rapid-entry: Return commits and drops you onto a fresh line). Async so the
    // reload's rebuild can't drop the focus assignment.
    DispatchQueue.main.async { inlineFocus = .newRow }
  }

  private var taskListContent: some View {
    // `selection` is bound to List on both platforms; rows carry `.tag(id)` so
    // List can map a row to a selection value. The native selection highlight
    // is the single indicator — on macOS it doubles as the context-menu
    // target, on iOS the edit-mode circle shows membership. We never draw our
    // own selection background (see `rowBackground`).
    //   • macOS: single-click select, ⌘/⇧-click, ↑↓ — all native.
    //   • iOS: a Set selection only engages in edit mode, so outside edit mode
    //     taps fall through to our single-tap-to-edit gesture; inside it, taps
    //     toggle the native circles.
    List(selection: listSelection) {
      taskListHeader
      taskListRows
      // The quick-add line lives in the Inbox section on Today (see
      // `triageSection`); every other list gets it at the foot, where its single
      // context is unambiguous.
      if filter != .today { quickAddRow }
      taskListFooter
    }
    // Commit a rename the moment its field loses the cursor — the iOS analog of
    // Esc/Return (no hardware Esc there). Row→row switches are pre-committed in
    // `beginEdit`; this catches focus going to the quick-add line or to nil.
    .onChange(of: inlineFocus) { old, _ in commitRenameOnFocusLoss(from: old) }
    #if os(macOS)
    // PURE native selection: click / ⌘/⇧-click / ↑↓ are the List's own, and a
    // native click also gives the List key focus (no programmatic focus claim —
    // an extra `@FocusState` on the List fought the inline field's focus and
    // left clicks dead after an edit). Keyboard actions on the selected row are
    // MODIFIER menu commands (⌘R rename, ⌘K complete) — reliable regardless of
    // focus; unmodified Space/Return are NOT bound (they hit the checkbox /
    // sidebar). Double-click opens the composer; right-click → Rename / Edit
    // Details. Esc is handled in both places (the inline field owns it while it
    // has focus — see InlineTaskRow — and this is the fallback when the list does):
    //   editing → COMMIT the rename (safer than cancel) · quick-add → blur ·
    //   selected → deselect.
    .onExitCommand {
      if let id = editingTitleId, let task = currentTask(id: id) { commitRename(task) }
      else if inlineFocus != nil { inlineFocus = nil }
      else { clearSelection() }
    }
    #endif
  }

  @ViewBuilder
  private var taskListHeader: some View {
    titleRow
    newTodosBannerRow
    remindersRow
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
    // Rendered on Today only when there's something to triage. (It used to be
    // always-on to host the inline quick-add line; that line was dropped, so an
    // empty Inbox now stays out of the way entirely.) New tasks come from the
    // toolbar `+` / ⌘N composer.
    if filter == .today, !triageItems.isEmpty {
      Section {
        if !inboxCollapsed {
          ForEach(triageItems) { task in row(task, quickMenu: true).asTaskRow(id: task.id) }
        }
      } header: {
        inboxHeader(count: triageItems.count)
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
  /// anywhere on it toggles the section. Shared by the Inbox and the woven
  /// Calendar agenda so both fold identically.
  @ViewBuilder
  private func foldableSectionHeader(icon: String, title: String, count: Int? = nil,
                                     isCollapsed: Bool, showsHairline: Bool = true,
                                     onToggle: @escaping () -> Void) -> some View {
    #if os(macOS)
    let headerTopPadding: CGFloat = 32
    let headerHorizontalCorrection: CGFloat = 0
    #else
    let headerTopPadding: CGFloat = 18
    let headerHorizontalCorrection: CGFloat = -16
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
        .padding(.horizontal, Theme.hPadding)
        .padding(.horizontal, headerHorizontalCorrection)
        .padding(.top, headerTopPadding)
        .padding(.bottom, 6)
        // A collapsed Calendar drops its own hairline so it doesn't stack a
        // second divider above the next section's — one rule, not two.
        if showsHairline {
          Hairline().padding(.bottom, 4)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .textCase(nil)
    .selectionDisabled()
  }

  @ViewBuilder
  private var taskListRows: some View {
    switch filter {
    case .today:
      todayCalendarSection
      triageSection
      groupedOpenItems
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
      .simultaneousGesture(TapGesture(count: 2).onEnded { focusNewTask() })
      .simultaneousGesture(TapGesture(count: 1).onEnded { clearSelection() })
      #else
      .onTapGesture { clearSelection() }
      #endif
      .asListRow()
  }

  @ViewBuilder
  private var titleRow: some View {
    if !embedded {
      ScreenTitle(icon: titleIcon, iconTint: titleTint, title: filter.title)
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
    if loadedFilters.contains(filter) && visibleItems.isEmpty && review.isEmpty && doneToday.isEmpty && triageItems.isEmpty && !isLoading {
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
          description: Text("Tap the + button to add a task.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .plainListChrome()
      }
    }
  }

  private var reviewRows: some View {
    ForEach(review) { task in row(task).asTaskRow(id: task.id) }
  }

  private var visibleRows: some View {
    ForEach(visibleItems) { task in
      row(task).asTaskRow(id: task.id)
    }
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
      // Inbox rows render above the Today groups, so traverse them first.
      return triageItems.map(\.id) + orderedFromGroupedOpen(pool: items + review)
    case .unscheduled:
      return review.map(\.id) + orderedFromGroupedOpen(pool: items)
    case .upcoming:
      return review.map(\.id) + upcomingBuckets().flatMap { $0.tasks.map(\.id) }
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

  private func openSelectedForEdit() {
    guard let id = effectiveSelectionId(),
          let t = currentTask(id: id) else { return }
    editingDetail = t
  }

  #if os(macOS)
  /// The action behind the ⌘R "Rename" menu command. Nil — so the menu item
  /// disables and ⌘R falls through — when a text field / picker sheet is active
  /// or no plain open row is selected. Uses an EXPLICIT selection (not
  /// `effectiveSelectionId`'s first-row fallback), and `currentTask` now includes
  /// Inbox rows, so it renames exactly the selected task.
  private var renameSelectedAction: (() -> Void)? {
    guard editingTitleId == nil, inlineFocus == nil, !composerIsOpen,
          whenSheet == nil, !showingMoveSheet, !showingRepeatSheet,
          !nav.showQuickFind,
          let id = selection.first(where: { currentTask(id: $0) != nil }),
          let task = currentTask(id: id), task.status != .done
    else { return nil }
    return { beginEdit(task) }
  }
  #endif

  private func toggleSelected() {
    guard let id = effectiveSelectionId(),
          let t = currentTask(id: id) else { return }
    toggle(t)
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
    guard let id = effectiveSelectionId(),
          let t = currentTask(id: id) else { return }
    Haptics.tick()
    if t.isOnToday { mutator.removeFromToday(id: t.id) }
    else { mutator.moveToToday(id: t.id, today: true) }
    Task { await load() }
  }

  /// ⌘S — open the When (schedule) picker for the focused row.
  private func openWhenForSelected() {
    guard let id = effectiveSelectionId() else { return }
    whenSheet = WhenSheet(taskId: id, kind: .scheduled)
  }

  /// ⌘⇧D — open the Deadline picker for the focused row.
  private func openDeadlineForSelected() {
    guard let id = effectiveSelectionId() else { return }
    whenSheet = WhenSheet(taskId: id, kind: .deadline)
  }

  /// ⌘⌫ — delete every selected row (or the effective single row).
  private func deleteSelected() {
    let ids = selection.isEmpty ? [effectiveSelectionId()].compactMap { $0 } : Array(selection)
    guard !ids.isEmpty else { return }
    Haptics.warning()
    clearSelection()
    for id in ids { applyDelete(id) }
  }

  /// ⌘. — clear schedule + today, sending the row back to Anytime.
  private func clearScheduleForSelected() {
    guard let id = effectiveSelectionId() else { return }
    applyWhen(id: id, kind: .scheduled, date: nil)
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
      motion.run(Theme.Motion.settle) { }
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

  /// Present the bottom snackbar. The `.task(id:)` on the overlay owns the
  /// auto-dismiss; this just sets the payload (a fresh id restarts the clock).
  private func showToast(_ message: String, undo: (() -> Void)? = nil) {
    toast = TaskToast(message: message, undo: undo)
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
    mutator.update(id: id, title: trimmed, notes: notes)
    Task { await load() }
  }

  private func applyMove(id: String, areaId: String?, projectId: String?) {
    Haptics.tick()
    // Capture the prior filing BEFORE the move so Undo can put it back.
    let task = currentTask(id: id)
    let prevArea = task?.area
    let prevProject = task?.project
    if let task {
      let chosenKind: SuggestionEngine.Suggestion.Kind? =
        projectId != nil ? .project : (areaId != nil ? .area : nil)
      let chosenId = projectId ?? areaId
      recordImplicitRejectionIfMismatch(task: task,
                                        chosenKind: chosenKind,
                                        chosenId: chosenId)
    }
    // Project takes precedence — Septena derives area from project on save.
    if projectId != nil {
      mutator.moveToProject(id: id, project: projectId)
    } else {
      mutator.moveToArea(id: id, area: areaId)
      mutator.moveToProject(id: id, project: nil)
    }
    // Filing is engagement — clear the agent cue so a moved proposal leaves the
    // Inbox. No-op for non-agent / already-seen rows.
    mutator.acknowledge(id: id)
    Task { await load() }

    // The inline move submenus relocate a row with no visible trace ("where did
    // it go?"). Name the destination and offer a one-tap Undo back to the prior
    // area/project — the same move primitives, run in reverse.
    let destName =
      projectId.flatMap { pid in projects.first { $0.id == pid }?.title }
      ?? areaId.flatMap { aid in areas.first { $0.id == aid }?.title }
      ?? "No Project"
    showToast("Moved to \(destName)") {
      if let prevProject {
        mutator.moveToProject(id: id, project: prevProject)
      } else {
        mutator.moveToArea(id: id, area: prevArea)
        mutator.moveToProject(id: id, project: nil)
      }
      Task { await load() }
    }
  }

  // MARK: - Row

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
    .draggable(task.id) {
      Text(task.title)
        .scaledFont(size: 13)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    #endif
  }

  /// The one-tap "file here" capsule for a confident Inbox suggestion — rendered
  /// as the inboard-most trailing accessory (left of the date). Nil when the
  /// classifier isn't confident. Tapping files the task + acknowledges.
  private func suggestionCapsule(for task: SeptenaTask) -> AnyView? {
    guard let suggestion = inboxSuggestion(for: task) else { return nil }
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
        .background(Capsule().fill(theme.color(for: "tasks").opacity(0.14)))
        .foregroundStyle(theme.color(for: "tasks"))
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
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
      case .project, .unscheduled, .today: return true
      default:                             return false
      }
    }()
    let suppressArea: Bool = {
      switch filter {
      case .project, .area, .unscheduled, .today: return true
      default:                                    return false
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
      accessory: accessory,
      onToggle: { toggle(task) },
      onTap: nil
    )
    // Fade on insert/removal. The fade only plays inside an animated
    // transaction; every settle-driven removal runs through `motion.run`, so
    // Reduce Motion still gets an instant (un-animated) drop.
    .transition(.opacity)
    //   • iOS: single tap → rename the title in place (skipped while reordering;
    //     completed rows open the composer instead). Full composer = the ⓘ on
    //     the inline row.
    //   • iOS: single tap renames in place.
    //   • macOS: native List handles single-click select + ⌘/⇧-click + ↑/↓; a
    //     plain `.onTapGesture(count: 2)` opens the composer. Unlike the
    //     `.simultaneousGesture` form (which swallowed the selecting click), a
    //     count-2 tap only matches the double-click and leaves the single click
    //     to the List's native selection. Rename = ⌘R / right-click → Rename.
    #if os(iOS)
    .simultaneousGesture(SpatialTapGesture().onEnded { value in
      guard !isEditMode else { return }
      if value.location.x < Theme.hPadding + Theme.checkboxTap { return }
      beginEdit(task)
    })
    #else
    .onTapGesture(count: 2) { editingDetail = task }
    #endif
    // Right-click selects this row (unless already part of a selection) so the
    // menu's target is unambiguous.
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
      // The row instead shows as selected (native highlight on macOS via the
      // selection set; the tinted highlight below on iOS).
      isToday: false,
      isSelected: true,
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
        editingDetail = task
      }
    )
    .transition(.opacity)
    .septenaOnRightClick {
      if !selection.contains(task.id) { selectOnly(task.id) }
    }
    .contextMenu { taskContextMenu(for: task) }
  }

  /// The always-present quick-add line at the foot of a single-context list (the
  /// Reminders empty bottom row). A single click / tap focuses it; Return
  /// commits and re-focuses for rapid back-to-back entry. Today hosts the same
  /// line inside its Inbox section instead (see `triageSection`).
  @ViewBuilder
  private var quickAddRow: some View {
    if allowsInlineCreate {
      quickAddLine().asListRow()
    }
  }

  /// The shared quick-add field — one definition for both the Inbox-section line
  /// (Today) and the foot-of-list line (every other creatable list). The
  /// checkbox is neutral (never the Today-yellow): a not-yet-created task isn't
  /// "promoted to Today".
  private func quickAddLine() -> some View {
    InlineTaskRow(
      text: $newTaskText,
      placeholder: "New task",
      accent: theme.color(for: "tasks"),
      isDone: false,
      isToday: false,
      isSelected: false,
      focus: $inlineFocus,
      focusValue: .newRow,
      showsDetails: false,
      onToggle: {},
      onCommit: { commitNewTask() },
      onCancel: { inlineFocus = nil },
      onOpenDetails: nil
    )
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
        onRename: { task in beginEdit(task) },
        onOpenDetail: { task in editingDetail = task },
        onApplySuggestion: applySuggestion,
        onMoveToToday: { ids, today in
          Haptics.tick()
          for id in ids {
            if today { mutator.moveToToday(id: id, today: true) }
            else { mutator.removeFromToday(id: id) }
            // Engagement — clear the agent cue so a ratified proposal leaves the
            // Inbox. No-op for non-agent / already-seen rows.
            mutator.acknowledge(id: id)
          }
          Task { await load() }
        },
        onOpenWhen: { target in
          if case .single(let t) = target { whenSheet = WhenSheet(taskId: t.id, kind: .scheduled) }
        },
        onOpenDeadline: { target in
          if case .single(let t) = target { whenSheet = WhenSheet(taskId: t.id, kind: .deadline) }
        },
        onOpenMove: { target in
          if case .single(let t) = target { moveTargetId = t.id; showingMoveSheet = true }
        },
        onMoveTo: { target, areaId, projectId in
          if case .single(let t) = target {
            Haptics.pick()
            applyMove(id: t.id, areaId: areaId, projectId: projectId)
          }
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
    rowActionsMenu(target: .single(task))
  }

  private func rankedSuggestions(for target: ActionTarget) -> [SuggestionEngine.Suggestion]? {
    guard case let .single(task) = target, task.status == .open else { return nil }
    // Today's triage band keeps its richer pre-ranked list (computed in `load()`).
    if filter == .today, let top = suggestionEngine.topSuggestion(for: task.id) {
      return suggestionEngine.suggestions[task.id] ?? [top]
    }
    // Any other view: classify the title on demand against the trained model,
    // but only offer a destination the task ISN'T already filed under (no
    // "Move to <where it already lives>").
    guard let s = suggestionEngine.suggest(forText: task.title) else { return nil }
    let alreadyThere = (s.kind == .area && task.area == s.id)
      || (s.kind == .project && task.project == s.id)
    return alreadyThere ? nil : [s]
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
    Task { await load() }
  }

  /// The one-tap "file here" suggestion for an Inbox row — only for genuinely
  /// loose captures (no project/area yet) and only when the classifier is
  /// confident (`topSuggestion` is already evidence + margin gated). Agent rows
  /// that already carry a placement are ratified via the checkbox / ⋯, not this.
  private func inboxSuggestion(for task: SeptenaTask) -> SuggestionEngine.Suggestion? {
    inboxSuggestions[task.id]
  }

  /// Implicit "Not this" — fires when the user moves the task somewhere
  /// other than the engine's top pick (via the menu's alternates, "Other…",
  /// the context menu's Move, or any other path that calls applyMove).
  /// Records the top suggestion as a rejection for this target so similar
  /// future tasks won't pick it.
  private func recordImplicitRejectionIfMismatch(task: SeptenaTask,
                                                 chosenKind: SuggestionEngine.Suggestion.Kind?,
                                                 chosenId: String?) {
    guard let top = suggestionEngine.topSuggestion(for: task.id) else { return }
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

  // MARK: - Unscheduled grouping (by project / area)

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
    let loose = pool.filter { $0.project == nil && $0.area == nil }

    // Loose tasks first — uncategorized, no header. On Today with an Inbox
    // stacked above, draw a hairline seam first so the first ratified row
    // doesn't read as a 4th Inbox entry (see docs/TRIAGE_BAND_SPEC.md). Skip it
    // when the Inbox is collapsed — its own header hairline already abuts the
    // Today rows, so a second line would just stack on top of it.
    if filter == .today && !triageItems.isEmpty && !loose.isEmpty && !inboxCollapsed {
      Hairline()
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .plainListChrome()
    }
    ForEach(loose) { task in row(task).asTaskRow(id: task.id) }

    // Areas in sidebar order: direct-area tasks, then each project's tasks.
    ForEach(areas) { area in
      let areaTasks = byArea[area.id] ?? []
      if !areaTasks.isEmpty {
        Section {
          ForEach(areaTasks) { task in row(task).asTaskRow(id: task.id) }
        } header: {
          groupHeader(icon: "square.stack.3d.up.fill",
                      title: area.title,
                      areaEmoji: area.emoji,
                      onTap: { nav.path = [.area(area)] })
        }
      }
      ForEach(projects.filter { $0.area == area.id }) { project in
        if let tasks = byProject[project.id], !tasks.isEmpty {
          Section {
            ForEach(tasks) { task in row(task).asTaskRow(id: task.id) }
          } header: {
            groupHeader(icon: nil,
                        title: project.title,
                        onTap: { nav.path = [.project(project)] })
          }
        }
      }
    }

    // Top-level projects (no area).
    ForEach(projects.filter { $0.area == nil }) { project in
      if let tasks = byProject[project.id], !tasks.isEmpty {
        Section {
          ForEach(tasks) { task in row(task).asTaskRow(id: task.id) }
        } header: {
          groupHeader(icon: nil,
                      title: project.title,
                      onTap: { nav.path = [.project(project)] })
        }
      }
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
                           onTap: (() -> Void)? = nil) -> some View {
    groupHeaderBody(icon: icon, title: title, areaEmoji: areaEmoji, onTap: onTap)
      .textCase(nil)
      .selectionDisabled()
  }

  private func groupHeaderBody(icon: String?, title: String,
                               areaEmoji: String? = nil,
                               onTap: (() -> Void)? = nil) -> some View {
    // Same icon column width and same icon→text gap as task rows so
    // every icon sits at one X and every text starts at one X.
    #if os(macOS)
    let headerTopPadding: CGFloat = 32
    let headerHorizontalCorrection: CGFloat = 0
    let titleLeadingCorrection: CGFloat = -6
    #else
    let headerTopPadding: CGFloat = 18
    // Nudge the whole header (symbol + title) ~2pt left of where it sat so the
    // area/project symbol lines up over the task-row checkbox.
    let headerHorizontalCorrection: CGFloat = -18
    // Cancel GroupHeaderLabel's internal 6pt leading (less the 2pt the group
    // already shifted) so the tappable title lands at the same X as task-row
    // text — the same alignment macOS gets from its -6.
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
          ProjectProgressIcon(progress: 0.25, tint: Theme.inkSecondary, diameter: 14)
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
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.horizontal, headerHorizontalCorrection)
      // ~2 lines of whitespace above each project/area cluster header so
      // groups visually break apart in mixed list views (Unscheduled, Today,
      // Upcoming). Without this gap, a header reads as the next row of the
      // previous group instead of the start of a new one.
      .padding(.top, headerTopPadding)
      .padding(.bottom, 6)

      // Hairline beneath project/area cluster headers — separates the title
      // from the tasks underneath in mixed-list views (Today, Unscheduled).
      // Date buckets (Upcoming) are non-tappable and skip the rule.
      if onTap != nil {
        Hairline()
          .padding(.bottom, 4)
      }
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
    let today = cal.startOfDay(for: Date())
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

  /// The day's calendar events as a "Calendar" section at the top of Today —
  /// the agenda you read before the to-dos. Only renders when the opt-in is on
  /// and there's something to show; `calendarEvents` is already gated to
  /// granted-access in `refreshCalendarEvents()`.
  @ViewBuilder
  private var todayCalendarSection: some View {
    if showCalendarEvents, !calendarEvents.isEmpty {
      Section {
        if !calendarCollapsed {
          calendarEventsBlock(calendarEvents)
        }
      } header: {
        foldableSectionHeader(icon: "calendar", title: "Calendar",
                              isCollapsed: calendarCollapsed,
                              showsHairline: !calendarCollapsed) {
          toggleCalendarFold()
        }
      }
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
          calendarEventsBlock(bucket.events)
        }
        ForEach(bucket.tasks) { task in row(task).asTaskRow(id: task.id) }
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
    let today = SeptenaDate.today
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
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let target = cal.startOfDay(for: date)
    let days = cal.dateComponents([.day], from: today, to: target).day ?? 0
    if days == 0 { return "Today" }
    if days == 1 { return "Tomorrow" }
    let df = DateFormatter()
    df.locale = .current
    df.dateFormat = (days < 7) ? "EEEE" : "EEE, MMM d"
    return df.string(from: date)
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
          mutator.moveToToday(id: id, today: true)
        } else {
          mutator.moveToToday(id: id, today: false)
          mutator.schedule(id: id, date: d)
          // Deferring drops the row off Today; confirm where it landed. No
          // Undo — re-opening the When picker is the natural reversal.
          showToast("Deferred to \(dateHeaderLabel(SeptenaDate.format(d) ?? ""))")
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
    // out IN PLACE and is gone (it lives on in the dedicated Logbook); the empty
    // animated transaction lets that removal play `.transition(.opacity)`.
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
        motion.run(Theme.Motion.settle) { }
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
    drop(&items); drop(&review); drop(&doneToday)
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
    items = preservingSettling(fresh: local, prior: prior)
    review = []
    doneToday = []
    loadedFilters.insert(filter)
    // Projects + areas live in SwiftData (mirrored by CKSyncEngine), so
    // the local cache is authoritative — no network round-trip needed.
    projects = LocalCache.projects(in: modelContext)
    areas = LocalCache.areas(in: modelContext)
    // Refresh the inbox suggestion engine from local data. LocalCache
    // returns every status, so the engine sees the full corpus for
    // ranking.
    // Today's triage band gets the richer per-task ranked suggestions; every
    // other view (except the all-done Logbook) still trains the model so a
    // row's context menu can suggest a destination on demand via
    // `suggest(forText:)`.
    if filter == .today {
      // Re-read the Inbox and merge back any just-checked row that's still
      // settling (the `.triage` query drops done tasks), so an accepted
      // suggestion lingers struck-through and fades in place like every other
      // completed row — same preservation `items` gets above.
      let localTriage = LocalCache.tasks(in: modelContext, filter: .triage)
      triageStorage = preservingSettling(fresh: localTriage, prior: triageStorage)
      // The Inbox lives on the Today view now (the triage rows), so classify
      // the live open rows — that's what powers the one-tap "file here"
      // suggestion chip and the implicit "not this" learning. refresh also
      // primes the model for the composer's on-keystroke suggest().
      let allTasks = LocalCache.allTasks(in: modelContext)
      suggestionEngine.refresh(inbox: localTriage,
                               allTasks: allTasks,
                               projects: projects,
                               areas: areas)
    } else {
      triageStorage = []
    }
    if filter != .today && filter != .logbook && filter != .recentlyDeleted {
      suggestionEngine.prepare(allTasks: LocalCache.allTasks(in: modelContext),
                               projects: projects,
                               areas: areas)
    }
    // Snapshot the per-row Inbox suggestions into @State so the chip renders
    // (and re-renders) with each load. Reading the @Observable engine live
    // inside the row's body proved unreliable for this list; the composer's
    // own suggestion chip works precisely because it caches into @State too.
    let suggestSource: [SeptenaTask] = filter == .today ? triageItems : []
    var freshSuggestions: [String: SuggestionEngine.Suggestion] = [:]
    for t in suggestSource where t.project == nil && t.area == nil {
      // Use the SAME call the composer's working chip uses, so the row and the
      // edit box never disagree on confidence (the model was just trained by the
      // refresh/prepare above).
      if let s = suggestionEngine.suggest(forText: t.title) { freshSuggestions[t.id] = s }
    }
    inboxSuggestions = freshSuggestions
    // Refresh dismissed state — banner reappears next day automatically.
    if filter == .today {
      let last = UserDefaults.standard.string(forKey: "septena.newTodos.dismissedDate")
      newTodosDismissed = (last == SeptenaDate.today)
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
        UserDefaults.standard.set(SeptenaDate.today, forKey: "septena.newTodos.dismissedDate")
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

  private var titleIcon: String {
    switch filter {
    case .today: return "sun.max.fill"
    case .triage: return "tray.full"
    case .upcoming: return "calendar"
    case .unscheduled: return "rectangle.stack"
    case .logbook: return "checkmark.circle"
    case .recentlyDeleted: return "trash"
    case .project: return "number"
    case .area: return "folder"
    }
  }

  private var titleTint: Color {
    .secondary
  }

}

/// Compact tappable target for area / project section headers inside a list.
/// Wraps just the title (and optional chevron) so the click target matches the
/// visible text rather than the whole row width. Lights up with a subtle hover
/// background on macOS / iPadOS pointer; no-op on touch-only devices.
private struct GroupHeaderLabel: View {
  let title: String
  let hasChevron: Bool
  let action: () -> Void
  @State private var hovered = false

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
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Area/project headers are pointer-only affordances: clickable to drill
    // into the section, but kept OUT of the keyboard focus chain so ↑/↓ and
    // Tab traverse only task rows. Without this, the header Button steals a
    // focus stop between every group.
    .focusable(false)
    .onHover { hovered = $0 }
  }
}

/// Encapsulates the standalone-tab nav chrome so we can opt out cleanly
/// when TaskListView is embedded inside a detail page.
private struct TopLevelChromeModifier: ViewModifier {
  let showChrome: Bool

  func body(content: Content) -> some View {
    if showChrome {
      content
        .septenaInlineTitle()
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
  @Binding var moveTargetId: String?
  @Binding var showingRepeatSheet: Bool
  @Binding var repeatTargetId: String?

  let areas: [Area]
  let projects: [Project]
  let currentTask: (String?) -> SeptenaTask?
  let currentScheduled: (String?) -> Date?
  let currentDeadline: (String?) -> Date?
  let currentRecurrence: (String?) -> Recurrence?
  let applyWhen: (String, TaskListView.WhenKind, Date?) -> Void
  let applyMove: (String, String?, String?) -> Void
  let applyRecurrence: (String, Recurrence?) -> Void

  func body(content: Content) -> some View {
    content
      .sheet(item: $whenSheet) { sheet in
        switch sheet.kind {
        case .scheduled:
          DatePickerSheet(
            title: "When",
            initialDate: currentScheduled(sheet.taskId),
            setLabel: "Set Date",
            updateLabel: "Update Date",
            clearLabel: "No Date"
          ) { date in
            applyWhen(sheet.taskId, .scheduled, date)
          }
          .presentationDetents([.height(DatePickerSheet.sheetHeight), .large])
          .presentationBackground(.thinMaterial)
          .presentationCornerRadius(Theme.cornerRadius)
        case .deadline:
          DatePickerSheet(
            title: "Deadline",
            initialDate: currentDeadline(sheet.taskId),
            setLabel: "Set Deadline",
            updateLabel: "Update Deadline",
            clearLabel: "Remove Deadline"
          ) { date in
            applyWhen(sheet.taskId, .deadline, date)
          }
          .presentationDetents([.height(DatePickerSheet.sheetHeight), .large])
          .presentationBackground(.thinMaterial)
          .presentationCornerRadius(Theme.cornerRadius)
        }
      }
      .sheet(isPresented: $showingMoveSheet) {
        let target = currentTask(moveTargetId)
        MovePickerSheet(
          areas: areas,
          projects: projects,
          currentAreaId: target?.area,
          currentProjectId: target?.project
        ) { areaId, projectId in
          if let id = moveTargetId {
            applyMove(id, areaId, projectId)
          }
          moveTargetId = nil
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
  /// Begin an in-place title rename. Optional — the deep Tasks list supplies it;
  /// the Next surface (which has no inline editor) leaves it nil.
  var onRename: ((SeptenaTask) -> Void)? = nil
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

  var body: some View {
    if case let .single(task) = target {
      if let onRename, task.status != .done {
        Button {
          onRename(task)
        } label: {
          Label("Rename", systemImage: "pencil")
        }
      }
      Button {
        onOpenDetail(task)
      } label: {
        Label("Edit Details…", systemImage: "info.circle")
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

    if singleTodayFlag == true {
      Button {
        onMoveToToday(target.ids, false)
      } label: {
        Label("Remove from Today", systemImage: "sun.min")
      }
    } else if singleTodayFlag == false && filter != .today {
      Button {
        onMoveToToday(target.ids, true)
      } label: {
        Label("Move to Today", systemImage: "sun.max.fill")
      }
    }

    Button {
      onOpenWhen(target)
    } label: {
      Label("When…", systemImage: "calendar")
    }

    Button {
      onOpenDeadline(target)
    } label: {
      Label("Deadline…", systemImage: "flag")
    }

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
      Label("Move", systemImage: "folder")
    }

    if case let .single(task) = target {
      Button {
        onOpenRepeat(task)
      } label: {
        Label("Repeat…", systemImage: "repeat")
      }
    }

    Divider()

    Button {
      onCancel(target.ids)
    } label: {
      Label("Cancel Task", systemImage: "xmark.circle")
    }

    Divider()

    Button(role: .destructive) {
      onDelete(target)
    } label: {
      Label("Delete", systemImage: "trash")
    }
  }

  // Drives the "Move to / Remove from Today" label. Reads `isOnToday`, not the
  // raw `today` pin, so a task that's in Today via a scheduled/deadline date
  // (unpinned) is correctly offered "Remove from Today" rather than a no-op
  // "Move to Today."
  private var singleTodayFlag: Bool? {
    if case let .single(task) = target { return task.isOnToday }
    return nil
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
  var toggleToday: () -> Void
  var openWhen: () -> Void
  var openDeadline: () -> Void
  /// Toggles done/open on the selected row — same handler as Space.
  /// Nil-gated by selection so ⌘K can't fire on an empty list.
  var toggleComplete: (() -> Void)?
  /// Nil when nothing is selected — disables the menu item rather than
  /// letting ⌘⌫ silently grab the first row.
  var delete: (() -> Void)?
  /// Same gating as `delete` — ⌘. shouldn't act on an unintended row.
  var clearSchedule: (() -> Void)?
  /// ⌘R → rename the selected row in place. Nil (→ menu item disabled) when a
  /// text field/sheet is active or no open row is selected. A MODIFIER menu
  /// shortcut is the reliable way to do this on macOS — unmodified Space/Return
  /// can't be (they hit the checkbox / the sidebar). See CLAUDE.md.
  var rename: (() -> Void)?
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

// MARK: - List row chrome helper
//
// Every row we draw inside the List should opt out of the default
// separator / row background / row insets so our existing row composition
// (selection pill, padding, full-bleed action icons) lines up exactly the
// way it did inside the old LazyVStack. Non-task rows also opt out of List
// selection so keyboard traversal lands only on tagged task rows.
// Used in `body` directly and inside the grouping helpers.

extension View {
  func asListRow() -> some View {
    self
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
      .selectionDisabled()
  }

  func asTaskRow(id: String) -> some View {
    self
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
      .tag(id)
  }

  func plainListChrome() -> some View {
    listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
      .selectionDisabled()
  }
}

// MARK: - Inline editable task line
//
// The shared atom behind BOTH in-place rename and the quick-add footer — the
// merged "type-a-line" behavior. It mirrors `CheckableRow`'s layout (a
// baseline-aligned `TaskCheckbox` + the title) so an editing row sits flush
// with its static neighbours, but renders the title as a `TextField`. The
// quick-add line passes an inert `onToggle` (no task to check yet); rename
// passes the row's real toggle so you can still check a task mid-edit.

private struct InlineTaskRow: View {
  @Binding var text: String
  let placeholder: String
  let accent: Color
  let isDone: Bool
  var isToday: Bool = false
  /// Draw the row as selected. macOS gets the native source-list highlight from
  /// the List selection set, so this only paints the iOS highlight (List
  /// selection there shows only in edit mode).
  var isSelected: Bool = false
  @FocusState.Binding var focus: TaskListView.InlineFocus?
  let focusValue: TaskListView.InlineFocus
  /// Show the trailing ⓘ Details button (rename rows on iOS use it to escalate
  /// to the full composer; the quick-add line doesn't).
  var showsDetails: Bool = false
  let onToggle: () -> Void
  let onCommit: () -> Void
  let onCancel: () -> Void
  var onOpenDetails: (() -> Void)? = nil

  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(isDone: isDone, isToday: isToday, onToggle: onToggle)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(.septenaTaskTitle)
        .foregroundStyle(Theme.inkPrimary)
        .focused($focus, equals: focusValue)
        .submitLabel(.done)
        .onSubmit(onCommit)
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
    .background(selectionHighlight)
    .contentShape(Rectangle())
  }

  /// The standard row-selection wash, mirroring `CheckableRow.selectionHighlight`
  /// so an editing row reads exactly like a selected static one. iOS only —
  /// macOS draws its own native source-list selection from the List.
  @ViewBuilder
  private var selectionHighlight: some View {
    #if os(iOS)
    if isSelected {
      RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
        .fill(accent.opacity(0.18))
        .padding(.horizontal, max(0, rowHInset - 6))
    }
    #endif
  }
}
