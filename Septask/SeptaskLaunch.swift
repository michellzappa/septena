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
    // Opened after midnight (or after a few days away): a backgrounded app
    // does not reliably receive `NSCalendarDayChanged`, so the foreground is
    // the reliable place to advance fixed-schedule repeats. Idempotent —
    // keep in parity with Septena's `.active` branch in App.swift.
    services.taskMutator.catchUpFixedSchedules()
    await ClaudeGatewayProvider.shared.refreshIfNeeded()
    ClaudeReconnectNudge.shared.reconcile()
  }
}

#if os(macOS)
import AppKit
import UserNotifications

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
final class SeptaskMacAppDelegate: NSObject, NSApplicationDelegate,
                                   UNUserNotificationCenterDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Route the Claude reconnect nudge's tap here. The Mac schedules the same
    // reminder the phone does (`ClaudeReconnectNudge`, started by
    // `SeptaskLaunch.run` below); without a delegate the tap would foreground
    // the app without re-minting.
    UNUserNotificationCenter.current().delegate = self
    // Global ⌃Space hotkey disabled for now — it contends with Moom's own
    // ⌃Space binding system-wide (mz uses that combo for Moom). Quick Entry
    // is still reachable via the Window ▸ Quick Entry menu item, just without
    // a keyboard shortcut. Re-enable with SeptaskKitQuickEntry.installHotKey()
    // once a non-conflicting key is picked.
    SeptaskKitWindowController.show()
    // First run: the AppKit shell is the default window on macOS, so a fresh
    // install would otherwise land in an empty task list with no introduction
    // — the SwiftUI welcome gate rides the classic window, which no longer
    // opens at launch. Same view, same completion key, hosted as a sheet.
    if let shell = SeptaskKitWindowController.existing?.window {
      SeptaskKitWelcome.presentIfNeeded(over: shell)
    }
    // Sparkle starts scheduled checks when the controller is created. Local
    // Debug builds intentionally have no update key and must not prompt.
    #if !DEBUG
    if SeptaskUpdater.isConfigured { _ = SeptaskUpdater.shared }
    #endif
    Task { @MainActor in await SeptaskLaunch.run(settings: SeptaskMacRuntime.settings) }
  }

  /// Show the banner even while Septask is frontmost — the nudge still matters
  /// if you aren't looking at Settings.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  /// macOS twin of `SeptaskAppDelegate`'s iOS handler. Claude is the only
  /// nudge Septask schedules, and a plain tap re-mints too.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let actionID = response.actionIdentifier
    let userInfo = response.notification.request.content.userInfo
    Task { @MainActor in
      await SeptenaServices.shared.start()
      if actionID == NotificationActionID.claudeReconnect || userInfo["claudeReconnect"] != nil {
        await ClaudeGatewayProvider.shared.refreshIfNeeded(force: true)
        ClaudeReconnectNudge.shared.reconcile()
      }
      completionHandler()
    }
  }

  /// Clicking the Dock icon with every window closed reopens the shell — the
  /// standard single-window app behavior.
  func applicationShouldHandleReopen(_ sender: NSApplication,
                                     hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      SeptaskKitWindowController.show()
      // Second chance for the welcome: if the shell window wasn't up at launch
      // there was nothing to host the sheet, and it would otherwise never
      // appear again. `presentIfNeeded` self-gates, so this is a no-op once
      // the user has finished it.
      if let shell = SeptaskKitWindowController.existing?.window {
        SeptaskKitWelcome.presentIfNeeded(over: shell)
      }
    }
    return true
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    Task { @MainActor in await SeptaskLaunch.activate() }
  }
}
#endif
