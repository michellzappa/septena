import SwiftUI

// Things-style task list. See docs/things-reference/screens.md

struct TaskListView: View {
  @EnvironmentObject var client: ConvexClient
  @EnvironmentObject var nav: NavigationState

  @State private var tasks: [EngageTask] = []
  @State private var areas: [Area] = []
  @State private var projects: [Project] = []
  @State private var isLoading = false
  @State private var errorMessage: String?

  // Inline new-task entry
  @State private var isCreating = false
  @State private var draftTitle = ""
  @State private var draftNotes = ""

  // Inline title edit
  @State private var editingTaskId: String? = nil
  @State private var editingTitle: String = ""
  @State private var editingNotes: String = ""
  @FocusState private var editFieldFocused: Bool

  // Multi-select
  @State private var selectMode = false
  @State private var selection: Set<String> = []

  // Recently-completed visibility
  @State private var recentlyCompleted: Set<String> = []

  // Sheets for multi-select actions
  @State private var showingWhenSheet = false
  @State private var showingMoveSheet = false
  @State private var scheduleEditingTask: String? = nil
  @State private var deadlineEditingTask: String? = nil

  let filter: TaskFilter

  var body: some View {
    ZStack(alignment: .bottom) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ScreenTitle(icon: titleIcon, iconTint: titleTint, title: filter.title)

          if filteredTasks.isEmpty && !isLoading {
            Text("Nothing here yet")
              .font(.thingsMeta)
              .foregroundStyle(.secondary)
              .padding(.horizontal, Theme.hPadding)
              .padding(.top, 40)
          }

          if shouldGroup {
            groupedList
          } else {
            flatList
          }

          if isCreating {
            InlineNewTaskRow(
              title: $draftTitle, notes: $draftNotes,
              defaultWhen: whenLabel, defaultWhenIcon: titleIcon, defaultWhenTint: titleTint,
              onCommit: { commitDraft() }, onCancel: { cancelDraft() }
            )
            .padding(.top, 8)
          }

          Spacer(minLength: 140)
        }
      }
      .background(Color(.systemBackground))

      trailingFloater
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { toolbarContent }
    .alert("Error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .sheet(isPresented: $showingWhenSheet) {
      WhenPickerSheet(onPick: { date in
        if let id = scheduleEditingTask {
          applyStartToTask(id: id, date: date)
          scheduleEditingTask = nil
        } else if let id = deadlineEditingTask {
          applyDueToTask(id: id, date: date)
          deadlineEditingTask = nil
        } else {
          applyDueToSelected(date)
        }
      })
        .presentationDetents([.medium])
    }
    .sheet(isPresented: $showingMoveSheet) {
      MovePickerSheet(areas: areas, projects: projects, onPick: { areaId, projectId in
        applyMoveToSelected(areaId: areaId, projectId: projectId)
      })
      .presentationDetents([.medium, .large])
    }
    .task(id: filter) {
      await load()
      if nav.autoStartEntry {
        nav.autoStartEntry = false
        startDraft()
      }
    }
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      if selectMode {
        Button("Done") { exitSelectMode() }
          .font(.system(size: 15, weight: .semibold))
      } else if editingTaskId != nil {
        Button("Done") { commitEdit() }
          .font(.system(size: 15, weight: .semibold))
      } else {
        Button {
          // placeholder for ••• menu
        } label: {
          Image(systemName: "ellipsis.circle")
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: - Floating UI

  @ViewBuilder
  private var trailingFloater: some View {
    if selectMode {
      MultiSelectBar(
        count: selection.count,
        onWhen: { showingWhenSheet = true },
        onMove: { showingMoveSheet = true },
        onDelete: deleteSelected,
        onMore: { /* TODO */ }
      )
      .padding(.horizontal, 24)
      .padding(.bottom, 20)
      .transition(.move(edge: .bottom).combined(with: .opacity))
    } else if isCreating {
      HStack {
        Spacer()
        Button {
          if draftTitle.trimmingCharacters(in: .whitespaces).isEmpty { cancelDraft() } else { commitDraft() }
        } label: {
          Text("Done")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Theme.magicPlusBlue)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
      }
      .padding(.trailing, Theme.hPadding)
      .padding(.bottom, 20)
    } else {
      HStack {
        Spacer()
        MagicPlusButton { startDraft() }
      }
      .padding(.trailing, Theme.hPadding)
      .padding(.bottom, 20)
    }
  }

  // MARK: - List variants

  private var flatList: some View {
    VStack(spacing: 0) {
      ForEach(filteredTasks) { task in
        row(task)
        Hairline()
      }
    }
  }

  private var groupedList: some View {
    VStack(alignment: .leading, spacing: 0) {
      let ungrouped = filteredTasks.filter { $0.project == nil }
      if !ungrouped.isEmpty {
        ForEach(ungrouped) { task in
          row(task)
          Hairline()
        }
      }
      ForEach(groupedByProject, id: \.0.id) { project, items in
        ListSectionHeader(
          icon: "circle", iconTint: .secondary, title: project.name,
          onTap: selectMode ? nil : { nav.path.append(.project(project)) }
        )
        Hairline()
        ForEach(items) { task in
          row(task)
          Hairline()
        }
      }
    }
  }

  // MARK: - Row

  @ViewBuilder
  private func row(_ task: EngageTask) -> some View {
    if editingTaskId == task.id {
      InlineEditTaskRow(
        title: $editingTitle,
        notes: $editingNotes,
        isDone: task.status == .completed,
        onToggleDone: { toggle(task) },
        onCommit: { commitEdit() },
        onCancel: { editingTaskId = nil; editFieldFocused = false },
        onSchedule: { scheduleEditingTask = task.id; showingWhenSheet = true },
        onDeadline: { deadlineEditingTask = task.id; showingWhenSheet = true }
      )
    } else {
      editableRowBody(task)
    }
  }

  @ViewBuilder
  private func editableRowBody(_ task: EngageTask) -> some View {
    HStack(spacing: 12) {
      ThingsCheckbox(isDone: task.status == .completed) {
        if !selectMode { toggle(task) }
      }
      .allowsHitTesting(!selectMode)
      .opacity(selectMode ? 0.5 : 1)

      Button {
        if selectMode {
          toggleSelection(task.id)
        } else {
          startEdit(task)
        }
      } label: {
        HStack(spacing: 6) {
          Text(task.title)
            .font(.thingsTaskTitle)
            .foregroundStyle(task.status == .completed ? .secondary : .primary)
            .strikethrough(task.status == .completed)
            .opacity(task.status == .completed ? 0.5 : 1)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 8)
          if selectMode {
            RadioCircle(isSelected: selection.contains(task.id))
          } else {
            trailingMeta(task)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .swipeLeftToSelect {
        if selectMode {
          if !selection.contains(task.id) { toggleSelection(task.id) }
        } else {
          enterSelectMode(with: task.id)
        }
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 12)
    .frame(minHeight: Theme.rowHeight)
    .background(selectMode && selection.contains(task.id) ? Theme.rowSelected : Color.clear)
  }

  @ViewBuilder
  private func trailingMeta(_ task: EngageTask) -> some View {
    HStack(spacing: 6) {
      if task.isRecurring {
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      if let due = task.due { deadlineLabel(for: due) }
    }
  }

  @ViewBuilder
  private func deadlineLabel(for date: Date) -> some View {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let target = cal.startOfDay(for: date)
    let days = cal.dateComponents([.day], from: today, to: target).day ?? 0
    HStack(spacing: 3) {
      Image(systemName: "flag.fill").font(.system(size: 11))
      Text(days < 0 ? "\(-days)d over" : days == 0 ? "today" : days == 1 ? "1d left" : "\(days)d left")
        .font(.thingsMeta)
    }
    .foregroundStyle(days == 0 ? Theme.overdueRed : .secondary)
  }

  // MARK: - Edit mode

  private func startEdit(_ task: EngageTask) {
    if editingTaskId != nil && editingTaskId != task.id { commitEdit() }
    editingTaskId = task.id
    editingTitle = task.title
    editingNotes = task.notes ?? ""
    editFieldFocused = true
  }

  private func commitEdit() {
    guard let id = editingTaskId else { return }
    let trimmedTitle = editingTitle.trimmingCharacters(in: .whitespaces)
    let newNotes = editingNotes
    editingTaskId = nil
    editFieldFocused = false
    guard !trimmedTitle.isEmpty else { return }
    guard let original = tasks.first(where: { $0.id == id }) else { return }
    var patch: [String: Any] = [:]
    if original.title != trimmedTitle { patch["title"] = trimmedTitle }
    if (original.notes ?? "") != newNotes {
      patch["notes"] = newNotes.isEmpty ? NSNull() : newNotes
    }
    guard !patch.isEmpty else { return }
    Task {
      try? await client.taskUpdate(id: id, patch: patch, actor: "human")
      await load()
    }
  }

  // MARK: - Selection mode

  private func enterSelectMode(with initialId: String) {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    withAnimation(.easeOut(duration: 0.2)) {
      selectMode = true
      selection = [initialId]
    }
  }

  private func toggleSelection(_ id: String) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if selection.contains(id) {
      selection.remove(id)
    } else {
      selection.insert(id)
    }
  }

  private func exitSelectMode() {
    withAnimation(.easeOut(duration: 0.2)) {
      selectMode = false
      selection = []
    }
  }

  private func applyDueToTask(id: String, date: Date?) {
    let patch: [String: Any] = ["due": date.map { Int($0.timeIntervalSince1970 * 1000) } ?? NSNull()]
    Task {
      try? await client.taskUpdate(id: id, patch: patch, actor: "human")
      await load()
    }
  }

  private func applyStartToTask(id: String, date: Date?) {
    let patch: [String: Any] = ["start": date.map { Int($0.timeIntervalSince1970 * 1000) } ?? NSNull()]
    Task {
      try? await client.taskUpdate(id: id, patch: patch, actor: "human")
      await load()
    }
  }

  private func applyDueToSelected(_ date: Date?) {
    let ids = Array(selection)
    let patch: [String: Any] = ["due": date.map { Int($0.timeIntervalSince1970 * 1000) } ?? NSNull()]
    Task {
      for id in ids {
        try? await client.taskUpdate(id: id, patch: patch, actor: "human")
      }
      await load()
      exitSelectMode()
    }
  }

  private func applyMoveToSelected(areaId: String?, projectId: String?) {
    let ids = Array(selection)
    var patch: [String: Any] = [:]
    patch["area"] = areaId ?? NSNull()
    patch["project"] = projectId ?? NSNull()
    Task {
      var failures = 0
      var lastError: String?
      for id in ids {
        do {
          try await client.taskUpdate(id: id, patch: patch, actor: "human")
        } catch {
          failures += 1
          lastError = error.localizedDescription
        }
      }
      if failures > 0 {
        errorMessage = "Move failed for \(failures) task(s): \(lastError ?? "unknown")"
      }
      await load()
      exitSelectMode()
    }
  }

  private func deleteSelected() {
    let ids = Array(selection)
    Task {
      for id in ids {
        try? await client.taskCancel(id: id, actor: "human")
      }
      await load()
      exitSelectMode()
    }
  }

  // MARK: - Derived

  private var shouldGroup: Bool {
    switch filter {
    case .today, .upcoming, .anytime, .someday: return true
    default: return false
    }
  }

  private var groupedByProject: [(Project, [EngageTask])] {
    let withProject = filteredTasks.filter { $0.project != nil }
    let byId = Dictionary(grouping: withProject) { $0.project! }
    return byId.compactMap { pid, items -> (Project, [EngageTask])? in
      guard let p = projects.first(where: { $0.id == pid }) else { return nil }
      return (p, items)
    }.sorted { $0.0.sortOrder < $1.0.sortOrder }
  }

  private var titleIcon: String {
    switch filter {
    case .inbox: return "tray.fill"
    case .today: return "star.fill"
    case .upcoming: return "calendar"
    case .anytime: return "square.stack.3d.up.fill"
    case .someday: return "archivebox.fill"
    case .logbook: return "checkmark.square.fill"
    case .review: return "exclamationmark.triangle.fill"
    case .project, .area: return "circle"
    }
  }

  private var titleTint: Color {
    switch filter {
    case .inbox: return Theme.inboxBlue
    case .today: return Theme.todayYellow
    case .upcoming: return Theme.upcomingRed
    case .anytime: return Theme.anytimeTeal
    case .someday: return Theme.somedayTan
    case .logbook: return Theme.logbookGreen
    default: return .secondary
    }
  }

  private var whenLabel: String {
    switch filter {
    case .today: return "Today"
    case .inbox: return "Inbox"
    case .upcoming: return "Upcoming"
    case .anytime: return "Anytime"
    case .someday: return "Someday"
    default: return "Today"
    }
  }

  // MARK: - Inline entry

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

    var due: Date? = nil
    var project: String? = nil
    var area: String? = nil
    let today = Calendar.current.startOfDay(for: Date())
    switch filter {
    case .today: due = today
    case .project(let pid): project = pid
    case .area(let aid): area = aid
    default: break
    }
    if let parsed = EngageDateParser.parse(title) { due = parsed }
    let repeatRule = EngageDateParser.parseRepeatRule(title)

    Task {
      do {
        try await client.taskCreate(
          title: title, notes: notes, origin: .human, owner: "human",
          area: area, project: project, due: due, repeatRule: repeatRule
        )
        draftTitle = ""; draftNotes = ""
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - Filter + load

  private var filteredTasks: [EngageTask] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    return tasks.filter { task in
      let isActive = task.status == .open || recentlyCompleted.contains(task.id)
      switch filter {
      case .inbox:
        return isActive && task.area == nil && task.project == nil && task.due == nil && task.start == nil
      case .today:
        return isActive && (
          (task.due != nil && calendar.isDate(task.due!, inSameDayAs: today)) ||
          (task.start != nil && calendar.isDate(task.start!, inSameDayAs: today)) ||
          (task.due != nil && task.due! < today)
        )
      case .upcoming(let days):
        let end = calendar.date(byAdding: .day, value: days, to: today)!
        return isActive && (
          (task.due != nil && task.due! >= today && task.due! <= end) ||
          (task.start != nil && task.start! >= today && task.start! <= end)
        )
      case .anytime:
        return isActive && task.due == nil && task.start == nil && (task.area != nil || task.project != nil)
      case .someday: return false
      case .project(let pid): return isActive && task.project == pid
      case .area(let aid): return isActive && task.area == aid
      case .review: return task.status == .open && task.agentStatus == .blocked
      case .logbook: return task.status == .completed || task.status == .cancelled
      }
    }
  }

  private func load() async {
    isLoading = true
    errorMessage = nil
    do {
      async let t = client.tasksList()
      async let p = client.projectsList()
      async let a = client.areasList()
      tasks = try await t
      projects = try await p
      areas = try await a
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  private func toggle(_ task: EngageTask) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if task.status == .open {
      recentlyCompleted.insert(task.id)
      Task {
        try? await client.taskComplete(id: task.id, completedBy: "human")
        await load()
      }
    } else if recentlyCompleted.contains(task.id) {
      recentlyCompleted.remove(task.id)
      Task {
        try? await client.taskUpdate(
          id: task.id,
          patch: ["status": "open", "completedAt": NSNull(), "completedBy": NSNull()],
          actor: "human"
        )
        await load()
      }
    }
  }
}

// MARK: - Legacy shim

struct TaskRowView: View {
  let task: EngageTask
  var body: some View { ThingsTaskRow(task: task) }
}
