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
        RecurrencePickerSheet(initial: currentRecurrence(repeatTargetId),
                              hasScheduledDate: currentScheduled(repeatTargetId) != nil,
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
  let onSetRepeatPaused: ([String], Bool) -> Void
  let onCreateNextCopy: (SeptenaTask) -> Void
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
      .keyboardShortcut(TaskRowShortcuts.copy)

      Divider()
    } else if target.isBulk {
      Button {
        onCopy(target)
      } label: {
        Label("Copy Titles", systemImage: "doc.on.doc")
      }
      .keyboardShortcut(TaskRowShortcuts.copy)

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
        onOpenMove(target)
      } label: {
        Label("More…", systemImage: "ellipsis")
      }
      // ⌘⇧M lives on the sheet-opening item, not the parent Menu: a shortcut on
      // the Menu container propagates to every submenu row (Inbox, each area,
      // each project, More…), so all of them showed ⌘⇧M. Attaching it here — the
      // action that mirrors the menu-bar "Move…" — marks only the one item.
      .keyboardShortcut(TaskRowShortcuts.move)

      if !target.tasks.allSatisfy(\.isInTriageBand) {
        Divider()

        Button {
          onMoveTo(target, nil, nil)
        } label: {
          Label("Inbox", systemImage: "tray")
        }
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
    } label: {
      Label(moveLabel, systemImage: "folder")
    }

    if case let .single(task) = target {
      Button {
        onOpenRepeat(task)
      } label: {
        Label("Repeat…", systemImage: "arrow.clockwise")
      }

      if task.recurrence != nil {
        Button {
          onCreateNextCopy(task)
        } label: {
          Label("Create Next Copy", systemImage: "plus.circle")
        }
      }
    }

    if !target.tasks.isEmpty && target.tasks.allSatisfy({ $0.recurrence != nil }) {
      let paused = target.tasks.allSatisfy(\.recurrencePaused)
      Button {
        onSetRepeatPaused(target.ids, !paused)
      } label: {
        Label(paused ? "Resume Repeat" : "Pause Repeat",
              systemImage: paused ? "play.circle" : "pause.circle")
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
    "Move to Today"
  }

  private var todayRemoveLabel: String {
    "Remove from Today"
  }

  private var whenLabel: String {
    "When…"
  }

  private var deadlineLabel: String {
    "Deadline…"
  }

  private var moveLabel: String {
    count > 1 ? "Move Tasks" : "Move"
  }

  private var duplicateLabel: String {
    count > 1 ? "Duplicate Tasks" : "Duplicate"
  }

  private var cancelLabel: String {
    count > 1 ? "Cancel Tasks" : "Cancel Task"
  }

  private var deleteLabel: String {
    count > 1 ? "Delete Tasks" : "Delete"
  }
}
