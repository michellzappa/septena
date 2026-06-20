import SwiftUI

// Single canonical menu for the Tasks tile — same content from the
// trailing-circle button (Menu) and the tile's `.contextMenu`.
//
// Spec'd as:
//
//   • Create in Inbox…   → pops the composer in place to capture a loose task;
//                           it lands in the Inbox section on top of Today
//                           (docs/TRIAGE_BAND_SPEC.md).
//   • Go to Today         → switches to Tasks tab + .filter(.today), where the
//                           triage band (the retired Inbox page's contents) now
//                           sits on top of the day.
//   • Section "Today"     → up to 3 open today's tasks, tap to mark done.
//
// "Create in Inbox…" is the full-input escape (every section's quick-add ends
// with a path to the full composer). The "check off" items use the same
// TaskMutator path as TaskListView,
// so optimistic state, outbox, and CloudKit push all behave identically.

struct TasksQuickAddMenu: View {
  let todayTasks: [SeptenaTask]
  let onCreateInInbox: () -> Void
  let onGoToToday: () -> Void
  let onCheckOff: (SeptenaTask) -> Void

  /// Top 3 open tasks for today; finished ones drop out so the menu
  /// doesn't surface stale rows once they're complete.
  private var open: [SeptenaTask] {
    todayTasks.filter { $0.status != .done }.prefix(3).map { $0 }
  }

  var body: some View {
    Button { onCreateInInbox() } label: {
      Label("Create in Inbox…", systemImage: "plus.circle")
    }
    Button { onGoToToday() } label: {
      Label("Go to Today", systemImage: "star")
    }

    if !open.isEmpty {
      Section("Today") {
        ForEach(open) { task in
          Button { onCheckOff(task) } label: {
            Label(task.title, systemImage: "checkmark.circle")
          }
        }
      }
    }

  }
}
