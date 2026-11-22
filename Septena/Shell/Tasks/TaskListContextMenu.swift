import SwiftUI

// The per-row context menu and the modal presenter that hosts the sheets it
// opens. Shared by the deep task list and `TaskRowActions`. Split out of
// TaskListView.swift.


// Internal so the shared `TaskRowActions` modifier can host the same
// When / Deadline / Move / Repeat picker sheets on the Next surface.
struct TaskListModalPresenter: ViewModifier {
  @Binding var whenSheet: TaskListView.WhenSheet?
  @Binding var showingMoveSheet: Bool
  @Binding var moveTargetIds: [String]
  @Binding var showingRepeatSheet: Bool
  @Binding var repeatTargetId: String?
  var reminderTargetId: Binding<String?> = .constant(nil)
  var tagsTargetIds: Binding<[String]> = .constant([])

  let areas: [Area]
  let projects: [Project]
  let currentTask: (String?) -> SeptenaTask?
  let currentScheduled: (String?) -> Date?
  let currentDeadline: (String?) -> Date?
  let currentRecurrence: (String?) -> Recurrence?
  let applyWhen: ([String], TaskListView.WhenKind, Date?) -> Void
  let applyMove: ([String], String?, String?) -> Void
  let applyRecurrence: (String, Recurrence?) -> Void
  let applyRecurrencePaused: (String, Bool) -> Void
  var applyReminder: ((String, TaskReminder?) -> Void)? = nil

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
        let hidesInboxTarget = !moveTargetIds.isEmpty
          && moveTargetIds.allSatisfy { currentTask($0)?.isInTriageBand == true }
        MovePickerSheet(
          areas: areas,
          projects: projects,
          currentAreaId: target?.area,
          currentProjectId: target?.project,
          hidesInboxTarget: hidesInboxTarget,
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
        let scheduledDate = currentScheduled(repeatTargetId)
        RecurrencePickerSheet(initial: currentRecurrence(repeatTargetId),
                              hasScheduledDate: scheduledDate != nil,
                              scheduledDate: SeptenaDate.format(scheduledDate),
                              initialPaused: currentTask(repeatTargetId)?.recurrencePaused ?? false,
                              onPick: { rule in
          if let id = repeatTargetId {
            applyRecurrence(id, rule)
          }
          repeatTargetId = nil
        }, onPauseChanged: { paused in
          if let id = repeatTargetId { applyRecurrencePaused(id, paused) }
        })
        .presentationDetents([.medium, .large])
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(Theme.cornerRadius)
      }
      .sheet(isPresented: Binding(
        get: { reminderTargetId.wrappedValue != nil },
        set: { if !$0 { reminderTargetId.wrappedValue = nil } }
      )) {
        if let id = reminderTargetId.wrappedValue {
          ReminderPickerSheet(initial: currentTask(id)?.reminder) { reminder in
            applyReminder?(id, reminder)
            reminderTargetId.wrappedValue = nil
          }
          .presentationDetents([.medium, .large])
          .presentationBackground(.thinMaterial)
          .presentationCornerRadius(Theme.cornerRadius)
        }
      }
      .sheet(isPresented: Binding(
        get: { !tagsTargetIds.wrappedValue.isEmpty },
        set: { if !$0 { tagsTargetIds.wrappedValue = [] } }
      )) {
        TagPickerSheet(taskIDs: tagsTargetIds.wrappedValue) {
          tagsTargetIds.wrappedValue = []
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(Theme.cornerRadius)
        #endif
      }
  }
}

// Internal (shared with `TaskRowActions`) so the Next surface renders the
// exact same per-row task menu as the Tasks list — single source of truth.
//
// Items, order, titles, icons and shortcuts come from the registry menu
// `task.row` (`registry/actions.json`), the same tree the AppKit shell's row
// menu renders. This view only binds each action ID to a handler and fills the
// Move submenu's destination slots.
struct TaskListRowContextMenu: View {
  let target: TaskListView.ActionTarget
  let filter: TaskFilter
  let rankedSuggestions: [SuggestionEngine.Suggestion]?
  let onDuplicate: (TaskListView.ActionTarget) -> Void
  let onOpenDetail: (SeptenaTask) -> Void
  let onApplySuggestion: (SeptenaTask, SuggestionEngine.Suggestion) -> Void
  let onMoveToToday: ([String], Bool) -> Void
  var onToggleStar: (([String], Bool) -> Void)? = nil
  /// Toggles done / open on the target rows (Complete ▸ Mark as Complete).
  var onToggleComplete: (([String]) -> Void)? = nil
  let onOpenWhen: (TaskListView.ActionTarget) -> Void
  let onOpenDeadline: (TaskListView.ActionTarget) -> Void
  var onOpenReminder: ((SeptenaTask) -> Void)? = nil
  var onOpenTags: ((TaskListView.ActionTarget) -> Void)? = nil
  var onClearSchedule: (([String]) -> Void)? = nil
  let onOpenMove: (TaskListView.ActionTarget) -> Void
  /// Move a task straight to a destination from the inline submenu, skipping the
  /// sheet. `areaId`/`projectId` follow `MovePickerSheet.onPick` semantics
  /// (both nil = Inbox; area only; or a project under its area).
  let onMoveTo: (TaskListView.ActionTarget, _ areaId: String?, _ projectId: String?) -> Void
  /// Destinations surfaced inline. Areas + top-level (no-area) projects only —
  /// a bounded set; projects-under-areas stay behind "Move…".
  let moveAreas: [Area]
  let moveTopProjects: [Project]
  /// The project's sections, for Move to Section ▸ (project pages only).
  var sections: [SeptenaTask] = []
  /// Files the target under a section (nil = no section).
  var onMoveToSection: ((String?) -> Void)? = nil
  let onOpenRepeat: (SeptenaTask) -> Void
  let onSetRepeatPaused: ([String], Bool) -> Void
  let onCreateNextCopy: (SeptenaTask) -> Void
  let onCancel: ([String]) -> Void
  let onDelete: (TaskListView.ActionTarget) -> Void

  private var count: Int { target.count }
  private var single: SeptenaTask? {
    if case let .single(task) = target { return task }
    return nil
  }

  var body: some View {
    RegistryMenuContent(nodes: RegistryMenuResolver.resolve(
      RegistryActions.menu("task.row"), bind: bind, slot: slot))
  }

  private func bind(_ id: String) -> RegistryActionBinding? {
    let tasks = target.tasks
    let plural: RegistryTitleVariant = count > 1 ? .plural : .base
    switch id {
    case "task.editDetails":
      guard let task = single else { return nil }
      return .init { onOpenDetail(task) }
    case "task.duplicate":
      return .init(variant: plural) { onDuplicate(target) }
    case "task.toggleComplete":
      guard let onToggleComplete else { return nil }
      return .init { onToggleComplete(target.ids) }
    case "task.cancel":
      return .init(variant: plural) { onCancel(target.ids) }
    case "task.delete":
      return .init(variant: plural) { onDelete(target) }
    case "task.toggleToday":
      switch todayAction {
      case .add: return .init(variant: .add) { onMoveToToday(target.ids, true) }
      case .remove: return .init(variant: .remove) { onMoveToToday(target.ids, false) }
      case nil: return nil
      }
    case "task.toggleStar":
      guard let onToggleStar else { return nil }
      let allStarred = !tasks.isEmpty && tasks.allSatisfy(\.starred)
      return .init(variant: allStarred ? .remove : .add) { onToggleStar(target.ids, !allStarred) }
    case "task.tags":
      guard let onOpenTags else { return nil }
      return .init { onOpenTags(target) }
    case "task.when":
      return .init { onOpenWhen(target) }
    case "task.deadline":
      return .init { onOpenDeadline(target) }
    case "task.reminder":
      guard let task = single, let onOpenReminder else { return nil }
      return .init { onOpenReminder(task) }
    case "task.clearSchedule":
      guard let onClearSchedule,
            tasks.contains(where: { $0.isOnToday || $0.scheduled != nil || $0.deadline != nil })
      else { return nil }
      return .init { onClearSchedule(target.ids) }
    case "task.move":
      return .init { onOpenMove(target) }
    case "task.repeat":
      guard let task = single else { return nil }
      return .init { onOpenRepeat(task) }
    case "task.pauseResumeRepeat":
      guard !tasks.isEmpty, tasks.allSatisfy({ $0.recurrence != nil }) else { return nil }
      let paused = tasks.allSatisfy(\.recurrencePaused)
      return .init(variant: paused ? .active : .base) { onSetRepeatPaused(target.ids, !paused) }
    case "task.createNextCopy":
      guard let task = single, task.recurrence != nil else { return nil }
      return .init { onCreateNextCopy(task) }
    default:
      // `task.toggleInfo` and anything this shell has no handler for.
      return nil
    }
  }

  private func slot(_ id: String) -> [RegistryMenuNode] {
    switch id {
    case "moveDestinations": return moveDestinations
    case "sectionDestinations": return sectionDestinations
    default: return []
    }
  }

  /// The Move submenu's destinations: the filing suggestion first (the same
  /// pick as the row's chip; single task only, a pick is ranked for one
  /// title), then Inbox, every area and every top-level project.
  private var moveDestinations: [RegistryMenuNode] {
    var nodes: [RegistryMenuNode] = []
    if let suggestion = rankedSuggestions?.first, let task = single {
      nodes.append(RegistryMenuEntry.slot(
        id: "suggested",
        title: String(localized: "Suggested: \(suggestion.title)"),
        sfSymbol: suggestion.kind == .project ? "number" : "folder") {
          onApplySuggestion(task, suggestion)
        })
      nodes.append(.divider(id: "suggested.divider"))
    }
    if !target.tasks.allSatisfy(\.isInTriageBand) {
      nodes.append(RegistryMenuEntry.slot(
        id: "inbox", title: TaskFilter.triage.title,
        sfSymbol: RegistryIcons.sfSymbol(for: "list.inbox")) {
          onMoveTo(target, nil, nil)
        })
    }
    if !moveAreas.isEmpty || !moveTopProjects.isEmpty {
      nodes.append(.divider(id: "destinations.divider"))
      for area in moveAreas {
        let title = (area.emoji?.isEmpty == false) ? "\(area.emoji ?? "")  \(area.title)" : area.title
        nodes.append(RegistryMenuEntry.slot(id: "area.\(area.id)", title: title) {
          onMoveTo(target, area.id, nil)
        })
      }
      for project in moveTopProjects {
        nodes.append(RegistryMenuEntry.slot(
          id: "project.\(project.id)", title: project.title,
          sfSymbol: RegistryIcons.sfSymbol(for: "place.project")) {
            onMoveTo(target, nil, project.id)
          })
      }
    }
    return nodes
  }

  /// Move to Section ▸ — No Section, then every heading of the project.
  private var sectionDestinations: [RegistryMenuNode] {
    guard let onMoveToSection, !sections.isEmpty else { return [] }
    var nodes: [RegistryMenuNode] = [
      RegistryMenuEntry.slot(id: "section.none", title: String(localized: "No Section")) {
        onMoveToSection(nil)
      },
      .divider(id: "sections.divider"),
    ]
    for heading in sections {
      nodes.append(RegistryMenuEntry.slot(id: "section.\(heading.id)", title: heading.title) {
        onMoveToSection(heading.id)
      })
    }
    return nodes
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
}
