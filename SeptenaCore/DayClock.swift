import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Single source of truth for "what day is it" and "what time is it now"
// across the app. Views observe this instead of calling `SeptenaDate.today`
// or `Date()` directly, so a session that crosses midnight (or sits idle
// for a minute) updates uniformly:
//
//   • `today` republishes on `.NSCalendarDayChanged` and on every
//     `refreshIfNeeded()` (called from scenePhase → .active in the App).
//     Backgrounded apps don't reliably receive NSCalendarDayChanged, so
//     the foreground check covers the "opened after midnight" case.
//   • `now` ticks every 60s on a single Timer so the DayTimeline cursor
//     and the Nutrition fasting row share one clock instead of each view
//     spinning up its own publisher.
//
// `today` is the YYYY-MM-DD string the rest of the app already speaks
// (see `SeptenaDate`). Views attach `.onChange(of: clock.today) { reload() }`
// to refetch day-scoped data at rollover.

@MainActor
@Observable
public final class DayClock {
  public private(set) var today: String = SeptenaDate.today
  public private(set) var now: Date = Date()

  #if DEBUG
  /// Debug time-travel: shifts the whole app's notion of "now" by this many
  /// days (0 = real today, clamped to the last week by the caller). Because
  /// every day-scoped view observes `today`/`now`, setting this navigates
  /// the entire homepage's data at once — used by the dashboard's ⟨ / ⟩
  /// keyboard shortcuts to inspect SolarClock + past days. Compiled out of
  /// Release entirely.
  public var debugDayOffset: Int = 0 { didSet { refreshIfNeeded() } }
  #endif

  @ObservationIgnored private var dayObserver: NSObjectProtocol?
  @ObservationIgnored private var minuteTimer: Timer?

  public init() {
    dayObserver = NotificationCenter.default.addObserver(
      forName: .NSCalendarDayChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshIfNeeded() }
    }
    scheduleMinuteTimer()
  }

  deinit {
    if let dayObserver { NotificationCenter.default.removeObserver(dayObserver) }
    minuteTimer?.invalidate()
  }

  /// Pull fresh values from the system clock. Cheap; safe to call often.
  /// Called from `scenePhase → .active` so the day flips when the app
  /// returns from background across midnight.
  public func refreshIfNeeded() {
    let nowDate = currentInstant()
    if now != nowDate { now = nowDate }
    let day = SeptenaDate.format(nowDate) ?? today
    if day != today { today = day }
    #if DEBUG
    DayClock.travelledToday = debugDayOffset == 0 ? nil : day
    #endif
  }

  #if DEBUG
  /// Process-wide mirror of the time-travelled day, published by
  /// `refreshIfNeeded`. Nil whenever the offset is 0 (the normal case).
  private static var travelledToday: String?
  #endif

  /// "What day is it" for non-view code — the write paths that can't observe
  /// an injected clock but must still agree with what the user is looking at.
  /// Task recurrence is the motivating case: completing a repeat computes the
  /// next date, and reading the real `Date()` there made time travel useless
  /// for the one feature it's most needed to test. Release builds always get
  /// the real day; there is no offset to honor.
  public static var appToday: String {
    #if DEBUG
    return travelledToday ?? SeptenaDate.today
    #else
    return SeptenaDate.today
    #endif
  }

  /// Instant counterpart to `appToday`, for stamps that must agree with it.
  public static var appNow: Date {
    #if DEBUG
    guard let travelledToday, let day = SeptenaDate.parse(travelledToday) else { return Date() }
    // Keep the real wall-clock time, move the calendar day.
    let real = Date()
    let cal = Calendar.current
    let t = cal.dateComponents([.hour, .minute, .second], from: real)
    return cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: t.second ?? 0,
                    of: day) ?? real
    #else
    return Date()
    #endif
  }

  /// The system instant, shifted by `debugDayOffset` in DEBUG builds. In
  /// Release this is just `Date()` (the offset doesn't exist).
  private func currentInstant() -> Date {
    let base = Date()
    #if DEBUG
    if debugDayOffset != 0 {
      return Calendar.current.date(byAdding: .day, value: debugDayOffset, to: base) ?? base
    }
    #endif
    return base
  }

  private func scheduleMinuteTimer() {
    minuteTimer?.invalidate()
    let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshIfNeeded() }
    }
    t.tolerance = 5
    RunLoop.main.add(t, forMode: .common)
    minuteTimer = t
  }
}
