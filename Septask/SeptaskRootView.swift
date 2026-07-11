import SwiftUI

/// Septask's top-level tabs (iPhone). Tasks hosts the full sidebar module —
/// same label and checkmark as Septena's Tasks tab, so the ✓ means "the task
/// module" in both apps; Today and Upcoming are first-class smart-list tabs;
/// the trailing `+` is an action, not a destination — it presents quick-add
/// and selection never actually moves to it.
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
  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var hSize
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
      // subset with a Septask surface. The embedded Next fold (Today's foot)
      // added two: the mood check-in and the nutrition new-meal sheet, both
      // suggestion destinations. Training stays out (its destination is the
      // live-session surface Septask doesn't compile — the fold filters that
      // suggestion). Anything else ever set shows empty rather than crashing.
      .sheet(item: $nav.presentedModal) { modal in
        switch modal {
        case .quickFind:
          withEnvironment(QuickFindView())
            .septenaModalSheet(detents: [.medium, .large],
                               macWidth: 560, macHeight: 420)
        case .addInfo(let section):
          // Septask's quick capture IS the task composer — no multi-section
          // palette here (the tasks-only twin of AddInfoSheet). The one
          // exception: the Next fold's fast-break suggestion targets
          // nutrition, which opens the new-meal sheet directly.
          if section == .nutrition {
            withEnvironment(NewNutritionEntrySheet())
              .septenaModalSheet(macWidth: 560, macHeight: 600)
          } else {
            withEnvironment(SeptaskQuickAdd())
              .septenaModalSheet(detents: [.medium, .large],
                                 macWidth: 560, macHeight: 520)
          }
        case .moodCheckin:
          // The Next fold's mood suggestion — same check-in page as
          // Septena's tab root (RootTabView.modalSheet).
          withEnvironment(AddMoodPage(anchorTime: dayClock.now, date: dayClock.today))
            .septenaModalSheet(macWidth: 560, macHeight: 600)
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
      if hSize == .compact {
        systemTabView
      } else {
        ContentView()
      }
    }
    // Shared task views navigate through the ONE NavigationState path
    // (project drill-ins, smart-list jumps); ContentView's stack renders it
    // on the Tasks tab. A route landing while a filter tab is frontmost
    // must move selection — the tab-bar twin of RootTabView's pendingTab
    // forwarding.
    .onChange(of: nav.path) { _, path in
      guard hSize == .compact, let last = path.last else { return }
      switch last {
      case .filter(.today):    selection = .today
      case .filter(.upcoming): selection = .upcoming
      default:                 selection = .tasks
      }
    }
    #else
    ContentView()
    #endif
  }

  #if os(iOS)
  /// The three navigation destinations remain a real `TabView`, but its
  /// system bar is replaced with a compact glass cluster plus a detached,
  /// circular quick-add button. This keeps the `+` visually and semantically
  /// separate from navigation.
  private var systemTabView: some View {
    TabView(selection: $selection) {
      // ContentView self-tints to `theme.accent` (ink), so the Tasks tab's
      // chrome/content stays black; the reset on Today/Upcoming does the same
      // for the tabs that don't host ContentView. Only the bar's SELECTED item
      // picks up the Tasks color, from the `.tint` on the TabView below.
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
    .toolbar(.hidden, for: .tabBar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SeptaskFloatingTabBar(selection: $selection, tint: theme.color(for: "tasks")) {
        // Use the shared modal state so the floating `+`, ⌘K, and any future
        // entry point all present the same task composer.
        nav.presentAddInfo(section: .tasks)
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 8)
    }
  }
  #endif
}

#if os(iOS)
/// Septask's iPhone tab control: a navigation capsule and a deliberately
/// separate circular floating action button. The split makes the create action
/// read as an action rather than a fourth destination.
private struct SeptaskFloatingTabBar: View {
  @Binding var selection: SeptaskTab
  let tint: Color
  let addTask: () -> Void
  @Namespace private var selectionBubble

  private let tabs: [(tab: SeptaskTab, title: String, systemImage: String)] = [
    (.tasks, "Tasks", "checkmark"),
    (.today, "Today", "sun.max.fill"),
    (.upcoming, "Upcoming", "calendar")
  ]

  var body: some View {
    GlassEffectContainer {
      HStack(spacing: 10) {
        HStack(spacing: 2) {
          ForEach(tabs, id: \.tab) { tab in
            tabButton(tab)
          }
        }
        .padding(4)
        .glassSegmentTrack()

        Button(action: addTask) {
          Image(systemName: "plus")
            .font(.body.weight(.bold))
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .glassCircle(tint: tint)
        .accessibilityLabel("New To-Do")
        .accessibilityHint("Creates a new task")
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func tabButton(_ tab: (tab: SeptaskTab, title: String, systemImage: String)) -> some View {
    let isSelected = selection == tab.tab
    return Button {
      guard !isSelected else { return }
      withAnimation(.snappy(duration: 0.28)) {
        selection = tab.tab
      }
    } label: {
      VStack(spacing: 2) {
        Image(systemName: tab.systemImage)
          .font(.caption.weight(.semibold))
        Text(tab.title)
          .font(.caption2.weight(.medium))
          .lineLimit(1)
      }
      .frame(minWidth: 62, minHeight: 48)
      .foregroundStyle(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
      .glassSegmentSelectionUnderlay(
        isSelected: isSelected,
        tint: tint,
        in: selectionBubble,
        id: "septaskFloatingTabSelection"
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tab.title)
    .accessibilityIdentifier("septask.tab.\(tab.tab)")
    .accessibilityValue(isSelected ? "Selected" : "")
    .glassEffectID(tab.tab, in: selectionBubble)
  }
}
#endif

/// Quick-add sheet: a fresh router per presentation so the draft never
/// leaks between opens. Sizing comes from the host's `septenaModalSheet`.
private struct SeptaskQuickAdd: View {
  @State private var router = AddInfoRouter()

  var body: some View {
    AddTaskPage(router: router)
  }
}
