import Foundation

// Live-fasting state machine. The backend's 7-day chart anchors each
// window from "prev day's last eating event → today's first eating
// event"; this module answers the live question "am I fasting right
// now?". Mirrors septena-app/lib/fasting.ts so iOS and web agree on
// what counts as a last meal of the day.

public enum FastingDefaults {
  /// Hour of day after which a post-dinner fast window starts.
  public static let eveningHour24h: Int = 19
  /// Minutes after the latest meal before the timer activates.
  public static let postMealGraceMin: Int = 30
  /// Default target fasting band (hours). Used until macros-config loads.
  public static let targetMinH: Double = 14
  public static let targetMaxH: Double = 16
}

public struct FastingConfig: Equatable, Sendable {
  public var eveningHour: Int
  public var graceMin: Int

  public init(eveningHour: Int = FastingDefaults.eveningHour24h,
              graceMin: Int = FastingDefaults.postMealGraceMin) {
    self.eveningHour = eveningHour
    self.graceMin = graceMin
  }
}

public struct FastingStateInputs: Equatable, Sendable {
  /// HH:MM of the most recent eating event today, or nil if none.
  public var todayLatestMeal: String?
  public var todayMealCount: Int
  /// HH:MM of yesterday's final eating event, or nil if none.
  public var yesterdayLastMeal: String?

  public init(todayLatestMeal: String?, todayMealCount: Int, yesterdayLastMeal: String?) {
    self.todayLatestMeal = todayLatestMeal
    self.todayMealCount = todayMealCount
    self.yesterdayLastMeal = yesterdayLastMeal
  }
}

public enum FastingState: Equatable, Sendable {
  case fed
  case fasting(sinceDay: SinceDay, sinceTime: String, totalMin: Int)

  public enum SinceDay: Sendable { case today, yesterday }

  public var isFasting: Bool {
    if case .fasting = self { return true }
    return false
  }

  public var hoursAndMinutes: (h: Int, m: Int)? {
    guard case .fasting(_, _, let total) = self else { return nil }
    return (total / 60, total % 60)
  }
}

private func parseHM(_ hm: String, dayOffset: Int, now: Date, calendar: Calendar) -> Date? {
  let parts = hm.split(separator: ":").compactMap { Int($0) }
  guard parts.count >= 2 else { return nil }
  guard let base = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { return nil }
  return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: base)
}

public func computeFastingState(
  inputs: FastingStateInputs?,
  config: FastingConfig = FastingConfig(),
  now: Date = Date(),
  calendar: Calendar = .current
) -> FastingState {
  guard let inputs else { return .fed }

  // Case A: overnight fast still running — nothing eaten today yet.
  if inputs.todayMealCount == 0, let yest = inputs.yesterdayLastMeal,
     let then = parseHM(yest, dayOffset: 1, now: now, calendar: calendar) {
    let diff = now.timeIntervalSince(then)
    if diff > 0 {
      return .fasting(sinceDay: .yesterday, sinceTime: yest, totalMin: Int(diff / 60))
    }
  }

  // Case B: post-dinner, new fast window beginning.
  let hour = calendar.component(.hour, from: now)
  if hour >= config.eveningHour, let today = inputs.todayLatestMeal,
     let then = parseHM(today, dayOffset: 0, now: now, calendar: calendar) {
    let totalMin = Int(now.timeIntervalSince(then) / 60)
    if totalMin >= config.graceMin {
      return .fasting(sinceDay: .today, sinceTime: today, totalMin: totalMin)
    }
  }

  return .fed
}
