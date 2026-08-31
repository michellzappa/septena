import Foundation

// ─── Natural Language Date Parser ─────────────────────────────────────────────

struct SeptenaDateParser {
  /// Parse a natural language date string into a Date.
  /// Examples:
  ///   "tomorrow", "next monday", "in 3 days", "every monday",
  ///   "monthly on the 1st", "March 15", "2026-04-05"
  static func parse(_ input: String) -> Date? {
    let normalized = input.lowercased().trimmingCharacters(in: .whitespaces)
    let calendar = Calendar.current
    let now = Date()

    if let relative = parseRelative(normalized, relativeTo: now, calendar: calendar) {
      return relative
    }

    if let weekday = parseWeekday(normalized, relativeTo: now, calendar: calendar) {
      return weekday
    }

    if let interval = parseInterval(normalized, relativeTo: now) {
      return interval
    }

    return parseAbsolute(input, calendar: calendar)
  }

  /// Extract repeatRule from natural language.
  /// Returns nil if no repeat pattern detected.
  static func parseRepeatRule(_ input: String) -> String? {
    let lower = input.lowercased()
    let patterns = [
      ("every day", "every day"),
      ("every mon", "every monday"),
      ("every tue", "every tuesday"),
      ("every wed", "every wednesday"),
      ("every thu", "every thursday"),
      ("every fri", "every friday"),
      ("every sat", "every saturday"),
      ("every sun", "every sunday"),
      ("every week", "every week"),
      ("every month", "every month"),
      ("every year", "every year"),
      ("every ", "every "), // catch-all
      ("monthly", "monthly"),
      ("weekly", "weekly"),
      ("daily", "daily"),
      ("yearly", "yearly"),
    ]

    for (pattern, rule) in patterns {
      if let range = lower.range(of: pattern) {
        // Only treat trailing text as a new token when the pattern ended at a
        // word boundary (space-suffixed pattern, whitespace, or end of string).
        // Otherwise "every mon" would match "every monday" and append the
        // leftover "day", yielding "every monday day".
        let endsAtBoundary = pattern.hasSuffix(" ")
          || range.upperBound == lower.endIndex
          || lower[range.upperBound].isWhitespace
        if endsAtBoundary {
          let after = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespaces)
          if !after.isEmpty && !after.contains(" ") {
            return rule + " " + after
          }
        }
        return rule
      }
    }

    // "in X days" → repeat every X days
    let intervalPattern = #"in (\d+) days?"#
    if let match = lower.range(of: intervalPattern, options: .regularExpression) {
      let nums = lower[match].components(separatedBy: " ").compactMap { Int($0) }
      if let n = nums.first { return "every \(n) days" }
    }

    return nil
  }

  // ─── Private helpers ──────────────────────────────────────────────────────

  private static func parseRelative(_ s: String, relativeTo now: Date, calendar: Calendar) -> Date? {
    switch s {
    case "today": return now
    case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: now)
    case "tonight": return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now)
    default: return nil
    }
  }

  private static func parseWeekday(_ s: String, relativeTo now: Date, calendar: Calendar) -> Date? {
    let dayMap: [String: Int] = [
      "sunday": 1, "sun": 1,
      "monday": 2, "mon": 2,
      "tuesday": 3, "tue": 3,
      "wednesday": 4, "wed": 4,
      "thursday": 5, "thu": 5,
      "friday": 6, "fri": 6,
      "saturday": 7, "sat": 7,
    ]

    let lower = s.trimmingCharacters(in: .whitespaces)
    for (name, weekday) in dayMap {
      if lower == name || lower == "next \(name)" {
        return nextDate(for: weekday, after: now, calendar: calendar)
      }
    }
    return nil
  }

  private static func parseInterval(_ s: String, relativeTo now: Date) -> Date? {
    let pattern = #"in (\d+) (day|week|month)s?"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          match.numberOfRanges == 3,
          let countRange = Range(match.range(at: 1), in: s),
          let count = Int(s[countRange]),
          let unitRange = Range(match.range(at: 2), in: s) else { return nil }

    let unit = String(s[unitRange])
    let calendar = Calendar.current

    switch unit {
    case "day": return calendar.date(byAdding: .day, value: count, to: now)
    case "week": return calendar.date(byAdding: .weekOfYear, value: count, to: now)
    case "month": return calendar.date(byAdding: .month, value: count, to: now)
    default: return nil
    }
  }

  private static func parseAbsolute(_ s: String, calendar: Calendar) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")

    let formats = [
      "yyyy-MM-dd",
      "MMMM d",
      "MMM d",
      "MMMM d, yyyy",
      "MM/dd/yyyy",
      "dd/MM/yyyy",
    ]

    for format in formats {
      formatter.dateFormat = format
      if let date = formatter.date(from: s.trimmingCharacters(in: .whitespaces)) {
        return date
      }
    }
    return nil
  }

  private static func nextDate(for weekday: Int, after date: Date, calendar: Calendar) -> Date? {
    let currentWeekday = calendar.component(.weekday, from: date)
    var daysToAdd = weekday - currentWeekday
    if daysToAdd <= 0 { daysToAdd += 7 }
    return calendar.date(byAdding: .day, value: daysToAdd, to: date)
  }
}

/// Pure date arithmetic for task recurrence. Kept beside the date utilities
/// because the lightweight core test target includes this file without the
/// full SwiftData-backed task model.
enum RecurrenceDateCalculator {
  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
  }()

  static func nextDate(completedOn: String,
                       scheduled: String?,
                       logicalScheduled: String? = nil,
                       unit: String,
                       interval: Int,
                       afterCompletion: Bool) -> String? {
    guard let completedDate = formatter.date(from: String(completedOn.prefix(10))) else {
      return nil
    }
    let anchor = afterCompletion
      ? completedDate
      : ((logicalScheduled ?? scheduled).flatMap {
          formatter.date(from: String($0.prefix(10)))
        } ?? completedDate)
    let component: Calendar.Component
    switch unit {
    case "day": component = .day
    case "week": component = .weekOfYear
    case "month": component = .month
    default: return nil
    }
    let step = max(1, interval)
    let calendar = Calendar.current
    // Month-end is only preserved on a FIXED schedule, where the anchor is the
    // previous scheduled date and the error compounds. An after-completion rule
    // anchors on whatever day you happened to tick the box, so snapping there
    // would invent a month-end intent the user never expressed.
    let keepMonthEnd = !afterCompletion
    guard var next = advance(anchor, by: step, component, calendar, keepMonthEnd: keepMonthEnd) else {
      return nil
    }
    if !afterCompletion {
      // A task scheduled long ago (or a corrupt date) must not spin here.
      var guardRail = 0
      while next <= completedDate {
        guardRail += 1
        guard guardRail <= 10_000,
              let advanced = advance(next, by: step, component, calendar, keepMonthEnd: keepMonthEnd) else {
          return nil
        }
        next = advanced
      }
    }
    return formatter.string(from: next)
  }

  /// Adds `step` units to `date`.
  ///
  /// For month steps this preserves a month-end anchor: `byAdding: .month`
  /// alone clamps Jan 31 → Feb 28, and because the next occurrence re-anchors
  /// on that stored date the rule then walks Mar 28 → Apr 28 and never returns
  /// to month-end. Snapping a last-day-of-month anchor to the last day of the
  /// target month makes the chain stable (Jan 31 → Feb 28 → Mar 31 → Apr 30).
  /// The trade-off is deliberate: a fixed monthly rule anchored on Feb 28 is
  /// read as "month-end", because the repeat picker offers no day-of-month.
  private static func advance(_ date: Date,
                              by step: Int,
                              _ component: Calendar.Component,
                              _ calendar: Calendar,
                              keepMonthEnd: Bool) -> Date? {
    guard let next = calendar.date(byAdding: component, value: step, to: date) else { return nil }
    guard component == .month, keepMonthEnd, isLastDayOfMonth(date, calendar),
          let range = calendar.range(of: .day, in: .month, for: next) else { return next }
    var parts = calendar.dateComponents([.year, .month, .day], from: next)
    parts.day = range.upperBound - 1
    return calendar.date(from: parts) ?? next
  }

  private static func isLastDayOfMonth(_ date: Date, _ calendar: Calendar) -> Bool {
    guard let range = calendar.range(of: .day, in: .month, for: date) else { return false }
    return calendar.component(.day, from: date) == range.upperBound - 1
  }

  static func occurrenceID(sourceTaskID: String, scheduled: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in "\(sourceTaskID)|\(scheduled)".utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1099511628211
    }
    return "recur-\(String(format: "%016llx", hash))"
  }
}
