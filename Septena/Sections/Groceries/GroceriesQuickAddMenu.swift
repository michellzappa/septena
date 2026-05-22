import SwiftUI

// Single canonical menu for the Groceries tile — same content from the
// trailing-circle button (Menu) and the tile's `.contextMenu`.
//
// Top 3 most-recently-bought stocked items + Groceries…. "Most recently
// bought" is the closest proxy we have for "most commonly toggled":
// staples (milk, eggs, bread) get re-bought often and therefore
// surface first. The server doesn't currently track a toggle count;
// if that signal becomes available, swap the sort here.
//
// Tap a row → POSTs `low: true` (same PATCH as AddGroceryPage.markLow).
// Adding new items / searching / picking from the long tail lives behind
// "Groceries…" (the AddInfo sheet has type-to-create + full list).

struct GroceriesQuickAddMenu: View {
  let items: [GroceryItem]
  let onMarkLow: (GroceryItem) -> Void

  /// Top 3 stocked items ranked by `lastBought` descending. Items with no
  /// `lastBought` sort last so freshly-added groceries don't crowd out
  /// known staples until they've been bought at least once.
  private var topStocked: [GroceryItem] {
    items
      .filter { !$0.low }
      .sorted { lhs, rhs in
        switch (lhs.lastBought, rhs.lastBought) {
        case let (.some(l), .some(r)): return l > r
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none):
          return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
      }
      .prefix(3)
      .map { $0 }
  }

  var body: some View {
    if topStocked.isEmpty {
      Button {} label: {
        Label("No stocked items", systemImage: "checkmark.circle")
      }
      .disabled(true)
    } else {
      ForEach(topStocked) { item in
        Button { onMarkLow(item) } label: {
          Label(displayName(item), systemImage: "cart.badge.minus")
        }
      }
    }

  }

  private func displayName(_ item: GroceryItem) -> String {
    return item.name
  }
}
