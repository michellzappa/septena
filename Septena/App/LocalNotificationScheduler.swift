import Foundation
import SwiftData
#if canImport(UIKit)
import UserNotifications
#endif

// Central consumer of every plugin's `notificationDescriptors`. The same
// machine as `BadgeManager` — bound to a `ModelContext`, woken by the same
// data-change notifications — but instead of an icon badge it produces the
// app's local-notification schedule.
//
// Flow on each reconcile:
//   1. master toggle + per-section enablement gate (mirrors NextFeed)
//   2. ask each enabled plugin to evaluate each of its (toggled-on) descriptors
//   3. a non-nil `NotificationPlan` → a pending `UNCalendarNotificationTrigger`;
//      a nil → withdraw that descriptor's pending request (auto-suppression)
//
// Requests are keyed by descriptor id, so reconciling is idempotent: re-adding
// replaces, and stale requests (toggled off, section disabled, or now
// suppressed) are removed. Triggers are non-repeating matches on hour:minute,
// so each fires at the next occurrence and is re-armed on the following
// reconcile (cold launch, foreground, or any section data change).
//
// macOS has no `UserNotifications` scheduling surface we use here, so the
// whole body is `#if canImport(UIKit)` — on Mac the scheduler is an inert
// singleton, exactly like BadgeManager's platform split.

@MainActor
final class LocalNotificationScheduler {
  static let shared = LocalNotificationScheduler()

  /// Master on/off. Absent → on (the user opted in by granting permission).
  static let masterKey = "septena.notify.enabled"
  /// Prefix for our OS request identifiers, so reconcile only ever touches
  /// requests this scheduler owns.
  private static let requestPrefix = "septena.notify.req."

  /// Quiet window — no nudges fire between these hours (except descriptors
  /// flagged `quietHoursExempt`, e.g. the bedtime wind-down).
  private static let quietStartHour = 21   // 21:00
  private static let quietEndHour = 8       // 08:00
  /// Hard ceiling on how many *non-exempt* nudges may be pending at once.
  /// With the calm descriptor set this is slack, but it caps any future growth.
  private static let dailyCap = 3

  /// A descriptor paired with the concrete plan it produced this reconcile.
  /// Carrying the descriptor lets quiet-hours/cap/category logic read its
  /// metadata without a second lookup.
  private struct Nudge {
    let descriptor: NotificationDescriptor
    let plan: NotificationPlan
  }

  private weak var contextRef: ModelContext?
  private var observers: [NSObjectProtocol] = []
  private var started = false

  private init() {}

  // MARK: Lifecycle

  func start(context: ModelContext) {
    contextRef = context
    guard !started else { reconcile(); return }
    started = true
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      .septenaTasksChanged, .septenaDataChanged, .septenaOuraChanged,
      UserDefaults.didChangeNotification,
    ]
    for name in names {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.reconcile() }
      })
    }
    registerCategories()
    reconcile()
  }

  /// Register one `UNNotificationCategory` per descriptor that declares
  /// actions, keyed by descriptor id. A notification references its category
  /// via `content.categoryIdentifier`; the AppDelegate handler dispatches the
  /// tapped action by id. Idempotent — re-setting the full category set is
  /// how UNUserNotificationCenter expects updates.
  private func registerCategories() {
    #if canImport(UIKit)
    var categories: Set<UNNotificationCategory> = []
    for plugin in SectionRegistry.all {
      for descriptor in plugin.notificationDescriptors where !descriptor.actions.isEmpty {
        let actions = descriptor.actions.map { action in
          UNNotificationAction(identifier: action.id, title: action.title,
                               options: action.opensApp ? [.foreground] : [])
        }
        categories.insert(UNNotificationCategory(identifier: descriptor.id,
                                                 actions: actions,
                                                 intentIdentifiers: [],
                                                 options: []))
      }
    }
    UNUserNotificationCenter.current().setNotificationCategories(categories)
    #endif
  }

  /// Ask once, on first launch only. A denial is honored silently —
  /// `apply` no-ops when authorization isn't granted.
  func requestAuthorizationIfNeeded() async {
    #if canImport(UIKit)
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .notDetermined else { return }
    _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    #endif
  }

  // MARK: Reconcile

  func reconcile() {
    #if canImport(UIKit)
    guard let context = contextRef else { return }
    let nudges = Self.masterEnabled ? computeNudges(context: context) : []
    Task { await apply(nudges: nudges) }
    #endif
  }

  /// Enumerate enabled plugins → toggled-on descriptors → live evaluation,
  /// then apply the calm filters: drop nudges that fall in quiet hours
  /// (unless exempt), and keep only the top `dailyCap` non-exempt ones by
  /// priority. Pure read over the local store.
  private func computeNudges(context: ModelContext) -> [Nudge] {
    let enabledSections = Set(
      SettingsMirror.loadSections(context: context).filter(\.isEnabled).map(\.key)
    )
    let now = Date()
    var nudges: [Nudge] = []
    for plugin in SectionRegistry.all {
      guard enabledSections.contains(plugin.manifest.key) else { continue }
      for descriptor in plugin.notificationDescriptors {
        guard Self.isEnabled(descriptor) else { continue }
        guard let plan = plugin.evaluateNotification(descriptor.id, context: context, now: now)
        else { continue }
        // Quiet hours: keep only if outside 21:00–08:00, or the descriptor is
        // exempt (the bedtime wind-down, which is *about* that window).
        if !descriptor.quietHoursExempt && Self.isQuietHour(plan.hour) { continue }
        nudges.append(Nudge(descriptor: descriptor, plan: plan))
      }
    }
    // Daily cap on non-exempt nudges, highest priority first. Exempt ones
    // (bedtime) are always kept and don't count against the cap.
    let exempt = nudges.filter { $0.descriptor.quietHoursExempt }
    let capped = nudges
      .filter { !$0.descriptor.quietHoursExempt }
      .sorted { $0.descriptor.priority > $1.descriptor.priority }
      .prefix(Self.dailyCap)
    return exempt + Array(capped)
  }

  private static func isQuietHour(_ hour: Int) -> Bool {
    // Window wraps midnight: [21:00, 24:00) ∪ [00:00, 08:00).
    hour >= quietStartHour || hour < quietEndHour
  }

  #if canImport(UIKit)
  private func apply(nudges: [Nudge]) async {
    let center = UNUserNotificationCenter.current()
    let status = await center.notificationSettings().authorizationStatus
    let granted = status == .authorized || status == .provisional

    let pending = await center.pendingNotificationRequests()
    let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.requestPrefix) }

    // No permission (or master off → empty plans): clear everything we own.
    guard granted else {
      center.removePendingNotificationRequests(withIdentifiers: ours)
      return
    }

    let desired = Set(nudges.map { Self.requestID($0.plan.descriptorID) })
    let stale = ours.filter { !desired.contains($0) }
    if !stale.isEmpty {
      center.removePendingNotificationRequests(withIdentifiers: stale)
    }

    for nudge in nudges {
      let plan = nudge.plan
      let content = UNMutableNotificationContent()
      content.title = plan.title
      content.body = plan.body
      content.threadIdentifier = plan.threadID
      content.sound = .default
      // Only attach a category when the descriptor has actions — otherwise the
      // OS renders an empty action area.
      if !nudge.descriptor.actions.isEmpty {
        content.categoryIdentifier = nudge.descriptor.id
      }
      if !plan.userInfo.isEmpty {
        content.userInfo = plan.userInfo
      }
      var comps = DateComponents()
      comps.hour = plan.hour
      comps.minute = plan.minute
      let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
      let request = UNNotificationRequest(identifier: Self.requestID(plan.descriptorID),
                                          content: content, trigger: trigger)
      // Re-adding with the same identifier replaces the existing request.
      try? await center.add(request)
    }
  }
  #endif

  // MARK: Toggle reads

  private static var masterEnabled: Bool {
    boolDefault(masterKey, fallback: true)
  }

  private static func isEnabled(_ descriptor: NotificationDescriptor) -> Bool {
    boolDefault(descriptor.defaultsKey, fallback: descriptor.defaultEnabled)
  }

  /// Read a Bool default that defaults to `fallback` when the user has never
  /// set it (UserDefaults.bool returns false for an absent key).
  private static func boolDefault(_ key: String, fallback: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
  }

  private static func requestID(_ descriptorID: String) -> String {
    requestPrefix + descriptorID
  }
}
