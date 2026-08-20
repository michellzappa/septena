import Testing
import Foundation

// Regression coverage for SeptenaCore/DateParser.swift. `parseRepeatRule` and
// absolute-date parsing are deterministic; the relative parses ("tomorrow")
// read the wall clock, so we don't assert on their exact values here.

@Suite struct DateParserTests {

  @Test func repeatRuleNamedWeekday() {
    // Full weekday names map cleanly: the "every mon" prefix pattern no longer
    // appends the leftover "day" tail when it matched mid-word. The 3-letter
    // form still resolves to the full weekday rule.
    #expect(SeptenaDateParser.parseRepeatRule("every monday") == "every monday")
    #expect(SeptenaDateParser.parseRepeatRule("walk the dog every fri") == "every friday")
  }

  @Test func repeatRuleKeywords() {
    #expect(SeptenaDateParser.parseRepeatRule("weekly") == "weekly")
    #expect(SeptenaDateParser.parseRepeatRule("monthly") == "monthly")
    #expect(SeptenaDateParser.parseRepeatRule("daily") == "daily")
  }

  @Test func repeatRuleIntervalInDays() {
    #expect(SeptenaDateParser.parseRepeatRule("in 3 days") == "every 3 days")
  }

  @Test func repeatRuleNoneForPlainText() {
    #expect(SeptenaDateParser.parseRepeatRule("buy groceries") == nil)
  }

  @Test func parsesISODate() {
    let date = SeptenaDateParser.parse("2026-04-05")
    #expect(date != nil)
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date!)
    #expect(c.year == 2026)
    #expect(c.month == 4)
    #expect(c.day == 5)
  }

  @Test func returnsNilForGarbage() {
    #expect(SeptenaDateParser.parse("not a date at all") == nil)
  }
}

@Suite struct RecurrenceTests {
  @Test func advancesFromCompletionDate() {
    #expect(RecurrenceDateCalculator.nextDate(
      completedOn: "2026-08-02", scheduled: nil,
      unit: "day", interval: 3, afterCompletion: true
    ) == "2026-08-05")
  }

  @Test func advancesFromFixedScheduleAndSkipsMissedDates() {
    #expect(RecurrenceDateCalculator.nextDate(
      completedOn: "2026-08-20", scheduled: "2026-08-01",
      unit: "week", interval: 1, afterCompletion: false
    ) == "2026-08-22")
  }

  /// A fixed monthly rule anchored on month-end used to decay: `byAdding:
  /// .month` clamps Jan 31 → Feb 28, and because the next occurrence re-anchors
  /// on the stored date it then walked Mar 28 → Apr 28 forever.
  @Test func fixedMonthlyKeepsMonthEndAcrossTheChain() {
    var scheduled = "2026-01-31"
    var walked: [String] = []
    for _ in 0..<4 {
      let next = RecurrenceDateCalculator.nextDate(
        completedOn: scheduled, scheduled: scheduled,
        unit: "month", interval: 1, afterCompletion: false
      )
      guard let next else { break }
      walked.append(next)
      scheduled = next
    }
    #expect(walked == ["2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31"])
  }

  /// Mid-month days are untouched by the month-end rule.
  @Test func fixedMonthlyKeepsAnOrdinaryDayOfMonth() {
    #expect(RecurrenceDateCalculator.nextDate(
      completedOn: "2026-01-15", scheduled: "2026-01-15",
      unit: "month", interval: 1, afterCompletion: false
    ) == "2026-02-15")
  }

  /// After-completion anchors on whatever day the box was ticked, so month-end
  /// snapping must NOT apply — it would invent an intent the user never set.
  @Test func afterCompletionMonthlyDoesNotSnapToMonthEnd() {
    #expect(RecurrenceDateCalculator.nextDate(
      completedOn: "2026-02-28", scheduled: nil,
      unit: "month", interval: 1, afterCompletion: true
    ) == "2026-03-28")
  }

  /// A fixed weekly rule keeps its weekday no matter how late it is completed.
  @Test func fixedWeeklyKeepsItsWeekday() {
    // 2026-08-03 is a Monday; completed three weeks late, still lands Monday.
    let next = RecurrenceDateCalculator.nextDate(
      completedOn: "2026-08-22", scheduled: "2026-08-03",
      unit: "week", interval: 1, afterCompletion: false
    )
    #expect(next == "2026-08-24")
  }

  @Test func fixedScheduleExceptionAdvancesFromLogicalSlot() {
    // The visible copy was moved from Monday Aug 24 to Wednesday Aug 26.
    // Completing it must still produce the following Monday, not Sep 2.
    #expect(RecurrenceDateCalculator.nextDate(
      completedOn: "2026-08-26",
      scheduled: "2026-08-26",
      logicalScheduled: "2026-08-24",
      unit: "week",
      interval: 1,
      afterCompletion: false
    ) == "2026-08-31")
  }

  @Test func completionBasedRuleIgnoresLogicalSlot() {
    #expect(RecurrenceDateCalculator.nextDate(
      completedOn: "2026-08-26",
      scheduled: "2026-08-24",
      logicalScheduled: "2026-08-24",
      unit: "day",
      interval: 3,
      afterCompletion: true
    ) == "2026-08-29")
  }

  @Test func producesStableOccurrenceIDs() {
    let first = RecurrenceDateCalculator.occurrenceID(sourceTaskID: "task-1", scheduled: "2026-08-05")
    let second = RecurrenceDateCalculator.occurrenceID(sourceTaskID: "task-1", scheduled: "2026-08-05")
    #expect(first == second)
    #expect(first.hasPrefix("recur-"))
  }
}
