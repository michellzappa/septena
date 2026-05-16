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
    Button("New Task") { actions?.newTask() }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(actions == nil)

    Divider()

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
