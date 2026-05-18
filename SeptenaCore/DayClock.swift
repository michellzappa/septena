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
    let nowDate = Date()
    if now != nowDate { now = nowDate }
    let day = SeptenaDate.today
    if day != today { today = day }
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
