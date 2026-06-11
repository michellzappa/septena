import SwiftUI

// Single canonical menu for the Supplements tile — undone doses due *now* +
// Supplements…, bound to both the trailing-circle button and the tile's
// `.contextMenu`. Answers "what should I take next", so it applies the same
// due-now bucket filter as the Next feed's `supplementsNow` (anytime shows
// all day; a bucketed dose shows during its window and, with carry-over on,
// lingers through later buckets; never shows early) — the two surfaces must
// not disagree.
//
// Server-given order is already median-time-of-day sorted per the
// webapp's `api/services/_time_of_day.py :: median_time_by_item()`, so
// Vitamin D surfaces before Magnesium in the morning, etc. No client-
// side sorting.

private func remaining(_ supplements: [SupplementDayItem]) -> [SupplementDayItem] {
  supplements.filter { !$0.done }
}

private func displayName(_ item: SupplementDayItem) -> String {
  item.name
}

struct SupplementsQuickAddMenu: View {
  let supplements: [SupplementDayItem]
  let onToggle: (SupplementDayItem) -> Void

  @AppStorage(NextLinger.supplementsKey) private var linger = NextLinger.supplementsDefault

  var body: some View {
    let undone = remaining(supplements)
    let nowOrder = DayBucket.current.order
    let items = undone.filter { supp in
      guard let raw = supp.bucket, let b = DayBucket(rawValue: raw) else { return true }
      return linger ? (b.order <= nowOrder) : (b.order == nowOrder)
    }
    if items.isEmpty {
      // Distinguish "all taken" from "nothing due in this time bucket".
      let label = undone.isEmpty ? "Nothing left today" : "Nothing due right now"
      Button {} label: { Label(label, systemImage: "checkmark.circle") }
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
