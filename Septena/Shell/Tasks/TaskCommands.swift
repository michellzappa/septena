import SwiftUI

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
    // task list is focused. Rename is ⌘R — a MODIFIER menu shortcut, the only
    // reliable keyboard path on macOS: unmodified Space activates the row's
    // checkbox (completes it) and Return is stolen by the sidebar. Mouse rename
    // is double-click → composer / right-click → Rename. Disabled (so ⌘R falls
    // through to any focused text field) when `rename` is nil.
    Button("Rename") { actions?.rename?() }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(actions?.rename == nil)

    // ⌘D clones the selected row into a new task (new id, same title/filing/
    // notes/schedule). Disabled (so ⌘D falls through) when nothing's selected.
    Button("Duplicate") { actions?.duplicate?() }
      .keyboardShortcut("d", modifiers: .command)
      .disabled(actions?.duplicate == nil)

    Button("Mark as Complete") { markComplete?() }
      .keyboardShortcut("k", modifiers: .command)
      .disabled(markComplete == nil)

    Button("Toggle Today") { actions?.toggleToday() }
      .keyboardShortcut("t", modifiers: .command)
      .disabled(actions == nil)

    Button("When…") { actions?.openWhen() }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(actions == nil)

    Button("Deadline…") { actions?.openDeadline() }
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(actions == nil)

    Button("Move…") { actions?.openMove() }
      .keyboardShortcut("m", modifiers: .command)
      .disabled(actions == nil)

    Divider()

    Button("Clear Schedule") { actions?.clearSchedule?() }
      .keyboardShortcut(".", modifiers: .command)
      .disabled(actions?.clearSchedule == nil)

    Button("Delete") { actions?.delete?() }
      .keyboardShortcut(.delete, modifiers: .command)
      .disabled(actions?.delete == nil)
  }
}

/// Row actions published by `NextView` while the Next checklist is focused.
/// Only checklist-toggle is exposed here — the rest of the Task menu stays
/// task-list-only so ⌘T / ⌘S / … don't silently no-op on a habit row.
struct NextListActions {
  /// Toggles done/open on the selected row — same handler as Space.
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
