import Foundation

/// The "waking day" boundary for the dashboard dial.
///
/// The rest of the app keys "what day is it" to calendar midnight (`DayClock`,
/// every deterministic day-keyed CloudKit id). This type is a **presentation
/// lens for the rhythm wheel only** — it answers a narrower question: *which
/// waking day does this instant belong to?* — so the dial can roll over at
/// **wake** instead of midnight. Staying up past midnight then keeps the evening
/// on the same dial instead of snapping it to "yesterday," and the small hours
/// before you wake read as the night before — not clutter on the fresh day.
///
/// It deliberately does NOT touch `DayClock.today`, task scheduling, or any
/// day-keyed id. See `docs/WAKING_DAY_WHEEL.md`.
///
/// ## Boundary resolution (layered fallback)
/// 1. **Sleep-driven** — if a confident main-sleep wake time is known for a
///    civil date (from `OuraNight`, which is one main night per date — naps
///    never enter here), the waking day for that date begins at that wake.
/// 2. **Fixed cutoff** — no sleep data for that date → the day rolls at
///    `cutoffHour` (default 04:00). This is the load-bearing fallback and the
///    pre-sync behavior (Oura hasn't pushed last night yet).
/// 3. **Midnight** — `enabled == false` collapses to plain `startOfDay`, so the
///    same call path serves a toggle-off / legacy state.
///
/// A waking day is identified by its **civil-date key** — the calendar date you
/// woke up on. Keying by civil midnight (not the wake instant) keeps day-distance
/// math exact even when wake time varies night to night: `dayKey` always returns
/// a midnight `Date`, so `dateComponents([.day])` between two keys is correct.
public struct WakingDay: Sendable, Equatable {
  /// When false, every `dayKey` is plain calendar `startOfDay` — the legacy
  /// midnight boundary. The toggle-off and "no lens" path.
  public var enabled: Bool
  /// Fallback roll point (hour, 0..<24) for dates with no main-sleep wake.
  public var cutoffHour: Int
  /// Main-sleep wake time per civil date (`"yyyy-MM-dd"` → fraction of day,
  /// 0..<1). The date is the morning you woke up — matching `OuraNight.date`.
  public var wakeFractionByDate: [String: Double]

  public init(enabled: Bool = true,
              cutoffHour: Int = 4,
              wakeFractionByDate: [String: Double] = [:]) {
    self.enabled = enabled
    self.cutoffHour = cutoffHour
    self.wakeFractionByDate = wakeFractionByDate
  }

  /// The midnight (calendar `startOfDay`) of the waking day that contains
  /// `instant`. For an instant before that morning's wake, this is the
  /// *previous* civil date — the night belongs to the day that's ending.
  public func dayKey(containing instant: Date, calendar: Calendar = .current) -> Date {
    let civil = calendar.startOfDay(for: instant)
    guard enabled else { return civil }
    let frac = wakeFraction(forCivilDate: civil, calendar: calendar)
      ?? Double(cutoffHour) / 24
    let wakeInstant = civil.addingTimeInterval(frac * 86_400)
    if instant >= wakeInstant { return civil }
    return calendar.date(byAdding: .day, value: -1, to: civil) ?? civil
  }

  /// Whole waking days between `instant` and the waking "today" anchored at
  /// `todayKey` (a `dayKey`). 0 = same waking day (today), 1 = yesterday, …
  /// Negative for future instants. Mirrors the wheel's `daysAgo`.
  public func daysAgo(_ instant: Date, todayKey: Date, calendar: Calendar = .current) -> Int {
    let key = dayKey(containing: instant, calendar: calendar)
    return calendar.dateComponents([.day], from: key, to: todayKey).day ?? 0
  }

  /// Main-sleep wake fraction for a civil date, if known.
  public func wakeFraction(forCivilDate civil: Date, calendar: Calendar = .current) -> Double? {
    wakeFractionByDate[Self.ymd(civil, calendar: calendar)]
  }

  // Construction from `OuraNight` sleep data lives in `WakingDay+Oura.swift` —
  // kept out of this file so the resolver core has no model dependency and can
  // be unit-tested in isolation.

  // MARK: Helpers

  /// "HH:mm" → fraction of a day (0..<1). nil for missing/malformed input.
  static func fraction(fromHHmm s: String?) -> Double? {
    guard let s else { return nil }
    let parts = s.split(separator: ":")
    guard let h = Double(parts.first ?? "") else { return nil }
    let m = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
    return (h * 60 + m) / 1440
  }

  /// Civil date → `"yyyy-MM-dd"` in the calendar's own time zone, so a custom
  /// (test) calendar resolves keys in its zone rather than the device's.
  static func ymd(_ date: Date, calendar: Calendar) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }
}
