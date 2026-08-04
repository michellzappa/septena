import SwiftUI

// The shared per-row action surface: the context menu, its modal presenter,
// and the `.taskRowActions` entry point every task row attaches. Split out of
// TaskComponents.swift.

// MARK: - Shared per-row task actions

/// The full task context menu + its picker sheets, bundled into one modifier so
/// any surface (the Tasks list, the Next feed) attaches the *same* menu — Edit
/// Details…, Copy, Duplicate, Move to / Remove from Today, When…, Deadline…,
/// Move…, Repeat…, Cancel, Delete. The menu body is `TaskListRowContextMenu` and the sheets are
/// `TaskListModalPresenter`, both shared with `TaskListView`, so the two
/// surfaces can't drift. Which picker is open is owned per-row.
///
/// Mutations go straight through `TaskMutator`; the surface refreshes off the
/// mutator's change notifications (same as the row's checkbox), so no explicit
/// reload is threaded here. The Inbox "file here" suggestions are a
/// Tasks-list-only affordance and stay nil elsewhere.
struct TaskRowActions: ViewModifier {
  let task: SeptenaTask
  var filter: TaskFilter = .today
  var areas: [Area] = []
  var projects: [Project] = []
  let mutator: TaskMutator
  /// Opens the task's edit / agent composer ("Edit Details…"). nil hides it.
  var onOpenDetail: ((SeptenaTask) -> Void)? = nil
  /// Fired after a menu mutation that can change which list a row belongs to
  /// (remove-from-today, reschedule, move, cancel, delete). Surfaces that hold
  /// their task arrays in @State — like the Tasks drawer — pass a reload here so
  /// the row leaves in real time. Surfaces that already refresh off
  /// `.septenaTasksChanged` (the full `TaskListView`) leave it nil.
  var onChange: (() -> Void)? = nil

  @State private var whenSheet: TaskListView.WhenSheet?
  @State private var showingMoveSheet = false
  @State private var moveTargetIds: [String] = []
  @State private var showingRepeatSheet = false
  @State private var repeatTargetId: String?

  @Environment(PromoteFlashStore.self) private var promoteFlash
  @Environment(\.septenaToast) private var toastStore

  func body(content: Content) -> some View {
    content
      .contextMenu {
        TaskListRowContextMenu(
          target: .single(task),
          filter: filter,
          rankedSuggestions: nil,
          onCopy: { target in
            let titles = target.tasks.map(\.title)
            guard !titles.isEmpty else { return }
            SeptenaPasteboard.copy(titles.joined(separator: "\n"))
            Haptics.tick()
          },
          onDuplicate: { _ in duplicateTask(task) },
          onOpenDetail: { onOpenDetail?($0) },
          onApplySuggestion: { _, _ in },
          onMoveToToday: { ids, today in
            Haptics.tick()
            if today {
              for id in ids {
                mutator.moveToToday(id: id, today: true)
                mutator.acknowledge(id: id)
                promoteFlash.flash(id)
              }
            } else {
              for id in ids {
                mutator.removeFromToday(id: id)
                mutator.acknowledge(id: id)
              }
            }
            onChange?()
          },
          onOpenWhen: { target in
            whenSheet = .init(taskIds: target.ids, kind: .scheduled)
          },
          onOpenDeadline: { target in
            whenSheet = .init(taskIds: target.ids, kind: .deadline)
          },
          onOpenMove: { target in
            moveTargetIds = target.ids
            showingMoveSheet = true
          },
          onMoveTo: { target, areaId, projectId in
            for id in target.ids { applyMove(id: id, areaId: areaId, projectId: projectId) }
          },
          moveAreas: areas,
          moveTopProjects: projects.filter { $0.area == nil && $0.status == .active },
          onOpenRepeat: { t in repeatTargetId = t.id; showingRepeatSheet = true },
          onCancel: { ids in Haptics.warning(); for id in ids { mutator.cancel(id: id) }; onChange?() },
          onDelete: { _ in applyDelete(task) }
        )
      }
      .modifier(TaskListModalPresenter(
        whenSheet: $whenSheet,
        showingMoveSheet: $showingMoveSheet,
        moveTargetIds: $moveTargetIds,
        showingRepeatSheet: $showingRepeatSheet,
        repeatTargetId: $repeatTargetId,
        areas: areas,
        projects: projects,
        currentTask: { _ in task },
        currentScheduled: { _ in task.scheduled.flatMap(SeptenaDate.parse) },
        currentDeadline: { _ in task.deadline.flatMap(SeptenaDate.parse) },
        currentRecurrence: { _ in task.recurrence },
        applyWhen: { ids, kind, date in
          for id in ids { applyWhen(id: id, kind: kind, date: date) }
        },
        applyMove: { ids, areaId, projectId in
          for id in ids { applyMove(id: id, areaId: areaId, projectId: projectId) }
        },
        applyRecurrence: { id, rule in Haptics.tick(); mutator.setRecurrence(id: id, recurrence: rule); onChange?() }
      ))
  }

  // Mirrors `TaskListView.applyWhen` — Things-style "Today" pin vs. future
  // scheduled date vs. cleared. Kept in lockstep with that method.
  private func applyWhen(id: String, kind: TaskListView.WhenKind, date: Date?) {
    Haptics.tick()
    switch kind {
    case .deadline:
      mutator.setDeadline(id: id, date: date)
    case .scheduled:
      if let d = date {
        if Calendar.current.isDateInToday(d) {
          mutator.schedule(id: id, date: nil)
          mutator.moveToToday(id: id, today: true)
          promoteFlash.flash(id)
        } else {
          mutator.moveToToday(id: id, today: false)
          mutator.schedule(id: id, date: d)
          toastStore?.show("Deferred to \(SeptenaDate.scheduleHeaderLabel(for: d))")
        }
      } else {
        mutator.schedule(id: id, date: nil)
        mutator.moveToToday(id: id, today: false)
      }
    }
    mutator.acknowledge(id: id)
    onChange?()
  }

  private func duplicateTask(_ task: SeptenaTask) {
    Haptics.tick()
    mutator.duplicate(task)
    onChange?()
  }

  // Mirrors `TaskListView.applyMove`, minus the Inbox suggestion-rejection
  // bookkeeping (no classifier on surfaces that use this).
  private func applyMove(id: String, areaId: String?, projectId: String?) {
    Haptics.tick()
    let prevArea = task.area
    let prevProject = task.project
    let wasInTriage = task.isInTriageBand
    if projectId != nil {
      mutator.moveToProject(id: id, project: projectId)
    } else {
      mutator.moveToArea(id: id, area: areaId)
      mutator.moveToProject(id: id, project: nil)
    }
    mutator.acknowledge(id: id)
    onChange?()
    let destName =
      projectId.flatMap { pid in projects.first { $0.id == pid }?.title }
      ?? areaId.flatMap { aid in areas.first { $0.id == aid }?.title }
      ?? "No Project"
    toastStore?.show("Moved to \(destName)") {
      if let prevProject {
        mutator.moveToProject(id: id, project: prevProject)
      } else {
        mutator.moveToArea(id: id, area: prevArea)
        mutator.moveToProject(id: id, project: nil)
      }
      if wasInTriage { mutator.moveToToday(id: id, today: false) }
      onChange?()
    }
  }

  private func applyDelete(_ task: SeptenaTask) {
    Haptics.warning()
    let title = task.title
    mutator.delete(id: task.id)
    onChange?()
    toastStore?.show(title.isEmpty ? "Task deleted" : "\"\(title)\" deleted") {
      mutator.restore(id: task.id)
      onChange?()
    }
  }
}

extension View {
  /// Attach the shared task context menu + picker sheets to a row — see
  /// `TaskRowActions`. Use this anywhere a task row appears so the menu stays
  /// identical to the Tasks list.
  func taskRowActions(task: SeptenaTask,
                      filter: TaskFilter = .today,
                      areas: [Area] = [],
                      projects: [Project] = [],
                      mutator: TaskMutator,
                      onOpenDetail: ((SeptenaTask) -> Void)? = nil,
                      onChange: (() -> Void)? = nil) -> some View {
    modifier(TaskRowActions(task: task, filter: filter, areas: areas,
                            projects: projects, mutator: mutator,
                            onOpenDetail: onOpenDetail, onChange: onChange))
  }
}
