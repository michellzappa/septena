import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// compact homepage on iPhone: the root screen IS the sidebar.
// QuickFind + smart lists + areas/projects + Settings. See docs/reference/navigation.md.

/// Process-wide memo of the sidebar's last task aggregate. SwiftUI re-runs
/// `SidebarRootView.init` on every parent render and discards the
/// State(initialValue:) values for installed views — without this memo each
/// of those constructions re-scanned the full task table for nothing. The
/// first construction per process computes it; `load()` keeps it fresh.
@MainActor
private enum SidebarSeed {
  static var aggregate: SidebarRootView.Aggregate?
}

struct SidebarRootView: View {
  @Environment(NavigationState.self) private var nav
  @Environment(AreasMutator.self) private var areasMutator
  @Environment(ProjectsMutator.self) private var projectsMutator
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(\.modelContext) private var modelContext
  @Environment(DayClock.self) private var clock
  /// Push-navigation surface (iPad regular / macOS) vs. compact stack (iPhone /
  /// slide-over) — the single rule, resolved at the app root, that decides
  /// whether the sidebar drives a persistent detail pane. Selection is native
  /// (`List(selection:)`) on push surfaces and Button-driven on compact ones.
  @Environment(\.usesPushNavigation) private var usesPushNavigation

  @State private var areas: [Area]
  @State private var projects: [Project]
  @State private var counts: TasksCounts? = nil
  /// Tasks completed today — drives the Logbook tile/row count.
  @State private var doneTodayCount: Int = 0
  @State private var reviewCount: Int = 0
  @State private var agentCount: Int = 0
  @State private var starredCount: Int = 0
  @State private var fadedCount: Int = 0
  @State private var recentlyDeletedCount: Int = 0
  /// Repeating badge. Filled by `load()` from the roll-up pass; `body` used
  /// to fetch the list on every render.
  @State private var repeatingCount: Int = 0

  // Sidebar order is now the synced `position` field (docs/DRAG_AND_DROP.md §5):
  // Move Up/Down renumbers via areas/projects mutators; the legacy device-local
  // `sidebar.*Order` UserDefaults keys survive only as NavigationState's
  // pre-sync upgrade fallback, so nothing here reads/writes them anymore.
  /// Areas the user has folded shut (Things-style) — their projects are
  /// hidden until re-expanded. Stored as a JSON id set; only areas that
  /// actually have projects ever show the fold control.
  @AppStorage("sidebar.collapsedAreas") private var collapsedAreasData: Data = Data()

  // Seed sidebar lists from cache before first render so the sidebar isn't
  // ever blank — areas/projects barely change, so this is effectively the
  // final answer almost every time.
  //
  // Seeding goes through process-wide memos (StructureCache + SidebarSeed):
  // SwiftUI re-runs this init on every parent render and discards the
  // State(initialValue:) values for installed views, so computing a full
  // task-table aggregate here made every nav click pay for a scan nobody
  // used. Only the first construction per process computes; `load()` keeps
  // the seed fresh afterwards.
  init() {
    let ctx = LocalStore.shared.container.mainContext
    let structure = StructureCache.snapshot(in: ctx)
    _areas = State(initialValue: structure.areas)
    _projects = State(initialValue: structure.projects)
    let agg = SidebarSeed.aggregate ?? {
      let token = StoreHealth.readToken()
      let stats = TaskReads.dashboardStats(today: SeptenaDate.today,
                                           now: Date(),
                                           context: ctx)
      var agg = Self.aggregate(tasks: LocalCache.liveAggregateEntities(in: ctx), today: SeptenaDate.today)
      agg.counts = stats.counts
      agg.doneTodayCount = stats.history.daily.last?.done ?? 0
      // Only memoize a pass in which every read succeeded — see `load()`. A
      // failed pass paints this frame from empty values, then `load()` fixes
      // it; memoizing it would make the zeros permanent.
      if !StoreHealth.readsFailed(since: token) { SidebarSeed.aggregate = agg }
      return agg
    }()
    _counts = State(initialValue: agg.counts)
    _doneTodayCount = State(initialValue: agg.doneTodayCount)
    _projectProgress = State(initialValue: agg.projectProgress)
    _starredCount = State(initialValue: agg.starredCount)
    _fadedCount = State(initialValue: agg.fadedCount)
    _reviewCount = State(initialValue: agg.reviewCount)
    _agentCount = State(initialValue: agg.agentCount)
    _repeatingCount = State(initialValue: agg.repeatingCount)
    _projectOpenCount = State(initialValue: agg.projectOpenCount)
    _areaOpenCount = State(initialValue: agg.areaOpenCount)
  }
  /// Fraction of each project's tasks that are done (0...1). Drives the
  /// circular progress icon in SidebarProjectRow.
  @State private var projectProgress: [String: Double] = [:]
  /// Open task count per project — drives the muted gray count on each
  /// SidebarProjectRow.
  @State private var projectOpenCount: [String: Int] = [:]
  /// Open task count per area, rolling up loose-in-area + tasks in that
  /// area's projects.
  @State private var areaOpenCount: [String: Int] = [:]
  @State private var errorMessage: String?

  /// Magic Plus on the homepage offers task / project / area creation.
  @State private var showingCreateMenu = false
  @State private var showingNewProject = false
  @State private var showingNewArea = false
  @State private var newAreaName = ""

  /// Right-click → Rename. One pair of state per kind keeps the alert
  /// presentation simple (alert(isPresented:) reads `target != nil`).
  @State private var renameProjectTarget: Project?
  @State private var renameAreaTarget: Area?
  @State private var renameDraft = ""

  /// Right-click → Delete (confirm before mutating).
  @State private var deleteProjectTarget: Project?
  @State private var deleteAreaTarget: Area?

  /// Right-click on an area → "New Project here". Pre-selects the area so the
  /// existing NewProjectSheet shows it as the target.
  @State private var newProjectInArea: String?

  var body: some View {
    #if os(macOS)
    sidebarMac.modifier(rightClickAlerts)
    #else
    if usesPushNavigation {
      sidebarSplit.modifier(rightClickAlerts)
    } else {
      sidebarPhone.modifier(rightClickAlerts)
    }
    #endif
  }

  // MARK: - Right-click alerts (rename / delete)

  private var rightClickAlerts: some ViewModifier {
    RightClickAlerts(
      renameProjectTarget: Binding(
        get: { renameProjectTarget },
        set: { renameProjectTarget = $0 }),
      renameAreaTarget: Binding(
        get: { renameAreaTarget },
        set: { renameAreaTarget = $0 }),
      deleteProjectTarget: Binding(
        get: { deleteProjectTarget },
        set: { deleteProjectTarget = $0 }),
      deleteAreaTarget: Binding(
        get: { deleteAreaTarget },
        set: { deleteAreaTarget = $0 }),
      renameDraft: Binding(
        get: { renameDraft },
        set: { renameDraft = $0 }),
      commitRenameProject: { p, name in renameProject(p, to: name) },
      commitRenameArea:    { a, name in renameArea(a, to: name) },
      commitDeleteProject: { p in deleteProject(p) },
      commitDeleteArea:    { a in deleteArea(a) },
      projectDeleteCopy: { p in
        RegistryPrompts.deleteProject(id: p.id, title: p.title, context: modelContext)
      },
      areaDeleteCopy: { a in
        RegistryPrompts.deleteArea(id: a.id, title: a.title, context: modelContext)
      }
    )
  }

  // MARK: - Right-click mutations

  private func renameProject(_ project: Project, to raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != project.title else { return }
    Haptics.tick()
    Task {
      do {
        try await projectsMutator.rename(id: project.id, to: trimmed)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func renameArea(_ area: Area, to raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != area.title else { return }
    Haptics.tick()
    Task {
      do {
        try await areasMutator.rename(id: area.id, to: trimmed)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func moveProject(_ project: Project, to areaId: String?) {
    guard project.area != areaId else { return }
    Haptics.tick()
    Task {
      do {
        try await projectsMutator.setArea(id: project.id, area: areaId)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  /// Mark a project done / cancelled from the sidebar context menu — the iPad
  /// home for these lifecycle actions (the detail page's nav-bar overflow is
  /// suppressed on iPad so it can't collide with the global chrome). If the
  /// project being closed is the one open in the detail, bounce to Today.
  private func setProjectStatus(_ project: Project, to status: ProjectStatus) {
    Haptics.tick()
    if status != .active, case .project(let id) = nav.path.last, id == project.id {
      nav.path = [.filter(.today)]
    }
    Task {
      do {
        try await projectsMutator.setStatus(id: project.id, status: status)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func deleteProject(_ project: Project) {
    Haptics.warning()
    // If the user was viewing the project that just got deleted, bounce them
    // to Today so they aren't stranded on a 404.
    if case .project(let id) = nav.path.last, id == project.id {
      nav.path = [.filter(.today)]
    }
    // Capture before the delete; record at the gesture (CLAUDE.md: undo is
    // recorded at the user gesture, never inside a mutator).
    let undoSnapshot = TaskUndo.projectDeleteSnapshot(id: project.id, projects: projectsMutator,
                                                      context: modelContext)
    let projects = projectsMutator
    let tasks = taskMutator
    Task {
      do {
        try await projectsMutator.delete(id: project.id)
        if let undoSnapshot {
          TaskUndo.recordProjectDelete(undoSnapshot, projects: projects, mutator: tasks)
        }
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func deleteArea(_ area: Area) {
    Haptics.warning()
    if case .area(let id) = nav.path.last, id == area.id {
      nav.path = [.filter(.today)]
    }
    // Capture before the delete; record at the gesture (CLAUDE.md).
    let undoSnapshot = TaskUndo.areaDeleteSnapshot(id: area.id, areas: areasMutator,
                                                   projects: projectsMutator, context: modelContext)
    let areas = areasMutator
    let projects = projectsMutator
    let tasks = taskMutator
    Task {
      do {
        try await areasMutator.delete(id: area.id)
        if let undoSnapshot {
          TaskUndo.recordAreaDelete(undoSnapshot, areas: areas, projects: projects, mutator: tasks)
        }
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  /// iPad regular / foldable widescreen: the NavigationSplitView sidebar
  /// column. Same insetGrouped "bubble card" home as iPhone (the surface the
  /// user preferred), but on a slightly recessed `sidebarPanelBackground` so the
  /// column reads as a distinct panel against the detail pane.
  @ViewBuilder
  private var sidebarSplit: some View {
    sidebarListContent()
    .background(Theme.sidebarPanelBackground)
    .navigationTitle("")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    #if !SEPTASK
    // Septena iPad: the window-level overlay (`RootTabView`) owns the sole
    // sidebar show/hide control — drop the system's auto-injected toggle so it
    // doesn't duplicate beside Quick Find in this column's nav bar. Septask
    // has no overlay bar and keeps the native system toggle.
    .toolbar(removing: .sidebarToggle)
    #endif
    .modifier(sidebarBehavior)
  }

  /// iPhone compact: scrolling list with a standard navigation bar and
  /// toolbar `+` menu (Reminders pattern). Settings is reachable from the
  /// top-left "…" overflow menu (and ⌘, on macOS).
  @ViewBuilder
  private var sidebarPhone: some View {
    sidebarListContent()
    .background(Theme.sidebarBackground)
    // Empty nav bar so iOS renders its default scroll-edge fade as
    // sidebar rows pass behind the top safe area.
    .navigationTitle("")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .modifier(sidebarBehavior)
  }

  /// macOS layout: a native source-list sidebar in a balanced split view, so
  /// opening it reserves space for navigation instead of covering the detail.
  @ViewBuilder
  private var sidebarMac: some View {
    sidebarListContent()
    .modifier(sidebarBehavior)
  }

  /// The Tasks home, standardized onto a system `List`: the smart-list tiles as
  /// a borderless first section, then real grouped sections per area / top-level
  /// project. `List` supplies the grouped "bubble" cards, the inter-row
  /// separators, while the surrounding navigation container supplies the
  /// platform-appropriate navigation material. This replaces the hand-built
  /// `sectionCard` / `inCardDivider` / bare-VStack scaffolding it used to use:
  /// iOS uses `insetGrouped`; macOS uses its native Liquid Glass sidebar.
  private func sidebarListContent() -> some View {
    Group {
      #if os(iOS)
      // iPhone + iPad share the Reminders-style home: the 2-column smart-list
      // grid sits at the top of the scroll (so it scrolls *with* the area /
      // project cards below the top chrome — not a separate pinned bar), then
      // the grouped cards. Host it as an empty section's *header* with zero
      // `listRowInsets` (rather than a section body row): `.insetGrouped` clips
      // every section's body cells to the system grouped-section corner radius,
      // which sliced the grid's outer combined corners differently from each
      // tile's own radius. A section header sits outside that corner clip, and
      // `.listRowInsets(EdgeInsets())` strips the default header text indent so
      // the grid aligns flush with the grouped cards below.
      List(selection: sidebarSelection) {
        Section {
        } header: {
          smartListGrid
            .textCase(nil)
            .foregroundStyle(Color.primary)
            .listRowInsets(EdgeInsets())
            .accessibilityRemoveTraits(.isHeader)
        }
        areaProjectSections()
      }
      #if os(iOS) && SEPTASK
      .onDrop(of: [.septenaTaskDragIDs],
              delegate: SidebarNewAreaDropDelegate {
                Haptics.tick()
                newAreaName = ""
                showingNewArea = true
              })
      .magicPlusSectionDrop(id: "mp-sidebar-new-area", kind: .newArea,
                            priority: 1, highlights: false) {
        Haptics.tick()
        newAreaName = ""
        showingNewArea = true
      }
      #endif
      .modifier(IOSSidebarListChrome())
      .septenaNeutralListSelection()
      .pageChrome(
        id: "tasks",
        title: "Tasks",
        localActions: { AnyView(tasksMenuExtraRows) },
        add: sidebarAddAction
      )
      #else
      // Let SwiftUI supply the macOS sidebar material, row metrics, active
      // state, and selection behavior. Inset/card styling here creates nested
      // opaque surfaces that fight the system sidebar material.
      List(selection: sidebarSelection) {
        smartListSection
        areaProjectSections()
      }
      .listStyle(.sidebar)
      .septenaNeutralListSelection()
      .pageChrome(
        id: "tasks",
        title: "Tasks",
        localActions: { AnyView(tasksMenuExtraRows) }
      )
      #endif
    }
    .onAppear { reconcileSidebarSelection() }
    .onChange(of: usesPushNavigation) { _, _ in reconcileSidebarSelection() }
    // macOS menu bar → sidebar sheets. The Task menu's New Project / New Area
    // set these one-shots (macOS has no toolbar "···"); consume + reset here.
    .onChange(of: nav.shouldCreateProject) { _, want in
      if want { showingNewProject = true; nav.shouldCreateProject = false }
    }
    .onChange(of: nav.shouldCreateArea) { _, want in
      if want { showingNewArea = true; nav.shouldCreateArea = false }
    }
  }

  // MARK: - Smart lists section
  //
  // iOS (iPhone + iPad): the 2-up tile grid is its own borderless section at the
  // top (see `smartListGridSection`). macOS: native source-list rows.

  @ViewBuilder
  private var smartListSection: some View {
    Section {
      ForEach(smartListSpecs, id: \.title) { spec in
        #if os(iOS)
        compactRow { smartListRow(for: spec) }
        #else
        compactRow(route: spec.route) { smartListRow(for: spec) }
        #endif
      }
    }
  }

  @ViewBuilder
  private func smartListRow(for spec: SmartListSpec) -> some View {
    let row = navRow(spec.route) {
      SmartListRow(icon: spec.icon,
                   iconColor: spec.color,
                   title: spec.title,
                   count: spec.count)
    }
    .contextMenu { smartListContextMenu(for: spec) }
    #if os(macOS)
    row.modifier(SmartListTaskDrop(route: spec.route, mutator: taskMutator))
    #else
    row
    #endif
  }

  @ViewBuilder
  private func smartListContextMenu(for spec: SmartListSpec) -> some View {
    if case .filter(let filter) = spec.route,
       let destID = filter.destinationID,
       let dest = SmartListPreferences.sidebarById[destID] {
      if dest.canMoveSection {
        let currentSection = SmartListPreferences.shared.section(for: destID)
        Button {
          let prefs = SmartListPreferences.shared
          let before = prefs.snapshot()
          let target: SmartListSection = currentSection == .top ? .bottom : .top
          prefs.setSection(target, for: destID)
          let after = prefs.snapshot()
          if after != before {
            TaskUndo.record(
              name: String(localized: "Move \(spec.title)", comment: "Sidebar: undo action"),
              undo: { SmartListPreferences.shared.restore(before) },
              redo: { SmartListPreferences.shared.restore(after) }
            )
          }
        } label: {
          Label(
            currentSection == .top ? "Move Below Areas & Projects" : "Move Above Areas & Projects",
            systemImage: currentSection == .top ? "arrow.down.to.line" : "arrow.up.to.line"
          )
        }
      }
      if dest.canHide {
        Button {
          let prefs = SmartListPreferences.shared
          let before = prefs.snapshot()
          prefs.setHidden(true, for: destID)
          let after = prefs.snapshot()
          if after != before {
            if isSelected(spec.route) {
              selectRoute(.filter(.today))
            }
            TaskUndo.record(
              name: String(localized: "Hide \(spec.title)", comment: "Sidebar: undo action"),
              undo: { SmartListPreferences.shared.restore(before) },
              redo: { SmartListPreferences.shared.restore(after) }
            )
          }
        } label: {
          Label("Hide \(spec.title)", systemImage: "eye.slash")
        }
      }
    }
    #if SEPTASK
    Button {
      SeptaskSettingsLink.request(RegistrySettings.PageID.smartLists)
      #if os(macOS)
      SeptaskKitSettingsWindow.show()
      #else
      nav.showSettings = true
      #endif
    } label: {
      Label("Customize Smart Lists…", systemImage: "slider.horizontal.3")
    }
    #endif
  }

  #if os(iOS)
  /// The 2-column grid of large smart-list tiles (Today / Upcoming / Repeating /
  /// Anytime / Logbook). Hosted as a zero-inset section header at the top of the
  /// sidebar List so it scrolls with the cards below, spans the same card width,
  /// and stays outside `.insetGrouped`'s section corner clip.
  private var smartListGrid: some View {
    LazyVGrid(columns: [GridItem(.flexible(), spacing: IOSSidebarListMetrics.sectionSpacing),
                        GridItem(.flexible(), spacing: IOSSidebarListMetrics.sectionSpacing)],
              spacing: IOSSidebarListMetrics.sectionSpacing) {
      ForEach(smartListSpecs, id: \.title) { spec in
        Button { selectRoute(spec.route) } label: {
          SmartListTile(icon: spec.icon,
                        iconColor: spec.color,
                        title: spec.title,
                        count: spec.count,
                        isSelected: isSelected(spec.route))
        }
        .buttonStyle(InertButtonStyle())
        .contextMenu { smartListContextMenu(for: spec) }
        // Drag-a-task-onto-Today re-home, matching the area / project cards
        // below. Only the Today tile takes a drop; self-gates to iPad
        // full-screen (inert on iPhone/compact).
        .modifier(SmartListTaskDrop(route: spec.route, mutator: taskMutator))
      }
    }
    .frame(maxWidth: .infinity)
    #if SEPTASK
    // Septask draws no floating chrome bar above the sidebar (iPadBarHeight == 0),
    // so on the two-column iPad canvas the 2×2 would sit flush to the top edge.
    // Give it a top margin matching its own left/right inset (the insetGrouped
    // gutter) so the grid is symmetric. iPhone/compact keeps its nav-bar spacing.
    .padding(.top, usesPushNavigation ? Theme.pageGutter : 0)
    #endif
  }
  #endif

  /// Septena Life's iPad split view publishes "+" from the sidebar into the
  /// window-level overlay (`RootTabView.iPadTopBar`). Septask has no overlay
  /// bar — its detail column owns "+" in its own nav bar so it stays visible
  /// even when the sidebar collapses on unfolded iPhone Duo / iPad.
  private var sidebarAddAction: PageAdd? {
    #if SEPTASK
    return nil
    #else
    return usesPushNavigation ? .action { nav.requestNewTask() } : nil
    #endif
  }

  @ViewBuilder
  private var tasksMenuExtraRows: some View {
    Button {
      showingNewArea = true
      newAreaName = ""
    } label: {
      Label(RegistryActions.title("sidebar.newArea"), systemImage: "square.stack.3d.up")
    }
    Button {
      showingNewProject = true
    } label: {
      Label(RegistryActions.title("sidebar.newProject"), systemImage: "number")
    }
    #if SEPTASK
    Divider()
    Button {
      SeptaskSettingsLink.request(RegistrySettings.PageID.smartLists)
      #if os(macOS)
      SeptaskKitSettingsWindow.show()
      #else
      nav.showSettings = true
      #endif
    } label: {
      Label("Customize Smart Lists…", systemImage: "slider.horizontal.3")
    }
    #endif
    #if !SEPTASK
    Divider()
    // Page-specific settings, in the same slot Next uses (just above the
    // shared Settings row): deep-link to the top-level Settings ▸ Tasks
    // pane. Rides `NavigationState` (iOS forwards it through the shared
    // settings sheet). Septask has its own Settings shell, so the entry is
    // compiled out there.
    Button {
      nav.settingsDestination = .tasks
      nav.showSettings = true
    } label: {
      Label("Task Settings", systemImage: "checklist")
    }
    #endif
  }

  private var sidebarBehavior: some ViewModifier {
    SidebarBehaviorModifier(
      showingCreateMenu: $showingCreateMenu,
      showingNewProject: $showingNewProject,
      showingNewArea: $showingNewArea,
      newAreaName: $newAreaName,
      errorMessage: $errorMessage,
      newProjectInArea: $newProjectInArea,
      areas: areas,
      onNewTodo: {
        // Land on Today (where the triage band lives) instead of a separate
        // Inbox page (retired). The composer seeds from the Today filter.
        nav.path = [.filter(.today)]
        nav.requestNewTask()
      },
      onCreateProject: { title, areaId in createProject(title: title, areaId: areaId) },
      onCreateArea: { createArea() },
      reload: { Task { await load() } }
    )
  }

  // MARK: - Create handlers

  private func createProject(title: String, areaId: String?) {
    let t = title.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return }
    Task {
      do {
        _ = try await projectsMutator.create(title: t, area: areaId)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func createArea() {
    let name = newAreaName.trimmingCharacters(in: .whitespaces)
    newAreaName = ""
    guard !name.isEmpty else { return }
    Task {
      do {
        _ = try await areasMutator.create(title: name)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - Smart lists
  //
  // Reminders-style: on iOS a 2-column grid of tiles, on macOS a vertical
  // list of rows with the same colored filled-icon glyph treatment. The
  // route + icon + color + title comes from `SmartListSpec` so the tile and
  // row renderers share one source of truth.

  private struct SmartListSpec {
    let route: Route
    let icon: String
    let color: Color
    let title: String
    let count: Int?
  }

  private var nonEmptySmartListIDs: Set<String> {
    var ids = Set<String>()
    // Review and Agent also stay while selected, so accepting the last item
    // does not pull the row out from under the user.
    if reviewCount > 0 || isSelected(.filter(.review)) { ids.insert("review") }
    if agentCount > 0 || isSelected(.filter(.agent)) { ids.insert("agent") }
    if starredCount > 0 { ids.insert("starred") }
    if fadedCount > 0 { ids.insert("faded") }
    if recentlyDeletedCount > 0 { ids.insert("recentlyDeleted") }
    return ids
  }

  private var topSmartListRoutes: [Route] {
    TaskDestinations.sidebarRoutes(in: .top, nonEmptyIDs: nonEmptySmartListIDs)
  }

  private var bottomSmartListRoutes: [Route] {
    TaskDestinations.sidebarRoutes(in: .bottom, nonEmptyIDs: nonEmptySmartListIDs)
  }

  private var visibleSmartListRoutes: [Route] {
    topSmartListRoutes + bottomSmartListRoutes
  }

  private func makeSmartListSpec(_ route: Route) -> SmartListSpec {
    SmartListSpec(route: route,
                  icon: route.icon,
                  color: smartListColor(route),
                  title: route.title,
                  count: smartListCount(route))
  }

  // The smart-list SET, section placement, and order are single-sourced in
  // `SmartListPreferences` over `registry/destinations.json`. Top lists render
  // in the 2-column tile grid (iOS) / top cluster (macOS); bottom lists render
  // in a grouped card below Areas & Projects.
  private var smartListSpecs: [SmartListSpec] {
    topSmartListRoutes.map(makeSmartListSpec)
  }

  private var bottomSmartListSpecs: [SmartListSpec] {
    bottomSmartListRoutes.map(makeSmartListSpec)
  }

  private func smartListColor(_ route: Route) -> Color {
    // Only Today wears the user's active accent color — it's the bucket you
    // act on. The other special lists recede to quiet secondary ink.
    switch route {
    case .filter(.today): return AppearancePreferences.shared.accentSwiftUIColor
    default:              return .secondary
    }
  }

  private func smartListCount(_ route: Route) -> Int? {
    switch route {
    // Today total = pinned-today + scheduled/due rolling in. Both buckets live
    // on Today, so the user-facing count is the sum.
    case .filter(.today):           return counts.map { $0.todayCount + $0.reviewCount }
    case .filter(.review):          return reviewCount > 0 ? reviewCount : nil
    case .filter(.agent):           return agentCount > 0 ? agentCount : nil
    case .filter(.upcoming):        return counts?.upcomingCount
    case .filter(.repeating):       return repeatingCount
    case .filter(.unscheduled):     return counts?.unscheduledCount
    case .filter(.logbook):         return doneTodayCount > 0 ? doneTodayCount : nil
    case .filter(.starred):         return starredCount > 0 ? starredCount : nil
    case .filter(.faded):           return fadedCount > 0 ? fadedCount : nil
    case .filter(.recentlyDeleted): return recentlyDeletedCount > 0 ? recentlyDeletedCount : nil
    default:                        return nil
    }
  }

  /// A navigable sidebar row. Two behaviors:
  ///   • macOS / iPad regular (push nav): a native `List(selection:)` cell
  ///     tagged by its route, whose selection drives the detail directly through
  ///     `sidebarSelection` — a single click (or arrow key) *is* open, the
  ///     standard system source-list model.
  ///   • iPhone / slide-over (compact): a Button that sets `nav.path` directly;
  ///     InertButtonStyle suppresses the click-tint flash.
  @ViewBuilder
  private func navRow<Content: View>(_ route: Route,
                                     @ViewBuilder content: () -> Content) -> some View {
    #if os(macOS)
    content().tag(route.id)
    #else
    if usesPushNavigation {
      content().tag(route.id)
    } else {
      Button { selectRoute(route) } label: { content() }
        .buttonStyle(PlainHoverRowButtonStyle(cornerRadius: 10))
    }
    #endif
  }

  /// Every route the sidebar can currently select — visible smart lists, areas,
  /// and every active project. Used to resolve a `Route.id` tag back to its
  /// full `Route` for the selection binding.
  private var selectableRoutes: [Route] {
    var routes = visibleSmartListRoutes
    routes += areas.map { .area(id: $0.id) }
    routes += projects.filter { $0.status == .active }.map { .project(id: $0.id) }
    return routes
  }

  /// Two-way bridge between `List(selection:)` and the app's `nav.path`: reads
  /// the current route's id, and writing one (a click / keyboard move) resolves
  /// it back to a `Route` and routes through `selectRoute`, so selection and
  /// navigation stay one action. Id-based so a reloaded project/area struct
  /// (same id, changed fields) can't drop the highlight.
  ///
  /// On push surfaces (iPad regular / macOS) a detail pane is always visible,
  /// so selection never reads as nil — Today is the default home, and a route
  /// that fell off the sidebar (archived project, deleted area) bounces there.
  private var sidebarSelection: Binding<String?> {
    Binding(
      get: {
        if usesPushNavigation { return effectiveSidebarRoute.id }
        return nav.path.last?.id
      },
      set: { id in
        if let id, let route = selectableRoutes.first(where: { $0.id == id }) {
          selectRoute(route)
        } else if usesPushNavigation {
          selectRoute(.filter(.today))
        }
      }
    )
  }

  /// The route the sidebar should treat as selected on split surfaces. Mirrors
  /// `ContentView`'s detail fallback and re-validates against the live
  /// `selectableRoutes` list so a stale project/area can't leave no row lit.
  private var effectiveSidebarRoute: Route {
    if let last = nav.path.last,
       selectableRoutes.contains(where: { $0.sameDestination(as: last) }) {
      return last
    }
    return .filter(.today)
  }

  /// Sync `nav.path` when the split surface needs a guaranteed selection.
  private func reconcileSidebarSelection() {
    guard usesPushNavigation else { return }
    let route = effectiveSidebarRoute
    if nav.path.last?.id != route.id { nav.path = [route] }
  }

  private func selectRoute(_ route: Route) {
    // The sidebar IS the navigation (replace, not deepen) — `go` owns that rule.
    nav.go(to: route)
  }

  /// Which route the sidebar should render as "current". In a compact-width
  /// layout the sidebar IS the home screen, so an empty nav stack means "no
  /// row is current" — returning a Today fallback there would falsely
  /// highlight the Today tile while the user is looking at the overview. A
  /// regular-width split (iPad, macOS, or an unfolded foldable) always has a
  /// detail pane showing, so Today is a sensible default.
  private var highlightedRoute: Route? {
    #if os(iOS)
    if !usesPushNavigation { return nav.path.last }
    return nav.path.last ?? .filter(.today)
    #else
    return effectiveSidebarRoute
    #endif
  }

  /// Stable-id comparison via `Route.sameDestination` — default `Route`
  /// equality compares the whole `Project` / `Area` struct, which breaks the
  /// highlight as soon as the sidebar reloads an entity with any changed field.
  private func isSelected(_ route: Route) -> Bool {
    highlightedRoute?.sameDestination(as: route) ?? false
  }

  // MARK: - Areas and projects
  //
  // Real grouped `List` sections stand in for the hand-built Mimestream
  // "bubble" cards: each area is a section (the area row on top, its active
  // projects beneath), with a separate section for top-level projects. `List`
  // draws the rounded grouped card and the inter-row separators, so there's no
  // `sectionCard` / `inCardDivider` scaffolding left. An area with no projects
  // still renders as a one-row card, so every area reads as the same container.

  @ViewBuilder
  private func areaProjectSections() -> some View {
    if !topLevelProjects.isEmpty {
      Section {
        ForEach(topLevelProjects) { project in
          compactRow(route: .project(id: project.id)) { projectRow(project, parent: nil) }
        }
      }
    }
    ForEach(areas, id: \.id) { area in
      let areaProjects = projects.filter { $0.area == area.id && $0.status == .active }
      let collapsed = collapsedAreas.contains(area.id)
      Section {
        compactRow(route: .area(id: area.id)) {
          areaRow(area, hasProjects: !areaProjects.isEmpty, collapsed: collapsed)
        }
        if !collapsed {
          ForEach(areaProjects) { project in
            compactRow(route: .project(id: project.id)) { projectRow(project, parent: area.id) }
          }
        }
      }
    }
    if !bottomSmartListSpecs.isEmpty {
      Section {
        ForEach(bottomSmartListSpecs, id: \.route.id) { spec in
          compactRow(route: spec.route) { smartListRow(for: spec) }
        }
      }
    }
  }

  /// Tightens a sidebar list row to Reminders-like density. The row views carry
  /// their own height (`Theme.sidebar*RowHeight`), so the List's default vertical
  /// inset otherwise stacks on top and makes rows too tall — we zero it and keep
  /// a 16pt horizontal inset for the iOS grouped cards. macOS uses the system
  /// sidebar's row metrics, which respond to the person's sidebar size setting.
  @ViewBuilder
  private func compactRow<V: View>(route: Route? = nil,
                                   @ViewBuilder _ row: () -> V) -> some View {
    let selected = route.map { isSelected($0) } ?? false
    row()
      #if os(iOS)
      .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
      // Custom neutral fill only — suppress UIKit's accent capsule / selection
      // ring so rows don't grow or glow on tap (same pattern as the task-list
      // detail).
      .listRowBackground(SelectableListRowBackground(isSelected: selected))
      #else
      // macOS: unselected rows stay transparent so the native `.sidebar` Liquid
      // Glass material shows through; the selected row gets the app's
      // `listSelectionFill` as an inset capsule. Suppress AppKit's accent ring
      // so that fill is the only highlight.
      .listRowBackground(SidebarMacRowBackground(isSelected: selected))
      #endif
      .septenaSuppressListCellSelection()
  }

  /// The area's own row — tappable to its detail, with rename / reorder / delete
  /// in the context menu (and, on macOS, a task drop target). Sits at the top of
  /// its section's grouped card, projects underneath.
  @ViewBuilder
  private func areaRow(_ area: Area, hasProjects: Bool, collapsed: Bool) -> some View {
    navRow(.area(id: area.id)) {
      SidebarAreaRow(name: area.title, emoji: area.emoji, count: areaOpenCount[area.id] ?? 0,
                     isCollapsed: hasProjects ? collapsed : nil,
                     onToggleCollapse: hasProjects ? { toggleAreaCollapsed(area.id) } : nil)
    }
    #if os(iOS)
    .contextMenu {
      areaMenu(area)
    } preview: {
      SidebarAreaRow(name: area.title, emoji: area.emoji, count: areaOpenCount[area.id] ?? 0)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Theme.cardSurface)
    }
    #else
    .contextMenu { areaMenu(area) }
    #endif
    // Drag-a-task-here re-home on co-visible sidebar+list (iPad/Mac); on compact
    // iPhone Septena, dropping Magic Plus on an Area creates a New Project in it.
    .modifier(SidebarTaskDrop(kind: .area(area.id), mutator: taskMutator) {
      newProjectInArea = area.id
      showingNewProject = true
    })
    .magicPlusSectionDrop(id: "mp-sidebar-area-\(area.id)",
                          kind: .newProject(label: "New Project in \(area.title)")) {
      Haptics.tick()
      newProjectInArea = area.id
      showingNewProject = true
    }
  }

  @ViewBuilder
  private func projectRow(_ project: Project, parent: String?) -> some View {
    let parentTitle = parent.flatMap { pid in areas.first(where: { $0.id == pid })?.title }
    let magicLabel = parentTitle.map { "New Project in \($0)" } ?? "New Project"
    navRow(.project(id: project.id)) {
      SidebarProjectRow(name: project.title,
                        progress: projectProgress[project.id] ?? 0,
                        count: projectOpenCount[project.id] ?? 0)
    }
    #if os(iOS)
    .contextMenu {
      projectMenu(project)
    } preview: {
      SidebarProjectRow(name: project.title,
                        progress: projectProgress[project.id] ?? 0,
                        count: projectOpenCount[project.id] ?? 0)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Theme.cardSurface)
    }
    #else
    .contextMenu { projectMenu(project) }
    #endif
    // Drag-a-task-here re-home on co-visible sidebar+list (iPad/Mac); on compact
    // iPhone Septena, dropping Magic Plus on a Project creates a sibling Project.
    .modifier(SidebarTaskDrop(kind: .project(project.id), mutator: taskMutator) {
      newProjectInArea = parent
      showingNewProject = true
    })
    .magicPlusSectionDrop(id: "mp-sidebar-proj-\(project.id)",
                          kind: .newProject(label: magicLabel)) {
      Haptics.tick()
      newProjectInArea = parent
      showingNewProject = true
    }
  }

  // MARK: - Context menus

  /// Registry `sidebar.project`, the same menu the AppKit sidebar renders.
  private func projectMenu(_ project: Project) -> some View {
    let siblings = projects.filter { $0.area == project.area && $0.status == .active }
    let idx = siblings.firstIndex(where: { $0.id == project.id })
    return RegistryMenuContent(nodes: RegistryMenuResolver.resolve(
      RegistryActions.menu("sidebar.project"),
      bind: { id in
        switch id {
        case "project.rename":
          return .init {
            renameDraft = project.title
            renameProjectTarget = project
          }
        case "project.moveUp":
          guard let idx else { return nil }
          return .init(perform: idx == 0 ? nil : {
            reorderProject(project.id, before: siblings[idx - 1].id, parent: project.area)
          })
        case "project.moveDown":
          guard let idx else { return nil }
          return .init(perform: idx == siblings.count - 1 ? nil : {
            reorderProject(siblings[idx + 1].id, before: project.id, parent: project.area)
          })
        case "project.markDone": return .init { setProjectStatus(project, to: .done) }
        case "project.cancel": return .init { setProjectStatus(project, to: .cancelled) }
        case "project.delete": return .init { deleteProjectTarget = project }
        default: return nil
        }
      },
      slot: { id in
        guard id == "moveToAreaDestinations" else { return [] }
        return projectAreaDestinations(project)
      }))
  }

  /// Move to Area ▸ — No Area, then every area; the current parent is
  /// checked and inert. Same slot the AppKit sidebar fills.
  private func projectAreaDestinations(_ project: Project) -> [RegistryMenuNode] {
    var nodes: [RegistryMenuNode] = [
      RegistryMenuEntry.slot(id: "area.none", title: String(localized: "No Area"),
                             isOn: project.area == nil,
                             perform: project.area == nil ? nil : { moveProject(project, to: nil) }),
    ]
    if !areas.isEmpty { nodes.append(.divider(id: "areas.divider")) }
    for area in areas {
      nodes.append(RegistryMenuEntry.slot(
        id: "area.\(area.id)", title: area.title, isOn: project.area == area.id,
        perform: project.area == area.id ? nil : { moveProject(project, to: area.id) }))
    }
    return nodes
  }

  /// Registry `sidebar.area`, the same menu the AppKit sidebar renders.
  private func areaMenu(_ area: Area) -> some View {
    let idx = areas.firstIndex(where: { $0.id == area.id })
    return RegistryMenuContent(nodes: RegistryMenuResolver.resolve(
      RegistryActions.menu("sidebar.area")) { id in
        switch id {
        case "area.newProject":
          return .init {
            newProjectInArea = area.id
            showingNewProject = true
          }
        case "area.rename":
          return .init {
            renameDraft = area.title
            renameAreaTarget = area
          }
        case "area.moveUp":
          guard let idx else { return nil }
          return .init(perform: idx == 0 ? nil : { reorderArea(area.id, before: areas[idx - 1].id) })
        case "area.moveDown":
          guard let idx else { return nil }
          return .init(perform: idx == areas.count - 1 ? nil : {
            reorderArea(areas[idx + 1].id, before: area.id)
          })
        case "area.delete": return .init { deleteAreaTarget = area }
        default: return nil
        }
      })
  }

  /// Move the area with id `movedId` to the position immediately before
  /// `targetId`, then sync to the server. Optimistic update + rollback on
  /// failure (any server error reloads server state to restore truth).
  private func reorderArea(_ movedId: String, before targetId: String) {
    guard let from = areas.firstIndex(where: { $0.id == movedId }),
          let to = areas.firstIndex(where: { $0.id == targetId }),
          from != to else { return }
    var next = areas
    let item = next.remove(at: from)
    let insertAt = (from < to) ? to - 1 : to
    next.insert(item, at: insertAt)
    commitAreaOrder(next)
  }

  private func commitAreaOrder(_ next: [Area]) {
    Haptics.tick()
    areas = next   // optimistic; the reorder re-posts .septenaStructureChanged → load() re-sorts by position
    let ids = next.map(\.id)
    Task { try? await areasMutator.reorder(orderedIDs: ids) }
  }

  /// Reorder a project within its parent group (top-level when parent is
  /// nil, or within a single area). Cross-group drags are caller-rejected
  /// in the drop handler — this function assumes same-parent invariant.
  private func reorderProject(_ movedId: String, before targetId: String, parent: String?) {
    commitProjectOrder(parent: parent) { siblings in
      guard let from = siblings.firstIndex(where: { $0.id == movedId }),
            let to   = siblings.firstIndex(where: { $0.id == targetId }),
            from != to else { return nil }
      var next = siblings
      let item = next.remove(at: from)
      let insertAt = (from < to) ? to - 1 : to
      next.insert(item, at: insertAt)
      return next
    }
  }

  /// Single commit path for project reorder: compute the new sibling-order
  /// (active projects in the given parent group), splice it back into the
  /// full `projects` array preserving everything outside that group, push
  /// optimistic state, and write to the server. Rolls back on failure.
  ///
  /// Why splice-back-into-full-array: `replaceProjects` is atomic over the
  /// entire collection — sending only one group would lose the rest. We
  /// must reorder within the group while keeping every other row in place.
  private func commitProjectOrder(parent: String?,
                                  reorder: ([Project]) -> [Project]?) {
    let isInGroup: (Project) -> Bool = { p in
      p.area == parent && p.status == .active
    }
    let siblings = projects.filter(isInGroup)
    guard let nextSiblings = reorder(siblings) else { return }

    // Splice the reordered siblings back into the full projects array,
    // keeping the relative position of the first sibling slot stable so
    // non-group projects don't shift.
    var next: [Project] = []
    var sibIter = nextSiblings.makeIterator()
    for p in projects {
      if isInGroup(p) {
        if let s = sibIter.next() { next.append(s) }
      } else {
        next.append(p)
      }
    }

    Haptics.tick()
    projects = next   // optimistic; reorder re-posts .septenaStructureChanged → load() re-sorts by position
    let groupIDs = nextSiblings.map(\.id)
    Task { try? await projectsMutator.reorder(orderedIDs: groupIDs) }
  }

  private var topLevelProjects: [Project] {
    projects.filter { $0.area == nil && $0.status == .active }
  }

  // MARK: - Area fold state

  private var collapsedAreas: Set<String> {
    (try? JSONDecoder().decode(Set<String>.self, from: collapsedAreasData)) ?? []
  }

  /// Fold / unfold an area's project list, persisting the choice. Animated so
  /// the project rows slide in/out and the chevron rotates together.
  private func toggleAreaCollapsed(_ areaId: String) {
    Haptics.tick()
    var set = collapsedAreas
    if set.contains(areaId) { set.remove(areaId) } else { set.insert(areaId) }
    a11yAnimate(.easeInOut(duration: 0.2)) {
      collapsedAreasData = (try? JSONEncoder().encode(set)) ?? Data()
    }
  }

  // MARK: - Load

  private func load() async {
    // CloudKit is the only backend and LocalCache is authoritative. One
    // structure memo read, one live-task pass for roll-ups, one combined
    // counts+history scan for smart-list badges.
    //
    // Every read below returns `[]` on failure, which is indistinguishable
    // from an empty store — so a wedged context would paint 0 on every tile
    // AND memoize those zeros into `SidebarSeed`, where they stay for the rest
    // of the process. Take a read-failure token first and discard the whole
    // pass if any read threw: the previous, correct values stay on screen and
    // the next pass tries again.
    let token = StoreHealth.readToken()
    let structure = StructureCache.snapshot(in: modelContext)
    let stats = TaskReads.dashboardStats(today: clock.today,
                                         now: clock.now,
                                         context: modelContext)
    var agg = Self.aggregate(tasks: LocalCache.liveAggregateEntities(in: modelContext), today: clock.today)
    agg.counts = stats.counts
    agg.doneTodayCount = stats.history.daily.last?.done ?? 0
    let deleted = LocalCache.recentlyDeletedCount(in: modelContext)
    guard !StoreHealth.readsFailed(since: token) else {
      SeptenaLog.error("[Sidebar] load aborted — a store read failed; keeping the last good counts")
      return
    }
    areas = structure.areas
    projects = structure.projects
    apply(aggregate: agg)
    SidebarSeed.aggregate = agg
    recentlyDeletedCount = deleted
    reconcileSidebarSelection()
  }

  fileprivate struct Aggregate {
    var counts: TasksCounts
    var doneTodayCount: Int = 0
    var projectProgress: [String: Double]
    var projectOpenCount: [String: Int]
    var areaOpenCount: [String: Int]
    var starredCount: Int = 0
    var fadedCount: Int = 0
    var reviewCount: Int = 0
    var agentCount: Int = 0
    var repeatingCount: Int = 0
  }

  /// Single-pass roll-up over the live tasks. Called once per load (and once
  /// per process by init, when the SidebarSeed memo is still empty). Reads
  /// entities (`LocalCache.liveAggregateEntities`), not row objects: a count
  /// never needs the conversation or recurrence JSON a row object decodes.
  private static func aggregate(tasks: [TaskEntity], today: String) -> Aggregate {
    // Project progress = done / (done + open). Cancelled doesn't count
    // toward either side of the ratio.
    var done: [String: Int] = [:]
    var total: [String: Int] = [:]
    var projOpen: [String: Int] = [:]
    // Area count = direct-in-area tasks ONLY. Nested projects render as
    // their own rows, so rolling them up would double-count.
    var areaDirectOpen: [String: Int] = [:]
    var inbox = 0, triage = 0, todayN = 0, upcoming = 0, unscheduled = 0, open = 0
    var starred = 0, faded = 0, review = 0, agent = 0, repeating = 0
    let now = Date()
    for t in tasks {
      // Faded open tasks leave every count and project ratio (docs/TASK_FADE_SPEC.md §4).
      if t.isFaded { faded += 1; continue }
      if t.status == .open { open += 1 }
      if let pid = t.project {
        switch t.status {
        case .done:                 done[pid, default: 0] += 1; total[pid, default: 0] += 1
        case .open:                 total[pid, default: 0] += 1; projOpen[pid, default: 0] += 1
        case .cancelled:            break
        }
      } else if let aid = t.area, t.status == .open {
        areaDirectOpen[aid, default: 0] += 1
      }
      guard t.status == .open else { continue }
      // Smart-list buckets — mirror LocalCache.tasks(in:filter:) semantics.
      if t.starred { starred += 1 }
      // Check the raw columns first so only rows that carry JSON decode it.
      if t.recurrenceUnit != nil, t.recurrence != nil { repeating += 1 }
      if t.conversationJSON != nil {
        let convo = t.conversation
        if convo.needsHumanReview { review += 1 }
        if convo.agentStage(at: now) != nil { agent += 1 }
      }
      if t.isInInbox { inbox += 1 }
      // The triage band (unratified) sits above Today and is excluded from it.
      if t.isInTriageBand { triage += 1 }
      if !t.isInTriageBand, t.isOnToday { todayN += 1 }
      if t.isUpcoming { upcoming += 1 }
      if !t.today, t.scheduled == nil, t.deadline == nil { unscheduled += 1 }
    }
    // Lump the today-screen sum into `todayCount` and leave `reviewCount`
    // at 0 — the sidebar shows the sum, so the tile looks identical
    // whether the server splits 5/2 or we send 7/0.
    let progress = total.reduce(into: [String: Double]()) { acc, kv in
      acc[kv.key] = Double(done[kv.key] ?? 0) / Double(kv.value)
    }
    return Aggregate(
      counts: TasksCounts(today: today,
                          todayCount: todayN, reviewCount: 0,
                          inboxCount: inbox, triageCount: triage,
                          upcomingCount: upcoming,
                          unscheduledCount: unscheduled,
                          openCount: open),
      projectProgress: progress,
      projectOpenCount: projOpen,
      areaOpenCount: areaDirectOpen,
      starredCount: starred,
      fadedCount: faded,
      reviewCount: review,
      agentCount: agent,
      repeatingCount: repeating)
  }

  private func apply(aggregate agg: Aggregate) {
    counts = agg.counts
    doneTodayCount = agg.doneTodayCount
    projectProgress = agg.projectProgress
    projectOpenCount = agg.projectOpenCount
    areaOpenCount = agg.areaOpenCount
    starredCount = agg.starredCount
    fadedCount = agg.fadedCount
    reviewCount = agg.reviewCount
    agentCount = agg.agentCount
    repeatingCount = agg.repeatingCount
  }

}
// MARK: - Sidebar primitives

/// The muted trailing count shown on every sidebar row (smart lists, areas,
/// projects, Recently Deleted). One definition so all the numbers read
/// identically — never restyle a count inline.
struct SidebarCount: View {
  let count: Int

  var body: some View {
    if count > 0 {
      Text("\(count)")
        .scaledFont(size: 12, weight: .regular)
        .foregroundStyle(Theme.inkSecondary.opacity(0.6))
    }
  }
}

struct SmartListRow: View {
  let icon: String
  /// Bare symbol tint — active accent on Today, quiet secondary on other special lists.
  var iconColor: Color = .secondary
  let title: String
  /// Muted gray count — neutral signal for total rows on this list.
  var count: Int? = nil

  var body: some View {
    HStack(spacing: Theme.sidebarRowSpacing) {
      // Platform sidebar standard (Mail, Files, Notes): a bare SF Symbol with
      // no filled background box. Fixed frame keeps titles aligned across
      // symbols of different widths.
      Image(systemName: icon)
        .scaledFont(size: Theme.sidebarIconSize, weight: .semibold)
        .foregroundStyle(iconColor)
        .frame(width: Theme.sidebarIconSize + 4, height: Theme.sidebarIconSize + 4)
      Text(title)
        .scaledFont(size: Theme.sidebarAreaTitleSize)
        // `.primary` (not a fixed Theme ink) so the native `.sidebar`
        // selection inverts the title to white over the focused accent.
        .foregroundStyle(.primary)
      Spacer()
      if let n = count { SidebarCount(count: n) }
    }
    .frame(height: Theme.sidebarSmartRowHeight)
    .contentShape(Rectangle())
  }
}

#if os(iOS)
/// Shared rhythm for the iOS Tasks sidebar: tile gutters, inter-row gaps in
/// the 2×2 grid, and the gap between the grid and the grouped cards below.
private enum IOSSidebarListMetrics {
  static let sectionSpacing: CGFloat = 14
}

/// iPhone + iPad share the insetGrouped "bubble card" Tasks home — the same
/// tiles-over-grouped-cards rhythm. (iPad used to render the `.sidebar` source
/// list; it now matches iPhone.)
private struct IOSSidebarListChrome: ViewModifier {
  func body(content: Content) -> some View {
    content
      .listStyle(.insetGrouped)
      // Hide the system grouped fill so `Theme.sidebarBackground` (applied by
      // `sidebarPhone` / `sidebarSplit`) shows through, matching the app surface.
      .scrollContentBackground(.hidden)
      // insetGrouped's default inter-section gap (~35pt) leaves too much air
      // above the first area and between area cards; tighten it for a denser,
      // more Reminders-like rhythm.
      .listSectionSpacing(IOSSidebarListMetrics.sectionSpacing)
      // iOS 26 soft scroll-edge: content blurs/fades as it scrolls under the top
      // instead of a hard cutoff — matching the task lists (SelectableScrollList)
      // and home pages (SeptenaPage). Especially visible on Septask iPad, where
      // the grid now sits at the top with no floating bar above it.
      .scrollEdgeEffectStyle(.soft, for: .top)
  }
}
#endif

private struct SidebarBehaviorModifier: ViewModifier {
  @Binding var showingCreateMenu: Bool
  @Binding var showingNewProject: Bool
  @Binding var showingNewArea: Bool
  @Binding var newAreaName: String
  @Binding var errorMessage: String?
  @Binding var newProjectInArea: String?

  let areas: [Area]
  let onNewTodo: () -> Void
  let onCreateProject: (String, String?) -> Void
  let onCreateArea: () -> Void
  let reload: () -> Void

  /// The sidebar re-reads the store (two full entity passes) after each task
  /// change. While it is off screen (another iPhone tab, or a project page
  /// pushed on top) that work is wasted, so it waits and runs once when the
  /// sidebar comes back. Same rule as `TaskListView.reloadOrDeferWhileEditing`.
  @State private var isVisible = false
  @State private var reloadPending = false

  private func reloadIfVisible() {
    guard isVisible else { reloadPending = true; return }
    reload()
  }

  func body(content: Content) -> some View {
    content
      .modifier(SidebarSheets(
        showingCreateMenu: $showingCreateMenu,
        showingNewProject: $showingNewProject,
        showingNewArea: $showingNewArea,
        newAreaName: $newAreaName,
        errorMessage: $errorMessage,
        newProjectInArea: $newProjectInArea,
        areas: areas,
        onNewTodo: onNewTodo,
        onCreateProject: onCreateProject,
        onCreateArea: onCreateArea
      ))
      .task { reload() }
      .onAppear {
        isVisible = true
        if reloadPending {
          reloadPending = false
          reload()
        }
      }
      .onDisappear { isVisible = false }
      // Debounced: a burst of toggles (or a CK batch fanning out per-record
      // mutator posts) coalesces into one reload instead of one per post.
      .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)
        .debounce(for: .seconds(0.3), scheduler: RunLoop.main)) { _ in
        reloadIfVisible()
      }
      .onReceive(NotificationCenter.default.publisher(for: .septenaStructureChanged)
        .debounce(for: .seconds(0.3), scheduler: RunLoop.main)) { _ in
        reloadIfVisible()
      }
  }
}

/// iOS "Reminders home screen" smart-list tile — whole tile fills with the
/// list color (subtle top-to-bottom gradient), white icon top-left, huge
/// white count top-right, white label bottom-left.
struct SmartListTile: View {
  let icon: String
  let iconColor: Color
  let title: String
  /// Total rows on the list — big bold number top-right.
  var count: Int? = nil
  /// When true, the tile gets the same neutral selection fill as list rows —
  /// no outline ring. iPhone never sees a selected tile (tapping pushes onto the
  /// stack).
  var isSelected: Bool = false

  var body: some View {
    // Mimestream-style minimal tile: white card with a small filled
    // colored circle for the icon, big bold count top-right in primary,
    // small primary label bottom-left. Lighter than the saturated
    // gradient version. Two counts split overdue from the rest: red on the
    // left, black on the right, both at the same weight so neither one
    // dominates as a "badge".
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        Image(systemName: icon)
          .scaledFont(size: 20, weight: .semibold)
          .foregroundStyle(iconColor)
          .frame(width: 26, height: 26, alignment: .leading)
        Spacer()
        countCluster
      }
      Spacer(minLength: 6)
      Text(title)
        .scaledFont(size: 15, weight: .regular)
        .foregroundStyle(Color.primary)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: TaskCardMetrics.radius, style: .continuous)
        .fill(isSelected ? Theme.listSelectionFill : Theme.cardSurface)
    )
  }

  /// Top-right cluster: single bold total in primary. Overdue is signalled
  /// in the sidebar row's red pill and in-list red dates — repeating it on
  /// the tile read as noise.
  @ViewBuilder
  private var countCluster: some View {
    if let n = count {
      Text("\(n)")
        .scaledFont(size: 26, weight: .bold)
        .foregroundStyle(Color.primary)
        .monospacedDigit()
    }
  }
}

/// Reminders-style colored rounded-square glyph: filled colored container
/// with a white SF Symbol inside. Used both in smart-list rows and tiles.
struct ColoredGlyph: View {
  let icon: String
  let color: Color
  let size: CGFloat
  /// Inner SF Symbol size as a fraction of `size`. Default `0.58` matches
  /// the original tight-glyph look used in compact sidebar rows. Settings
  /// rows pass a smaller ratio so the tile reads iOS-Settings-sized while
  /// the glyph stays at its natural ~16pt mark.
  var glyphRatio: CGFloat = 0.58
  @Environment(\.colorScheme) private var colorScheme

  /// Slight desaturation in dark mode keeps the small filled square from
  /// glaring against a dark background; light mode renders full strength.
  private var adaptedFill: Color {
    color.opacity(colorScheme == .dark ? 0.78 : 1.0)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
    ZStack {
      shape.fill(adaptedFill)
      // Per-tile sheen, the modern iOS Settings look: a soft top-down
      // gradient that lightens the top edge and gently deepens the bottom,
      // giving each saturated square a little dimensionality. Drawn over
      // the base fill so the color stays the source of truth.
      shape.fill(
        LinearGradient(
          colors: [Color.white.opacity(0.26), .clear, Color.black.opacity(0.07)],
          startPoint: .top, endPoint: .bottom
        )
      )
      Image(systemName: icon)
        .scaledFont(size: size * glyphRatio, weight: .semibold)
        .foregroundStyle(.white)
    }
    .frame(width: size, height: size)
  }
}

/// Soft tinted section icon — shared `SectionGlyph` in `SectionGlyph.swift`.

struct SidebarAreaRow: View {
  let name: String
  /// Optional user glyph; nil ⇒ the muted dot.
  var emoji: String? = nil
  /// Open task count rolled up across the area (loose + projects in it).
  var count: Int = 0
  /// Fold state — non-nil only when the area has projects (so a fold control
  /// is meaningful).
  var isCollapsed: Bool? = nil
  var onToggleCollapse: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: Theme.sidebarRowSpacing) {
      AreaIcon(emoji: emoji)
        .frame(width: Theme.sidebarIconSize + 4, alignment: .center)
      Text(name)
        .scaledFont(size: Theme.sidebarAreaTitleSize, weight: .semibold)
        .foregroundStyle(SidebarRowTitleStyle.color)
      Spacer()
      if let isCollapsed, let onToggleCollapse {
        SidebarFoldChevron(isCollapsed: isCollapsed, action: onToggleCollapse)
      }
      SidebarCount(count: count)
    }
    .frame(height: Theme.sidebarRowHeight)
    .contentShape(Rectangle())
  }
}

/// Trailing fold control on an area row: a chevron that points right when the
/// area is collapsed and rotates down when expanded. It takes its own tap via
/// a `.highPriorityGesture` so folding never falls through to the row's
/// navigation (iPhone Button label / iPad+macOS `List(selection:)`).
struct SidebarFoldChevron: View {
  let isCollapsed: Bool
  let action: () -> Void

  var body: some View {
    Image(systemName: "chevron.right")
      .scaledFont(size: 12, weight: .semibold)
      .foregroundStyle(.tertiary)
      .rotationEffect(.degrees(isCollapsed ? 0 : 90))
      .frame(width: 28, height: 28)
      .contentShape(Rectangle())
      .highPriorityGesture(TapGesture().onEnded { action() })
      #if os(macOS)
      .help(isCollapsed ? "Show projects" : "Hide projects")
      #endif
  }
}

/// Area glyph — a small filled dot in the muted icon tint. Deliberately
/// NOT a hollow circle so it doesn't read as a checkable / progress
/// shape. Same outer dimension as `ProjectProgressIcon` (so the icon
/// column stays aligned), but only the inner dot is drawn.
struct AreaIcon: View {
  var tint: Color = Theme.iconMuted
  var diameter: CGFloat? = nil
  /// Retained for call-site compatibility with the previous two-circle
  /// glyph — ignored by the new rendering.
  var lineWidth: CGFloat? = nil
  /// User-assigned glyph. When present it takes the dot's place in the same
  /// icon column, so areas with an emoji read at a glance and areas without
  /// keep the neutral dot.
  var emoji: String? = nil

  private var resolvedDiameter: CGFloat { diameter ?? Theme.sidebarIconSize * 0.95 }

  var body: some View {
    if let emoji, !emoji.isEmpty {
      Text(emoji)
        .font(.system(size: resolvedDiameter * 0.72))
        .fixedSize()
        .frame(width: resolvedDiameter, height: resolvedDiameter)
    } else {
      Circle()
        .fill(tint)
        .frame(width: resolvedDiameter * 0.42,
               height: resolvedDiameter * 0.42)
        .frame(width: resolvedDiameter, height: resolvedDiameter)
    }
  }
}

struct SidebarProjectRow: View {
  let name: String
  /// Fraction of tasks done (0...1). 0 → empty ring, 1 → filled disc.
  var progress: Double = 0
  // Keep the project completion glyph consistent with the rest of the
  // project/area UI (group headers, area rows, project detail).
  var tint: Color = Theme.inkSecondary
  /// Open task count — muted gray, right-aligned alongside the pie.
  var count: Int = 0

  var body: some View {
    HStack(spacing: Theme.sidebarRowSpacing) {
      ProjectProgressIcon(progress: progress,
                          tint: tint,
                          diameter: nil)
        .frame(width: Theme.sidebarIconSize + 4, alignment: .center)
      Text(name)
        .scaledFont(size: Theme.sidebarTitleSize, weight: Theme.sidebarTitleWeight)
        .foregroundStyle(SidebarRowTitleStyle.color)
      Spacer()
      SidebarCount(count: count)
    }
    .frame(height: Theme.sidebarProjectRowHeight)
    .contentShape(Rectangle())
  }
}

/// The sidebar row title color. macOS uses `.primary` so the native `.sidebar`
/// selection inverts the title (white over the focused accent); iOS keeps the
/// app's fixed ink, since its list selection only shows in edit mode and never
/// recolors row text.
enum SidebarRowTitleStyle {
  static var color: Color {
    #if os(macOS)
    .primary
    #else
    Theme.inkPrimary
    #endif
  }
}

/// Compact project icon: a circular progress bar. A faint track ring sits
/// underneath an accent-tinted arc that begins at 12 o'clock and sweeps
/// clockwise in proportion to completion.
struct ProjectProgressIcon: View {
  let progress: Double
  let tint: Color
  /// Optional override for sizes that don't match the sidebar default
  /// (e.g. the larger glyph next to a project's screen title).
  var diameter: CGFloat? = nil
  var lineWidth: CGFloat? = nil
  /// Optional color for the progress arc when it should read differently
  /// from the track's base `tint` — e.g. a derived, target-less ring dimmed
  /// to half so it never implies a goal the domain doesn't have. Defaults to
  /// `tint`; the faint track always derives from `tint`.
  var arcTint: Color? = nil

  // House ring: small + thick. Shared with the habit/supplement completion
  // ring (`CompletionRateBadge`) so projects and habits read identically.
  // Call sites that want a larger header glyph pass explicit overrides.
  private var resolvedDiameter: CGFloat { diameter ?? 14 }
  private var resolvedLineWidth: CGFloat { lineWidth ?? 2.5 }

  var body: some View {
    // Guard non-finite input explicitly: a NaN/Inf fed into `.trim` /
    // `StrokeStyle` is an uncatchable SwiftUI geometry trap. `max/min` alone
    // don't reliably scrub NaN, so test `isFinite` first.
    let clamped = progress.isFinite ? max(0, min(1, progress)) : 0
    ZStack {
      Circle()
        .stroke(tint.opacity(0.22), lineWidth: resolvedLineWidth)
      Circle()
        .trim(from: 0, to: clamped)
        .stroke(arcTint ?? tint,
                style: StrokeStyle(lineWidth: resolvedLineWidth,
                                   lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: resolvedDiameter, height: resolvedDiameter)
    .padding(resolvedLineWidth / 2)
  }
}

// MARK: - New project sheet (used by ProjectDetailView / create flow)

struct NewProjectSheet: View {
  let areas: [Area]
  /// Pre-selected area when invoked from an area's right-click menu.
  var initialAreaId: String? = nil
  let onCreate: (String, String?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var selectedAreaId: String?

  init(areas: [Area], initialAreaId: String? = nil, onCreate: @escaping (String, String?) -> Void) {
    self.areas = areas
    self.initialAreaId = initialAreaId
    self.onCreate = onCreate
    _selectedAreaId = State(initialValue: initialAreaId)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(RegistryPrompts.textPrompt("newProject").placeholder, text: $title)
        }
        Section("Area") {
          Picker("Area", selection: $selectedAreaId) {
            Text("None").tag(nil as String?)
            ForEach(areas) { area in
              Text(area.title).tag(area.id as String?)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }
      }
      // Grouped style keeps the macOS sheet from collapsing to no height
      // (default-styled Forms report no flexible height) — same rule the
      // shared AdaptiveEditScaffold applies to its sheet branch.
      .formStyle(.grouped)
      .navigationTitle(RegistryPrompts.textPrompt("newProject").title)
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(RegistryPrompts.cancelTitle) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(RegistryPrompts.textPrompt("newProject").confirmTitle) {
            onCreate(title, selectedAreaId)
            dismiss()
          }
          .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
  }
}

/// Sheet/alert/confirmation-dialog stack shared by both sidebar layouts.
/// Pulled out so iPhone (floating Magic Plus → action sheet) and macOS
/// (bottom "+ New List" button) can both trigger the same flows.
/// Rename / delete alerts driven by the sidebar's right-click context menu.
/// Lives in its own modifier so the body of SidebarRootView stays small.
private struct RightClickAlerts: ViewModifier {
  @Binding var renameProjectTarget: Project?
  @Binding var renameAreaTarget: Area?
  @Binding var deleteProjectTarget: Project?
  @Binding var deleteAreaTarget: Area?
  @Binding var renameDraft: String
  let commitRenameProject: (Project, String) -> Void
  let commitRenameArea:    (Area, String) -> Void
  let commitDeleteProject: (Project) -> Void
  let commitDeleteArea:    (Area) -> Void
  let projectDeleteCopy: (Project) -> RegistryPromptCopy
  let areaDeleteCopy: (Area) -> RegistryPromptCopy

  func body(content: Content) -> some View {
    let renameProject = RegistryPrompts.textPrompt("renameProject")
    let renameArea = RegistryPrompts.textPrompt("renameArea")
    return content
      .alert(renameProject.title,
             isPresented: Binding(
              get: { renameProjectTarget != nil },
              set: { if !$0 { renameProjectTarget = nil } })) {
        TextField(renameProject.placeholder, text: $renameDraft)
        Button(renameProject.confirmTitle) {
          if let p = renameProjectTarget { commitRenameProject(p, renameDraft) }
          renameProjectTarget = nil
        }
        Button(RegistryPrompts.cancelTitle, role: .cancel) { renameProjectTarget = nil }
      }
      .alert(renameArea.title,
             isPresented: Binding(
              get: { renameAreaTarget != nil },
              set: { if !$0 { renameAreaTarget = nil } })) {
        TextField(renameArea.placeholder, text: $renameDraft)
        Button(renameArea.confirmTitle) {
          if let a = renameAreaTarget { commitRenameArea(a, renameDraft) }
          renameAreaTarget = nil
        }
        Button(RegistryPrompts.cancelTitle, role: .cancel) { renameAreaTarget = nil }
      }
      // Copy states what goes with the container and where it goes
      // (`RegistryPrompts.deleteArea` / `deleteProject`, shared with the AppKit sheet).
      .confirmationDialog(deleteProjectTarget.map { projectDeleteCopy($0).title } ?? "",
                          isPresented: Binding(
                            get: { deleteProjectTarget != nil },
                            set: { if !$0 { deleteProjectTarget = nil } }),
                          titleVisibility: .visible) {
        Button(deleteProjectTarget.flatMap { projectDeleteCopy($0).confirmTitle } ?? "",
               role: .destructive) {
          if let p = deleteProjectTarget { commitDeleteProject(p) }
          deleteProjectTarget = nil
        }
        Button(RegistryPrompts.cancelTitle, role: .cancel) { deleteProjectTarget = nil }
      } message: {
        Text(deleteProjectTarget.map { projectDeleteCopy($0).message } ?? "")
      }
      .confirmationDialog(deleteAreaTarget.map { areaDeleteCopy($0).title } ?? "",
                          isPresented: Binding(
                            get: { deleteAreaTarget != nil },
                            set: { if !$0 { deleteAreaTarget = nil } }),
                          titleVisibility: .visible) {
        Button(deleteAreaTarget.flatMap { areaDeleteCopy($0).confirmTitle } ?? "",
               role: .destructive) {
          if let a = deleteAreaTarget { commitDeleteArea(a) }
          deleteAreaTarget = nil
        }
        Button(RegistryPrompts.cancelTitle, role: .cancel) { deleteAreaTarget = nil }
      } message: {
        Text(deleteAreaTarget.map { areaDeleteCopy($0).message } ?? "")
      }
  }
}

private struct SidebarSheets: ViewModifier {
  @Binding var showingCreateMenu: Bool
  @Binding var showingNewProject: Bool
  @Binding var showingNewArea: Bool
  @Binding var newAreaName: String
  @Binding var errorMessage: String?
  /// Pre-selected area for "New Project" — set when the user invokes it from
  /// an area's right-click menu. Cleared on sheet dismiss.
  @Binding var newProjectInArea: String?
  let areas: [Area]
  let onNewTodo: () -> Void
  let onCreateProject: (String, String?) -> Void
  let onCreateArea: () -> Void

  func body(content: Content) -> some View {
    content
      .confirmationDialog("Create", isPresented: $showingCreateMenu, titleVisibility: .hidden) {
        Button(RegistryActions.title("app.newTask"))   { onNewTodo() }
        Button(RegistryActions.title("sidebar.newProject")) { showingNewProject = true }
        Button(RegistryActions.title("sidebar.newArea"))    { newAreaName = ""; showingNewArea = true }
        Button(RegistryPrompts.cancelTitle, role: .cancel) {}
      }
      .sheet(isPresented: $showingNewProject, onDismiss: { newProjectInArea = nil }) {
        NewProjectSheet(areas: areas,
                        initialAreaId: newProjectInArea,
                        onCreate: onCreateProject)
          .presentationDetents([.medium])
          .septenaSheetChrome()
      }
      .alert(RegistryPrompts.textPrompt("newArea").title, isPresented: $showingNewArea) {
        TextField(RegistryPrompts.textPrompt("newArea").placeholder, text: $newAreaName)
        Button(RegistryPrompts.textPrompt("newArea").confirmTitle) { onCreateArea() }
        Button(RegistryPrompts.cancelTitle, role: .cancel) { newAreaName = "" }
      }
      .alert(RegistryPrompts.errorTitle, isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )) {
        Button(RegistryPrompts.errorConfirmTitle) { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
  }
}

// MARK: - Task drop into sidebar

/// Drop target for tasks dragged from `TaskListView` onto a sidebar area /
/// project / smart-list row. Pairs with the source via `TaskDragIDs`.
///
/// Active only on a co-visible sidebar+list canvas (`usesPushNavigation` —
/// iPad full-screen and Mac). On iPhone / compact the sidebar is a separate
/// pushed screen, so a task can never be dragged onto a row there: the
/// modifier passes the row through untouched (no highlight machinery, no drop
/// surface), leaving the context-menu "Move to…" as the sole re-home path.
private struct SidebarTaskDrop: ViewModifier {
  enum Kind {
    case area(String)
    case project(String)
    case today

    /// Maps a smart-list route to a drop action, or nil for routes with no
    /// single unambiguous "move here" meaning (Upcoming, Anytime, Logbook).
    init?(route: Route) {
      switch route {
      case .filter(.today):   self = .today
      default:                return nil
      }
    }
  }

  let kind: Kind
  let mutator: TaskMutator
  var onMagicPlusDrop: (() -> Void)? = nil
  @Environment(NavigationState.self) private var nav
  @Environment(\.usesPushNavigation) private var usesPushNavigation
  @Environment(\.modelContext) private var modelContext
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    #if os(iOS) && SEPTASK
    let active = true
    #else
    let active = usesPushNavigation
    #endif
    if active {
      content
        .background(
          // ONE canonical emphasis: a drop-hover reuses the SAME fill as a
          // selected row (`Theme.listSelectionFill`), never a second bespoke
          // accent treatment. See CLAUDE.md "One selection/target language".
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isTargeted ? Theme.listSelectionFill : Color.clear)
            .a11yAnimation(.easeOut(duration: 0.12), value: isTargeted)
        )
        .onDrop(of: [.septenaTaskDragIDs],
                delegate: SidebarTaskDropDelegate(isTargeted: $isTargeted) { ids in
                  guard !ids.isEmpty else { return false }
                  if TaskDragIDs.isNewTaskPayload(ids) {
                    Haptics.tick()
                    if let onMagicPlusDrop {
                      onMagicPlusDrop()
                      return true
                    }
                    switch kind {
                    case .area(let areaId):
                      nav.go(to: .area(id: areaId))
                    case .project(let projectId):
                      nav.go(to: .project(id: projectId))
                    case .today:
                      nav.go(to: .filter(.today))
                    }
                    nav.requestNewTask()
                    return true
                  }
                  // One drop = one undo step (shake / ⌘Z), covering every
                  // dragged row. Today rides in the filing snapshot, so a
                  // drop on Today undoes too. Allowed on compact iPhone too
                  // so two-finger cross-tab/back task drags land on projects.
                  let before = ids.compactMap { LocalCache.task(id: $0, in: modelContext) }
                    .map(TaskUndo.FilingSnapshot.init)
                  rehome(ids)
                  TaskUndo.recordMove(before: before, context: modelContext, mutator: mutator)
                  return true
                })
    } else {
      content
    }
  }

  private func rehome(_ ids: [String]) {
    Haptics.tick()
    switch kind {
    // Batch move preserves the selection's relative order at the top of the
    // destination and clears the agent cue (parity with `SeptaskKitSidebar`).
    case .area(let areaId):
      mutator.moveToList(ids: ids, area: areaId, project: nil, acknowledge: true)
    case .project(let projectId):
      mutator.moveToList(ids: ids, area: nil, project: projectId, acknowledge: true)
    case .today:
      for id in ids { mutator.apply(.putOnToday, to: id) }
    }
  }
}

private struct SidebarTaskDropDelegate: DropDelegate {
  @Binding var isTargeted: Bool
  let perform: (_ ids: [String]) -> Bool

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.septenaTaskDragIDs])
  }

  func dropEntered(info: DropInfo) {
    isTargeted = true
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    isTargeted = true
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    isTargeted = false
  }

  func performDrop(info: DropInfo) -> Bool {
    isTargeted = false
    guard let provider = info.itemProviders(for: [.septenaTaskDragIDs]).first else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.septenaTaskDragIDs.identifier) { data, _ in
      guard let data,
            let payload = try? JSONDecoder().decode(TaskDragIDs.self, from: data),
            !payload.ids.isEmpty
      else { return }
      DispatchQueue.main.async { _ = perform(payload.ids) }
    }
    return true
  }
}

/// Catches Magic Plus drops landing on the Tasks index background (between
/// area cards or below the last section) to create a new Area.
private struct SidebarNewAreaDropDelegate: DropDelegate {
  let onDropNewArea: () -> Void

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.septenaTaskDragIDs])
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .copy)
  }

  func performDrop(info: DropInfo) -> Bool {
    guard let provider = info.itemProviders(for: [.septenaTaskDragIDs]).first else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.septenaTaskDragIDs.identifier) { data, _ in
      guard let data,
            let payload = try? JSONDecoder().decode(TaskDragIDs.self, from: data),
            TaskDragIDs.isNewTaskPayload(payload.ids)
      else { return }
      DispatchQueue.main.async { onDropNewArea() }
    }
    return true
  }
}

/// Installs `SidebarTaskDrop` on a smart-list row only when the route has a
/// meaningful drop action (Today); other routes pass
/// through so they don't show a misleading drop highlight.
private struct SmartListTaskDrop: ViewModifier {
  let route: Route
  let mutator: TaskMutator
  @Environment(NavigationState.self) private var nav

  func body(content: Content) -> some View {
    if let kind = SidebarTaskDrop.Kind(route: route) {
      content
        .modifier(SidebarTaskDrop(kind: kind, mutator: mutator))
        .magicPlusSectionDrop(id: "mp-sidebar-smart-\(route.id)",
                              kind: .taskSection(label: "New Task in \(route.title)")) {
          Haptics.tick()
          nav.go(to: route)
          nav.requestNewTask()
        }
    } else {
      content
    }
  }
}
