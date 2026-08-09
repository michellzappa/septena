import SwiftUI

// The process's launch sequence, in one place because two roots now perform
// it: the SwiftUI window's `.task` (iOS, and the macOS classic window) and the
// macOS AppKit delegate below, which is the default shell on macOS.
//
// Everything here is idempotent — `services.start()` memoizes, the importer
// no-ops with nothing pending — so whichever root comes up first wins and a
// second call is harmless.
@MainActor
enum SeptaskLaunch {
  static func run(settings: SettingsStore) async {
    let services = SeptenaServices.shared
    let localStore = LocalStore.shared

    await services.start()
    SharedTaskCaptureImporter.importPending(using: services.taskMutator)
    ClaudeReconnectNudge.shared.start()
    SeptaskDiagnosticsCoordinator.shared.start()
    Task { @MainActor in
      await ClaudeGatewayProvider.shared.refreshIfNeeded()
      ClaudeReconnectNudge.shared.reconcile()
    }
    BadgeManager.shared.start(context: localStore.container.mainContext)
    Task {
      await services.absorbRemoteChanges()
      let context = localStore.container.mainContext
      settings.reloadFromMirror(context: context)
      settings.reconcileWelcomeName(context: context, engine: services.ckEngine)
      settings.reconcileTelemetryLevel(context: context, engine: services.ckEngine)
      settings.reconcileHiddenCalendars(context: context, engine: services.ckEngine)
      settings.reconcileSupporter(context: context, engine: services.ckEngine)
    }
  }

  /// Foreground refresh — the same work both roots do when their window
  /// becomes active.
  static func activate() async {
    let services = SeptenaServices.shared
    await services.start()
    SharedTaskCaptureImporter.importPending(using: services.taskMutator)
    ClaudeReconnectNudge.shared.activate()
    SeptaskDiagnosticsCoordinator.shared.start()
    try? await services.ckEngine.fetchChanges()
    await ClaudeGatewayProvider.shared.refreshIfNeeded()
    ClaudeReconnectNudge.shared.reconcile()
  }
}

#if os(macOS)
import AppKit

/// The observable objects the AppKit shell owns, since it has no SwiftUI
/// scene to hold them.
///
/// One instance each, process-wide: the launch reconcile and the hosted
/// Settings window must write through the SAME `SettingsStore`, or settings
/// changed in one place are invisible to the other until a relaunch. Same
/// reason the theme and clock are shared — a second `DayClock` wouldn't carry
/// the debug day offset.
@MainActor
enum SeptaskMacRuntime {
  static let settings = SettingsStore()
  static let theme = SectionTheme()
  static let dayClock = DayClock()
  static let logCommit = LogCommitCenter()
}

/// macOS composition root. The AppKit shell is the default window on macOS
/// (docs/SEPTASK.md, "AppKit shell on macOS"), so the app's launch work runs
/// here rather than in a SwiftUI scene's `.task` — the SwiftUI window is
/// suppressed at launch and only opens on request.
@MainActor
final class SeptaskMacAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    SeptaskKitQuickEntry.installHotKey()
    SeptaskKitWindowController.show()
    // Sparkle starts scheduled checks when the controller is created. Local
    // Debug builds intentionally have no update key and must not prompt.
    #if !DEBUG
    if SeptaskUpdater.isConfigured { _ = SeptaskUpdater.shared }
    #endif
    Task { @MainActor in await SeptaskLaunch.run(settings: SeptaskMacRuntime.settings) }
  }

  /// Clicking the Dock icon with every window closed reopens the shell — the
  /// standard single-window app behavior.
  func applicationShouldHandleReopen(_ sender: NSApplication,
                                     hasVisibleWindows flag: Bool) -> Bool {
    if !flag { SeptaskKitWindowController.show() }
    return true
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    Task { @MainActor in await SeptaskLaunch.activate() }
  }
}
#endif
