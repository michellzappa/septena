import SwiftUI

/// Septask's root. There is no tab bar (removed 2026-11-22, Things /
/// Reminders model): on iPhone the sidebar list (Today, Upcoming, smart lists,
/// areas, projects) IS the root of one `NavigationStack`, and every list
/// pushes onto it. The app opens on Today with the list one Back away. On iPad
/// regular / macOS the split-view sidebar is the switcher. Composition only:
/// `ContentView` and the task views are shared and unchanged.
///
/// Quick capture lives in the floating circular Magic Plus orb
/// (`MagicPlusOrb`) at the bottom-right edge: tap opens the create quick
/// menu, and hold-and-drag drops a new inline task onto any row gap, heading,
/// group, or Upcoming day — or creates a Project/Area on the list root.
/// Search lives in the trailing nav bar.
///
/// Septask has no Next page (removed 2026-11-19: it showed life-OS content,
/// not tasks; Today covers "what's next" for tasks).
struct SeptaskRootView: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  // Read the full task environment here (all injected by SeptaskApp, so these
  // are safe) so the modal sheets below can RE-inject it. `.sheet` normally
  // inherits `@Observable` environment, but the quick-add path presents
  // AddTaskPage directly (not via AddInfoSheet), and a sheet that reparents
  // must not be left guessing — a missing object is a hard launch trap
  // (docs/SEPTASK.md P1 env-injection note).
  @Environment(DayClock.self) private var dayClock
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(AreasMutator.self) private var areasMutator
  @Environment(ProjectsMutator.self) private var projectsMutator
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(LogCommitCenter.self) private var logCommit
  @Environment(\.modelContext) private var modelContext
  @State private var magicPlusDrag = MagicPlusDragState()
  /// True while the software keyboard is up. The orb hides then: while the
  /// user types, it covers the field and the rows around it.
  @State private var keyboardVisible = false
  /// The first run (`SeptaskFirstRun.swift`), shown once per account.
  @State private var showingFirstRun = false
  /// Settings ▸ About ▸ Show Welcome Again sets this; observed so the flow
  /// opens at once instead of on the next launch.
  @AppStorage(SettingsKey.welcomeForce) private var welcomeForce = false
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
  @Environment(\.verticalSizeClass) private var vSize
  /// Matches `ResolveAdaptiveNavigation` (`usesPushNavigation`): split layout
  /// only when BOTH dimensions are regular (unfolded iPhone Duo, iPad full-
  /// screen / large multitasking). Testing `== .regular` rather than
  /// `!= .compact` keeps a transient `nil` size class during fold/unfold in
  /// the safe compact branch, and keeps compact-height landscape phones out of
  /// a cramped split view.
  private var usesSplitLayout: Bool { hSize == .regular && vSize == .regular }
  #else
  @Environment(\.openWindow) private var openWindow
  #endif

  /// Re-inject the whole task environment onto a presented sheet's content —
  /// belt-and-suspenders against `@Observable` environment loss across a
  /// presentation boundary.
  private func withEnvironment<V: View>(_ content: V) -> some View {
    content
      .environment(nav)
      .environment(theme)
      .environment(dayClock)
      .environment(taskMutator)
      .environment(areasMutator)
      .environment(projectsMutator)
      .environment(ckEngine)
      .environment(settingsStore)
      .environment(logCommit)
      .tint(AppearancePreferences.shared.accentSwiftUIColor)
      .preferredColorScheme(AppearancePreferences.shared.preferredColorScheme)
  }

  var body: some View {
    @Bindable var nav = nav
    return rootLayout
      // Same as RootTabView: resolve the push-vs-sheet rule once at the
      // shell root and publish `\.usesPushNavigation` to every surface.
      .resolvesAdaptiveNavigation()
      .doFlowSheets()
      // The app-global modals, one `.sheet(item:)` like RootTabView — the
      // subset with a Septask surface. The mood check-in and new-meal sheets
      // left with the Next page (2026-11-19). Anything else ever set shows
      // empty rather than crashing.
      .sheet(item: $nav.presentedModal) { modal in
        switch modal {
        case .quickFind:
          withEnvironment(QuickFindView())
            .septenaModalSheet(detents: [.medium, .large],
                               macWidth: 560, macHeight: 420)
        case .addInfo:
          // Septask's quick capture IS the task composer — no multi-section
          // palette here (the tasks-only twin of AddInfoSheet), whatever
          // section the request names.
          withEnvironment(SeptaskQuickAdd())
            .septenaModalSheet(detents: [.medium, .large],
                               macWidth: 560, macHeight: 520)
        case .keyboardShortcuts:
          withEnvironment(KeyboardShortcutsView())
            .septenaModalSheet(detents: [.medium, .large],
                               macWidth: 480, macHeight: 560)
        default:
          EmptyView()
        }
      }
      // Settings — mirrors RootTabView exactly: a sheet on iOS, a real
      // Settings window on macOS (traffic lights, ⌘W), opened by flipping
      // `nav.showSettings`. The window scene lives in SeptaskApp.
      #if os(iOS)
      .sheet(isPresented: $nav.showSettings) {
        withEnvironment(SeptaskSettingsView())
      }
      .fullScreenCover(isPresented: $showingFirstRun) {
        withEnvironment(SeptaskFirstRunView { showingFirstRun = false })
          .environment(\.modelContext, modelContext)
      }
      .task {
        await SeptaskFirstRunGate.resolve(settings: settingsStore)
        showingFirstRun = SeptaskFirstRunGate.shouldPresent(settings: settingsStore, context: modelContext)
      }
      // A cover cannot open over the Settings sheet, so a forced welcome
      // waits until Settings has closed.
      .onChange(of: welcomeForce) { _, forced in
        if forced, !nav.showSettings { showingFirstRun = true }
      }
      .onChange(of: nav.showSettings) { _, open in
        if !open, welcomeForce, !showingFirstRun { showingFirstRun = true }
      }
      #else
      .onChange(of: nav.showSettings) { _, open in
        guard open else { return }
        openWindow(id: "septask-settings")
        nav.showSettings = false
      }
      #endif
  }

  /// The lists, or the Do screen in their place (docs/DO_SPEC.md §4): no list
  /// is behind it, so no list command can run. A ZStack always exists, so the
  /// root's lifecycle modifiers do not run again when the two change places.
  private var rootLayout: some View {
    ZStack {
      if DoFlow.isAvailable, DoStore.shared.isFullHere, let doing = DoStore.shared.current {
        DoScreen(doing: doing)
          .id(doing.sessionID)
          .transition(.opacity)
      } else {
        lists
          .transition(.opacity)
      }
    }
    .a11yAnimation(.easeInOut(duration: 0.25), value: DoStore.shared.isFullHere)
  }

  @ViewBuilder
  private var lists: some View {
    #if os(iOS)
    if usesSplitLayout {
      ContentView()
    } else {
      compactStack
    }
    #else
    ContentView()
    #endif
  }

  #if os(iOS)
  /// Start a new task inline (never a modal sheet/drawer):
  /// - On Today, Upcoming, Project, Area, Anytime, or Inbox: opens the inline
  ///   composer right in the active list via `nav.requestNewTask()`.
  /// - On the list root (no list mounted) or read-only history smart lists:
  ///   opens Today (Inbox) and opens the inline composer there.
  private func triggerInlineNewTask() {
    Haptics.press()
    // Where the draft lands is the list's `newTaskTarget`
    // (registry/destinations.json): `here` and `tomorrow` create on this
    // list, `today` opens Today first. Project and area pages create here.
    let canCreateInPlace: Bool = {
      guard let last = nav.path.last else { return false }
      switch last {
      case .project, .area:
        return true
      case .filter(let filter):
        return (filter.registryDestination?.newTaskTarget ?? "today") != "today"
      default:
        return false
      }
    }()
    if !canCreateInPlace { nav.path = [.filter(.today)] }
    nav.requestNewTask()
  }

  /// The iPhone shell: `ContentView`'s compact `NavigationStack` (the
  /// sidebar list is its root) with the floating circular Magic Plus orb
  /// over the bottom-right corner (Things 3 style), so it stays behind the
  /// keyboard when typing inline.
  private var compactStack: some View {
    ZStack(alignment: .bottomTrailing) {
      ContentView()

      // An open task (inline editor or pushed page) hides the orb: it showed
      // through the editor. It fades with the push, not after it.
      let hideMagicPlus = nav.isTaskMultiSelectActive || SeptenaToastActivity.shared.hasActiveToast
        || keyboardVisible || nav.isTaskEditorOpen
      MagicPlusOrb(
        drag: magicPlusDrag,
        isViewingProject: isViewingProject,
        isViewingArea: isViewingArea,
        isViewingHome: isViewingHome,
        onNewTask: { triggerInlineNewTask() },
        onNewSection: { nav.shouldCreateHeading = true },
        onNewProject: { nav.shouldCreateProject = true },
        onNewArea: { nav.shouldCreateArea = true },
        onJoinShared: { SeptaskSharing.presentJoin() }
      )
      .padding(.trailing, 16)
      .padding(.bottom, 8)
      .opacity(hideMagicPlus ? 0 : 1)
      .allowsHitTesting(!hideMagicPlus)
      .a11yAnimation(.easeInOut(duration: 0.25), value: hideMagicPlus)

    }
    .environment(\.magicPlusDrag, magicPlusDrag)
    .onAppear {
      // An empty list root has no insert point: a drop there makes an Area.
      magicPlusDrag.fallbackDrop = {
        if nav.path.isEmpty { nav.shouldCreateArea = true } else { triggerInlineNewTask() }
      }
      // Open on Today, with the list root one Back away. The split layout
      // already falls back to Today when the path is empty (ContentView).
      if nav.path.isEmpty { nav.path = [.filter(.today)] }
    }
    .onChange(of: nav.path) { _, _ in
      if !magicPlusDrag.isDragging {
        magicPlusDrag.reset()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
      keyboardVisible = true
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
      keyboardVisible = false
    }
  }

  /// The list root (Tasks index). There the orb makes only Projects and
  /// Areas (decided 2026-11-23): the tap opens a two-row menu, and the drag
  /// drops a new Project or Area at the line.
  private var isViewingHome: Bool { nav.path.isEmpty }

  /// The orb only makes tasks on a list. On a project it also makes a
  /// section; on an area it also makes a project in that area; everywhere
  /// else the tap makes a task.
  private var isViewingProject: Bool {
    if case .project = nav.path.last { return true }
    return false
  }

  private var isViewingArea: Bool {
    if case .area = nav.path.last { return true }
    return false
  }
  #endif
}

/// Quick-add sheet: a fresh router per presentation so the draft never
/// leaks between opens. Sizing comes from the host's `septenaModalSheet`.
///
/// The SAME `AddTaskPage` Septena's quick-add palette shows, in its
/// self-hosted mode: Septena feeds the page's query from `AddInfoSheet`'s
/// search bar, which Septask doesn't compile, so here the page draws its own
/// focused title field plus Cancel / Add, and files to the Inbox. (Presenting
/// the page bare used to leave the sheet with no text field at all.)
private struct SeptaskQuickAdd: View {
  @State private var router = AddInfoRouter()

  var body: some View {
    NavigationStack {
      AddTaskPage(router: router, hostsTitleField: true, forcesInbox: true)
        .navigationTitle(RegistryActions.title(.appNewTask))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
  }
}
