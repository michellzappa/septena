import SwiftUI

// One screen per filter (Today / Inbox / Upcoming / Anytime / Logbook / Project / Area).
// Server does the filtering — we just render whatever /api/tasks/list returns.

struct TaskListView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme

  let filter: TaskFilter
  /// True when this view is laid out *inside* another detail screen
  /// (Project / Area detail). Suppresses the screen title and top-bar chrome
  /// so the parent owns identity. Pushed as its own screen → leave `false`.
  var embedded: Bool = false
  /// When set on an Area page, hides tasks that belong to a project so the
  /// area list shows only area-direct work (projects live in the parent view).
  var excludeProjectedTasks: Bool = false

  @State private var items: [EngageTask] = []
  @State private var review: [EngageTask] = []
  @State private var doneToday: [EngageTask] = []
  @State private var areas: [Area] = []
  @State private var projects: [Project] = []

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
  @State private var isCreating = false
  @State private var draftTitle = ""
  @State private var draftNotes = ""

  // Inline title edit
  @State private var editingTaskId: String?
  @State private var editingTitle = ""
  @State private var editingNotes = ""

  // When picker
  @State private var showingWhenSheet = false
  @State private var whenTargetId: String?
  @State private var whenKind: WhenKind = .due
  enum WhenKind { case due, scheduled }

  // Move picker
  @State private var showingMoveSheet = false
  @State private var moveTargetId: String?

  // Repeat picker
  @State private var showingRepeatSheet = false
  @State private var repeatTargetId: String?

  // "You have N new to-dos" banner — compact start-of-day welcome that
  // surfaces tasks rolling in from scheduled-past or due-today. Dismissed
  // per-day via UserDefaults; reappears the next morning.
  @State private var newTodosDismissed: Bool = false

  var body: some View {
    List {
      // Title is owned by the parent when embedded (Project / Area detail).
      if !embedded {
        ScreenTitle(icon: titleIcon, iconTint: titleTint, title: filter.title)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
      }

      // compact "You have N new to-dos" banner on Today.
      if filter == .today && !review.isEmpty && !newTodosDismissed {
        newTodosBanner(count: review.count)
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

      // New-task entry appears at the TOP of the list.
      if isCreating {
        let suppressDest: Bool = {
          switch filter { case .project, .area: return true; default: return false }
        }()
        InlineNewTaskRow(
          title: $draftTitle, notes: $draftNotes,
          defaultWhen: filter.title,
          defaultWhenIcon: titleIcon,
          defaultWhenTint: titleTint,
          showDestination: !suppressDest,
          onCommit: { commitDraft() },
          onCancel: { cancelDraft() }
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
      }

      if visibleItems.isEmpty && review.isEmpty && doneToday.isEmpty && !isCreating && !isLoading {
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
        ForEach(review) { task in row(task, reviewable: true).asListRow() }
        groupedOpenItems
      } else if filter == .upcoming {
        ForEach(review) { task in row(task, reviewable: true).asListRow() }
        groupedUpcomingItems
      } else {
        ForEach(review) { task in row(task, reviewable: true).asListRow() }
        ForEach(visibleItems) { task in row(task).asListRow() }
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
    .modifier(KeyboardNavigationModifier(
      isInputMode: editingTaskId != nil || isCreating,
      hasSelection: selectedTaskId != nil,
      onArrow: { delta, jump in
        if jump { jumpSelection(toFirst: delta < 0) }
        else    { moveSelection(delta) }
      },
      onReturn: openSelectedForEdit,
      onEscape: { selectedTaskId = nil },
      onSpace: toggleSelected,
      onNewTask: startDraft,
      onToggleToday: toggleTodayForSelected
    ))
    // Only attach top-level nav chrome on the standalone tab versions.
    // Embedded uses (Project / Area detail wraps) inherit chrome from parent
    // — adding modifiers here would create duplicate back buttons.
    .modifier(TopLevelChromeModifier(showChrome: !embedded, nav: nav))
    .alert("Error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .sheet(isPresented: $showingWhenSheet) {
      switch whenKind {
      case .scheduled:
        WhenPickerSheet(
          onPick: { date in
            if let id = whenTargetId { applyWhen(id: id, date: date) }
            whenTargetId = nil
          },
          onSomeday: {
            if let id = whenTargetId { applySomeday(id) }
            whenTargetId = nil
          }
        )
        .presentationDetents([.medium])
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(Theme.cornerRadius)
      case .due:
        DeadlinePickerSheet(
          initialDate: currentDeadline(for: whenTargetId)
        ) { date in
          if let id = whenTargetId { applyWhen(id: id, date: date) }
          whenTargetId = nil
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
    // Re-load on every appearance so completed tasks (kept visible in-place
    // while the user is on the screen) drop off when they return.
    .onAppear { Task { await load() } }
    .refreshable { await load() }
  }

  /// Existing deadline for a target task, so DeadlinePickerSheet can
  /// pre-fill its date picker and show "Update Deadline" / "No Deadline".
  private func currentDeadline(for id: String?) -> Date? {
    guard let id else { return nil }
    let pool = items + review + doneToday
    return pool.first(where: { $0.id == id })?.due.flatMap(SeptenaDate.parse)
  }

  /// Existing recurrence rule for a target task, so RecurrencePickerSheet
  /// can pre-fill its controls and show "Update Repeat" / "Don't Repeat".
  private func currentRecurrence(for id: String?) -> Recurrence? {
    guard let id else { return nil }
    let pool = items + review + doneToday
    return pool.first(where: { $0.id == id })?.recurrence
  }

  private func currentTask(id: String?) -> EngageTask? {
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
  private func orderedFromGroupedOpen(pool: [EngageTask]) -> [String] {
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

  /// ⌘T — flip the task's "today" flag. Same action as the context-menu
  /// entry, just keyboard-driven on the currently selected row.
  private func toggleTodayForSelected() {
    guard let id = selectedTaskId,
          let t = currentTask(id: id) else { return }
    Haptics.tick()
    Task {
      try? await client.moveToToday(id: t.id, today: !t.today)
      await load()
    }
  }

  private func applyRecurrence(id: String, rule: Recurrence?) {
    Haptics.tick()
    Task {
      do {
        _ = try await client.setRecurrence(id: id, recurrence: rule)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func applySomeday(_ id: String) {
    Haptics.tick()
    Task {
      do { try await client.someday(id: id); await load() }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func applyCancel(_ id: String) {
    Haptics.warning()
    // Optimistic flip so the user sees the row immediately switch to its
    // cancelled treatment (strikethrough + dim, like a done task). Server
    // filters cancelled out of every non-logbook view, so without this the
    // row would just vanish silently on reload — easy to read as "nothing
    // happened". Linger on screen until the user navigates / reloads, in
    // line with how completed tasks behave.
    let prior = currentTask(id: id)?.status
    flipStatus(id: id, to: .cancelled)
    sessionDoneIds.insert(id)
    Task {
      do {
        try await client.cancel(id: id)
      } catch {
        if let prior {
          flipStatus(id: id, to: prior)
          sessionDoneIds.remove(id)
        }
        errorMessage = error.localizedDescription
      }
    }
  }

  private func applyDelete(_ id: String) {
    Haptics.warning()
    Task {
      do { try await client.delete(id: id); await load() }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func applyMove(id: String, areaId: String?, projectId: String?) {
    Haptics.tick()
    Task {
      do {
        // Project takes precedence — Septena derives area from project on save.
        if projectId != nil {
          _ = try await client.moveToProject(id: id, project: projectId)
        } else {
          _ = try await client.moveToArea(id: id, area: areaId)
          _ = try await client.moveToProject(id: id, project: nil)
        }
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - Row

  @ViewBuilder
  private func row(_ task: EngageTask, reviewable: Bool = false) -> some View {
    rowContent(task, reviewable: reviewable)
      // Explicit value-driven animation so both directions of the
      // taskBody ↔ editor swap animate, regardless of whether the
      // mutating call site wrapped in withAnimation. The transition
      // modifier on each branch supplies the opacity blend; this drives
      // the timing curve and ensures List sees the row's height change
      // as part of the spring.
      .animation(Self.expandSpring, value: editingTaskId == task.id)
  }

  @ViewBuilder
  private func rowContent(_ task: EngageTask, reviewable: Bool = false) -> some View {
    if editingTaskId == task.id {
      InlineEditTaskRow(
        task: task,
        title: $editingTitle,
        notes: $editingNotes,
        isDone: task.status == .done,
        projectTitle: task.project.flatMap { pid in projects.first(where: { $0.id == pid })?.title },
        areaTitle:    task.area.flatMap    { aid in areas.first(where:    { $0.id == aid })?.title },
        onToggleDone: { toggle(task) },
        onCommit: { commitEdit() },
        onCancel: {
          withAnimation(Self.expandSpring) { editingTaskId = nil }
        },
        onSchedule: {
          whenTargetId = task.id; whenKind = .scheduled; showingWhenSheet = true
        },
        onDeadline: {
          whenTargetId = task.id; whenKind = .due; showingWhenSheet = true
        },
        onMove: {
          moveTargetId = task.id; showingMoveSheet = true
        },
        onRepeat: {
          repeatTargetId = task.id; showingRepeatSheet = true
        }
      )
      // Pure opacity transitions — scale-from-top was unreliable inside
      // List on the insertion side (the editor would mount full-size
      // without fading). Opacity blends predictably both directions;
      // List handles the row's own height change with its native
      // animation.
      .transition(.opacity)
    } else {
      taskBody(task, reviewable: reviewable)
        .transition(.opacity)
        // Right-click should make it visually clear which row the menu
        // refers to — flip the selection cursor onto this task before the
        // menu opens. iOS gets natural press feedback from long-press, so
        // the shim is a no-op there.
        .septenaOnRightClick { selectedTaskId = task.id }
        // Long-press menu — temporary stand-in for swipe-to-reveal (which is
        // List-only in SwiftUI). Each item fires a haptic when selected.
        .contextMenu {
          Button {
            Haptics.tick()
            Task { try? await client.moveToToday(id: task.id, today: !task.today); await load() }
          } label: {
            Label(task.today ? "Remove from Today" : "Move to Today",
                  systemImage: task.today ? "sun.min" : "sun.max.fill")
          }
          Button {
            whenTargetId = task.id; whenKind = .scheduled; showingWhenSheet = true
          } label: {
            Label("When…", systemImage: "calendar")
          }
          Button {
            whenTargetId = task.id; whenKind = .due; showingWhenSheet = true
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
            // Labelled "Cancel Task" (not "Cancel") so iOS doesn't treat
            // this as a dismiss button — a bare "Cancel" inside a menu has
            // shown up as no-op in past iOS builds.
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
    }
  }

  @ViewBuilder
  private func taskBody(_ task: EngageTask, reviewable: Bool) -> some View {
    // `.firstTextBaseline` lines the checkbox up with the title's text
    // baseline; the alignment guide on the box anchors it by visual center
    // so the box reads as centered with the title cap-height, not bottom-
    // anchored. For multi-line rows the title still wins the alignment.
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      // Promoted-to-Today tasks wear a sun-in-circle glyph as their
      // checkbox (instead of a plain circle). Renders on every filter
      // including Today itself, so the today signal is visible wherever
      // the task appears.
      TaskCheckbox(
        isDone: task.status == .done,
        isToday: task.today
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
      // Trailing date label — compact. Always on the right, never a
      // pill under the title:
      //   • Due (deadline) wins: flag + label, red when overdue/today.
      //   • Otherwise scheduled (when present and we're not on Today, where
      //     the screen itself is "today"): calendar + label, muted.
      trailingDate(task)
    }
    .padding(.horizontal, Theme.hPadding)
    // Explicit vertical padding (not frame-min-height centering) so the
    // title's Y is anchored to a fixed offset from the row top.
    // TextField's internal metrics differ slightly from Text on iOS,
    // which made the centered-content approach shift the title on edit
    // open. Equal padding top + bottom on closed rows; the editor uses
    // the same top padding.
    .padding(.vertical, Theme.rowTapHeight >= 44 ? 11 : 5)
    .background(rowBackground(for: task))
    // Hit area covers the FULL padded row (checkbox + title column +
    // padding above/below). Inner controls — TaskCheckbox button, action
    // icons — still consume their own taps via gesture priority, so they
    // toggle / open without selecting first.
    .contentShape(Rectangle())
    #if os(macOS)
    // macOS: one click selects, a second click on the already-selected row
    // opens the editor. Single .onTapGesture only — attaching a count:2
    // sibling forces SwiftUI to wait the system double-click interval
    // (~300ms) on every single click before firing.
    .onTapGesture {
      if selectedTaskId == task.id {
        startEdit(task)
      } else {
        selectedTaskId = task.id
      }
    }
    #else
    .onTapGesture {
      selectedTaskId = task.id
      startEdit(task)
    }
    #endif
  }

  /// Single highlight rule: light accent-tint pill (matches the sidebar's
  /// selection pill) when the row is the keyboard cursor AND it's not
  /// currently being edited (the editor card has its own chrome).
  /// Animation is scoped to the fill only — wrapping the whole row body in
  /// `.animation(value: selectedTaskId)` caused every visible row to re-layout
  /// for 150ms on each selection change, which was the macOS click-lag source.
  @ViewBuilder
  private func rowBackground(for task: EngageTask) -> some View {
    let isHighlighted = selectedTaskId == task.id && editingTaskId != task.id
    RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
      .fill(isHighlighted ? theme.accent.opacity(0.15) : Color.clear)
      .padding(.horizontal, Theme.hPadding - 6)
  }

  /// A task with a due date that's today or in the past — surfaces a flag.
  private func isOverdue(_ task: EngageTask) -> Bool {
    guard let due = task.due.flatMap(SeptenaDate.parse) else { return false }
    let today = Calendar.current.startOfDay(for: Date())
    return Calendar.current.startOfDay(for: due) <= today
  }

  /// Trailing date indicator: flag for a deadline (due) or calendar for a
  /// scheduled "when". Lives on the right side of the row so dates never
  /// crowd the title or meta line.
  @ViewBuilder
  private func trailingDate(_ task: EngageTask) -> some View {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    if let due = task.due.flatMap(SeptenaDate.parse) {
      let dueSoon = cal.startOfDay(for: due) <= today
      HStack(spacing: 4) {
        Image(systemName: "flag.fill").font(.system(size: 12))
        Text(shortDate(due)).font(.septenaMeta)
      }
      .foregroundStyle(dueSoon ? Theme.overdueRed : Theme.inkSecondary)
      .padding(.top, 3)
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
  private func metaLine(_ task: EngageTask) -> some View {
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
  private var visibleItems: [EngageTask] {
    var result = items
    if excludeProjectedTasks { result = result.filter { $0.project == nil } }
    if hideHistoricalDone {
      result = result.filter { $0.status != .done || sessionDoneIds.contains($0.id) }
    }
    return result
  }

  private var hideHistoricalDone: Bool {
    switch filter {
    case .project, .area: return true
    default:              return false
    }
  }

  @ViewBuilder
  private func groupHeader(icon: String?, title: String, onTap: (() -> Void)? = nil) -> some View {
    let body = HStack(spacing: 10) {
      if icon == "square.stack.3d.up.fill" {
        // Area glyph — two nested circles, mirrors SidebarAreaRow.
        AreaIcon(diameter: 14, lineWidth: 1.5)
          .frame(width: 20, alignment: .center)
      } else if icon != nil {
        // Other named system icons (date buckets etc.)
        Image(systemName: icon!)
          .font(.system(size: 16))
          .foregroundStyle(Theme.iconMuted)
          .frame(width: 20, alignment: .center)
      } else {
        // Project pie glyph — same component as the sidebar / detail page
        // so the look-and-feel is identical.
        ProjectProgressIcon(progress: 0.25, tint: Theme.iconMuted, diameter: 14)
          .frame(width: 20, alignment: .center)
      }
      Text(title)
        .font(.system(size: Theme.groupHeaderFontSize, weight: .semibold))
        .foregroundStyle(Theme.inkPrimary)
      if onTap != nil {
        Image(systemName: "chevron.right")
          .font(.system(size: Theme.groupHeaderFontSize - 6, weight: .semibold))
          .foregroundStyle(Theme.iconMuted)
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
    .contentShape(Rectangle())

    if let onTap {
      Button(action: onTap) { body }.buttonStyle(.plain)
    } else {
      body
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
    let tasks: [EngageTask]
  }

  private func upcomingBuckets() -> [DateBucket] {
    var order: [String] = []
    var grouped: [String: [EngageTask]] = [:]
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

  // (Floating Magic Plus removed — new-task creation lives in the macOS
  // toolbar ("+" / ⇧⌘N) and in the global ⌘N shortcut. Reintroduce when
  // we add user-controlled list ordering / a drag-to-reorder model.)

  // MARK: - Edit

  /// Spring used for the row-expand / row-collapse transition. Snappy enough
  /// to feel responsive on tap, soft enough to read as an expand rather than
  /// a snap. Same shape on insert and dismiss for symmetry.
  private static let expandSpring: Animation = .spring(response: 0.32, dampingFraction: 0.84)

  private func startEdit(_ task: EngageTask) {
    if editingTaskId != nil && editingTaskId != task.id { commitEdit() }
    // All three state changes inside the same animation transaction so
    // the conditional-content swap (taskBody → InlineEditTaskRow) sees
    // a coherent spring on insertion. Setting title/notes outside the
    // withAnimation block was triggering an instant re-render before
    // editingTaskId flipped, which made the open-side transition land
    // without an active transaction.
    withAnimation(Self.expandSpring) {
      editingTitle = task.title
      editingNotes = task.notes ?? ""
      editingTaskId = task.id
    }
  }

  private func commitEdit() {
    guard let id = editingTaskId else { return }
    let t = editingTitle.trimmingCharacters(in: .whitespaces)
    withAnimation(Self.expandSpring) {
      editingTaskId = nil
    }
    guard !t.isEmpty else { return }
    Task {
      _ = try? await client.update(id: id, title: t, notes: editingNotes)
      await load()
    }
  }

  /// Tap-outside dismiss — commits any active inline edit, closes the
  /// new-task draft, AND clears the keyboard-cursor selection so the
  /// accent pill goes away when the user clicks empty space.
  private func dismissInlineEdit() {
    if editingTaskId != nil {
      commitEdit()
    }
    if isCreating {
      if draftTitle.trimmingCharacters(in: .whitespaces).isEmpty {
        cancelDraft()
      } else {
        commitDraft()
      }
    }
    selectedTaskId = nil
  }

  // MARK: - Create

  private func startDraft() {
    draftTitle = ""; draftNotes = ""
    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isCreating = true }
  }

  private func cancelDraft() {
    withAnimation(.easeOut(duration: 0.2)) { isCreating = false }
    draftTitle = ""; draftNotes = ""
  }

  private func commitDraft() {
    let title = draftTitle.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { cancelDraft(); return }
    let notes = draftNotes.isEmpty ? nil : draftNotes

    var due: Date?
    var scheduled: Date?
    var project: String?
    var area: String?
    var today = false
    var status: TaskStatus = .open

    let cal = Calendar.current
    let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))

    switch filter {
    case .today:
      today = true
    case .upcoming:
      // Default to tomorrow so the new task actually appears in the list.
      // Without a future scheduled or due date, the server's upcoming view
      // would never surface it.
      scheduled = tomorrow
    case .project(let pid):
      project = pid
    case .area(let aid):
      area = aid
    case .unscheduled:
      status = .someday
    default:
      break
    }

    if let parsed = EngageDateParser.parse(title) { due = parsed }

    Task {
      do {
        _ = try await client.create(
          title: title, area: area, project: project,
          scheduled: scheduled, due: due, today: today, notes: notes, status: status
        )
        draftTitle = ""; draftNotes = ""
        isCreating = false
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - When picker apply

  private func applyWhen(id: String, date: Date?) {
    Haptics.tick()
    Task {
      do {
        switch whenKind {
        case .due:
          try await client.setDue(id: id, date: date)
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
              try await client.schedule(id: id, date: nil)
              try await client.moveToToday(id: id, today: true)
            } else {
              try await client.moveToToday(id: id, today: false)
              try await client.schedule(id: id, date: d)
            }
          } else {
            try await client.schedule(id: id, date: nil)
            try await client.moveToToday(id: id, today: false)
          }
        }
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - Toggle done

  /// Toggle the checkbox optimistically — flip status in-place so the row
  /// shows checked without disappearing. Server filters out completed tasks
  /// from inbox/today/upcoming/unscheduled views, so they're gone the next
  /// time the screen reloads (which happens when you leave & return).
  private func toggle(_ task: EngageTask) {
    let newStatus: TaskStatus = task.status == .done ? .open : .done
    if newStatus == .done { Haptics.success() } else { Haptics.tap() }

    flipStatus(id: task.id, to: newStatus)
    if newStatus == .done { sessionDoneIds.insert(task.id) }
    else                  { sessionDoneIds.remove(task.id) }

    Task {
      do {
        if newStatus == .done {
          try await client.complete(id: task.id)
        } else {
          try await client.uncomplete(id: task.id)
        }
      } catch {
        // Revert the optimistic flip and surface the error.
        flipStatus(id: task.id, to: task.status)
        if task.status == .done { sessionDoneIds.insert(task.id) }
        else                    { sessionDoneIds.remove(task.id) }
        errorMessage = error.localizedDescription
      }
    }
  }

  /// Mutate the matching task in any of the visible buckets so the row
  /// re-renders with the new status without a server round-trip.
  private func flipStatus(id: String, to newStatus: TaskStatus) {
    func apply(_ list: inout [EngageTask]) {
      if let i = list.firstIndex(where: { $0.id == id }) {
        list[i].status = newStatus
      }
    }
    apply(&items); apply(&review); apply(&doneToday)
  }

  // MARK: - Load

  private func load() async {
    isLoading = true
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

      async let p = client.projects()
      async let a = client.areas()
      projects = (try? await p) ?? []
      areas = (try? await a) ?? []

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

/// Encapsulates the standalone-tab nav chrome so we can opt out cleanly
/// when TaskListView is embedded inside a detail page.
private struct TopLevelChromeModifier: ViewModifier {
  let showChrome: Bool
  let nav: NavigationState

  func body(content: Content) -> some View {
    if showChrome {
      content
        .septenaInlineTitle()
        // Toolbar glass pills float over the detail content on macOS 26
        // (Reminders-style top chrome). `.primaryAction` slot puts them on
        // the right side; system applies the new Liquid Glass styling.
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button {
              nav.showingQuickEntry = true
            } label: {
              Image(systemName: "plus")
            }
            .help("Quick Entry")
            .keyboardShortcut("n", modifiers: [.command, .shift])
          }
        }
    } else {
      content
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

  /// Auto-focus the list on appear so the arrow keys / space / enter work
  /// immediately, without the user having to click into the content first.
  @FocusState private var listFocused: Bool

  func body(content: Content) -> some View {
    content
      .background(newTaskHotkey)
      .background(toggleTodayHotkey)
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

  /// Hidden ⌘T — flips the focused row's "today" flag. No-op without a
  /// selected row, so it's safe to leave globally bound.
  private var toggleTodayHotkey: some View {
    Button("Toggle Today") { onToggleToday() }
      .keyboardShortcut("t", modifiers: .command)
      .opacity(0)
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
  }

  /// Hidden ⌘N button — surfaces "New Task" without a visible toolbar item.
  /// iPad picks it up on hardware keyboards too.
  private var newTaskHotkey: some View {
    Button("New Task") { onNewTask() }
      .keyboardShortcut("n", modifiers: .command)
      .opacity(0)
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
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
