import Foundation

/// Daily snapshot store for grocery stock level.
///
/// A grocery item's `low` flag is *state*, not an event — there is no
/// per-day activity to plot the way there is for caffeine sessions or
/// tasks completed. So the only honest day-based series is "how many
/// items were missing (low) on day D." We can't reconstruct that from
/// the current snapshot alone (we'd need every low↔stocked transition
/// date, which isn't stored), so instead we record today's count each
/// time the dashboard loads and let the series fill in going forward.
///
/// Gaps (days the app wasn't opened) carry forward the last known
/// count rather than collapsing to 0 — stock level persists whether or
/// not you looked at it, so a quiet day is "same as yesterday," not
/// "suddenly nothing missing."
enum GroceryStockHistory {
  private static let key = "groceries.missingHistory.v1"
  private static let retentionDays = 120

  private static let fmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  private static func load() -> [String: Int] {
    UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
  }

  private static func save(_ map: [String: Int]) {
    UserDefaults.standard.set(map, forKey: key)
  }

  /// Stamp today's missing count. Cheap and idempotent — only writes
  /// when the value actually changes, so calling it on every render is
  /// fine. Prunes entries older than `retentionDays`.
  static func record(missing: Int, on date: Date = Date()) {
    let today = fmt.string(from: Calendar.current.startOfDay(for: date))
    var map = load()
    if map[today] == missing { return }
    map[today] = missing

    if let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: date) {
      let cutoffKey = fmt.string(from: Calendar.current.startOfDay(for: cutoff))
      map = map.filter { $0.key >= cutoffKey }
    }
    save(map)
  }

  /// Trailing `days`-long series of missing counts, oldest-first, last
  /// element = today. Gaps carry forward the most recent prior count;
  /// days before the first-ever snapshot read as 0 (we genuinely have
  /// no data, and don't fabricate it).
  static func series(days: Int, asOf date: Date = Date()) -> [Int] {
    let map = load()
    let cal = Calendar.current
    let today = cal.startOfDay(for: date)
    var last = 0
    var started = false
    var out: [Int] = []
    out.reserveCapacity(days)
    for back in stride(from: days - 1, through: 0, by: -1) {
      guard let d = cal.date(byAdding: .day, value: -back, to: today) else { continue }
      if let v = map[fmt.string(from: d)] {
        last = v
        started = true
        out.append(v)
      } else {
        out.append(started ? last : 0)
      }
    }
    return out
  }
}
