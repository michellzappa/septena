import SwiftUI
import SwiftData
import UserNotifications

// The process's launch sequence, in one place because two roots now perform
// it: the SwiftUI window's `.task` (iOS, and the macOS classic window) and the
// macOS AppKit delegate below, which is the default shell on macOS.
//
// Everything here is idempotent — `services.start()` memoizes, the importer
// no-ops with nothing pending — so whichever root comes up first wins and a
// second call is harmless.
//
// Draw Today first (docs/LAUNCH_PERF.md): the first frame reads only the
// local store. Before it, the launch binds the mutators (cheap, and it makes
// a tap during the deferred start safe) and nothing else. Services start,
// sync, imports, diagnostics and the badge wait for `LaunchPhase`, and
// nothing awaits the network before the first frame. The wait is iOS-only:
// the macOS AppKit shell draws its own list without `TaskListView`, so it
// would only ever hit the timeout.
@MainActor
enum SeptaskLaunch {
  static func run(settings: SettingsStore) async {
    let services = SeptenaServices.shared
    let localStore = LocalStore.shared

    services.bindWriteBoundary()
    #if os(iOS)
    // The Apple Watch link (docs/WATCH.md), before the first-frame wait: a
    // watch message can launch the app in the background, where no frame is
    // ever drawn. Activation is cheap and reads nothing.
    WatchBridge.shared.start()
    #endif
    await waitForFirstFrameIfNeeded()
    await services.start()
    LaunchTrace.spanSync("launch.deferredWork") {
      SharedTaskCaptureImporter.importPending(using: services.taskMutator)
      SeptaskLegacyClaudeCleanup.runOnce()
      // Weekly diagnostics retired 2026-11-22 and usage data 2026-11-25 (#436):
      // the app sends neither. Clears any old opt-in and its pending batch.
      SeptaskDiagnosticsCoordinator.setEnabled(false)
      BadgeManager.shared.start(context: localStore.container.mainContext)
      TaskReminderScheduler.shared.start(context: localStore.container.mainContext)
      SeptaskPushNotifications.shared.start()
      TasksWidgetSnapshotPublisher.shared.drainPendingCompletions(using: services.taskMutator)
      TasksWidgetSnapshotPublisher.shared.start()
      SeptaskAppShortcuts.updateAppShortcutParameters()
      #if os(iOS)
      // The next cold launch draws Today from this file (#82). macOS draws
      // its AppKit list without `TaskListView`, so it has no reader.
      TodaySnapshotWriter.shared.start()
      #endif
      // App Store renewals, Ask to Buy approvals and purchases the server
      // missed (spec §7.1), on the iPhone, iPad and Mac (ADR 0026).
      PlusStore.shared.start()
    }
    Task(priority: .utility) {
      await services.absorbRemoteChanges()
      let context = localStore.container.mainContext
      settings.reloadFromMirror(context: context)
      AppearancePreferences.shared.adoptSynced(SeptaskSyncedSettings.current())
      SmartListPreferences.shared.adoptSynced(SeptaskSyncedSettings.current())
      settings.reconcileWelcomeName(context: context, engine: services.ckEngine)
      settings.reconcileHiddenCalendars(context: context, engine: services.ckEngine)
      // No `reconcileSupporter`: the supporter flag came from Septena through
      // CloudKit, and Septask no longer reads CloudKit. `engine` above is
      // only the "push allowed" signal; in Septask the push goes to the task
      // backend (SettingsMirror.upsert), and the engine never starts.
    }
  }

  /// Foreground refresh — the same work both roots do when their window
  /// becomes active. On a cold launch iOS reports `.active` right away, so
  /// this waits for the first frame too.
  static func activate() async {
    let services = SeptenaServices.shared
    services.bindWriteBoundary()
    await waitForFirstFrameIfNeeded()
    await services.start()
    SharedTaskCaptureImporter.importPending(using: services.taskMutator)
    SeptaskDiagnosticsCoordinator.setEnabled(false)
    // Task backend: reconcile, push, pull, reopen the live socket.
    TaskSyncEngine.shared.activate()
    // The plan, fresh for Today's upsell notices (spec §3.2). The server
    // judges it; a change posts `.septenaTasksChanged`.
    Task { @MainActor in await PlanStatus.shared.refresh() }
    // Opened after midnight (or after a few days away): a backgrounded app
    // does not reliably receive `NSCalendarDayChanged`, so the foreground is
    // the reliable place to advance fixed-schedule repeats. Idempotent —
    // keep in parity with Septena's `.active` branch in App.swift.
    services.taskMutator.catchUpFixedSchedules()
    services.runFadePassIfDue()
    TaskReminderScheduler.shared.scheduleReconcile()
    SeptaskPushNotifications.shared.syncRegistrationIfNeeded()
    TasksWidgetSnapshotPublisher.shared.drainPendingCompletions(using: services.taskMutator)
    TasksWidgetSnapshotPublisher.shared.schedulePublish()
    #if os(iOS)
    WatchBridge.shared.appDidBecomeActive()
    #endif
  }

  /// iOS: hold deferred launch work until the first Today frame is drawn.
  /// macOS: return at once (see the note above).
  private static func waitForFirstFrameIfNeeded() async {
    #if os(iOS)
    await LaunchPhase.shared.waitForFirstFrame()
    #endif
  }
}

/// Real-use launch numbers from MetricKit (docs/LAUNCH_PERF.md). The system
/// delivers one payload a day at most, with histograms of time to first draw
/// and resume time across that day's launches. Each payload is logged to the
/// unified log (subsystem `com.septena.cloud`, category "Launch") and its
/// summary kept on this device under `lastSummaryKey`. It never leaves the
/// device: it is not part of the weekly diagnostics batch.
///
/// iOS only: `MXAppLaunchMetric` does not exist on macOS.
final class SeptaskLaunchMetrics: NSObject, @unchecked Sendable {
  static let shared = SeptaskLaunchMetrics()
  static let lastSummaryKey = "septask.launchMetrics.lastSummary"

  /// Call once at launch. Idempotent (MetricKit keeps one entry per object).
  func start() {
    #if os(iOS)
    MXMetricManager.shared.add(self)
    #endif
  }
}

#if os(iOS)
import MetricKit
import os

extension SeptaskLaunchMetrics: MXMetricManagerSubscriber {
  private static let logger = Logger(subsystem: Log.subsystem, category: "Launch")

  func didReceive(_ payloads: [MXMetricPayload]) {
    for payload in payloads {
      guard let launch = payload.applicationLaunchMetrics else { continue }
      var parts = ["period \(payload.timeStampBegin.formatted()) to \(payload.timeStampEnd.formatted())",
                   "version \(payload.latestApplicationVersion)"]
      parts.append("timeToFirstDraw " + Self.summary(launch.histogrammedTimeToFirstDraw))
      if #available(iOS 15.2, *) {
        parts.append("optimizedTimeToFirstDraw " + Self.summary(launch.histogrammedOptimizedTimeToFirstDraw))
      }
      parts.append("resume " + Self.summary(launch.histogrammedApplicationResumeTime))
      let line = parts.joined(separator: "; ")
      Self.logger.notice("MetricKit launch: \(line, privacy: .public)")
      UserDefaults.standard.set(line, forKey: Self.lastSummaryKey)
    }
  }

  /// "n=12 p50≈310ms p90≈540ms", from the bucket midpoints.
  private static func summary(_ histogram: MXHistogram<UnitDuration>) -> String {
    var buckets: [(ms: Double, count: Int)] = []
    let enumerator = histogram.bucketEnumerator
    while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
      let start = bucket.bucketStart.converted(to: .milliseconds).value
      let end = bucket.bucketEnd.converted(to: .milliseconds).value
      buckets.append(((start + end) / 2, bucket.bucketCount))
    }
    let total = buckets.reduce(0) { $0 + $1.count }
    guard total > 0 else { return "n=0" }
    func percentile(_ p: Double) -> Int {
      let target = Int((Double(total) * p).rounded(.up))
      var seen = 0
      for bucket in buckets {
        seen += bucket.count
        if seen >= target { return Int(bucket.ms) }
      }
      return Int(buckets.last?.ms ?? 0)
    }
    return "n=\(total) p50≈\(percentile(0.5))ms p90≈\(percentile(0.9))ms"
  }
}
#endif

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
    AppearancePreferences.shared.applyPlatformAppearance()
    // Global Quick Entry hotkey, ⌃⌥Space (Carbon RegisterEventHotKey: no
    // Accessibility permission, no event tap). ⌃Space is the system input
    // source switch and Moom's binding, so it is not used.
    SeptaskKitQuickEntry.installHotKey()
    // A fresh account gets the first run as a sheet on this window
    // (`SeptaskKitFirstRun.swift`); after it, the Get started checklist and
    // the sign-in notice (`TaskNotices`) hold whatever was skipped.
    // Before the window: an open Do shows in its first frame, and the menu
    // bar item with it (SeptaskKitDo.swift).
    SeptaskKitDo.shared.start()
    SeptaskKitWindowController.show()
    Task { @MainActor in await SeptaskKitFirstRunWindow.presentIfNeeded() }
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
    NSApp.unhide(nil)
    if !flag {
      SeptaskKitWindowController.show()
    }
    return true
  }

  /// A quit waits for a running session refresh, at most 3 seconds. Without
  /// the reply the stored token still works (ADR 0040); this saves a retry.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard TaskBackendClient.isRefreshing else { return .terminateNow }
    Task { @MainActor in
      let deadline = ContinuousClock.now + .seconds(3)
      while TaskBackendClient.isRefreshing, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// ⌘Q must not lose an open edit: the shell's text editors commit on blur,
  /// and quitting blurs nothing. Save them explicitly before the process ends.
  func applicationWillTerminate(_ notification: Notification) {
    SeptaskKitWindowController.existing?.commitAllEdits()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    Task { @MainActor in await SeptaskLaunch.activate() }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      SeptaskDeepLinkRouter.handleMac(url)
    }
  }
}
#endif

/// Routes `septask://` deep links from widgets and iCal events (`quick-add`,
/// `list/<id>`, `task/<id>`) into the active iOS or macOS shell.
@MainActor
enum SeptaskDeepLinkRouter {
  static func filter(forListID id: String) -> TaskFilter {
    switch id {
    case TasksWidgetListSummary.todayID:    return .today
    case TasksWidgetListSummary.upcomingID: return .upcoming
    case TasksWidgetListSummary.inboxID:    return .triage
    case TasksWidgetListSummary.starredID:  return .starred
    default:
      if id.hasPrefix("project:") {
        return .project(String(id.dropFirst("project:".count)))
      }
      if id.hasPrefix("area:") {
        return .area(String(id.dropFirst("area:".count)))
      }
      return .today
    }
  }

  static func route(forListID id: String) -> Route {
    switch id {
    case TasksWidgetListSummary.todayID:    return .filter(.today)
    case TasksWidgetListSummary.upcomingID: return .filter(.upcoming)
    case TasksWidgetListSummary.inboxID:    return .filter(.triage)
    case TasksWidgetListSummary.starredID:  return .filter(.starred)
    default:
      if id.hasPrefix("project:") {
        return .project(id: String(id.dropFirst("project:".count)))
      }
      if id.hasPrefix("area:") {
        return .area(id: String(id.dropFirst("area:".count)))
      }
      return .filter(.today)
    }
  }

  static func destinationFilter(forTaskID taskID: String, context: ModelContext) -> TaskFilter {
    let tid = taskID
    if let entity = StoreHealth.fetch(context, FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.id == tid && $0.deletedAt == nil }
    )).first {
      let task = SeptenaTask(entity)
      if task.status != .open { return .logbook }
      if task.isFaded { return .faded }
      if task.isOnToday { return .today }
      if let p = task.project { return .project(p) }
      if let a = task.area { return .area(a) }
      if task.scheduled != nil || task.deadline != nil { return .upcoming }
      if task.isInTriageBand { return .triage }
      return .unscheduled
    }
    return .today
  }

  static func destinationRoute(forTaskID taskID: String, context: ModelContext) -> Route {
    let filter = destinationFilter(forTaskID: taskID, context: context)
    switch filter {
    case .project(let pid): return .project(id: pid)
    case .area(let aid):    return .area(id: aid)
    default:                return .filter(filter)
    }
  }

  /// Navigation action initiated by an `openAppWhenRun = true` App Intent.
  enum PendingIntentAction: Equatable {
    case showToday
    case openTaskConversation(taskID: String)
  }

  /// Stashed on iOS when an App Intent triggers cold launch before
  /// `SeptaskMainWindow.task` wires `SeptaskAppDelegate.navigation`.
  private static var pendingIntentAction: PendingIntentAction?

  static func consumePendingIntentAction() -> PendingIntentAction? {
    defer { pendingIntentAction = nil }
    return pendingIntentAction
  }

  static func apply(_ action: PendingIntentAction, navigation: NavigationState, context: ModelContext) {
    navigation.presentedModal = nil
    navigation.showSettings = false
    switch action {
    case .showToday:
      navigation.go(to: .filter(.today))
    case .openTaskConversation(let taskID):
      let dest = destinationRoute(forTaskID: taskID, context: context)
      navigation.revealTask(id: taskID, in: dest, opensPage: true)
    }
  }

  static func routeFromIntent(_ action: PendingIntentAction) {
    #if os(iOS)
    if let nav = SeptaskAppDelegate.navigation {
      apply(action, navigation: nav, context: LocalStore.shared.container.mainContext)
    } else {
      pendingIntentAction = action
    }
    #else
    NSApp.activate(ignoringOtherApps: true)
    SeptaskKitWindowController.show()
    guard let shell = SeptaskKitWindowController.existing else { return }
    switch action {
    case .showToday:
      shell.go(to: .today)
    case .openTaskConversation(let taskID):
      let context = LocalStore.shared.container.mainContext
      let dest = destinationFilter(forTaskID: taskID, context: context)
      shell.openTaskConversation(id: taskID, in: dest)
    }
    #endif
  }

  static func handle(_ url: URL, navigation: NavigationState, context: ModelContext) {
    guard let link = TasksWidgetDeepLink.parse(url) else { return }
    switch link {
    case .quickAdd:
      navigation.presentAddInfo()
    case .list(let id):
      navigation.go(to: route(forListID: id))
    case .task(let taskID):
      openTask(taskID, navigation: navigation, context: context)
    case .join(let token):
      SeptaskSharing.presentJoin(link: token)
    }
  }

  /// Show a task in the list that owns it. `opensPage` also opens its task
  /// page (a reference to another task).
  static func openTask(_ taskID: String, opensPage: Bool = false,
                       navigation: NavigationState, context: ModelContext) {
    let filter = destinationFilter(forTaskID: taskID, context: context)
    let dest: Route
    switch filter {
    case .project(let pid): dest = .project(id: pid)
    case .area(let aid):    dest = .area(id: aid)
    default:                dest = .filter(filter)
    }
    navigation.pendingTaskReveal = NavigationState.TaskReveal(taskID: taskID, routeID: dest.id,
                                                              opensPage: opensPage)
    navigation.go(to: dest)
  }

  #if os(macOS)
  static func handleMac(_ url: URL) {
    guard let link = TasksWidgetDeepLink.parse(url) else { return }
    NSApp.activate(ignoringOtherApps: true)
    SeptaskKitWindowController.show()
    guard let shell = SeptaskKitWindowController.existing else { return }
    switch link {
    case .quickAdd:
      shell.go(to: .today)
      shell.newTask()
    case .list(let id):
      shell.go(to: filter(forListID: id))
    case .task(let taskID):
      openTaskMac(taskID)
    case .join(let token):
      SeptaskSharing.presentJoin(link: token)
    }
  }

  static func openTaskMac(_ taskID: String, opensPage: Bool = false) {
    guard let shell = SeptaskKitWindowController.existing else { return }
    let context = LocalStore.shared.container.mainContext
    shell.revealTask(id: taskID, in: destinationFilter(forTaskID: taskID, context: context),
                     opensPage: opensPage)
  }
  #endif
}
