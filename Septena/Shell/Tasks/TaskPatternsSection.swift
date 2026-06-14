import SwiftUI

// Tasks "Patterns" view — the throughput counterpart to the checklist sections'
// `CompletionPatternsSection`. Tasks have no fixed daily "total" to express as a
// done/total adherence percent (a habit stack does; a to-do list doesn't), so the
// honest pattern is *throughput*: how many tasks you finished each day, rendered
// as the same GitHub-style `ConsistencyHeatmap` every other section uses, plus a
// compact stat header (last-30-day total + current daily-completion streak).
//
// See docs/DRAWER_MODES_SPEC.md. Reuses `ConsistencyHeatmap` so the grid + ramp
// can't drift from Habits/GitHub.

/// One day's completed-task count for `TaskPatternsSection`.
struct TaskCompletionDay: Hashable {
  let date: String   // YYYY-MM-DD
  let count: Int
}

struct TaskPatternsSection: View {
  let accent: Color
  /// Daily series, chronological (oldest → newest), ending today.
  let days: [TaskCompletionDay]
  var loading: Bool = false

  private var byDate: [String: Int] {
    Dictionary(days.map { ($0.date, $0.count) }, uniquingKeysWith: { a, _ in a })
  }

  private var hasData: Bool { days.contains { $0.count > 0 } }

  /// Earliest day with a completion — clamps the heatmap's left edge so
  /// pre-history weeks don't render as a wall of empty cells.
  private var firstDataDate: Date? {
    days.first(where: { $0.count > 0 }).flatMap { SeptenaDate.parse($0.date) }
  }

  /// Tasks completed across the last 30 days.
  private var last30Total: Int {
    days.suffix(30).map(\.count).reduce(0, +)
  }

  /// Consecutive days back from today with ≥1 completion. Honest: a gap today
  /// breaks it to 0.
  private var currentStreak: Int {
    var streak = 0
    for day in days.reversed() {
      if day.count > 0 { streak += 1 } else { break }
    }
    return streak
  }

  var body: some View {
    if hasData {
      DrawerSection("Completed") {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .top, spacing: 22) {
            stat("\(last30Total)", "last 30 days")
            stat("\(currentStreak)", "day streak")
          }
          ConsistencyHeatmap(
            endDate: Date(),
            firstDataDate: firstDataDate,
            accent: accent,
            getDay: { iso in
              let count = byDate[iso] ?? 0
              return HeatmapDay(level: Self.level(count), label: Self.label(iso: iso, count: count))
            }
          )
        }
      }
    } else if !loading {
      DrawerSection("Completed") {
        Text("Check a few things off and your completion pattern shows up here.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func stat(_ value: String, _ caption: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
        .foregroundStyle(accent)
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// Map a day's completion count to the heatmap's 0…4 ramp. Fixed buckets
  /// tuned for a personal to-do list (a handful of tasks is a strong day): any
  /// completion lifts to at least level 1.
  static func level(_ count: Int) -> Int {
    switch count {
    case ..<1: return 0
    case 1...2: return 1
    case 3...4: return 2
    case 5...7: return 3
    default: return 4
    }
  }

  private static func label(iso: String, count: Int) -> String {
    guard count > 0 else { return iso }
    return count == 1 ? "\(iso): 1 task" : "\(iso): \(count) tasks"
  }
}
