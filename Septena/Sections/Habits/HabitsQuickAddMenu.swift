import SwiftUI

// Top 4 undone habits from the *visible* buckets — visible meaning
// "morning" once the clock hits morning, "afternoon" once it hits noon,
// etc. Same cutoff as AddHabitPage so the menu doesn't surface evening
// habits at 10am. Flat list (no per-bucket section header) since the
// "what's actionable now" concept is already implied by the bucket filter.
struct HabitsQuickAddMenu: View {
  let habits: [HabitDayItem]
  let buckets: [String]
  let onComplete: (HabitDayItem) -> Void
  let onMore: () -> Void

  /// Buckets up to and including the current time-of-day bucket. Unknown
  /// bucket names (server-side renames) pass through as visible.
  private var visibleBuckets: Set<String> {
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
        allowed.insert(name) // unknown bucket — fail open
      }
    }
    return allowed
  }

  private var actionable: [HabitDayItem] {
    habits
      .filter { !$0.done && !$0.skipped }
      .filter { visibleBuckets.contains($0.bucket) }
      .prefix(4)
      .map { $0 }
  }

  var body: some View {
    if actionable.isEmpty {
      Button {} label: { Label("Nothing left right now", systemImage: "checkmark.circle") }
        .disabled(true)
    } else {
      ForEach(actionable) { item in
        Button { onComplete(item) } label: {
          Label(displayName(item), systemImage: "checkmark.circle")
        }
      }
    }

    Divider()
    Button { onMore() } label: {
      Label("More…", systemImage: "ellipsis")
    }
  }

  private func displayName(_ item: HabitDayItem) -> String {
    "\(item.emoji ?? "") \(item.name)".trimmingCharacters(in: .whitespaces)
  }
}
