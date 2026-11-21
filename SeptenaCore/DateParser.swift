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

/// Ordinal weekday rule for fixed monthly/yearly recurrences (e.g. last Friday:
/// `ordinal = -1, weekday = 6`). `weekday` uses `1 = Sunday ... 7 = Saturday`,
/// matching Foundation `Calendar.component(.weekday)` and JS `getUTCDay() + 1`.
struct RecurrenceOrdinalWeekday: Codable, Hashable, Sendable {
  var ordinal: Int   // 1..4 or -1 (last)
  var weekday: Int   // 1 = Sunday ... 7 = Saturday
}

/// Pure date arithmetic for task recurrence. Kept beside the date utilities
/// because the lightweight core test target includes this file without the
/// full SwiftData-backed task model.
/// LOCKSTEP with `backend/src/recurrence.ts` and `registry/conformance/recurrence.json`.
enum RecurrenceDateCalculator {
  private struct CivilDate: Comparable {
    let y: Int
    let m: Int // 1..12
    let d: Int // 1..31

    static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
      if lhs.y != rhs.y { return lhs.y < rhs.y }
      if lhs.m != rhs.m { return lhs.m < rhs.m }
      return lhs.d < rhs.d
    }
  }

  private static let utcCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
  }()

  private static func parseYMD(_ ymd: String) -> CivilDate? {
    let prefix = String(ymd.prefix(10))
    let parts = prefix.split(separator: "-")
    guard parts.count == 3,
          let y = Int(parts[0]),
          let m = Int(parts[1]),
          let d = Int(parts[2]),
          (1...12).contains(m),
          (1...31).contains(d) else { return nil }
    return CivilDate(y: y, m: m, d: d)
  }

  private static func formatYMD(_ p: CivilDate) -> String {
    String(format: "%04d-%02d-%02d", p.y, p.m, p.d)
  }

  private static func toUTCDate(_ p: CivilDate) -> Date? {
    utcCalendar.date(from: DateComponents(year: p.y, month: p.m, day: p.d))
  }

  private static func fromUTCDate(_ date: Date) -> CivilDate {
    let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
    return CivilDate(y: c.year ?? 1970, m: c.month ?? 1, d: c.day ?? 1)
  }

  private static func daysInMonth(year: Int, month: Int) -> Int {
    guard let d = utcCalendar.date(from: DateComponents(year: year, month: month, day: 1)),
          let range = utcCalendar.range(of: .day, in: .month, for: d) else { return 30 }
    return range.upperBound - 1
  }

  private static func addDays(_ p: CivilDate, _ n: Int) -> CivilDate? {
    guard let d = toUTCDate(p),
          let next = utcCalendar.date(byAdding: .day, value: n, to: d) else { return nil }
    return fromUTCDate(next)
  }

  /// 1 = Sunday ... 7 = Saturday.
  private static func weekdayOf(_ p: CivilDate) -> Int {
    guard let d = toUTCDate(p) else { return 1 }
    return utcCalendar.component(.weekday, from: d)
  }

  /// ISO Monday-first offset: Mon=0, Tue=1, ..., Sat=5, Sun=6.
  private static func isoOffset(_ weekday: Int) -> Int {
    (weekday + 5) % 7
  }

  private static func addMonthsRaw(year: Int, month: Int, delta: Int) -> (Int, Int) {
    let total = year * 12 + (month - 1) + delta
    let y = Int(floor(Double(total) / 12.0))
    let m = ((total % 12) + 12) % 12 + 1
    return (y, m)
  }

  private static func addMonths(_ p: CivilDate, _ delta: Int, keepMonthEnd: Bool) -> CivilDate {
    let (y, m) = addMonthsRaw(year: p.y, month: p.m, delta: delta)
    let dim = daysInMonth(year: y, month: m)
    if keepMonthEnd && p.d == daysInMonth(year: p.y, month: p.m) {
      return CivilDate(y: y, m: m, d: dim)
    }
    return CivilDate(y: y, m: m, d: min(p.d, dim))
  }

  private static func resolveMonthDay(year: Int, month: Int, monthDay: Int) -> CivilDate? {
    let dim = daysInMonth(year: year, month: month)
    if monthDay == -1 { return CivilDate(y: year, m: month, d: dim) }
    if (1...31).contains(monthDay) { return CivilDate(y: year, m: month, d: min(monthDay, dim)) }
    return nil
  }

  private static func resolveOrdinalWeekday(year: Int, month: Int, ow: RecurrenceOrdinalWeekday) -> CivilDate? {
    guard (1...7).contains(ow.weekday),
          ow.ordinal == -1 || (1...4).contains(ow.ordinal) else { return nil }
    let dim = daysInMonth(year: year, month: month)
    if ow.ordinal == -1 {
      let lastWd = weekdayOf(CivilDate(y: year, m: month, d: dim))
      let back = (lastWd - ow.weekday + 7) % 7
      return CivilDate(y: year, m: month, d: dim - back)
    }
    let firstWd = weekdayOf(CivilDate(y: year, m: month, d: 1))
    let delta = (ow.weekday - firstWd + 7) % 7
    let day = 1 + delta + (ow.ordinal - 1) * 7
    guard day <= dim else { return nil }
    return CivilDate(y: year, m: month, d: day)
  }

  private static func normalizeIsoWeekdays(_ weekdays: [Int]?) -> [Int] {
    guard let weekdays, !weekdays.isEmpty else { return [] }
    let unique = Set(weekdays.filter { (1...7).contains($0) })
    return unique.sorted { isoOffset($0) < isoOffset($1) }
  }

  private static func advanceWeeklyByWeekdays(_ p: CivilDate, step: Int, isoOrderedWeekdays: [Int]) -> CivilDate? {
    let curOffset = isoOffset(weekdayOf(p))
    for w in isoOrderedWeekdays {
      let off = isoOffset(w)
      if off > curOffset {
        return addDays(p, off - curOffset)
      }
    }
    guard let weekMonday = addDays(p, -curOffset),
          let nextWeekMonday = addDays(weekMonday, step * 7),
          let first = isoOrderedWeekdays.first else { return nil }
    return addDays(nextWeekMonday, isoOffset(first))
  }

  static func nextDate(completedOn: String,
                       scheduled: String?,
                       logicalScheduled: String? = nil,
                       unit: String,
                       interval: Int,
                       afterCompletion: Bool,
                       weekdays: [Int]? = nil,
                       monthDay: Int? = nil,
                       ordinalWeekday: RecurrenceOrdinalWeekday? = nil) -> String? {
    guard let completed = parseYMD(completedOn) else { return nil }
    let anchor: CivilDate
    if afterCompletion {
      anchor = completed
    } else {
      anchor = (logicalScheduled ?? scheduled).flatMap(parseYMD) ?? completed
    }
    let step = max(1, interval)
    let isFixed = !afterCompletion
    let isoWeekdays = isFixed ? normalizeIsoWeekdays(weekdays) : []
    let fixedMonthDay = isFixed ? monthDay : nil
    let fixedOrdinal = isFixed ? ordinalWeekday : nil
    let keepMonthEnd = isFixed && fixedMonthDay == nil && fixedOrdinal == nil

    func advance(_ p: CivilDate) -> CivilDate? {
      switch unit {
      case "day":
        return addDays(p, step)
      case "week":
        if !isoWeekdays.isEmpty {
          return advanceWeeklyByWeekdays(p, step: step, isoOrderedWeekdays: isoWeekdays)
        }
        return addDays(p, step * 7)
      case "month":
        if let ow = fixedOrdinal {
          let (y, m) = addMonthsRaw(year: p.y, month: p.m, delta: step)
          return resolveOrdinalWeekday(year: y, month: m, ow: ow)
        }
        if let md = fixedMonthDay {
          let (y, m) = addMonthsRaw(year: p.y, month: p.m, delta: step)
          return resolveMonthDay(year: y, month: m, monthDay: md)
        }
        return addMonths(p, step, keepMonthEnd: keepMonthEnd)
      case "year":
        let y = p.y + step
        let m = p.m
        if let ow = fixedOrdinal {
          return resolveOrdinalWeekday(year: y, month: m, ow: ow)
        }
        if let md = fixedMonthDay {
          return resolveMonthDay(year: y, month: m, monthDay: md)
        }
        let dim = daysInMonth(year: y, month: m)
        return CivilDate(y: y, m: m, d: min(p.d, dim))
      default:
        return nil
      }
    }

    guard var next = advance(anchor) else { return nil }
    if !afterCompletion {
      var guardRail = 0
      while next <= completed {
        guardRail += 1
        guard guardRail <= 10_000, let advanced = advance(next) else { return nil }
        next = advanced
      }
    }
    return formatYMD(next)
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

// MARK: - Timed Task Reminders (docs/TIMED_REMINDERS_SPEC.md)

enum TaskReminderMode: String, Codable, Hashable, Sendable {
  case floating
  case fixed
}

/// Value representation of a task's timed reminder. Wraps the flat persisted
/// columns (`reminderAt`, `reminderMode`, `reminderSnoozedUntil`,
/// `reminderDismissedAt`) on `TaskEntity`.
struct TaskReminder: Codable, Hashable, Sendable {
  /// Wall-clock `YYYY-MM-DDTHH:MM` (floating) or UTC ISO-8601 `YYYY-MM-DDTHH:MM:SSZ` (fixed).
  var fireAt: String
  var mode: TaskReminderMode
  var snoozedUntil: String?
  var dismissedAt: String?

  enum CodingKeys: String, CodingKey {
    case fireAt = "reminder_at"
    case mode = "reminder_mode"
    case snoozedUntil = "reminder_snoozed_until"
    case dismissedAt = "reminder_dismissed_at"
  }

  init(fireAt: String,
       mode: TaskReminderMode = .floating,
       snoozedUntil: String? = nil,
       dismissedAt: String? = nil) {
    self.fireAt = fireAt
    self.mode = mode
    self.snoozedUntil = snoozedUntil
    self.dismissedAt = dismissedAt
  }
}

/// Pure timed-reminder arithmetic and arming rules.
/// LOCKSTEP with `backend/src/reminders.ts` and `registry/conformance/reminders.json`.
enum TaskReminderRules {
  private static let utcCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
  }()

  private static func parseYMD(_ ymd: String) -> Date? {
    let prefix = String(ymd.prefix(10))
    let parts = prefix.split(separator: "-")
    guard parts.count == 3,
          let y = Int(parts[0]),
          let m = Int(parts[1]),
          let d = Int(parts[2]),
          (1...12).contains(m),
          (1...31).contains(d) else { return nil }
    return utcCalendar.date(from: DateComponents(year: y, month: m, day: d))
  }

  private static func formatYMD(_ date: Date) -> String {
    let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
  }

  static func shiftForRecurrence(sourceReminderAt: String?,
                                 sourceScheduled: String?,
                                 nextScheduled: String?) -> String? {
    guard let src = sourceReminderAt,
          let nextDay = nextScheduled,
          src.count > 10 else { return nil }
    let idx = src.index(src.startIndex, offsetBy: 10)
    guard src[idx] == "T" else { return nil }
    let remDayStr = String(src[..<idx])
    let timeSuffix = String(src[idx...])
    guard let nextDate = parseYMD(nextDay) else { return nil }

    var offsetDays = 0
    if let sched = sourceScheduled,
       let remDate = parseYMD(remDayStr),
       let schedDate = parseYMD(sched) {
      offsetDays = utcCalendar.dateComponents([.day], from: schedDate, to: remDate).day ?? 0
    }
    guard let target = utcCalendar.date(byAdding: .day, value: offsetDays, to: nextDate) else {
      return nil
    }
    return formatYMD(target) + timeSuffix
  }

  static func shiftOnReschedule(reminderAt: String?,
                                oldScheduled: String?,
                                newScheduled: String?) -> String? {
    guard let rem = reminderAt else { return nil }
    guard let oldS = oldScheduled, let newS = newScheduled, rem.count > 10 else { return rem }
    let idx = rem.index(rem.startIndex, offsetBy: 10)
    guard rem[idx] == "T" else { return rem }
    let remDay = String(rem[..<idx])
    let oldDay = String(oldS.prefix(10))
    let newDay = String(newS.prefix(10))
    guard remDay == oldDay else { return rem }
    return newDay + String(rem[idx...])
  }

  static func shouldArm(status: String,
                        isDeleted: Bool,
                        isHeading: Bool,
                        isUnratifiedProposal: Bool,
                        reminderAt: String?,
                        reminderDismissedAt: String?) -> Bool {
    guard status == "open",
          !isDeleted,
          !isHeading,
          !isUnratifiedProposal,
          let rem = reminderAt, !rem.isEmpty,
          reminderDismissedAt == nil else { return false }
    return true
  }
}
