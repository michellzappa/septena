import Foundation
import SeptenaSharedCore

// Task fade rules, visual countdown, and weekly sweep schedule
// (`docs/TASK_FADE_SPEC.md` §4 & §5, ADR 0006).
//
// The fade rule itself (row opacity, eligibility, the window and the grace
// period) lives in the shared Rust core (ADR 0025), so every client computes
// the same fade; this enum adapts Swift values to it. The weekly sweep, the
// Settings keys and the sweep copy stay here. Both task lists — SwiftUI
// (`CheckableRow` / `TaskCheckboxModel`) and AppKit (`SeptaskKitTaskCell`) —
// read this single entry point so they cannot drift.

enum TaskFade {
  /// Default untouched window before an open task fades (days).
  static let windowDays: Int = RegistryRules.fadeWindowDays

  /// The faintest a fading row gets. Label ink at 0.55 on the light background
  /// stays above a 4.5:1 contrast ratio, so a faded title is still readable.
  static let minOpacity: Double = RegistryRules.fadeMinOpacity

  /// Device mirror of the synced setting `tasksShowAging`, so rows read it
  /// without a decode (`SettingsMirror.setFadeEnabled`). Absent → enabled by
  /// default (`docs/TASK_FADE_SPEC.md` §11).
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
    SeptenaSharedCore.rowOpacity(fill: fill)
  }

  // MARK: - Clock & eligibility (§4)

  /// Resolves the fade clock for a task: `touchedAt` when set, else `createdAt`
  /// when real (not the `.distantPast` migration sentinel), else the `YYYY-MM-DD`
  /// `created` day. Returns `nil` only when no creation date is known at all.
  /// The core resolves the same clock for the fade itself; the sweep copy
  /// (`sweepReason`) reads this one.
  static func clockDate(touchedAt: Date?, createdAt: Date, created: String?) -> Date? {
    if let touchedAt { return touchedAt }
    if createdAt != .distantPast { return createdAt }
    return parseDay(created)
  }

  /// Whether the daily fade pass should stamp `fadedAt = now` on this task.
  /// Eligibility (§4): open, not a heading, not deleted or faded, no
  /// deadline, `scheduled` nil or before `today`, no recurrence, not the
  /// agent's turn, not assigned to Claude, not waiting on the human.
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
                         isProposal: Bool = false,
                         touchedAt: Date?,
                         createdAt: Date,
                         created: String?,
                         now: Date,
                         today: String) -> Bool {
    let input = coreInput(isOpen: isOpen, isHeading: isHeading, isDeleted: isDeleted, isFaded: isFaded,
                          deadline: deadline, scheduled: scheduled, hasRecurrence: hasRecurrence,
                          isAgentTurn: isAgentTurn, isAssignedToClaude: isAssignedToClaude,
                          isAwaitingHuman: isAwaitingHuman, showsAgentCue: false, isProposal: isProposal,
                          touchedAt: touchedAt, createdAt: createdAt, created: created, now: now, today: today)
    return (try? SeptenaSharedCore.shouldFade(input: input)) ?? false
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
                       isProposal: Bool = false,
                       touchedAt: Date?,
                       createdAt: Date,
                       created: String?,
                       now: Date,
                       today: String) -> Double? {
    let input = coreInput(isOpen: isOpen, isHeading: isHeading, isDeleted: isDeleted, isFaded: isFaded,
                          deadline: deadline, scheduled: scheduled, hasRecurrence: hasRecurrence,
                          isAgentTurn: isAgentTurn, isAssignedToClaude: isAssignedToClaude,
                          isAwaitingHuman: isAwaitingHuman, showsAgentCue: showsAgentCue, isProposal: isProposal,
                          touchedAt: touchedAt, createdAt: createdAt, created: created, now: now, today: today)
    return try? SeptenaSharedCore.fadeFill(input: input)
  }

  private static func coreInput(isOpen: Bool, isHeading: Bool, isDeleted: Bool, isFaded: Bool,
                                deadline: String?, scheduled: String?, hasRecurrence: Bool,
                                isAgentTurn: Bool, isAssignedToClaude: Bool, isAwaitingHuman: Bool,
                                showsAgentCue: Bool, isProposal: Bool, touchedAt: Date?, createdAt: Date, created: String?,
                                now: Date, today: String) -> FadeInput {
    FadeInput(
      isOpen: isOpen, isHeading: isHeading, isDeleted: isDeleted, isFaded: isFaded,
      deadline: deadline, scheduled: scheduled, hasRecurrence: hasRecurrence,
      isAgentTurn: isAgentTurn, isAssignedToClaude: isAssignedToClaude,
      isAwaitingHuman: isAwaitingHuman, showsAgentCue: showsAgentCue,
      isProposal: isProposal,
      touchedAt: touchedAt.map(SharedCoreValues.instant),
      // `.distantPast` is the migration sentinel for "creation time unknown".
      createdAt: createdAt == .distantPast ? nil : SharedCoreValues.instant(createdAt),
      created: created,
      now: SharedCoreValues.instant(now),
      today: today,
      utcOffsetSeconds: SharedCoreValues.utcOffsetSeconds(at: now)
    )
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
  /// True only on the sweep day itself (Sunday by default), when the user has
  /// not swept or dismissed this week, and at least one task faded since the
  /// last sweep. An ignored banner goes away on Monday; the Faded pile still
  /// opens the same sheet on any day.
  static func isSweepDue(now: Date,
                         lastSweepAt: Date?,
                         dismissedWeek: Date?,
                         fadedDates: [Date],
                         calendar: Calendar = .current) -> Bool {
    let anchor = mostRecentSweepAnchor(now: now, calendar: calendar)
    guard calendar.startOfDay(for: now) == anchor else { return false }
    if let lastSweepAt, lastSweepAt >= anchor { return false }
    if let dismissedWeek, dismissedWeek >= anchor { return false }
    return fadedDates.contains { isInCurrentSweep(fadedAt: $0, lastSweepAt: lastSweepAt) }
  }

  /// When the last sweep finished on any device: the later of the account's
  /// value and this device's, so a stale sync cannot bring a sweep back.
  static var lastSweepAt: Date? {
    let ts = UserDefaults.standard.double(forKey: lastSweepAtKey)
    return [ts > 0 ? Date(timeIntervalSince1970: ts) : nil, SeptaskSyncedSettings.current().fadeSweptAt]
      .compactMap { $0 }.max()
  }

  @MainActor
  static func markSweepCompleted(at date: Date) {
    UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastSweepAtKey)
    SettingsMirror.updateSynced { $0.fadeSweptAt = date }
  }

  static var dismissedSweepWeek: Date? {
    let ts = UserDefaults.standard.double(forKey: dismissedSweepWeekKey)
    return [ts > 0 ? Date(timeIntervalSince1970: ts) : nil,
            parseDay(SeptaskSyncedSettings.current().fadeSweepDismissedOn)]
      .compactMap { $0 }.max()
  }

  /// Dismisses this week's sweep banner on every device without dropping any tasks.
  @MainActor
  static func dismissSweepForCurrentWeek(now: Date, calendar: Calendar = .current) {
    let anchor = mostRecentSweepAnchor(now: now, calendar: calendar)
    UserDefaults.standard.set(anchor.timeIntervalSince1970, forKey: dismissedSweepWeekKey)
    let day = SeptenaDate.format(anchor)
    SettingsMirror.updateSynced { $0.fadeSweepDismissedOn = day }
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
