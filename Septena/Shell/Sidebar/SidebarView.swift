import SwiftUI
import SwiftData

// compact homepage on iPhone: the root screen IS the sidebar.
// QuickFind + smart lists + areas/projects + Settings. See docs/reference/navigation.md.


struct SidebarRootView: View {
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  @Environment(AreasMutator.self) private var areasMutator
  @Environment(ProjectsMutator.self) private var projectsMutator
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(\.modelContext) private var modelContext

  @State private var areas: [Area]
  @State private var projects: [Project]
  @State private var counts: TasksCounts? = nil

  // Persisted sidebar order — arrays of IDs in display order.
  // Written on every Move Up/Down; applied when loading from cache/server.
  @AppStorage("sidebar.areaOrder")    private var areaOrderData: Data = Data()
  @AppStorage("sidebar.projectOrder") private var projectOrderData: Data = Data()

  // Seed sidebar lists from cache before first render so the sidebar isn't
  // ever blank — areas/projects barely change, so this is effectively the
  // final answer almost every time.
  init() {
    let ctx = LocalStore.shared.container.mainContext
    _areas = State(initialValue: LocalCache.areas(in: ctx))
    _projects = State(initialValue: LocalCache.projects(in: ctx))
    let cachedTasks = LocalCache.allTasks(in: ctx)
    let agg = Self.aggregate(tasks: cachedTasks)
    _counts = State(initialValue: agg.counts)
    _projectProgress = State(initialValue: agg.projectProgress)
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
    sidebarPhone.modifier(rightClickAlerts)
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
      commitDeleteArea:    { a in deleteArea(a) }
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

  private func deleteProject(_ project: Project) {
    Haptics.warning()
    // If the user was viewing the project that just got deleted, bounce them
    // to Today so they aren't stranded on a 404.
    if case .project(let p) = nav.path.last, p.id == project.id {
      nav.path = [.filter(.today)]
    }
    Task {
      do {
        try await projectsMutator.delete(id: project.id)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func deleteArea(_ area: Area) {
    Haptics.warning()
    if case .area(let a) = nav.path.last, a.id == area.id {
      nav.path = [.filter(.today)]
    }
    Task {
      do {
        try await areasMutator.delete(id: area.id)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  /// iPhone / iPad layout: scrolling list with a standard navigation bar and
  /// toolbar `+` menu (Reminders pattern). Settings is reachable from the
  /// top-left "…" overflow menu (and ⌘, on macOS).
  @ViewBuilder
  private var sidebarPhone: some View {
    sidebarScrollContent(topPadding: 12, bottomPadding: 24, spacerMinLength: 40)
    .background(Theme.sidebarBackground)
    // Empty nav bar so iOS renders its default scroll-edge fade as
    // sidebar rows pass behind the top safe area.
    .navigationTitle("")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    // Consistent home-page chrome across Week / Next / Tasks:
    //   • top-left "…" menu (Settings today; room to grow)
    //   • top-right magnifyingglass → Quick Find sheet (also reachable
    //     via the discreet Settings row at the bottom of the sidebar)
    // The floating + bubble that used to sit beside the tab bar has
    // been removed; New Project / New Area remain reachable from the
    // Areas/Projects sheets.
    .toolbar { phoneToolbar }
    .modifier(sidebarBehavior)
  }

  /// macOS layout: full-bleed scroll list. Creation actions live in the
  /// sidebar column's toolbar (Liquid Glass pills on macOS 26 Tahoe);
  /// Settings is the discreet last item in the toolbar's overflow.
  @ViewBuilder
  private var sidebarMac: some View {
    sidebarScrollContent(topPadding: 12, bottomPadding: 12, spacerMinLength: 24)
    // No explicit background — NavigationSplitView renders its sidebar
    // column with the system Liquid Glass material on macOS 26 (Tahoe).
    .toolbar { macToolbar }
    .modifier(sidebarBehavior)
  }

  private func sidebarScrollContent(topPadding: CGFloat,
                                    bottomPadding: CGFloat,
                                    spacerMinLength: CGFloat) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        smartLists
          .padding(.top, topPadding)
          .padding(.bottom, bottomPadding)
        // areasAndProjects renders its own per-section cards
        // (Mimestream-style), so no outer card wrapping here.
        areasAndProjects
        Spacer(minLength: spacerMinLength)
      }
    }
  }

  @ToolbarContentBuilder
  private var phoneToolbar: some ToolbarContent {
    ToolbarItem(placement: .navigation) { phoneMoreMenu }
    ToolbarItem(placement: .primaryAction) { searchButton(accessibilityLabel: "Search") }
  }

  @ToolbarContentBuilder
  private var macToolbar: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) { macCreateMenu }
    ToolbarItem(placement: .primaryAction) { searchButton(help: "Quick Find (⌘K)") }
  }

  private var phoneMoreMenu: some View {
    Menu {
      Button {
        showingNewArea = true
        newAreaName = ""
      } label: {
        Label("New Area", systemImage: "square.stack.3d.up")
      }
      Button {
        showingNewProject = true
      } label: {
        Label("New Project", systemImage: "number")
      }
      Divider()
      Button {
        nav.showSettings = true
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .accessibilityLabel("More")
  }

  private var macCreateMenu: some View {
    Menu {
      Button {
        newAreaName = ""
        showingNewArea = true
      } label: {
        Label("New Area", systemImage: "square.stack.3d.up")
      }
      Button {
        showingNewProject = true
      } label: {
        Label("New Project", systemImage: "number")
      }
    } label: {
      Image(systemName: "plus")
    }
    .menuStyle(.button)
    .help("New Area or Project")
  }

  private func searchButton(accessibilityLabel: String? = nil,
                            help: String? = nil) -> some View {
    Button { nav.showQuickFind = true } label: {
      Image(systemName: "magnifyingglass")
    }
    .modifier(SidebarButtonLabelModifier(accessibilityLabel: accessibilityLabel, help: help))
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
        nav.path = [.filter(.inbox)]
        nav.shouldStartCreating = true
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

  private var smartListSpecs: [SmartListSpec] {
    [
      SmartListSpec(route: .filter(.inbox),
                    icon: "tray.fill", color: .gray,
                    title: "Inbox",
                    count: counts?.inboxCount),
      SmartListSpec(route: .filter(.today),
                    icon: "sun.max.fill", color: Theme.todayAccent,
                    title: "Today",
                    // Total = pinned-today + scheduled/due rolling in. Both
                    // buckets live on Today, so the user-facing count is
                    // the sum (matches the tile/sidebar Today screen).
                    count: counts.map { $0.todayCount + $0.reviewCount }),
      // Next moved out of the Tasks sidebar — it's a top-level tab now.
      SmartListSpec(route: .filter(.upcoming),
                    icon: "calendar", color: .red,
                    title: "Upcoming",
                    count: counts?.upcomingCount),
      SmartListSpec(route: .filter(.unscheduled),
                    icon: "rectangle.stack.fill", color: .orange,
                    title: "Anytime",
                    count: counts?.unscheduledCount),
      SmartListSpec(route: .filter(.someday),
                    icon: "moon.stars.fill", color: .purple,
                    title: "Someday",
                    count: counts?.somedayCount),
      SmartListSpec(route: .filter(.logbook),
                    icon: "checkmark", color: .gray,
                    title: "Completed",
                    count: nil),
    ]
  }

  @ViewBuilder
  private var smartLists: some View {
    #if os(macOS)
    VStack(alignment: .leading, spacing: 2) {
      ForEach(smartListSpecs, id: \.title) { spec in
        sidebarButton(spec.route) {
          SmartListRow(icon: spec.icon,
                       iconColor: spec.color,
                       title: spec.title,
                       count: spec.count)
        }
        .modifier(SmartListTaskDrop(route: spec.route, mutator: taskMutator))
      }
    }
    .padding(.horizontal, Theme.hPadding)
    #else
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)],
              spacing: 12) {
      ForEach(smartListSpecs, id: \.title) { spec in
        Button { selectRoute(spec.route) } label: {
          SmartListTile(icon: spec.icon,
                        iconColor: spec.color,
                        title: spec.title,
                        count: spec.count,
                        isSelected: isSelected(spec.route))
        }
        // .plain on iOS animates a brief scale + tint on the whole label,
        // which read as "the sidebar lifts" on tap. The selected fill is
        // the only feedback we want — InertButtonStyle strips the rest.
        .buttonStyle(InertButtonStyle())
      }
    }
    .padding(.horizontal, Theme.hPadding)
    #endif
  }

  @ViewBuilder
  private func sidebarButton<Content: View>(_ route: Route,
                                            @ViewBuilder label: () -> Content) -> some View {
    // InertButtonStyle (instead of `.plain`) suppresses the brief label-tint
    // flash that macOS applies on click. The persistent selection pill is
    // the only feedback we want.
    Button { selectRoute(route) } label: { label() }
      .buttonStyle(InertButtonStyle())
      .background(rowBackground(for: route))
  }

  private func selectRoute(_ route: Route) {
    Haptics.tap()
    // Tapping a sidebar row replaces the current detail rather than deepening
    // the stack — the sidebar IS the navigation, not a "go back" affordance.
    nav.path = [route]
  }

  /// Which route the sidebar should render as "current". On iPhone the
  /// sidebar IS the home screen, so an empty nav stack means "no row is
  /// current" — returning a Today fallback there would falsely highlight
  /// the Today tile while the user is looking at the overview. iPad/macOS
  /// always have a detail pane showing, so Today is a sensible default.
  private var selectedRoute: Route? {
    #if os(iOS)
    if UIDevice.current.userInterfaceIdiom == .phone {
      return nav.path.last
    }
    #endif
    return nav.path.last ?? .filter(.today)
  }

  /// Stable-id comparison. Default `Route` equality compares the whole
  /// associated value (full `Project` / `Area` struct), which breaks the
  /// highlight as soon as the sidebar reloads a project with any changed
  /// field. We only care about identity here.
  private func isSelected(_ route: Route) -> Bool {
    guard let selectedRoute else { return false }
    switch (selectedRoute, route) {
    case (.filter(let a), .filter(let b)):   return a == b
    case (.next, .next):                     return true
    case (.project(let a), .project(let b)): return a.id == b.id
    case (.area(let a), .area(let b)):       return a.id == b.id
    default:                                 return false
    }
  }

  /// Single highlight rule: selected → light accent tint pill, otherwise
  /// transparent. Same shape and color logic as the task-row selection pill.
  /// iOS / iPadOS sidebar rows sit inside Mimestream-style cards on the
  /// `Theme.cardSurface` background, so the highlight needs a stronger fill
  /// to read as "this is the current screen". macOS keeps the lighter
  /// accent on its bare sidebar column.
  @ViewBuilder
  private func rowBackground(for route: Route) -> some View {
    #if os(iOS)
    // Highlight sits inside the section card's inner padding — no negative
    // bleed, and a larger corner so it reads as a nested pill rather than a
    // separate rectangle clashing with the card's 18pt rounding.
    let fill: Color = isSelected(route) ? theme.accent.opacity(0.18) : .clear
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(fill)
      .padding(.horizontal, -6)
    #else
    let fill: Color = isSelected(route) ? theme.accent.opacity(0.15) : .clear
    RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
      .fill(fill)
      .padding(.horizontal, -4)
    #endif
  }

  // MARK: - Areas and projects

  @ViewBuilder
  private var areasAndProjects: some View {
    // Mimestream / iOS Mail pattern: each grouping is a section with a
    // header above and a card below containing that group's rows.
    // - Top-level projects (no area) → one card, no header
    // - Each area → header above (tappable for area detail) + card
    //   containing that area's projects
    VStack(alignment: .leading, spacing: 12) {
      if !topLevelProjects.isEmpty {
        topLevelProjectsSection
      }
      ForEach(areas) { area in
        areaSection(area)
      }
    }
  }

  // MARK: - Per-section renderers

  @ViewBuilder
  private var topLevelProjectsSection: some View {
    sectionCard {
      ForEach(Array(topLevelProjects.enumerated()), id: \.element.id) { idx, project in
        projectRow(project, parent: nil)
        if idx < topLevelProjects.count - 1 { inCardDivider }
      }
    }
  }

  @ViewBuilder
  private func areaSection(_ area: Area) -> some View {
    let projectsInArea = projects.filter { $0.area == area.id && $0.status == .active }

    // Each area is its own card (Mimestream-style 'bubble'). The area
    // row sits at the top of the card, projects underneath. Areas
    // without projects still get a card so every area visually reads
    // as the same kind of container.
    sectionCard {
      sidebarButton(.area(area)) {
        SidebarAreaRow(name: area.title, count: areaOpenCount[area.id] ?? 0)
      }
      #if os(iOS)
      .contextMenu {
        areaMenu(area)
      } preview: {
        SidebarAreaRow(name: area.title, count: areaOpenCount[area.id] ?? 0)
          .padding(.horizontal, 14).padding(.vertical, 6)
          .background(Theme.cardSurface)
      }
      #else
      .contextMenu { areaMenu(area) }
      .modifier(SidebarTaskDrop(kind: .area(area.id), mutator: taskMutator))
      #endif

      if !projectsInArea.isEmpty {
        inCardDivider
        ForEach(Array(projectsInArea.enumerated()), id: \.element.id) { idx, project in
          projectRow(project, parent: area.id)
          if idx < projectsInArea.count - 1 { inCardDivider }
        }
      }
    }
  }

  /// Card wrapper for a section's rows — Mimestream-style: rounded
  /// surface on iOS, bare rows on macOS (matches the platform's native
  /// sidebar conventions).
  @ViewBuilder
  private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    #if os(iOS)
    VStack(alignment: .leading, spacing: 0) { content() }
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(
        Theme.cardSurface,
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )
      .padding(.horizontal, sectionCardHPad)
    #else
    VStack(alignment: .leading, spacing: 0) { content() }
      .padding(.horizontal, Theme.hPadding)
    #endif
  }

  // Horizontal margin for section cards. iOS uses a Mimestream-style
  // inset; macOS lines up with the sidebar's standard hPadding.
  #if os(iOS)
  private var sectionCardHPad: CGFloat { 20 }
  #else
  private var sectionCardHPad: CGFloat { Theme.hPadding }
  #endif

  @ViewBuilder
  private func projectRow(_ project: Project, parent: String?) -> some View {
    sidebarButton(.project(project)) {
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
    .modifier(SidebarTaskDrop(kind: .project(project.id), mutator: taskMutator))
    #endif
  }

  // MARK: - Context menus

  @ViewBuilder
  private func projectMenu(_ project: Project) -> some View {
    Button {
      renameDraft = project.title
      renameProjectTarget = project
    } label: {
      Label("Rename", systemImage: "pencil")
    }
    let siblings = projects.filter { $0.area == project.area && $0.status == .active }
    if let idx = siblings.firstIndex(where: { $0.id == project.id }) {
      Divider()
      Button {
        reorderProject(project.id, before: siblings[idx - 1].id, parent: project.area)
      } label: {
        Label("Move Up", systemImage: "chevron.up")
      }
      .disabled(idx == 0)
      Button {
        let next = siblings[idx + 1]
        reorderProject(next.id, before: project.id, parent: project.area)
      } label: {
        Label("Move Down", systemImage: "chevron.down")
      }
      .disabled(idx == siblings.count - 1)
    }
    Divider()
    Button(role: .destructive) {
      deleteProjectTarget = project
    } label: {
      Label("Delete Project", systemImage: "trash")
    }
  }

  @ViewBuilder
  private func areaMenu(_ area: Area) -> some View {
    Button {
      renameDraft = area.title
      renameAreaTarget = area
    } label: {
      Label("Rename", systemImage: "pencil")
    }
    Button {
      newProjectInArea = area.id
      showingNewProject = true
    } label: {
      Label("New Project", systemImage: "plus.square")
    }
    if let idx = areas.firstIndex(where: { $0.id == area.id }) {
      Divider()
      Button {
        reorderArea(area.id, before: areas[idx - 1].id)
      } label: {
        Label("Move Up", systemImage: "chevron.up")
      }
      .disabled(idx == 0)
      Button {
        let next = areas[idx + 1]
        reorderArea(next.id, before: area.id)
      } label: {
        Label("Move Down", systemImage: "chevron.down")
      }
      .disabled(idx == areas.count - 1)
    }
    Divider()
    Button(role: .destructive) {
      deleteAreaTarget = area
    } label: {
      Label("Delete Area", systemImage: "trash")
    }
  }

  /// Thin hairline shown between consecutive rows inside the iPhone
  /// areas/projects card. Indented to the left edge of the row text
  /// (past the icon column) so it lines up with the system iOS list
  /// separator style. macOS sidebar reads cleanly without inter-row
  /// hairlines (Mimestream macOS doesn't draw them either), so we
  /// render nothing there.
  @ViewBuilder
  private var inCardDivider: some View {
    #if os(iOS)
    Rectangle()
      .fill(Color(uiColor: .opaqueSeparator).opacity(0.6))
      .frame(height: 0.5)
      .padding(.leading, Theme.checkboxTap + Theme.iconTextGap)
    #else
    EmptyView()
    #endif
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
    areas = next
    areaOrderData = (try? JSONEncoder().encode(next.map(\.id))) ?? Data()
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
    projects = next
    projectOrderData = (try? JSONEncoder().encode(next.map(\.id))) ?? Data()
  }

  private var topLevelProjects: [Project] {
    projects.filter { $0.area == nil && $0.status == .active }
  }

  // MARK: - Load

  private func load() async {
    // Paint sidebar from cache immediately — areas / projects rarely change,
    // and tile counts can be rebuilt from the SwiftData task cache without a
    // round-trip. The server response overwrites both below.
    let cachedAreas = applyStoredOrder(to: LocalCache.areas(in: modelContext))
    let cachedProjects = applyStoredProjectOrder(to: LocalCache.projects(in: modelContext))
    if !cachedAreas.isEmpty { areas = cachedAreas }
    if !cachedProjects.isEmpty { projects = cachedProjects }
    let cachedTasks = LocalCache.allTasks(in: modelContext)
    if !cachedTasks.isEmpty { apply(aggregate: Self.aggregate(tasks: cachedTasks)) }
    // CloudKit is the only backend. LocalCache is authoritative —
    // CKSyncEngine keeps SwiftData fresh.
    async let c = TaskReads.counts(context: modelContext)
    async let all = TaskReads.list(view: "all", context: modelContext)
    areas = applyStoredOrder(to: LocalCache.areas(in: modelContext))
    projects = applyStoredProjectOrder(to: LocalCache.projects(in: modelContext))
    let serverCounts = await c
    let items = await all.items
    var agg = Self.aggregate(tasks: items)
    // Per-smart-list counts come from LocalCache via TaskReads.counts.
    // Per-project / per-area roll-ups stay from the local aggregate.
    agg.counts = serverCounts
    apply(aggregate: agg)
  }

  private struct Aggregate {
    var counts: TasksCounts
    var projectProgress: [String: Double]
    var projectOpenCount: [String: Int]
    var areaOpenCount: [String: Int]
  }

  /// Single-pass roll-up over a task list. Called twice per load: once over
  /// the local cache for instant paint, once over the server response.
  private static func aggregate(tasks: [SeptenaTask]) -> Aggregate {
    // Project progress = done / (done + open). Cancelled doesn't count
    // toward either side of the ratio.
    var done: [String: Int] = [:]
    var total: [String: Int] = [:]
    var projOpen: [String: Int] = [:]
    // Area count = direct-in-area tasks ONLY. Nested projects render as
    // their own rows, so rolling them up would double-count.
    var areaDirectOpen: [String: Int] = [:]
    var inbox = 0, todayN = 0, upcoming = 0, unscheduled = 0, open = 0, someday = 0
    let today = SeptenaDate.today
    for t in tasks {
      if t.status == .open { open += 1 }
      if t.status == .someday { someday += 1 }
      if let pid = t.project {
        switch t.status {
        case .done:                 done[pid, default: 0] += 1; total[pid, default: 0] += 1
        case .open:                 total[pid, default: 0] += 1; projOpen[pid, default: 0] += 1
        case .cancelled, .someday:  break
        }
      } else if let aid = t.area, t.status == .open {
        areaDirectOpen[aid, default: 0] += 1
      }
      guard t.status == .open else { continue }
      // Smart-list buckets — mirror LocalCache.tasks(in:filter:) semantics.
      if t.project == nil, t.area == nil,
         t.scheduled == nil, t.due == nil, !t.today {
        inbox += 1
      }
      if t.today { todayN += 1 }
      else if let s = t.scheduled, s <= today { todayN += 1 }
      else if let d = t.due, d <= today { todayN += 1 }
      if !t.today {
        if let s = t.scheduled, s > today { upcoming += 1 }
        else if let d = t.due, d > today { upcoming += 1 }
      }
      if !t.today, t.scheduled == nil, t.due == nil { unscheduled += 1 }
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
                          inboxCount: inbox, upcomingCount: upcoming,
                          unscheduledCount: unscheduled,
                          somedayCount: someday, openCount: open),
      projectProgress: progress,
      projectOpenCount: projOpen,
      areaOpenCount: areaDirectOpen)
  }

  private func apply(aggregate agg: Aggregate) {
    counts = agg.counts
    projectProgress = agg.projectProgress
    projectOpenCount = agg.projectOpenCount
    areaOpenCount = agg.areaOpenCount
  }

  private func applyStoredOrder(to loaded: [Area]) -> [Area] {
    guard let ids = try? JSONDecoder().decode([String].self, from: areaOrderData),
          !ids.isEmpty else { return loaded }
    let byId = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    let ordered = ids.compactMap { byId[$0] }
    let new = loaded.filter { !ids.contains($0.id) }
    return ordered + new
  }

  private func applyStoredProjectOrder(to loaded: [Project]) -> [Project] {
    guard let ids = try? JSONDecoder().decode([String].self, from: projectOrderData),
          !ids.isEmpty else { return loaded }
    let byId = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    let ordered = ids.compactMap { byId[$0] }
    let new = loaded.filter { !ids.contains($0.id) }
    return ordered + new
  }
}
// MARK: - Sidebar primitives

struct SmartListRow: View {
  let icon: String
  /// The list's color — fills the rounded-square icon container behind a
  /// white SF Symbol (Reminders pattern).
  let iconColor: Color
  let title: String
  /// Muted gray count — neutral signal for total rows on this list.
  var count: Int? = nil

  var body: some View {
    HStack(spacing: 10) {
      ColoredGlyph(icon: icon, color: iconColor,
                   size: Theme.sidebarIconSize + 4)
      Text(title)
        .font(.body)
        .foregroundStyle(.primary)
      Spacer()
      if let n = count, n > 0 {
        Text("\(n)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .frame(height: Theme.sidebarSmartRowHeight)
    .contentShape(Rectangle())
  }
}

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
      .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
        reload()
      }
      .onReceive(NotificationCenter.default.publisher(for: .septenaStructureChanged)) { _ in
        reload()
      }
  }
}

private struct SidebarButtonLabelModifier: ViewModifier {
  let accessibilityLabel: String?
  let help: String?

  func body(content: Content) -> some View {
    if let accessibilityLabel {
      if let help {
        content
          .accessibilityLabel(accessibilityLabel)
          .help(help)
      } else {
        content
          .accessibilityLabel(accessibilityLabel)
      }
    } else if let help {
      content.help(help)
    } else {
      content
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
  /// When true, the tile renders with a tinted outline + slight fill so the
  /// iPad sidebar shows which smart list the detail pane is currently on.
  /// iPhone never sees a selected tile (tapping pushes onto the stack), but
  /// it costs nothing to honor here.
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
        ZStack {
          Circle().fill(iconColor)
          Image(systemName: icon)
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(.white)
        }
        .frame(width: 26, height: 26)
        Spacer()
        countCluster
      }
      Spacer(minLength: 6)
      Text(title)
        .scaledFont(size: 15, weight: .regular)
        .foregroundStyle(.primary)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(isSelected ? iconColor.opacity(0.18) : Theme.cardSurface)
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
        .foregroundStyle(.primary)
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

/// Soft tinted section icon — the homepage treatment: an accent-tinted
/// rounded square with the SF Symbol drawn *in the accent color* (not a
/// white glyph on a saturated fill, which is `ColoredGlyph`). Shared by
/// the Dense/Heatmap homepage rows and the Settings section rows so the
/// same section reads identically in both places. Defaults match the
/// homepage exactly (28pt square, 7pt corner, 14pt semibold glyph).
struct SectionGlyph: View {
  let icon: String
  let accent: Color
  var size: CGFloat = 28
  /// Inner SF Symbol size as a fraction of `size`. Default `0.5` is the
  /// homepage's 14-on-28 glyph.
  var glyphRatio: CGFloat = 0.5

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
      .fill(accent.opacity(0.18))
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: icon)
          .scaledFont(size: size * glyphRatio, weight: .semibold)
          .foregroundStyle(accent)
      }
  }
}

struct SidebarAreaRow: View {
  let name: String
  /// Open task count rolled up across the area (loose + projects in it).
  var count: Int = 0

  var body: some View {
    HStack(spacing: Theme.sidebarRowSpacing) {
      AreaIcon()
        .frame(width: Theme.sidebarIconSize + 4, alignment: .center)
      Text(name)
        .scaledFont(size: Theme.sidebarAreaTitleSize, weight: .semibold)
        .foregroundStyle(Theme.inkPrimary)
      Spacer()
      if count > 0 {
        Text("\(count)")
          .scaledFont(size: 12, weight: .regular)
          .foregroundStyle(Theme.inkSecondary.opacity(0.6))
      }
      SidebarRowChevron()
    }
    .frame(height: Theme.sidebarRowHeight)
    .contentShape(Rectangle())
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

  private var resolvedDiameter: CGFloat { diameter ?? Theme.sidebarIconSize * 0.95 }

  var body: some View {
    Circle()
      .fill(tint)
      .frame(width: resolvedDiameter * 0.42,
             height: resolvedDiameter * 0.42)
      .frame(width: resolvedDiameter, height: resolvedDiameter)
  }
}

struct SidebarProjectRow: View {
  let name: String
  /// Fraction of tasks done (0...1). 0 → empty ring, 1 → filled disc.
  var progress: Double = 0
  var tint: Color = Theme.iconMuted
  /// Open task count — muted gray, right-aligned alongside the pie.
  var count: Int = 0

  var body: some View {
    HStack(spacing: Theme.sidebarRowSpacing) {
      ProjectProgressIcon(progress: progress, tint: tint)
        .frame(width: Theme.sidebarIconSize + 4, alignment: .center)
      Text(name)
        .scaledFont(size: Theme.sidebarTitleSize, weight: Theme.sidebarTitleWeight)
        .foregroundStyle(Theme.inkPrimary)
      Spacer()
      if count > 0 {
        Text("\(count)")
          .scaledFont(size: 12, weight: .regular)
          .foregroundStyle(Theme.inkSecondary.opacity(0.6))
      }
      SidebarRowChevron()
    }
    .frame(height: Theme.sidebarProjectRowHeight)
    .contentShape(Rectangle())
  }
}

/// Trailing chevron used at the end of sidebar list rows. iOS Mail /
/// Reminders / Settings put a disclosure indicator at the end of every
/// navigable row, and the iPhone sidebar matches that. macOS sidebars
/// (Mail.app, Reminders.app) don't draw chevrons — the persistent
/// selection pill is the only "this row is the current screen" cue
/// needed — so we render nothing there.
struct SidebarRowChevron: View {
  var body: some View {
    #if os(iOS)
    Image(systemName: "chevron.right")
      .scaledFont(size: 12, weight: .semibold)
      .foregroundStyle(.tertiary)
    #else
    EmptyView()
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

  // House ring: small + thick. Shared with the habit/supplement completion
  // ring (`CompletionRateBadge`) so projects and habits read identically.
  // Call sites that want a larger header glyph pass explicit overrides.
  private var resolvedDiameter: CGFloat { diameter ?? 14 }
  private var resolvedLineWidth: CGFloat { lineWidth ?? 2.5 }

  var body: some View {
    let clamped = max(0, min(1, progress))
    ZStack {
      Circle()
        .stroke(tint.opacity(0.22), lineWidth: resolvedLineWidth)
      Circle()
        .trim(from: 0, to: clamped)
        .stroke(tint,
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
          TextField("Project title", text: $title)
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
      .navigationTitle("New Project")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
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

  func body(content: Content) -> some View {
    content
      .alert("Rename Project",
             isPresented: Binding(
              get: { renameProjectTarget != nil },
              set: { if !$0 { renameProjectTarget = nil } })) {
        TextField("Project name", text: $renameDraft)
        Button("Save") {
          if let p = renameProjectTarget { commitRenameProject(p, renameDraft) }
          renameProjectTarget = nil
        }
        Button("Cancel", role: .cancel) { renameProjectTarget = nil }
      }
      .alert("Rename Area",
             isPresented: Binding(
              get: { renameAreaTarget != nil },
              set: { if !$0 { renameAreaTarget = nil } })) {
        TextField("Area name", text: $renameDraft)
        Button("Save") {
          if let a = renameAreaTarget { commitRenameArea(a, renameDraft) }
          renameAreaTarget = nil
        }
        Button("Cancel", role: .cancel) { renameAreaTarget = nil }
      }
      .alert("Delete \(deleteProjectTarget?.title ?? "Project")?",
             isPresented: Binding(
              get: { deleteProjectTarget != nil },
              set: { if !$0 { deleteProjectTarget = nil } })) {
        Button("Delete", role: .destructive) {
          if let p = deleteProjectTarget { commitDeleteProject(p) }
          deleteProjectTarget = nil
        }
        Button("Cancel", role: .cancel) { deleteProjectTarget = nil }
      } message: {
        Text("Tasks in this project will be moved to the inbox.")
      }
      .alert("Delete \(deleteAreaTarget?.title ?? "Area")?",
             isPresented: Binding(
              get: { deleteAreaTarget != nil },
              set: { if !$0 { deleteAreaTarget = nil } })) {
        Button("Delete", role: .destructive) {
          if let a = deleteAreaTarget { commitDeleteArea(a) }
          deleteAreaTarget = nil
        }
        Button("Cancel", role: .cancel) { deleteAreaTarget = nil }
      } message: {
        Text("Projects in this area will be detached but not deleted.")
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
        Button("New To-Do")   { onNewTodo() }
        Button("New Project") { showingNewProject = true }
        Button("New Area")    { newAreaName = ""; showingNewArea = true }
        Button("Cancel", role: .cancel) {}
      }
      .sheet(isPresented: $showingNewProject, onDismiss: { newProjectInArea = nil }) {
        NewProjectSheet(areas: areas,
                        initialAreaId: newProjectInArea,
                        onCreate: onCreateProject)
          .presentationDetents([.medium])
          .septenaSheetChrome()
      }
      .alert("New Area", isPresented: $showingNewArea) {
        TextField("Area name", text: $newAreaName)
        Button("Create") { onCreateArea() }
        Button("Cancel", role: .cancel) { newAreaName = "" }
      }
      .alert("Error", isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )) {
        Button("OK") { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
  }
}

// MARK: - Task drop into sidebar (macOS)

#if os(macOS)
/// Drop target for a task dragged from `TaskListView` (which publishes its
/// id via `.draggable(task.id)`) onto a sidebar area / project / smart-list
/// row. Pairs with the source via the Transferable `String` payload.
private struct SidebarTaskDrop: ViewModifier {
  enum Kind {
    case area(String)
    case project(String)
    case today
    case inbox
    case someday

    /// Maps a smart-list route to a drop action, or nil for routes with no
    /// single unambiguous "move here" meaning (Upcoming, Anytime, Logbook).
    init?(route: Route) {
      switch route {
      case .filter(.today):   self = .today
      case .filter(.inbox):   self = .inbox
      case .filter(.someday): self = .someday
      default:                return nil
      }
    }
  }

  let kind: Kind
  let mutator: TaskMutator
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.accentColor.opacity(isTargeted ? 0.18 : 0))
          .animation(.easeOut(duration: 0.12), value: isTargeted)
      )
      .dropDestination(for: String.self) { ids, _ in
        guard !ids.isEmpty else { return false }
        for id in ids { rehome(id) }
        return true
      } isTargeted: { isTargeted = $0 }
  }

  private func rehome(_ id: String) {
    Haptics.tick()
    switch kind {
    case .area(let areaId):
      mutator.moveToArea(id: id, area: areaId)
      mutator.moveToProject(id: id, project: nil)
    case .project(let projectId):
      mutator.moveToProject(id: id, project: projectId)
    case .today:
      mutator.moveToToday(id: id, today: true)
    case .someday:
      mutator.moveToSomeday(id: id)
    case .inbox:
      // Inbox = no routing at all: clear schedule, deadline, area, project, and
      // the Today pin. A leftover deadline would keep the task out of Inbox
      // (the filter requires due == nil) and stuck in Today, so we clear it too.
      // Drop the pin LAST: `setDue(nil)` re-pins a still-Today row, so ending on
      // `moveToToday(false)` guarantees the task actually lands in Inbox.
      mutator.schedule(id: id, date: nil)
      mutator.setDue(id: id, date: nil)
      mutator.moveToArea(id: id, area: nil)
      mutator.moveToProject(id: id, project: nil)
      mutator.moveToToday(id: id, today: false)
    }
  }
}

/// Installs `SidebarTaskDrop` on a smart-list row only when the route has a
/// meaningful drop action (Today / Inbox / Someday); other routes pass
/// through so they don't show a misleading drop highlight.
private struct SmartListTaskDrop: ViewModifier {
  let route: Route
  let mutator: TaskMutator
  func body(content: Content) -> some View {
    if let kind = SidebarTaskDrop.Kind(route: route) {
      content.modifier(SidebarTaskDrop(kind: kind, mutator: mutator))
    } else {
      content
    }
  }
}
#endif
