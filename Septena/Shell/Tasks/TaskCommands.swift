import SwiftUI

/// Modifier shortcuts for row-level task actions — single source for the Task
/// menu bar, the row context menu, and iPad hidden shortcut buttons.
enum TaskRowShortcuts {
  static let editDetails = KeyboardShortcut("r", modifiers: .command)
  static let copy = KeyboardShortcut("c", modifiers: .command)
  static let duplicate = KeyboardShortcut("d", modifiers: .command)
  static let markComplete = KeyboardShortcut("k", modifiers: .command)
  // ⌥⌘K, deliberately one modifier away from ⌘K: cancelling and completing are
  // neighbours in meaning (both retire a row to the Logbook) but opposite in
  // outcome, so they should be neighbours on the keyboard AND impossible to
  // hit by accident. Not a system-reserved equivalent.
  static let cancel = KeyboardShortcut("k", modifiers: [.command, .option])
  static let toggleToday = KeyboardShortcut("t", modifiers: .command)
  static let when = KeyboardShortcut("s", modifiers: .command)
  static let deadline = KeyboardShortcut("d", modifiers: [.command, .shift])
  // Keep ⌘⇧M for compatibility, but the focused task list also accepts the
  // bare ⌘M alias. Septask/Septena deliberately reclaim it because it is never
  // useful to minimize while working in a task list.
  static let move = KeyboardShortcut("m", modifiers: [.command, .shift])
  static let moveBare = KeyboardShortcut("m", modifiers: .command)
  // ⌘⇧., not ⌘.: bare ⌘. is the universal system Cancel / iPad hardware-Escape
  // key, so a plain ⌘. would silently unschedule selected rows when a user hits
  // it to "escape".
  static let clearSchedule = KeyboardShortcut(".", modifiers: [.command, .shift])
  static let delete = KeyboardShortcut(.delete, modifiers: .command)
}

/// One row-level task command: its menu title, its binding, and which handler
/// slot on `TaskActions` it drives.
///
/// This is the single registry every surface renders from — the macOS Task
/// menu, the iPad hidden-shortcut buttons, the row context menu, and the
/// human-facing Keyboard Shortcuts sheet. They used to each spell the list out
/// by hand and had drifted: the catalogue advertised ⌘. for Clear Schedule
/// (the real binding is ⌘⇧.), the context menu's Copy carried no shortcut at
/// all, and the iPad buttons had empty titles so the hold-⌘ HUD showed blank
/// rows. Add a command here and every surface picks it up.
struct TaskRowCommand: Identifiable {
  let id: String
  let title: String
  let shortcut: KeyboardShortcut
  /// Extra bindings handled by the focused task surface. A menu item can show
  /// only one key equivalent, so these aliases are registered by the surface
  /// itself and included in the shortcuts catalogue.
  var alternateShortcuts: [KeyboardShortcut] = []
  /// The handler slot on `TaskActions`. Nil there means "not available for the
  /// current selection", which disables the menu item.
  let handler: KeyPath<TaskActions, (() -> Void)?>
  /// Also served by the Next checklist when no task list is focused.
  var acceptsNextList: Bool = false
  /// A menu separator precedes this item.
  var separatorBefore: Bool = false

  /// The primary shortcut rendered as keycap tokens, e.g. ["⌘", "⇧", "M"] —
  /// so callers can display the real binding rather than a hand-copied guess.
  var keycaps: [String] {
    Self.keycaps(for: shortcut)
  }

  static func keycaps(for shortcut: KeyboardShortcut) -> [String] {
    var caps: [String] = []
    if shortcut.modifiers.contains(.control) { caps.append("⌃") }
    if shortcut.modifiers.contains(.option)  { caps.append("⌥") }
    if shortcut.modifiers.contains(.shift)   { caps.append("⇧") }
    if shortcut.modifiers.contains(.command) { caps.append("⌘") }
    caps.append(keycap(for: shortcut.key))
    return caps
  }

  var allShortcuts: [KeyboardShortcut] {
    [shortcut] + alternateShortcuts
  }

  /// Compare on `character` rather than the `KeyEquivalent` cases themselves so
  /// this doesn't depend on `KeyEquivalent`'s (SDK-version-dependent)
  /// `Equatable` conformance.
  private static func keycap(for key: KeyEquivalent) -> String {
    let c = key.character
    if c == KeyEquivalent.delete.character     { return "⌫" }
    if c == KeyEquivalent.escape.character     { return "esc" }
    if c == KeyEquivalent.return.character     { return "return" }
    if c == KeyEquivalent.space.character      { return "space" }
    if c == KeyEquivalent.tab.character        { return "tab" }
    if c == KeyEquivalent.upArrow.character    { return "↑" }
    if c == KeyEquivalent.downArrow.character  { return "↓" }
    if c == KeyEquivalent.leftArrow.character  { return "←" }
    if c == KeyEquivalent.rightArrow.character { return "→" }
    return String(c).uppercased()
  }
}

enum TaskRowCommands {
  /// Menu order. Mirrors the Task menu top to bottom.
  static let all: [TaskRowCommand] = [
    TaskRowCommand(id: "editDetails", title: "Edit Details…",
                   shortcut: TaskRowShortcuts.editDetails, handler: \.editDetails),
    TaskRowCommand(id: "copy", title: "Copy",
                   shortcut: TaskRowShortcuts.copy, handler: \.copy),
    TaskRowCommand(id: "duplicate", title: "Duplicate",
                   shortcut: TaskRowShortcuts.duplicate, handler: \.duplicate),
    TaskRowCommand(id: "markComplete", title: "Mark as Complete",
                   shortcut: TaskRowShortcuts.markComplete, handler: \.toggleComplete,
                   acceptsNextList: true),
    TaskRowCommand(id: "cancel", title: "Cancel Task",
                   shortcut: TaskRowShortcuts.cancel, handler: \.cancel),
    TaskRowCommand(id: "toggleToday", title: "Toggle Today",
                   shortcut: TaskRowShortcuts.toggleToday, handler: \.toggleToday),
    TaskRowCommand(id: "when", title: "When…",
                   shortcut: TaskRowShortcuts.when, handler: \.openWhen),
    TaskRowCommand(id: "deadline", title: "Deadline…",
                   shortcut: TaskRowShortcuts.deadline, handler: \.openDeadline),
    TaskRowCommand(id: "move", title: "Move…",
                   shortcut: TaskRowShortcuts.move,
                   alternateShortcuts: [TaskRowShortcuts.moveBare],
                   handler: \.openMove),
    TaskRowCommand(id: "clearSchedule", title: "Clear Schedule",
                   shortcut: TaskRowShortcuts.clearSchedule, handler: \.clearSchedule,
                   separatorBefore: true),
    TaskRowCommand(id: "delete", title: "Delete",
                   shortcut: TaskRowShortcuts.delete, handler: \.delete),
  ]
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
  /// Retires the selected row(s) as cancelled — ⌥⌘K. Distinct from complete:
  /// the work didn't happen, and the Logbook records that difference.
  var cancel: (() -> Void)?
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

  /// Resolve a command's handler from whatever is focused. Most come straight
  /// from the task list; Mark as Complete also accepts the Next checklist.
  private func handler(for command: TaskRowCommand) -> (() -> Void)? {
    if let actions, let action = actions[keyPath: command.handler] { return action }
    if command.acceptsNextList { return nextActions?.toggleComplete }
    return nil
  }

  var body: some View {
    // ⌘N lives in the File menu via `NewTaskCommand` so it works even when no
    // task list is focused. Edit is ⌘R — a MODIFIER menu shortcut, the only
    // reliable keyboard path on macOS. Each item disables itself (so its key
    // falls through to any focused text field) when its handler is nil.
    ForEach(TaskRowCommands.all) { command in
      if command.separatorBefore { Divider() }
      let action = handler(for: command)
      Button(command.title) { action?() }
        .keyboardShortcut(command.shortcut)
        .disabled(action == nil)
      // NSMenuItem has one visible key-equivalent slot. Keep the alias as a
      // hidden command item; the task surface also handles it directly so the
      // binding remains focused on the list rather than Window ▸ Minimize.
      ForEach(Array(command.alternateShortcuts.enumerated()), id: \.offset) { _, shortcut in
        Button(command.title) { action?() }
          .keyboardShortcut(shortcut)
          .hidden()
          .disabled(action == nil)
      }
    }
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
  #if SEPTASK
  @FocusedValue(\.septaskNavigationActions) private var septaskNavigation
  #endif

  var body: some View {
    Button("New To-Do") {
      if let actions {
        actions.newTask()
      } else {
        #if SEPTASK
        septaskNavigation?.newTask()
        #else
        OpenNewTaskRouting.dispatch()
        #endif
      }
    }
    .keyboardShortcut("n", modifiers: .command)
  }
}
