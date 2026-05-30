#if canImport(UIKit)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
  /// Captured at cold launch before NavigationState exists. The app's
  /// `.task` drains this on first render.
  private static var pending: ShortcutAction?
  /// Set by SeptenaApp once NavigationState is alive — lets warm-launch
  /// shortcut events publish directly without a stash.
  static weak var navigation: NavigationState?
  /// Set by SeptenaApp once the CloudKit engine exists. Silent CK pushes
  /// route through here to `engine.handleRemoteNotification`. Weak so
  /// app teardown doesn't leak.
  static weak var ckEngine: CKEngine?

  static func consumePendingShortcut() -> ShortcutAction? {
    defer { pending = nil }
    return pending
  }

  /// Single ingress for Quick Action delivery from any of the three
  /// paths (cold-launch scene options, warm scene activation, legacy
  /// UIApplicationDelegate fallback). If `navigation` is already alive
  /// — meaning the SwiftUI scene has mounted and stashed it on us —
  /// the action publishes immediately; otherwise it stays in `pending`
  /// for App's `.task` to drain on first render.
  static func dispatchShortcut(_ action: ShortcutAction) {
    if let nav = navigation {
      Task { @MainActor in nav.pendingShortcut = action }
    } else {
      pending = action
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
      // Return false so the system does NOT also call performActionFor
      // on cold launch — we've already captured it.
      return false
    }
    return true
  }

  func application(
    _ application: UIApplication,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    guard let action = ShortcutAction(rawValue: shortcutItem.type) else {
      completionHandler(false); return
    }
    Self.dispatchShortcut(action)
    completionHandler(true)
  }

  /// Hand iOS a scene configuration that points at SeptenaSceneDelegate.
  /// Required so scene-based shortcut delivery (`UIScene.ConnectionOptions
  /// .shortcutItem` on cold launch; `windowScene(_:performActionFor:)` on
  /// warm) actually fires — without an explicit delegate class, iOS uses
  /// a no-op default and silently drops Home Screen Quick Actions.
  func application(_ application: UIApplication,
                   configurationForConnecting connectingSceneSession: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: "Default",
                                       sessionRole: connectingSceneSession.role)
    config.delegateClass = SeptenaSceneDelegate.self
    return config
  }

  /// Silent CK pushes arrive here. CKSyncEngine's database subscription
  /// triggers a content-available push when another device writes; we
  /// hand the payload to the engine which translates it into a fetch.
  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    Task { @MainActor in
      let handled = await Self.ckEngine?.handleRemoteNotification(userInfo) ?? false
      completionHandler(handled ? .newData : .noData)
    }
  }
}
#endif

#if canImport(AppKit)
import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {
  static weak var ckEngine: CKEngine?

  func application(_ application: NSApplication,
                   didReceiveRemoteNotification userInfo: [String: Any]) {
    Task { @MainActor in
      await Self.ckEngine?.handleRemoteNotification(userInfo)
    }
  }
}
#endif
