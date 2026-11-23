import Foundation
import SeptenaSharedCore

// ─── Natural Language Date Parser ─────────────────────────────────────────────

/// The ONE typed-date parser. Every surface that turns typed text into a day
/// goes through `parse` — the Septask date popover and anything else — so
/// "tom" can't mean tomorrow in one place and nothing in another.
///
/// Relative to the `today` the caller passes, never the wall clock: app
/// callers pass DayClock's today (`DayClock.today` / `SeptenaDate.today`) so
/// time travel and day rollover hold. This file also compiles into the
/// SeptenaCoreTests bundle, which has no DayClock — hence the parameter
/// instead of reading DayClock here.
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

/// Task recurrence arithmetic. The rule lives once, in the shared Rust core
/// (`core/crates/septena-core/src/recurrence.rs`, ADR 0025); this enum only
/// adapts Swift values to it. Vectors: `registry/conformance/recurrence.json`.
/// The backend's `backend/src/recurrence.ts` is the one copy left (C3, #249).
enum RecurrenceDateCalculator {
  static func nextDate(completedOn: String,
                       scheduled: String?,
                       logicalScheduled: String? = nil,
                       unit: String,
                       interval: Int,
                       afterCompletion: Bool,
                       weekdays: [Int]? = nil,
                       monthDay: Int? = nil,
                       ordinalWeekday: RecurrenceOrdinalWeekday? = nil) -> String? {
    let rule = SeptenaSharedCore.RecurrenceRule(
      unit: unit,
      interval: Int32(clamping: interval),
      afterCompletion: afterCompletion,
      weekdays: weekdays?.map { Int32(clamping: $0) },
      monthDay: monthDay.map { Int32(clamping: $0) },
      ordinalWeekday: ordinalWeekday.map {
        SeptenaSharedCore.OrdinalWeekday(ordinal: Int32(clamping: $0.ordinal),
                                         weekday: Int32(clamping: $0.weekday))
      })
    return SeptenaSharedCore.nextScheduledDate(completedOn: completedOn,
                                               scheduled: scheduled,
                                               logicalScheduled: logicalScheduled,
                                               rule: rule)
  }

  static func occurrenceID(sourceTaskID: String, scheduled: String) -> String {
    SeptenaSharedCore.occurrenceId(sourceTaskId: sourceTaskID, scheduled: scheduled)
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

/// Timed-reminder arithmetic and arming rules. The rules live once, in the
/// shared Rust core (`core/crates/septena-core/src/reminders.rs`, ADR 0025);
/// this enum only adapts Swift values to it. Vectors:
/// `registry/conformance/reminders.json`. The backend's
/// `backend/src/reminders.ts` is the one copy left (C3, #249).
enum TaskReminderRules {
  static func shiftForRecurrence(sourceReminderAt: String?,
                                 sourceScheduled: String?,
                                 nextScheduled: String?) -> String? {
    SeptenaSharedCore.shiftReminderForRecurrence(sourceReminderAt: sourceReminderAt,
                                                 sourceScheduled: sourceScheduled,
                                                 nextScheduled: nextScheduled)
  }

  static func shiftOnReschedule(reminderAt: String?,
                                oldScheduled: String?,
                                newScheduled: String?) -> String? {
    SeptenaSharedCore.shiftReminderOnReschedule(reminderAt: reminderAt,
                                                oldScheduled: oldScheduled,
                                                newScheduled: newScheduled)
  }

  static func shouldArm(status: String,
                        isDeleted: Bool,
                        isHeading: Bool,
                        isUnratifiedProposal: Bool,
                        reminderAt: String?,
                        reminderDismissedAt: String?) -> Bool {
    SeptenaSharedCore.shouldArmReminder(input: SeptenaSharedCore.ReminderArmInput(
      status: status,
      isDeleted: isDeleted,
      isHeading: isHeading,
      isUnratifiedProposal: isUnratifiedProposal,
      reminderAt: reminderAt,
      reminderDismissedAt: reminderDismissedAt))
  }
}
