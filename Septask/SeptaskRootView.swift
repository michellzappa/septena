import SwiftUI

/// Septask's top-level tabs (iPhone). Tasks hosts the full sidebar module —
/// same label and checkmark as Septena's Tasks tab, so the ✓ means "the task
/// module" in both apps; Today and Upcoming are first-class destinations.
/// Quick capture lives in the separate floating circular Magic Plus orb
/// (`MagicPlusOrb`) anchored just above the bottom-right edge of the tab bar:
/// tap opens the create quick menu, and hold-and-drag drops a new inline task
/// onto any row gap, heading, group, or Upcoming day — or creates a Project/Area
/// on the Tasks page. Search lives in the trailing nav bar.
///
/// Septask has no Next page (removed 2026-11-19: it showed life-OS content,
/// not tasks; Today covers "what's next" for tasks).
enum SeptaskTab: Hashable {
  case tasks, today, upcoming
}

/// Septask's root, mirroring `RootTabView`'s shell shape: the standard
/// system `TabView` on iPhone (bottom bar, Music-style minimize on scroll),
/// and NO tab bar on iPad regular / macOS — there the split-view sidebar is
/// the switcher, which is the norm (Septena's iPad segmented switcher is a
/// full-app exception, deliberately not copied). Composition only: every
/// tab hosts shared views unchanged.
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
  @State private var selection: SeptaskTab = .today
  @State private var magicPlusDrag = MagicPlusDragState()
  @State private var showingNewProjectSheet = false
  @State private var newProjectInitialAreaId: String? = nil
  @State private var showingNewAreaAlert = false
  @State private var newAreaName = ""
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
      .sheet(isPresented: $showingNewProjectSheet, onDismiss: { newProjectInitialAreaId = nil }) {
        let areas = StructureCache.snapshot(in: modelContext).areas
        withEnvironment(
          NewProjectSheet(areas: areas,
                          initialAreaId: newProjectInitialAreaId) { title, areaId in
            createProject(title: title, areaId: areaId)
          }
        )
        .presentationDetents([.medium])
        .septenaSheetChrome()
      }
      .alert("New Area", isPresented: $showingNewAreaAlert) {
        TextField("Area name", text: $newAreaName)
        Button("Create") { createArea() }
        Button("Cancel", role: .cancel) { newAreaName = "" }
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

  @ViewBuilder
  private var rootLayout: some View {
    #if os(iOS)
    Group {
      if usesSplitLayout {
        ContentView()
      } else {
        systemTabView
      }
    }
    // Fold / unfold continuity (iPhone Duo) and iPad multitasking resize:
    // preserve the exact surface the user is viewing across the TabView ↔
    // NavigationSplitView boundary instead of snapping back to Today.
    .onChange(of: usesSplitLayout) { _, isSplit in
      syncRouteAcrossLayoutTransition(toSplit: isSplit)
    }
    // Shared task views navigate through the ONE NavigationState path
    // (project drill-ins, smart-list jumps); ContentView's stack renders it
    // on the Tasks tab. A route landing while a filter tab is frontmost
    // must move selection — the tab-bar twin of RootTabView's pendingTab
    // forwarding.
    //
    // Today and Upcoming ARE tabs, so a route to either switches to that tab
    // and is then dropped from the shared path. Leaving it there also pushed a
    // second copy of the list inside the Tasks tab: back on Tasks you landed in
    // a duplicate Today instead of the Tasks home, and that hidden copy could
    // consume a search reveal meant for the tab you were looking at.
    .onChange(of: nav.path) { _, path in
      guard !usesSplitLayout, let last = path.last else { return }
      switch last {
      case .filter(.today):
        selection = .today
        nav.path = []
      case .filter(.upcoming):
        selection = .upcoming
        nav.path = []
      default:
        selection = .tasks
      }
    }
    #else
    ContentView()
    #endif
  }

  #if os(iOS)
  /// Keep the user's active view aligned when crossing compact ↔ split
  /// (folding/unfolding iPhone Duo or resizing an iPad window).
  private func syncRouteAcrossLayoutTransition(toSplit: Bool) {
    if toSplit {
      switch selection {
      case .today:
        nav.path = [.filter(.today)]
      case .upcoming:
        nav.path = [.filter(.upcoming)]
      case .tasks:
        if nav.path.isEmpty { nav.path = [.filter(.today)] }
      }
    } else {
      switch nav.path.last {
      case .filter(.today):
        selection = .today
        nav.path = []
      case .filter(.upcoming):
        selection = .upcoming
        nav.path = []
      case .some:
        selection = .tasks
      case nil:
        break
      }
    }
  }
  #endif

  #if os(iOS)
  /// User tab-bar selection bridge:
  /// - Tapping `Tasks` (switching from Today/Upcoming or re-tapping Tasks)
  ///   always clears `nav.path` so Tasks lands at its top-level index.
  /// - Switching to Today or Upcoming clears any stale Tasks stack route.
  ///
  /// Programmatic navigation (e.g. tapping a project from Quick Find or a task
  /// row) sets `selection = .tasks` directly in `.onChange(of: nav.path)` and
  /// bypasses this setter so the pushed route is preserved.
  private var tabSelection: Binding<SeptaskTab> {
    Binding(
      get: { selection },
      set: { tapped in
        magicPlusDrag.reset()
        if !nav.path.isEmpty {
          nav.path = []
        }
        selection = tapped
      }
    )
  }

  /// Start a new task inline (never a modal sheet/drawer):
  /// - On Today, Upcoming, Project, Area, Anytime, or Inbox: opens the inline
  ///   composer right in the active list via `nav.requestNewTask()`.
  /// - On the Tasks index (no list mounted) or read-only history smart lists:
  ///   switches to Today (Inbox) and opens the inline composer there.
  private func triggerInlineNewTask() {
    Haptics.tap()
    if selection == .tasks {
      let canCreateInPlace: Bool = {
        guard let last = nav.path.last else { return false }
        switch last {
        case .project, .area, .filter(.unscheduled), .filter(.triage),
             .filter(.today), .filter(.upcoming):
          return true
        default:
          return false
        }
      }()
      if !canCreateInPlace {
        if !nav.path.isEmpty { nav.path = [] }
        selection = .today
      }
    }
    nav.requestNewTask()
  }

  /// Real iOS 26 3-tab `TabView` (`Tasks`, `Today`, `Upcoming`) with system
  /// scroll minimization, paired with a separate floating circular Magic Plus
  /// orb anchored just above the bottom-right edge of the tab bar (Things 3
  /// style) so it stays behind the keyboard when typing inline.
  private var systemTabView: some View {
    ZStack(alignment: .bottomTrailing) {
      TabView(selection: tabSelection) {
        // Septask has no section colors: the bar, the tabs and their content
        // all take the platform accent (no `.tint` on the TabView).
        Tab("Tasks", systemImage: "checkmark", value: SeptaskTab.tasks) {
          ContentView()
        }
        Tab("Today", systemImage: "sun.max.fill", value: SeptaskTab.today) {
          NavigationStack { TaskListView(filter: .today) }.tint(theme.accent)
        }
        Tab("Upcoming", systemImage: "calendar", value: SeptaskTab.upcoming) {
          NavigationStack { TaskListView(filter: .upcoming) }.tint(theme.accent)
        }
      }
      .tabBarMinimizeBehavior(.onScrollDown)

      MagicPlusOrb(
        drag: magicPlusDrag,
        isViewingProject: isViewingProject,
        onNewTask: { triggerInlineNewTask() },
        onNewSection: { nav.shouldCreateHeading = true },
        onNewProject: {
          newProjectInitialAreaId = activeAreaIdForNewProject
          showingNewProjectSheet = true
        },
        onNewArea: {
          newAreaName = ""
          showingNewAreaAlert = true
        }
      )
      .padding(.trailing, 16)
      .padding(.bottom, 92)
      .ignoresSafeArea(.all, edges: .bottom)
      .opacity(nav.isTaskMultiSelectActive ? 0 : 1)
      .allowsHitTesting(!nav.isTaskMultiSelectActive)
      .a11yAnimation(.snappy(duration: 0.2), value: nav.isTaskMultiSelectActive)

      MagicPlusFloatingOverlay(drag: magicPlusDrag)
    }
    .environment(\.magicPlusDrag, magicPlusDrag)
    .onChange(of: nav.path) { _, _ in
      if !magicPlusDrag.isDragging {
        magicPlusDrag.reset()
      }
    }
  }

  private var isViewingProject: Bool {
    if selection == .tasks, case .project = nav.path.last { return true }
    return false
  }

  private var activeAreaIdForNewProject: String? {
    if selection == .tasks, case .area(let id) = nav.path.last { return id }
    return nil
  }

  private func createProject(title: String, areaId: String?) {
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    Task {
      _ = try? await projectsMutator.create(title: trimmed, area: areaId)
    }
  }

  private func createArea() {
    let name = newAreaName.trimmingCharacters(in: .whitespaces)
    newAreaName = ""
    guard !name.isEmpty else { return }
    Task {
      _ = try? await areasMutator.create(title: name)
    }
  }
  #endif
}

#if os(iOS)
/// Separate floating circular Magic Plus orb anchored above bottom-right of
/// the real iOS 26 `TabView`:
/// - Solid accent circle + subtle 6-dot grip beneath `+` communicates a
///   grabbable object rather than a flat tap-only tab icon.
/// - Tap opens a native popover quick menu (`New Task` inline, `New Section`
///   in projects, `New Project`, `New Area`).
/// - Instant drag (no hold delay) detaches the orb to follow the finger 1:1
///   and morphs live into a ghost task card or contextual action pill over
///   every row gap, heading, Today/Anytime group, Upcoming day, or Tasks
///   index Area/Project drop zone.
private struct MagicPlusOrb: View {
  let drag: MagicPlusDragState
  @State private var showingMenu = false

  let isViewingProject: Bool
  let onNewTask: () -> Void
  let onNewSection: () -> Void
  let onNewProject: () -> Void
  let onNewArea: () -> Void

  var body: some View {
    ZStack {
      Circle()
        .fill(Theme.selectionAccent.gradient)
        .overlay(
          Circle()
            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(drag.isDragging ? 0.08 : 0.28), radius: 10, y: 4)
      VStack(spacing: 4) {
        Image(systemName: "plus")
          .scaledFont(size: 21, weight: .bold)
          .foregroundStyle(Theme.checkboxCheck)
        gripDots
      }
      .offset(y: 2)
    }
    .frame(width: 58, height: 58)
    .contentShape(Circle())
    .opacity(drag.isDragging ? 0.22 : 1)
    .scaleEffect(drag.isDragging ? 0.86 : 1)
    .a11yAnimation(.snappy(duration: 0.2), value: drag.isDragging)
    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
      drag.homeCenter = CGPoint(x: rect.midX, y: rect.midY)
    }
    .onTapGesture {
      guard !drag.isDragging else { return }
      Haptics.tap()
      showingMenu = true
    }
    .simultaneousGesture(
      DragGesture(minimumDistance: 8, coordinateSpace: .global)
        .onChanged { value in
          if !drag.isDragging {
            showingMenu = false
            drag.beginDrag(at: value.location)
          } else {
            drag.updateDrag(at: value.location)
          }
        }
        .onEnded { value in
          drag.endDrag(at: value.location)
        }
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel("New")
    .accessibilityHint("Tap for create options, or drag onto a list position.")
    .popover(isPresented: $showingMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
      quickMenu
        .presentationCompactAdaptation(.popover)
    }
  }

  /// Subtle 3×2 tactile grip dots beneath `+` signaling the orb can be dragged.
  private var gripDots: some View {
    VStack(spacing: 2.5) {
      ForEach(0..<2, id: \.self) { _ in
        HStack(spacing: 3) {
          ForEach(0..<3, id: \.self) { _ in
            Circle()
              .fill(Theme.checkboxCheck.opacity(0.55))
              .frame(width: 2.5, height: 2.5)
          }
        }
      }
    }
    .accessibilityHidden(true)
  }

  private var quickMenu: some View {
    VStack(alignment: .leading, spacing: 2) {
      menuRow(title: "New Task", icon: "checkmark.circle") {
        showingMenu = false
        onNewTask()
      }
      if isViewingProject {
        menuRow(title: "New Section", icon: "rectangle.split.1x2") {
          showingMenu = false
          onNewSection()
        }
      }
      Divider()
        .padding(.vertical, 4)
      menuRow(title: "New Project", icon: "number") {
        showingMenu = false
        onNewProject()
      }
      menuRow(title: "New Area", icon: "square.stack.3d.up") {
        showingMenu = false
        onNewArea()
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 6)
    .frame(minWidth: 196)
  }

  private func menuRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .scaledFont(size: 16, weight: .medium)
          .foregroundStyle(Color.accentColor)
          .frame(width: 22)
        Text(title)
          .font(.septenaSidebarRow)
          .foregroundStyle(.primary)
        Spacer(minLength: 8)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
#endif

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
        .navigationTitle("New Task")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
  }
}
