#if canImport(UIKit)
import UIKit
import Foundation

// Bridges the user's Quick Actions selection (UserDefaults
// `septena.quickActions.keys`) into iOS's dynamic shortcuts API.
// Called on app launch and whenever the Settings → Customize → Quick
// Actions pane toggles a row. Idempotent — safe to call as often as the
// settings change.
@MainActor
enum QuickActionsApplier {
  static func apply() {
    let raw = UserDefaults.standard.string(forKey: SettingsKey.quickActionKeys) ?? ""
    let keys = raw
      .split(separator: ",")
      .map(String.init)
      .filter { !$0.isEmpty }
      .prefix(4)

    let items: [UIApplicationShortcutItem] = keys.compactMap { key in
      guard let manifest = SectionManifest.byKey[key] else { return nil }
      let action = ShortcutAction.openSection(key)
      return UIApplicationShortcutItem(
        type: action.rawValue,
        localizedTitle: manifest.defaultLabel,
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(systemImageName: manifest.iconSymbol),
        userInfo: nil
      )
    }

    UIApplication.shared.shortcutItems = items
  }
}
#endif
