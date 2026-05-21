import SwiftUI
import SwiftData
import AppIntents
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
  /// Owns `ckEngine`, `taskMutator`, `areasMutator`, `projectsMutator`,
  /// and `httpOutbox` so AppIntents (Siri / Shortcuts) can reach the
  /// same instances the SwiftUI scene uses — see SeptenaServices.swift
  /// for the rationale. The properties below are convenience aliases
  /// so the view body / environment-injection sites read like before.
  private let services = SeptenaServices.shared
  private var ckEngine: CKEngine { services.ckEngine }
  private var taskMutator: TaskMutator { services.taskMutator }
  private var areasMutator: AreasMutator { services.areasMutator }
  private var projectsMutator: ProjectsMutator { services.projectsMutator }
  private var httpOutbox: HTTPOutbox { services.httpOutbox }
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
      VStack(spacing: 0) {
        OfflineBanner()
        RootTabView()
      }
        .environment(clientProvider.client)
        .environment(navigation)
        .environment(theme)
        .environment(trainingDraft)
        .environment(settingsStore)
        .environment(taskMutator)
        .environment(areasMutator)
        .environment(projectsMutator)
        .environment(httpOutbox)
        .environment(dayClock)
        .environment(ckEngine)
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
            taskMutator.kickDrain()
            httpOutbox.kickDrain()
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
          // ordering and palette on the first frame; the network refresh
          // overwrites them when it lands.
          theme.paintFromCache()
          settingsStore.paintFromCache()
          await theme.refresh(from: clientProvider.client)
          await settingsStore.refresh(from: clientProvider.client)
          // CKSyncEngine owns the read path. Ask it to pull from CK.
          try? await ckEngine.fetchChanges()
          // Backstop for users whose local mirror is missing areas/projects
          // (e.g. installed before Phase 5b pushed them to CK). If either
          // table is empty AND FastAPI is reachable, pull once and fold
          // in. After they re-run Re-sync to iCloud, the engine's
          // applyFetchedRecord keeps the mirror in sync from CK and this
          // branch is a no-op.
          let context = localStore.container.mainContext
          let areaCount = (try? context.fetchCount(FetchDescriptor<AreaEntity>())) ?? 0
          let projectCount = (try? context.fetchCount(FetchDescriptor<ProjectEntity>())) ?? 0
          SeptenaLog.info("[Hydrate] CK mode launch: areas=\(areaCount) projects=\(projectCount)")
          if areaCount == 0 || projectCount == 0 {
            SeptenaLog.info("[Hydrate] mirror gap — pulling from FastAPI as one-shot")
            if let areas = try? await clientProvider.client.areas(),
               let projects = try? await clientProvider.client.projects() {
              let syncer = Syncer(client: clientProvider.client, context: context)
              syncer.applyAreas(areas)
              syncer.applyProjects(projects)
              NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
              SeptenaLog.info("[Hydrate] seeded \(areas.count) areas, \(projects.count) projects from FastAPI — run Re-sync to iCloud to push to CloudKit")
            } else {
              SeptenaLog.info("[Hydrate] FastAPI pull failed — sidebar will be empty for areas/projects until reachable")
            }
          }
          // Flush anything that was queued in a prior session (e.g. the
          // app was killed mid-drain). Safe to call before/after pullAll
          // since the mutator's pendingSync flag protects rows during
          // upsert, and the drainer is idempotent. In CK mode kickDrain
          // is a no-op (the outbox is empty), so we skip the route check.
          taskMutator.kickDrain()
          httpOutbox.kickDrain()
          BadgeManager.shared.start(context: localStore.container.mainContext)
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
  /// in. Posts `.septenaTasksChanged` after a successful run so any open
  /// task list refreshes without manual reload.
  @MainActor
  private func runRemindersAutoImport() async {
    let client = clientProvider.client
    let bridge = RemindersBridge.shared
    let before = bridge.recentImports.count
    await bridge.runAutoImport { title, due, notes in
      _ = try await client.create(title: title, due: due, notes: notes)
    }
    if bridge.recentImports.count != before {
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
  }
}

// MARK: - Home Screen Quick Actions
//
// Two static shortcuts declared in Info.plist (UIApplicationShortcutItems):
//   - com.septena.app.new-todo   → open Inbox + start an inline draft row
//   - com.septena.app.show-today → jump to Today smart list
// SwiftUI has no native shortcut handler, so a tiny UIApplicationDelegate
// bridges the event into NavigationState. ContentView observes
// `pendingShortcut` and routes accordingly.

enum ShortcutAction: String, Equatable {
  case newTodo   = "com.septena.app.new-todo"
  case showToday = "com.septena.app.show-today"
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
  /// Captured at cold launch before NavigationState exists. The app's
  /// `.task` drains this on first render.
  private static var pending: ShortcutAction?
  /// Set by SeptenaApp once NavigationState is alive — lets warm-launch
  /// shortcut events publish directly without a stash.
  static weak var navigation: NavigationState?
  /// Set by SeptenaApp once the CloudKit engine exists. Silent CK pushes
  /// route through here to `engine.handleRemoteNotification`. Weak so
  /// app teardown doesn't leak.
  static weak var ckEngine: CKEngine?

  static func consumePendingShortcut() -> ShortcutAction? {
    defer { pending = nil }
    return pending
  }

  func application(
    _ application: UIApplication,
    willFinishLaunchingWithOptions launchOptions:
      [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem,
       let action = ShortcutAction(rawValue: item.type) {
      Self.pending = action
      // Return false so the system does NOT also call performActionFor
      // on cold launch — we've already captured it.
      return false
    }
    return true
  }

  func application(
    _ application: UIApplication,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    guard let action = ShortcutAction(rawValue: shortcutItem.type) else {
      completionHandler(false); return
    }
    if let nav = Self.navigation {
      Task { @MainActor in nav.pendingShortcut = action }
    } else {
      Self.pending = action
    }
    completionHandler(true)
  }

  /// Silent CK pushes arrive here. CKSyncEngine's database subscription
  /// triggers a content-available push when another device writes; we
  /// hand the payload to the engine which translates it into a fetch.
  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    Task { @MainActor in
      let handled = await Self.ckEngine?.handleRemoteNotification(userInfo) ?? false
      completionHandler(handled ? .newData : .noData)
    }
  }
}
#endif

#if os(macOS)
final class MacAppDelegate: NSObject, NSApplicationDelegate {
  static weak var ckEngine: CKEngine?

  func application(_ application: NSApplication,
                   didReceiveRemoteNotification userInfo: [String: Any]) {
    Task { @MainActor in
      await Self.ckEngine?.handleRemoteNotification(userInfo)
    }
  }
}
#endif

// MARK: - Routes

enum Route: Hashable {
  case filter(TaskFilter)
  case next
  case project(Project)
  case area(Area)
}

// MARK: - Navigation state

@MainActor
@Observable
final class NavigationState {
  var path: [Route] = []
  /// One-shot trigger: when set to true, the currently-visible
  /// TaskListView starts a new inline task (same flow as ⌘N) on its
  /// next render. TaskListView resets it to false after consuming. Used
  /// by toolbar `+` actions and the sidebar Menu's New To-Do entry, so
  /// 'new task' never opens a modal sheet — always inline, like Things.
  var shouldStartCreating = false

  /// One-shot trigger from a Home Screen Quick Action (long-press app
  /// icon). ContentView dispatches the route change + `shouldStartCreating`
  /// flip, then resets this to nil. nil means "no pending shortcut".
  var pendingShortcut: ShortcutAction?

  /// macOS sidebar visibility — toggled by ⌘/. `.all` shows both columns,
  /// `.detailOnly` collapses the sidebar so detail content runs edge-to-edge.
  var sidebarVisibility: NavigationSplitViewVisibility = .all

  /// Drives the Settings sheet. Flipped from the sidebar's Settings button
  /// and the macOS toolbar gear; the sheet closes via its own Done button.
  var showSettings = false

  /// Drives the Quick Find palette (⌘⇧F). A floating sheet over the main
  /// window; selecting a result routes via `path` and dismisses itself.
  var showQuickFind = false

  /// Drives the unified Add Info palette (⌘K, or long-press the FAB on
  /// touch). Sheet routes capture into any of the ten Septena sections
  /// using the same rules-based smart behaviour as the web ⌘K palette.
  var showAddInfo = false

  /// Optional jump-target — when non-nil, AddInfoSheet opens directly to
  /// that page instead of the root list. Cleared on dismiss.
  var addInfoRequestedSection: AddInfoSection? = nil

  /// Drives the Training session sheet (logger). Flipped from ⌘K's
  /// "Start training" rows, the Training destination's Start button, and
  /// from any future quick-action; the sheet itself reads the live draft
  /// out of `TrainingDraftStore` so resume-after-dismiss just works.
  var showTrainingSession = false

  /// Persisted base URL — UserDefaults-backed, mirrored from ClientProvider.
  var serverURL: String = UserDefaults.standard.string(forKey: "septena.serverURL")
    ?? SeptenaClient.default.absoluteString
}

// MARK: - Content view

struct ContentView: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme

  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  #endif

  var body: some View {
    @Bindable var nav = nav
    layout(path: $nav.path)
      .tint(theme.accent)
      // Settings / QuickFind / AddInfo sheets are mounted at the
      // RootTabView level (so they work from Week / Next, not just the
      // Tasks tab which hosts ContentView).
      .onReceive(NotificationCenter.default
        .publisher(for: .septenaOpenQuickAdd)) { _ in
        // macOS menu bar "New To-Do" routes through here — same effect as
        // iOS Home Screen Quick Action's `.newTodo` case.
        nav.path = [.filter(.inbox)]
        nav.shouldStartCreating = true
      }
      .onChange(of: nav.pendingShortcut) { _, action in
        guard let action else { return }
        switch action {
        case .newTodo:
          nav.path = [.filter(.inbox)]
          nav.shouldStartCreating = true
        case .showToday:
          nav.path = [.filter(.today)]
        }
        nav.pendingShortcut = nil
      }
  }

  @ViewBuilder
  private func layout(path: Binding<[Route]>) -> some View {
    #if os(macOS)
    splitLayout(path: path)
    #else
    if hSize == .regular {
      splitLayout(path: path)
    } else {
      stackLayout(path: path)
    }
    #endif
  }

  // iPhone / compact: sidebar IS the root, routes push onto the stack.
  // The app is conceptually flat (selectRoute replaces the path rather
  // than appending), so stack depth is always 1 — the back chevron iOS
  // renders is simply "return to sidebar".
  private func stackLayout(path: Binding<[Route]>) -> some View {
    NavigationStack(path: path) {
      SidebarRootView()
        .navigationDestination(for: Route.self) { destination(for: $0) }
    }
  }

  // iPad regular / macOS: two-column. Sidebar stays put, detail swaps.
  //
  // The app is conceptually flat — sidebar selection always sets
  // `nav.path = [route]` (single element, never pushed onto). So instead of
  // a NavigationStack(path:) that animates a pop+push on every click, the
  // detail pane just renders the current route directly. `.id(route)` keeps
  // each project/area as its own fresh view instance.
  private func splitLayout(path: Binding<[Route]>) -> some View {
    @Bindable var nav = nav
    let route = nav.path.last ?? .filter(.today)
    return NavigationSplitView(columnVisibility: $nav.sidebarVisibility) {
      SidebarRootView()
    } detail: {
      NavigationStack {
        destination(for: route)
          .padding(.horizontal, Theme.listLeadingInset)
          .background(Theme.paperBackground)
      }
    }
  }

  // Per-route .id is applied INSIDE destination(for:) — TaskListView is
  // intentionally reused across filter swaps (sub-second snap; resets its
  // own session state via .onChange(of: filter)), while Project / Area
  // detail use their entity ids so navigating between two projects gives
  // a fresh view with fresh state.
  @ViewBuilder
  private func destination(for route: Route) -> some View {
    switch route {
    case .filter(let f):  TaskListView(filter: f)
    case .next:           NextView()
    case .project(let p): ProjectDetailView(project: p).id(p.id)
    case .area(let a):    AreaDetailView(area: a).id(a.id)
    }
  }
}

// MARK: - macOS menu bar quick-entry

#if os(macOS)

/// Lightweight Today loader for the menu bar. Fetches via the existing
/// `client.list(view: "today")` API and re-runs whenever a task mutation
/// posts `.septenaTasksChanged`, so the dropdown reflects the same state
/// as the main window without any custom sync.
@MainActor
@Observable
private final class MenuBarTodayLoader {
  var items: [SeptenaTask] = []
  @ObservationIgnored private var observer: NSObjectProtocol?

  init() {
    // First fetch happens when the menu is opened for the first time
    // (which is when @State instantiates this loader).
    Task { await refresh() }
    // Stay in sync with the rest of the app — every mutation posts this.
    observer = NotificationCenter.default.addObserver(
      forName: .septenaTasksChanged, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in await self?.refresh() }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func refresh() async {
    do {
      let resp = try await TaskReads.list(
        view: "today",
        client: ClientProvider.shared.client,
        context: LocalStore.shared.container.mainContext
      )
      // Mirror the Today screen: pinned-today (`items`) plus scheduled/due
      // rolling in (`review`). Completed-today rows live in `done` and stay
      // out of the menu bar.
      items = (resp.items + (resp.review ?? [])).filter { $0.status == .open }
    } catch {
      // Silent: stale items remain visible until the next refresh.
    }
  }
}

/// Standard NSMenu-style dropdown for the menu bar item. Only Button,
/// Divider, and Text are guaranteed to render with `.menuBarExtraStyle(.menu)`
/// — anything else (TextField, ScrollView, custom Views) gets dropped or
/// breaks the menu layout. Quick capture lives in the main app instead,
/// reached via "New To-Do" which activates the window into draft mode.
private struct MenuBarMenu: View {
  @State private var loader = MenuBarTodayLoader()

  var body: some View {
    Button("New To-Do") { startQuickAdd() }
      .keyboardShortcut("n")

    Divider()

    if loader.items.isEmpty {
      Text("Nothing on Today")
    } else {
      Text("Today")
      ForEach(loader.items) { task in
        Button(task.title) { activateMainWindow() }
      }
    }

    Divider()

    Button("Open Septena") { activateMainWindow() }
    Button("Quit Septena") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }

  private func startQuickAdd() {
    activateMainWindow()
    // Posted notification is observed in ContentView — sets path to Inbox
    // and flips `shouldStartCreating`, same as ⌘N / iOS quick action.
    NotificationCenter.default.post(name: .septenaOpenQuickAdd, object: nil)
  }

  private func activateMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows
      .first { $0.canBecomeMain }?
      .makeKeyAndOrderFront(nil)
    Task { await loader.refresh() }
  }
}
#endif

// MARK: - App Intent: "Add to Septena"
//
// Powers Siri ("Hey Siri, add buy milk to Septena"), Spotlight actions,
// and Shortcuts.app. Runs in the app's own process — when the system
// triggers an intent with the app cold-killed, iOS launches it in the
// background just to run `perform()`. That cold-launch path may execute
// before the SwiftUI scene's `.task` mounts, so we can't assume the
// CKEngine has been bound. `SeptenaServices.shared.start()` is the
// shared, idempotent entry point: both the scene and this intent call
// it, the first one wires the stack, the second awaits the same task.
// Once it returns, `taskMutator.create(...)` routes to CloudKit instead
// of falling back to FastAPI.

struct AddTaskIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Task"
  static let description = IntentDescription("Add a new to-do to Septena.")

  @Parameter(title: "Title", requestValueDialog: "What's the task?")
  var taskTitle: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    await SeptenaServices.shared.start()
    _ = SeptenaServices.shared.taskMutator.create(title: taskTitle)
    return .result(dialog: "Added “\(taskTitle)” to Septena.")
  }
}

struct SeptenaShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AddTaskIntent(),
      // AppShortcuts phrases must contain \(.applicationName); the leading
      // "Hey Siri, " is implicit. iOS 26 restricts inline String parameter
      // templating to AppEntity/AppEnum, so the title can't be captured
      // directly from the phrase — once any phrase matches, Siri prompts
      // "What's the task?" via the @Parameter's requestValueDialog. The
      // wide variety here is so the user doesn't have to memorize one
      // exact wording.
      phrases: [
        "Add to \(.applicationName)",
        "Add task to \(.applicationName)",
        "Add reminder to \(.applicationName)",
        "Add a task to \(.applicationName)",
        "Add a to-do to \(.applicationName)",
        "New task in \(.applicationName)",
        "New to-do in \(.applicationName)",
        "New reminder in \(.applicationName)",
        "Create task in \(.applicationName)",
        "Create a task in \(.applicationName)",
        "Save to \(.applicationName)",
        "Capture in \(.applicationName)",
        "Note in \(.applicationName)",
        "Remind me in \(.applicationName)",
        "Remind me with \(.applicationName)",
        "Remind me using \(.applicationName)",
        "In \(.applicationName) remind me",
        "In \(.applicationName) add a task",
        "In \(.applicationName) add a to-do",
        "In \(.applicationName) create a task",
        "Using \(.applicationName) remind me",
      ],
      shortTitle: "Add Task",
      systemImageName: "plus.circle"
    )
  }
}
