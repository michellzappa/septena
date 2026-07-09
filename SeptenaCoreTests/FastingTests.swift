import Testing
import Foundation

// Regression coverage for the live-fasting state machine (`computeFastingState`
// in SeptenaCore/Fasting.swift). The function takes `now` and `calendar` as
// injectable parameters, so these tests are fully deterministic — we pin a
// gregorian/UTC calendar and build fixed `now` values, no wall-clock reads.

@Suite struct FastingTests {

  // A gregorian calendar fixed to UTC so `.hour` extraction and date math
  // don't drift with the machine's locale/timezone.
  private static let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()

  private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    Self.cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  @Test func nilInputsAreFed() {
    let state = computeFastingState(
      inputs: nil,
      now: at(2026, 6, 9, 12, 0),
      calendar: Self.cal
    )
    #expect(state == .fed)
    #expect(state.isFasting == false)
  }

  @Test func overnightFastWhenNothingEatenToday() {
    // Yesterday's last meal at 20:00, nothing today, now = today 08:00 → 12h fast.
    let inputs = FastingStateInputs(todayLatestMeal: nil, todayMealCount: 0, yesterdayLastMeal: "20:00")
    let state = computeFastingState(inputs: inputs, now: at(2026, 6, 9, 8, 0), calendar: Self.cal)

    #expect(state.isFasting)
    if case .fasting(let sinceDay, let sinceTime, let total) = state {
      #expect(sinceDay == .yesterday)
      #expect(sinceTime == "20:00")
      #expect(total == 12 * 60)   // 720 minutes
    } else {
      Issue.record("expected .fasting, got \(state)")
    }
  }

  @Test func postDinnerFastStartsAfterGrace() {
    // Ate at 19:00, now 20:00 (past the 19:00 evening hour) → 60 min ≥ 30 grace.
    let inputs = FastingStateInputs(todayLatestMeal: "19:00", todayMealCount: 1, yesterdayLastMeal: "20:00")
    let state = computeFastingState(inputs: inputs, now: at(2026, 6, 9, 20, 0), calendar: Self.cal)

    if case .fasting(let sinceDay, _, let total) = state {
      #expect(sinceDay == .today)
      #expect(total == 60)
    } else {
      Issue.record("expected .fasting, got \(state)")
    }
  }

  @Test func withinGraceWindowIsStillFed() {
    // Ate at 19:50, now 20:00 → only 10 min, below the 30-min grace.
    let inputs = FastingStateInputs(todayLatestMeal: "19:50", todayMealCount: 1, yesterdayLastMeal: "20:00")
    let state = computeFastingState(inputs: inputs, now: at(2026, 6, 9, 20, 0), calendar: Self.cal)
    #expect(state == .fed)
  }

  @Test func daytimeAfterEatingIsFed() {
    // Before the evening hour, with a meal logged today → not fasting.
    let inputs = FastingStateInputs(todayLatestMeal: "12:00", todayMealCount: 1, yesterdayLastMeal: "20:00")
    let state = computeFastingState(inputs: inputs, now: at(2026, 6, 9, 14, 0), calendar: Self.cal)
    #expect(state == .fed)
  }

  @Test func hoursAndMinutesBreakdown() {
    let state = FastingState.fasting(sinceDay: .yesterday, sinceTime: "20:00", totalMin: 750)
    #expect(state.hoursAndMinutes?.h == 12)
    #expect(state.hoursAndMinutes?.m == 30)
    #expect(FastingState.fed.hoursAndMinutes == nil)
  }
}
