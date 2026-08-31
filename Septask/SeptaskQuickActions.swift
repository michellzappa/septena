#if os(iOS)
import UIKit
import UserNotifications

// Home Screen Quick Action delivery for Septask.
//
// This is the slim composition-root twin of the full app's
// `AppDelegate` + `SeptenaSceneDelegate`. Septask can't compile those
// verbatim — the full-app `AppDelegate` pulls in notification-action
// handling and life-OS wiring the tasks-only build deliberately omits —
// so per docs/SEPTASK.md this app-level chrome lives in `Septask/` and
// reuses only the SHARED pieces that already compile: the `ShortcutAction`
// enum and `NavigationState.pendingShortcut`. The one static item Septask
// ships is "New To-Do" (declared in Info.plist); tapping it lands the
// quick-add composer.
//
// Two delivery paths, both funneling into `dispatch(_:)`:
//   • cold launch → the scene delegate's `scene(_:willConnectTo:options:)`
//     (with `UIApplicationSupportsMultipleScenes = true`, the tapped item
//     rides `UIScene.ConnectionOptions`, not `launchOptions`), plus the
//     `willFinishLaunchingWithOptions` fallback below;
//   • warm activation → `windowScene(_:performActionFor:)`.
// `dispatch` publishes immediately if `NavigationState` is alive, else
// stashes for `SeptaskApp.task` to drain on first render.
// `UIResponder`, not `NSObject` — load-bearing. `undoManager` is a
// `UIResponder` property, so an `NSObject` delegate cannot override it (the
// compiler says "does not override any property from its superclass") and the
// app delegate would not sit in the responder chain the lookup walks.
final class SeptaskAppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  /// Captured at cold launch before `NavigationState` exists; drained by
  /// `SeptaskApp.task`.
  private static var pending: ShortcutAction?
  /// Set by `SeptaskApp` once `NavigationState` is alive — lets warm-launch
  /// taps publish straight through without a stash.
  static weak var navigation: NavigationState?

  static func consumePendingShortcut() -> ShortcutAction? {
    defer { pending = nil }
    return pending
  }

  /// Shake-to-undo and three-finger undo — same responder-chain hookup as
  /// Septena's `AppDelegate`. See `TaskUndo` for why one stack is shared by
  /// all four task surfaces.
  override var undoManager: UndoManager? { TaskUndo.manager }

  static func dispatch(_ action: ShortcutAction) {
    if let nav = navigation {
      Task { @MainActor in nav.pendingShortcut = action }
    } else {
      pending = action
    }
  }

  /// Septask owns the same Claude reconnect notification path as Septena.
  /// Registering the delegate at launch lets both the action button and a
  /// plain notification tap re-mint the hosted gateway token in this app.
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions:
      [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    Task { @MainActor in ClaudeReconnectNudge.shared.start() }
    return true
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let actionID = response.actionIdentifier
    let userInfo = response.notification.request.content.userInfo
    guard actionID == NotificationActionID.claudeReconnect || userInfo["claudeReconnect"] != nil else {
      completionHandler()
      return
    }
    Task { @MainActor in
      // A notification can cold-launch us before the SwiftUI scene has bound
      // the task stack. Start is idempotent, and refresh is deliberately an
      // explicit user action here so the Apple sign-in sheet may appear.
      await SeptenaServices.shared.start()
      await ClaudeGatewayProvider.shared.refreshIfNeeded(force: true)
      ClaudeReconnectNudge.shared.reconcile()
      completionHandler()
    }
  }

  func application(
    _ application: UIApplication,
    willFinishLaunchingWithOptions launchOptions:
      [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem,
       let action = ShortcutAction(rawValue: item.type) {
      Self.pending = action
      // Return false so the system does NOT also call performActionFor on
      // cold launch — we've already captured it (mirrors the full app).
      return false
    }
    return true
  }

  /// Point new scenes at `SeptaskSceneDelegate`. Without an explicit
  /// delegate class, iOS uses a no-op default and silently drops the
  /// cold-launch quick action.
  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: "Default",
                                      sessionRole: connectingSceneSession.role)
    config.delegateClass = SeptaskSceneDelegate.self
    return config
  }
}

final class SeptaskSceneDelegate: NSObject, UIWindowSceneDelegate {
  var window: UIWindow?

  /// Cold-launch / scene-reconnect entry point.
  func scene(_ scene: UIScene,
             willConnectTo session: UISceneSession,
             options connectionOptions: UIScene.ConnectionOptions) {
    if let item = connectionOptions.shortcutItem,
       let action = ShortcutAction(rawValue: item.type) {
      SeptaskAppDelegate.dispatch(action)
    }
  }

  /// Warm activation entry point — tap while the app is suspended.
  func windowScene(_ windowScene: UIWindowScene,
                   performActionFor shortcutItem: UIApplicationShortcutItem,
                   completionHandler: @escaping (Bool) -> Void) {
    guard let action = ShortcutAction(rawValue: shortcutItem.type) else {
      completionHandler(false); return
    }
    SeptaskAppDelegate.dispatch(action)
    completionHandler(true)
  }
}
#endif
