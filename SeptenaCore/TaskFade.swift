import Foundation

// Task fade rules, visual countdown, and weekly sweep schedule
// (`docs/TASK_FADE_SPEC.md` §4 & §5, ADR 0006).
//
// Pure Foundation so `SeptenaCoreTests` can test every boundary directly
// without a host app or SwiftData store. Both task lists — SwiftUI
// (`CheckableRow` / `TaskCheckboxModel`) and AppKit (`SeptaskKitTaskCell`) —
// read this single rule so they cannot drift.

enum TaskFade {
  /// Default untouched window before an open task fades (days).
  static let windowDays: Int = RegistryRules.fadeWindowDays
  /// Fade window in seconds.
  static let windowInterval: TimeInterval = Double(windowDays) * 24 * 60 * 60
  /// Grace period in seconds — a fresh task stays at full strength for its first day.
  static let graceInterval: TimeInterval = Double(RegistryRules.fadeGraceDays) * 24 * 60 * 60

  /// The faintest a fading row gets. Label ink at 0.55 on the light background
  /// stays above a 4.5:1 contrast ratio, so a faded title is still readable.
  static let minOpacity: Double = RegistryRules.fadeMinOpacity

  /// Shared UserDefaults key for the Settings toggle (`SettingsKey.tasksShowAging`).
  /// Absent → enabled by default (`docs/TASK_FADE_SPEC.md` §11).
  static let enabledDefaultsKey = "septena.tasks.showAging"

  /// Persisted timestamp of the last completed weekly sweep.
  static let lastSweepAtKey = "septena.fade.lastSweepAt"
  /// Persisted anchor (Sunday start-of-day) of a dismissed sweep banner so
  /// ignoring a sweep stays quiet until the next Sunday without dropping tasks.
  static let dismissedSweepWeekKey = "septena.fade.dismissedSweepWeek"

  /// Gregorian weekday for the weekly sweep (1 = Sunday, default per §5 & §11).
  static let sweepWeekday: Int = RegistryRules.fadeSweepWeekday

  /// Whether task fading (visual countdown + daily fade pass) is turned on.
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
  }

  /// Row content opacity for a fade fill (0…1, nil = not fading): full at
  /// 0, `minOpacity` at 1. Applied to the checkbox too; it stays tappable.
  static func rowOpacity(_ fill: Double?) -> Double {
    guard let fill, fill.isFinite, fill > 0 else { return 1 }
    return 1 - min(1, fill) * (1 - minOpacity)
  }

  // MARK: - Clock & eligibility (§4)

  /// Resolves the fade clock for a task: `touchedAt` when set, else `createdAt`
  /// when real (not the `.distantPast` migration sentinel), else the `YYYY-MM-DD`
  /// `created` day. Returns `nil` only when no creation date is known at all,
  /// so legacy rows with unknown age never falsely fade.
  static func clockDate(touchedAt: Date?, createdAt: Date, created: String?) -> Date? {
    if let touchedAt { return touchedAt }
    if createdAt != .distantPast { return createdAt }
    return parseDay(created)
  }

  /// Whether a task can fade under §4 (all non-time conditions):
  /// - open, not a heading, not deleted, not already faded;
  /// - no hard `deadline`;
  /// - `scheduled` is nil or strictly in the past (`< today`);
  /// - no recurrence rule;
  /// - conversation is not on the agent's turn, `assignee` is not `claude`,
  ///   and it is not waiting on the human in Review / an open question card.
  static func isEligible(isOpen: Bool,
                         isHeading: Bool,
                         isDeleted: Bool,
                         isFaded: Bool,
                         deadline: String?,
                         scheduled: String?,
                         hasRecurrence: Bool,
                         isAgentTurn: Bool,
                         isAssignedToClaude: Bool,
                         isAwaitingHuman: Bool = false,
                         today: String) -> Bool {
    guard isOpen, !isHeading, !isDeleted, !isFaded else { return false }
    if let deadline, !deadline.isEmpty { return false }
    if let scheduled, !scheduled.isEmpty, String(scheduled.prefix(10)) >= today { return false }
    guard !hasRecurrence else { return false }
    guard !isAgentTurn, !isAssignedToClaude, !isAwaitingHuman else { return false }
    return true
  }

  /// Whether the daily fade pass should stamp `fadedAt = now` on this task.
  static func shouldFade(isOpen: Bool,
                         isHeading: Bool,
                         isDeleted: Bool,
                         isFaded: Bool,
                         deadline: String?,
                         scheduled: String?,
                         hasRecurrence: Bool,
                         isAgentTurn: Bool,
                         isAssignedToClaude: Bool,
                         isAwaitingHuman: Bool = false,
                         touchedAt: Date?,
                         createdAt: Date,
                         created: String?,
                         now: Date,
                         today: String) -> Bool {
    guard isEligible(isOpen: isOpen, isHeading: isHeading, isDeleted: isDeleted,
                     isFaded: isFaded, deadline: deadline, scheduled: scheduled,
                     hasRecurrence: hasRecurrence, isAgentTurn: isAgentTurn,
                     isAssignedToClaude: isAssignedToClaude,
                     isAwaitingHuman: isAwaitingHuman, today: today) else {
      return false
    }
    guard let clock = clockDate(touchedAt: touchedAt, createdAt: createdAt, created: created) else {
      return false
    }
    return now.timeIntervalSince(clock) >= windowInterval
  }

  /// Countdown progress (0…1) for the visible row fade in every list (§4).
  /// `nil` during the first untouched day or for ineligible / agent-cue rows.
  /// Ramps smoothly to `1.0` (`minOpacity = 0.55`) at `windowDays`.
  static func fadeFill(isOpen: Bool,
                       isHeading: Bool,
                       isDeleted: Bool,
                       isFaded: Bool,
                       deadline: String?,
                       scheduled: String?,
                       hasRecurrence: Bool,
                       isAgentTurn: Bool,
                       isAssignedToClaude: Bool,
                       isAwaitingHuman: Bool = false,
                       showsAgentCue: Bool,
                       touchedAt: Date?,
                       createdAt: Date,
                       created: String?,
                       now: Date,
                       today: String) -> Double? {
    guard !showsAgentCue,
          isEligible(isOpen: isOpen, isHeading: isHeading, isDeleted: isDeleted,
                     isFaded: isFaded, deadline: deadline, scheduled: scheduled,
                     hasRecurrence: hasRecurrence, isAgentTurn: isAgentTurn,
                     isAssignedToClaude: isAssignedToClaude,
                     isAwaitingHuman: isAwaitingHuman, today: today),
          let clock = clockDate(touchedAt: touchedAt, createdAt: createdAt, created: created) else {
      return nil
    }
    let elapsed = now.timeIntervalSince(clock)
    guard elapsed >= graceInterval else { return nil }
    return min(1, elapsed / windowInterval)
  }

  // MARK: - Weekly sweep (§5)

  /// Start-of-day of the most recent Sunday on or before `now`.
  static func mostRecentSweepAnchor(now: Date, calendar: Calendar = .current) -> Date {
    let startOfToday = calendar.startOfDay(for: now)
    let weekday = calendar.component(.weekday, from: startOfToday)
    let delta = (weekday - sweepWeekday + 7) % 7
    return calendar.date(byAdding: .day, value: -delta, to: startOfToday) ?? startOfToday
  }

  /// Whether a faded task belongs to the current sweep (faded since the last
  /// completed sweep).
  static func isInCurrentSweep(fadedAt: Date?, lastSweepAt: Date?) -> Bool {
    guard let fadedAt else { return false }
    guard let lastSweepAt else { return true }
    return fadedAt > lastSweepAt
  }

  /// Whether the weekly sweep banner should appear in the Inbox band (§5).
  /// True once the Sunday anchor has passed since the last sweep (and the user
  /// hasn't dismissed this week's banner), and at least one task faded since
  /// the last sweep.
  static func isSweepDue(now: Date,
                         lastSweepAt: Date?,
                         dismissedWeek: Date?,
                         fadedDates: [Date],
                         calendar: Calendar = .current) -> Bool {
    let anchor = mostRecentSweepAnchor(now: now, calendar: calendar)
    if let lastSweepAt, lastSweepAt >= anchor { return false }
    if let dismissedWeek, dismissedWeek >= anchor { return false }
    return fadedDates.contains { isInCurrentSweep(fadedAt: $0, lastSweepAt: lastSweepAt) }
  }

  static var lastSweepAt: Date? {
    let ts = UserDefaults.standard.double(forKey: lastSweepAtKey)
    return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
  }

  static func markSweepCompleted(at date: Date) {
    UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastSweepAtKey)
  }

  static var dismissedSweepWeek: Date? {
    let ts = UserDefaults.standard.double(forKey: dismissedSweepWeekKey)
    return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
  }

  /// Dismisses this week's sweep banner without dropping any tasks.
  static func dismissSweepForCurrentWeek(now: Date, calendar: Calendar = .current) {
    let anchor = mostRecentSweepAnchor(now: now, calendar: calendar)
    UserDefaults.standard.set(anchor.timeIntervalSince1970, forKey: dismissedSweepWeekKey)
  }

  /// Plain-language, field-derived one-line reason shown under a faded row in
  /// the sweep sheet (`docs/TASK_FADE_SPEC.md` §9 — no AI needed).
  static func sweepReason(touchedAt: Date?,
                          createdAt: Date,
                          created: String?,
                          listName: String?,
                          scheduled: String?,
                          now: Date,
                          calendar: Calendar = .current) -> String {
    var parts: [String] = []
    if let clock = clockDate(touchedAt: touchedAt, createdAt: createdAt, created: created) {
      let days = max(windowDays, Int(now.timeIntervalSince(clock) / 86_400))
      parts.append("\(days) days without activity")
    }
    if let scheduled, !scheduled.isEmpty {
      parts.append("Past date")
    } else {
      parts.append("No date")
    }
    if let listName, !listName.isEmpty {
      parts.append(listName)
    } else {
      parts.append("Inbox")
    }
    return parts.joined(separator: " · ")
  }

  // MARK: - Helpers

  private static func parseDay(_ raw: String?) -> Date? {
    guard let raw, raw.count >= 10 else { return nil }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.date(from: String(raw.prefix(10)))
  }
}
