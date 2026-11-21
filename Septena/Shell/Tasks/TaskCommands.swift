import SwiftUI

/// Commands published by the focused task list. The menu bar and the iPad
/// shortcut HUD consume this shared contract; `TaskListView` supplies only the
/// handlers for its current selection.
///
/// Titles, order and key bindings are NOT here: they come from
/// `registry/actions.json` (`RegistryActions`), keyed by action ID. This type
/// only maps an action ID to the handler for the current selection.
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

  /// The registry actions this type can serve, in shortcuts-sheet order. The
  /// iPad hidden shortcut buttons render these.
  static let rowCommandIds: [String] = {
    var seen = Set<String>()
    return RegistryActions.shortcutsTaskList
      .map(\.id)
      .filter { supports($0) && seen.insert($0).inserted }
  }()

  /// True when the SwiftUI task list has a handler slot for `actionId`.
  static func supports(_ actionId: String) -> Bool {
    slot(for: actionId) != nil
  }

  /// The handler for a registry action ID. nil when nothing is selected that
  /// it can act on (the menu item disables) or when the list has no such
  /// command (`supports` is false).
  func handler(for actionId: String) -> (() -> Void)? {
    guard let slot = Self.slot(for: actionId) else { return nil }
    return self[keyPath: slot]
  }

  private static func slot(for actionId: String) -> KeyPath<TaskActions, (() -> Void)?>? {
    switch actionId {
    case "task.editDetails": return \.editDetails
    case "task.copy": return \.copy
    case "task.duplicate": return \.duplicate
    case "task.toggleComplete": return \.toggleComplete
    case "task.cancel": return \.cancel
    case "task.toggleToday": return \.toggleToday
    case "task.when": return \.openWhen
    case "task.deadline": return \.openDeadline
    case "task.move": return \.openMove
    case "task.clearSchedule": return \.clearSchedule
    case "task.delete": return \.delete
    default: return nil
    }
  }
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
