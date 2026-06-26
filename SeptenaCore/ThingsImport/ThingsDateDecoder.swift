import Foundation

enum ThingsDateDecoder {
  private static let yMask: Int64 = 0b111111111110000000000000000
  private static let mMask: Int64 = 0b000000000001111000000000000
  private static let dMask: Int64 = 0b000000000000000111110000000

  /// Decode Things' binary YYYYYYYYYYYMMMMDDDDD date integer.
  static func decodeThingsDate(_ value: Int64?) -> Date? {
    guard let value, value > 0 else { return nil }
    let year = Int((value & yMask) >> 16)
    let month = Int((value & mMask) >> 12)
    let day = Int((value & dMask) >> 7)
    guard year >= 1970, (1...12).contains(month), (1...31).contains(day) else { return nil }
    var comps = DateComponents()
    comps.year = year
    comps.month = month
    comps.day = day
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    return cal.date(from: comps)
  }

  /// Legacy / alternate column: REAL unix timestamp (seconds).
  static func decodeUnixTimestamp(_ value: Double?) -> Date? {
    guard let value, value > 0 else { return nil }
    return Date(timeIntervalSince1970: value)
  }

  private static let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
  }()

  static func formatISODate(_ d: Date?) -> String? {
    guard let d else { return nil }
    return isoFormatter.string(from: d)
  }

  static var todayISO: String { isoFormatter.string(from: Date()) }
}
