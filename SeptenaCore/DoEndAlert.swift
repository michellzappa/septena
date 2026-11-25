import Foundation
import UserNotifications

/// The local notification when a planned length ends (docs/DO_SPEC.md §4). Only
/// the device that shows the Do arms it, so nothing else signals the end.
@MainActor
enum DoEndAlert {
  private static let requestID = "septena.do.plannedEnd"
  private static var armed: DoState?

  static func update(for doing: DoState?) {
    guard doing != armed else { return }
    armed = doing
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [requestID])
    center.removeDeliveredNotifications(withIdentifiers: [requestID])
    guard let doing, let end = doing.plannedEnd, let planned = doing.plannedMinutes else { return }
    let seconds = end.timeIntervalSinceNow
    guard seconds > 1 else { return }
    let content = UNMutableNotificationContent()
    content.title = doing.title
    content.body = RegistryDoing.plannedEnd(count: planned)
    content.sound = .default
    // Silent until the user allowed alerts. A Do never asks for them by itself
    // unless the user set a length (`requestAccess`).
    center.add(UNNotificationRequest(
      identifier: requestID, content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
  }

  /// Called when the user picks a length.
  static func requestAccess() async {
    guard await TaskReminderScheduler.shared.requestAuthorizationIfNeeded() else { return }
    let doing = armed
    armed = nil
    update(for: doing)
  }
}
