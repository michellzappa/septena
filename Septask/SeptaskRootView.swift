import SwiftUI

/// Septask's top-level tabs (iPhone). Tasks hosts the full sidebar module —
/// same label and checkmark as Septena's Tasks tab, so the ✓ means "the task
/// module" in both apps; Today and Upcoming are first-class destinations.
/// Quick capture lives in the separate floating Magic Plus orb (`magicPlusOrb`)
/// bottom-trailing above the tab bar — tap starts an inline task in place, and
/// hold-and-drag drops a new inline task onto any row gap, heading, group,
/// Upcoming day, or Tasks destination. Search lives in the trailing nav bar.
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
  @State private var selection: SeptaskTab = .today
  @AppStorage("septena.magicPlusDragHintSeen") private var magicPlusDragHintSeen = false
  @Namespace private var tabBubble
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
  /// User tap on a bottom tab item:
  /// - Tapping `Tasks` (switching from Today/Upcoming or re-tapping Tasks)
  ///   always clears `nav.path` so Tasks lands at its top-level index.
  /// - Switching to Today or Upcoming clears any stale Tasks stack route.
  ///
  /// Programmatic navigation (e.g. tapping a project from Quick Find or a task
  /// row) sets `selection = .tasks` directly in `.onChange(of: nav.path)` so
  /// the pushed route is preserved.
  private func selectTab(_ tapped: SeptaskTab) {
    Haptics.tap()
    if !nav.path.isEmpty {
      nav.path = []
    }
    if selection != tapped {
      a11yAnimate(.snappy(duration: 0.24)) {
        selection = tapped
      }
    }
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

  /// Compact iPhone root: active tab full-screen with bottom scroll clearance,
  /// paired with a single bottom row — Liquid Glass 3-tab pill aligned leftmost
  /// and the separate draggable Magic Plus orb at the exact same height on the
  /// bottom-right.
  private var systemTabView: some View {
    ZStack(alignment: .bottom) {
      activeTabContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaPadding(.bottom, 76)

      VStack(alignment: .trailing, spacing: 10) {
        if !magicPlusDragHintSeen {
          magicPlusDragHint
        }
        HStack(alignment: .center, spacing: 12) {
          bottomTabPill
          Spacer(minLength: 0)
          magicPlusOrb
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 21)
      .ignoresSafeArea(.all, edges: .bottom)
    }
  }

  @ViewBuilder
  private var activeTabContent: some View {
    switch selection {
    case .tasks:
      ContentView()
    case .today:
      NavigationStack { TaskListView(filter: .today) }.tint(theme.accent)
    case .upcoming:
      NavigationStack { TaskListView(filter: .upcoming) }.tint(theme.accent)
    }
  }

  private var bottomTabItems: [(tab: SeptaskTab, title: String, icon: String)] {
    [
      (.tasks, "Tasks", "checkmark"),
      (.today, "Today", "sun.max.fill"),
      (.upcoming, "Upcoming", "calendar"),
    ]
  }

  /// Left-aligned Liquid Glass 3-tab pill matching iOS 26 tab-bar proportions
  /// and height (`60pt`) alongside the bottom-right Magic Plus orb.
  private var bottomTabPill: some View {
    GlassEffectContainer {
      HStack(spacing: 2) {
        ForEach(bottomTabItems, id: \.tab) { item in
          let isActive = selection == item.tab
          Button {
            selectTab(item.tab)
          } label: {
            VStack(spacing: 2) {
              Image(systemName: item.icon)
                .scaledFont(size: 18, weight: .semibold)
              Text(item.title)
                .scaledFont(size: 10, weight: .medium)
                .lineLimit(1)
            }
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .frame(minWidth: 74, maxHeight: .infinity)
            .padding(.horizontal, 6)
            .background {
              if isActive {
                Capsule()
                  .fill(Color.primary.opacity(0.11))
                  .matchedGeometryEffect(id: "septask-tab-pill", in: tabBubble)
              }
            }
            .contentShape(Capsule())
          }
          .buttonStyle(.plain)
          .glassEffectID(item.tab, in: tabBubble)
        }
      }
      .padding(4)
      .frame(height: 60)
      .glassSegmentTrack()
    }
  }

  /// One-time subtle coach pill above Magic Plus so users discover press-and-
  /// drag placement without cluttering the chrome permanently. Dismisses on tap
  /// or automatically after the first Magic Plus drag-and-drop.
  private var magicPlusDragHint: some View {
    Button {
      a11yAnimate(.easeOut(duration: 0.2)) {
        magicPlusDragHintSeen = true
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "hand.point.up.left.and.text")
          .scaledFont(size: 11, weight: .medium)
        Text("Hold & drag + to place")
          .font(.septenaCaption)
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .contentShape(Capsule())
      .glassCapsule()
    }
    .buttonStyle(.plain)
    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
  }

  /// Separate floating Magic Plus orb anchored in the detached bottom-right
  /// tab-bar slot:
  /// - Solid accent orb + subtle 6-dot grip beneath `+` communicates a
  ///   grabbable object rather than a flat tap-only tab icon.
  /// - Tap: starts a new inline task in the active list (never a modal/drawer).
  /// - Hold & drag: carries `TaskDragIDs.newTask` through native iOS drag and
  ///   drop into any `TaskReorderDrop`, `TaskMoveDrop`, or `SidebarTaskDrop`.
  private var magicPlusOrb: some View {
    Button {
      triggerInlineNewTask()
    } label: {
      ZStack {
        Circle()
          .fill(Color.accentColor.gradient)
          .overlay(
            Circle()
              .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
          )
          .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        VStack(spacing: 4) {
          Image(systemName: "plus")
            .scaledFont(size: 21, weight: .bold)
            .foregroundStyle(Color.white)
          magicPlusGripDots
        }
        .offset(y: 2)
      }
      .frame(width: 60, height: 60)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .contentShape(.dragPreview, Circle())
    .accessibilityLabel("New Task")
    .accessibilityHint("Tap to add a task inline, or hold and drag onto a list position.")
    .draggable(TaskDragIDs.newTask) {
      ZStack {
        Circle()
          .fill(Color.accentColor.gradient)
          .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        Image(systemName: "plus")
          .scaledFont(size: 22, weight: .bold)
          .foregroundStyle(Color.white)
      }
      .frame(width: 56, height: 56)
      .contentShape(.dragPreview, Circle())
    }
  }

  /// Subtle 3×2 tactile grip dots under `+` signaling the orb can be dragged.
  private var magicPlusGripDots: some View {
    VStack(spacing: 2.5) {
      ForEach(0..<2, id: \.self) { _ in
        HStack(spacing: 3) {
          ForEach(0..<3, id: \.self) { _ in
            Circle()
              .fill(Color.white.opacity(0.55))
              .frame(width: 2.5, height: 2.5)
          }
        }
      }
    }
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
        .navigationTitle("New Task")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
  }
}
