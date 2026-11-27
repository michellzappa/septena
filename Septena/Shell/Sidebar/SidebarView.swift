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
  @State private var newProjectRequest: NewProjectRequest?
  @State private var showingNewArea = false
  @State private var newAreaName = ""
  #if os(iOS)
  /// Dedicated Magic Plus drag coordinator for the iPad split sidebar column.
  @State private var sidebarMagicPlusDrag = MagicPlusDragState()
  #endif

  /// Right-click → Rename. One pair of state per kind keeps the alert
  /// presentation simple (alert(isPresented:) reads `target != nil`).
  @State private var renameProjectTarget: Project?
  @State private var renameAreaTarget: Area?
  @State private var renameDraft = ""
  /// Right-click → Change Emoji. The picker the area page's icon opens.
  @State private var emojiAreaTarget: Area?
  @State private var emojiDraft = ""

  /// Right-click → Delete (confirm before mutating).
  @State private var deleteProjectTarget: Project?
  @State private var deleteAreaTarget: Area?

  /// The inline row a Magic Plus drop opens on the iPhone/iPad Tasks index: the
  /// insert line turns into this row, and its title creates the Project or
  /// Area at that position.
  @State private var magicDraft: SidebarMagicDraft?
  @State private var magicDraftTitle = ""

  var body: some View {
    #if os(macOS)
    sidebarMac.modifier(rightClickAlerts).sheet(item: $emojiAreaTarget, content: areaEmojiSheet)
    #else
    if usesPushNavigation {
      sidebarSplit.modifier(rightClickAlerts).sheet(item: $emojiAreaTarget, content: areaEmojiSheet)
    } else {
      sidebarPhone.modifier(rightClickAlerts).sheet(item: $emojiAreaTarget, content: areaEmojiSheet)
    }
    #endif
  }

  private func areaEmojiSheet(_ area: Area) -> some View {
    EmojiPickerContent(emoji: $emojiDraft) { setAreaEmoji(area, $0) }
  }

  private func setAreaEmoji(_ area: Area, _ value: String) {
    let emoji: String? = value.isEmpty ? nil : value
    guard emoji != area.emoji else { return }
    Task {
      do {
        try await areasMutator.setEmoji(id: area.id, emoji: emoji)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
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
    Haptics.commit()
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
    Haptics.commit()
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
    let oldAreaId = project.area
    guard oldAreaId != areaId else { return }
    if let areaId, collapsedAreas.contains(areaId) {
      toggleAreaCollapsed(areaId)
    }
    Haptics.commit()
    let mutator = projectsMutator
    let projectId = project.id
    Task {
      do {
        try await mutator.setArea(id: projectId, area: areaId)
        TaskUndo.record(
          name: String(localized: "Move Project", comment: "Sidebar: undo action"),
          undo: { Task { try? await mutator.setArea(id: projectId, area: oldAreaId) } },
          redo: { Task { try? await mutator.setArea(id: projectId, area: areaId) } }
        )
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  /// Move a project into `targetAreaId` (if different) and place it right
  /// before `targetProjectId`, all in one undoable step.
  private func moveAndReorderProject(_ movedId: String, before targetProjectId: String,
                                     inArea targetAreaId: String?) {
    guard movedId != targetProjectId,
          let project = projects.first(where: { $0.id == movedId }) else { return }
    let oldAreaId = project.area
    let oldSiblings = projects.filter { $0.area == oldAreaId && $0.status == .active }.map(\.id)
    let targetSiblings = projects.filter { $0.area == targetAreaId && $0.status == .active }.map(\.id)
    var nextTarget = targetSiblings.filter { $0 != movedId }
    let insertAt = nextTarget.firstIndex(of: targetProjectId) ?? nextTarget.count
    nextTarget.insert(movedId, at: insertAt)

    let reparent = oldAreaId != targetAreaId
    guard reparent || nextTarget != targetSiblings else { return }
    let nextOld = oldSiblings.filter { $0 != movedId }
    if let targetAreaId, collapsedAreas.contains(targetAreaId) {
      toggleAreaCollapsed(targetAreaId)
    }
    Haptics.commit()
    let mutator = projectsMutator
    let forwardOrders: [[String]] = reparent ? [nextOld, nextTarget] : [nextTarget]
    let backwardOrders: [[String]] = reparent ? [targetSiblings, oldSiblings] : [oldSiblings]
    Task {
      do {
        if reparent { try await mutator.setArea(id: movedId, area: targetAreaId) }
        for order in forwardOrders { try await mutator.reorder(orderedIDs: order) }
        TaskUndo.record(
          name: reparent
            ? String(localized: "Move Project", comment: "Sidebar: undo action")
            : String(localized: "Reorder Projects", comment: "Sidebar: undo action"),
          undo: {
            Task {
              if reparent { try? await mutator.setArea(id: movedId, area: oldAreaId) }
              for order in backwardOrders { try? await mutator.reorder(orderedIDs: order) }
            }
          },
          redo: {
            Task {
              if reparent { try? await mutator.setArea(id: movedId, area: targetAreaId) }
              for order in forwardOrders { try? await mutator.reorder(orderedIDs: order) }
            }
          }
        )
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  /// Handles dragging an Area or Project row onto another Area, Project, or the
  /// top No-Area zone in the iOS/iPadOS sidebar.
  private func handleStructureDrop(_ item: SidebarStructureDragItem,
                                   onto target: SidebarStructureDropTarget) -> Bool {
    switch (item, target) {
    case (.area(let movedId), .area(let targetId)):
      guard movedId != targetId else { return false }
      reorderArea(movedId, before: targetId)
      return true
    case (.project(let movedId), .area(let areaId)):
      guard let project = projects.first(where: { $0.id == movedId }),
            project.area != areaId else { return false }
      moveProject(project, to: areaId)
      return true
    case (.project(let movedId), .project(let targetId, let parent)):
      guard movedId != targetId else { return false }
      moveAndReorderProject(movedId, before: targetId, inArea: parent)
      return true
    case (.project(let movedId), .noArea):
      guard let project = projects.first(where: { $0.id == movedId }),
            project.area != nil else { return false }
      moveProject(project, to: nil)
      return true
    default:
      return false
    }
  }

  /// Mark a project done / cancelled from the sidebar context menu — the iPad
  /// home for these lifecycle actions (the detail page's nav-bar overflow is
  /// suppressed on iPad so it can't collide with the global chrome). If the
  /// project being closed is the one open in the detail, bounce to Today.
  private func setProjectStatus(_ project: Project, to status: ProjectStatus) {
    Haptics.projectStatusChanged(to: status)
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
  /// column reads as a distinct panel against the detail pane — plus a
  /// draggable Magic Plus orb at the bottom-trailing corner to drop new Areas
  /// and Projects directly into place.
  @ViewBuilder
  private var sidebarSplit: some View {
    #if os(iOS)
    ZStack(alignment: .bottomTrailing) {
      sidebarListContent()
        .background(Theme.sidebarPanelBackground)

      let hideOrb = magicDraft != nil || SeptenaToastActivity.shared.hasActiveToast
      MagicPlusOrb(
        drag: sidebarMagicPlusDrag,
        isViewingProject: false,
        isViewingArea: false,
        isViewingHome: true,
        onNewTask: {},
        onNewSection: {},
        onNewProject: { newProjectRequest = NewProjectRequest(initialAreaId: activeAreaId) },
        onNewArea: { newAreaName = ""; showingNewArea = true },
        onJoinShared: { SeptaskSharing.presentJoin() }
      )
      .padding(.trailing, 16)
      .padding(.bottom, 12)
      .opacity(hideOrb ? 0 : 1)
      .allowsHitTesting(!hideOrb)
      .a11yAnimation(.easeInOut(duration: 0.2), value: hideOrb)
    }
    .environment(\.magicPlusDrag, sidebarMagicPlusDrag)
    .onAppear {
      sidebarMagicPlusDrag.fallbackDrop = {
        openMagicDraft(.area(index: areas.count))
      }
    }
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .modifier(sidebarBehavior)
    #else
    sidebarListContent()
      .background(Theme.sidebarPanelBackground)
      .navigationTitle("")
      .modifier(sidebarBehavior)
    #endif
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
      #if os(iOS)
      .onDrop(of: [.septenaTaskDragIDs],
              delegate: SidebarNewAreaDropDelegate {
                Haptics.commit()
                newAreaName = ""
                showingNewArea = true
              })
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
    // macOS menu bar & Magic Plus → sidebar sheets. Pre-select the Area in
    // view (open Area page, or the owning Area of the open Project page).
    .onChange(of: nav.shouldCreateProject) { _, want in
      if want {
        newProjectRequest = NewProjectRequest(initialAreaId: activeAreaId)
        nav.shouldCreateProject = false
      }
    }
    .onChange(of: nav.shouldCreateArea) { _, want in
      if want {
        newAreaName = ""
        showingNewArea = true
        nav.shouldCreateArea = false
      }
    }
  }

  /// The Area currently in view — either the open Area page, or the owning
  /// Area of the open Project page.
  private var activeAreaId: String? {
    guard let route = nav.path.last else { return nil }
    switch route {
    case .area(let id):
      return id
    case .project(let id):
      return projects.first(where: { $0.id == id })?.area
    default:
      return nil
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
  /// `inBottomSection`: rows below Areas & Projects draw their title in
  /// secondary ink (docs/DesignSpec.md, "Sidebar ink"), the same rule as the AppKit sidebar.
  private func smartListRow(for spec: SmartListSpec,
                            inBottomSection: Bool = false) -> some View {
    let titleInk: Color = inBottomSection ? Theme.inkSecondary : .primary
    #if os(macOS)
    navRow(spec.route) {
      SmartListRow(icon: spec.icon,
                   iconColor: spec.color,
                   title: spec.title,
                   titleInk: titleInk,
                   count: spec.count)
    }
    .contextMenu { smartListContextMenu(for: spec) }
    .modifier(SmartListTaskDrop(route: spec.route, mutator: taskMutator))
    #else
    cardRow(spec.route) {
      SmartListRow(icon: spec.icon,
                   iconColor: spec.color,
                   title: spec.title,
                   titleInk: titleInk,
                   count: spec.count)
    } menu: {
      smartListContextMenu(for: spec)
    }
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
    Button {
      SeptaskSettingsLink.request(RegistrySettings.PageID.smartLists)
      #if os(macOS)
      SeptaskKitSettingsWindow.show()
      #else
      nav.showSettings = true
      #endif
    } label: {
      Label("Customize Lists…", systemImage: "slider.horizontal.3")
    }
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
        .buttonStyle(NavigationPressStyle())
        .contextMenu { smartListContextMenu(for: spec) }
        // Drag-a-task-onto-Today re-home, matching the area / project cards
        // below. Only the Today tile takes a drop; self-gates to iPad
        // full-screen (inert on iPhone/compact).
        .modifier(SmartListTaskDrop(route: spec.route, mutator: taskMutator))
      }
    }
    .frame(maxWidth: .infinity)
    // Septask draws no floating chrome bar above the sidebar (iPadBarHeight == 0),
    // so on the two-column iPad canvas the 2×2 would sit flush to the top edge.
    // Give it a top margin matching its own left/right inset (the insetGrouped
    // gutter) so the grid is symmetric. iPhone/compact keeps its nav-bar spacing.
    .padding(.top, usesPushNavigation ? Theme.pageGutter : 0)
    // Dropping a dragged Project onto the top grid un-parents it to No Area
    // even when there are no loose projects yet.
    .modifier(SidebarStructureDrop(target: .noArea, onDrop: handleStructureDrop))
  }
  #endif

  /// Septena Life's iPad split view publishes "+" from the sidebar into the
  /// window-level overlay (`RootTabView.iPadTopBar`). Septask has no overlay
  /// bar — its detail column owns "+" in its own nav bar so it stays visible
  /// even when the sidebar collapses on unfolded iPhone Duo / iPad.
  private var sidebarAddAction: PageAdd? {
    return nil
  }

  @ViewBuilder
  private var tasksMenuExtraRows: some View {
    Button {
      showingNewArea = true
      newAreaName = ""
    } label: {
      Label(RegistryActions.title(.sidebarNewArea), systemImage: "square.stack.3d.up")
    }
    Button {
      newProjectRequest = NewProjectRequest(initialAreaId: activeAreaId)
    } label: {
      Label(RegistryActions.title(.sidebarNewProject), systemImage: "number")
    }
    Button {
      SeptaskSharing.presentJoin()
    } label: {
      Label(RegistryActions.title(.sidebarJoinShared), systemImage: RegistryIcons.sfSymbol(for: "action.share_project"))
    }
    Divider()
    Button {
      SeptaskSettingsLink.request(RegistrySettings.PageID.smartLists)
      #if os(macOS)
      SeptaskKitSettingsWindow.show()
      #else
      nav.showSettings = true
      #endif
    } label: {
      Label("Customize Lists…", systemImage: "slider.horizontal.3")
    }
  }

  private var sidebarBehavior: some ViewModifier {
    SidebarBehaviorModifier(
      showingCreateMenu: $showingCreateMenu,
      newProjectRequest: $newProjectRequest,
      showingNewArea: $showingNewArea,
      newAreaName: $newAreaName,
      errorMessage: $errorMessage,
      areas: areas,
      activeAreaId: activeAreaId,
      onNewTodo: {
        // Land on Today (where the triage band lives) instead of a separate
        // Inbox page (retired). The composer seeds from the Today filter.
        nav.path = [.filter(.today)]
        nav.requestNewTask()
      },
      onCreateProject: { title, areaId, mode in createProject(title: title, areaId: areaId, mode: mode) },
      onCreateArea: { createArea() },
      reload: { Task { await load() } }
    )
  }

  // MARK: - Create handlers

  private func createProject(title: String, areaId: String?, mode: ProjectChecklistMode?) {
    let t = title.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return }
    Task {
      do {
        _ = try await projectsMutator.create(title: t, area: areaId, checklistMode: mode)
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

  private var nonEmptySmartListIDs: Set<RegistryDestinationID> {
    var ids = Set<RegistryDestinationID>()
    // Review also stays while selected, so accepting the last item does not
    // pull the row out from under the user. Agent work in progress is a
    // Review group (ADR 0046).
    if reviewCount + agentCount + fadedCount > 0 || isSelected(.filter(.review)) { ids.insert(.review) }
    if starredCount > 0 { ids.insert(.starred) }
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
    // Only Today wears color — it's the bucket you act on: gold under
    // Colorful, else the accent (`tokens.json` `multicolorGlyphs`). The other
    // special lists recede to quiet secondary ink.
    switch route {
    case .filter(.today): return AppearancePreferences.shared.glyphSwiftUIColor(TaskFilter.today.registryDestination?.iconId ?? "list.today")
    default:              return .secondary
    }
  }

  private func smartListCount(_ route: Route) -> Int? {
    switch route {
    // Today total = pinned-today + scheduled/due rolling in. Both buckets live
    // on Today, so the user-facing count is the sum.
    case .filter(.today):           return counts.map { $0.todayCount + $0.reviewCount }
    case .filter(.review):          return reviewCount > 0 ? reviewCount : nil
    case .filter(.upcoming):        return counts?.upcomingCount
    case .filter(.repeating):       return repeatingCount
    case .filter(.unscheduled):     return counts?.unscheduledCount
    case .filter(.logbook):         return doneTodayCount > 0 ? doneTodayCount : nil
    case .filter(.starred):         return starredCount > 0 ? starredCount : nil
    default:                        return nil
    }
  }

  /// A navigable sidebar row. Two behaviors:
  ///   • macOS / iPad regular (push nav): a native `List(selection:)` cell
  ///     tagged by its route, whose selection drives the detail directly through
  ///     `sidebarSelection` — a single click (or arrow key) *is* open, the
  ///     standard system source-list model.
  ///   • iPhone / slide-over (compact): a Button that sets `nav.path` directly.
  ///     `NavigationPressStyle` shows the selection wash from touch-down, the
  ///     way the source list selects on mouse-down (`SelectionLanguage.swift`).
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
        .buttonStyle(NavigationPressStyle(hoverCornerRadius: 10))
    }
    #endif
  }

  #if os(iOS)
  /// An iOS sidebar row. The row paints its own fill across the whole cell,
  /// and the context menu sits on that painted row, so a long-press lifts
  /// what the cell shows, at the cell's width and height.
  ///
  /// Three rules keep the lift free of distortion:
  ///  - The row is as tall as the cell. `List` stretches a cell to its
  ///    minimum row height, so a shorter row lifts as a strip of the cell.
  ///  - The base fill is opaque. The selection fill is a wash, and the cell
  ///    background under it does not lift with the row.
  ///  - The lift has the same corners on every row. A card slice (round top,
  ///    square bottom) does not match the corners the system clips the cell
  ///    to, so an area row changed shape as it lifted.
  ///
  /// The fill is the one selection token: selected, or pressed from
  /// touch-down (`NavigationPressStyle`).
  @ViewBuilder
  private func cardRow<Content: View, Menu: View>(
    _ route: Route,
    @ViewBuilder content: () -> Content,
    @ViewBuilder menu: @escaping () -> Menu
  ) -> some View {
    let selected = isSelected(route)
    let label = content()
    NavigationPressReader { pressed in
      navRow(route) {
        label
          .padding(.horizontal, 16)
          .modifier(FillListCell())
          .contentShape(Rectangle())
      }
      .background {
        Theme.cardSurface
        SelectableListRowBackground(isSelected: selected || pressed)
      }
      .contentShape(.contextMenuPreview,
                    RoundedRectangle(cornerRadius: TaskCardMetrics.radius, style: .continuous))
      .contextMenu(menuItems: menu)
    }
  }
  #endif

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
    // A Magic Plus draft row is spliced in as a slot (`projectSlots` /
    // `areaSlots`).
    let looseRows = projectSlots(topLevelProjects, area: nil)
    if !looseRows.isEmpty {
      Section {
        ForEach(Array(looseRows.enumerated()), id: \.element.id) { idx, slot in
          projectSlotRow(slot, parent: nil, parentTitle: nil,
                         isFirstLoose: idx == 0,
                         isLastInLastCard: areas.isEmpty && magicDraft == nil
                           && idx == looseRows.count - 1)
        }
      }
    }
    ForEach(areaSlots) { slot in
      switch slot {
      case .draft:
        Section {
          compactRow { magicDraftRow(isArea: true) }
        }
      case .area(let area, let index):
        let areaProjects = projects.filter { $0.area == area.id && $0.status == .active }
        let collapsed = collapsedAreas.contains(area.id)
        let rows = collapsed ? [] : projectSlots(areaProjects, area: area.id)
        let isLastArea = index == areas.count - 1 && !magicDraftIsAreaAtEnd
        Section {
          compactRow(route: .area(id: area.id)) {
            areaRow(area, areaIndex: index, hasProjects: !areaProjects.isEmpty, collapsed: collapsed,
                    isLastInLastCard: isLastArea && rows.isEmpty)
          }
          ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
            projectSlotRow(row, parent: area.id, parentTitle: area.title,
                           isFirstLoose: false,
                           isLastInLastCard: isLastArea && idx == rows.count - 1)
          }
        }
      }
    }
    let bottomSpecs = bottomSmartListSpecs
    if !bottomSpecs.isEmpty {
      Section {
        ForEach(bottomSpecs, id: \.route.id) { spec in
          compactRow(route: spec.route) { smartListRow(for: spec, inBottomSection: true) }
        }
      }
    }
  }

  /// Tightens a sidebar list row to Reminders-like density. The row views carry
  /// their own height (`Theme.sidebar*RowHeight`), so the List's default insets
  /// are zeroed; on iOS `cardRow` puts the 16pt side inset back INSIDE the row,
  /// so the row paints the whole cell. macOS uses the system sidebar's row
  /// metrics, which respond to the person's sidebar size setting.
  @ViewBuilder
  private func compactRow<V: View>(route: Route? = nil,
                                   @ViewBuilder _ row: () -> V) -> some View {
    let selected = route.map { isSelected($0) } ?? false
    #if os(iOS)
    // Custom neutral fill only — suppress UIKit's accent capsule / selection
    // ring so rows don't grow or glow on tap (same pattern as the task-list
    // detail). `cardRow` paints the same fill over the whole cell, pressed
    // state included; this cell fill sits under it.
    row()
      .listRowInsets(EdgeInsets())
      .listRowBackground(SelectableListRowBackground(isSelected: selected))
      .septenaSuppressListCellSelection()
    #else
    row()
      // macOS: unselected rows stay transparent so the native `.sidebar` Liquid
      // Glass material shows through; the selected row gets the app's
      // `listSelectionFill` as an inset capsule. Suppress AppKit's accent ring
      // so that fill is the only highlight.
      .listRowBackground(SidebarMacRowBackground(isSelected: selected))
      .septenaSuppressListCellSelection()
    #endif
  }

  /// The tappable row and its context menu; `areaRow` adds the drop targets.
  @ViewBuilder
  private func areaRowBase(_ area: Area, hasProjects: Bool, collapsed: Bool) -> some View {
    #if os(iOS)
    cardRow(.area(id: area.id)) {
      SidebarAreaRow(name: area.title, emoji: area.emoji, count: areaOpenCount[area.id] ?? 0,
                     isCollapsed: hasProjects ? collapsed : nil,
                     onToggleCollapse: hasProjects ? { toggleAreaCollapsed(area.id) } : nil)
    } menu: {
      areaMenu(area)
    }
    #else
    navRow(.area(id: area.id)) {
      SidebarAreaRow(name: area.title, emoji: area.emoji, count: areaOpenCount[area.id] ?? 0,
                     isCollapsed: hasProjects ? collapsed : nil,
                     onToggleCollapse: hasProjects ? { toggleAreaCollapsed(area.id) } : nil)
    }
    .contextMenu { areaMenu(area) }
    #endif
  }

  /// The area's own row — tappable to its detail, with rename / reorder / delete
  /// in the context menu, draggable to reorder, and a drop target for projects
  /// and tasks. Sits at the top of its section's grouped card, projects underneath.
  @ViewBuilder
  private func areaRow(_ area: Area, areaIndex: Int, hasProjects: Bool, collapsed: Bool,
                       isLastInLastCard: Bool) -> some View {
    let projectInAreaLabel = String(localized: "New Project in \(area.title)",
                                    comment: "Magic Plus: drop inside an area")
    areaRowBase(area, hasProjects: hasProjects, collapsed: collapsed)
    .draggable(SidebarStructureDragItem.area(area.id))
    .modifier(SidebarStructureDrop(target: .area(area.id), onDrop: handleStructureDrop))
    // Drag-a-task-here re-home on co-visible sidebar+list (iPad/Mac).
    .modifier(SidebarTaskDrop(kind: .area(area.id), mutator: taskMutator) {
      newProjectRequest = NewProjectRequest(initialAreaId: area.id)
    })
    // Magic Plus on the Tasks index makes Areas at Area level (gap above any
    // Area card, or below the last card) and Projects inside an Area (under
    // the Area row or any Project row).
    .magicPlusListInsert(id: "mp-sidebar-area-top-\(area.id)", edge: .top,
                         isArea: true, label: RegistryActions.title(.sidebarNewArea),
                         lineInset: 0, active: magicZonesActive) { _ in
      openMagicDraft(.area(index: areaIndex))
    }
    .magicPlusListInsert(id: "mp-sidebar-area-\(area.id)", edge: .bottom,
                         isArea: false, label: projectInAreaLabel,
                         lineInset: Self.projectLineInset, active: magicZonesActive) { _ in
      if collapsedAreas.contains(area.id) { toggleAreaCollapsed(area.id) }
      openMagicDraft(.project(area: area.id, index: 0))
    }
    .modifier(MagicPlusTrailingAreaGap(enabled: isLastInLastCard, active: magicZonesActive) {
      openMagicDraft(.area(index: areas.count))
    })
  }

  /// The tappable row and its context menu; `projectRow` adds the drop targets.
  @ViewBuilder
  private func projectRowBase(_ project: Project) -> some View {
    #if os(iOS)
    cardRow(.project(id: project.id)) {
      SidebarProjectRow(name: project.title,
                        isChecklist: project.checklistMode != nil,
                        progress: projectProgress[project.id] ?? 0,
                        count: projectOpenCount[project.id] ?? 0,
                        share: project.share)
    } menu: {
      projectMenu(project)
    }
    #else
    navRow(.project(id: project.id)) {
      SidebarProjectRow(name: project.title,
                        isChecklist: project.checklistMode != nil,
                        progress: projectProgress[project.id] ?? 0,
                        count: projectOpenCount[project.id] ?? 0,
                        share: project.share)
    }
    .contextMenu { projectMenu(project) }
    #endif
  }

  @ViewBuilder
  private func projectRow(_ project: Project, parent: String?, parentTitle: String?,
                          index: Int, isFirstLoose: Bool,
                          isLastInLastCard: Bool) -> some View {
    let projectLabel: String = {
      if let parentTitle {
        return String(localized: "New Project in \(parentTitle)",
                      comment: "Magic Plus: drop inside an area")
      }
      return RegistryActions.title(.sidebarNewProject)
    }()
    projectRowBase(project)
    .draggable(SidebarStructureDragItem.project(project.id))
    .modifier(SidebarStructureDrop(target: .project(project.id, parent: parent),
                                   onDrop: handleStructureDrop))
    // Drag-a-task-here re-home on co-visible sidebar+list (iPad/Mac).
    .modifier(SidebarTaskDrop(kind: .project(project.id), mutator: taskMutator) {
      newProjectRequest = NewProjectRequest(initialAreaId: parent)
    })
    // Top of the loose projects card allows inserting a standalone Project at index 0.
    .modifier(MagicPlusOptionalTopInsert(
      enabled: isFirstLoose,
      id: "mp-sidebar-loose-top",
      label: RegistryActions.title(.sidebarNewProject),
      lineInset: Self.projectLineInset,
      active: magicZonesActive
    ) {
      openMagicDraft(.project(area: nil, index: 0))
    })
    // Magic Plus under a Project puts a new Project after it, in the same
    // area (or standalone if loose).
    .magicPlusListInsert(id: "mp-sidebar-proj-\(project.id)", edge: .bottom,
                         isArea: false, label: projectLabel,
                         lineInset: Self.projectLineInset, active: magicZonesActive) { _ in
      openMagicDraft(.project(area: parent, index: index + 1))
    }
    .modifier(MagicPlusTrailingAreaGap(enabled: isLastInLastCard, active: magicZonesActive) {
      openMagicDraft(.area(index: areas.count))
    })
  }

  // MARK: - Magic Plus drafts (iPhone & iPad Tasks index)

  /// Leading inset of a Project insert line: it starts past the icon column,
  /// so it reads as "inside this card". An Area line spans the whole gap.
  private static let projectLineInset: CGFloat = Theme.sidebarIconSize + 4

  /// Insert zones live whenever the sidebar index is visible on iOS/iPadOS:
  /// on iPad split (`usesPushNavigation`) the sidebar is always visible with
  /// its own orb; on iPhone compact it is active only at the root (`path.isEmpty`)
  /// so it never intercepts drops on pushed task lists.
  private var magicZonesActive: Bool {
    #if os(iOS)
    usesPushNavigation || nav.path.isEmpty
    #else
    false
    #endif
  }

  private var magicDraftIsAreaAtEnd: Bool {
    if case .area(let i) = magicDraft, i >= areas.count { return true }
    return false
  }

  /// Areas in order, with the Area draft spliced in at its index.
  private var areaSlots: [SidebarAreaSlot] {
    var slots = areas.enumerated().map { SidebarAreaSlot.area($0.element, index: $0.offset) }
    if case .area(let i) = magicDraft {
      slots.insert(.draft, at: min(max(i, 0), slots.count))
    }
    return slots
  }

  /// One area's projects (or the loose ones), with the Project draft spliced
  /// in at its index.
  private func projectSlots(_ list: [Project], area: String?) -> [SidebarProjectSlot] {
    var slots = list.enumerated().map { SidebarProjectSlot.project($0.element, index: $0.offset) }
    if case .project(let a, let i) = magicDraft, a == area {
      slots.insert(.draft, at: min(max(i, 0), slots.count))
    }
    return slots
  }

  @ViewBuilder
  private func projectSlotRow(_ slot: SidebarProjectSlot, parent: String?, parentTitle: String?,
                              isFirstLoose: Bool, isLastInLastCard: Bool) -> some View {
    switch slot {
    case .draft:
      compactRow { magicDraftRow(isArea: false) }
    case .project(let project, let index):
      compactRow(route: .project(id: project.id)) {
        projectRow(project, parent: parent, parentTitle: parentTitle,
                   index: index, isFirstLoose: isFirstLoose,
                   isLastInLastCard: isLastInLastCard)
      }
    }
  }

  private func magicDraftRow(isArea: Bool) -> some View {
    SidebarMagicDraftRow(isArea: isArea, title: $magicDraftTitle, onEnd: commitMagicDraft)
      #if os(iOS)
      // iOS rows carry their 16pt side inset inside the row (`cardRow`).
      .padding(.horizontal, 16)
      #endif
  }

  private func openMagicDraft(_ draft: SidebarMagicDraft) {
    Haptics.commit()
    magicDraftTitle = ""
    a11yAnimate(.snappy(duration: 0.22)) { magicDraft = draft }
  }

  /// Ends the draft row: a typed title creates the Project or Area at the
  /// draft's position; an empty title just closes the row.
  private func commitMagicDraft() {
    guard let draft = magicDraft else { return }
    let title = magicDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    a11yAnimate(.snappy(duration: 0.22)) { magicDraft = nil }
    magicDraftTitle = ""
    guard !title.isEmpty else { return }
    switch draft {
    case .project(let area, let index):
      let siblingIDs = projects.filter { $0.area == area && $0.status == .active }.map(\.id)
      Task {
        do {
          let created = try await projectsMutator.create(title: title, area: area)
          var ids = siblingIDs.filter { $0 != created.id }
          ids.insert(created.id, at: min(index, ids.count))
          try await projectsMutator.reorder(orderedIDs: ids)
          await load()
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    case .area(let index):
      let areaIDs = areas.map(\.id)
      Task {
        do {
          let created = try await areasMutator.create(title: title)
          var ids = areaIDs.filter { $0 != created.id }
          ids.insert(created.id, at: min(index, ids.count))
          try await areasMutator.reorder(orderedIDs: ids)
          await load()
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  // MARK: - Context menus

  /// Registry `sidebar.project`, the same menu the AppKit sidebar renders.
  private func projectMenu(_ project: Project) -> some View {
    let siblings = projects.filter { $0.area == project.area && $0.status == .active }
    let idx = siblings.firstIndex(where: { $0.id == project.id })
    return RegistryMenuContent(nodes: RegistryMenuResolver.resolve(
      RegistryActions.menu(.sidebarProject),
      bind: { id in
        switch id {
        case .projectRename:
          return .init {
            renameDraft = project.title
            renameProjectTarget = project
          }
        case .projectMoveUp:
          guard let idx else { return nil }
          return .init(perform: idx == 0 ? nil : {
            reorderProject(project.id, before: siblings[idx - 1].id, parent: project.area)
          })
        case .projectMoveDown:
          guard let idx else { return nil }
          return .init(perform: idx == siblings.count - 1 ? nil : {
            reorderProject(siblings[idx + 1].id, before: project.id, parent: project.area)
          })
        case .projectUseAsChecklist:
          return project.checklistMode == nil ? .init {
            Task { try await projectsMutator.useAsChecklist(id: project.id) }
          } : nil
        case .projectMarkDone: return .init { setProjectStatus(project, to: .done) }
        case .projectCancel: return .init { setProjectStatus(project, to: .cancelled) }
        case .projectShare: return .init { SeptaskSharing.present(projectID: project.id) }
        // A shared project ends from its Share screen.
        case .projectDelete: return project.share == nil ? .init { deleteProjectTarget = project } : nil
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
                             sfSymbol: "tray", isOn: project.area == nil,
                             perform: project.area == nil ? nil : { moveProject(project, to: nil) }),
    ]
    if !areas.isEmpty { nodes.append(.divider(id: "areas.divider")) }
    for area in areas {
      nodes.append(RegistryMenuEntry.slot(
        id: "area.\(area.id)", title: area.title,
        listIcon: .area(emoji: area.emoji), isOn: project.area == area.id,
        perform: project.area == area.id ? nil : { moveProject(project, to: area.id) }))
    }
    return nodes
  }

  /// Registry `sidebar.area`, the same menu the AppKit sidebar renders.
  private func areaMenu(_ area: Area) -> some View {
    let idx = areas.firstIndex(where: { $0.id == area.id })
    return RegistryMenuContent(nodes: RegistryMenuResolver.resolve(
      RegistryActions.menu(.sidebarArea)) { id in
        switch id {
        case .areaNewProject:
          return .init {
            newProjectRequest = NewProjectRequest(initialAreaId: area.id)
          }
        case .areaRename:
          return .init {
            renameDraft = area.title
            renameAreaTarget = area
          }
        case .areaChangeEmoji:
          return .init {
            emojiDraft = area.emoji ?? ""
            emojiAreaTarget = area
          }
        case .areaMoveUp:
          guard let idx else { return nil }
          return .init(perform: idx == 0 ? nil : { reorderArea(area.id, before: areas[idx - 1].id) })
        case .areaMoveDown:
          guard let idx else { return nil }
          return .init(perform: idx == areas.count - 1 ? nil : {
            reorderArea(areas[idx + 1].id, before: area.id)
          })
        case .areaDelete: return .init { deleteAreaTarget = area }
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
    let before = areas.map(\.id)
    let after = next.map(\.id)
    guard before != after else { return }
    Haptics.commit()
    areas = next   // optimistic; the reorder re-posts .septenaStructureChanged → load() re-sorts by position
    let mutator = areasMutator
    Task {
      try? await mutator.reorder(orderedIDs: after)
      TaskUndo.record(
        name: String(localized: "Reorder Areas", comment: "Sidebar: undo action"),
        undo: { Task { try? await mutator.reorder(orderedIDs: before) } },
        redo: { Task { try? await mutator.reorder(orderedIDs: after) } }
      )
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

    Haptics.commit()
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
    Haptics.selection()
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
    guard !StoreHealth.readsFailed(since: token) else {
      SeptenaLog.error("[Sidebar] load aborted — a store read failed; keeping the last good counts")
      return
    }
    areas = structure.areas
    projects = structure.projects
    apply(aggregate: agg)
    SidebarSeed.aggregate = agg
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
        case .cancelled, .checklistChecked: break
        }
      } else if let aid = t.area, t.status == .open {
        areaDirectOpen[aid, default: 0] += 1
      }
      guard t.status == .open else { continue }
      // Smart-list buckets — mirror LocalCache.tasks(in:filter:) semantics.
      if t.starred { starred += 1 }
      // Check the raw columns first so only rows that carry JSON decode it.
      if t.recurrenceUnit != nil, t.recurrence != nil { repeating += 1 }
      if t.conversationJSON != nil || t.isWaiting {
        let convo = t.conversation
        // Review shows both; only what waits on the user counts in its badge.
        // Waiting (docs/REVIEW_SPEC.md §6) shows but does not count.
        if let group = convo.reviewGroup(at: now, waiting: t.isWaiting) {
          if group.countsInBadge { review += 1 } else { agent += 1 }
        }
      }
      if t.isInInbox { inbox += 1 }
      // The triage band (unratified) sits above Today and is excluded from it.
      if t.isInTriageBand { triage += 1 }
      if !t.isInTriageBand, t.isOnToday { todayN += 1 }
      if t.isUpcoming { upcoming += 1 }
      if t.isAnytime { unscheduled += 1 }
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
/// projects). One definition so all the numbers read identically — never
/// restyle a count inline.
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
  /// Title ink. `.primary` (not a fixed Theme ink) so the native `.sidebar`
  /// selection inverts the title to white over the focused accent. Bottom
  /// smart lists pass `Theme.inkSecondary`, which adapts the same way.
  var titleInk: Color = .primary
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
        .foregroundStyle(titleInk)
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
/// The card gap is the Magic Plus line's gap too (`MagicPlusListMetrics`).
private enum IOSSidebarListMetrics {
  static let sectionSpacing: CGFloat = MagicPlusListMetrics.cardGap
}

/// Sizes a row to the whole list cell. It reads the minimum row height inside
/// the cell, where `List` sets it.
private struct FillListCell: ViewModifier {
  @Environment(\.defaultMinListRowHeight) private var minRowHeight

  func body(content: Content) -> some View {
    content.frame(maxWidth: .infinity, minHeight: minRowHeight, alignment: .leading)
  }
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
  @Binding var newProjectRequest: NewProjectRequest?
  @Binding var showingNewArea: Bool
  @Binding var newAreaName: String
  @Binding var errorMessage: String?

  let areas: [Area]
  let activeAreaId: String?
  let onNewTodo: () -> Void
  let onCreateProject: (String, String?, ProjectChecklistMode?) -> Void
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
        newProjectRequest: $newProjectRequest,
        showingNewArea: $showingNewArea,
        newAreaName: $newAreaName,
        errorMessage: $errorMessage,
        areas: areas,
        activeAreaId: activeAreaId,
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
  /// no outline ring. A press shows the same fill (`NavigationPressStyle`).
  var isSelected: Bool = false
  @Environment(\.isNavigationPressed) private var isPressed

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
        .fill(isSelected || isPressed ? Theme.listSelectionFill : Theme.cardSurface)
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
  var isChecklist: Bool = false
  /// Fraction of tasks done (0...1). 0 → empty ring, 1 → filled disc.
  var progress: Double = 0
  // Keep the project completion glyph consistent with the rest of the
  // project/area UI (group headers, area rows, project detail).
  var tint: Color = Theme.inkSecondary
  /// Open task count — muted gray, right-aligned alongside the pie.
  var count: Int = 0
  var share: ProjectShare? = nil

  var body: some View {
    HStack(spacing: Theme.sidebarRowSpacing) {
      Group {
        if isChecklist {
          Image(systemName: "checklist").foregroundStyle(tint)
        } else {
          ProjectProgressIcon(progress: progress, tint: tint, diameter: nil)
        }
      }
      .frame(width: Theme.sidebarIconSize + 4, alignment: .center)
      Text(name)
        .scaledFont(size: Theme.sidebarTitleSize, weight: Theme.sidebarTitleWeight)
        .foregroundStyle(SidebarRowTitleStyle.color)
      if let share {
        Image(systemName: RegistryIcons.sfSymbol(for: "project.shared"))
          .scaledFont(size: 11)
          .foregroundStyle(Theme.inkSecondary)
          .accessibilityLabel(share.membersLabel)
      }
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

/// Identifies a single presentation of `NewProjectSheet` together with its
/// pre-selected Area so `.sheet(item:)` always delivers the exact area ID
/// atomically (avoiding SwiftUI's stale-capture trap with `.sheet(isPresented:)`).
struct NewProjectRequest: Identifiable {
  let id = UUID()
  let initialAreaId: String?
}

struct NewProjectSheet: View {
  let areas: [Area]
  /// Pre-selected area when invoked from an area's context menu, an open Area
  /// page, or a Project inside an Area.
  var initialAreaId: String? = nil
  let onCreate: (String, String?, ProjectChecklistMode?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var mode: ProjectChecklistMode?
  @State private var selectedAreaId: String?
  @FocusState private var titleFocused: Bool

  init(areas: [Area], initialAreaId: String? = nil, onCreate: @escaping (String, String?, ProjectChecklistMode?) -> Void) {
    self.areas = areas
    self.initialAreaId = initialAreaId
    self.onCreate = onCreate
    _selectedAreaId = State(initialValue: initialAreaId)
  }

  private var canCreate: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func submit() {
    guard canCreate else { return }
    onCreate(title, selectedAreaId, mode)
    dismiss()
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(RegistryPrompts.textPrompt(.newProject).placeholder, text: $title)
            .focused($titleFocused)
            .submitLabel(.done)
            .onSubmit { submit() }
        }
        Picker(RegistrySurfaces.checklistProjectType, selection: $mode) {
          Text(RegistrySurfaces.standardProjectTitle).tag(nil as ProjectChecklistMode?)
          Text(RegistrySurfaces.checklistProjectTitle).tag(ProjectChecklistMode?.some(.plain))
        }
        Section("Area") {
          Button { selectedAreaId = nil } label: {
            areaOptionRow(title: nil, emoji: nil, selected: selectedAreaId == nil)
          }
          .buttonStyle(PlainHoverRowButtonStyle())
          .listRowBackground(SelectableListRowBackground(isSelected: selectedAreaId == nil))
          ForEach(areas) { area in
            let isSelected = selectedAreaId == area.id
            Button { selectedAreaId = area.id } label: {
              areaOptionRow(title: area.title, emoji: area.emoji, selected: isSelected)
            }
            .buttonStyle(PlainHoverRowButtonStyle())
            .listRowBackground(SelectableListRowBackground(isSelected: isSelected))
          }
        }
      }
      // Grouped style keeps the macOS sheet from collapsing to no height
      // (default-styled Forms report no flexible height) — same rule the
      // shared AdaptiveEditScaffold applies to its sheet branch.
      .formStyle(.grouped)
      .navigationTitle(RegistryPrompts.textPrompt(.newProject).title)
      .septenaInlineTitle()
      .onAppear {
        selectedAreaId = initialAreaId
        DispatchQueue.main.async { titleFocused = true }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          DrawerCloseButton { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(RegistryPrompts.textPrompt(.newProject).confirmTitle) {
            submit()
          }
          .disabled(!canCreate)
        }
      }
    }
  }

  @ViewBuilder
  private func areaOptionRow(title: String?, emoji: String?, selected: Bool) -> some View {
    HStack(spacing: 12) {
      if let title {
        AreaIcon(diameter: 15, emoji: emoji)
          .frame(width: 22)
        Text(title)
          .fontWeight(selected ? .semibold : .regular)
          .foregroundStyle(Theme.inkPrimary)
      } else {
        Image(systemName: "tray")
          .scaledFont(size: 15)
          .foregroundStyle(Theme.iconMuted)
          .frame(width: 22)
        Text("No Area")
          .fontWeight(selected ? .semibold : .regular)
          .foregroundStyle(Theme.inkPrimary)
      }
      Spacer()
      if selected {
        Image(systemName: "checkmark")
          .scaledFont(size: 13, weight: .semibold)
          .foregroundStyle(AppearancePreferences.shared.accentSwiftUIColor)
      }
    }
    .contentShape(Rectangle())
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
    let renameProject = RegistryPrompts.textPrompt(.renameProject)
    let renameArea = RegistryPrompts.textPrompt(.renameArea)
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
  @Binding var newProjectRequest: NewProjectRequest?
  @Binding var showingNewArea: Bool
  @Binding var newAreaName: String
  @Binding var errorMessage: String?
  let areas: [Area]
  let activeAreaId: String?
  let onNewTodo: () -> Void
  let onCreateProject: (String, String?, ProjectChecklistMode?) -> Void
  let onCreateArea: () -> Void

  func body(content: Content) -> some View {
    content
      .confirmationDialog("Create", isPresented: $showingCreateMenu, titleVisibility: .hidden) {
        Button(RegistryActions.title(.appNewTask))   { onNewTodo() }
        Button(RegistryActions.title(.sidebarNewProject)) {
          newProjectRequest = NewProjectRequest(initialAreaId: activeAreaId)
        }
        Button(RegistryActions.title(.sidebarNewArea))    { newAreaName = ""; showingNewArea = true }
        Button(RegistryPrompts.cancelTitle, role: .cancel) {}
      }
      .sheet(item: $newProjectRequest) { request in
        NewProjectSheet(areas: areas,
                        initialAreaId: request.initialAreaId,
                        onCreate: onCreateProject)
          .presentationDetents([.medium])
          .septenaSheetChrome()
      }
      .alert(RegistryPrompts.textPrompt(.newArea).title, isPresented: $showingNewArea) {
        TextField(RegistryPrompts.textPrompt(.newArea).placeholder, text: $newAreaName)
        Button(RegistryPrompts.textPrompt(.newArea).confirmTitle) { onCreateArea() }
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
    #if os(iOS)
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
                    Haptics.commit()
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
    Haptics.commit()
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

  func body(content: Content) -> some View {
    if let kind = SidebarTaskDrop.Kind(route: route) {
      content
        .modifier(SidebarTaskDrop(kind: kind, mutator: mutator))
    } else {
      content
    }
  }
}

// MARK: - Magic Plus drafts on the Tasks index

/// Where a Magic Plus drop on the Tasks index opens its inline draft row.
enum SidebarMagicDraft: Equatable {
  /// A new Project at `index` among the active projects of `area` (nil: loose).
  case project(area: String?, index: Int)
  /// A new Area at `index` in the area order.
  case area(index: Int)
}

private enum SidebarAreaSlot: Identifiable {
  case area(Area, index: Int)
  case draft

  var id: String {
    switch self {
    case .area(let area, _): return area.id
    case .draft:             return "magic-draft-area"
    }
  }
}

private enum SidebarProjectSlot: Identifiable {
  case project(Project, index: Int)
  case draft

  var id: String {
    switch self {
    case .project(let project, _): return project.id
    case .draft:                   return "magic-draft-project"
    }
  }
}

/// Top insertion point on the first loose project row (inserts at index 0).
private struct MagicPlusOptionalTopInsert: ViewModifier {
  let enabled: Bool
  let id: String
  let label: String
  let lineInset: CGFloat
  let active: Bool
  let onDrop: () -> Void

  func body(content: Content) -> some View {
    if enabled {
      content.magicPlusListInsert(id: id, edge: .top, isArea: false, label: label,
                                  lineInset: lineInset, active: active) { _ in onDrop() }
    } else {
      content
    }
  }
}

/// The gap under the last card on the Tasks index: a drop there makes a new
/// Area at the end. Registered only by the last row of the last card.
private struct MagicPlusTrailingAreaGap: ViewModifier {
  let enabled: Bool
  let active: Bool
  let onDrop: () -> Void

  func body(content: Content) -> some View {
    if enabled {
      content.magicPlusListInsert(id: "mp-sidebar-area-gap-end",
                                  edge: .belowGap(MagicPlusListMetrics.cardGap),
                                  isArea: true,
                                  label: RegistryActions.title(.sidebarNewArea),
                                  active: active) { _ in onDrop() }
    } else {
      content
    }
  }
}

// MARK: - Drag-to-move & reorder Areas / Projects in the SwiftUI sidebar

private enum SidebarStructureDropTarget {
  case area(String)
  case project(String, parent: String?)
  case noArea
}

/// Drop target for dragging an Area or Project onto another Area, Project, or
/// the top No-Area zone. Highlights using the ONE canonical selection wash
/// (`Theme.listSelectionFill`).
private struct SidebarStructureDrop: ViewModifier {
  let target: SidebarStructureDropTarget
  let onDrop: (SidebarStructureDragItem, SidebarStructureDropTarget) -> Bool
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isTargeted ? Theme.listSelectionFill : Color.clear)
          .a11yAnimation(.easeOut(duration: 0.12), value: isTargeted)
      )
      .onDrop(of: [.septenaStructureDragItem],
              delegate: SidebarStructureDropDelegate(isTargeted: $isTargeted) { item in
                onDrop(item, target)
              })
  }
}

private struct SidebarStructureDropDelegate: DropDelegate {
  @Binding var isTargeted: Bool
  let perform: (SidebarStructureDragItem) -> Bool

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.septenaStructureDragItem])
  }

  func dropEntered(info: DropInfo) { isTargeted = true }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    isTargeted = true
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) { isTargeted = false }

  func performDrop(info: DropInfo) -> Bool {
    isTargeted = false
    guard let provider = info.itemProviders(for: [.septenaStructureDragItem]).first else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.septenaStructureDragItem.identifier) { data, _ in
      guard let data,
            let item = try? JSONDecoder().decode(SidebarStructureDragItem.self, from: data)
      else { return }
      DispatchQueue.main.async { _ = perform(item) }
    }
    return true
  }
}

/// The inline row the insert line turns into: the Project or Area glyph and a
/// focused title field. Return or leaving the field ends it; the host creates
/// the item when the title is not empty.
private struct SidebarMagicDraftRow: View {
  let isArea: Bool
  @Binding var title: String
  let onEnd: () -> Void
  @FocusState private var focused: Bool

  var body: some View {
    let prompt = RegistryPrompts.textPrompt(isArea ? .newArea : .newProject)
    HStack(spacing: Theme.sidebarRowSpacing) {
      Group {
        if isArea {
          AreaIcon()
        } else {
          ProjectProgressIcon(progress: 0, tint: Theme.inkSecondary)
        }
      }
      .frame(width: Theme.sidebarIconSize + 4, alignment: .center)
      TextField(prompt.placeholder, text: $title)
        .scaledFont(size: isArea ? Theme.sidebarAreaTitleSize : Theme.sidebarTitleSize,
                    weight: isArea ? .semibold : Theme.sidebarTitleWeight)
        .foregroundStyle(SidebarRowTitleStyle.color)
        .focused($focused)
        .submitLabel(.done)
        .onSubmit(onEnd)
    }
    .frame(height: isArea ? Theme.sidebarRowHeight : Theme.sidebarProjectRowHeight)
    .onAppear { DispatchQueue.main.async { focused = true } }
    .onChange(of: focused) { _, isFocused in
      if !isFocused { onEnd() }
    }
  }
}
