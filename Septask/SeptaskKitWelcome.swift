#if os(macOS)
import AppKit
import SwiftUI

// First-run welcome for the AppKit shell.
//
// The SwiftUI window carries its own gate (`septaskWelcomeGate`), but macOS
// launches into the AppKit shell and that window is `.defaultLaunchBehavior
// (.suppressed)` — so a fresh install landed in an empty task list with no
// introduction at all. This mounts the SAME `SeptaskWelcomeView` against the
// SAME `septask.welcome.completed` key, hosted rather than ported for the same
// reason Settings is hosted (docs/SEPTASK.md): a welcome is a form surface,
// not a keyboard-latency surface, and a second copy would drift.
@MainActor
enum SeptaskKitWelcome {
  private static var sheet: NSWindow?

  /// Present the welcome over the shell window, once per install.
  /// Self-gating, so the caller does not need to know the rules: a no-op once
  /// completed, during a demo-seed (screenshot) launch, or if it is already up.
  static func presentIfNeeded(over host: NSWindow) {
    guard sheet == nil,
          !DemoSeedMode.isOn,
          !UserDefaults.standard.bool(forKey: SeptaskWelcome.completedKey)
    else { return }
    present(over: host)
  }

  private static func present(over host: NSWindow) {
    // Shared observables, never fresh instances — the welcome reads the theme
    // for its accent, and a second `SectionTheme` paints the wrong color until
    // relaunch (docs/SEPTASK.md, hosted-view rule). Navigation is per-window
    // and unused here, so a detached one is correct.
    let root = SeptaskWelcomeView(onComplete: { finish() })
      .septenaSharedEnvironment(navigation: NavigationState(),
                                theme: SeptaskMacRuntime.theme,
                                settings: SeptaskMacRuntime.settings,
                                dayClock: SeptaskMacRuntime.dayClock,
                                logCommit: SeptaskMacRuntime.logCommit,
                                services: SeptenaServices.shared)
      .modelContainer(LocalStore.shared.container)
      .septenaTextSize()

    let content = NSHostingController(rootView: AnyView(root))
    // Matches the SwiftUI gate's `macSheetFrame(width: 520, height: 620)`.
    content.preferredContentSize = NSSize(width: 520, height: 620)

    let window = NSWindow(contentViewController: content)
    // No `.closable`, so there is no close button and Esc does not dismiss:
    // "Get Started" is the only exit. This is the AppKit counterpart of the
    // SwiftUI gate's `.interactiveDismissDisabled()`.
    window.styleMask = [.titled, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    sheet = window

    host.beginSheet(window) { _ in
      MainActor.assumeIsolated { sheet = nil }
    }
  }

  /// Close the sheet. The view already wrote `septask.welcome.completed`
  /// through its own `@AppStorage` before calling this.
  private static func finish() {
    guard let window = sheet else { return }
    window.sheetParent?.endSheet(window)
    sheet = nil
  }
}
#endif
