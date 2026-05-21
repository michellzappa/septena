import SwiftUI

// Top 5 undone supplements in server-given order — which is already
// median-time-of-day sorted per `api/services/_time_of_day.py` ::
// `median_time_by_item()` in the webapp. So Vitamin D appears before
// Magnesium in the morning if those are the user's typical times.
// No additional client-side sorting needed.
struct SupplementsQuickAddMenu: View {
  let supplements: [SupplementDayItem]
  let onToggle: (SupplementDayItem) -> Void
  let onMore: () -> Void

  private var remaining: [SupplementDayItem] {
    supplements.filter { !$0.done }.prefix(5).map { $0 }
  }

  var body: some View {
    if remaining.isEmpty {
      Button {} label: { Label("Nothing left today", systemImage: "checkmark.circle") }
        .disabled(true)
    } else {
      ForEach(remaining) { item in
        Button { onToggle(item) } label: {
          Label(displayName(item), systemImage: "checkmark.circle")
        }
      }
    }

    Divider()
    Button { onMore() } label: {
      Label("More…", systemImage: "ellipsis")
    }
  }

  private func displayName(_ item: SupplementDayItem) -> String {
    "\(item.emoji ?? "") \(item.name)".trimmingCharacters(in: .whitespaces)
  }
}
