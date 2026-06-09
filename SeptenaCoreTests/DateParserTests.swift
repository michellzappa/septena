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
