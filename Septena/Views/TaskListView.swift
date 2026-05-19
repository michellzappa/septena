import SwiftUI
import SwiftData

// One screen per filter (Today / Inbox / Upcoming / Anytime / Logbook / Project / Area).
// Read-through cache: views render from SwiftData immediately, then refresh
// from the server in the background and fold the response back in.

struct TaskListView: View {
  @Environment(SeptenaClient.self) private var client
  /// Task write-path: applies optimistic SwiftData changes, enqueues
  /// outbox ops, and drains to FastAPI with retry. Every mutation in this
  /// view routes through here instead of `client.*` so the UI never
  /// blocks on the network and offline edits survive an app restart.
  @Environment(TaskMutator.self) private var mutator
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  #if os(iOS)
  /// Drives the Details surface choice: `.sheet` on iPhone compact,
  /// `.inspector` on iPad regular. `.inspector` adapts poorly to iPhone
  /// (renders as a blank near-fullscreen panel), so we route there
  /// only when the trailing column actually has room.
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

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

  /// Global sort applied when this list is showing a project or area — name
  /// or earliest-due first. Other filters (Today, Upcoming, etc.) have their
  /// own ordering that's part of the screen's meaning, so this is ignored
  /// outside `.project` / `.area`.
  @AppStorage(SettingsKey.taskSort) private var taskSortRaw: String = TaskSort.dateAdded.rawValue

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
  @State private var storageFilter: TaskFilter? = nil

  @State private var areas: [Area]
  @State private var projects: [Project]

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
    let ctx = LocalStore.shared.container.mainContext
    _areas = State(initialValue: LocalCache.areas(in: ctx))
    _projects = State(initialValue: LocalCache.projects(in: ctx))
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
    let ctx = LocalStore.shared.container.mainContext
    _areas = State(initialValue: LocalCache.areas(in: ctx))
    _projects = State(initialValue: LocalCache.projects(in: ctx))
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

  /// Keyboard cursor — which row is highlighted by arrow-key navigation.
  /// Separate from `editingTaskId`: a row can be selected without being open.
  @State private var selectedTaskId: String?

  // Inline new-task entry
  /// Tracks a task created via ⌘N (or the toolbar + button) so that
  /// committing/cancelling an empty title deletes it — the editor flow
  /// is the new-task flow, no leftover drafts.
  @State private var newlyCreatedTaskId: String? = nil

  // Inline title edit
  @State private var editingTaskId: String?
  @State private var editingTitle = ""
  @State private var editingNotes = ""

  // When picker. Use a single Identifiable item so the sheet's kind
  // is intrinsic to the presentation — avoids stale-state races where
  // tapping "When" could open the prior "Deadline" pane.
  @State private var whenSheet: WhenSheet?
  enum WhenKind { case due, scheduled }
  struct WhenSheet: Identifiable {
    let id: String   // composite of taskId + kind so reopening a kind re-presents cleanly
    let taskId: String
    let kind: WhenKind
    init(taskId: String, kind: WhenKind) {
      self.taskId = taskId
      self.kind = kind
      self.id = "\(taskId)|\(kind == .due ? "due" : "sched")"
    }
  }

  // Move picker
  @State private var showingMoveSheet = false
  @State private var moveTargetId: String?

  // Repeat picker
  @State private var showingRepeatSheet = false
  @State private var repeatTargetId: String?

  // Details pane is driven by its own state, NOT by `selectedTaskId`.
  // Selection is a keyboard-cursor highlight; the pane is opened only
  // by the (i) button on the inline editor. Decoupling them prevents
  // the pane from popping up as a side effect of tapping / arrowing.
  @State private var paneTaskId: String?
  private var detailsPaneIsOpen: Binding<Bool> {
    Binding(
      get: { paneTaskId != nil && currentTask(id: paneTaskId) != nil },
      set: { isOpen in if !isOpen { paneTaskId = nil } }
    )
  }

  /// True on iPad regular width and macOS — wide enough for a real
  /// trailing inspector column. False on iPhone compact, where we
  /// present Details as a `.sheet` instead.
  private var useInspectorForDetails: Bool {
    #if os(macOS)
    return true
    #else
    return horizontalSizeClass == .regular
    #endif
  }

  /// Shared content for the Details surface — used by both the
  /// `.sheet` (iPhone) and `.inspector` (iPad/Mac) presenters.
  @ViewBuilder
  private var detailsPaneContent: some View {
    if let id = paneTaskId, let target = currentTask(id: id) {
      TaskDetailsSheet(
        task: target,
        projectTitle: target.project.flatMap { pid in projects.first(where: { $0.id == pid })?.title },
        areaTitle:    target.area.flatMap    { aid in areas.first(where:    { $0.id == aid })?.title },
        onSaveTitleNotes: { newTitle, newNotes in
          applyTitleNotes(id: target.id, title: newTitle, notes: newNotes)
        },
        onOpenWhen: {
          whenSheet = WhenSheet(taskId: target.id, kind: .scheduled)
        },
        onOpenDeadline: {
          whenSheet = WhenSheet(taskId: target.id, kind: .due)
        },
        onOpenRepeat: {
          repeatTargetId = target.id; showingRepeatSheet = true
        },
        onOpenMove: {
          moveTargetId = target.id; showingMoveSheet = true
        },
        onDelete: {
          applyDelete(target.id)
          paneTaskId = nil
        },
        onDone: { paneTaskId = nil }
      )
      .id(id)
    }
  }

  // Local semantic sorter — populates a "→ Suggested" chip on Inbox rows.
  @State private var suggestionEngine = SuggestionEngine.shared

  // "Show N logged items" — recently completed tasks, scoped to the current
  // view. Loaded lazily on first expand and refreshed alongside the main list.
  @State private var loggedItemsStorage: [SeptenaTask] = []
  @State private var loggedFilter: TaskFilter? = nil
  @State private var showLogged = false

  private var loggedItems: [SeptenaTask] {
    loggedFilter == filter ? loggedItemsStorage : []
  }

  /// Where the "Show N logged items" footer is shown. Suppressed on the
  /// Logbook screen itself, and on Today / Inbox where historical completions
  /// would just be noise.
  private var showsLoggedSection: Bool {
    switch filter {
    case .today, .inbox, .logbook: return false
    default:                       return true
    }
  }

  // "You have N new to-dos" banner — compact start-of-day welcome that
  // surfaces tasks rolling in from scheduled-past or due-today. Dismissed
  // per-day via UserDefaults (local only); reappears the next morning.
  // Cross-device same-day dismissal sync is in the backlog.
  @State private var newTodosDismissed: Bool =
    UserDefaults.standard.string(forKey: "septena.newTodos.dismissedDate") == SeptenaDate.today

  var body: some View {
    List {
      // Title is owned by the parent when embedded (Project / Area detail).
      if !embedded {
        ScreenTitle(icon: titleIcon, iconTint: titleTint, title: filter.title)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
      } else {
        // Parent-supplied title + notes (Project / Area detail). Lives inside
        // the List so it scrolls away with the rows instead of pinning above.
        embeddedHeader()
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
      }

      // compact "You have N new to-dos" banner on Today.
      if filter == .today && !rolledInReview.isEmpty && !newTodosDismissed {
        newTodosBanner(count: rolledInReview.count)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
      }

      // Apple Reminders mirror — only on Inbox.
      if filter == .inbox {
        RemindersInboxSection(onImported: { Task { await load() } })
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
      }

      if loadedFilters.contains(filter) && visibleItems.isEmpty && review.isEmpty && doneToday.isEmpty && !isLoading {
        ContentUnavailableView(
          "Nothing here yet",
          systemImage: titleIcon,
          description: Text("Tap the + button to add a task.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
      }

      // ── OPEN block ──────────────────────────────────────────────
      if filter == .today {
        groupedOpenItems
      } else if filter == .unscheduled {
        ForEach(review) { task in row(task).asListRow() }
        groupedOpenItems
      } else if filter == .upcoming {
        ForEach(review) { task in row(task).asListRow() }
        groupedUpcomingItems
      } else {
        ForEach(review) { task in row(task).asListRow() }
        ForEach(visibleItems) { task in row(task).asListRow() }
      }

      // "Show N logged items" — collapsed by default. Skipped on Logbook
      // (that screen *is* the log) and on Today / Inbox where it's noise.
      if showsLoggedSection && !loggedItems.isEmpty {
        loggedToggleRow.asListRow()
        if showLogged {
          ForEach(sortedLoggedItems) { task in
            loggedRow(task).asListRow()
          }
        }
      }

      // Empty bottom area that catches a tap anywhere below the last row
      // and dismisses any open inline edit. The List itself swallows
      // background taps, so we have to opt into this surface as a real
      // row. InlineEditTaskRow's internal .onTapGesture swallow protects
      // taps inside the editor from reaching this surface.
      Color.clear
        .frame(minHeight: 240)
        .contentShape(Rectangle())
        .onTapGesture { dismissInlineEdit() }
        .asListRow()
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Theme.paperBackground)
    .scrollDismissesKeyboard(.interactively)
    // Per-list floating `+` removed — the app-global Liquid Glass bubble in
    // RootTabView is the single creation entry point. When the Tasks tab is
    // active that bubble flips `shouldStartCreating`, so this list still
    // gets its inline draft via the existing `.onChange` handler below.
    // Reminders-style floating glass pill above the soft keyboard.
    // Apple's pattern (WWDC25 session 323) is `.safeAreaInset` + the
    // iOS 26 `.glassEffect()` — not `ToolbarItemGroup(.keyboard)`,
    // which renders as a flat strip flush to the keyboard.
    #if os(iOS)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let id = editingTaskId, let task = currentTask(id: id) {
        editorKeyboardAccessory(for: task)
      }
    }
    #endif
    .modifier(KeyboardNavigationModifier(
      isInputMode: editingTaskId != nil,
      hasSelection: selectedTaskId != nil,
      onArrow: { delta, jump in
        if jump { jumpSelection(toFirst: delta < 0) }
        else    { moveSelection(delta) }
      },
      onReturn: openSelectedForEdit,
      onEscape: { selectedTaskId = nil },
      onSpace: toggleSelected,
      onNewTask: startDraft,
      onToggleToday: toggleTodayForSelected,
      onOpenWhen: openWhenForSelected,
      onOpenDeadline: openDeadlineForSelected,
      onDelete: deleteSelected,
      onClearSchedule: clearScheduleForSelected
    ))
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
    .sheet(item: $whenSheet) { sheet in
      switch sheet.kind {
      case .scheduled:
        DatePickerSheet(
          title: "When",
          initialDate: currentScheduled(for: sheet.taskId),
          setLabel: "Set Date",
          updateLabel: "Update Date",
          clearLabel: "No Date"
        ) { date in
          applyWhen(id: sheet.taskId, kind: .scheduled, date: date)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(Theme.cornerRadius)
      case .due:
        DatePickerSheet(
          title: "Deadline",
          initialDate: currentDeadline(for: sheet.taskId),
          setLabel: "Set Deadline",
          updateLabel: "Update Deadline",
          clearLabel: "Remove Deadline"
        ) { date in
          applyWhen(id: sheet.taskId, kind: .due, date: date)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(Theme.cornerRadius)
      }
    }
    .sheet(isPresented: $showingMoveSheet) {
      let target = currentTask(id: moveTargetId)
      MovePickerSheet(
        areas: areas,
        projects: projects,
        currentAreaId: target?.area,
        currentProjectId: target?.project
      ) { areaId, projectId in
        if let id = moveTargetId {
          applyMove(id: id, areaId: areaId, projectId: projectId)
        }
        moveTargetId = nil
      }
      .presentationDetents([.medium, .large])
      .presentationBackground(.thinMaterial)
      .presentationCornerRadius(Theme.cornerRadius)
    }
    .sheet(isPresented: $showingRepeatSheet) {
      RecurrencePickerSheet(initial: currentRecurrence(for: repeatTargetId)) { rule in
        if let id = repeatTargetId {
          applyRecurrence(id: id, rule: rule)
        }
        repeatTargetId = nil
      }
      .presentationDetents([.medium, .large])
      .presentationBackground(.thinMaterial)
      .presentationCornerRadius(Theme.cornerRadius)
    }
    // Details — sheet on iPhone compact (where `.inspector` renders
    // as a blank near-fullscreen panel), trailing inspector column on
    // iPad regular / macOS. Same content view either way.
    .modifier(TaskDetailsPresenter(
      isOpen: detailsPaneIsOpen,
      useInspector: useInspectorForDetails,
      content: { detailsPaneContent }
    ))
    // Re-load on every appearance so completed tasks (kept visible in-place
    // while the user is on the screen) drop off when they return.
    .onAppear { Task { await load() } }
    .refreshable { await load() }
    // Filter swaps reuse this same view (no .id(route) at the App level for
    // .filter cases). `items` is a computed property that already returns
    // the right data for `filter` synchronously, so we only need to clear
    // session-scoped state and re-trigger the network refresh.
    .onChange(of: filter) { _, _ in
      sessionDoneIds = []
      selectedTaskId = nil
      editingTaskId = nil
      paneTaskId = nil
      newlyCreatedTaskId = nil
      Task { await load() }
    }
    // Consume the global "start a new task" trigger from the sidebar
    // Menu or detail toolbar so the new-task flow stays inline (same
    // as ⌘N) instead of opening a modal sheet.
    .onChange(of: nav.shouldStartCreating) { _, fire in
      guard fire else { return }
      nav.shouldStartCreating = false
      startDraft()
    }
    .onAppear {
      if nav.shouldStartCreating {
        nav.shouldStartCreating = false
        startDraft()
      }
    }
  }

  /// Existing deadline for a target task, so the picker sheet can
  /// pre-fill its date and show "Update Deadline" / "Remove Deadline".
  private func currentDeadline(for id: String?) -> Date? {
    guard let id else { return nil }
    let pool = items + review + doneToday
    return pool.first(where: { $0.id == id })?.due.flatMap(SeptenaDate.parse)
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
    return (items + review + doneToday).first(where: { $0.id == id })
  }

  // MARK: - Keyboard navigation

  /// Flat ordered list of task IDs in the same order they're rendered.
  /// Drives ↑/↓ and ⌘↑/⌘↓ traversal.
  private var keyboardOrderedTaskIds: [String] {
    switch filter {
    case .today:
      return orderedFromGroupedOpen(pool: items + review)
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

  private func moveSelection(_ delta: Int) {
    let ids = keyboardOrderedTaskIds
    guard !ids.isEmpty else { return }
    if let current = selectedTaskId, let idx = ids.firstIndex(of: current) {
      let next = min(max(idx + delta, 0), ids.count - 1)
      selectedTaskId = ids[next]
    } else {
      selectedTaskId = delta > 0 ? ids.first : ids.last
    }
  }

  private func jumpSelection(toFirst: Bool) {
    let ids = keyboardOrderedTaskIds
    selectedTaskId = toFirst ? ids.first : ids.last
  }

  private func openSelectedForEdit() {
    guard let id = selectedTaskId,
          let t = currentTask(id: id) else { return }
    startEdit(t)
  }

  private func toggleSelected() {
    guard let id = selectedTaskId,
          let t = currentTask(id: id) else { return }
    toggle(t)
  }

  /// Resolve the row a keyboard shortcut should act on. Falls back to the
  /// first row in the list when nothing is explicitly selected — otherwise
  /// the first ⌘T after launch is a silent no-op, which reads as "broken".
  /// Sets `selectedTaskId` as a side effect so the selection pill follows.
  private func effectiveSelectionId() -> String? {
    if let id = selectedTaskId, currentTask(id: id) != nil { return id }
    guard let first = keyboardOrderedTaskIds.first else { return nil }
    selectedTaskId = first
    return first
  }

  /// ⌘T — flip the task's "today" flag. Same action as the context-menu
  /// entry, just keyboard-driven on the currently selected row.
  private func toggleTodayForSelected() {
    guard let id = effectiveSelectionId(),
          let t = currentTask(id: id) else { return }
    Haptics.tick()
    mutator.moveToToday(id: t.id, today: !t.today)
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
    whenSheet = WhenSheet(taskId: id, kind: .due)
  }

  /// ⌘⌫ — delete the focused row.
  private func deleteSelected() {
    guard let id = selectedTaskId, currentTask(id: id) != nil else { return }
    Haptics.warning()
    selectedTaskId = nil
    applyDelete(id)
  }

  /// ⌘. — clear schedule + today, sending the row back to Anytime.
  private func clearScheduleForSelected() {
    guard let id = selectedTaskId, currentTask(id: id) != nil else { return }
    applyWhen(id: id, kind: .scheduled, date: nil)
  }

  private func applyRecurrence(id: String, rule: Recurrence?) {
    Haptics.tick()
    mutator.setRecurrence(id: id, recurrence: rule)
    Task { await load() }
  }

  private func applyCancel(_ id: String) {
    Haptics.warning()
    // Optimistic flip so the user sees the row immediately switch to its
    // cancelled treatment (strikethrough + dim, like a done task). The
    // mutator durably enqueues the server-side cancel; if push ultimately
    // fails the next pull will surface server truth.
    flipStatus(id: id, to: .cancelled)
    sessionDoneIds.insert(id)
    mutator.cancel(id: id)
  }

  private func applyDelete(_ id: String) {
    Haptics.warning()
    // Remove from the visible buckets immediately — the row is filtered
    // from LocalCache via `pendingDeletion`, but the in-memory @State
    // arrays power the current screen and have to be poked separately.
    removeLocally(id: id)
    mutator.delete(id: id)
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

  /// Open the Details pane for a task. Only the (i) button on the
  /// inline editor calls this — tapping a row does NOT open the pane.
  /// Commits any in-flight inline draft first so the pane reads fresh
  /// state.
  private func openDetails(for task: SeptenaTask) {
    if editingTaskId != nil { commitEdit() }
    paneTaskId = task.id
  }

  private func applyMove(id: String, areaId: String?, projectId: String?) {
    Haptics.tick()
    if let task = currentTask(id: id) {
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
    Task { await load() }
  }

  // MARK: - Row

  @ViewBuilder
  private func row(_ task: SeptenaTask) -> some View {
    rowContent(task)
      // One shared highlight backplate covers both the closed-row and
      // inline-editor branches, so the accent tint stays put when the
      // row swaps state — no cross-fade needed.
      .background(rowBackground(for: task))
      // Spring drives the row's height change; we intentionally do
      // NOT use a transition that fades content in/out, since the
      // two branches share the same checkbox + title layout.
      .animation(Self.expandSpring, value: editingTaskId == task.id)
  }

  @ViewBuilder
  private func rowContent(_ task: SeptenaTask) -> some View {
    if editingTaskId == task.id {
      InlineEditTaskRow(
        title: $editingTitle,
        notes: $editingNotes,
        isDone: task.status == .done,
        isToday: task.today && filter != .today,
        // Tap-to-edit and ⌘N both want the keyboard up immediately —
        // any time the inline editor mounts, it should claim focus.
        autoFocus: true,
        onToggleDone: { toggle(task) },
        onCommit: { commitEdit() },
        onCancel: {
          let id = editingTaskId
          let title = editingTitle.trimmingCharacters(in: .whitespaces)
          let wasNew = (id != nil && id == newlyCreatedTaskId)
          withAnimation(Self.expandSpring) { editingTaskId = nil }
          newlyCreatedTaskId = nil
          // If the user hit Esc on a fresh ⌘N task with an empty title,
          // delete it so we don't leave a stub in the list.
          if wasNew && title.isEmpty, let id {
            mutator.delete(id: id)
            removeLocally(id: id)
          }
        },
        onOpenDetails: {
          // Commit current draft, then open the Details pane (info
          // button is the only path to the pane).
          commitEdit()
          paneTaskId = task.id
        }
      )
      // No cross-fade between display and edit modes — that fade was the
      // source of the "title + checkmark flicker on open". The checkbox /
      // title sit at the same position in both branches; an instant swap
      // is imperceptible. The expand spring on the parent still animates
      // the row's height as the editor pane unfolds below.
      .transition(.identity)
    } else {
      taskBody(task)
        .transition(.identity)
        // Right-click should make it visually clear which row the menu
        // refers to — flip the selection cursor onto this task before the
        // menu opens. iOS gets natural press feedback from long-press, so
        // the shim is a no-op there.
        .septenaOnRightClick { selectedTaskId = task.id }
        // Long-press (iOS) / right-click (macOS) context menu. Shares the
        // exact same Buttons as the trailing ellipsis Menu on the row so
        // both entry points stay in lockstep.
        .contextMenu { rowActionsMenu(for: task) }
    }
  }

  /// Single source of truth for per-row actions. Used by both the trailing
  /// ellipsis `Menu` on the row and the long-press / right-click
  /// `.contextMenu` — keeping one builder means the two entry points can
  /// never drift apart.
  @ViewBuilder
  private func rowActionsMenu(for task: SeptenaTask) -> some View {
    // Smart-sort suggestions — used to render as a separate trailing chip
    // on Inbox rows, but folded in here so all per-row actions live in one
    // place. SwiftUI `Section` inside a `Menu` is the standard way to group
    // related items with a header.
    if filter == .inbox,
       task.status == .open,
       let top = suggestionEngine.topSuggestion(for: task.id) {
      let ranked = suggestionEngine.suggestions[task.id] ?? [top]
      Section("Suggested") {
        ForEach(Array(ranked.enumerated()), id: \.element) { _, s in
          Button {
            applySuggestion(task: task, suggestion: s)
          } label: {
            Label("Move to \(s.title)",
                  systemImage: s.kind == .area ? "tray" : "folder")
          }
        }
      }
      Divider()
    }
    // Hide "Move to Today" whenever the row is already surfacing on the
    // Today view — either via the today flag or because its scheduled/due
    // date pulled it in. Only show "Remove from Today" when the today flag
    // is actually set (that's the only state the toggle can undo).
    if task.today {
      Button {
        Haptics.tick()
        mutator.moveToToday(id: task.id, today: false)
        Task { await load() }
      } label: {
        Label("Remove from Today", systemImage: "sun.min")
      }
    } else if filter != .today {
      Button {
        Haptics.tick()
        mutator.moveToToday(id: task.id, today: true)
        Task { await load() }
      } label: {
        Label("Move to Today", systemImage: "sun.max.fill")
      }
    }
    Button {
      whenSheet = WhenSheet(taskId: task.id, kind: .scheduled)
    } label: {
      Label("When…", systemImage: "calendar")
    }
    Button {
      whenSheet = WhenSheet(taskId: task.id, kind: .due)
    } label: {
      Label("Deadline…", systemImage: "flag")
    }
    Button {
      moveTargetId = task.id
      showingMoveSheet = true
    } label: {
      Label("Move…", systemImage: "folder")
    }
    Button {
      repeatTargetId = task.id; showingRepeatSheet = true
    } label: {
      Label("Repeat…", systemImage: "repeat")
    }
    Divider()
    Button {
      applyCancel(task.id)
    } label: {
      // Labelled "Cancel Task" (not "Cancel") so iOS doesn't treat this as
      // a dismiss button — a bare "Cancel" inside a menu has shown up as
      // no-op in past iOS builds.
      Label("Cancel Task", systemImage: "xmark.circle")
    }
    Divider()
    Button(role: .destructive) {
      Haptics.warning()
      applyDelete(task.id)
    } label: {
      Label("Delete", systemImage: "trash")
    }
  }

  @ViewBuilder
  private func taskBody(_ task: SeptenaTask) -> some View {
    // `.firstTextBaseline` lines the checkbox up with the title's text
    // baseline; the alignment guide on the box anchors it by visual center
    // so the box reads as centered with the title cap-height, not bottom-
    // anchored. For multi-line rows the title still wins the alignment.
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      // Promoted-to-Today tasks wear a sun-in-circle glyph as their
      // checkbox. Suppressed on the Today filter itself — the page
      // header already says 'Today', so every checkbox carrying a sun
      // would be noise.
      TaskCheckbox(
        isDone: task.status == .done,
        isToday: task.today && filter != .today
      ) { toggle(task) }
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      VStack(alignment: .leading, spacing: 4) {
        // Cancelled tasks share the visual language of done tasks
        // (strikethrough + dimmed) so the user gets immediate feedback
        // when they cancel — even though the server filters cancelled
        // out of non-logbook views on the next reload.
        let isInactive = task.status == .done || task.status == .cancelled
        Text(task.title)
          .font(.septenaTaskTitle)
          .foregroundStyle(isInactive ? Theme.inkSecondary : Theme.inkPrimary)
          .strikethrough(isInactive)
          .opacity(isInactive ? 0.5 : 1)
          .lineLimit(1)
          .truncationMode(.tail)
          .multilineTextAlignment(.leading)

        metaLine(task)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      // Notes glyph on the right when the task has any — kept out of the
      // meta line so it doesn't crowd the project/area/date chips below.
      if !(task.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Image(systemName: "text.alignleft")
          .font(.system(size: 12))
          .foregroundStyle(Theme.inkSecondary)
      }
      // Trailing date / status — one clear signal per row. See
      // `trailingDate` for the full rule set.
      trailingDate(task)
    }
    .padding(.horizontal, Theme.hPadding)
    // Explicit vertical padding (not frame-min-height centering) so the
    // title's Y is anchored to a fixed offset from the row top.
    // TextField's internal metrics differ slightly from Text on iOS,
    // which made the centered-content approach shift the title on edit
    // open. Equal padding top + bottom on closed rows; the editor uses
    // the same top padding.
    .padding(.vertical, Theme.rowVPadding)
    // Hit area covers the FULL padded row (checkbox + title column +
    // padding above/below). Inner controls — TaskCheckbox button, action
    // icons — still consume their own taps via gesture priority, so they
    // toggle / open without selecting first.
    .contentShape(Rectangle())
    // Tap = inline edit (Reminders-style). Title focuses, keyboard
    // accessory chips appear. The (i) button in the editor is the
    // ONLY path that opens the Details pane — we deliberately do NOT
    // set `selectedTaskId` here, because that drives the inspector
    // binding and would render a blank pane behind the editor.
    .onTapGesture { startEdit(task) }
  }

  /// Highlight backplate. Two states:
  ///   • editing — stronger accent fill so the active row reads as
  ///     "open" while the inline editor is up and the keyboard accessory
  ///     is acting on this task.
  ///   • keyboard cursor — light accent tint (matches the sidebar's
  ///     selection pill) when arrowed-to but not actively edited.
  /// Animation is scoped to the fill so we don't re-layout every visible
  /// row on each selection change (the old macOS click-lag source).
  @ViewBuilder
  private func rowBackground(for task: SeptenaTask) -> some View {
    let isEditing = editingTaskId == task.id
    let isCursor  = selectedTaskId == task.id && !isEditing
    let fill: Color = {
      if isEditing { return theme.accent.opacity(0.18) }
      if isCursor  { return theme.accent.opacity(0.10) }
      return .clear
    }()
    RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
      .fill(fill)
      .padding(.horizontal, Theme.hPadding - 6)
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
    Task { await load() }
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

  /// A task with a due date that's today or in the past — surfaces a flag.
  private func isOverdue(_ task: SeptenaTask) -> Bool {
    guard let due = task.due.flatMap(SeptenaDate.parse) else { return false }
    let today = Calendar.current.startOfDay(for: Date())
    return Calendar.current.startOfDay(for: due) <= today
  }

  /// Trailing date / status indicator. Red only ever means **deadline
  /// missed** — a `scheduled` date in the past is not "overdue", it's just
  /// the reason the row is on Today. Rules:
  ///   • `due ≤ today` → red bold date text (`Today` / `Yesterday` / `May 14`).
  ///   • `due > today` → gray flag + date (marked, not urgent).
  ///   • No `due`, scheduled future, not on Today → muted calendar + date.
  ///   • No `due`, scheduled past → nothing. The row's presence on Today
  ///     *is* the signal; a red label here would conflate "missed deadline"
  ///     with "showed up because of a planning date."
  @ViewBuilder
  private func trailingDate(_ task: SeptenaTask) -> some View {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    if let due = task.due.flatMap(SeptenaDate.parse) {
      let dueDay = cal.startOfDay(for: due)
      if dueDay <= today {
        Text(cal.isDateInToday(due) ? "Today" : shortDate(due))
          .font(.septenaMeta.weight(.semibold))
          .foregroundStyle(Theme.overdueRed)
          .padding(.top, 3)
      } else {
        HStack(spacing: 4) {
          Image(systemName: "flag.fill").font(.system(size: 12))
          Text(shortDate(due)).font(.septenaMeta)
        }
        .foregroundStyle(Theme.inkSecondary)
        .padding(.top, 3)
      }
    } else if filter != .today, let scheduled = task.scheduled.flatMap(SeptenaDate.parse) {
      HStack(spacing: 4) {
        Image(systemName: "calendar").font(.system(size: 11))
        Text(shortDate(scheduled)).font(.septenaMeta)
      }
      .foregroundStyle(Theme.inkSecondary)
      .padding(.top, 3)
    }
  }

  /// Sub-line beneath the title: `★ today · # project · 📅 May 20 · 🚩`.
  /// Two date roles: `scheduled` is residence (calendar chip with date);
  /// `due` is a warning flag (icon-only when scheduled is also present;
  /// flag + days-left when due is the only date signal). Red tint when
  /// due ≤ today, neutral otherwise.
  @ViewBuilder
  private func metaLine(_ task: SeptenaTask) -> some View {
    // Suppress project/area chips when the surrounding context already shows
    // them: on a project page (project + area), an area page (area), and on
    // Unscheduled (which renders project/area cluster headers above each
    // group). Upcoming groups by date, so chips stay there.
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
    let projectTitle = suppressProject
      ? nil
      : task.project.flatMap { pid in projects.first(where: { $0.id == pid })?.title }
    let areaTitle = suppressArea
      ? nil
      : task.area.flatMap { aid in areas.first(where: { $0.id == aid })?.title }

    // Dates live in the trailing region (see trailingDate); only project/area
    // chips render under the title now.
    let hasAny = projectTitle != nil || areaTitle != nil
    if hasAny {
      HStack(spacing: 10) {
        if let title = projectTitle {
          metaChip(icon: "number", text: title)
        } else if let title = areaTitle {
          metaChip(icon: "folder", text: title)
        }
      }
    }
  }

  private func shortDate(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f.string(from: d)
  }

  @ViewBuilder
  private func metaChip(icon: String, text: String) -> some View {
    // Icon param kept for call-site compatibility but no longer rendered —
    // project / area context is clear from text alone, and the leading glyph
    // was visual noise. Plain SF Sans proportional digits.
    Text(text).font(.septenaMeta)
      .foregroundStyle(Theme.inkSecondary)
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

  /// Renders `items` clustered by their project (preferred) or area, with
  /// inline headers that push the corresponding sidebar destination.
  @ViewBuilder
  private var groupedOpenItems: some View {
    // Today: fold "scheduled earlier" items into the same cluster grouping so
    // a due-today task lands under its project/area like any other.
    let pool = (filter == .today) ? items + review : items
    let byProject = Dictionary(grouping: pool.filter { $0.project != nil },
                               by: { $0.project! })
    let byArea = Dictionary(grouping: pool.filter { $0.project == nil && $0.area != nil },
                            by: { $0.area! })
    let loose = pool.filter { $0.project == nil && $0.area == nil }

    // 1. Loose first (no header) so uncategorized tasks aren't buried.
    ForEach(loose) { task in row(task).asListRow() }

    // 2. Areas in sidebar order: direct-area tasks, then each project's tasks.
    ForEach(areas) { area in
      let areaTasks = byArea[area.id] ?? []
      if !areaTasks.isEmpty {
        groupHeader(icon: "square.stack.3d.up.fill", title: area.title) {
          nav.path = [.area(area)]
        }
        .asListRow()
        ForEach(areaTasks) { task in row(task).asListRow() }
      }
      ForEach(projects.filter { $0.area == area.id }) { project in
        if let tasks = byProject[project.id], !tasks.isEmpty {
          groupHeader(icon: nil, title: project.title) {
            nav.path = [.project(project)]
          }
          .asListRow()
          ForEach(tasks) { task in row(task).asListRow() }
        }
      }
    }

    // 3. Top-level projects (no area).
    ForEach(projects.filter { $0.area == nil }) { project in
      if let tasks = byProject[project.id], !tasks.isEmpty {
        groupHeader(icon: nil, title: project.title) {
          nav.path = [.project(project)]
        }
        .asListRow()
        ForEach(tasks) { task in row(task).asListRow() }
      }
    }
  }

  /// Filters applied client-side before rendering:
  /// - `excludeProjectedTasks` keeps the Area page focused on loose work.
  /// - On Project / Area pages, completed tasks only appear if the user
  ///   completed them during this view's session.
  private var visibleItems: [SeptenaTask] {
    var result = items
    if excludeProjectedTasks { result = result.filter { $0.project == nil } }
    if hideHistoricalDone {
      result = result.filter { $0.status != .done || sessionDoneIds.contains($0.id) }
    }
    // Apply the global sort only on project/area pages — those are the
    // surfaces with no inherent ordering of their own.
    switch filter {
    case .project, .area:
      let sort = TaskSort(rawValue: taskSortRaw) ?? .dateAdded
      result.sort(by: taskSortComparator(sort))
    default:
      break
    }
    return result
  }

  /// Total ordering for `visibleItems`. For due-date sort, tasks without a
  /// `due` sink to the bottom; ties (and the no-due bucket) fall back to
  /// case-insensitive title so the order is stable across reloads.
  private func taskSortComparator(_ sort: TaskSort) -> (SeptenaTask, SeptenaTask) -> Bool {
    switch sort {
    case .alphabetical:
      return { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    case .dueDate:
      return { a, b in
        switch (a.due, b.due) {
        case let (la?, lb?) where la != lb: return la < lb
        case (_?, nil):                     return true
        case (nil, _?):                     return false
        default:
          return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
      }
    case .dateAdded:
      // Oldest first → newest sinks to the bottom (matches the "newest at
      // the end of the list" feel of most task apps). Tasks missing
      // `created` (legacy rows) fall through to title for stability.
      return { a, b in
        switch (a.created, b.created) {
        case let (la?, lb?) where la != lb: return la < lb
        case (_?, nil):                     return true
        case (nil, _?):                     return false
        default:
          return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
      }
    }
  }

  private var hideHistoricalDone: Bool {
    switch filter {
    case .project, .area: return true
    case .today:
      // Settings → General → "Show completed tasks in Today" governs this.
      // Default true (matches the long-standing "completions linger" feel);
      // turning it off drops completed rows on the next reload, keeping only
      // ones the user just checked off this session.
      let show = UserDefaults.standard.object(forKey: SettingsKey.todayShowCompleted) as? Bool ?? true
      return !show
    default:              return false
    }
  }

  @ViewBuilder
  private func groupHeader(icon: String?, title: String, onTap: (() -> Void)? = nil) -> some View {
    // Same icon column width and same icon→text gap as task rows so
    // every icon sits at one X and every text starts at one X.
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.iconTextGap) {
        if icon == "square.stack.3d.up.fill" {
          // Area dot is intentionally bumped past task-row icon size — it's a
          // section header, not an inline glyph, and the larger circle reads as
          // a chapter marker.
          AreaIcon(tint: Theme.inkSecondary, diameter: 21, lineWidth: 1.5)
            .frame(width: Theme.checkboxTap, alignment: .center)
        } else if icon != nil {
          Image(systemName: icon!)
            .font(.system(size: 16))
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
            .padding(.leading, -6)
        } else {
          Text(title)
            .font(.system(size: Theme.groupHeaderFontSize, weight: .semibold))
            .foregroundStyle(Theme.inkPrimary)
        }
        Spacer()
      }
      .padding(.horizontal, Theme.hPadding)
      // ~2 lines of whitespace above each project/area cluster header so
      // groups visually break apart in mixed list views (Unscheduled, Today,
      // Upcoming). Without this gap, a header reads as the next row of the
      // previous group instead of the start of a new one.
      .padding(.top, 32)
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

  // MARK: - Upcoming grouping (by date)

  /// Buckets upcoming items by their scheduled (or due) date, in the order
  /// dates first appear in `items`. Date headers are non-tappable.
  @ViewBuilder
  private var groupedUpcomingItems: some View {
    let buckets = upcomingBuckets()
    ForEach(buckets, id: \.key) { bucket in
      groupHeader(icon: "calendar", title: bucket.label).asListRow()
      ForEach(bucket.tasks) { task in row(task).asListRow() }
    }
  }

  private struct DateBucket {
    let key: String        // YYYY-MM-DD
    let label: String
    let tasks: [SeptenaTask]
  }

  private func upcomingBuckets() -> [DateBucket] {
    var order: [String] = []
    var grouped: [String: [SeptenaTask]] = [:]
    for task in items {
      let key = task.scheduled ?? task.due ?? ""
      guard !key.isEmpty else { continue }
      if grouped[key] == nil { order.append(key) }
      grouped[key, default: []].append(task)
    }
    return order.map { key in
      DateBucket(key: key, label: dateHeaderLabel(key), tasks: grouped[key] ?? [])
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

  #if os(iOS)
  /// Reminders-style floating glass pill that appears above the soft
  /// keyboard while the inline editor is open. Built with the iOS 26
  /// `.glassEffect()` + `.safeAreaInset` pattern — not
  /// `ToolbarItemGroup(.keyboard)`, which renders as a flat strip.
  @ViewBuilder
  private func editorKeyboardAccessory(for task: SeptenaTask) -> some View {
    HStack(spacing: 28) {
      accessoryChip(systemName: "calendar") {
        whenSheet = WhenSheet(taskId: task.id, kind: .scheduled)
      }
      accessoryChip(systemName: task.today ? "sun.max.fill" : "sun.max",
                    tint: task.today ? .orange : nil) {
        Haptics.tick()
        mutator.moveToToday(id: task.id, today: !task.today)
        Task { await load() }
      }
      accessoryChip(systemName: "number") {
        moveTargetId = task.id; showingMoveSheet = true
      }
      accessoryChip(systemName: "flag") {
        whenSheet = WhenSheet(taskId: task.id, kind: .due)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .glassEffect(.regular.interactive(), in: .capsule)
    .padding(.horizontal, 14)
    .padding(.bottom, 8)
  }

  @ViewBuilder
  private func accessoryChip(systemName: String, tint: Color? = nil,
                             action: @escaping () -> Void) -> some View {
    Button {
      Haptics.pick()
      // Commit any in-flight title/notes draft so the picker reads
      // fresh state.
      if editingTaskId != nil { commitEdit() }
      action()
    } label: {
      Image(systemName: systemName)
        .font(.system(size: 20, weight: .regular))
        .foregroundStyle(tint ?? Theme.inkPrimary)
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
  #endif

  // MARK: - Edit

  /// Spring used for the row-expand / row-collapse transition. Snappy enough
  /// to feel responsive on tap, soft enough to read as an expand rather than
  /// a snap. Same shape on insert and dismiss for symmetry.
  private static let expandSpring: Animation = .spring(response: 0.32, dampingFraction: 0.84)

  private func startEdit(_ task: SeptenaTask) {
    // If switching from another task, persist the prior draft inline
    // (no nested withAnimation) so the swap is ONE animation transaction:
    // editingTaskId stays on the prior id until our withAnimation block
    // atomically flips title + notes + id together. The previous version
    // called commitEdit() — which has its own withAnimation setting
    // editingTaskId = nil — and that intermediate frame let the prior
    // row's view mode flash into existence between the two transactions.
    if let priorId = editingTaskId, priorId != task.id {
      let priorTitle = editingTitle.trimmingCharacters(in: .whitespaces)
      let wasNew = (newlyCreatedTaskId == priorId)
      if priorTitle.isEmpty {
        if wasNew {
          mutator.delete(id: priorId)
          removeLocally(id: priorId)
        }
      } else {
        mutator.update(id: priorId, title: priorTitle, notes: editingNotes)
        Task { await load() }
      }
      newlyCreatedTaskId = nil
    }
    withAnimation(Self.expandSpring) {
      editingTitle = task.title
      editingNotes = task.notes ?? ""
      editingTaskId = task.id
    }
  }

  private func commitEdit() {
    guard let id = editingTaskId else { return }
    let t = editingTitle.trimmingCharacters(in: .whitespaces)
    let wasNew = (newlyCreatedTaskId == id)
    withAnimation(Self.expandSpring) {
      editingTaskId = nil
    }
    newlyCreatedTaskId = nil
    if t.isEmpty {
      // Empty title: delete the task if it was a fresh ⌘N draft;
      // otherwise leave it alone (existing tasks shouldn't vanish just
      // because the user blurred while the field was empty).
      if wasNew {
        mutator.delete(id: id)
        removeLocally(id: id)
      }
      return
    }
    mutator.update(id: id, title: t, notes: editingNotes)
    Task { await load() }
  }

  /// Tap-outside dismiss — commits any active inline edit AND clears the
  /// keyboard-cursor selection so the accent pill goes away when the
  /// user clicks empty space.
  private func dismissInlineEdit() {
    if editingTaskId != nil { commitEdit() }
    selectedTaskId = nil
  }

  // MARK: - Create

  private func startDraft() {
    // Create the new task server-side immediately, then open it in the
    // standard inline editor. Empty-title commit/cancel deletes the
    // task so the user isn't punished for hitting ⌘N speculatively.
    var scheduled: Date?
    var project: String?
    var area: String?
    var today = false

    let cal = Calendar.current
    let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))

    switch filter {
    case .today:            today = true
    case .upcoming:         scheduled = tomorrow
    case .project(let pid): project = pid
    case .area(let aid):    area = aid
    default:                break
    }

    // Optimistic: TaskMutator inserts a SwiftData row with a client UUID
    // and queues the server push. Returns the new task immediately so
    // the inline editor opens without a network round-trip.
    //   - empty title → delete (handled in commitEdit / onCancel)
    //   - non-empty → server's placeholder gets replaced via update
    let created = mutator.create(
      title: "New To-Do", area: area, project: project,
      scheduled: scheduled, due: nil, today: today, notes: nil
    )
    insertLocally(created)
    editingTitle = ""
    editingNotes = ""
    newlyCreatedTaskId = created.id
    withAnimation(Self.expandSpring) { editingTaskId = created.id }
  }

  // MARK: - When picker apply

  private func applyWhen(id: String, kind: WhenKind, date: Date?) {
    Haptics.tick()
    switch kind {
    case .due:
      mutator.setDue(id: id, date: date)
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
        }
      } else {
        mutator.schedule(id: id, date: nil)
        mutator.moveToToday(id: id, today: false)
      }
    }
    Task { await load() }
  }

  // MARK: - Toggle done

  /// Toggle the checkbox optimistically — flip status in-place so the row
  /// shows checked without disappearing. Server filters out completed tasks
  /// from inbox/today/upcoming/unscheduled views, so they're gone the next
  /// time the screen reloads (which happens when you leave & return).
  private func toggle(_ task: SeptenaTask) {
    let newStatus: TaskStatus = task.status == .done ? .open : .done
    if newStatus == .done { Haptics.success() } else { Haptics.tap() }

    flipStatus(id: task.id, to: newStatus)
    if newStatus == .done { sessionDoneIds.insert(task.id) }
    else                  { sessionDoneIds.remove(task.id) }

    if newStatus == .done {
      mutator.complete(id: task.id)
    } else {
      mutator.uncomplete(id: task.id)
    }
  }

  /// Mutate the matching task in any of the visible buckets so the row
  /// re-renders with the new status without a server round-trip.
  private func flipStatus(id: String, to newStatus: TaskStatus) {
    func apply(_ list: inout [SeptenaTask]) {
      if let i = list.firstIndex(where: { $0.id == id }) {
        list[i].status = newStatus
      }
    }
    apply(&items); apply(&review); apply(&doneToday)
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

  /// Inverse of `removeLocally` — paired with `TaskMutator.create(...)`.
  /// Inserts the freshly-minted task at the top of `items` so the inline
  /// editor mounts on a visible row.
  private func insertLocally(_ task: SeptenaTask) {
    items.insert(task, at: 0)
  }

  // MARK: - Logged items section

  /// Scope the logbook (which is always global on the server) to the area /
  /// project the user is currently looking at. On top-level filters we keep
  /// everything.
  private func filterLogged(_ all: [SeptenaTask]) -> [SeptenaTask] {
    switch filter {
    case .project(let pid):
      return all.filter { $0.project == pid }
    case .area(let aid):
      let projectIdsInArea = Set(projects.filter { $0.area == aid }.map(\.id))
      return all.filter { task in
        if task.area == aid { return true }
        if let pid = task.project, projectIdsInArea.contains(pid) { return true }
        return false
      }
    default:
      return all
    }
  }

  private var sortedLoggedItems: [SeptenaTask] {
    loggedItems.sorted { (a, b) in
      (a.completedAt ?? "") > (b.completedAt ?? "")
    }
  }

  @ViewBuilder
  private var loggedToggleRow: some View {
    Button {
      Haptics.tick()
      withAnimation(.easeInOut(duration: 0.2)) { showLogged.toggle() }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: showLogged ? "chevron.down" : "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.iconMuted)
        Text(showLogged
             ? "Hide logged items"
             : "Show \(loggedItems.count) logged item\(loggedItems.count == 1 ? "" : "s")")
          .font(.septenaMeta.weight(.semibold))
          .foregroundStyle(Theme.inkSecondary)
        Spacer()
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.top, 24)
      .padding(.bottom, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func loggedRow(_ task: SeptenaTask) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(isDone: true, isToday: false) { toggle(task) }
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      if let when = task.completedAt.flatMap(SeptenaDate.parse) {
        Text(shortDate(when))
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
          .frame(minWidth: 44, alignment: .leading)
      }

      Text(task.title)
        .font(.septenaTaskTitle)
        .foregroundStyle(Theme.inkSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding)
  }

  // MARK: - Load

  private func load() async {
    // Cache was already painted in init(); only show the loading state when
    // we have literally nothing to render (first ever launch, cache miss).
    if items.isEmpty { isLoading = true }
    defer { isLoading = false }
    do {
      let listView = filter.serverView
      var area: String?
      var project: String?
      switch filter {
      case .area(let aid): area = aid
      case .project(let pid): project = pid
      default: break
      }
      let resp = try await client.list(view: listView, area: area, project: project)
      items = resp.items
      review = resp.review ?? []
      doneToday = resp.done ?? []
      loadedFilters.insert(filter)

      async let p = client.projects()
      async let a = client.areas()
      projects = (try? await p) ?? []
      areas = (try? await a) ?? []

      // Refresh the embedding-backed suggestion chips for Inbox rows. The
      // engine needs every assigned task — each project / area's semantic
      // identity is the centroid of its assigned tasks. Open tasks come
      // from the local mirror; done tasks need an explicit logbook pull
      // (the server's "all" view returns open-only, so weeks of completed
      // work would otherwise be invisible to the model).
      if filter == .inbox {
        var allTasks = LocalCache.allTasks(in: modelContext)
        if let logbook = try? await client.list(view: "logbook", days: 365) {
          let known = Set(allTasks.map(\.id))
          allTasks.append(contentsOf: logbook.items.filter { !known.contains($0.id) })
        }
        suggestionEngine.refresh(inbox: resp.items,
                                 allTasks: allTasks,
                                 projects: projects,
                                 areas: areas)
      }

      // 2. Fold the fresh server response back into SwiftData so the next
      //    cold load renders from cache. Scope tells the syncer how to
      //    prune deleted rows without nuking out-of-scope tasks.
      let syncer = Syncer(client: client, context: modelContext)
      let scope: Syncer.TaskScope = {
        switch filter {
        case .area(let aid): return .area(aid)
        case .project(let pid): return .project(pid)
        default: return .filter(filter)
        }
      }()
      syncer.applyTasks(resp.items + (resp.review ?? []) + (resp.done ?? []),
                        scope: scope)
      syncer.applyAreas(areas)
      syncer.applyProjects(projects)

      // Recently completed, scoped to the current view. Server's logbook
      // endpoint ignores area/project, so we filter client-side.
      if showsLoggedSection {
        if let logbook = try? await client.list(view: "logbook", days: 30) {
          loggedItemsStorage = filterLogged(logbook.items)
          loggedFilter = filter
        }
      }

      // Refresh dismissed state — banner reappears next day automatically.
      if filter == .today {
        let last = UserDefaults.standard.string(forKey: "septena.newTodos.dismissedDate")
        newTodosDismissed = (last == SeptenaDate.today)
      }
    } catch is CancellationError {
      // Pull-to-refresh interruption or task cancellation — no user error.
      return
    } catch let urlError as URLError where urlError.code == .cancelled {
      // URLSession cancelled mid-request (refresh re-triggered). Silent.
      return
    } catch {
      SeptenaLog.error("load failed", error)
      errorMessage = error.localizedDescription
    }
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
      .font(.system(size: 14))
      .foregroundStyle(.primary)
      Spacer()
      Button {
        Haptics.tick()
        UserDefaults.standard.set(SeptenaDate.today, forKey: "septena.newTodos.dismissedDate")
        withAnimation(.easeOut(duration: 0.2)) { newTodosDismissed = true }
      } label: {
        Text("OK")
          .font(.system(size: 13, weight: .semibold))
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
    case .inbox: return "tray"
    case .upcoming: return "calendar"
    case .unscheduled: return "rectangle.stack"
    case .logbook: return "checkmark.circle"
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
          .font(.system(size: Theme.groupHeaderFontSize, weight: .semibold))
          .foregroundStyle(Theme.inkPrimary)
        if hasChevron {
          Image(systemName: "chevron.right")
            .font(.system(size: Theme.groupHeaderFontSize - 6, weight: .semibold))
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

/// Routes the Details surface to `.inspector` (iPad regular / macOS)
/// or `.sheet` (iPhone compact). `.inspector` adapts poorly to compact
/// width — renders as a near-fullscreen blank panel — so we present
/// a real bottom sheet there instead.
private struct TaskDetailsPresenter<C: View>: ViewModifier {
  let isOpen: Binding<Bool>
  let useInspector: Bool
  @ViewBuilder let content: () -> C

  func body(content base: Content) -> some View {
    if useInspector {
      base.inspector(isPresented: isOpen) {
        content()
          .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
      }
    } else {
      base.sheet(isPresented: isOpen) {
        content()
          .presentationDetents([.medium, .large])
          .presentationBackground(.thinMaterial)
          .presentationCornerRadius(Theme.cornerRadius)
      }
    }
  }
}

/// Bundles ⌘N, ⌘T, ↑/↓, ⌘↑/⌘↓, Enter, Esc, Space into one modifier so the
/// TaskListView body stays small enough for the SwiftUI type-checker.
/// While a row is being edited, arrow/return/space/escape are forwarded to
/// the native TextField; ⌘N and ⌘T remain globally active.
private struct KeyboardNavigationModifier: ViewModifier {
  /// True when a row is being edited OR a new-task draft is open. While in
  /// input mode, all row-navigation keys forward to the active TextField.
  let isInputMode: Bool
  let hasSelection: Bool
  /// `delta` is -1/+1; `jump` true → move to first/last instead of stepping.
  let onArrow: (_ delta: Int, _ jump: Bool) -> Void
  let onReturn: () -> Void
  let onEscape: () -> Void
  let onSpace: () -> Void
  let onNewTask: () -> Void
  let onToggleToday: () -> Void
  let onOpenWhen: () -> Void
  let onOpenDeadline: () -> Void
  let onDelete: () -> Void
  let onClearSchedule: () -> Void

  /// Auto-focus the list on appear so the arrow keys / space / enter work
  /// immediately, without the user having to click into the content first.
  @FocusState private var listFocused: Bool

  func body(content: Content) -> some View {
    content
      // Publish row actions to the menu bar via FocusedValues. The
      // "Task" CommandMenu in App.swift owns the keyboard shortcuts
      // (⌘N, ⌘T, ⌘S, ⌘⇧D, ⌘⌫, ⌘.) and shows them under a real menu,
      // which also surfaces them in the iPad keyboard HUD.
      .focusedSceneValue(\.taskActions, TaskActions(
        newTask: onNewTask,
        toggleToday: onToggleToday,
        openWhen: onOpenWhen,
        openDeadline: onOpenDeadline,
        toggleComplete: hasSelection ? onSpace : nil,
        delete: hasSelection ? onDelete : nil,
        clearSchedule: hasSelection ? onClearSchedule : nil
      ))
      .focusable()
      .focused($listFocused)
      // Suppress the macOS blue focus ring around the whole list — the
      // selection pill on the focused row is indicator enough.
      .focusEffectDisabled()
      .onAppear { listFocused = true }
      .onKeyPress(keys: [.upArrow]) { press in
        guard !isInputMode else { return .ignored }
        onArrow(-1, press.modifiers.contains(.command))
        return .handled
      }
      .onKeyPress(keys: [.downArrow]) { press in
        guard !isInputMode else { return .ignored }
        onArrow(1, press.modifiers.contains(.command))
        return .handled
      }
      .onKeyPress(.return) {
        guard !isInputMode, hasSelection else { return .ignored }
        onReturn()
        return .handled
      }
      .onKeyPress(.escape) {
        guard !isInputMode, hasSelection else { return .ignored }
        onEscape()
        return .handled
      }
      .onKeyPress(.space) {
        guard !isInputMode, hasSelection else { return .ignored }
        onSpace()
        return .handled
      }
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
// way it did inside the old LazyVStack. Used in `body` directly and inside
// the grouping helpers.

extension View {
  func asListRow() -> some View {
    self
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
  }
}
