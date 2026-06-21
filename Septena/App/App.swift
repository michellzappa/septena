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
  @State private var navigation = NavigationState()
  @State private var theme = SectionTheme()
  @State private var trainingDraft = TrainingDraftStore()
  @State private var settingsStore = SettingsStore()
  /// StoreKit 2 backing for "Support Septena" (patronage). Drives only the
  /// cosmetic supporter state — see SupportStore.
  @State private var supportStore = SupportStore()
  /// App-wide celebration layer. Fired by foreground log actions (habit
  /// streaks today; consumables next), played by a single LogCommitOverlay.
  @State private var logCommit = LogCommitCenter()
  /// App-wide "what day / what time is it" clock. Views read `today`/`now`
  /// from this instead of calling `SeptenaDate.today` or `Date()` so they
  /// re-render on midnight rollover and on each minute tick uniformly.
  @State private var dayClock = DayClock()
  /// Whole-app privacy gate (Face ID / Touch ID / passcode). No-op unless the
  /// user turns it on in Settings ▸ Privacy. Driven below from `scenePhase`.
  @State private var appLock = AppLock()
  /// Whether the user already supports the app (mock today). Only drives the
  /// cosmetic badge — and suppresses the one-time support moment below.
  @AppStorage(SettingsKey.plusUnlocked) private var plusUnlocked = false
  /// One-time gate: the gentle "support Septena" moment is shown at most once,
  /// ever, after a milestone once the user is well-established.
  @AppStorage(SettingsKey.supportMomentShown) private var supportMomentShown = false
  /// Armed (in-memory, this session) when an eligible user just earned a
  /// milestone; presented on the next foreground so it never stacks on the
  /// celebration itself.
  @State private var supportMomentPending = false
  @State private var showSupportMoment = false
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
        // Privacy lock cover. Applied AFTER LogCommitOverlay so it layers
        // above it, and (like the overlays here) before the .environment
        // chain, so it can read `appLock` from the environment below.
        .overlay { AppLockCover() }
        // Septena keeps everything in the user's private iCloud, so warn
        // plainly when there's no usable account. Applied here (inside the
        // .environment chain below) so it can read `ckEngine`.
        .iCloudRequirementWarning()
        // First-run welcome (section picker + chained onboarding). Applied
        // innermost, like the iCloud warning, so the gate modifier sits
        // inside the .environment scope below and can read SettingsStore /
        // SectionTheme / CKEngine / DayClock. Self-gating: a no-op once the
        // account has been onboarded.
        .welcomeGate()
        // The earned "support Septena" moment — shown at most once, only to a
        // well-established user, and only on a foreground after a milestone.
        // It's the support screen (sells nothing functional); marking it shown
        // on present guarantees once-ever regardless of outcome.
        .sheet(isPresented: $showSupportMoment) {
          SeptenaPlusPaywall()
            .onAppear { supportMomentShown = true }
        }
        .environment(navigation)
        .environment(theme)
        .environment(trainingDraft)
        .environment(settingsStore)
        .environment(supportStore)
        .environment(taskMutator)
        .environment(checklistMutator)
        .environment(areasMutator)
        .environment(projectsMutator)
        .environment(dayClock)
        .environment(ckEngine)
        .environment(logCommit)
        .environment(appLock)
        .modelContainer(localStore.container)
        .onChange(of: scenePhase) { _, phase in
          // Drive the privacy lock first: re-arm / re-cover on background,
          // prompt for auth on return. No-op unless the user enabled it.
          appLock.handle(scenePhase: phase)
          // Foreground transitions are the best moment to flush any
          // mutations that were queued while offline / suspended, and
          // to re-check the clock so a backgrounded-across-midnight
          // session flips `today` before any view renders. We also pull
          // from CloudKit here — silent pushes can be coalesced or
          // dropped by APNs, so foregrounding must be a reliable
          // refresh path independent of push delivery.
          if phase == .active {
            // Present the support moment armed in a prior session — before the
            // fresh milestone check below, so a thank-you ask and a brand-new
            // celebration never land on top of each other.
            if supportMomentPending, !supportMomentShown, !showSupportMoment {
              supportMomentPending = false
              showSupportMoment = true
            }
            dayClock.refreshIfNeeded()
            // Re-arm nudges: absorbs a backgrounded-across-midnight rollover
            // and any completions made on another device while we were away.
            LocalNotificationScheduler.shared.reconcile()
            Task {
              await TelemetryClient.shared.trackAppOpen()
              let sections = await MainActor.run {
                SettingsMirror.loadSections(context: localStore.container.mainContext)
              }
              await TelemetryClient.shared.trackSectionInventory(sections)
              await ckEngine.refreshAccountStatus()
              try? await ckEngine.fetchChanges()
              // Republish the watch snapshot after pulling — this is also how
              // watch-originated completions get reflected back to the watch.
              await MainActor.run {
                WatchSnapshotPublisher.schedule(context: localStore.container.mainContext)
                // Surface milestones earned while away (background Withings
                // ingest, logs from intents, another device's data syncing in).
                if MilestonePresenter.presentPending(
                  milestones: services.milestoneMutator, theme: theme,
                  logCommit: logCommit, now: dayClock.now) {
                  armSupportMoment()
                }
              }
            }
            // Keep the Claude gateway's CloudKit token fresh. No-op unless
            // the user connected Claude, and skips the network when the
            // last push is still well within token lifetime.
            Task { await ClaudeGatewayProvider.shared.refreshIfNeeded() }
            // Re-check support entitlement on foreground — a renewal, lapse, or
            // purchase on another device should reflect here without a relaunch.
            Task { await supportStore.refreshEntitlement() }
          }
        }
        .onOpenURL { url in
          handleDeepLink(url)
        }
        // Resolve support products + current entitlement once, off the first
        // frame (it's a network round-trip). Mirrors the supporter state into
        // the cosmetic `plusUnlocked` flag the rest of the app reads.
        .task { await supportStore.start() }
        .task {
          // Cold-launch arm: `onChange(of:)` doesn't fire for the initial
          // scene phase, so kick the first biometric prompt here when the app
          // came up locked. No-op when the lock is off.
          appLock.handle(scenePhase: scenePhase)
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
          await PerfTrace.span("app.servicesStart") { await services.start() }
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
            // exists: `.septenaTasksChanged` reloads tasks; `.septenaDataChanged`
            // reloads the mirror-backed tiles (nutrition, training, mood, gut,
            // intake, chores, groceries, hydration…) and recomputes their
            // derived caches — without it those rows show 0 despite seeded data.
            NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
            NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
            // Invalidate the process-wide areas/projects memo (cached empty at
            // launch, before the seed inserted them) so the Tasks sidebar shows
            // the seeded structure instead of a bare smart-list grid.
            NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
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
            PerfTrace.spanSync("app.logTaskStateSummary") {
              LocalCache.logTaskStateSummary(in: localStore.container.mainContext)
            }
            // Pull CloudKit (+ project-graph heal, occurredAt backfill,
            // timezone publish), then refresh the mirror-backed surfaces
            // to absorb any remote changes.
            await PerfTrace.span("app.absorbRemoteChanges") {
              await services.absorbRemoteChanges()
            }
            // Spotlight "readability" backfill — donate tasks + the catalog
            // entities (habits, supplements, chores, exercises, session types,
            // grocery items/categories) to the on-device index after the pull
            // (not the pre-sync mirror) so system search and, per Apple, Apple
            // Intelligence / personal-context Siri can find them. `start()` then
            // keeps the index live off `.septenaTasksChanged` /
            // `.septenaDataChanged` (incl. section enable/disable purge). See
            // docs/SPOTLIGHT_READABILITY_PLAN.md.
            SpotlightIndexer.shared.start()
            await SpotlightIndexer.shared.backfill()
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
            // Same bridge for the weight-unit preference: adopt an inbound
            // value from another device, or push the locale-seeded local
            // default up so it syncs.
            settingsStore.reconcileUnits(
              context: localStore.container.mainContext, engine: ckEngine)
            // Grandfather established accounts past the first-run welcome:
            // `onboardedAt` is a new field, so every pre-existing user starts
            // nil — stamp it when the account already has data so the welcome
            // only ever shows to genuinely fresh accounts. Runs after the pull
            // so a returning user's new device sees their synced content.
            settingsStore.grandfatherOnboardingIfEstablished(
              now: dayClock.now,
              context: localStore.container.mainContext, engine: ckEngine)
            // Same bridge for the first-run onboarding marker: adopt a synced
            // `onboardedAt` (a returning user's new device, dismissing the
            // welcome once their data syncs in) or push a local completion up.
            settingsStore.reconcileOnboarding(
              context: localStore.container.mainContext, engine: ckEngine)
            // Seed the Claude gateway token on cold launch (no-op if Claude
            // isn't connected or a recent token is still valid).
            await ClaudeGatewayProvider.shared.refreshIfNeeded()
            BadgeManager.shared.start(context: localStore.container.mainContext)
            // Behavioral nudge layer. Start the scheduler (reconciles now and
            // on every section data-change, like BadgeManager) but DON'T prompt
            // for notification permission at launch — that's asked only when the
            // user opts in, in Settings ▸ Notifications. Until then the OS status
            // is `.notDetermined` and `apply` no-ops, so nothing fires.
            LocalNotificationScheduler.shared.start(context: localStore.container.mainContext)
            // One-shot: lift legacy macro targets (MacrosConfig bands) into
            // range goals. After CK fetch above so it won't duplicate bands a
            // sibling device already migrated.
            MacroTargetMigration.runIfNeeded(context: localStore.container.mainContext)
            // One-shot: materialize training's built-in weekly targets (12–20
            // hard sets, 150 cardio min, 4 sessions) as editable goals, for
            // users who train. After CK fetch so it won't duplicate a seed.
            TrainingTargetMigration.runIfNeeded(context: localStore.container.mainContext)
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
            if MilestonePresenter.presentPending(milestones: milestones, theme: theme,
                                                 logCommit: logCommit, now: dayClock.now) {
              armSupportMoment()
            }
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
          if MilestonePresenter.presentPending(
            milestones: services.milestoneMutator, theme: theme,
            logCommit: logCommit, now: dayClock.now) {
            armSupportMoment()
          }
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

        Button("Today")    { navigation.pendingTab = .tasks; navigation.path = [.filter(.today)] }
          .keyboardShortcut("1", modifiers: [.command, .option])
        Button("Upcoming") { navigation.pendingTab = .tasks; navigation.path = [.filter(.upcoming)] }
          .keyboardShortcut("2", modifiers: [.command, .option])
        Button("Anytime")  { navigation.pendingTab = .tasks; navigation.path = [.filter(.unscheduled)] }
          .keyboardShortcut("3", modifiers: [.command, .option])

        Divider()

        // Quick Find — the jump-to-anything palette. Lives in Go (the app's
        // navigation menu) rather than a bespoke top-level "Find" menu, the
        // way Xcode's "Open Quickly…" sits under File.
        Button("Quick Find…") { navigation.showQuickFind = true }
          .keyboardShortcut("f", modifiers: [.command, .shift])
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
      // webapp's ⌘K). It's a "capture" action, so it sits in File alongside
      // New To-Do rather than in a bespoke top-level "Add" menu. Quick Find
      // (⌘⇧F) lives in the Go menu above.
      CommandGroup(after: .newItem) {
        Button("Add Info…") { navigation.showAddInfo = true }
          .keyboardShortcut("k", modifiers: .command)
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

    // Settings as a first-class window rather than a sheet, so it carries
    // native traffic lights and closes like any window (the user's
    // expectation on macOS). Opened by RootTabView when `showSettings`
    // flips; a fixed window id means repeat opens reuse the one window.
    // `.contentSize` resizability pins it to SettingsView's own frame and
    // drops the zoom button — there's nothing to maximize into.
    Window("Settings", id: "settings") {
      SettingsView(initialDestination: navigation.settingsDestination)
        // A separate scene gets its own environment — replicate the main
        // WindowGroup's chain above so SettingsView resolves SettingsStore /
        // CKEngine / NavigationState / SectionTheme. Keep the two in sync.
        .environment(navigation)
        .environment(theme)
        .environment(trainingDraft)
        .environment(settingsStore)
        .environment(supportStore)
        .environment(taskMutator)
        .environment(checklistMutator)
        .environment(areasMutator)
        .environment(projectsMutator)
        .environment(dayClock)
        .environment(ckEngine)
        .environment(logCommit)
        .modelContainer(localStore.container)
    }
    // Hidden title bar so the sidebar background runs to the top of the window
    // and the traffic lights float over it — the System Settings layout. The
    // window title text is dropped along with the strip; SettingsView already
    // labels each pane in the detail column, so nothing is lost.
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    .defaultPosition(.center)
    #endif
  }

  /// Arm the one-time "support Septena" moment after a milestone just fired —
  /// but only for a well-established user who isn't already a supporter and
  /// hasn't seen it. Armed in-memory; the next foreground presents it, so the
  /// ask never lands on top of the celebration that earned it. The 30-day
  /// floor (from the synced `onboardedAt`) keeps it from ever feeling early.
  @MainActor
  private func armSupportMoment() {
    guard !supportMomentShown, !plusUnlocked, !supportMomentPending,
          !showSupportMoment else { return }
    guard let onboarded = settingsStore.serverSettings?.onboardedAt,
          dayClock.now.timeIntervalSince(onboarded) >= 30 * 24 * 60 * 60 else { return }
    supportMomentPending = true
  }

  private func handleDeepLink(_ url: URL) {
    guard url.scheme == "septena" else { return }
    if url.host == "training", url.path == "/active" {
      navigation.showTrainingSession = true
    } else if url.host == "next" {
      // The Next widget opens straight to the Next tab.
      navigation.pendingTab = .next
    } else if url.host == "home" {
      // The time-wheel widget opens the Week dashboard — where the full
      // homepage dial / Wheel layout lives.
      navigation.pendingTab = .week
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
      _ = taskMutator.create(title: title, deadline: due, notes: notes)
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
  // Hold the iCloud warning until the first-run welcome is done, so a fresh
  // install sees the welcome and nothing else. Once onboarded (or on an
  // established account, where the flag is already set), it behaves as before.
  @AppStorage(SettingsKey.welcomeCompleted) private var welcomeCompleted = false
  @State private var showAlert = false

  func body(content: Content) -> some View {
    content
      .onAppear { showAlert = shouldWarn(ckEngine.accountStatus) }
      .onChange(of: ckEngine.accountStatus) { _, status in
        showAlert = shouldWarn(status)
      }
      .onChange(of: welcomeCompleted) { _, _ in
        showAlert = shouldWarn(ckEngine.accountStatus)
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

  /// Warn only for a definitively-missing account AND only once the welcome
  /// is behind us — the welcome owns the first-launch screen on its own.
  /// Demo-seed (screenshot / UI-test) builds skip CloudKit entirely, so the
  /// warning would be both false and a tap-blocking alert mid-capture; suppress
  /// it there.
  private func shouldWarn(_ status: CKAccountStatus) -> Bool {
    !DemoSeedMode.isOn && welcomeCompleted && Self.accountMissing(status)
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
