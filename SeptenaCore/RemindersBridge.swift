import Foundation
import EventKit

// Bridge to Apple Reminders. Lets the user nominate one Reminders list as
// Septena's "inbox source"; pending reminders from that list surface in the
// Septena Inbox as task-style rows and can be imported with one tap. Import
// always deletes the original reminder so dedupe is implicit.

@MainActor
final class RemindersBridge: ObservableObject {
  static let shared = RemindersBridge()

  let store = EKEventStore()

  private init() {}

  // MARK: - Auth

  enum Access {
    case granted        // .fullAccess (or legacy .authorized)
    case writeOnly      // can write but not read — useless for import
    case denied
    case notDetermined
  }

  var access: Access {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    if #available(iOS 17.0, macOS 14.0, *) {
      switch status {
      case .fullAccess: return .granted
      case .writeOnly:  return .writeOnly
      case .denied, .restricted: return .denied
      case .notDetermined: return .notDetermined
      @unknown default: return .denied
      }
    } else {
      switch status {
      case .authorized: return .granted
      case .denied, .restricted: return .denied
      case .notDetermined: return .notDetermined
      // .fullAccess / .writeOnly exist on the enum but only get returned on
      // iOS 17+ / macOS 14+. Handle them so the switch is exhaustive on older
      // SDKs too.
      default: return .denied
      }
    }
  }

  func requestAccess() async -> Bool {
    do {
      if #available(iOS 17.0, macOS 14.0, *) {
        return try await store.requestFullAccessToReminders()
      } else {
        return try await store.requestAccess(to: .reminder)
      }
    } catch {
      return false
    }
  }

  // MARK: - Source list (which Reminders list mirrors into the Inbox)

  private static let sourceKey = "septena.reminders.sourceListID"

  var sourceListID: String? {
    get { UserDefaults.standard.string(forKey: Self.sourceKey) }
    set {
      if let v = newValue { UserDefaults.standard.set(v, forKey: Self.sourceKey) }
      else                { UserDefaults.standard.removeObject(forKey: Self.sourceKey) }
      objectWillChange.send()
    }
  }

  func sourceList() -> EKCalendar? {
    guard let id = sourceListID else { return nil }
    return store.calendar(withIdentifier: id)
  }

  // MARK: - Read

  func reminderLists() -> [EKCalendar] {
    store.calendars(for: .reminder)
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  /// Incomplete reminders from `calendar`, in the order Reminders returns them.
  func pendingReminders(in calendar: EKCalendar) async -> [EKReminder] {
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: nil, calendars: [calendar])
    return await withCheckedContinuation { cont in
      store.fetchReminders(matching: predicate) { results in
        cont.resume(returning: results ?? [])
      }
    }
  }

  // MARK: - Delete

  /// Batch-remove the given reminders and commit once.
  func delete(_ reminders: [EKReminder]) throws {
    for r in reminders {
      try store.remove(r, commit: false)
    }
    try store.commit()
  }
}

// MARK: - View-model snapshot

struct ImportedReminder: Identifiable, Hashable {
  let id: String              // EKReminder.calendarItemIdentifier
  let title: String
  let notes: String?
  let dueDate: Date?

  static func == (lhs: ImportedReminder, rhs: ImportedReminder) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }

  init(_ r: EKReminder) {
    self.id = r.calendarItemIdentifier
    self.title = r.title ?? "Untitled"
    self.notes = r.notes
    self.dueDate = r.dueDateComponents?.date
  }
}
