import SwiftUI
import SwiftData

// Per-item detail for a habit or supplement. Tapping the row body opens this
// (the checkbox still checks off). The intelligence is consistency: current +
// best streak, a 30-day completion rate, and a GitHub-style consistency
// heatmap — all derived at read time from the item's dated `done` rows (via
// the `fetch` closure, backed by `ChecklistMirror.habit/supplementCompletionDates`).
//
// This is now a thin builder over the shared `LogDetailScaffold` so habits,
// supplements, chores and training exercises all render the same surface.

struct LoggableDetailView: View {
  let title: String
  let emoji: String?
  let accent: Color
  /// Past-tense verb for the count line — "done" (habits) / "taken"
  /// (supplements). Yields "Done 12 days" / "Taken 12 days".
  let doneVerb: String
  /// Loads this item's completion dates (YYYY-MM-DD, ascending) from a context.
  let fetch: (ModelContext) -> [String]
  /// Routes the toolbar "Edit" to the parent's existing edit sheet.
  let onEdit: () -> Void

  var body: some View {
    LogDetailScaffold(
      title: title,
      accent: accent,
      load: { ctx in Self.detail(dates: fetch(ctx), emoji: emoji, doneVerb: doneVerb) },
      onEdit: onEdit
    )
  }

  /// Build the shared `LogDetail` from a habit/supplement's completion dates.
  static func detail(dates: [String], emoji: String?, doneVerb: String) -> LogDetail {
    let stats = ConsistencyStats.make(dates: dates)
    var d = LogDetail()
    d.emoji = emoji
    d.subtitle = stats.totalCount == 0
      ? "No history yet"
      : "\(doneVerb.capitalized) \(stats.totalCount) \(stats.totalCount == 1 ? "day" : "days")"
    d.tiles = [
      LogStat(value: "\(stats.currentStreak)", caption: "day streak",
              tone: stats.currentStreak > 0 ? .accent : .normal),
      LogStat(value: "\(stats.bestStreak)", caption: "best streak"),
      LogStat(value: "\(stats.last30Percent)%", caption: "last 30 days"),
    ]
    if !dates.isEmpty {
      let done = Set(dates)
      d.heatmap = LogHeatmap(firstDate: LogDetailFormat.firstDate(dates),
                             level: { done.contains($0) ? 4 : 0 })
    }
    d.recent = stats.recentDates.map {
      LogRecent(title: LogDetailFormat.longDay($0), trailing: LogDetailFormat.relativeDay($0))
    }
    return d
  }
}

// MARK: - Derived stats

/// Consistency figures for a habit/supplement, derived at read time from its
/// completion dates. Pure value type — no I/O.
struct ConsistencyStats {
  let totalCount: Int
  let currentStreak: Int
  let bestStreak: Int
  /// Share of the last 30 days (incl. today) the item was done, 0–100.
  let last30Percent: Int
  /// Most-recent completion dates, newest first (capped for display).
  let recentDates: [String]

  static func make(dates: [String]) -> ConsistencyStats {
    let ords = Set(dates.compactMap(ordinal))
    let todayOrd = SeptenaDate.parse(SeptenaDate.today).flatMap {
      Calendar.current.ordinality(of: .day, in: .era, for: $0)
    }

    // Current streak: consecutive days back from today (or yesterday, so a
    // not-yet-done today doesn't read as a broken streak).
    var current = 0
    if let t = todayOrd {
      var cursor = ords.contains(t) ? t : t - 1
      while ords.contains(cursor) { current += 1; cursor -= 1 }
    }

    // Best streak: longest run of consecutive ordinals.
    var best = 0, run = 0, prev: Int? = nil
    for o in ords.sorted() {
      if let p = prev, o == p + 1 { run += 1 } else { run = 1 }
      best = max(best, run); prev = o
    }

    let last30 = todayOrd.map { t in ords.filter { $0 > t - 30 && $0 <= t }.count } ?? 0
    let pct = Int(round(Double(last30) * 100 / 30))

    return ConsistencyStats(
      totalCount: dates.count,
      currentStreak: current,
      bestStreak: best,
      last30Percent: pct,
      recentDates: Array(dates.reversed().prefix(12))
    )
  }

  private static func ordinal(_ iso: String) -> Int? {
    guard let d = SeptenaDate.parse(iso) else { return nil }
    return Calendar.current.ordinality(of: .day, in: .era, for: d)
  }
}
