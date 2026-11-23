import Foundation

// MARK: - Toast undo

/// Lets an undo toast reverse ITS OWN action, never whatever happens to be on
/// top of the shared stack.
///
/// A toast used to call `TaskUndo.undo()`, which undoes the NEWEST entry. If
/// anything was recorded after the toast's action (another completion, a
/// rename), tapping the toast's Undo took back that newer action and left the
/// toast's own one in place.
///
/// Create the ticket right AFTER recording the action. While nothing newer has
/// touched the stack, `undo` goes through `TaskUndo.undo()` so the toast and
/// shake / ⌘Z stay one stack. Once anything newer registers (or an undo / redo
/// runs), `undo` runs `fallback` instead: a direct reversal through the
/// mutators.
@MainActor
final class TaskUndoTicket {
  private let actionName: String
  private var isNewest = true
  nonisolated(unsafe) private var observer: NSObjectProtocol?

  init() {
    actionName = TaskUndo.undoActionName
    // Registered after the caller's `record`, whose own `changed` post has
    // already gone out, so only LATER stack changes reach this.
    observer = NotificationCenter.default.addObserver(
      forName: TaskUndo.changed, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.isNewest = false }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func undo(fallback: () -> Void) {
    if isNewest, TaskUndo.canUndo, TaskUndo.undoActionName == actionName {
      TaskUndo.undo()
    } else {
      fallback()
    }
    isNewest = false
  }
}
