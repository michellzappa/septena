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
      .alert(RegistryPrompts.textPrompt("newArea").title, isPresented: $showingNewAreaAlert) {
        TextField(RegistryPrompts.textPrompt("newArea").placeholder, text: $newAreaName)
        Button(RegistryPrompts.textPrompt("newArea").confirmTitle) { createArea() }
        Button(RegistryPrompts.cancelTitle, role: .cancel) { newAreaName = "" }
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
        compactStack
      }
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

      let hideMagicPlus = nav.isTaskMultiSelectActive || SeptenaToastActivity.shared.hasActiveToast
        || keyboardVisible
      MagicPlusOrb(
        drag: magicPlusDrag,
        isViewingProject: isViewingProject,
        isViewingToday: isViewingToday,
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
      .padding(.bottom, 8)
      .opacity(hideMagicPlus ? 0 : 1)
      .allowsHitTesting(!hideMagicPlus)
      .a11yAnimation(.snappy(duration: 0.2), value: hideMagicPlus)

      MagicPlusFloatingOverlay(drag: magicPlusDrag)
    }
    .environment(\.magicPlusDrag, magicPlusDrag)
    .onAppear {
      magicPlusDrag.fallbackDrop = { triggerInlineNewTask() }
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

  /// Today never creates areas or projects, so the orb's tap there makes a
  /// task directly instead of opening the create menu.
  private var isViewingToday: Bool {
    if case .filter(.today) = nav.path.last { return true }
    return false
  }

  private var isViewingProject: Bool {
    if case .project = nav.path.last { return true }
    return false
  }

  private var activeAreaIdForNewProject: String? {
    if case .area(let id) = nav.path.last { return id }
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
/// Separate floating circular Magic Plus orb anchored at the bottom-right of
/// the iPhone navigation stack:
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
  /// Finger-down state: the orb sinks while touched, so the press reads as
  /// received before the tap even ends.
  @GestureState private var isPressed = false
  /// Bumped on each tap: drives the release pop (grow, then settle back).
  @State private var popTick = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let isViewingProject: Bool
  let isViewingToday: Bool
  let onNewTask: () -> Void
  let onNewSection: () -> Void
  let onNewProject: () -> Void
  let onNewArea: () -> Void

  var body: some View {
    let appearance = AppearancePreferences.shared
    let accent = appearance.magicPlusSwiftUIColor
    let ink = appearance.magicPlusInkSwiftUIColor

    // Keep both the resting "+" orb and the cancel socket inside one stable
    // ZStack (toggling opacity/scale, never swapping container identity) so
    // SwiftUI's active DragGesture never drops mid-drag.
    ZStack {
      // Resting "+" orb — hidden completely while dragging. Renders in the
      // brand Persimmon under Colorful, else the user's fruit accent
      // (`AppearancePreferences.magicPlusSwiftUIColor`), never per-section.
      ZStack {
        Circle()
          .fill(accent.gradient)
          .overlay(
            Circle()
              .strokeBorder(ink.opacity(0.22), lineWidth: 0.75)
          )
          .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        VStack(spacing: 4) {
          Image(systemName: "plus")
            .scaledFont(size: 21, weight: .bold)
            .foregroundStyle(ink)
          gripDots(ink: ink)
        }
        .offset(y: 2)
      }
      .scaleEffect(isPressed && !drag.isDragging ? 0.88 : 1)
      .a11yAnimation(.spring(response: 0.22, dampingFraction: 0.6), value: isPressed)
      // Release pop: overshoot past rest, then spring back. Reduce Motion never
      // bumps `popTick`, so the keyframes never play there.
      .keyframeAnimator(initialValue: CGFloat(1), trigger: popTick) { content, scale in
        content.scaleEffect(scale)
      } keyframes: { _ in
        SpringKeyframe(1.14, duration: 0.12, spring: .snappy)
        SpringKeyframe(1, duration: 0.32, spring: .bouncy)
      }
      .opacity(drag.isDragging ? 0 : 1)
      .scaleEffect(drag.isDragging ? 0.75 : 1)

      // Cancel drop socket — appears in the bottom-right spot during drag so
      // dragging back here unmistakably cancels the action.
      // Plain glass, like the toolbar circles: no dashed ring (decided
      // 2026-11-23). It turns red glass while the finger is over it.
      ZStack {
        Color.clear
        Image(systemName: "xmark")
          .scaledFont(size: 18, weight: .semibold)
          .foregroundStyle(drag.isOverCancelSocket ? Color.red : Color.secondary)
      }
      .glassCircle(tint: drag.isOverCancelSocket ? .red : nil)
      .opacity(drag.isDragging ? 1 : 0)
      .scaleEffect(drag.isDragging ? (drag.isOverCancelSocket ? 1.08 : 0.94) : 0.75)
    }
    .frame(width: 58, height: 58)
    .contentShape(Circle())
    .a11yAnimation(.snappy(duration: 0.2), value: drag.isDragging)
    .a11yAnimation(.snappy(duration: 0.18), value: drag.isOverCancelSocket)
    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
      drag.homeCenter = CGPoint(x: rect.midX, y: rect.midY)
    }
    .onTapGesture {
      guard !drag.isDragging else { return }
      Haptics.press()
      if !reduceMotion { popTick += 1 }
      if isViewingToday { onNewTask() } else { showingMenu = true }
    }
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .updating($isPressed) { _, pressed, _ in pressed = true }
    )
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
    .accessibilityHint(isViewingToday
      ? Text("Tap for a new task, or drag onto a list position.")
      : Text("Tap for create options, or drag onto a list position."))
    .popover(isPresented: $showingMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
      quickMenu
        .presentationCompactAdaptation(.popover)
    }
  }

  /// Subtle 3×2 tactile grip dots beneath `+` signaling the orb can be dragged.
  private func gripDots(ink: Color) -> some View {
    VStack(spacing: 2.5) {
      ForEach(0..<2, id: \.self) { _ in
        HStack(spacing: 3) {
          ForEach(0..<3, id: \.self) { _ in
            Circle()
              .fill(ink.opacity(0.55))
              .frame(width: 2.5, height: 2.5)
          }
        }
      }
    }
    .accessibilityHidden(true)
  }

  private var quickMenu: some View {
    VStack(alignment: .leading, spacing: 2) {
      menuRow(title: RegistryActions.title("app.newTask"), icon: "checkmark.circle") {
        showingMenu = false
        onNewTask()
      }
      if isViewingProject {
        menuRow(title: RegistryActions.title("section.new"), icon: "rectangle.split.1x2") {
          showingMenu = false
          onNewSection()
        }
      }
      Divider()
        .padding(.vertical, 4)
      menuRow(title: RegistryActions.title("sidebar.newProject"), icon: "number") {
        showingMenu = false
        onNewProject()
      }
      menuRow(title: RegistryActions.title("sidebar.newArea"), icon: "square.stack.3d.up") {
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
          .foregroundStyle(AppearancePreferences.shared.accentSwiftUIColor)
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
        .navigationTitle(RegistryActions.title("app.newTask"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
  }
}
