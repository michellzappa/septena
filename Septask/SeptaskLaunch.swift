import SwiftUI
import UserNotifications

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
    SeptaskLegacyClaudeCleanup.runOnce()
    SeptaskDiagnosticsCoordinator.shared.start()
    BadgeManager.shared.start(context: localStore.container.mainContext)
    Task {
      await services.absorbRemoteChanges()
      let context = localStore.container.mainContext
      settings.reloadFromMirror(context: context)
      settings.reconcileWelcomeName(context: context, engine: services.ckEngine)
      settings.reconcileTelemetryLevel(context: context, engine: services.ckEngine)
      settings.reconcileHiddenCalendars(context: context, engine: services.ckEngine)
      // No `reconcileSupporter`: the supporter flag came from Septena through
      // CloudKit, and Septask no longer reads CloudKit. `engine` above is
      // only the "push allowed" signal; in Septask the push goes to the task
      // backend (SettingsMirror.upsert), and the engine never starts.
    }
  }

  /// Foreground refresh — the same work both roots do when their window
  /// becomes active.
  static func activate() async {
    let services = SeptenaServices.shared
    await services.start()
    SharedTaskCaptureImporter.importPending(using: services.taskMutator)
    SeptaskDiagnosticsCoordinator.shared.start()
    // Task backend: reconcile, push, pull, reopen the live socket.
    TaskSyncEngine.shared.activate()
    // Opened after midnight (or after a few days away): a backgrounded app
    // does not reliably receive `NSCalendarDayChanged`, so the foreground is
    // the reliable place to advance fixed-schedule repeats. Idempotent —
    // keep in parity with Septena's `.active` branch in App.swift.
    services.taskMutator.catchUpFixedSchedules()
  }
}

/// One-time removal of the old hosted-gateway Claude connection
/// (mcp.septena.app, a CloudKit web-auth token re-minted every ~8h with an
/// Apple sign-in). Septask no longer compiles `ClaudeGatewayProvider` or
/// `ClaudeReconnectNudge`: Claude now connects to the task backend
/// (`https://api.septena.app/mcp`), paired in Settings ▸ About ▸ Advanced ▸
/// Task backend. This clears only what Septask itself wrote. The shared App
/// Group keys (`septena.claudeGateway.enabled` / `.lastRefreshAt` /
/// `.nudgeOwner` in `group.com.septena.cloud`) stay: Septena still reads them.
@MainActor
enum SeptaskLegacyClaudeCleanup {
  private static let doneKey = "septask.legacyClaudeGatewayCleanup.v1"
  /// `ClaudeReconnectNudge.notificationID` — literal, the type is not compiled here.
  private static let nudgeNotificationID = "septena.claude.connectionNudge"
  /// `ClaudeGatewayProvider.tokenKeychainAccount`.
  private static let tokenKeychainAccount = "septena.claudeGateway.ckToken"
  /// Bundle-local defaults the old provider and its Settings toggle wrote.
  private static let localDefaultsKeys = [
    "septena.notify.toggle.claude.connection",
    "septena.claudeGateway.enabled",
    "septena.claudeGateway.lastRefreshAt",
    "septena.claudeGateway.measure.cycleRefreshAt",
    "septena.claudeGateway.measure.lastValidAge",
    "septena.claudeGateway.measure.finalizedCycle",
    "septena.claudeGateway.measure.samples",
  ]

  static func runOnce() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: doneKey) else { return }
    // Each app has its own notification queue, so this never touches the
    // reminder Septena schedules.
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [nudgeNotificationID])
    center.removeDeliveredNotifications(withIdentifiers: [nudgeNotificationID])
    #if os(iOS)
    // iOS: the item sits in Septask's own keychain access group (no
    // keychain-access-groups entitlement), so Septena's copy is out of reach.
    // macOS: not deleted. The unsandboxed Mac apps share the login keychain
    // and both used this account name, so a delete could remove Septena's.
    KeychainStore.delete(account: tokenKeychainAccount)
    #endif
    for key in localDefaultsKeys { defaults.removeObject(forKey: key) }
    defaults.set(true, forKey: doneKey)
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
    // Global Quick Entry hotkey, ⌃⌥Space (Carbon RegisterEventHotKey: no
    // Accessibility permission, no event tap). ⌃Space is the system input
    // source switch and Moom's binding, so it is not used.
    SeptaskKitQuickEntry.installHotKey()
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

  /// ⌘Q must not lose an open edit: the shell's text editors commit on blur,
  /// and quitting blurs nothing. Save them explicitly before the process ends.
  func applicationWillTerminate(_ notification: Notification) {
    SeptaskKitWindowController.existing?.commitAllEdits()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    Task { @MainActor in await SeptaskLaunch.activate() }
  }
}
#endif
