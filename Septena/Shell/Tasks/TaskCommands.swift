import SwiftUI

/// Menu-bar items for row-level actions. The handlers live on
/// `TaskListView`; this view reads them from `FocusedValues.taskActions`
/// so the items light up only while a task list is the focused scene.
///
/// Lives under the "Task" menu on macOS and surfaces in the iPad
/// keyboard-shortcut HUD (hold ⌘) automatically.
struct TaskCommandsMenu: View {
  @FocusedValue(\.taskActions) private var actions

  var body: some View {
    // ⌘N lives in the File menu via `NewTaskCommand` so it works even when
    // no task list is focused (otherwise the system falls back to "New
    // Window").
    Button("Mark as Complete") { actions?.toggleComplete?() }
      .keyboardShortcut("k", modifiers: .command)
      .disabled(actions?.toggleComplete == nil)

    Button("Toggle Today") { actions?.toggleToday() }
      .keyboardShortcut("t", modifiers: .command)
      .disabled(actions == nil)

    Button("When…") { actions?.openWhen() }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(actions == nil)

    Button("Deadline…") { actions?.openDeadline() }
      .keyboardShortcut("d", modifiers: [.command, .shift])
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
        NotificationCenter.default.post(name: .septenaOpenQuickAdd, object: nil)
      }
    }
    .keyboardShortcut("n", modifiers: .command)
  }
}
