import SwiftUI

// Single canonical menu for the Tasks tile — same content from the
// trailing-circle button (Menu) and the tile's `.contextMenu`.
//
// Spec'd as:
//
//   • Create in Inbox…   → switches to Tasks tab, routes to Inbox filter,
//                           and trips `nav.shouldStartCreating` so the
//                           list opens its inline create row (Things-style
//                           — same flow as the sidebar's New To-Do button).
//   • Go to Inbox         → switches to Tasks tab + .filter(.inbox).
//   • Go to Today         → switches to Tasks tab + .filter(.today).
//   • Section "Today"     → up to 3 open today's tasks, tap to mark done.
//   • Tasks…              → opens the AddInfo sheet (existing palette).
//
// The "check off" items use the same TaskMutator path as TaskListView,
// so optimistic state, outbox, and CloudKit push all behave identically.

struct TasksQuickAddMenu: View {
  let todayTasks: [SeptenaTask]
  let onCreateInInbox: () -> Void
  let onGoToInbox: () -> Void
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
    Button { onGoToInbox() } label: {
      Label("Go to Inbox", systemImage: "tray")
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
