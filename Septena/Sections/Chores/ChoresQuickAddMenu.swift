import SwiftUI

// Single canonical menu for the Chores tile — top 2 most-overdue
// actionable chores + Chores…, bound to both the trailing-circle button
// and the tile's `.contextMenu`. Sort: actionable (daysOverdue >= 0) →
// most-overdue first → alphabetical tiebreak. Answers "what's screaming
// at me hardest right now" — the broader list lives in the sheet.

private func actionable(_ chores: [ChoreItem]) -> [ChoreItem] {
  chores
    .filter { $0.daysOverdue >= 0 }
    .sorted { lhs, rhs in
      if lhs.daysOverdue != rhs.daysOverdue { return lhs.daysOverdue > rhs.daysOverdue }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

private func displayName(_ chore: ChoreItem) -> String {
  let core = chore.name
  let n = chore.daysOverdue
  return n <= 0 ? core : "\(core) · \(n)d late"
}

struct ChoresQuickAddMenu: View {
  let chores: [ChoreItem]
  let onComplete: (ChoreItem) -> Void
  /// Opens the Chores section (add / manage / see the full list) — the
  /// always-present escape so the menu is never a dead end when nothing's due.
  let onOpen: () -> Void

  var body: some View {
    let items = actionable(chores)
    if items.isEmpty {
      Text("Nothing due today")
    } else {
      ForEach(items) { chore in
        Button { onComplete(chore) } label: {
          Label(displayName(chore), systemImage: "checkmark.circle")
        }
      }
    }
    Divider()
    Button { onOpen() } label: {
      Label("Chores…", systemImage: "ellipsis")
    }
  }
}
