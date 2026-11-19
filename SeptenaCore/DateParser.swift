import Foundation

// ─── Natural Language Date Parser ─────────────────────────────────────────────

/// The ONE typed-date parser. Every surface that turns typed text into a day
/// goes through `parse` — the Septask date popover and anything else — so
/// "tom" can't mean tomorrow in one place and nothing in another.
///
/// Relative to the `today` the caller passes, never the wall clock: app
/// callers pass DayClock's today (`DayClock.today` / `SeptenaDate.today`) so
/// time travel and day rollover hold. This file also compiles into the watch
/// targets and the Foundation-only test bundle, which have no DayClock — hence
/// the parameter instead of reading DayClock here.
struct SeptenaDateParser {
  /// Parse what a person types into a day. Day precision only; returns the
  /// start of that day.
  ///
  /// Accepts: today / tod / tonight, tomorrow / tom / tmr / tmrw, weekday names
  /// and their abbreviations (the next occurrence after today; "next fri"
  /// too), "in N days / weeks / months", "+N" (days), "+Nd" / "+Nw" / "+Nm",
  /// month-day in either order ("dec 4", "4 dec", optional year, commas
  /// ignored: "March 15, 2027"), ISO "yyyy-mm-dd", and "mm/dd/yyyy" (then
  /// "dd/mm/yyyy" when the first reading is not a date). Month and weekday
  /// names match English and the current locale.
  static func parse(_ raw: String, today: Date, calendar: Calendar = .current) -> Date? {
    let text = raw.lowercased()
      .folding(options: .diacriticInsensitive, locale: .current)
      .replacingOccurrences(of: ",", with: " ")
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
    guard !text.isEmpty else { return nil }
    let start = calendar.startOfDay(for: today)
    func add(_ value: Int, _ component: Calendar.Component) -> Date? {
      calendar.date(byAdding: component, value: value, to: start)
    }

    switch text {
    case "today", "tod", "tdy", "now", "tonight": return start
    case "tomorrow", "tom", "tmr", "tmrw", "tmw": return add(1, .day)
    default: break
    }

    // "+3", "+3d", "+2w", "+1m"
    if text.hasPrefix("+") {
      return relative(String(text.dropFirst()).replacingOccurrences(of: " ", with: ""),
                      add: add)
    }

    // "in 3 days", "in 2 weeks", "in 1 month", "in 3d"
    if text.hasPrefix("in ") {
      return relative(String(text.dropFirst(3)).replacingOccurrences(of: " ", with: ""),
                      add: add)
    }

    // Weekday, optionally "next ..."
    let weekdayText = text.hasPrefix("next ") ? String(text.dropFirst(5)) : text
    if let weekday = weekdayNumber(weekdayText, calendar: calendar) {
      let current = calendar.component(.weekday, from: start)
      var delta = (weekday - current + 7) % 7
      if delta == 0 { delta = 7 }
      return add(delta, .day)
    }

    // ISO yyyy-mm-dd
    let iso = text.split(separator: "-")
    if iso.count == 3, iso[0].count == 4,
       let year = Int(iso[0]), let month = Int(iso[1]), let day = Int(iso[2]) {
      return validDate(year: year, month: month, day: day, calendar: calendar)
    }

    // mm/dd/yyyy, then dd/mm/yyyy
    let slash = text.split(separator: "/")
    if slash.count == 3, slash[2].count == 4,
       let first = Int(slash[0]), let second = Int(slash[1]), let year = Int(slash[2]) {
      return validDate(year: year, month: first, day: second, calendar: calendar)
        ?? validDate(year: year, month: second, day: first, calendar: calendar)
    }

    // Month-day in either order, optional year: "dec 4", "4 dec 2027".
    let words = text.split(separator: " ").map(String.init)
    guard words.count == 2 || words.count == 3 else { return nil }
    var month: Int?
    var day: Int?
    if let m = monthNumber(words[0], calendar: calendar), let d = Int(words[1]) {
      month = m; day = d
    } else if let d = Int(words[0]), let m = monthNumber(words[1], calendar: calendar) {
      month = m; day = d
    }
    guard let month, let day else { return nil }
    if words.count == 3 {
      guard let year = Int(words[2]) else { return nil }
      return validDate(year: year, month: month, day: day, calendar: calendar)
    }
    // No year: the next time that day comes round, today included.
    let thisYear = calendar.component(.year, from: start)
    if let date = validDate(year: thisYear, month: month, day: day, calendar: calendar),
       date >= start {
      return date
    }
    return validDate(year: thisYear + 1, month: month, day: day, calendar: calendar)
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

  /// "3", "3d", "3days", "2w", "2weeks", "1m", "1month" → offset from today.
  private static func relative(_ text: String, add: (Int, Calendar.Component) -> Date?) -> Date? {
    let digits = text.prefix { $0.isNumber }
    guard let count = Int(digits) else { return nil }
    let unit = text.dropFirst(digits.count)
    switch unit {
    case "", "d", "day", "days": return add(count, .day)
    case "w", "wk", "wks", "week", "weeks": return add(count * 7, .day)
    case "m", "mo", "month", "months": return add(count, .month)
    default: return nil
    }
  }

  private static func validDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
    let components = DateComponents(year: year, month: month, day: day)
    guard components.isValidDate(in: calendar) else { return nil }
    return calendar.date(from: components)
  }

  private static let englishWeekdays = ["sunday", "monday", "tuesday", "wednesday",
                                        "thursday", "friday", "saturday"]
  private static let englishMonths = ["january", "february", "march", "april", "may", "june",
                                      "july", "august", "september", "october", "november",
                                      "december"]

  /// 1 = Sunday … 7 = Saturday (Calendar's numbering). A word matches a full
  /// name, or any prefix of at least three letters ("thu", "thurs").
  private static func weekdayNumber(_ word: String, calendar: Calendar) -> Int? {
    let localized = calendar.weekdaySymbols.map { fold($0) }
    for names in [englishWeekdays, localized] {
      if let index = names.firstIndex(where: { word.count >= 3 && $0.hasPrefix(word) }) {
        return index + 1
      }
    }
    return nil
  }

  /// 1 = January … 12. Full name or a prefix of at least three letters.
  private static func monthNumber(_ word: String, calendar: Calendar) -> Int? {
    let cleaned = word.hasSuffix(".") ? String(word.dropLast()) : word
    let localized = calendar.monthSymbols.map { fold($0) }
    for names in [englishMonths, localized] {
      if let index = names.firstIndex(where: { cleaned.count >= 3 && $0.hasPrefix(cleaned) }) {
        return index + 1
      }
    }
    return nil
  }

  private static func fold(_ text: String) -> String {
    text.lowercased().folding(options: .diacriticInsensitive, locale: .current)
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
