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

  func application(
    _ application: UIApplication,
    willFinishLaunchingWithOptions launchOptions:
      [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // Touch SeptenaServices eagerly during launch. Two reasons:
    //   1. When iOS wakes us in the background to deliver a CoreBluetooth
    //      event, the CBCentralManager has to be reconstructed *before*
    //      `willRestoreState` can fire. Without this touch the engines
    //      stay un-init'd until SwiftUI mounts, which is too late.
    //   2. If the user has the "Background capture" toggle on, we need
    //      to immediately re-arm the BLE scan with the same restore
    //      identifier so iOS pairs us back with the queued scan state.
    //
    // The MainActor hop is unfortunate — UIKit calls this method on
    // the main thread but it's not declared @MainActor, so we have
    // to context-switch explicitly. The Task is fire-and-forget;
    // the willRestore deadline is generous (several seconds).
    Task { @MainActor in
      let services = SeptenaServices.shared
      if services.aranetBridge.backgroundCaptureEnabled {
        services.aranetBridge.start()
      }
    }
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
    if let nav = Self.navigation {
      Task { @MainActor in nav.pendingShortcut = action }
    } else {
      Self.pending = action
    }
    completionHandler(true)
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
