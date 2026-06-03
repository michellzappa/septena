import Foundation

// Manifest seam for local notifications — the third declaration surface a
// section plugin contributes to, alongside `aimMetrics` (goals) and
// `mcpSkill` (agent tools). A plugin *declares* the nudges it wants
// (`NotificationDescriptor`) and *evaluates* each one against the live data
// (`SectionPlugin.evaluateNotification`); the central
// `LocalNotificationScheduler` consumes every plugin's declarations, picks
// fire-times, and reconciles them with `UNUserNotificationCenter`.
//
// The philosophy is "nudge to mark, don't nag to do": a nudge fires around
// the time the user *usually logs* that activity (learned from history) and
// auto-suppresses the moment it's already logged today. Suppression is the
// `nil` return from `evaluateNotification` — the scheduler removes any
// pending request whose descriptor produced no plan.
//
// These types live in SeptenaCore (UI-free) so the app target, tests, and
// any future surface can share them. The plugins and scheduler that consume
// them live in the app target because they touch SwiftUI / UserNotifications.

/// One inline action button on a notification. The `id` is matched in the
/// AppDelegate's response handler to route to a mutator; declare the same
/// id string here and there via `NotificationActionID`.
public struct NotificationAction: Sendable, Hashable {
  public let id: String
  public let title: String
  /// `true` brings the app to the foreground when tapped (e.g. "Open");
  /// `false` performs the action in the background (the common "mark"/"log"
  /// case — no app switch).
  public let opensApp: Bool

  public init(id: String, title: String, opensApp: Bool = false) {
    self.id = id
    self.title = title
    self.opensApp = opensApp
  }
}

/// Stable action identifiers, shared by the descriptors that declare them and
/// the AppDelegate handler that dispatches them. One source of truth so the
/// button and its behavior can't drift.
public enum NotificationActionID {
  public static let choreComplete   = "septena.action.chores.complete"
  public static let hydrationAdd250 = "septena.action.hydration.add250"
  public static let hydrationAdd500 = "septena.action.hydration.add500"
}

/// Keys for the per-notification `userInfo` payload the handler reads back.
public enum NotificationUserInfoKey {
  public static let choreID = "choreID"
}

/// One nudge a section can raise. Identity + the copy shown on its Settings
/// toggle; the actual content + fire-time are produced per-evaluation.
public struct NotificationDescriptor: Sendable, Hashable, Identifiable {
  /// Stable, dotted id — `"<section>.<nudge>"`, e.g. `"chores.overdue"`.
  /// Doubles as the per-nudge Settings toggle key suffix, the OS request
  /// identifier suffix, AND the `UNNotificationCategory` id, so a descriptor
  /// maps 1:1 to one pending request and one action category.
  public let id: String
  /// Owning section's manifest key. The scheduler only evaluates descriptors
  /// whose section is enabled, matching the Next-feed enablement gate.
  public let sectionKey: String
  /// Human label for the Settings toggle (e.g. "Overdue chore digest").
  public let title: String
  /// Whether this nudge is on for a user who has never touched its toggle.
  public let defaultEnabled: Bool
  /// Inline action buttons. The scheduler registers these as the descriptor's
  /// notification category; the AppDelegate handler dispatches taps by action id.
  public let actions: [NotificationAction]
  /// Tie-break when the daily cap trims the schedule — higher wins.
  public let priority: Int
  /// Nudges normally don't fire 21:00–08:00. Set `true` for ones that are
  /// *about* that window (the bedtime wind-down) so they survive the filter.
  public let quietHoursExempt: Bool

  public init(id: String, sectionKey: String, title: String,
              defaultEnabled: Bool = true,
              actions: [NotificationAction] = [],
              priority: Int = 0,
              quietHoursExempt: Bool = false) {
    self.id = id
    self.sectionKey = sectionKey
    self.title = title
    self.defaultEnabled = defaultEnabled
    self.actions = actions
    self.priority = priority
    self.quietHoursExempt = quietHoursExempt
  }

  /// UserDefaults key backing this nudge's per-section enable toggle.
  /// Writing it posts `UserDefaults.didChangeNotification`, which the
  /// scheduler observes to re-reconcile.
  public var defaultsKey: String { "septena.notify.toggle.\(id)" }
}

/// A concrete nudge the scheduler should have pending: what to say and the
/// wall-clock time-of-day to say it. The scheduler turns `hour`/`minute`
/// into a non-repeating `UNCalendarNotificationTrigger`, so it fires at the
/// next occurrence of that time and is re-armed on the next reconcile.
public struct NotificationPlan: Sendable, Hashable {
  public let descriptorID: String
  public let title: String
  public let body: String
  /// Groups a section's notifications in the OS notification stack.
  public let threadID: String
  public let hour: Int
  public let minute: Int
  /// Extra payload delivered with the notification, read back by the action
  /// handler (e.g. the chore id a "Mark done" button should complete).
  public let userInfo: [String: String]

  public init(descriptorID: String, title: String, body: String,
              threadID: String, hour: Int, minute: Int,
              userInfo: [String: String] = [:]) {
    self.descriptorID = descriptorID
    self.title = title
    self.body = body
    self.threadID = threadID
    self.hour = hour
    self.minute = minute
    self.userInfo = userInfo
  }

  /// Convenience: build a plan from a minutes-since-midnight fire-time.
  public init(descriptorID: String, title: String, body: String,
              threadID: String, minuteOfDay: Int,
              userInfo: [String: String] = [:]) {
    let m = ((minuteOfDay % 1440) + 1440) % 1440
    self.init(descriptorID: descriptorID, title: title, body: body,
              threadID: threadID, hour: m / 60, minute: m % 60, userInfo: userInfo)
  }
}
