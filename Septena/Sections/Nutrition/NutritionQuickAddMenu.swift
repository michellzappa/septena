import SwiftUI

// Single canonical menu for the Nutrition tile — same content from the
// trailing-circle button (Menu) and the tile's `.contextMenu`.
//
// Two entry points + a recommendation section ("New meal…" is the full-input
// escape every section's quick-add ends with):
//
//   1. Search…  → focused search modal across the full meal history.
//                 The right path when "I know I've eaten this before
//                 but it isn't in the top 3."
//
//   2. New meal… → opens the meal-form sheet for a fresh entry.
//                  Macros + emoji + foods + ingredients, same shape as
//                  EditNutritionEntrySheet.
//
//   3. Section "Recommended" — top 3 meals scored by:
//        - time-of-day match (past instances within ±2h of now)
//        - repetition count over the lookback window
//        - recency bonus
//      Tap re-logs the meal at the current time with its macros.
//
// The dashboard does the scoring; the menu just renders.

struct NutritionQuickAddMenu: View {
  let recommendations: [NutritionEntry]
  let onSearch: () -> Void
  let onInput: () -> Void
  let onCommit: (NutritionEntry) -> Void

  private func displayName(_ entry: NutritionEntry) -> String {
    let head = entry.foods.first ?? "Meal"
    if let emoji = entry.emoji, !emoji.isEmpty { return "\(emoji) \(head)" }
    return head
  }

  var body: some View {
    Button { onSearch() } label: {
      Label("Search meals…", systemImage: "magnifyingglass")
    }
    Button { onInput() } label: {
      Label("New meal…", systemImage: "plus.circle")
    }

    if !recommendations.isEmpty {
      Section("Recommended") {
        ForEach(recommendations) { meal in
          Button { onCommit(meal) } label: {
            Label(displayName(meal), systemImage: "fork.knife")
          }
        }
      }
    }

  }
}
