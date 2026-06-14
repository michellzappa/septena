import Foundation

extension WakingDay {
  /// Build a resolver from the dashboard's already-loaded Oura nights. Each
  /// `OuraNight` is one *main* sleep per date (Oura's long-sleep), so naps can't
  /// move the boundary. `OuraNight.date` is the morning you woke up, which is
  /// exactly the civil-date key the resolver wants. Nights with no parseable
  /// `wakeTime` fall through to the cutoff for that date.
  static func from(nights: [OuraNight],
                   enabled: Bool = true,
                   cutoffHour: Int = 4) -> WakingDay {
    var map: [String: Double] = [:]
    for n in nights {
      if let f = fraction(fromHHmm: n.wakeTime) { map[n.date] = f }
    }
    return WakingDay(enabled: enabled, cutoffHour: cutoffHour, wakeFractionByDate: map)
  }
}
