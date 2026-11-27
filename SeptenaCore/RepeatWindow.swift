import Foundation
import SeptenaSharedCore

struct RepeatWindow: Decodable {
  let create: [String]
  let expireBefore: String?

  static func plan(rule: Recurrence, lastSlot: String, at now: Date,
                   zone: String?, startTime: String?) -> Self? {
    guard let missed = rule.missed, missed.advancesOnSchedule else { return nil }
    let clock = DateFormatter()
    clock.calendar = Calendar(identifier: .gregorian)
    clock.locale = Locale(identifier: "en_US_POSIX")
    clock.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
    clock.dateFormat = "yyyy-MM-dd'T'HH:mm"
    let local = clock.string(from: now).split(separator: "T")
    guard local.count == 2 else { return nil }
    var cadence: [String: Any] = [
      "unit": rule.unit.rawValue,
      "interval": rule.interval,
      "afterCompletion": rule.afterCompletion,
    ]
    cadence["weekdays"] = rule.weekdays
    cadence["monthDay"] = rule.monthDay
    if let ordinal = rule.ordinalWeekday {
      cadence["ordinalWeekday"] = ["ordinal": ordinal.ordinal, "weekday": ordinal.weekday]
    }
    var input: [String: Any] = [
      "mode": missed.rawValue, "lastSlot": lastSlot, "today": String(local[0]),
      "localTime": String(local[1]), "rule": cadence,
    ]
    input["startTime"] = startTime
    do {
      let data = try JSONSerialization.data(withJSONObject: input)
      let result = try invokeJson(function: "recurrenceWindow", inputJson: String(decoding: data, as: UTF8.self))
      return try JSONDecoder().decode(Self.self, from: Data(result.utf8))
    } catch {
      SeptenaLog.error("[Repeat] Could not reconcile calendar slots", error)
      return nil
    }
  }
}
