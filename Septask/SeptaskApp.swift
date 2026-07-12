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
        .environment(theme)
        .environment(settingsStore)
        .environment(services.taskMutator)
        .environment(services.areasMutator)
        .environment(services.projectsMutator)
        .environment(services.checklistMutator)
        .environment(services.ckEngine)
        .environment(dayClock)
        .environment(logCommit)
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
      .environment(navigation)
      .environment(theme)
      .environment(settingsStore)
      .environment(services.taskMutator)
      .environment(services.areasMutator)
      .environment(services.projectsMutator)
      .environment(services.checklistMutator)
      .environment(services.ckEngine)
      .environment(dayClock)
      .environment(logCommit)
      .environment(iPadChrome)
      .modelContainer(localStore.container)
      .septenaTextSize()
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
