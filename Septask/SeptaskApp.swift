import SwiftUI
import SwiftData
import Combine

/// Septask — the focused task app over Septena's task data (docs/SEPTASK.md).
///
/// Same repo, same SeptenaCore, same private CloudKit records; a different
/// composition root. This target compiles with the `SEPTASK` condition, which
/// flips `RuntimeProfile.current` to `.tasksOnly` so `SeptenaServices.start()`
/// binds only the task/area/project mutators and never touches the life-OS
/// subsystems or third-party provider stores.
///
/// P1 shell: mounts the SAME task surface the full app ships — `ContentView`
/// (sidebar + list split view) over `Shell/Tasks` + `Shell/Sidebar`, included
/// by source, never copied. Full-app-only spots inside those files are
/// `#if !SEPTASK`-gated. Welcome and a dedicated Settings surface are P3.
@main
struct SeptaskApp: App {
  @State private var navigation = NavigationState()
  @State private var theme = SectionTheme()
  @State private var dayClock = DayClock()
  /// iPad nav-bar chrome coordination — SeptenaPage's nav-depth reporter
  /// reads it unconditionally, so the shell must provide one even though
  /// Septask draws no global chrome overlay.
  @State private var iPadChrome = IPadChromeModel()
  /// Celebration layer for task completions (Today cleared → arc flourish),
  /// same wiring as the full app: overlay mounted innermost so it can read
  /// `logCommit` from the environment chain below.
  @State private var logCommit = LogCommitCenter()
  /// The settings mirror cache — same object the full app uses. Septask's
  /// Settings reads it for the profile name, telemetry level, and the What's
  /// New list, so the panes behave identically to Septena's. Reloaded on
  /// inbound data changes below, like App.swift.
  @State private var settingsStore = SettingsStore()
  private let localStore = LocalStore.shared
  private let services = SeptenaServices.shared
  @Environment(\.scenePhase) private var scenePhase
  #if os(iOS)
  /// Slim composition-root delegate for Home Screen Quick Action delivery
  /// (SeptaskQuickActions.swift) — the tasks-only twin of the full app's
  /// AppDelegate. iOS only; macOS has no icon long-press menu.
  @UIApplicationDelegateAdaptor(SeptaskAppDelegate.self) private var appDelegate
  #endif

  var body: some Scene {
    WindowGroup {
      SeptaskRootView()
        .overlay { LogCommitOverlay() }
        // Settings presentation lives in SeptaskRootView now: a sheet on iOS,
        // a real Settings window (below) on macOS — mirroring App.swift so
        // Septask's Settings is a native window with traffic lights, not a
        // modal dialog.
        // One-time Septask welcome; self-gating after completion.
        .septaskWelcomeGate()
        // Keep the tasks accent + settings cache aligned with the
        // CloudKit-synced mirror — inbound batches repaint both.
        .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
          settingsStore.reloadFromMirror(context: localStore.container.mainContext)
          theme.paintFromCache()
        }
        // Home Screen Quick Action routing. The delegate publishes onto
        // `pendingShortcut` (warm) or `SeptaskApp.task` drains it (cold);
        // either way we land the shared quick-add composer — the same sheet
        // the tab-bar `+` and ⌘I present. Septask ships no sections, so
        // `.openSection` is a no-op here.
        .onChange(of: navigation.pendingShortcut) { _, action in
          guard let action else { return }
          switch action {
          case .newTask:      navigation.presentAddInfo(section: .tasks)
          case .openSection:  break
          }
          navigation.pendingShortcut = nil
        }
        .environment(navigation)
        .environment(theme)
        .environment(settingsStore)
        .environment(services.taskMutator)
        .environment(services.areasMutator)
        .environment(services.projectsMutator)
        .environment(services.ckEngine)
        .environment(dayClock)
        .environment(logCommit)
        .environment(iPadChrome)
        .modelContainer(localStore.container)
        // App-wide text-size preference — shared `.septenaTextSize()` reading
        // the same device-local step Septena writes. Outermost so it flows to
        // the root, overlays, and the Settings sheet.
        .septenaTextSize()
        .task {
          #if os(iOS)
          // Drain a shortcut captured during cold launch (the delegate
          // stashes it before NavigationState exists), then hand the delegate
          // a live reference so warm-launch taps publish straight through.
          if let pending = SeptaskAppDelegate.consumePendingShortcut() {
            navigation.pendingShortcut = pending
          }
          SeptaskAppDelegate.navigation = navigation
          #endif
          await services.start()
          #if DEBUG
          // Screenshot / UI-test builds: load curated demo data into the
          // in-memory store, same as App.swift. No-op in release. Without this
          // Septask's demo launch is empty (the seed lives in the app root, the
          // one place composition isn't shared). Nudge a reload so the task
          // lists don't race ahead of the synchronous inserts and show 0.
          if DemoSeedMode.isOn {
            DemoSeed.populate(context: localStore.container.mainContext, today: dayClock.today)
            NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
            NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
          }
          #endif
          // Overdue-badge driver (Settings ▸ Badge). Same core singleton the
          // full app starts; never prompts for permission (macOS dock dot;
          // iOS deliberately stays clear).
          BadgeManager.shared.start(context: localStore.container.mainContext)
          // Off the critical path, like App.swift: first frame renders from
          // the local mirror; the server pull patches it via notifications.
          Task {
            await services.absorbRemoteChanges()
            // Post-fetch reconciles, mirroring App.swift's launch task —
            // adopt CloudKit-synced values (or push local ones up). Without
            // these the profile name set in Septena never lands here.
            let context = localStore.container.mainContext
            settingsStore.reloadFromMirror(context: context)
            settingsStore.reconcileWelcomeName(context: context, engine: services.ckEngine)
            settingsStore.reconcileTelemetryLevel(context: context, engine: services.ckEngine)
            settingsStore.reconcileHiddenCalendars(context: context, engine: services.ckEngine)
            settingsStore.reconcileSupporter(context: context, engine: services.ckEngine)
          }
        }
        .onChange(of: scenePhase) { _, phase in
          // Foreground fetch is the reliable refresh path (push is best
          // effort) — mandatory in both apps per docs/SEPTASK.md §5.
          if phase == .active {
            Task { try? await services.ckEngine.fetchChanges() }
          }
        }
    }
    // macOS: drop the "Septask" title strip, same as App.swift — on this SDK
    // the hidden-title-bar window is what gives the NavigationSplitView
    // sidebar its full-height rounded pane; the default style renders the
    // classic square sidebar under a title bar.
    #if os(macOS)
    .windowStyle(.hiddenTitleBar)
    #endif
    // The task-scoped subset of the full app's menu commands (App.swift) —
    // only entries whose backing surface Septask compiles. Quick Find /
    // Add Info / Settings / the shortcuts cheat-sheet wait for their sheet
    // hosts (P3). No tab bar here, so the smart lists take plain ⌘1–4.
    .commands {
      CommandMenu("Go") {
        Button("Today")    { navigation.path = [.filter(.today)] }
          .keyboardShortcut("1", modifiers: .command)
        Button("Upcoming") { navigation.path = [.filter(.upcoming)] }
          .keyboardShortcut("2", modifiers: .command)
        Button("Anytime")  { navigation.path = [.filter(.unscheduled)] }
          .keyboardShortcut("3", modifiers: .command)
        Button("Logbook")  { navigation.path = [.filter(.logbook)] }
          .keyboardShortcut("4", modifiers: .command)

        Divider()

        // Quick Find — same slot as the full app's Go menu (App.swift).
        Button("Quick Find…") { navigation.showQuickFind = true }
          .keyboardShortcut("f", modifiers: [.command, .shift])
      }
      // Row-level actions, fed by `TaskListView`'s `focusedSceneValue`;
      // items disable themselves when no task list is focused.
      CommandMenu("Task") { TaskCommandsMenu() }
      // ⌘/ toggles the sidebar, same as the full app.
      CommandGroup(after: .sidebar) {
        Button(navigation.sidebarVisibility == .detailOnly
               ? "Show Sidebar" : "Hide Sidebar") {
          navigation.sidebarVisibility =
            navigation.sidebarVisibility == .detailOnly ? .all : .detailOnly
        }
        .keyboardShortcut("/", modifiers: .command)
      }
      // ⌘N is New To-Do, not New Window — inline in the focused list, else
      // the quick-add fallback.
      CommandGroup(replacing: .newItem) { NewTaskCommand() }
      // ⌘I quick capture — the tab bar `+`'s keyboard twin, matching
      // Septena's Add Info (⌘I). Moved off ⌘K so ⌘K completes the selected
      // task (the Task menu's Mark as Complete); ⌘N still makes a new to-do.
      CommandGroup(after: .newItem) {
        Button("Quick Add…") { navigation.presentAddInfo(section: .tasks) }
          .keyboardShortcut("i", modifiers: .command)
      }
      // ⌘, opens Septask's Settings sheet — standard Preferences shortcut.
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { navigation.showSettings = true }
          .keyboardShortcut(",", modifiers: .command)
      }
      // ⌘⇧/ opens the shortcuts cheat-sheet, in Help like the full app.
      CommandGroup(after: .help) {
        Button("Keyboard Shortcuts") { navigation.showKeyboardShortcuts = true }
          .keyboardShortcut("/", modifiers: [.command, .shift])
      }
    }

    // macOS: Settings is a first-class window (native traffic lights, ⌘W,
    // reused across opens), same as App.swift's Window("Settings"). Opened by
    // SeptaskRootView when `showSettings` flips. A separate scene gets its own
    // environment — replicate the WindowGroup's chain so the panes resolve
    // SettingsStore / CKEngine / mutators / DayClock.
    #if os(macOS)
    Window("Settings", id: "septask-settings") {
      SeptaskSettingsView()
        .environment(navigation)
        .environment(theme)
        .environment(settingsStore)
        .environment(services.taskMutator)
        .environment(services.areasMutator)
        .environment(services.projectsMutator)
        .environment(services.ckEngine)
        .environment(dayClock)
        .environment(logCommit)
        .modelContainer(localStore.container)
        .septenaTextSize()
    }
    .windowResizability(.contentSize)
    #endif
  }
}
