import SwiftUI
import UniformTypeIdentifiers

// compact homepage on iPhone: the root screen IS the sidebar.
// QuickFind + smart lists + areas/projects + Settings. See docs/reference/navigation.md.

// MARK: - Sidebar drag identifier

/// Single Transferable type for all sidebar drags. The `kind` discriminator
/// lets the drop handler reject mismatches (an area dropped on a project
/// row, a top-level project dropped inside an area, etc.) without relying
/// on registered UTTypes. `parent` is the area id for projects-in-area, nil
/// for top-level projects, and ignored for areas — drop handlers use it to
/// scope reorders to the same group.
struct SidebarDragID: Codable, Hashable, Transferable {
  enum Kind: String, Codable, Hashable { case area, project }
  let kind: Kind
  let id: String
  let parent: String?

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .data)
  }

  static func area(_ id: String) -> SidebarDragID {
    SidebarDragID(kind: .area, id: id, parent: nil)
  }
  static func project(_ id: String, parent: String?) -> SidebarDragID {
    SidebarDragID(kind: .project, id: id, parent: parent)
  }
}

struct SidebarRootView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme

  @State private var areas: [Area] = []
  @State private var projects: [Project] = []
  @State private var counts: TasksCounts? = nil
  /// Fraction of each project's tasks that are done (0...1). Drives the
  /// pie-slice icon in SidebarProjectRow.
  @State private var projectProgress: [String: Double] = [:]
  /// Open task count per project — drives the muted gray count on each
  /// SidebarProjectRow.
  @State private var projectOpenCount: [String: Int] = [:]
  /// Open task count per area, rolling up loose-in-area + tasks in that
  /// area's projects.
  @State private var areaOpenCount: [String: Int] = [:]
  /// Open task count for the "Next" smart list. Fetched via view=next since
  /// `/counts` doesn't expose it directly.
  @State private var nextCount: Int? = nil
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
        _ = try await client.updateProject(id: project.id, title: trimmed)
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
    var next = areas
    if let idx = next.firstIndex(where: { $0.id == area.id }) {
      next[idx].title = trimmed
    }
    Task {
      do {
        areas = try await client.replaceAreas(next)
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
        try await client.deleteProject(id: project.id)
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
    let next = areas.filter { $0.id != area.id }
    Task {
      do {
        areas = try await client.replaceAreas(next)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  /// iPhone / iPad layout: scrolling list with a standard navigation bar and
  /// toolbar `+` menu (Reminders pattern). Settings remains reachable from
  /// the discreet last row of the scroll.
  @ViewBuilder
  private var sidebarPhone: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        smartLists.padding(.top, 12).padding(.bottom, 20)
        areasAndProjects
          .padding(.horizontal, 14)
          .padding(.vertical, 6)
          .background(
            Theme.cardSurface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
          )
          .padding(.horizontal, 20)
        settingsRow.padding(.top, 24)
        Spacer(minLength: 40)
      }
    }
    .background(Theme.sidebarBackground)
    .navigationTitle("Septena")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button {
            // Route through .filter(.inbox) so the inline editor mounts
            // on a known list — Sidebar root has no TaskListView, so
            // setting the trigger alone wouldn't open the editor.
            nav.path = [.filter(.inbox)]
            nav.shouldStartCreating = true
          } label: {
            Label("New To-Do", systemImage: "plus.circle")
          }
          Button { showingNewProject = true } label: {
            Label("New Project", systemImage: "number")
          }
          Button { newAreaName = ""; showingNewArea = true } label: {
            Label("New Area", systemImage: "square.stack.3d.up")
          }
        } label: {
          Image(systemName: "plus")
        }
      }
    }
    .modifier(SidebarSheets(
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
      onCreateArea: { createArea() }
    ))
    .task { await load() }
    .refreshable { await load() }
    // Auto-refresh counts whenever a task / project / area mutation happens
    // anywhere in the app. SeptenaClient fans this out from postJSON /
    // putJSON / deleteRaw, so this catches creates, completions, moves,
    // schedule changes, Reminders imports, area edits, etc.
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      Task { await load() }
    }
  }

  /// macOS layout: full-bleed scroll list. Creation actions live in the
  /// sidebar column's toolbar (Liquid Glass pills on macOS 26 Tahoe);
  /// Settings is the discreet last item in the toolbar's overflow.
  @ViewBuilder
  private var sidebarMac: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        smartLists.padding(.top, 12).padding(.bottom, 16)
        areasAndProjects
          .padding(.horizontal, Theme.hPadding)
        Spacer(minLength: 24)
      }
    }
    // No explicit background — NavigationSplitView renders its sidebar
    // column with the system Liquid Glass material on macOS 26 (Tahoe).
    .toolbar {
      // Primary action on the sidebar column: a Menu offering both list
      // shapes (Project under an Area, or top-level Project, or Area).
      // System styles this as a Liquid Glass pill on macOS 26.
      ToolbarItem(placement: .primaryAction) {
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
      // Settings — kept reachable from the sidebar's chrome rather than
      // tucked at the bottom of the list.
      ToolbarItem(placement: .automatic) {
        Button {
          nav.path = [.settings]
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
        .help("Settings")
      }
    }
    .modifier(SidebarSheets(
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
      onCreateArea: { createArea() }
    ))
    .task { await load() }
    .refreshable { await load() }
    // Auto-refresh counts whenever a task / project / area mutation happens
    // anywhere in the app. SeptenaClient fans this out from postJSON /
    // putJSON / deleteRaw, so this catches creates, completions, moves,
    // schedule changes, Reminders imports, area edits, etc.
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      Task { await load() }
    }
  }

  // MARK: - Create handlers

  private func createProject(title: String, areaId: String?) {
    let t = title.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return }
    Task {
      do {
        _ = try await client.createProject(title: t, area: areaId)
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
    let id = name.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .joined(separator: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let next = areas + [Area(id: id, title: name, context: nil)]
    Task {
      do {
        areas = try await client.replaceAreas(next)
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
    var overdueBadge: Int? = nil
  }

  private var smartListSpecs: [SmartListSpec] {
    [
      SmartListSpec(route: .filter(.inbox),
                    icon: "tray.fill", color: .gray,
                    title: "Inbox",
                    count: counts?.inboxCount),
      SmartListSpec(route: .filter(.today),
                    icon: "sun.max.fill", color: .blue,
                    title: "Today",
                    count: counts?.todayCount,
                    overdueBadge: counts?.reviewCount),
      SmartListSpec(route: .next,
                    icon: "arrow.right", color: .green,
                    title: "Next",
                    count: nextCount),
      SmartListSpec(route: .filter(.upcoming),
                    icon: "calendar", color: .red,
                    title: "Upcoming",
                    count: counts?.upcomingCount),
      SmartListSpec(route: .filter(.unscheduled),
                    icon: "rectangle.stack.fill", color: .orange,
                    title: "Unscheduled",
                    count: counts?.unscheduledCount),
      SmartListSpec(route: .filter(.logbook),
                    icon: "checkmark.circle.fill", color: .gray,
                    title: "Logbook",
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
                       overdueBadge: spec.overdueBadge,
                       count: spec.count)
        }
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
                        count: spec.count)
        }
        .buttonStyle(.plain)
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
      .animation(.easeOut(duration: 0.15), value: nav.path)
  }

  private func selectRoute(_ route: Route) {
    Haptics.tap()
    // Tapping a sidebar row replaces the current detail rather than deepening
    // the stack — the sidebar IS the navigation, not a "go back" affordance.
    nav.path = [route]
  }

  /// Which route the sidebar should render as "current".
  private var selectedRoute: Route {
    nav.path.last ?? .filter(.today)
  }

  /// Stable-id comparison. Default `Route` equality compares the whole
  /// associated value (full `Project` / `Area` struct), which breaks the
  /// highlight as soon as the sidebar reloads a project with any changed
  /// field. We only care about identity here.
  private func isSelected(_ route: Route) -> Bool {
    switch (selectedRoute, route) {
    case (.filter(let a), .filter(let b)):   return a == b
    case (.next, .next):                     return true
    case (.settings, .settings):             return true
    case (.project(let a), .project(let b)): return a.id == b.id
    case (.area(let a), .area(let b)):       return a.id == b.id
    default:                                 return false
    }
  }

  /// Single highlight rule: selected → light accent tint pill, otherwise
  /// transparent. Same shape and color logic as the task-row selection pill.
  @ViewBuilder
  private func rowBackground(for route: Route) -> some View {
    let fill: Color = isSelected(route) ? theme.accent.opacity(0.15) : .clear
    RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
      .fill(fill)
      .padding(.horizontal, -4)
  }

  // MARK: - Areas and projects

  @ViewBuilder
  private var areasAndProjects: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Top-level projects (no area). Each row is both draggable and a
      // drop target — drop on row = position before it. The trailing zone
      // beneath the last row handles "drop at end" of the top-level group.
      ForEach(topLevelProjects) { project in
        projectRowDraggable(project, parent: nil)
      }
      if !topLevelProjects.isEmpty {
        endOfGroupDropZone(parent: nil)
      }

      ForEach(Array(areas.enumerated()), id: \.element.id) { idx, area in
        // Skip the divider at the very top of the card — i.e. when this
        // area is the first child AND there are no top-level projects
        // above it.
        let showDivider = idx > 0 || !topLevelProjects.isEmpty
        areaBlock(area, showDivider: showDivider)
      }
      // Trailing area drop zone — lets the user drop an area at the very
      // end of the list (no target row available there otherwise).
      if !areas.isEmpty {
        Color.clear
          .frame(height: 18)
          .contentShape(Rectangle())
          .dropDestination(for: SidebarDragID.self) { items, _ in
            guard let drag = items.first, drag.kind == .area else { return false }
            reorderArea(drag.id, toEnd: true)
            return true
          }
      }
    }
  }

  /// Project row in either top-level or within-area context. `parent`
  /// scopes drag-drop so projects can only be reordered within the same
  /// group; cross-group drops (top-level ↔ area) are rejected.
  @ViewBuilder
  private func projectRowDraggable(_ project: Project, parent: String?) -> some View {
    sidebarButton(.project(project)) {
      SidebarProjectRow(name: project.title,
                        progress: projectProgress[project.id] ?? 0,
                        count: projectOpenCount[project.id] ?? 0)
    }
    .contextMenu { projectMenu(project) }
    .draggable(SidebarDragID.project(project.id, parent: parent)) {
      Text(project.title)
        .font(.system(size: Theme.sidebarTitleSize, weight: Theme.sidebarTitleWeight))
        .foregroundStyle(Theme.inkPrimary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
    .dropDestination(for: SidebarDragID.self) { items, _ in
      guard let drag = items.first,
            drag.kind == .project,
            drag.parent == parent,           // same group only
            drag.id != project.id else { return false }
      reorderProject(drag.id, before: project.id, parent: parent)
      return true
    }
  }

  /// Trailing drop zone for "put at the end of this project group". Sized
  /// generously so the user doesn't have to aim at a hairline.
  @ViewBuilder
  private func endOfGroupDropZone(parent: String?) -> some View {
    Color.clear
      .frame(height: 6)
      .contentShape(Rectangle())
      .dropDestination(for: SidebarDragID.self) { items, _ in
        guard let drag = items.first,
              drag.kind == .project,
              drag.parent == parent else { return false }
        reorderProject(drag.id, toEnd: true, parent: parent)
        return true
      }
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
    Divider()
    Button(role: .destructive) {
      deleteAreaTarget = area
    } label: {
      Label("Delete Area", systemImage: "trash")
    }
  }

  @ViewBuilder
  private func areaBlock(_ area: Area, showDivider: Bool = true) -> some View {
    let projectsInArea = projects.filter { $0.area == area.id && $0.status == .active }

    VStack(alignment: .leading, spacing: 0) {
      // Divider sits at the midpoint between the previous block's last row
      // and this area's header — equal whitespace top and bottom. Slightly
      // more contrasty than the default separator so it groups confidently.
      #if os(iOS)
      if showDivider {
        Rectangle()
          .fill(Color(uiColor: .opaqueSeparator).opacity(0.7))
          .frame(height: 0.5)
          .padding(.vertical, 10)
      }
      #else
      if showDivider {
        Spacer().frame(height: 12)
      }
      #endif

      sidebarButton(.area(area)) {
        SidebarAreaRow(name: area.title, count: areaOpenCount[area.id] ?? 0)
      }
      .contextMenu { areaMenu(area) }
      .draggable(SidebarDragID.area(area.id)) {
        Text(area.title)
          .font(.system(size: Theme.sidebarAreaTitleSize, weight: .semibold))
          .foregroundStyle(Theme.inkPrimary)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(Theme.cardSurface)
          .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
          .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
      }
      // The area header itself accepts area-drops to position "above this
      // area". Project drops are rejected — they belong on project rows.
      .dropDestination(for: SidebarDragID.self) { items, _ in
        guard let drag = items.first,
              drag.kind == .area,
              drag.id != area.id else { return false }
        reorderArea(drag.id, before: area.id)
        return true
      }

      ForEach(projectsInArea) { project in
        projectRowDraggable(project, parent: area.id)
      }
      // Trailing drop zone for projects in *this* area only.
      if !projectsInArea.isEmpty {
        endOfGroupDropZone(parent: area.id)
      }
    }
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

  /// Move the area with id `movedId` to the end of the areas list.
  private func reorderArea(_ movedId: String, toEnd: Bool) {
    guard toEnd, let from = areas.firstIndex(where: { $0.id == movedId }),
          from != areas.count - 1 else { return }
    var next = areas
    let item = next.remove(at: from)
    next.append(item)
    commitAreaOrder(next)
  }

  private func commitAreaOrder(_ next: [Area]) {
    let snapshot = areas
    Haptics.tick()
    areas = next
    Task {
      do {
        areas = try await client.replaceAreas(next)
      } catch {
        // Roll back to the pre-drop snapshot, then reload to reconcile with
        // any server state we might have missed during the failed write.
        areas = snapshot
        errorMessage = error.localizedDescription
        await load()
      }
    }
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

  private func reorderProject(_ movedId: String, toEnd: Bool, parent: String?) {
    guard toEnd else { return }
    commitProjectOrder(parent: parent) { siblings in
      guard let from = siblings.firstIndex(where: { $0.id == movedId }),
            from != siblings.count - 1 else { return nil }
      var next = siblings
      let item = next.remove(at: from)
      next.append(item)
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

    let snapshot = projects
    Haptics.tick()
    projects = next
    Task {
      do {
        projects = try await client.replaceProjects(next)
      } catch {
        projects = snapshot
        errorMessage = error.localizedDescription
        await load()
      }
    }
  }

  private var topLevelProjects: [Project] {
    projects.filter { $0.area == nil && $0.status == .active }
  }

  // MARK: - Settings

  @ViewBuilder
  private var settingsRow: some View {
    // Discreet on purpose — Settings is rarely needed; the rest of the
    // sidebar is the main surface.
    sidebarButton(.settings) {
      HStack(spacing: 10) {
        Image(systemName: "gearshape.fill")
          .font(.system(size: 14))
          .foregroundStyle(Theme.iconMuted)
          .frame(width: 24, alignment: .center)
        Text("Settings")
          .font(.system(size: 13, weight: .regular))
          .foregroundStyle(Theme.inkSecondary)
        Spacer()
      }
      .frame(height: 30)
      .contentShape(Rectangle())
    }
    .padding(.horizontal, Theme.hPadding)
  }

  // MARK: - Load

  private func load() async {
    do {
      async let a = client.areas()
      async let p = client.projects()
      async let c = client.counts()
      async let all = client.list(view: "all")
      areas = try await a
      projects = try await p
      counts = try await c
      // 'Next' in this app is the chores / habits / supplements ritual
      // (see NextView), not a tasks view — the server has no view=next
      // endpoint, so we don't surface a count here. Tile renders without
      // a number until / unless we wire a real source.
      nextCount = nil

      // Project progress = done / (done + open). Cancelled/someday don't
      // count toward either side of the ratio (they're not "to-do").
      let items = try await all.items
      var done: [String: Int] = [:]
      var total: [String: Int] = [:]
      var projOpen: [String: Int] = [:]
      var areaDirectOpen: [String: Int] = [:]
      for t in items {
        if let pid = t.project {
          switch t.status {
          case .done:           done[pid, default: 0] += 1; total[pid, default: 0] += 1
          case .open:           total[pid, default: 0] += 1; projOpen[pid, default: 0] += 1
          case .cancelled, .someday: break
          }
        } else if let aid = t.area, t.status == .open {
          // Open task assigned directly to an area (no project) — counts
          // toward that area's roll-up.
          areaDirectOpen[aid, default: 0] += 1
        }
      }
      projectProgress = total.reduce(into: [:]) { acc, kv in
        acc[kv.key] = Double(done[kv.key] ?? 0) / Double(kv.value)
      }
      projectOpenCount = projOpen
      // Area count = direct-in-area tasks ONLY. Projects nested under an
      // area are shown as their own rows beneath the area header, with
      // their own counts; rolling those up onto the area double-counts what
      // the user already sees and made the area number feel inflated.
      areaOpenCount = areaDirectOpen
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Sidebar primitives

struct SmartListRow: View {
  let icon: String
  /// The list's color — fills the rounded-square icon container behind a
  /// white SF Symbol (Reminders pattern).
  let iconColor: Color
  let title: String
  /// Red pill — used for "needs attention" (overdue / review).
  var overdueBadge: Int? = nil
  /// Muted gray count — neutral signal for how much sits behind the row.
  var count: Int? = nil

  var body: some View {
    HStack(spacing: 10) {
      ColoredGlyph(icon: icon, color: iconColor,
                   size: Theme.sidebarIconSize + 4)
      Text(title)
        .font(.body)
        .foregroundStyle(.primary)
      Spacer()
      if let b = overdueBadge, b > 0 {
        Text("\(b)")
          .font(.septenaBadge)
          .foregroundStyle(.white)
          .frame(minWidth: 18, minHeight: 18)
          .padding(.horizontal, 5)
          .background(Color.red)
          .clipShape(Capsule())
      }
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

/// iOS "Reminders home screen" smart-list tile — whole tile fills with the
/// list color (subtle top-to-bottom gradient), white icon top-left, huge
/// white count top-right, white label bottom-left.
struct SmartListTile: View {
  let icon: String
  let iconColor: Color
  let title: String
  var count: Int? = nil
  @Environment(\.colorScheme) private var colorScheme

  /// Dim the tile gradient in dark mode so fully saturated system colors
  /// don't glare. Light mode keeps the original Reminders-bright tint.
  private var gradientTop: Color {
    iconColor.opacity(colorScheme == .dark ? 0.78 : 1.0)
  }
  private var gradientBottom: Color {
    iconColor.opacity(colorScheme == .dark ? 0.55 : 0.78)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        Image(systemName: icon)
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.white)
        Spacer()
        if let n = count {
          Text("\(n)")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white)
            .monospacedDigit()
        }
      }
      Spacer(minLength: 4)
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
    .background(
      LinearGradient(
        colors: [gradientTop, gradientBottom],
        startPoint: .top,
        endPoint: .bottom
      ),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
  }
}

/// Reminders-style colored rounded-square glyph: filled colored container
/// with a white SF Symbol inside. Used both in smart-list rows and tiles.
struct ColoredGlyph: View {
  let icon: String
  let color: Color
  let size: CGFloat
  @Environment(\.colorScheme) private var colorScheme

  /// Slight desaturation in dark mode keeps the small filled square from
  /// glaring against a dark background; light mode renders full strength.
  private var adaptedFill: Color {
    color.opacity(colorScheme == .dark ? 0.78 : 1.0)
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .fill(adaptedFill)
      Image(systemName: icon)
        .font(.system(size: size * 0.58, weight: .semibold))
        .foregroundStyle(.white)
    }
    .frame(width: size, height: size)
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
        .font(.system(size: Theme.sidebarAreaTitleSize, weight: .semibold))
        .foregroundStyle(Theme.inkPrimary)
      Spacer()
      if count > 0 {
        Text("\(count)")
          .font(.system(size: 12, weight: .regular))
          .foregroundStyle(Theme.inkSecondary.opacity(0.6))
      }
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
        .font(.system(size: Theme.sidebarTitleSize, weight: Theme.sidebarTitleWeight))
        .foregroundStyle(Theme.inkPrimary)
      Spacer()
      if count > 0 {
        Text("\(count)")
          .font(.system(size: 12, weight: .regular))
          .foregroundStyle(Theme.inkSecondary.opacity(0.6))
      }
    }
    .frame(height: Theme.sidebarProjectRowHeight)
    .contentShape(Rectangle())
  }
}

/// compact project icon: a thin circle outline with a pie wedge filling
/// from 12 o'clock clockwise in proportion to completion.
struct ProjectProgressIcon: View {
  let progress: Double
  let tint: Color
  /// Optional override for sizes that don't match the sidebar default
  /// (e.g. the larger glyph next to a project's screen title).
  var diameter: CGFloat? = nil
  var lineWidth: CGFloat? = nil

  private var resolvedDiameter: CGFloat { diameter ?? Theme.sidebarIconSize * 0.95 }
  private var resolvedLineWidth: CGFloat { lineWidth ?? 1.2 }
  /// Gap between the inner pie and the ring. Pie sits inside the ring's
  /// inner edge (resolvedLineWidth) plus extra breathing room so the two
  /// read as distinct shapes, not a filled-stroke disc.
  private var pieInset: CGFloat { resolvedLineWidth + 2.5 }

  var body: some View {
    let clamped = max(0, min(1, progress))
    ZStack {
      Circle()
        .strokeBorder(tint, lineWidth: resolvedLineWidth)
      PieSliceShape(progress: clamped)
        .fill(tint)
        .padding(pieInset)
    }
    .frame(width: resolvedDiameter, height: resolvedDiameter)
  }
}

/// Pie slice from -90° (top) sweeping clockwise by `progress` × 360°.
struct PieSliceShape: Shape {
  var progress: Double

  func path(in rect: CGRect) -> Path {
    guard progress > 0 else { return Path() }
    var path = Path()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2
    if progress >= 1 {
      path.addEllipse(in: rect)
      return path
    }
    path.move(to: center)
    path.addArc(center: center,
                radius: radius,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + progress * 360),
                clockwise: false)
    path.closeSubpath()
    return path
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
