import SwiftUI
import SwiftData
import EventKit
import CloudKit
import Combine
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
    // Explicit id so the menu-bar "Open Septena" can recreate the window via
    // `openWindow(id:)` if it was fully closed (red button) while the app
    // stayed alive serving MCP.
    WindowGroup(id: "main") {
      RootTabView()
        // Single app-wide celebration layer. Mounted INNERMOST (before the
        // .environment chain) so the overlay is a descendant of every
        // environment below — including `logCommit` itself, which it reads.
        // (`.overlay` applied *after* `.environment` would place the overlay
        // OUTSIDE that scope and crash on the first frame.) Presented sheets
        // still render above it, so sheet-based logs fire after dismissal.
        .overlay { LogCommitOverlay() }
        // Septena keeps everything in the user's private iCloud, so warn
        // plainly when there's no usable account. Applied here (inside the
        // .environment chain below) so it can read `ckEngine`.
        .iCloudRequirementWarning()
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
                // Surface milestones earned while away (background Withings
                // ingest, logs from intents, another device's data syncing in).
                MilestonePresenter.presentPending(
                  milestones: services.milestoneMutator, theme: theme,
                  logCommit: logCommit, now: dayClock.now)
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
          // Best-effort: re-extract App Shortcut parameter suggestions so a
          // section disabled since last launch (here, on another device, or
          // via MCP) no longer offers its items in Siri / Spotlight. Not
          // load-bearing — disabled sections refuse in `requireSection()` and
          // their `suggestedEntities` return empty when the picker is shown.
          SeptenaShortcuts.updateAppShortcutParameters()
          #endif
          // Wire CKEngine's SwiftData seams, bind the mutators, start
          // the engine. Idempotent — AppIntents call the same entry
          // point, so a Siri-triggered cold launch and the scene's
          // `.task` race safely. Local-only and fast: the awaited part of
          // this `.task` ends right after the delegate stashing below, so
          // the first frame paints from the SwiftData mirror without
          // waiting on any network round-trip.
          await services.start()
          #if DEBUG
          // Catch section identity↔behavior drift in dev: every manifest row
          // must have a plugin and vice versa (the join is a runtime string).
          SectionRegistry.assertManifestParity()
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
          // Resume the local MCP server if the user left it enabled. Mutators
          // are bound now (start() above), so it's safe to serve writes.
          if UserDefaults.standard.bool(forKey: MCPDefaultsKey.enabled) {
            try? LocalMCPServer.shared.start()
          }
          #endif
          // `SectionTheme.init` and `SettingsStore.init` already hydrated
          // tile order + accent colors from disk synchronously, so the
          // first frame is correct — let it paint NOW. Everything below
          // (the CloudKit pull, the post-fetch refreshes/migrations, the
          // diagnostics) runs unawaited so launch never blocks on the
          // network or on full-table housekeeping scans. Internal order is
          // preserved: steps that want fetched data in hand still run
          // after `absorbRemoteChanges()` completes.
          Task { @MainActor in
            // Diagnostic snapshot of the local store. Surfaces migration
            // corruption / partial-state situations in the console without
            // an Inspector — but it's three full-table scans, so it has no
            // business ahead of the first frame.
            LocalCache.logTaskStateSummary(in: localStore.container.mainContext)
            // Pull CloudKit (+ project-graph heal, occurredAt backfill,
            // timezone publish), then refresh the mirror-backed surfaces
            // to absorb any remote changes.
            await services.absorbRemoteChanges()
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
            // One-shot: lift legacy macro targets (MacrosConfig bands) into
            // range goals. After CK fetch above so it won't duplicate bands a
            // sibling device already migrated.
            MacroTargetMigration.runIfNeeded(context: localStore.container.mainContext)
            // Milestone reconcile. The first pass per scope is the grandfather
            // pass: every already-qualified rung is granted silently, so launch
            // day never celebrates history. Runs after the CK fetch above so a
            // sibling device's milestone rows are already folded in (the
            // deterministic ids make the order moot, but quiet is quieter).
            // Body goals DO celebrate here — crossings that happened while the
            // app was away queue for the presenter below.
            let milestones = services.milestoneMutator
            milestones.evaluateBodyGoals(now: dayClock.now, today: dayClock.today)
            milestones.evaluateTraining(now: dayClock.now, celebrate: false)
            milestones.evaluateAllHabitStreaks(now: dayClock.now, today: dayClock.today)
            MilestonePresenter.presentPending(milestones: milestones, theme: theme,
                                              logCommit: logCommit, now: dayClock.now)
            #if DEBUG
            // One-shot, DEBUG-only: register optional CloudKit fields that
            // exist in code but were never written in Development, so they
            // promote to Production (which won't auto-register on write).
            // See docs/CloudKitSchema.md § Dev schema reconciliation.
            SchemaSeedRegistrar.runIfNeeded()
            #endif
            #if os(iOS)
            TrainingLiveActivityCoordinator.shared.reconcile(with: trainingDraft.draft)
            #endif
            await runRemindersAutoImport()
          }
        }
        .onReceive(NotificationCenter.default
          .publisher(for: .EKEventStoreChanged)) { _ in
          Task { await runRemindersAutoImport() }
        }
        // Detectors at the mutator boundary only WRITE milestone rows; this
        // debounced watcher is what actually fires the celebration, within a
        // beat of the log that earned it. One presentation path for every
        // source — see MilestonePresenter.
        .onReceive(NotificationCenter.default
          .publisher(for: .septenaDataChanged)
          .filter { $0.affectsSection("milestones") }
          .debounce(for: .seconds(0.6), scheduler: RunLoop.main)) { _ in
          MilestonePresenter.presentPending(
            milestones: services.milestoneMutator, theme: theme,
            logCommit: logCommit, now: dayClock.now)
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
    // ⌘1-4 switch the four top-level tabs (Week / Next / Tasks / Goals) via
    // `nav.pendingTab`, which RootTabView observes. ⌥⌘1-5 jump to the Tasks
    // smart lists; each first hops to the Tasks tab so the filter is visible
    // no matter which tab you're on, then sets nav.path to the route.
    .commands {
      CommandMenu("Go") {
        Button("Week")  { navigation.pendingTab = .week }
          .keyboardShortcut("1", modifiers: .command)
        Button("Next")  { navigation.pendingTab = .next }
          .keyboardShortcut("2", modifiers: .command)
        Button("Tasks") { navigation.pendingTab = .tasks }
          .keyboardShortcut("3", modifiers: .command)
        Button("Goals") { navigation.pendingTab = .goals }
          .keyboardShortcut("4", modifiers: .command)

        Divider()

        Button("Inbox")       { navigation.pendingTab = .tasks; navigation.path = [.filter(.inbox)] }
          .keyboardShortcut("1", modifiers: [.command, .option])
        Button("Today")       { navigation.pendingTab = .tasks; navigation.path = [.filter(.today)] }
          .keyboardShortcut("2", modifiers: [.command, .option])
        Button("Next List")   { navigation.pendingTab = .tasks; navigation.path = [.next] }
          .keyboardShortcut("3", modifiers: [.command, .option])
        Button("Upcoming")    { navigation.pendingTab = .tasks; navigation.path = [.filter(.upcoming)] }
          .keyboardShortcut("4", modifiers: [.command, .option])
        Button("Unscheduled") { navigation.pendingTab = .tasks; navigation.path = [.filter(.unscheduled)] }
          .keyboardShortcut("5", modifiers: [.command, .option])
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
      // ⌘? opens the keyboard-shortcuts cheat-sheet. Sits in the Help menu —
      // the standard macOS home for it — and surfaces in the iPad ⌘-HUD too.
      CommandGroup(after: .help) {
        Button("Keyboard Shortcuts") { navigation.showKeyboardShortcuts = true }
          .keyboardShortcut("/", modifiers: [.command, .shift])
      }
      #if os(macOS)
      // When the local MCP server is on, ⌘Q soft-quits (hides to the menu bar
      // so the server keeps serving). ⌥⌘Q forces a real exit. When the server
      // is off, plain ⌘Q quits as usual — the soft-quit path is gated on it.
      CommandGroup(after: .appTermination) {
        Button("Quit Septena Completely") { MacAppLifecycle.quitCompletely() }
          .keyboardShortcut("q", modifiers: [.command, .option])
      }
      #endif
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

// MARK: - iCloud requirement warning

/// Surfaces a warning when the device has no usable iCloud account.
/// Septena stores everything in the user's private CloudKit database — no
/// account means nowhere to read or write — so we say so plainly rather
/// than failing silently. Driven by `CKEngine.accountStatus` (refreshed
/// on launch, foreground, and `.CKAccountChanged`). Only the definitive
/// "missing" states trip it; the transient `.couldNotDetermine` /
/// `.temporarilyUnavailable` don't, so a slow first status query never
/// flashes a false warning.
private struct ICloudRequirementModifier: ViewModifier {
  @Environment(CKEngine.self) private var ckEngine
  @State private var showAlert = false

  func body(content: Content) -> some View {
    content
      .onAppear { showAlert = Self.accountMissing(ckEngine.accountStatus) }
      .onChange(of: ckEngine.accountStatus) { _, status in
        showAlert = Self.accountMissing(status)
      }
      .alert("iCloud Required", isPresented: $showAlert) {
        #if os(iOS)
        Button("Open Settings") { Self.openSettings() }
        #endif
        Button("OK", role: .cancel) { }
      } message: {
        Text("Septena keeps all your data in your private iCloud, so it needs you signed in. Open Settings and sign in to iCloud to use the app and sync across your devices.")
      }
  }

  /// Definitive "no usable account" states. `.couldNotDetermine` and
  /// `.temporarilyUnavailable` are transient (slow query, momentary
  /// outage) and deliberately excluded.
  private static func accountMissing(_ status: CKAccountStatus) -> Bool {
    status == .noAccount || status == .restricted
  }

  #if os(iOS)
  private static func openSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
      UIApplication.shared.open(url)
    }
  }
  #endif
}

private extension View {
  func iCloudRequirementWarning() -> some View {
    modifier(ICloudRequirementModifier())
  }
}
