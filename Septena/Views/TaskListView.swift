import SwiftUI

// One screen per filter (Today / Inbox / Upcoming / Anytime / Logbook / Project / Area).
// Server does the filtering — we just render whatever /api/tasks/list returns.

struct TaskListView: View {
  @EnvironmentObject var client: SeptenaClient
  @EnvironmentObject var nav: NavigationState
  @EnvironmentObject var theme: SectionTheme

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
  /// rows visible until the user navigates away (matches Things 3).
  @State private var sessionDoneIds: Set<String> = []

  /// Briefly tints a row's background on tap before it transitions into edit
  /// mode — mirrors the sidebar pulse so taps feel consistent.
  @State private var pulsedTaskId: String?
  @State private var taskPulseToken = 0

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

  var body: some View {
    ZStack(alignment: .bottom) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {

          // Title is owned by the parent when embedded (Project / Area detail).
          if !embedded {
            ScreenTitle(icon: titleIcon, iconTint: titleTint, title: filter.title)
          }

          // New-task entry appears at the TOP of the list — Things behavior.
          // Captures sit above your existing work so the entry point is
          // glanceable from the title.
          if isCreating {
            InlineNewTaskRow(
              title: $draftTitle, notes: $draftNotes,
              defaultWhen: filter.title,
              defaultWhenIcon: titleIcon,
              defaultWhenTint: titleTint,
              onCommit: { commitDraft() },
              onCancel: { cancelDraft() }
            )
            Hairline()
          }

          if visibleItems.isEmpty && review.isEmpty && doneToday.isEmpty && !isCreating && !isLoading {
            Text("Nothing here yet")
              .font(.septenaMeta)
              .foregroundStyle(.secondary)
              .padding(.horizontal, Theme.hPadding)
              .padding(.top, 40)
          }

          // ── OPEN block ──────────────────────────────────────────────
          // Tasks come first (most actionable), then chores / habits / supps.
          // Unscheduled / Upcoming both group items with inline headers —
          // by project/area or by date respectively.
          // "Scheduled Earlier" — render inline at the top so overdue items
          // are surfaced first, no separate header (they're part of Today).
          ForEach(review) { task in row(task, reviewable: true); Hairline() }

          if filter == .unscheduled {
            groupedOpenItems
          } else if filter == .upcoming {
            groupedUpcomingItems
          } else {
            ForEach(visibleItems) { task in row(task); Hairline() }
          }
          // Done tasks no longer surface on Today / Inbox / etc. — see Logbook
          // for the archive. Per-session optimistic toggles still render in
          // place (strikethrough) until the next reload.

          Spacer(minLength: 140)
        }
        // Tap any empty area of the scroll content (title row, gaps between
        // rows, bottom spacer) to commit the active inline edit. Buttons and
        // text fields inside rows consume their own taps first.
        .contentShape(Rectangle())
        .onTapGesture { dismissInlineEdit() }
      }
      .background(Theme.paperBackground)
      // Dragging the scroll dismisses the keyboard interactively; combined
      // with the editing card's onChange(focused) commit, this turns a quick
      // pull into a blur.
      .scrollDismissesKeyboard(.interactively)

      trailingFloater
    }
    // ZStack-level tap target so the FAB margin, safe-area gaps, and any
    // surface the inner ScrollView doesn't claim also commit the edit.
    // Buttons and the editing card consume their taps first, so this only
    // fires on truly empty space.
    .contentShape(Rectangle())
    .onTapGesture { dismissInlineEdit() }
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
      case .due:
        DeadlinePickerSheet(
          initialDate: currentDeadline(for: whenTargetId)
        ) { date in
          if let id = whenTargetId { applyWhen(id: id, date: date) }
          whenTargetId = nil
        }
        .presentationDetents([.medium, .large])
      }
    }
    .sheet(isPresented: $showingMoveSheet) {
      MovePickerSheet(areas: areas, projects: projects) { areaId, projectId in
        if let id = moveTargetId {
          applyMove(id: id, areaId: areaId, projectId: projectId)
        }
        moveTargetId = nil
      }
      .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showingRepeatSheet) {
      RecurrencePickerSheet(initial: currentRecurrence(for: repeatTargetId)) { rule in
        if let id = repeatTargetId {
          applyRecurrence(id: id, rule: rule)
        }
        repeatTargetId = nil
      }
      .presentationDetents([.medium, .large])
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
    Task {
      do { try await client.cancel(id: id); await load() }
      catch { errorMessage = error.localizedDescription }
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
        onCancel: { editingTaskId = nil },
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
    } else {
      taskBody(task, reviewable: reviewable)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          Button(role: .destructive) { applyDelete(task.id) } label: {
            Label("Delete", systemImage: "trash")
          }
          Button { applyCancel(task.id) } label: {
            Label("Cancel", systemImage: "xmark.circle")
          }
          .tint(Theme.inkSecondary)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
          Button {
            Haptics.tick()
            Task { try? await client.moveToToday(id: task.id, today: !task.today); await load() }
          } label: {
            Label(task.today ? "Demote" : "Today", systemImage: "star")
          }
          .tint(theme.accent)
        }
    }
  }

  @ViewBuilder
  private func taskBody(_ task: EngageTask, reviewable: Bool) -> some View {
    HStack(alignment: .top, spacing: 12) {
      ThingsCheckbox(isDone: task.status == .done) { toggle(task) }
        .padding(.top, 2)

      Button {
        pulseTask(task.id)
        startEdit(task)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Promoted to Today: small accent star inline with the title, sized
            // ~checkbox so it reads as a flag beside the task, not chrome.
            if task.today && filter != .today {
              Image(systemName: "star.fill")
                .font(.system(size: 14))
                .foregroundStyle(theme.accent)
            }
            Text(task.title)
              .font(.septenaTaskTitle)
              .foregroundStyle(task.status == .done ? Theme.inkSecondary : Theme.inkPrimary)
              .strikethrough(task.status == .done)
              .opacity(task.status == .done ? 0.5 : 1)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }

          metaLine(task)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if reviewable {
        Button {
          Haptics.tick()
          Task {
            try? await client.moveToToday(id: task.id, today: true)
            await load()
          }
        } label: {
          Image(systemName: "star.fill")
            .foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 12)
    .frame(minHeight: Theme.rowHeight)
    .background(pulsedTaskId == task.id ? theme.accent.opacity(0.14) : Color.clear)
    .animation(.easeOut(duration: 0.25), value: pulsedTaskId)
  }

  /// Briefly flash a row's background so tap registers visually before the
  /// inline edit card takes over.
  private func pulseTask(_ id: String) {
    pulsedTaskId = id
    taskPulseToken &+= 1
    let token = taskPulseToken
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      if taskPulseToken == token { pulsedTaskId = nil }
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
      case .project, .unscheduled: return true
      default:                     return false
      }
    }()
    let suppressArea: Bool = {
      switch filter {
      case .project, .area, .unscheduled: return true
      default:                            return false
      }
    }()
    let projectTitle = suppressProject
      ? nil
      : task.project.flatMap { pid in projects.first(where: { $0.id == pid })?.title }
    let areaTitle = suppressArea
      ? nil
      : task.area.flatMap { aid in areas.first(where: { $0.id == aid })?.title }
    let due          = task.due.flatMap(SeptenaDate.parse)
    let scheduled    = task.scheduled.flatMap(SeptenaDate.parse)
    let hasNotes     = !(task.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    let hasAny = hasNotes || projectTitle != nil || areaTitle != nil || due != nil || scheduled != nil
    if hasAny {
      HStack(spacing: 10) {
        if hasNotes {
          Image(systemName: "text.alignleft")
            .font(.system(size: 10))
            .foregroundStyle(Theme.inkSecondary)
        }
        if let title = projectTitle {
          metaChip(icon: "number", text: title)
        } else if let title = areaTitle {
          metaChip(icon: "folder", text: title)
        }
        if let scheduled {
          metaChip(icon: "calendar", text: shortDate(scheduled))
        }
        if let due {
          deadlineFlag(for: due, hasScheduled: scheduled != nil)
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
    HStack(spacing: 3) {
      Image(systemName: icon).font(.system(size: 10))
      Text(text).font(.septenaMeta)
    }
    .foregroundStyle(Theme.inkSecondary)
  }

  /// Deadline indicator. Red when overdue or due today; secondary otherwise.
  /// Icon-only when `scheduled` is also present (the calendar chip already
  /// shows a date — flag just signals "deadline exists"). Includes
  /// days-left text when due is the only date signal on the row.
  @ViewBuilder
  private func deadlineFlag(for date: Date, hasScheduled: Bool) -> some View {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let target = cal.startOfDay(for: date)
    let days = cal.dateComponents([.day], from: today, to: target).day ?? 0
    let tint: Color = days <= 0 ? Theme.overdueRed : Theme.inkSecondary
    HStack(spacing: 3) {
      Image(systemName: "flag.fill").font(.system(size: 10))
      if !hasScheduled {
        Text(days < 0 ? "\(-days)d over" : days == 0 ? "today" : days == 1 ? "1d left" : "\(days)d left")
          .font(.septenaMeta)
      }
    }
    .foregroundStyle(tint)
  }

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
    let byProject = Dictionary(grouping: items.filter { $0.project != nil },
                               by: { $0.project! })
    let byArea = Dictionary(grouping: items.filter { $0.project == nil && $0.area != nil },
                            by: { $0.area! })
    let loose = items.filter { $0.project == nil && $0.area == nil }

    // 1. Loose first (no header) so uncategorized tasks aren't buried.
    ForEach(loose) { task in row(task); Hairline() }

    // 2. Areas in sidebar order: direct-area tasks, then each project's tasks.
    ForEach(areas) { area in
      let areaTasks = byArea[area.id] ?? []
      if !areaTasks.isEmpty {
        groupHeader(icon: "square.stack.3d.up.fill", title: area.title) {
          nav.path.append(.area(area))
        }
        ForEach(areaTasks) { task in row(task); Hairline() }
      }
      ForEach(projects.filter { $0.area == area.id }) { project in
        if let tasks = byProject[project.id], !tasks.isEmpty {
          groupHeader(icon: nil, title: project.title) {
            nav.path.append(.project(project))
          }
          ForEach(tasks) { task in row(task); Hairline() }
        }
      }
    }

    // 3. Top-level projects (no area).
    ForEach(projects.filter { $0.area == nil }) { project in
      if let tasks = byProject[project.id], !tasks.isEmpty {
        groupHeader(icon: nil, title: project.title) {
          nav.path.append(.project(project))
        }
        ForEach(tasks) { task in row(task); Hairline() }
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
      if let icon {
        Image(systemName: icon)
          .font(.system(size: 16))
          .foregroundStyle(Theme.iconMuted)
          .frame(width: 20, alignment: .center)
      } else {
        // Project pie glyph, mirrors SidebarProjectRow.
        ZStack {
          Circle().stroke(Theme.iconMuted, lineWidth: 1.5)
            .frame(width: 14, height: 14)
          Circle().trim(from: 0, to: 0.25)
            .stroke(Theme.iconMuted, lineWidth: 5)
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, alignment: .center)
      }
      Text(title)
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(Theme.inkPrimary)
      if onTap != nil {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.iconMuted)
      }
      Spacer()
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.top, 18)
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
      groupHeader(icon: "calendar", title: bucket.label)
      ForEach(bucket.tasks) { task in row(task); Hairline() }
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

  // MARK: - Floater

  @ViewBuilder
  private var trailingFloater: some View {
    // Hide the FAB while creating — commit is by tap-outside or return key.
    if !isCreating {
      HStack {
        Spacer()
        MagicPlusButton { startDraft() }
      }
      .padding(.trailing, Theme.hPadding)
      .padding(.bottom, 20)
    }
  }

  // MARK: - Edit

  private func startEdit(_ task: EngageTask) {
    if editingTaskId != nil && editingTaskId != task.id { commitEdit() }
    editingTaskId = task.id
    editingTitle = task.title
    editingNotes = task.notes ?? ""
  }

  private func commitEdit() {
    guard let id = editingTaskId else { return }
    let t = editingTitle.trimmingCharacters(in: .whitespaces)
    editingTaskId = nil
    guard !t.isEmpty else { return }
    Task {
      _ = try? await client.update(id: id, title: t, notes: editingNotes)
      await load()
    }
  }

  /// Tap-outside dismiss — commits any active inline edit AND any in-flight
  /// new-task draft. Called from the empty-area tap on the scroll content.
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
        case .due: try await client.setDue(id: id, date: date)
        case .scheduled: try await client.schedule(id: id, date: date)
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

  // MARK: - Title chrome

  private var titleIcon: String {
    switch filter {
    case .today: return "star"
    case .inbox: return "tray"
    case .upcoming: return "calendar"
    case .unscheduled: return "rectangle.stack"
    case .logbook: return "checkmark.circle"
    case .project: return "number"
    case .area: return "folder"
    }
  }

  private var titleTint: Color {
    switch filter {
    case .today: return theme.accent
    default: return Theme.inkSecondary
    }
  }

}

/// Encapsulates the standalone-tab nav chrome so we can opt out cleanly
/// when TaskListView is embedded inside a detail page.
private struct TopLevelChromeModifier: ViewModifier {
  let showChrome: Bool
  let nav: NavigationState

  func body(content: Content) -> some View {
    if showChrome {
      content.navigationBarTitleDisplayMode(.inline)
    } else {
      content
    }
  }
}
