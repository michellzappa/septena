#if os(macOS)
import AppKit
import SwiftUI

// Settings for the AppKit shell: the existing SwiftUI SeptaskSettingsView,
// hosted in a plain NSWindow. Settings are forms — not keyboard-latency
// surfaces — so porting them to AppKit would be pure drift; hosting keeps the
// single implementation. The environment chain mirrors the SwiftUI Settings
// scene in SeptaskApp exactly (same injector), because a hosted shared view
// reading a missing @Environment crashes at launch — the documented Septask
// P1 trap.
@MainActor
enum SeptaskKitSettingsWindow {
  private static var controller: NSWindowController?

  static func show() {
    if let controller {
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }

    // The shell's shared observables — NOT fresh instances. A second
    // SettingsStore here would take the user's edits into a copy the rest of
    // the app never reads. Navigation is per-window, as in the SwiftUI scene.
    let navigation = NavigationState()
    let theme = SeptaskMacRuntime.theme
    let settings = SeptaskMacRuntime.settings
    settings.reloadFromMirror(context: LocalStore.shared.container.mainContext)
    theme.paintFromCache()

    let root = SeptaskSettingsView()
      .septenaSharedEnvironment(navigation: navigation, theme: theme,
                                settings: settings,
                                dayClock: SeptaskMacRuntime.dayClock,
                                logCommit: SeptaskMacRuntime.logCommit,
                                services: SeptenaServices.shared)
      .modelContainer(LocalStore.shared.container)
      .septenaTextSize()

    let host = NSHostingController(rootView: AnyView(root))
    let window = NSWindow(contentViewController: host)
    window.title = String(localized: "Settings", comment: "Settings window title")
    window.styleMask = [.titled, .closable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.center()
    let windowController = NSWindowController(window: window)
    controller = windowController
    windowController.window?.makeKeyAndOrderFront(nil)
  }
}
#endif
