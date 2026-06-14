import SwiftUI

// Single canonical menu for the Habits tile — top 2 undone habits from
// the current time-of-day bucket only, bound to the tile's `.contextMenu`.
// At 10am only morning habits surface; at 3pm only afternoon; at 8pm only
// evening. Answers "what's next right now" — the full list lives in the sheet.

private func currentBucketSet(_ buckets: [String]) -> Set<String> {
  // Read the current bucket through DayBucket so the user's configured
  // Settings ▸ Time of Day cutoffs apply here too, rather than re-hardcoding
  // 12 / 17.
  let now = DayBucket.current.rawValue
  var allowed = Set<String>()
  for name in buckets {
    let lower = name.lowercased()
    if DayBucket(rawValue: lower) != nil {
      if lower == now { allowed.insert(name) }
    } else {
      allowed.insert(name) // unknown bucket → fail open
    }
  }
  return allowed
}

private func actionable(_ habits: [HabitDayItem], buckets: [String]) -> [HabitDayItem] {
  let allowed = currentBucketSet(buckets)
  return habits
    .filter { !$0.done && !$0.skipped }
    .filter { allowed.contains($0.bucket) }
}

private func displayName(_ item: HabitDayItem) -> String {
  item.name
}

struct HabitsQuickAddMenu: View {
  let habits: [HabitDayItem]
  let buckets: [String]
  let onComplete: (HabitDayItem) -> Void

  var body: some View {
    let items = actionable(habits, buckets: buckets)
    if items.isEmpty {
      Button {} label: { Label("Nothing left right now", systemImage: "checkmark.circle") }
        .disabled(true)
    } else {
      ForEach(items) { item in
        Button { onComplete(item) } label: {
          Label(displayName(item), systemImage: "checkmark.circle")
        }
      }
    }
  }
}
