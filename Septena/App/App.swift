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
  init() {
    Self.registerFraunces()
  }

  private static func registerFraunces() {
    guard let url = Bundle.main.url(forResource: "Fraunces-Regular", withExtension: "ttf") else { return }
    var errorRef: Unmanaged<CFError>?
    _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef)
    errorRef?.release()
  }

  @State private var navigation = NavigationState()
  @State private var theme = SectionTheme()
  @State private var trainingDraft = TrainingDraftStore()
  @State private var settingsStore = SettingsStore()
  /// App-wide celebration layer. Fired by foreground log actions (habit
  /// streaks today; consumables next), played by a single LogCommitOverlay.
  @State private var logCommit = LogCommitCenter()
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
  /// Drives drainer kicks on foreground / coming-back-online transitions.
  @Environment(\.scenePhase) private var scenePhase
  #if os(iOS)
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  #endif
  #if os(macOS)
  @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var macAppDelegate
  #endif

  var body: some Scene {
    WindowGroup {
      RootTabView()
        // Single app-wide celebration layer. Mounted INNERMOST (before the
        // .environment chain) so the overlay is a descendant of every
        // environment below — including `logCommit` itself, which it reads.
        // (`.overlay` applied *after* `.environment` would place the overlay
        // OUTSIDE that scope and crash on the first frame.) Presented sheets
        // still render above it, so sheet-based logs fire after dismissal.
        .overlay { LogCommitOverlay() }
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
        .environment(logCommit)
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
            // Re-arm nudges: absorbs a backgrounded-across-midnight rollover
            // and any completions made on another device while we were away.
            LocalNotificationScheduler.shared.reconcile()
            Task {
              await ckEngine.refreshAccountStatus()
              try? await ckEngine.fetchChanges()
              // Republish the watch snapshot after pulling — this is also how
              // watch-originated completions get reflected back to the watch.
              await MainActor.run {
                WatchSnapshotPublisher.publish(context: localStore.container.mainContext)
              }
            }
            // Keep the Claude gateway's CloudKit token fresh. No-op unless
            // the user connected Claude, and skips the network when the
            // last push is still well within token lifetime.
            Task { await ClaudeGatewayProvider.shared.refreshIfNeeded() }
          }
        }
        .onOpenURL { url in
          handleDeepLink(url)
        }
        .task {
          #if os(iOS)
          // Drain any shortcut captured during cold launch — the
          // AppDelegate stashes it before NavigationState exists.
          if let pending = AppDelegate.consumePendingShortcut() {
            navigation.pendingShortcut = pending
          }
          AppDelegate.navigation = navigation
          // Apply the user's Quick Actions selection to UIApplication's
          // dynamic shortcut list so the Home Screen long-press menu
          // matches what they picked in Settings.
          QuickActionsApplier.apply()
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
          #if DEBUG
          // Screenshot / UI-test builds: load curated demo data into the
          // in-memory store. No-op in release (DemoSeedMode.isOn is false).
          if DemoSeedMode.isOn {
            DemoSeed.populate(context: localStore.container.mainContext, today: dayClock.today)
            // Direct inserts post no change notifications, so the dashboard's
            // first loadAll() can race ahead of the seed (its synchronous
            // history reads land empty). Nudge a full reload now that the data
            // exists — onTaskChange → loadAll().
            NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
          }
          #endif
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
          // `SectionTheme.init` and `SettingsStore.init` already hydrated
          // tile order + accent colors from disk synchronously, so the
          // first frame is correct. Pull CloudKit, then refresh the
          // mirror-backed surfaces to absorb any remote changes.
          try? await ckEngine.fetchChanges()
          await theme.refresh()
          await settingsStore.refresh()
          // Bridge the welcome name between the CloudKit-synced settings
          // payload and the local @AppStorage key WelcomeHeader reads:
          // adopt an inbound name from another device, or push a
          // pre-existing local-only name up (engine in hand here).
          settingsStore.reconcileWelcomeName(
            context: localStore.container.mainContext, engine: ckEngine)
          // Same bridge for the day-bucket cutoffs: adopt an inbound value
          // from another device, or push a pre-existing local override up.
          settingsStore.reconcileDayBucketCutoffs(
            context: localStore.container.mainContext, engine: ckEngine)
          // Seed the Claude gateway token on cold launch (no-op if Claude
          // isn't connected or a recent token is still valid).
          await ClaudeGatewayProvider.shared.refreshIfNeeded()
          BadgeManager.shared.start(context: localStore.container.mainContext)
          // Behavioral nudge layer. Ask once (no-op if already decided),
          // then start the scheduler — it reconciles now and re-reconciles
          // on every section data-change notification, like BadgeManager.
          // Screenshot / demo-seed builds skip the permission prompt so it
          // doesn't cover the UI in captures.
          if !DemoSeedMode.isOn {
            await LocalNotificationScheduler.shared.requestAuthorizationIfNeeded()
          }
          LocalNotificationScheduler.shared.start(context: localStore.container.mainContext)
          TrainingMuscleBackfill.runIfNeeded(context: localStore.container.mainContext)
          TrainingLibraryEnrichment.runIfNeeded(context: localStore.container.mainContext)
          TrainingMuscleBackfillV2.runIfNeeded(context: localStore.container.mainContext)
          // Repair orphan routine slugs *after* the backfills run so any
          // stub entities created here inherit the latest inference rules.
          RoutineSlugRepair.runIfNeeded(context: localStore.container.mainContext)
          // Run after RoutineSlugRepair so any stubs it created that
          // collide with library/manual entries get collapsed.
          DuplicateExerciseMerge.runIfNeeded(context: localStore.container.mainContext)
          // Derive `occurredAt` for legacy event rows (and first-sync Mood)
          // after the engine has fetched, so pushes carry the real timestamp.
          OccurredAtBackfill.runIfNeeded(context: localStore.container.mainContext)
          // Derive `createdAt` for legacy task rows from their `created`
          // string so the agent-cue decay window has a real instant to read.
          TaskCreatedAtBackfill.runIfNeeded(context: localStore.container.mainContext)
          #if os(iOS)
          TrainingLiveActivityCoordinator.shared.reconcile(with: trainingDraft.draft)
          #endif
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

  private func handleDeepLink(_ url: URL) {
    guard url.scheme == "septena" else { return }
    if url.host == "training", url.path == "/active" {
      navigation.showTrainingSession = true
    } else if url.host == "next" {
      // The Next widget opens straight to the Next tab.
      navigation.pendingTab = .next
    }
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
