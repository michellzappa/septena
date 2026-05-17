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

  /// Events from `Date()` through `Date() + days`. All calendars; the
  /// user filters via the system calendar app (hide/show), not us.
  func upcomingEvents(days: Int = 7) -> [EKEvent] {
    guard access == .granted else { return [] }
    let start = Date()
    guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    return store.events(matching: predicate)
      .sorted { $0.startDate < $1.startDate }
  }
}
