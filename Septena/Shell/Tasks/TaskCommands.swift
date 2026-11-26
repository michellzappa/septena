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
  /// Do: exactly one selected open task.
  var doTask: (() -> Void)?
  var duplicate: (() -> Void)?
  var copy: (() -> Void)?
  /// Favorite / unfavorite the selected row(s) — ⌥⌘S.
  var toggleStar: (() -> Void)? = nil
  /// Open the tag picker for the selected row(s) — ⇧⌘T.
  var openTags: (() -> Void)? = nil
  /// Open the reminder picker for one selected row — ⌥⌘R.
  var openReminder: (() -> Void)? = nil
  /// File one selected row into its suggested project or area — ⌥⌘M.
  var moveSuggested: (() -> Void)? = nil
  /// Waiting On… for one selected open row (docs/REVIEW_SPEC.md §6).
  var openWaiting: (() -> Void)? = nil
  /// Got It Back for the selected waiting rows.
  var gotItBack: (() -> Void)? = nil

  /// The registry actions this type can serve, in shortcuts-sheet order. The
  /// iPad hidden shortcut buttons render these.
  static let rowCommandIds: [RegistryActionID] = {
    var seen = Set<RegistryActionID>()
    return RegistryActions.shortcutsTaskList
      .map(\.actionId)
      .filter { supports($0) && seen.insert($0).inserted }
  }()

  /// True when the SwiftUI task list has a handler slot for `actionId`.
  static func supports(_ actionId: RegistryActionID) -> Bool {
    slot(for: actionId) != nil
  }

  /// The handler for a registry action ID. nil when nothing is selected that
  /// it can act on (the menu item disables) or when the list has no such
  /// command (`supports` is false).
  func handler(for actionId: RegistryActionID) -> (() -> Void)? {
    guard let slot = Self.slot(for: actionId) else { return nil }
    return self[keyPath: slot]
  }

  private static func slot(for actionId: RegistryActionID) -> KeyPath<TaskActions, (() -> Void)?>? {
    switch actionId {
    case .taskEditDetails: return \.editDetails
    case .taskDo: return \.doTask
    case .taskCopy: return \.copy
    case .taskDuplicate: return \.duplicate
    case .taskToggleComplete: return \.toggleComplete
    case .taskCancel: return \.cancel
    case .taskToggleToday: return \.toggleToday
    case .taskWhen: return \.openWhen
    case .taskDeadline: return \.openDeadline
    case .taskMove: return \.openMove
    case .taskClearSchedule: return \.clearSchedule
    case .taskToggleStar: return \.toggleStar
    case .taskTags: return \.openTags
    case .taskReminder: return \.openReminder
    case .taskMoveSuggested: return \.moveSuggested
    case .taskWaitingOn: return \.openWaiting
    case .taskGotItBack: return \.gotItBack
    case .taskDelete: return \.delete
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
