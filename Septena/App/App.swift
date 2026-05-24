import SwiftUI
import SwiftData
import EventKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

@main
struct SeptenaApp: App {
  @State private var clientProvider = ClientProvider.shared
  @State private var navigation = NavigationState()
  @State private var theme = SectionTheme()
  @State private var trainingDraft = TrainingDraftStore()
  @State private var settingsStore = SettingsStore()
  /// App-wide "what day / what time is it" clock. Views read `today`/`now`
  /// from this instead of calling `SeptenaDate.today` or `Date()` so they
  /// re-render on midnight rollover and on each minute tick uniformly.
  @State private var dayClock = DayClock()
  private let localStore = LocalStore.shared
  /// Process-wide accessor for the CloudKit-backed mutation stack.
  /// Owns `ckEngine`, `taskMutator`, `areasMutator`, `projectsMutator`
  /// so AppIntents (Siri / Shortcuts) can reach the same instances the
  /// SwiftUI scene uses — see SeptenaServices.swift for the rationale.
  /// The properties below are convenience aliases so the view body /
  /// environment-injection sites read like before.
  private let services = SeptenaServices.shared
  private var ckEngine: CKEngine { services.ckEngine }
  private var taskMutator: TaskMutator { services.taskMutator }
  private var checklistMutator: ChecklistMutator { services.checklistMutator }
  private var areasMutator: AreasMutator { services.areasMutator }
  private var projectsMutator: ProjectsMutator { services.projectsMutator }
  private var aranetBridge: AranetBridge { services.aranetBridge }
  private var airStore: AirStore { services.airStore }
  private var pollenClient: PollenClient { services.pollenClient }
  /// Drives drainer kicks on foreground / coming-back-online transitions.
  @Environment(\.scenePhase) private var scenePhase
  #if os(iOS)
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  private let watchBridge = WatchBridge.shared
  #endif
  #if os(macOS)
  @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var macAppDelegate
  #endif

  var body: some Scene {
    WindowGroup {
      RootTabView()
        .environment(clientProvider.client)
        .environment(navigation)
        .environment(theme)
        .environment(trainingDraft)
        .environment(settingsStore)
        .environment(taskMutator)
        .environment(checklistMutator)
        .environment(areasMutator)
        .environment(projectsMutator)
        .environment(dayClock)
        .environment(ckEngine)
        .environment(aranetBridge)
        .environment(airStore)
        .environment(pollenClient)
        .modelContainer(localStore.container)
        .onChange(of: scenePhase) { _, phase in
          // Foreground transitions are the best moment to flush any
          // mutations that were queued while offline / suspended, and
          // to re-check the clock so a backgrounded-across-midnight
          // session flips `today` before any view renders. We also pull
          // from CloudKit here — silent pushes can be coalesced or
          // dropped by APNs, so foregrounding must be a reliable
          // refresh path independent of push delivery.
          if phase == .active {
            dayClock.refreshIfNeeded()
            Task {
              await ckEngine.refreshAccountStatus()
              try? await ckEngine.fetchChanges()
            }
          }
        }
        .task {
          #if os(iOS)
          // Drain any shortcut captured during cold launch — the
          // AppDelegate stashes it before NavigationState exists.
          if let pending = AppDelegate.consumePendingShortcut() {
            navigation.pendingShortcut = pending
          }
          AppDelegate.navigation = navigation
          #endif
          // Diagnostic snapshot of the local store at launch. Surfaces
          // migration corruption / partial-state situations in the
          // console immediately — no Inspector required.
          LocalCache.logTaskStateSummary(in: localStore.container.mainContext)
          // Wire CKEngine's SwiftData seams, bind the mutators, start
          // the engine. Idempotent — AppIntents call the same entry
          // point, so a Siri-triggered cold launch and the scene's
          // `.task` race safely.
          await services.start()
          // Stash the engine on the platform's app delegate so silent
          // remote-notification callbacks (which aren't part of any
          // SwiftUI view hierarchy) can hand the push payload back to
          // the engine for a fetch.
          #if os(iOS)
          AppDelegate.ckEngine = ckEngine
          #endif
          #if os(macOS)
          MacAppDelegate.ckEngine = ckEngine
          #endif
          // Two-phase load for tile order + section colors. Disk reads
          // are synchronous so the dashboard renders with the user's
          // ordering and palette on the first frame; then pull CloudKit
          // before refreshing the mirror-backed settings surfaces.
          theme.paintFromCache()
          settingsStore.paintFromCache()
          try? await ckEngine.fetchChanges()
          await theme.refresh()
          await settingsStore.refresh()
          BadgeManager.shared.start(context: localStore.container.mainContext)
          TrainingMuscleBackfill.runIfNeeded(context: localStore.container.mainContext)
          TrainingLibraryEnrichment.runIfNeeded(context: localStore.container.mainContext)
          TrainingMuscleBackfillV2.runIfNeeded(context: localStore.container.mainContext)
          // Repair orphan routine slugs *after* the backfills run so any
          // stub entities created here inherit the latest inference rules.
          RoutineSlugRepair.runIfNeeded(context: localStore.container.mainContext)
          // Run after RoutineSlugRepair so any stubs it created that
          // collide with library/manual entries get collapsed.
          DuplicateExerciseMerge.runIfNeeded(context: localStore.container.mainContext)
          await runRemindersAutoImport()
        }
        .onReceive(NotificationCenter.default
          .publisher(for: .EKEventStoreChanged)) { _ in
          Task { await runRemindersAutoImport() }
        }
        .onAppear {
          #if canImport(UIKit)
          UITableView.appearance().keyboardDismissMode = .interactive
          #endif
        }
    }
    // macOS: drop the "Septena" title strip. Traffic lights remain — the
    // window chrome collapses into the toolbar area, giving the sidebar /
    // detail content the full height like the reference design does.
    #if os(macOS)
    .windowStyle(.hiddenTitleBar)
    #endif
    // ⌘1-4 jump to the smart lists. compact: 1=Inbox, 2=Today, 3=Upcoming,
    // 4=Unscheduled. Sets nav.path to the route directly so it works from
    // anywhere in the app, including detail screens.
    .commands {
      CommandMenu("Go") {
        Button("Inbox")       { navigation.path = [.filter(.inbox)] }
          .keyboardShortcut("1", modifiers: .command)
        Button("Today")       { navigation.path = [.filter(.today)] }
          .keyboardShortcut("2", modifiers: .command)
        Button("Next")        { navigation.path = [.next] }
          .keyboardShortcut("3", modifiers: .command)
        Button("Upcoming")    { navigation.path = [.filter(.upcoming)] }
          .keyboardShortcut("4", modifiers: .command)
        Button("Unscheduled") { navigation.path = [.filter(.unscheduled)] }
          .keyboardShortcut("5", modifiers: .command)
      }
      // Row-level actions, fed by `TaskListView`'s `focusedSceneValue`.
      // Items disable themselves when no task list is focused, which also
      // gates the shortcut so ⌘T can't fire from an unrelated screen.
      CommandMenu("Task") { TaskCommandsMenu() }
      // ⌘/ toggles the sidebar. Lives in the standard View > Sidebar group
      // so macOS shows it alongside the built-in column-visibility items.
      CommandGroup(after: .sidebar) {
        Button(navigation.sidebarVisibility == .detailOnly
               ? "Show Sidebar" : "Hide Sidebar") {
          navigation.sidebarVisibility =
            navigation.sidebarVisibility == .detailOnly ? .all : .detailOnly
        }
        .keyboardShortcut("/", modifiers: .command)
      }
      // ⌘, opens the Settings sheet — standard macOS Preferences shortcut.
      // Replaces the system app-settings menu item so it routes to ours
      // (the SwiftUI `Settings` scene isn't used; everything is one sheet).
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { navigation.showSettings = true }
          .keyboardShortcut(",", modifiers: .command)
      }
      // ⌘K opens Add Info — the unified quick-add palette (port of the
      // webapp's ⌘K). Quick Find moves to ⌘⇧F so it stays reachable from
      // the keyboard but the more frequently used "capture" action gets
      // the shorter shortcut.
      CommandMenu("Add") {
        Button("Add Info…") { navigation.showAddInfo = true }
          .keyboardShortcut("k", modifiers: .command)
      }
      CommandMenu("Find") {
        Button("Quick Find…") { navigation.showQuickFind = true }
          .keyboardShortcut("f", modifiers: [.command, .shift])
      }
      // Override the default ⌘N "New Window" with "New To-Do". When a task
      // list is focused, `NewTaskCommand` routes to the in-list inline
      // creator so the new row inherits the list's project/area context;
      // otherwise it falls back to the menu-bar Quick Add path (jump to
      // Inbox + draft a row), the same flow as the iOS Quick Action.
      CommandGroup(replacing: .newItem) { NewTaskCommand() }
    }

    // macOS menu bar quick-entry. Click the checklist glyph in the status
    // bar to drop a small "Quick Add" popover for capturing a task without
    // focusing the main window. Mirrors Things' Quick Entry but always
    // available, no global hotkey required.
    #if os(macOS)
    MenuBarExtra {
      MenuBarMenu()
    } label: {
      // MenuBarExtra labels must be Text/Image/Label — arbitrary Views
      // (e.g. Canvas) get silently dropped by the status bar.
      // `Discs` is the brand glyph as a monochrome PNG (1x/2x/3x) flagged
      // template-rendering-intent in the asset catalog, so it picks up
      // the menu bar tint automatically. PNG > SVG here because the
      // vector+template combo proved unreliable. The raster is sized at
      // 18pt (36/54 for 2x/3x) — MenuBarExtra uses the image's intrinsic
      // size and ignores SwiftUI .frame() on the label.
      Image("Discs")
    }
    .menuBarExtraStyle(.menu)
    #endif
  }

  /// Drains the Reminders source list into Septena when the user has opted
  /// in. Routes through `taskMutator` so imports land in CloudKit like every
  /// other task creation path. Posts `.septenaTasksChanged` after a successful run so any
  /// open task list refreshes without manual reload.
  @MainActor
  private func runRemindersAutoImport() async {
    let bridge = RemindersBridge.shared
    let before = bridge.recentImports.count
    // Belt-and-suspenders: scene `.task` has already awaited this, but
    // `.EKEventStoreChanged` can fire before `start()` returns on the
    // very first launch — awaiting the cached task here is a no-op once
    // ready, and the guarantee that `taskMutator` routes to CloudKit.
    await services.start()
    await bridge.runAutoImport { title, due, notes in
      _ = taskMutator.create(title: title, due: due, notes: notes)
    }
    if bridge.recentImports.count != before {
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
  }
}
