import Foundation

#if canImport(UserNotifications)
import UserNotifications
#endif

/// The one-shot, pre-expiry Claude reconnect reminder shared by Septena and
/// Septask. Each app owns its own local-notification queue, so the most
/// recently foregrounded app claims the reminder; a running sibling withdraws
/// its copy through a Darwin notification. Either app can always re-mint the
/// gateway token when the user taps the reminder.
///
/// Runs on macOS as well as iOS. The gate is `canImport(UserNotifications)`,
/// not `canImport(UIKit)`: `ASWebAuthenticationSession` already presents over
/// an `NSWindow` anchor, so the Mac can mint the same token, and the gateway
/// holds ONE rotating credential — a refresh from any app on any device
/// replaces it. Each device still tracks its own last mint (the shared App
/// Group and the token Keychain are both device-local), so two devices can
/// each hold a pending reminder; whichever the user answers wins.
///
/// Every app that schedules this must also handle the tap. The action id is
/// `NotificationActionID.claudeReconnect` — see `MacAppDelegate` (Septena) and
/// `SeptaskMacAppDelegate` (Septask) for the macOS handlers.
@MainActor
public final class ClaudeReconnectNudge {
  public static let shared = ClaudeReconnectNudge()

  public static let notificationID = "septena.claude.connectionNudge"
  private static let notificationMasterKey = "septena.notify.enabled"
  private static let stateChangedDarwinName = "com.septena.claudeGateway.changed"

  #if canImport(UserNotifications)
  private var observers: [NSObjectProtocol] = []
  private var started = false
  #endif

  private init() {}

  /// Start observing connection/toggle changes. This never asks for
  /// notification permission; the owning Settings surface does that only
  /// after the user explicitly visits Notifications.
  public func start() {
    #if canImport(UserNotifications)
    guard !started else {
      activate()
      return
    }
    started = true

    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: .septenaClaudeGatewayChanged, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.reconcile() }
    })
    observers.append(center.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.reconcile() }
    })

    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), nil,
      { _, _, _, _, _ in
        Task { @MainActor in ClaudeReconnectNudge.shared.reconcile() }
      },
      Self.stateChangedDarwinName as CFString, nil, .deliverImmediately)

    registerCategory()
    activate()
    #endif
  }

  /// Call whenever this app comes to the foreground. It becomes the preferred
  /// host for the pending alert when it is allowed to notify, so the user can
  /// reconnect in the app they are actually using without suppressing an
  /// already-authorized sibling app.
  public func activate() {
    #if canImport(UserNotifications)
    Task { @MainActor [weak self] in await self?.claimIfEligibleAndReconcile() }
    #endif
  }

  /// Recompute the single pending alert. Public so Settings can withdraw it
  /// immediately when its per-app toggle changes.
  public func reconcile() {
    #if canImport(UserNotifications)
    Task { @MainActor [weak self] in await self?.apply() }
    #endif
  }

  /// Ask only while the user is intentionally in a Notifications surface.
  /// This is the Septask equivalent of Septena's notifications permission
  /// flow; a first launch never shows a surprise system prompt.
  public func requestAuthorizationIfNeeded() async {
    #if canImport(UserNotifications)
    let center = UNUserNotificationCenter.current()
    let status = await center.notificationSettings().authorizationStatus
    if status == .notDetermined {
      _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }
    activate()
    #endif
  }

  #if canImport(UserNotifications)
  private func registerCategory() {
    let center = UNUserNotificationCenter.current()
    // Capture only immutable Sendable values in UserNotifications' completion
    // handler; obtaining the center again inside avoids crossing its
    // non-Sendable Objective-C instance into that closure.
    let notificationID = Self.notificationID
    center.getNotificationCategories { categories in
      var updated = Set(categories.filter { $0.identifier != notificationID })
      updated.insert(UNNotificationCategory(
        identifier: notificationID,
        actions: [UNNotificationAction(
          identifier: NotificationActionID.claudeReconnect,
          title: "Reconnect", options: [.foreground])],
        intentIdentifiers: [], options: []))
      UNUserNotificationCenter.current().setNotificationCategories(updated)
    }
  }

  private func apply() async {
    let center = UNUserNotificationCenter.current()
    // Every app can remove only its own pending request. A sibling that is
    // running receives the Darwin hint and clears its stale copy promptly.
    center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])

    let provider = ClaudeGatewayProvider.shared
    provider.reloadSharedState()
    guard ClaudeGatewayProvider.currentAppOwnsReconnectNudge,
          notificationsEnabled,
          provider.isEnabled,
          ClaudeGatewayProvider.connectionNudgeEnabled,
          let target = provider.nudgeFireDate,
          target.timeIntervalSinceNow >= 1
    else { return }

    let status = await center.notificationSettings().authorizationStatus
    guard status == .authorized || status == .provisional else { return }

    let content = UNMutableNotificationContent()
    content.title = "Keep Claude connected"
    content.body = "Your Claude session is about to expire. Tap to refresh while it's still live."
    content.threadIdentifier = "septena.claude"
    content.sound = .default
    content.interruptionLevel = .timeSensitive
    content.categoryIdentifier = Self.notificationID
    content.userInfo = ["claudeReconnect": true]

    let trigger = UNTimeIntervalNotificationTrigger(
      timeInterval: target.timeIntervalSinceNow, repeats: false)
    let request = UNNotificationRequest(
      identifier: Self.notificationID, content: content, trigger: trigger)
    try? await center.add(request)
  }

  private func claimIfEligibleAndReconcile() async {
    let provider = ClaudeGatewayProvider.shared
    provider.reloadSharedState()
    guard notificationsEnabled,
          provider.isEnabled,
          ClaudeGatewayProvider.connectionNudgeEnabled
    else {
      reconcile()
      return
    }
    let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    guard status == .authorized || status == .provisional else {
      reconcile()
      return
    }
    ClaudeGatewayProvider.claimReconnectNudge()
    reconcile()
  }

  private var notificationsEnabled: Bool {
    UserDefaults.standard.object(forKey: Self.notificationMasterKey) as? Bool ?? true
  }
  #endif
}
