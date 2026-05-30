#if canImport(UIKit)
import UIKit

// Scene-based Home Screen Quick Action delivery.
//
// The app declares `UIApplicationSupportsMultipleScenes = true` in
// Info.plist, which puts iOS into scene-lifecycle mode. In that mode
// the legacy `UIApplicationDelegate.application(_:performActionFor:)`
// is best-effort at best, and the cold-launch shortcut never appears
// in `launchOptions` — it's delivered via `UIScene.ConnectionOptions`
// instead. Without this delegate, every Home Screen Quick Action
// silently drops on the floor.
//
// Both paths funnel back into `AppDelegate.dispatchShortcut(_:)`, the
// single ingress that either publishes immediately (if `navigation`
// is already alive) or stashes in `pending` for `App.task` to drain.
final class SeptenaSceneDelegate: NSObject, UIWindowSceneDelegate {
  var window: UIWindow?

  /// Cold-launch / scene-reconnect entry point. iOS attaches the tapped
  /// shortcut item to `connectionOptions`; capture it before SwiftUI
  /// mounts and let `App.task` drain it once `NavigationState` exists.
  func scene(_ scene: UIScene,
             willConnectTo session: UISceneSession,
             options connectionOptions: UIScene.ConnectionOptions) {
    if let item = connectionOptions.shortcutItem,
       let action = ShortcutAction(rawValue: item.type) {
      AppDelegate.dispatchShortcut(action)
    }
  }

  /// Warm activation entry point — fires when the user taps a shortcut
  /// while the app is suspended in the background. Same dispatch path
  /// as cold launch; if `NavigationState` is alive (it almost always is
  /// here), the action publishes immediately and the section sheet
  /// presents over whatever tab the user left active.
  func windowScene(_ windowScene: UIWindowScene,
                   performActionFor shortcutItem: UIApplicationShortcutItem,
                   completionHandler: @escaping (Bool) -> Void) {
    guard let action = ShortcutAction(rawValue: shortcutItem.type) else {
      completionHandler(false); return
    }
    AppDelegate.dispatchShortcut(action)
    completionHandler(true)
  }
}
#endif
