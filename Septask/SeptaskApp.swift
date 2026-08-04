import SwiftUI
import SwiftData
import Combine

/// Septask — the focused task app over Septena's task data (docs/SEPTASK.md).
///
/// The task data/services are shared process-wide. Navigation is deliberately
/// *not*: every restored window owns its own route, presented sheet, and sidebar
/// state so opening a second Septask window never steers the first one.
@main
struct SeptaskApp: App {
  @State private var theme = SectionTheme()
  @State private var dayClock = DayClock()
  @State private var iPadChrome = IPadChromeModel()
  @State private var logCommit = LogCommitCenter()
  @State private var settingsStore = SettingsStore()
  /// The Settings window is its own scene and `navigation` is deliberately
  /// per-window (see the note above), so this scene owns a detached route
  /// state rather than borrowing a main window's. Previously the scene
  /// injected no NavigationState at all — anything in Settings that read one
  /// would have crashed on open.
  @State private var settingsNavigation = NavigationState()
  private let localStore = LocalStore.shared
  private let services = SeptenaServices.shared

  #if os(iOS)
  @UIApplicationDelegateAdaptor(SeptaskAppDelegate.self) private var appDelegate
  #endif

  var body: some Scene {
    WindowGroup(id: "main") {
      SeptaskMainWindow(
        localStore: localStore,
        services: services,
        theme: theme,
        dayClock: dayClock,
        iPadChrome: iPadChrome,
        logCommit: logCommit,
        settingsStore: settingsStore
      )
    }
    .restorationBehavior(.automatic)
    #if os(macOS)
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 980, height: 700)
    .defaultPosition(.center)
    .defaultLaunchBehavior(.presented)
    #endif
    .commands { SeptaskCommandMenus() }

    #if os(macOS)
    Window("Settings", id: "septask-settings") {
      SeptaskSettingsView()
        // Its own scene, so it replicates the main window's chain — via the
        // same shared injector, which also gives this scene the NavigationState
        // it was previously missing.
        .septenaSharedEnvironment(navigation: settingsNavigation, theme: theme,
                                  settings: settingsStore, dayClock: dayClock,
                                  logCommit: logCommit, services: services)
        .modelContainer(localStore.container)
        .septenaTextSize()
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    #endif
  }
}

/// The main-window composition root. Its `NavigationState` is intentionally
/// created here, inside the WindowGroup content closure, rather than on App.
private struct SeptaskMainWindow: View {
  @State private var navigation = NavigationState()

  let localStore: LocalStore
  let services: SeptenaServices
  let theme: SectionTheme
  let dayClock: DayClock
  let iPadChrome: IPadChromeModel
  let logCommit: LogCommitCenter
  let settingsStore: SettingsStore

  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    SeptaskRootView()
      .overlay { LogCommitOverlay() }
      .septaskWelcomeGate()
      .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
        settingsStore.reloadFromMirror(context: localStore.container.mainContext)
        theme.paintFromCache()
      }
      .onChange(of: navigation.pendingShortcut) { _, action in
        guard let action else { return }
        switch action {
        case .newTask:
          navigation.presentAddInfo(section: .tasks)
        case .today:
          navigation.path = [.filter(.today)]
        case .openSection:
          break
        }
        navigation.pendingShortcut = nil
      }
      // Shared with Septena — see `septenaSharedEnvironment`. Adding a
      // dependency there breaks BOTH roots until each supplies it, which is
      // what stops one app launching into a missing-environment crash.
      .septenaSharedEnvironment(navigation: navigation, theme: theme,
                                settings: settingsStore, dayClock: dayClock,
                                logCommit: logCommit, services: services)
      // Septask-only chrome.
      .environment(iPadChrome)
      .modelContainer(localStore.container)
      .septenaTextSize()
      // Ungated on iPad on purpose (unlike the task-list publishers, which are
      // `#if os(macOS)`): the iPad `.focusedSceneValue` crash came from publishing
      // inside a NavigationSplitView *detail* column. This is at the WindowGroup
      // content root, above the split view, so it's safe — and iPad Septask needs
      // these window-level actions (⌘N etc.) in the shortcut HUD.
      .focusedSceneValue(\.septaskNavigationActions, navigationActions)
      .task {
        #if os(iOS)
        if let pending = SeptaskAppDelegate.consumePendingShortcut() {
          navigation.pendingShortcut = pending
        }
        // A Home Screen quick action targets the foreground window. Updating
        // this reference when a scene activates keeps the delegate's warm path
        // aligned with that window while the underlying navigation stays local.
        SeptaskAppDelegate.navigation = navigation
        #endif

        await services.start()
        SharedTaskCaptureImporter.importPending(using: services.taskMutator)
        // Publish the watch snapshot as soon as the runtime is up — don't wait
        // for a foreground bounce; the watch shows "error fetching record" until
        // this record exists in CloudKit.
        #if os(iOS)
        TasksWatchSnapshotPublisher.schedule(
          context: localStore.container.mainContext,
          date: dayClock.today)
        #endif
        ClaudeReconnectNudge.shared.start()
        Task { @MainActor in
          await ClaudeGatewayProvider.shared.refreshIfNeeded()
          ClaudeReconnectNudge.shared.reconcile()
        }
        #if DEBUG
        if DemoSeedMode.isOn {
          DemoSeed.populate(context: localStore.container.mainContext, today: dayClock.today)
          NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
          NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
        }
        #endif
        BadgeManager.shared.start(context: localStore.container.mainContext)
        Task {
          await services.absorbRemoteChanges()
          let context = localStore.container.mainContext
          settingsStore.reloadFromMirror(context: context)
          settingsStore.reconcileWelcomeName(context: context, engine: services.ckEngine)
          settingsStore.reconcileTelemetryLevel(context: context, engine: services.ckEngine)
          settingsStore.reconcileHiddenCalendars(context: context, engine: services.ckEngine)
          settingsStore.reconcileSupporter(context: context, engine: services.ckEngine)
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          Task { @MainActor in
            await services.start()
            SharedTaskCaptureImporter.importPending(using: services.taskMutator)
          }
          #if os(iOS)
          SeptaskAppDelegate.navigation = navigation
          #endif
          ClaudeReconnectNudge.shared.activate()
          Task { @MainActor in
            try? await services.ckEngine.fetchChanges()
            await ClaudeGatewayProvider.shared.refreshIfNeeded()
            ClaudeReconnectNudge.shared.reconcile()
            TasksWatchSnapshotPublisher.schedule(
              context: localStore.container.mainContext,
              date: dayClock.today)
          }
        }
      }
  }

  private var navigationActions: SeptaskNavigationActions {
    SeptaskNavigationActions(
      go: { filter in navigation.go(to: .filter(filter)) },
      newTask: { navigation.shouldStartCreating = true },
      newProject: { navigation.shouldCreateProject = true },
      newArea: { navigation.shouldCreateArea = true },
      toggleSidebar: {
        navigation.sidebarVisibility = navigation.sidebarVisibility == .detailOnly ? .all : .detailOnly
      },
      sidebarVisibility: navigation.sidebarVisibility,
      showQuickFind: { navigation.showQuickFind = true },
      showQuickAdd: { navigation.presentAddInfo(section: .tasks) },
      showSettings: { navigation.showSettings = true },
      showKeyboardShortcuts: { navigation.showKeyboardShortcuts = true }
    )
  }
}
