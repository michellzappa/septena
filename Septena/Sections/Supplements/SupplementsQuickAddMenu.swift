import SwiftUI

// Single canonical menu for the Supplements tile — top 2 undone +
// Supplements…, bound to both the trailing-circle button and the tile's
// `.contextMenu`. Answers "what should I take next."
//
// Server-given order is already median-time-of-day sorted per the
// webapp's `api/services/_time_of_day.py :: median_time_by_item()`, so
// Vitamin D surfaces before Magnesium in the morning, etc. No client-
// side sorting.

private func remaining(_ supplements: [SupplementDayItem], limit: Int) -> [SupplementDayItem] {
  supplements.filter { !$0.done }.prefix(limit).map { $0 }
}

private func displayName(_ item: SupplementDayItem) -> String {
  item.name
}

struct SupplementsQuickAddMenu: View {
  let supplements: [SupplementDayItem]
  let onToggle: (SupplementDayItem) -> Void

  var body: some View {
    let items = remaining(supplements, limit: 2)
    if items.isEmpty {
      Button {} label: { Label("Nothing left today", systemImage: "checkmark.circle") }
        .disabled(true)
    } else {
      ForEach(items) { item in
        Button { onToggle(item) } label: {
          Label(displayName(item), systemImage: "checkmark.circle")
        }
      }
    }
  }
}
