import SwiftUI

// Top 4 actionable chores (days_overdue >= 0), sorted most-overdue first.
// "Add new" stays behind "More…" because menus can't host text input.
// Empty state: a disabled "Nothing due today" row + "More…" — never hide
// the menu entirely so the affordance stays consistent.
struct ChoresQuickAddMenu: View {
  let chores: [ChoreItem]
  let onComplete: (ChoreItem) -> Void
  let onMore: () -> Void

  private var actionable: [ChoreItem] {
    chores
      .filter { $0.daysOverdue >= 0 }
      .sorted { lhs, rhs in
        if lhs.daysOverdue != rhs.daysOverdue { return lhs.daysOverdue > rhs.daysOverdue }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
      .prefix(4)
      .map { $0 }
  }

  var body: some View {
    if actionable.isEmpty {
      Button {} label: { Label("Nothing due today", systemImage: "checkmark.circle") }
        .disabled(true)
    } else {
      ForEach(actionable) { chore in
        Button { onComplete(chore) } label: {
          Label(displayName(chore), systemImage: "checkmark.circle")
        }
      }
    }

    Divider()
    Button { onMore() } label: {
      Label("More…", systemImage: "ellipsis")
    }
  }

  private func displayName(_ chore: ChoreItem) -> String {
    let core = "\(chore.emoji ?? "") \(chore.name)".trimmingCharacters(in: .whitespaces)
    let n = chore.daysOverdue
    if n <= 0 { return core }
    return "\(core) · \(n)d late"
  }
}
