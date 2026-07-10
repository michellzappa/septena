import SwiftUI

/// Modifier shortcuts for row-level task actions — single source for the Task
/// menu bar, the row context menu, and iPad hidden shortcut buttons.
enum TaskRowShortcuts {
  static let editDetails = KeyboardShortcut("r", modifiers: .command)
  static let copy = KeyboardShortcut("c", modifiers: .command)
  static let duplicate = KeyboardShortcut("d", modifiers: .command)
  static let markComplete = KeyboardShortcut("k", modifiers: .command)
  static let toggleToday = KeyboardShortcut("t", modifiers: .command)
  static let when = KeyboardShortcut("s", modifiers: .command)
  static let deadline = KeyboardShortcut("d", modifiers: [.command, .shift])
  static let move = KeyboardShortcut("m", modifiers: .command)
  static let clearSchedule = KeyboardShortcut(".", modifiers: .command)
  static let delete = KeyboardShortcut(.delete, modifiers: .command)
}

/// Commands published by the focused task list. The menu bar and the iPad
/// shortcut HUD consume this shared contract; `TaskListView` supplies only the
/// handlers for its current selection.
struct TaskActions {
  var newTask: () -> Void
  var toggleToday: (() -> Void)?
  var openWhen: (() -> Void)?
  var openDeadline: (() -> Void)?
  var openMove: (() -> Void)?
  /// Toggles done/open on the selected row(s) — invoked by the explicit ⌘K
  /// Task-menu command.
  var toggleComplete: (() -> Void)?
  var delete: (() -> Void)?
  var clearSchedule: (() -> Void)?
  var editDetails: (() -> Void)?
  var duplicate: (() -> Void)?
  var copy: (() -> Void)?
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

/// Menu-bar items for row-level actions. The handlers live on
/// `TaskListView`; this view reads them from `FocusedValues.taskActions`
/// so the items light up only while a task list is the focused scene.
///
/// Lives under the "Task" menu on macOS and surfaces in the iPad
/// keyboard-shortcut HUD (hold ⌘) automatically.
struct TaskCommandsMenu: View {
  @FocusedValue(\.taskActions) private var actions
  @FocusedValue(\.nextListActions) private var nextActions

  private var markComplete: (() -> Void)? {
    actions?.toggleComplete ?? nextActions?.toggleComplete
  }

  var body: some View {
    // ⌘N lives in the File menu via `NewTaskCommand` so it works even when no
    // task list is focused. Edit is ⌘R — a MODIFIER menu shortcut, the only
    // reliable keyboard path on macOS: unmodified Space activates the row's
    // checkbox (completes it) and Return is stolen by the sidebar. Disabled
    // (so ⌘R falls through to any focused text field) when `editDetails` is nil.
    Button("Edit Details…") { actions?.editDetails?() }
      .keyboardShortcut(TaskRowShortcuts.editDetails)
      .disabled(actions?.editDetails == nil)

    Button("Copy") { actions?.copy?() }
      .keyboardShortcut(TaskRowShortcuts.copy)
      .disabled(actions?.copy == nil)

    Button("Duplicate") { actions?.duplicate?() }
      .keyboardShortcut(TaskRowShortcuts.duplicate)
      .disabled(actions?.duplicate == nil)

    Button("Mark as Complete") { markComplete?() }
      .keyboardShortcut(TaskRowShortcuts.markComplete)
      .disabled(markComplete == nil)

    Button("Toggle Today") { actions?.toggleToday?() }
      .keyboardShortcut(TaskRowShortcuts.toggleToday)
      .disabled(actions?.toggleToday == nil)

    Button("When…") { actions?.openWhen?() }
      .keyboardShortcut(TaskRowShortcuts.when)
      .disabled(actions?.openWhen == nil)

    Button("Deadline…") { actions?.openDeadline?() }
      .keyboardShortcut(TaskRowShortcuts.deadline)
      .disabled(actions?.openDeadline == nil)

    Button("Move…") { actions?.openMove?() }
      .keyboardShortcut(TaskRowShortcuts.move)
      .disabled(actions?.openMove == nil)

    Divider()

    Button("Clear Schedule") { actions?.clearSchedule?() }
      .keyboardShortcut(TaskRowShortcuts.clearSchedule)
      .disabled(actions?.clearSchedule == nil)

    Button("Delete") { actions?.delete?() }
      .keyboardShortcut(TaskRowShortcuts.delete)
      .disabled(actions?.delete == nil)
  }
}

/// Row actions published by `NextView` while the Next checklist is focused.
/// Only checklist-toggle is exposed here — the rest of the Task menu stays
/// task-list-only so ⌘T / ⌘S / … don't silently no-op on a habit row.
struct NextListActions {
  /// Toggles done/open on the selected row — invoked by ⌘K.
  var toggleComplete: (() -> Void)?
}

private struct NextListActionsKey: FocusedValueKey {
  typealias Value = NextListActions
}

extension FocusedValues {
  var nextListActions: NextListActions? {
    get { self[NextListActionsKey.self] }
    set { self[NextListActionsKey.self] = newValue }
  }
}

/// Replaces the system "New Window" ⌘N. When a task list is focused, fires
/// its inline-create action so the new row inherits the list's
/// project/area; otherwise posts the Quick Add notification (Inbox + draft
/// row), matching the menu-bar entry and iOS Home Screen Quick Action.
struct NewTaskCommand: View {
  @FocusedValue(\.taskActions) private var actions

  var body: some View {
    Button("New To-Do") {
      if let actions {
        actions.newTask()
      } else {
        OpenNewTaskRouting.dispatch()
      }
    }
    .keyboardShortcut("n", modifiers: .command)
  }
}
