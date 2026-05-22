import SwiftUI

// Single canonical menu for the Chores tile — top 5 actionable chores +
// More, bound to both the trailing-circle button and the tile's
// `.contextMenu`. Sort: actionable (daysOverdue >= 0) → most-overdue
// first → alphabetical tiebreak. Adding new chores stays in the sheet
// (menus can't host text input).

private func actionable(_ chores: [ChoreItem], limit: Int) -> [ChoreItem] {
  chores
    .filter { $0.daysOverdue >= 0 }
    .sorted { lhs, rhs in
      if lhs.daysOverdue != rhs.daysOverdue { return lhs.daysOverdue > rhs.daysOverdue }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
    .prefix(limit)
    .map { $0 }
}

private func displayName(_ chore: ChoreItem) -> String {
  let core = "\(chore.emoji ?? "") \(chore.name)".trimmingCharacters(in: .whitespaces)
  let n = chore.daysOverdue
  return n <= 0 ? core : "\(core) · \(n)d late"
}

struct ChoresQuickAddMenu: View {
  let chores: [ChoreItem]
  let onComplete: (ChoreItem) -> Void
  let onMore: () -> Void

  var body: some View {
    let items = actionable(chores, limit: 5)
    if items.isEmpty {
      Button {} label: { Label("Nothing due today", systemImage: "checkmark.circle") }
        .disabled(true)
    } else {
      ForEach(items) { chore in
        Button { onComplete(chore) } label: {
          Label(displayName(chore), systemImage: "checkmark.circle")
        }
      }
    }
    Divider()
    Button { onMore() } label: { Label("Chores…", systemImage: "ellipsis") }
  }
}
