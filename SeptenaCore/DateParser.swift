import Foundation
import SeptenaSharedCore

// ─── Natural Language Date Parser ─────────────────────────────────────────────

/// The ONE typed-date parser. Every surface that turns typed text into a day
/// goes through `parse` — the Septena date popover and anything else — so
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
  /// Accepts English, Brazilian Portuguese, Dutch, French, German, Italian, and Spanish
  /// relative dates, weekday names and abbreviations, "+N" (days), "+Nd" /
  /// "+Nw" / "+Nm", month-day in either order (optional year, commas ignored),
  /// ISO "yyyy-mm-dd", and localized numeric dates. Month and weekday names
  /// match all supported locales and the current locale.
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
    case "today", "tod", "tdy", "now", "tonight",
         "hoje", "hj", "agora", "hoje a noite",
         "vandaag", "nu", "vanavond",
         "aujourd'hui", "aujourd’hui", "maintenant", "ce soir",
         "heute", "heute abend", "jetzt",
         "oggi", "adesso", "stasera",
         "hoy", "ahora", "esta noche":
      return start
    case "tomorrow", "tom", "tmr", "tmrw", "tmw", "amanha", "morgen", "demain", "manana", "domani":
      return add(1, .day)
    case "day after tomorrow", "depois de amanha", "overmorgen", "ubermorgen", "dopodomani", "dopo domani",
         "apres-demain", "pasado manana":
      return add(2, .day)
    default: break
    }

    // "+3", "+3d", "+2w", "+1m"
    if text.hasPrefix("+") {
      return relative(String(text.dropFirst()).replacingOccurrences(of: " ", with: ""),
                      add: add)
    }

    // "in 3 days", "in 2 weeks", "in 1 month", "in 3d"
    for prefix in ["in ", "em ", "en ", "tra ", "fra "] where text.hasPrefix(prefix) {
      return relative(String(text.dropFirst(prefix.count)).replacingOccurrences(of: " ", with: ""),
                      add: add)
    }
    for prefix in ["over ", "dans "] where text.hasPrefix(prefix) {
      return relative(String(text.dropFirst(prefix.count)).replacingOccurrences(of: " ", with: ""),
                      add: add)
    }

    // Weekday, optionally "next ..."
    var weekdayText: String
    let weekdayPrefixes = [
      "next ", "proximo ", "proxima ", "volgende ", "prochain ", "prochaine ",
      "nachsten ", "kommenden ", "kommende ", "prossimo ", "prossima ",
      "prossimi ", "prossime ",
    ]
    weekdayText = weekdayPrefixes.first(where: { text.hasPrefix($0) })
      .map { String(text.dropFirst($0.count)) } ?? text
    if weekdayText == text {
      for suffix in [" prochain", " prochaine", " que viene"] where text.hasSuffix(suffix) {
        weekdayText = String(text.dropLast(suffix.count))
        break
      }
    }
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

    // Numeric dates follow day-first order for pt-BR, Dutch, French, German, Italian,
    // and Spanish; other locales try US order first, then day-first.
    let slash = text.split(separator: "/")
    if slash.count == 3, slash[2].count == 4,
       let first = Int(slash[0]), let second = Int(slash[1]), let year = Int(slash[2]) {
      let localeID = (calendar.locale?.identifier ?? Locale.current.identifier)
        .replacingOccurrences(of: "-", with: "_")
        .lowercased()
      let dayFirstOrder = ["pt_br", "nl", "fr", "de", "it", "es"].contains {
        localeID.hasPrefix($0)
      }
      let month = dayFirstOrder ? second : first
      let day = dayFirstOrder ? first : second
      return validDate(year: year, month: month, day: day, calendar: calendar)
        ?? validDate(year: year, month: dayFirstOrder ? first : second,
                     day: dayFirstOrder ? second : first, calendar: calendar)
    }

    // Month-day in either order, optional year: "dec 4", "4 dec 2027".
    let words = text.split(separator: " ").map(String.init).filter { $0 != "de" }
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
      .folding(options: .diacriticInsensitive, locale: .current)

    // Localized interval phrases map to the canonical English recurrence
    // rules consumed by the shared core.
    let intervalPatterns = [
      #"(?:elke|cada|alle) (\d+) (dagen?|weken?|maanden?|jaren?|dias?|semanas?|meses?|anos?|tage?n?|wochen?|monate?n?|jahre?n?)"#,
      #"(?:tous les|toutes les) (\d+) (jours?|semaines?|mois|ans?)"#,
      #"a cada (\d+) (dias?|semanas?|meses?|anos?)"#,
      #"ogni (\d+) (giorn[oi]|settiman[ae]|mes[ei]|ann[oi])"#,
    ]
    for pattern in intervalPatterns {
      if let match = lower.range(of: pattern, options: .regularExpression) {
        let parts = lower[match].split(separator: " ")
        guard let count = parts.compactMap({ Int($0) }).first,
              let unit = parts.last else { continue }
        let unitText = String(unit)
        let canonical: String
        if unitText.hasPrefix("dag") || unitText.hasPrefix("dia")
          || unitText.hasPrefix("jour") || unitText.hasPrefix("tag")
          || unitText.hasPrefix("giorn") {
          canonical = "days"
        } else if unitText.hasPrefix("week") || unitText.hasPrefix("semana")
          || unitText.hasPrefix("settim")
          || unitText.hasPrefix("semaine") || unitText.hasPrefix("woch") {
          canonical = "weeks"
        } else if unitText.hasPrefix("maand") || unitText.hasPrefix("mes")
          || unitText.hasPrefix("monat") || unitText.hasPrefix("mois") {
          canonical = "months"
        } else {
          canonical = "years"
        }
        return "every \(count) \(canonical)"
      }
    }

    let patterns = [
      ("chaque lundi", "every monday"),
      ("chaque mardi", "every tuesday"),
      ("chaque mercredi", "every wednesday"),
      ("chaque jeudi", "every thursday"),
      ("chaque vendredi", "every friday"),
      ("chaque samedi", "every saturday"),
      ("chaque dimanche", "every sunday"),
      ("tous les lundis", "every monday"),
      ("tous les mardis", "every tuesday"),
      ("tous les mercredis", "every wednesday"),
      ("tous les jeudis", "every thursday"),
      ("tous les vendredis", "every friday"),
      ("tous les samedis", "every saturday"),
      ("tous les dimanches", "every sunday"),
      ("jeden montag", "every monday"),
      ("jeden dienstag", "every tuesday"),
      ("jeden mittwoch", "every wednesday"),
      ("jeden donnerstag", "every thursday"),
      ("jeden freitag", "every friday"),
      ("jeden samstag", "every saturday"),
      ("jeden sonntag", "every sunday"),
      ("cada lunes", "every monday"),
      ("cada martes", "every tuesday"),
      ("cada miercoles", "every wednesday"),
      ("cada jueves", "every thursday"),
      ("cada viernes", "every friday"),
      ("cada sabado", "every saturday"),
      ("cada domingo", "every sunday"),
      ("todos los lunes", "every monday"),
      ("todos los martes", "every tuesday"),
      ("todos los miercoles", "every wednesday"),
      ("todos los jueves", "every thursday"),
      ("todos los viernes", "every friday"),
      ("todos los sabados", "every saturday"),
      ("todos los domingos", "every sunday"),
      ("toda segunda-feira", "every monday"),
      ("toda terca-feira", "every tuesday"),
      ("toda quarta-feira", "every wednesday"),
      ("toda quinta-feira", "every thursday"),
      ("toda sexta-feira", "every friday"),
      ("todo sabado", "every saturday"),
      ("todo domingo", "every sunday"),
      ("tous les jours", "every day"),
      ("chaque jour", "every day"),
      ("toutes les semaines", "every week"),
      ("chaque semaine", "every week"),
      ("tous les mois", "every month"),
      ("chaque mois", "every month"),
      ("tous les ans", "every year"),
      ("chaque annee", "every year"),
      ("jeden tag", "every day"),
      ("jede woche", "every week"),
      ("jeden monat", "every month"),
      ("jedes jahr", "every year"),
      ("cada dia", "every day"),
      ("cada semana", "every week"),
      ("cada mes", "every month"),
      ("cada ano", "every year"),
      ("ogni lunedi", "every monday"),
      ("ogni martedi", "every tuesday"),
      ("ogni mercoledi", "every wednesday"),
      ("ogni giovedi", "every thursday"),
      ("ogni venerdi", "every friday"),
      ("ogni sabato", "every saturday"),
      ("ogni domenica", "every sunday"),
      ("ogni giorno", "every day"),
      ("ogni settimana", "every week"),
      ("ogni mese", "every month"),
      ("ogni anno", "every year"),
      ("todo dia", "every day"),
      ("toda semana", "every week"),
      ("todo mes", "every month"),
      ("todo ano", "every year"),
      ("diariamente", "daily"),
      ("semanalmente", "weekly"),
      ("mensualmente", "monthly"),
      ("anualmente", "yearly"),
      ("elke maandag", "every monday"),
      ("elke dinsdag", "every tuesday"),
      ("elke woensdag", "every wednesday"),
      ("elke donderdag", "every thursday"),
      ("elke vrijdag", "every friday"),
      ("elke zaterdag", "every saturday"),
      ("elke zondag", "every sunday"),
      ("elke dag", "every day"),
      ("elke week", "every week"),
      ("elke maand", "every month"),
      ("elk jaar", "every year"),
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
      ("elke ", "every "), // catch-all
      ("cada ", "every "), // catch-all for Spanish recurrence phrases
      ("chaque ", "every "), // catch-all for French recurrence phrases
      ("jeden ", "every "), // catch-all for German recurrence phrases
      ("jede ", "every "),
      ("jedes ", "every "),
      ("ogni ", "every "), // catch-all for Italian recurrence phrases
      ("dagelijks", "daily"),
      ("wekelijks", "weekly"),
      ("maandelijks", "monthly"),
      ("jaarlijks", "yearly"),
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

    // "in X days" / "over X dagen" and localized equivalents → repeat every X days.
    let intervalPattern = #"(?:in|over|em|en|dans|tra|fra) (\d+) (?:days?|dagen?|dias?|jours?|tage?n?|giorn[oi])"#
    if let match = lower.range(of: intervalPattern, options: .regularExpression) {
      let nums = lower[match].components(separatedBy: " ").compactMap { Int($0) }
      if let n = nums.first { return "every \(n) days" }
    }

    return nil
  }

  // ─── Private helpers ──────────────────────────────────────────────────────

  /// "3", "3d", "3days", "2w", "2weeks", "1m", "1month" and supported
  /// locale day / week / month names → offset from today.
  private static func relative(_ text: String, add: (Int, Calendar.Component) -> Date?) -> Date? {
    let digits = text.prefix { $0.isNumber }
    guard let count = Int(digits) else { return nil }
    let unit = text.dropFirst(digits.count)
    switch unit {
    case "", "d", "day", "days", "dia", "dias", "dag", "dagen", "jour", "jours", "giorno", "giorni",
         "tag", "tage", "tagen":
      return add(count, .day)
    case "w", "wk", "wks", "week", "weeks", "sem", "semana", "semanas", "weken", "settimana", "settimane",
         "semaine", "semaines", "woche", "wochen":
      return add(count * 7, .day)
    case "m", "mo", "month", "months", "mes", "meses", "maand", "maanden", "mois", "mese", "mesi",
         "monat", "monate", "monaten":
      return add(count, .month)
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
  private static let portugueseWeekdays = ["domingo", "segunda-feira", "terca-feira",
                                           "quarta-feira", "quinta-feira", "sexta-feira",
                                           "sabado"]
  private static let dutchWeekdays = ["zondag", "maandag", "dinsdag", "woensdag",
                                      "donderdag", "vrijdag", "zaterdag"]
  private static let frenchWeekdays = ["dimanche", "lundi", "mardi", "mercredi",
                                       "jeudi", "vendredi", "samedi"]
  private static let germanWeekdays = ["sonntag", "montag", "dienstag", "mittwoch",
                                       "donnerstag", "freitag", "samstag"]
  private static let spanishWeekdays = ["domingo", "lunes", "martes", "miercoles",
                                        "jueves", "viernes", "sabado"]
  private static let italianWeekdays = ["domenica", "lunedi", "martedi", "mercoledi",
                                        "giovedi", "venerdi", "sabato"]
  private static let englishMonths = ["january", "february", "march", "april", "may", "june",
                                      "july", "august", "september", "october", "november",
                                      "december"]
  private static let portugueseMonths = ["janeiro", "fevereiro", "marco", "abril", "maio",
                                         "junho", "julho", "agosto", "setembro", "outubro",
                                         "novembro", "dezembro"]
  private static let dutchMonths = ["januari", "februari", "maart", "april", "mei", "juni",
                                    "juli", "augustus", "september", "oktober", "november",
                                    "december"]
  private static let frenchMonths = ["janvier", "fevrier", "mars", "avril", "mai", "juin",
                                     "juillet", "aout", "septembre", "octobre", "novembre",
                                     "decembre"]
  private static let germanMonths = ["januar", "februar", "marz", "april", "mai", "juni",
                                     "juli", "august", "september", "oktober", "november",
                                     "dezember"]
  private static let spanishMonths = ["enero", "febrero", "marzo", "abril", "mayo", "junio",
                                      "julio", "agosto", "septiembre", "octubre", "noviembre",
                                      "diciembre"]
  private static let italianMonths = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno",
                                      "luglio", "agosto", "settembre", "ottobre", "novembre",
                                      "dicembre"]

  /// 1 = Sunday … 7 = Saturday (Calendar's numbering). A word matches a full
  /// name, or any prefix of at least three letters ("thu", "thurs").
  private static func weekdayNumber(_ word: String, calendar: Calendar) -> Int? {
    let localized = calendar.weekdaySymbols.map { fold($0) }
    for names in [englishWeekdays, portugueseWeekdays, dutchWeekdays, frenchWeekdays,
                  germanWeekdays, spanishWeekdays, italianWeekdays, localized] {
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
    for names in [englishMonths, portugueseMonths, dutchMonths, frenchMonths,
                  germanMonths, spanishMonths, italianMonths, localized] {
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
