import SwiftUI

// Section-level "Patterns" view for checklist sections (Habits, Supplements,
// Chores, Medications): a GitHub-style completion heatmap where each day's level
// encodes how much of that day's stack was done, plus a compact stat header
// (last-30 average + current all-done streak). DRY across every section that can
// express a day as "done / total" — each feeds the same daily series, so the
// aggregate Patterns surface is defined once here. The per-ITEM detail heatmap
// lives in `LoggableDetailView`; this is the whole-section counterpart.
//
// See docs/DRAWER_MODES_SPEC.md (Phase 2). Reuses `ConsistencyHeatmap` and
// `ConsistencyStats` so the streak math + ramp can't drift from the item view.

/// Date helpers for sections that build a contiguous daily series in-view
/// (e.g. Medications computing adherence from a `@Query`, rather than from a
/// `ChecklistMirror` history read that already returns one row per day).
enum CompletionDateRange {
  /// The trailing `n` ISO dates ending today, oldest → newest.
  static func lastNDates(_ n: Int) -> [String] {
    let cal = Calendar.current
    return (0..<n).reversed().compactMap { off in
      cal.date(byAdding: .day, value: -off, to: Date()).flatMap(SeptenaDate.format)
    }
  }
}

/// One day's aggregate completion for `CompletionPatternsSection`.
struct CompletionDay: Hashable {
  let date: String   // YYYY-MM-DD
  let done: Int
  let total: Int

  var percent: Int { total > 0 ? Int((Double(done) * 100 / Double(total)).rounded()) : 0 }
}

struct CompletionPatternsSection: View {
  /// Card title — "Completion" (habits), "Adherence" (medications), etc.
  let title: String
  let accent: Color
  /// Daily series, chronological (oldest → newest), ending today.
  let days: [CompletionDay]
  var loading: Bool = false

  private var byDate: [String: CompletionDay] {
    Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
  }

  private var hasData: Bool { days.contains { $0.total > 0 } }

  /// Earliest day that had any items — clamps the heatmap's left edge so
  /// pre-history weeks don't render as a wall of empty cells.
  private var firstDataDate: Date? {
    days.first(where: { $0.total > 0 }).flatMap { SeptenaDate.parse($0.date) }
  }

  /// Average completion across the last 30 days that actually had items.
  private var last30Avg: Int {
    let recent = days.suffix(30).filter { $0.total > 0 }
    guard !recent.isEmpty else { return 0 }
    return Int((Double(recent.map(\.percent).reduce(0, +)) / Double(recent.count)).rounded())
  }

  /// Consecutive days back from today where the whole stack was done — reuses
  /// the shared streak definition so it matches the per-item view.
  private var fullStreak: Int {
    let fullDates = days.filter { $0.total > 0 && $0.done >= $0.total }.map(\.date)
    return ConsistencyStats.make(dates: fullDates).currentStreak
  }

  var body: some View {
    if hasData {
      DrawerSection(title) {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .top, spacing: 22) {
            stat("\(last30Avg)%", "last 30 days")
            stat("\(fullStreak)", fullStreak == 1 ? "day streak" : "day streak")
          }
          ConsistencyHeatmap(
            endDate: Date(),
            firstDataDate: firstDataDate,
            accent: accent,
            getDay: { iso in
              let d = byDate[iso]
              return HeatmapDay(level: Self.level(d?.percent ?? 0),
                                label: Self.label(iso: iso, day: d))
            }
          )
        }
      }
    } else if !loading {
      DrawerSection(title) {
        Text("Keep logging — a completion pattern appears here once there's a few days of history.")
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

  /// Map a 0–100 completion percent to the heatmap's 0…4 ramp via the shared
  /// `HeatmapLevel` convention (0 only for an empty day; any progress ≥ 1).
  static func level(_ pct: Int) -> Int { HeatmapLevel.completion(percent: pct) }

  private static func label(iso: String, day: CompletionDay?) -> String {
    guard let day, day.total > 0 else { return iso }
    return "\(iso): \(day.done)/\(day.total)"
  }
}
