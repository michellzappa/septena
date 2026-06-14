import Testing
import Foundation

// Coverage for SeptenaCore/WakingDay.swift — the dashboard dial's waking-day
// boundary. All tests run in a fixed UTC calendar so wake instants and civil
// dates are deterministic regardless of the host time zone.

@Suite struct WakingDayTests {

  /// UTC calendar — keeps `startOfDay` and the `"yyyy-MM-dd"` keys stable.
  private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }

  /// A UTC instant for the given civil date and time-of-day.
  private func at(_ ymd: String, _ hour: Int, _ minute: Int = 0) -> Date {
    var c = DateComponents()
    let p = ymd.split(separator: "-").map { Int($0)! }
    c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = hour; c.minute = minute
    c.timeZone = TimeZone(identifier: "UTC")
    return cal.date(from: c)!
  }

  private func key(_ ymd: String) -> Date { at(ymd, 0, 0) }

  // MARK: Cutoff fallback (no sleep data)

  @Test func cutoffKeepsLateNightOnTheSameDay() {
    // The headline case: 23:30 and 01:30 of the same overnight belong to the
    // SAME waking day — the dial doesn't flip at midnight.
    let w = WakingDay(enabled: true, cutoffHour: 4)
    let evening = w.dayKey(containing: at("2026-06-14", 23, 30), calendar: cal)
    let smallHours = w.dayKey(containing: at("2026-06-15", 1, 30), calendar: cal)
    #expect(evening == key("2026-06-14"))
    #expect(smallHours == key("2026-06-14"))   // still the 14th's waking day
  }

  @Test func cutoffRollsAtFourAM() {
    let w = WakingDay(enabled: true, cutoffHour: 4)
    // 03:59 is still the previous waking day; 04:00 begins the new one.
    #expect(w.dayKey(containing: at("2026-06-15", 3, 59), calendar: cal) == key("2026-06-14"))
    #expect(w.dayKey(containing: at("2026-06-15", 4, 0), calendar: cal) == key("2026-06-15"))
  }

  @Test func daytimeEventBelongsToItsOwnDay() {
    let w = WakingDay(enabled: true, cutoffHour: 4)
    #expect(w.dayKey(containing: at("2026-06-15", 14, 0), calendar: cal) == key("2026-06-15"))
  }

  // MARK: Sleep-driven boundary

  @Test func sleepWakeAnchorsTheDay() {
    // Woke 06:40 on the 15th. An event at 05:00 (before wake) is the night
    // before; at 07:00 (after wake) it's the new day.
    let w = WakingDay(enabled: true, cutoffHour: 4,
                      wakeFractionByDate: ["2026-06-15": (6 * 60 + 40) / 1440.0])
    #expect(w.dayKey(containing: at("2026-06-15", 5, 0), calendar: cal) == key("2026-06-14"))
    #expect(w.dayKey(containing: at("2026-06-15", 7, 0), calendar: cal) == key("2026-06-15"))
  }

  @Test func sleepWakeOverridesCutoff() {
    // With a real wake of 06:40, the 04:00 cutoff is irrelevant: 05:30 is
    // before wake → previous day (cutoff alone would have rolled at 04:00).
    let w = WakingDay(enabled: true, cutoffHour: 4,
                      wakeFractionByDate: ["2026-06-15": (6 * 60 + 40) / 1440.0])
    #expect(w.dayKey(containing: at("2026-06-15", 5, 30), calendar: cal) == key("2026-06-14"))
  }

  @Test func missingNightFallsBackToCutoff() {
    // Sleep map has the 14th but not the 15th (pre-sync morning). The 15th's
    // small hours resolve via the 04:00 cutoff, not a crash.
    let w = WakingDay(enabled: true, cutoffHour: 4,
                      wakeFractionByDate: ["2026-06-14": (7 * 60) / 1440.0])
    #expect(w.dayKey(containing: at("2026-06-15", 3, 0), calendar: cal) == key("2026-06-14"))
    #expect(w.dayKey(containing: at("2026-06-15", 6, 0), calendar: cal) == key("2026-06-15"))
  }

  // MARK: Disabled → plain midnight

  @Test func disabledCollapsesToMidnight() {
    let w = WakingDay(enabled: false, cutoffHour: 4)
    // Every instant keys to its own civil midnight — the legacy behavior.
    #expect(w.dayKey(containing: at("2026-06-15", 1, 30), calendar: cal) == key("2026-06-15"))
    #expect(w.dayKey(containing: at("2026-06-14", 23, 30), calendar: cal) == key("2026-06-14"))
  }

  // MARK: daysAgo

  @Test func daysAgoCountsWakingDays() {
    let w = WakingDay(enabled: true, cutoffHour: 4)
    let todayKey = w.dayKey(containing: at("2026-06-15", 14, 0), calendar: cal)
    // This afternoon → 0; last night's 02:00 small hours → still 0 (same
    // waking day as yesterday evening); yesterday evening → 1.
    #expect(w.daysAgo(at("2026-06-15", 14, 0), todayKey: todayKey, calendar: cal) == 0)
    #expect(w.daysAgo(at("2026-06-15", 2, 0), todayKey: todayKey, calendar: cal) == 1)
    #expect(w.daysAgo(at("2026-06-14", 20, 0), todayKey: todayKey, calendar: cal) == 1)
    #expect(w.daysAgo(at("2026-06-13", 12, 0), todayKey: todayKey, calendar: cal) == 2)
  }

  @Test func daysAgoStableAcrossVariableWakeTimes() {
    // Wake jitters night to night (06:00, 09:00, 05:30). daysAgo must still
    // count exactly one waking day per civil date — the civil-midnight key
    // keeps the math from drifting under <24h gaps.
    let w = WakingDay(enabled: true, cutoffHour: 4, wakeFractionByDate: [
      "2026-06-15": (6 * 60) / 1440.0,
      "2026-06-14": (9 * 60) / 1440.0,
      "2026-06-13": (5 * 60 + 30) / 1440.0,
    ])
    let todayKey = w.dayKey(containing: at("2026-06-15", 12, 0), calendar: cal)
    #expect(w.daysAgo(at("2026-06-15", 12, 0), todayKey: todayKey, calendar: cal) == 0)
    #expect(w.daysAgo(at("2026-06-14", 12, 0), todayKey: todayKey, calendar: cal) == 1)
    #expect(w.daysAgo(at("2026-06-13", 12, 0), todayKey: todayKey, calendar: cal) == 2)
  }

  // MARK: Wake-fraction lookup
  // (`WakingDay.from(nights:)` — the OuraNight adapter — lives in
  // WakingDay+Oura.swift and is exercised by the app build, since OuraNight
  // isn't compiled into this test bundle.)

  @Test func wakeFractionLookupByCivilDate() {
    let w = WakingDay(enabled: true, cutoffHour: 4, wakeFractionByDate: [
      "2026-06-15": (6 * 60 + 40) / 1440.0,
    ])
    #expect(w.wakeFraction(forCivilDate: key("2026-06-15"), calendar: cal) == (6 * 60 + 40) / 1440.0)
    #expect(w.wakeFraction(forCivilDate: key("2026-06-14"), calendar: cal) == nil)
  }

  @Test func fractionParsesHHmm() {
    #expect(WakingDay.fraction(fromHHmm: "00:00") == 0)
    #expect(WakingDay.fraction(fromHHmm: "06:00") == 0.25)
    #expect(WakingDay.fraction(fromHHmm: "12:00") == 0.5)
    #expect(WakingDay.fraction(fromHHmm: nil) == nil)
    #expect(WakingDay.fraction(fromHHmm: "garbage") == nil)
  }
}
