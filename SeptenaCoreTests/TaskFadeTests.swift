import XCTest

final class TaskFadeTests: XCTestCase {
  private let utc: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
  }()

  private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  // MARK: - Eligibility & 14-day window (§4)

  func testOpenUntouchedTaskFadesAt14Days() {
    let created = date(2026, 11, 1, hour: 10)
    let beforeWindow = date(2026, 11, 15, hour: 9)   // 13d 23h
    let atWindow = date(2026, 11, 15, hour: 10)      // 14d 0h

    XCTAssertFalse(TaskFade.shouldFade(
      isOpen: true, isHeading: false, isDeleted: false, isFaded: false,
      deadline: nil, scheduled: nil, hasRecurrence: false,
      isAgentTurn: false, isAssignedToClaude: false,
      touchedAt: nil, createdAt: created, created: "2026-11-01",
      now: beforeWindow, today: "2026-11-15"
    ))
    XCTAssertTrue(TaskFade.shouldFade(
      isOpen: true, isHeading: false, isDeleted: false, isFaded: false,
      deadline: nil, scheduled: nil, hasRecurrence: false,
      isAgentTurn: false, isAssignedToClaude: false,
      touchedAt: nil, createdAt: created, created: "2026-11-01",
      now: atWindow, today: "2026-11-15"
    ))
  }

  func testTouchedAtResetsFadeClock() {
    let created = date(2026, 10, 1)
    let touched = date(2026, 11, 10)
    let now = date(2026, 11, 20)

    XCTAssertFalse(TaskFade.shouldFade(
      isOpen: true, isHeading: false, isDeleted: false, isFaded: false,
      deadline: nil, scheduled: nil, hasRecurrence: false,
      isAgentTurn: false, isAssignedToClaude: false,
      touchedAt: touched, createdAt: created, created: "2026-10-01",
      now: now, today: "2026-11-20"
    ))
  }

  func testExclusionsNeverFade() {
    let old = date(2026, 10, 1)
    let now = date(2026, 11, 21)
    let today = "2026-11-21"

    func check(isOpen: Bool = true, isHeading: Bool = false, isDeleted: Bool = false,
               isFaded: Bool = false, deadline: String? = nil, scheduled: String? = nil,
               hasRecurrence: Bool = false, isAgentTurn: Bool = false,
               isAssignedToClaude: Bool = false) -> Bool {
      TaskFade.shouldFade(
        isOpen: isOpen, isHeading: isHeading, isDeleted: isDeleted, isFaded: isFaded,
        deadline: deadline, scheduled: scheduled, hasRecurrence: hasRecurrence,
        isAgentTurn: isAgentTurn, isAssignedToClaude: isAssignedToClaude,
        touchedAt: nil, createdAt: old, created: "2026-10-01",
        now: now, today: today
      )
    }

    XCTAssertFalse(check(isOpen: false))
    XCTAssertFalse(check(isHeading: true))
    XCTAssertFalse(check(isDeleted: true))
    XCTAssertFalse(check(isFaded: true))
    XCTAssertFalse(check(deadline: "2026-11-25"))
    XCTAssertFalse(check(deadline: "2026-11-01")) // even past deadline never fades
    XCTAssertFalse(check(scheduled: "2026-11-21")) // scheduled today
    XCTAssertFalse(check(scheduled: "2026-11-25")) // scheduled in future
    XCTAssertTrue(check(scheduled: "2026-11-10"))  // scheduled in the past CAN fade
    XCTAssertFalse(check(hasRecurrence: true))
    XCTAssertFalse(check(isAgentTurn: true))
    XCTAssertFalse(check(isAssignedToClaude: true))
  }

  func testLegacyUnknownAgeDoesNotFade() {
    let now = date(2026, 11, 21)
    XCTAssertFalse(TaskFade.shouldFade(
      isOpen: true, isHeading: false, isDeleted: false, isFaded: false,
      deadline: nil, scheduled: nil, hasRecurrence: false,
      isAgentTurn: false, isAssignedToClaude: false,
      touchedAt: nil, createdAt: .distantPast, created: nil,
      now: now, today: "2026-11-21"
    ))
    // Falls back to `created` day when createdAt is .distantPast
    XCTAssertTrue(TaskFade.shouldFade(
      isOpen: true, isHeading: false, isDeleted: false, isFaded: false,
      deadline: nil, scheduled: nil, hasRecurrence: false,
      isAgentTurn: false, isAssignedToClaude: false,
      touchedAt: nil, createdAt: .distantPast, created: "2026-11-01",
      now: now, today: "2026-11-21"
    ))
  }

  // MARK: - Visible fade curve (§4)

  func testFadeFillAndOpacityCurve() {
    let created = date(2026, 11, 1, hour: 12)
    // Under 1 day: full strength (nil)
    let fillFresh = TaskFade.fadeFill(
      isOpen: true, isHeading: false, isDeleted: false, isFaded: false,
      deadline: nil, scheduled: nil, hasRecurrence: false,
      isAgentTurn: false, isAssignedToClaude: false, showsAgentCue: false,
      touchedAt: nil, createdAt: created, created: "2026-11-01",
      now: date(2026, 11, 2, hour: 11), today: "2026-11-02"
    )
    XCTAssertNil(fillFresh)
    XCTAssertEqual(TaskFade.rowOpacity(fillFresh), 1.0, accuracy: 0.001)

    // Midpoint (7 days): 0.5 fill
    let fillMid = TaskFade.fadeFill(
      isOpen: true, isHeading: false, isDeleted: false, isFaded: false,
      deadline: nil, scheduled: nil, hasRecurrence: false,
      isAgentTurn: false, isAssignedToClaude: false, showsAgentCue: false,
      touchedAt: nil, createdAt: created, created: "2026-11-01",
      now: date(2026, 11, 8, hour: 12), today: "2026-11-08"
    )
    XCTAssertEqual(fillMid ?? -1, 0.5, accuracy: 0.001)
    XCTAssertEqual(TaskFade.rowOpacity(fillMid), 0.775, accuracy: 0.001)

    // At 14 days: 1.0 fill -> minOpacity (0.55)
    let fillEnd = TaskFade.fadeFill(
      isOpen: true, isHeading: false, isDeleted: false, isFaded: false,
      deadline: nil, scheduled: nil, hasRecurrence: false,
      isAgentTurn: false, isAssignedToClaude: false, showsAgentCue: false,
      touchedAt: nil, createdAt: created, created: "2026-11-01",
      now: date(2026, 11, 15, hour: 12), today: "2026-11-15"
    )
    XCTAssertEqual(fillEnd ?? -1, 1.0, accuracy: 0.001)
    XCTAssertEqual(TaskFade.rowOpacity(fillEnd), TaskFade.minOpacity, accuracy: 0.001)
  }

  // MARK: - Weekly sweep (§5)

  func testWeeklySweepSchedule() {
    // 2026-11-22 is a Sunday.
    let sunday = date(2026, 11, 22, hour: 10)
    let fadedThu = date(2026, 11, 19, hour: 9)

    // Due on Sunday when a task faded since last sweep (nil)
    XCTAssertTrue(TaskFade.isSweepDue(
      now: sunday, lastSweepAt: nil, dismissedWeek: nil,
      fadedDates: [fadedThu], calendar: utc
    ))

    // Sunday only: an ignored banner is gone on Monday
    XCTAssertFalse(TaskFade.isSweepDue(
      now: date(2026, 11, 23, hour: 10), lastSweepAt: nil, dismissedWeek: nil,
      fadedDates: [fadedThu], calendar: utc
    ))

    // Not due when no tasks faded
    XCTAssertFalse(TaskFade.isSweepDue(
      now: sunday, lastSweepAt: nil, dismissedWeek: nil,
      fadedDates: [], calendar: utc
    ))

    // Once swept on Sunday, quiet for the rest of the week even if another fades on Tuesday
    let sweptSunday = date(2026, 11, 22, hour: 11)
    let tuesday = date(2026, 11, 24, hour: 12)
    XCTAssertFalse(TaskFade.isSweepDue(
      now: tuesday, lastSweepAt: sweptSunday, dismissedWeek: nil,
      fadedDates: [date(2026, 11, 23, hour: 9)], calendar: utc
    ))

    // Next Sunday (2026-11-29) brings the sweep back for tasks faded since last sweep
    let nextSunday = date(2026, 11, 29, hour: 10)
    XCTAssertTrue(TaskFade.isSweepDue(
      now: nextSunday, lastSweepAt: sweptSunday, dismissedWeek: nil,
      fadedDates: [date(2026, 11, 23, hour: 9)], calendar: utc
    ))
    // Tasks faded BEFORE the last sweep don't re-trigger the next week's sweep
    XCTAssertFalse(TaskFade.isSweepDue(
      now: nextSunday, lastSweepAt: sweptSunday, dismissedWeek: nil,
      fadedDates: [fadedThu], calendar: utc
    ))

    // Dismissing on Sunday silences the banner for that week without dropping tasks
    let anchor = TaskFade.mostRecentSweepAnchor(now: sunday, calendar: utc)
    XCTAssertFalse(TaskFade.isSweepDue(
      now: date(2026, 11, 23, hour: 10), lastSweepAt: nil, dismissedWeek: anchor,
      fadedDates: [fadedThu], calendar: utc
    ))
  }
}
