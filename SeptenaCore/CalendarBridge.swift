import Foundation
import EventKit
import SwiftUI

// Mirrors RemindersBridge: shared EKEventStore, auth state, and a
// fetch helper for the next N days of events across all calendars.
// Read-only — Septena doesn't write events.

@MainActor
@Observable
final class CalendarBridge {
  static let shared = CalendarBridge()

  let store = EKEventStore()

  private init() {}

  // MARK: - Hidden calendars
  //
  // User-controlled per-calendar visibility, persisted by calendarIdentifier.
  // We treat hidden calendars as if they weren't there — both fetch helpers
  // strip them, so consumers (timeline, Next, dashboards) don't have to know.

  private static let hiddenKey = "septena.calendar.hiddenCalendarIDs"

  var hiddenCalendarIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) {
    didSet {
      UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: Self.hiddenKey)
    }
  }

  func isHidden(_ cal: EKCalendar) -> Bool {
    hiddenCalendarIDs.contains(cal.calendarIdentifier)
  }

  func setHidden(_ hidden: Bool, for cal: EKCalendar) {
    var s = hiddenCalendarIDs
    if hidden { s.insert(cal.calendarIdentifier) }
    else      { s.remove(cal.calendarIdentifier) }
    hiddenCalendarIDs = s
  }

  /// Every event calendar the user has, sorted by title for stable UI.
  func allCalendars() -> [EKCalendar] {
    guard access == .granted else { return [] }
    return store.calendars(for: .event)
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  /// Calendars to actually query — drops user-hidden ones. Returns nil
  /// when nothing is hidden so EventKit can take its default fast path.
  private var visibleCalendars: [EKCalendar]? {
    if hiddenCalendarIDs.isEmpty { return nil }
    return store.calendars(for: .event).filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
  }

  enum Access {
    case granted
    case writeOnly        // useless to us, treat as denied
    case denied
    case notDetermined
  }

  var access: Access {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, macOS 14.0, *) {
      switch status {
      case .fullAccess:        return .granted
      case .writeOnly:         return .writeOnly
      case .denied, .restricted: return .denied
      case .notDetermined:     return .notDetermined
      @unknown default:        return .denied
      }
    } else {
      switch status {
      case .authorized:        return .granted
      case .denied, .restricted: return .denied
      case .notDetermined:     return .notDetermined
      default:                 return .denied
      }
    }
  }

  func requestAccess() async -> Bool {
    do {
      if #available(iOS 17.0, macOS 14.0, *) {
        return try await store.requestFullAccessToEvents()
      } else {
        return try await store.requestAccess(to: .event)
      }
    } catch {
      return false
    }
  }

  /// Events from `Date()` through `Date() + days`. Honors per-calendar
  /// visibility configured in Settings → Calendar.
  func upcomingEvents(days: Int = 7) -> [EKEvent] {
    guard access == .granted else { return [] }
    let start = Date()
    guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: visibleCalendars)
    return store.events(matching: predicate)
      .sorted { $0.startDate < $1.startDate }
  }

  /// Every event on today's date, including ones that have already ended.
  /// Used by the Next screen to surface earlier-today meetings as "Done Today".
  func todayEvents() -> [EKEvent] { events(on: Date()) }

  /// Every event on the given calendar day, including ones that have already
  /// ended — so a scrubbed past day on the dial can show its real meetings.
  func events(on day: Date) -> [EKEvent] {
    guard access == .granted else { return [] }
    let cal = Calendar.current
    let start = cal.startOfDay(for: day)
    guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: visibleCalendars)
    return store.events(matching: predicate)
      .sorted { $0.startDate < $1.startDate }
  }
}
