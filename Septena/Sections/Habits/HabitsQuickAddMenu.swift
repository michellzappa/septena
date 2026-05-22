import SwiftUI

// Single canonical menu for the Habits tile — top 5 undone habits + More,
// bound to both the trailing-circle button and the tile's `.contextMenu`.
// Filtered to time-of-day buckets up to and including "now" — so evening
// habits don't surface at 10am.

private func visibleBucketSet(_ buckets: [String]) -> Set<String> {
  let canonical = ["morning", "afternoon", "evening"]
  let nowIdx: Int = {
    let h = Calendar.current.component(.hour, from: .now)
    if h < 12 { return 0 }
    if h < 17 { return 1 }
    return 2
  }()
  var allowed = Set<String>()
  for name in buckets {
    let lower = name.lowercased()
    if let i = canonical.firstIndex(of: lower) {
      if i <= nowIdx { allowed.insert(name) }
    } else {
      allowed.insert(name) // unknown bucket → fail open
    }
  }
  return allowed
}

private func actionable(_ habits: [HabitDayItem], buckets: [String], limit: Int) -> [HabitDayItem] {
  let allowed = visibleBucketSet(buckets)
  return habits
    .filter { !$0.done && !$0.skipped }
    .filter { allowed.contains($0.bucket) }
    .prefix(limit)
    .map { $0 }
}

private func displayName(_ item: HabitDayItem) -> String {
  "\(item.emoji ?? "") \(item.name)".trimmingCharacters(in: .whitespaces)
}

struct HabitsQuickAddMenu: View {
  let habits: [HabitDayItem]
  let buckets: [String]
  let onComplete: (HabitDayItem) -> Void
  let onMore: () -> Void

  var body: some View {
    let items = actionable(habits, buckets: buckets, limit: 5)
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
    Divider()
    Button { onMore() } label: { Label("Habits…", systemImage: "ellipsis") }
  }
}
