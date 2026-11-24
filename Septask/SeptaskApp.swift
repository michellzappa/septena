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
  #else
  // macOS runs the AppKit shell as its default window; this delegate opens it
  // and owns the launch sequence (docs/SEPTASK.md, "AppKit shell on macOS").
  @NSApplicationDelegateAdaptor(SeptaskMacAppDelegate.self) private var appDelegate
  #endif

  init() {
    // Launch signpost (docs/LAUNCH_PERF.md). The stored properties above run
    // first, so `launch.localStoreOpen` lands before this milestone.
    LaunchTrace.milestone("launch.appInit")
    SeptaskLaunchMetrics.shared.start()
  }

  var body: some Scene {
    WindowGroup("Septena", id: "main") {
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
    #if os(macOS)
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 980, height: 700)
    .defaultPosition(.center)
    // The classic SwiftUI window still exists — Go ▸ Classic Window opens it —
    // but macOS launches into the AppKit shell, so this scene neither presents
    // itself at launch nor gets restored on top of it.
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    #else
    .restorationBehavior(.automatic)
    #endif
    .commands { SeptaskCommandMenus() }

    #if os(macOS)
    Window("Settings", id: "septask-settings") {
      SeptaskSettingsSceneRoot(
        settingsNavigation: settingsNavigation,
        theme: theme,
        settingsStore: settingsStore,
        dayClock: dayClock,
        logCommit: logCommit,
        services: services,
        localStore: localStore
      )
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    #endif
  }
}

#if os(macOS)
private struct SeptaskSettingsSceneRoot: View {
  let settingsNavigation: NavigationState
  let theme: SectionTheme
  let settingsStore: SettingsStore
  let dayClock: DayClock
  let logCommit: LogCommitCenter
  let services: SeptenaServices
  let localStore: LocalStore
  private let appearance = AppearancePreferences.shared

  var body: some View {
    SeptaskSettingsView()
      // Its own scene, so it replicates the main window's chain — via the
      // same shared injector, which also gives this scene the NavigationState
      // it was previously missing.
      .septenaSharedEnvironment(navigation: settingsNavigation, theme: theme,
                                settings: settingsStore, dayClock: dayClock,
                                logCommit: logCommit, services: services)
      .modelContainer(localStore.container)
      .septenaTextSize()
      .tint(appearance.accentSwiftUIColor)
      .preferredColorScheme(appearance.preferredColorScheme)
  }
}
#endif

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
  private let appearance = AppearancePreferences.shared

  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    SeptaskRootView()
      .overlay { LogCommitOverlay() }
      .tint(appearance.accentSwiftUIColor)
      .preferredColorScheme(appearance.preferredColorScheme)
      // No CloudKit batch listener: Septask's settings arrive with the task
      // backend pull, and `SettingsStore` reloads itself on
      // `.septaskSettingsPulled`. Septask has no section colors to repaint.
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
      .onOpenURL { url in
        SeptaskDeepLinkRouter.handle(url, navigation: navigation, context: localStore.container.mainContext)
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
        if let intentAction = SeptaskDeepLinkRouter.consumePendingIntentAction() {
          SeptaskDeepLinkRouter.apply(
            intentAction,
            navigation: navigation,
            context: localStore.container.mainContext
          )
        }
        // A Home Screen quick action targets the foreground window. Updating
        // this reference when a scene activates keeps the delegate's warm path
        // aligned with that window while the underlying navigation stays local.
        SeptaskAppDelegate.navigation = navigation
        #endif

        // Shared with the macOS AppKit root — see `SeptaskLaunch`. Idempotent,
        // so it's harmless when that root already ran it.
        await SeptaskLaunch.run(settings: settingsStore)
        // No watch snapshot: it was a CloudKit record, and Septask is
        // CloudKit-free (docs/SEPTASK_BACKEND.md §9). The Septask watch needs
        // a new transport before its embed is restored (project.yml).
        #if DEBUG
        if DemoSeedMode.isOn {
          DemoSeed.populate(context: localStore.container.mainContext, today: dayClock.today)
          NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
          NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
        }
        #endif
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .background {
          // Close the backend live socket and try once more to drain the
          // task outbox.
          TaskSyncEngine.shared.enterBackground()
        }
        if phase == .active {
          #if os(iOS)
          SeptaskAppDelegate.navigation = navigation
          #endif
          Task { @MainActor in
            await SeptaskLaunch.activate()
          }
        }
      }
  }

  private var navigationActions: SeptaskNavigationActions {
    SeptaskNavigationActions(
      go: { filter in navigation.go(to: .filter(filter)) },
      newTask: { navigation.requestNewTask() },
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
