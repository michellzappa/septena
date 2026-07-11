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

  private init() {
    refreshAccess()
  }

  // MARK: - Hidden calendars
  //
  // User-controlled per-calendar visibility, persisted by `EKCalendar.title`.
  // We treat hidden calendars as if they weren't there — both fetch helpers
  // strip them, so consumers (timeline, Next, dashboards) don't have to know.
  //
  // Title — not `calendarIdentifier` — is the key on purpose: EventKit assigns
  // identifiers per-store, so the same iCloud calendar has a different id on
  // each device. Matching by title is what lets the synced selection ("set it
  // up once") resolve to the right calendars everywhere. The CloudKit round-trip
  // lives in `SettingsStore` (the `calendarHiddenTitles` settings field); this
  // UserDefaults cache is the offline-safe local authority the fetch filters use.

  private static let hiddenTitlesKey = "septena.calendar.hiddenCalendarTitles"
  /// Pre-sync key, stored `calendarIdentifier`s. Migrated to titles once, then removed.
  private static let legacyHiddenIDsKey = "septena.calendar.hiddenCalendarIDs"

  var hiddenCalendarTitles: Set<String> = Set(UserDefaults.standard.stringArray(forKey: hiddenTitlesKey) ?? []) {
    didSet {
      UserDefaults.standard.set(Array(hiddenCalendarTitles), forKey: Self.hiddenTitlesKey)
    }
  }

  func isHidden(_ cal: EKCalendar) -> Bool {
    hiddenCalendarTitles.contains(cal.title)
  }

  func setHidden(_ hidden: Bool, for cal: EKCalendar) {
    var s = hiddenCalendarTitles
    if hidden { s.insert(cal.title) }
    else      { s.remove(cal.title) }
    hiddenCalendarTitles = s
  }

  /// Every event calendar the user has, sorted by title for stable UI. Also the
  /// point where any legacy identifier-keyed selection is folded into the
  /// title-keyed set (we have the `EKCalendar`s in hand here to map id → title).
  func allCalendars() -> [EKCalendar] {
    guard access == .granted else { return [] }
    let cals = store.calendars(for: .event)
    migrateLegacyHiddenIfNeeded(from: cals)
    return cals
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  /// One-shot: translate any pre-sync `hiddenCalendarIDs` (identifiers) into the
  /// title-keyed set, then drop the legacy key so this never runs again. No-op
  /// once migrated. Keeps an existing local selection from silently resetting on
  /// the upgrade that moved this preference to titles.
  private func migrateLegacyHiddenIfNeeded(from cals: [EKCalendar]) {
    let defaults = UserDefaults.standard
    guard let legacy = defaults.stringArray(forKey: Self.legacyHiddenIDsKey), !legacy.isEmpty else { return }
    let legacyIDs = Set(legacy)
    let titles = cals.filter { legacyIDs.contains($0.calendarIdentifier) }.map(\.title)
    if !titles.isEmpty { hiddenCalendarTitles.formUnion(titles) }
    defaults.removeObject(forKey: Self.legacyHiddenIDsKey)
  }

  /// Calendars to actually query — drops user-hidden ones. Returns nil
  /// when nothing is hidden so EventKit can take its default fast path.
  private var visibleCalendars: [EKCalendar]? {
    if hiddenCalendarTitles.isEmpty { return nil }
    return store.calendars(for: .event).filter { !hiddenCalendarTitles.contains($0.title) }
  }

  enum Access {
    case granted
    case writeOnly        // useless to us, treat as denied
    case denied
    case notDetermined
  }

  /// Observable permission snapshot. EventKit's class-level authorization
  /// query does not by itself invalidate SwiftUI views.
  private(set) var access: Access = .notDetermined

  private static func currentAccess() -> Access {
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

  /// Re-check after a system permission sheet or a trip through Settings.
  func refreshAccess() {
    access = Self.currentAccess()
  }

  func requestAccess() async -> Bool {
    do {
      let granted: Bool
      if #available(iOS 17.0, macOS 14.0, *) {
        granted = try await store.requestFullAccessToEvents()
      } else {
        granted = try await store.requestAccess(to: .event)
      }
      // The request result is the authoritative immediate answer. EventKit's
      // process-wide status can lag a run-loop turn behind the completion.
      access = granted ? .granted : Self.currentAccess()
      return access == .granted
    } catch {
      refreshAccess()
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

  /// Today's events that haven't ended yet — what's still ahead (ongoing or
  /// upcoming). All-day events run until midnight, so they stay all day. Used by
  /// the Tasks Today agenda, which should clear a meeting once it's over and show
  /// nothing once the day's events are all behind us.
  func remainingTodayEvents() -> [EKEvent] {
    let now = Date()
    return events(on: now).filter { $0.endDate > now }
  }

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
