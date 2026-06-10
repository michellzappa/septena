import Foundation

/// Consistency figures for a dated done-list (habit/supplement completions),
/// derived at read time. Pure value type — no I/O. Lives in SeptenaCore so the
/// detail views and the milestone detectors share one streak definition and
/// can never disagree on what a "30-day streak" means.
struct ConsistencyStats {
  let totalCount: Int
  let currentStreak: Int
  let bestStreak: Int
  /// Share of the last 30 days (incl. today) the item was done, 0–100.
  let last30Percent: Int
  /// Most-recent completion dates, newest first (capped for display).
  let recentDates: [String]

  /// `today` is injectable so callers on the DayClock contract (the milestone
  /// detectors) pass `DayClock.today`; UI callers take the default.
  static func make(dates: [String], today: String = SeptenaDate.today) -> ConsistencyStats {
    let ords = Set(dates.compactMap(ordinal))
    let todayOrd = SeptenaDate.parse(today).flatMap {
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
