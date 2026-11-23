import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The per-row context menu and the modal presenter that hosts the sheets it
// opens. Split out of TaskListView.swift.


struct TaskListModalPresenter: ViewModifier {
  @Binding var whenSheet: TaskListView.WhenSheet?
  @Binding var showingMoveSheet: Bool
  @Binding var moveTargetIds: [String]
  @Binding var showingRepeatSheet: Bool
  @Binding var repeatTargetId: String?
  var reminderTargetId: Binding<String?> = .constant(nil)
  var tagsTargetIds: Binding<[String]> = .constant([])
  /// The Review row whose Send Back… alert is open (row menu
  /// `task.sendBackReview`).
  var sendBackTargetId: Binding<String?> = .constant(nil)
  var applySendBack: ((String, String) -> Void)? = nil

  /// Set by the When sheet's Repeat row: the Repeat sheet opens for this task
  /// once the When sheet has finished dismissing (two sheets can't overlap).
  @State private var pendingRepeatId: String?
  @State private var sendBackNote = ""

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
  /// When only: start time and duration, applied live from the When sheet.
  var applyTimeSlot: (([String], String?, Int?) -> Void)? = nil

  func body(content: Content) -> some View {
    content
      .sheet(item: $whenSheet, onDismiss: openPendingRepeat) { sheet in
        let firstId = sheet.taskIds.first
        let bulk = sheet.taskIds.count > 1
        switch sheet.kind {
        case .scheduled:
          // The same When picker the composer pill opens (ADR 0029). The time
          // slot shows for one task; a bulk When sets the date only.
          let first = currentTask(firstId)
          let slot = (!bulk && applyTimeSlot != nil) ? applyTimeSlot : nil
          DatePickerSheet(
            title: bulk ? "When (\(sheet.taskIds.count) tasks)" : "When",
            initialDate: currentScheduled(firstId),
            initialToday: !bulk && first?.today == true,
            clearLabel: "No Date",
            initialStartTime: bulk ? nil : first?.startTime,
            initialDurationMinutes: bulk ? nil : first?.durationMinutes,
            onTimeSlotChange: slot.map { apply in { start, minutes in apply(sheet.taskIds, start, minutes) } },
            // Repeat lives in the When picker (docs/TASK_ROW_MENU_SPEC.md).
            // The Repeat sheet edits one task, so the row is single-only.
            repeatLabel: bulk ? nil : TaskRepeatLabel.title(currentRecurrence(firstId)),
            onRepeat: bulk ? nil : { pendingRepeatId = firstId }
          ) { date in
            applyWhen(sheet.taskIds, .scheduled, date)
          }
          .taskPickerChrome(DatePickerSheet.detents(showsRepeat: !bulk, showsTime: slot != nil))
        case .deadline:
          DatePickerSheet(
            title: bulk ? "Deadline (\(sheet.taskIds.count) tasks)" : "Deadline",
            initialDate: currentDeadline(firstId),
            clearLabel: "Remove Deadline"
          ) { date in
            applyWhen(sheet.taskIds, .deadline, date)
          }
          .taskPickerChrome(DatePickerSheet.detents(showsRepeat: false, showsTime: false))
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
        .taskPickerChrome(TaskPickerDetents.move)
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
        .taskPickerChrome(TaskPickerDetents.standard)
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
          .taskPickerChrome(TaskPickerDetents.standard)
        }
      }
      .sheet(isPresented: Binding(
        get: { !tagsTargetIds.wrappedValue.isEmpty },
        set: { if !$0 { tagsTargetIds.wrappedValue = [] } }
      )) {
        TagPickerSheet(taskIDs: tagsTargetIds.wrappedValue) {
          tagsTargetIds.wrappedValue = []
        }
        .taskPickerChrome(TaskPickerDetents.standard)
      }
      .alert(String(localized: "Send Back"), isPresented: Binding(
        get: { sendBackTargetId.wrappedValue != nil },
        set: { if !$0 { sendBackTargetId.wrappedValue = nil; sendBackNote = "" } }
      )) {
        TextField(String(localized: "What needs another pass?"), text: $sendBackNote)
        Button(String(localized: "Cancel"), role: .cancel) {}
        Button(String(localized: "Send Back")) {
          let note = sendBackNote.trimmingCharacters(in: .whitespacesAndNewlines)
          if let id = sendBackTargetId.wrappedValue, !note.isEmpty {
            applySendBack?(id, note)
          }
        }
      }
  }

  private func openPendingRepeat() {
    guard let id = pendingRepeatId else { return }
    pendingRepeatId = nil
    repeatTargetId = id
    showingRepeatSheet = true
  }
}

/// The When picker's Repeat row title: "Repeat…", or "Repeat: <rule>" when
/// the task already repeats. Both shells read it.
enum TaskRepeatLabel {
  static func title(_ recurrence: Recurrence?) -> String {
    guard let recurrence else { return RegistryActions.title("task.repeat") }
    return String(localized: "Repeat: \(recurrence.shortLabel)")
  }
}

/// Share… (`task.share`): the system share sheet with `TaskShareText`.
enum TaskSharePresenter {
  @MainActor
  static func present(_ tasks: [SeptenaTask]) {
    let text = TaskShareText.text(for: tasks)
    guard !text.isEmpty else { return }
    #if os(iOS)
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }),
      var top = scene.keyWindow?.rootViewController else { return }
    while let presented = top.presentedViewController { top = presented }
    let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    // iPad presents the share sheet as a popover; it needs an anchor.
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = top.view
      popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
      popover.permittedArrowDirections = []
    }
    top.present(sheet, animated: true)
    #elseif os(macOS)
    guard let window = NSApp.keyWindow, let view = window.contentView else { return }
    let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    NSSharingServicePicker(items: [text])
      .show(relativeTo: NSRect(origin: point, size: .zero), of: view, preferredEdge: .minY)
    #endif
  }
}

// Items, order, titles, icons and shortcuts come from the registry menu
// `task.row` (`registry/actions.json`), the same tree the AppKit shell's row
// menu renders. This view only binds each action ID to a handler and fills the
// Move submenu's destination slots.
struct TaskListRowContextMenu: View {
  let target: TaskListView.ActionTarget
  let filter: TaskFilter
  let rankedSuggestions: [SuggestionEngine.Suggestion]?
  /// The row chip's filing pick (Inbox rows). When set, the menu leads with
  /// "File in <list>" and the Move submenu drops its Suggested entry.
  var filingChip: SuggestionEngine.Suggestion? = nil
  let onDuplicate: (TaskListView.ActionTarget) -> Void
  /// Starts touch multi-select with this row selected (Select). nil hides
  /// it: the Mac, or a list that is already selecting.
  var onSelect: ((SeptenaTask) -> Void)? = nil
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
  var onShare: ((TaskListView.ActionTarget) -> Void)? = nil
  /// Review rows (`needs_verify`) only.
  var onAcceptReview: ((SeptenaTask) -> Void)? = nil
  var onSendBackReview: ((SeptenaTask) -> Void)? = nil

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
    case "task.open", "task.editDetails":
      guard let task = single else { return nil }
      return .init { onOpenDetail(task) }
    case "task.share":
      guard let onShare else { return nil }
      return .init { onShare(target) }
    case "task.acceptReview":
      guard let task = single, task.conversation.needsHumanReview,
            let onAcceptReview else { return nil }
      return .init { onAcceptReview(task) }
    case "task.sendBackReview":
      guard let task = single, task.conversation.needsHumanReview,
            let onSendBackReview else { return nil }
      return .init { onSendBackReview(task) }
    case "task.duplicate":
      return .init(variant: plural) { onDuplicate(target) }
    case "task.select":
      guard let task = single, let onSelect else { return nil }
      return .init { onSelect(task) }
    case "task.toggleComplete":
      // Several tasks only: one task completes from its checkbox
      // (docs/TASK_ROW_MENU_SPEC.md). ⌘K and the menu bar still do one.
      guard count > 1, let onToggleComplete else { return nil }
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
    case "filingSuggestion": return filingSuggestionNodes
    default: return []
    }
  }

  /// "File in <list>" — the row chip's pick, first in the menu for an Inbox
  /// row. The same pick the chip shows, so the two never disagree.
  private var filingSuggestionNodes: [RegistryMenuNode] {
    guard let chip = filingChip, let task = single else { return [] }
    return [RegistryMenuEntry.slot(
      id: "fileSuggested",
      title: String(localized: "File in \(chip.title)"),
      sfSymbol: chip.kind == .project ? "number" : "folder") {
        onApplySuggestion(task, chip)
      }]
  }

  /// The Move submenu's destinations: the filing suggestion first (the same
  /// pick as the row's chip; single task only, a pick is ranked for one
  /// title), then Inbox, every area and every top-level project.
  private var moveDestinations: [RegistryMenuNode] {
    var nodes: [RegistryMenuNode] = []
    if filingChip == nil, let suggestion = rankedSuggestions?.first, let task = single {
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
