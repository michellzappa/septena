import SwiftUI
import UniformTypeIdentifiers

// Things-style sidebar: the root/home screen.
// See docs/things-reference/screens.md §1

struct SidebarView: View {
  @EnvironmentObject var client: AtaskClient
  @EnvironmentObject var nav: NavigationState

  @State private var tasks: [EngageTask] = []
  @State private var areas: [Area] = []
  @State private var projects: [Project] = []
  @State private var expandedAreas: Set<String> = []
  @State private var didInitialize = false
  @State private var tappedRoute: Route?

  // Drag state
  @State private var draggingId: String? = nil
  @State private var projectAreaOverrides: [String: String] = [:]  // projectId -> override areaId

  // New area/project creation
  @State private var showingCreateDialog = false
  @State private var createKind: CreateKind? = nil
  @State private var createName = ""

  enum CreateKind { case area, project }

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          QuickFindBar()
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 8)
            .padding(.bottom, 20)

          smartListsSection
            .padding(.horizontal, Theme.hPadding)

          Hairline()
            .padding(.top, 8)
            .padding(.bottom, 16)

          areasSection

          Spacer(minLength: 120)
        }
      }
      .background(Color(.systemBackground))

      MagicPlusButton { showingCreateDialog = true }
      .padding(.trailing, Theme.hPadding)
      .padding(.bottom, 20)
    }
    .navigationBarHidden(true)
    .confirmationDialog("Create", isPresented: $showingCreateDialog, titleVisibility: .hidden) {
      Button("New Project") { createKind = .project; createName = "" }
      Button("New Area") { createKind = .area; createName = "" }
      Button("New To-Do") {
        nav.showingQuickEntry = true
        go(.filter(.inbox))
      }
      Button("Cancel", role: .cancel) {}
    }
    .alert(createKind == .area ? "New Area" : "New Project", isPresented: Binding(
      get: { createKind != nil },
      set: { if !$0 { createKind = nil } }
    )) {
      TextField(createKind == .area ? "Area name" : "Project name", text: $createName)
      Button("Create") { commitCreate() }
      Button("Cancel", role: .cancel) { createKind = nil }
    }
    .task { await load() }
    .refreshable { await load() }
    .onChange(of: nav.selectedTab) { _, _ in
      tappedRoute = nil
    }
  }

  // MARK: - Navigation helper

  private func go(_ route: Route) {
    tappedRoute = route
    switch route {
    case .filter(let f):
      switch f {
      case .inbox: nav.selectedTab = .inbox
      case .today: nav.selectedTab = .today
      case .upcoming: nav.selectedTab = .upcoming
      case .anytime: nav.selectedTab = .anytime
      case .logbook: nav.selectedTab = .logbook
      case .review: nav.selectedTab = .review
      case .someday, .project, .area: break
      }
    case .project, .area, .agents, .agent: break
    }
  }

  private func isTapped(_ route: Route) -> Bool { tappedRoute == route }

  // MARK: - Smart lists

  private var smartListsSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      rowButton(.filter(.inbox)) {
        SmartListRow(icon: "tray.fill", tint: Theme.inboxBlue, title: "Inbox", count: count(for: .inbox))
      }
      rowButton(.filter(.today)) {
        SmartListRow(icon: "star.fill", tint: Theme.todayYellow, title: "Today", overdueBadge: overdueCount, count: count(for: .today))
      }
      rowButton(.filter(.upcoming(days: 30))) {
        SmartListRow(icon: "calendar", tint: Theme.upcomingRed, title: "Upcoming")
      }
      rowButton(.filter(.anytime)) {
        SmartListRow(icon: "square.stack.3d.up.fill", tint: Theme.anytimeTeal, title: "Anytime")
      }
      rowButton(.filter(.someday)) {
        SmartListRow(icon: "archivebox.fill", tint: Theme.somedayTan, title: "Someday")
      }
      rowButton(.filter(.logbook)) {
        SmartListRow(icon: "checkmark.square.fill", tint: Theme.logbookGreen, title: "Logbook")
      }
      rowButton(.agents) {
        SmartListRow(icon: "person.2.fill", tint: .purple, title: "Agents")
      }
    }
  }

  @ViewBuilder
  private func rowButton<Content: View>(_ route: Route, @ViewBuilder label: () -> Content) -> some View {
    Button { go(route) } label: { label() }
      .buttonStyle(.plain)
      .background(isTapped(route) ? Theme.rowSelected : Color.clear)
  }

  // MARK: - Areas + projects (draggable)

  private var areasSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Top-level projects (no area)
      ForEach(topLevelProjects) { project in
        Button { go(.project(project)) } label: {
          SidebarProjectRow(name: project.name, progress: progress(for: project))
            .padding(.horizontal, Theme.hPadding)
        }
        .buttonStyle(.plain)
        .background(isTapped(.project(project)) ? Theme.rowSelected : Color.clear)
        .onDrag {
          draggingId = "project:\(project.id)"
          return NSItemProvider(object: "project:\(project.id)" as NSString)
        }
      }

      if !topLevelProjects.isEmpty && !areas.isEmpty {
        Spacer().frame(height: 12)
      }

      ForEach(Array(areas.enumerated()), id: \.element.id) { idx, area in
        if idx > 0 || !topLevelProjects.isEmpty {
          Hairline()
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        areaBlock(area: area, index: idx)
      }
    }
  }

  private func progress(for project: Project) -> Double {
    let related = tasks.filter { $0.project == project.id }
    guard !related.isEmpty else { return 0 }
    let done = related.filter { $0.status == .completed || $0.status == .cancelled }.count
    return Double(done) / Double(related.count)
  }

  private var topLevelProjects: [Project] {
    projects
      .filter { effectiveArea(for: $0) == nil && $0.status == .active }
      .sorted { $0.sortOrder < $1.sortOrder }
  }

  @ViewBuilder
  private func areaBlock(area: Area, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { go(.area(area)) } label: {
        SidebarAreaRow(
          name: area.name,
          isExpanded: expandedAreas.contains(area.id),
          onToggle: {
            withAnimation(.easeInOut(duration: 0.2)) {
              if expandedAreas.contains(area.id) {
                expandedAreas.remove(area.id)
              } else {
                expandedAreas.insert(area.id)
              }
            }
          }
        )
      }
      .buttonStyle(.plain)
      .padding(.horizontal, Theme.hPadding)
      .background(isTapped(.area(area)) ? Theme.rowSelected : Color.clear)
      .onDrag {
        draggingId = "area:\(area.id)"
        return NSItemProvider(object: "area:\(area.id)" as NSString)
      }
      .onDrop(of: [.text], delegate: SidebarDropDelegate(
        targetKind: .area(area.id, index: index),
        areas: $areas,
        projects: $projects,
        projectAreaOverrides: $projectAreaOverrides,
        draggingId: $draggingId,
        expandedAreas: $expandedAreas
      ))

      if expandedAreas.contains(area.id) {
        ForEach(Array(projects(in: area.id).enumerated()), id: \.element.id) { pIdx, project in
          Button { go(.project(project)) } label: {
            SidebarProjectRow(name: project.name, progress: progress(for: project))
              .padding(.horizontal, Theme.hPadding)
          }
          .buttonStyle(.plain)
          .background(isTapped(.project(project)) ? Theme.rowSelected : Color.clear)
          .onDrag {
            draggingId = "project:\(project.id)"
            return NSItemProvider(object: "project:\(project.id)" as NSString)
          }
          .onDrop(of: [.text], delegate: SidebarDropDelegate(
            targetKind: .project(areaId: area.id, projectId: project.id, index: pIdx),
            areas: $areas,
            projects: $projects,
            projectAreaOverrides: $projectAreaOverrides,
            draggingId: $draggingId,
            expandedAreas: $expandedAreas
          ))
        }
      }
    }
    .padding(.bottom, 4)
  }

  // MARK: - Data

  private func projects(in areaId: String) -> [Project] {
    projects
      .filter { effectiveArea(for: $0) == areaId && $0.status == .active }
      .sorted { $0.sortOrder < $1.sortOrder }
  }

  private func effectiveArea(for project: Project) -> String? {
    projectAreaOverrides[project.id] ?? project.area
  }

  private var overdueCount: Int {
    let today = Calendar.current.startOfDay(for: Date())
    return tasks.filter {
      $0.status == .open && ($0.due.map { $0 < today } ?? false)
    }.count
  }

  private func count(for filter: TaskFilter) -> Int {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    return tasks.filter { task in
      guard task.status == .open else { return filter == .logbook }
      switch filter {
      case .inbox:
        return task.area == nil && task.project == nil && task.due == nil && task.start == nil
      case .today:
        return (task.due.map { cal.isDate($0, inSameDayAs: today) } ?? false)
          || (task.start.map { cal.isDate($0, inSameDayAs: today) } ?? false)
      default: return false
      }
    }.count
  }

  private func commitCreate() {
    let name = createName.trimmingCharacters(in: .whitespaces)
    let kind = createKind
    createKind = nil
    createName = ""
    guard !name.isEmpty, let kind else { return }
    Task {
      do {
        switch kind {
        case .area:
          try await client.areaCreate(name: name)
        case .project:
          try await client.projectCreate(title: name)
        }
        await load()
      } catch {
        // surface later
      }
    }
  }

  private func load() async {
    async let t = try? await client.tasksList()
    async let a = try? await client.areasList()
    async let p = try? await client.projectsList()
    let (tt, aa, pp) = await (t, a, p)
    tasks = tt ?? []
    areas = (aa ?? []).sorted { $0.sortOrder < $1.sortOrder }
    projects = pp ?? []
    if !didInitialize {
      expandedAreas = Set(areas.map { $0.id })
      didInitialize = true
    }
  }
}

// MARK: - Drop delegate

enum SidebarDropTarget {
  case area(String, index: Int)
  case project(areaId: String, projectId: String, index: Int)
}

struct SidebarDropDelegate: DropDelegate {
  let targetKind: SidebarDropTarget
  @Binding var areas: [Area]
  @Binding var projects: [Project]
  @Binding var projectAreaOverrides: [String: String]
  @Binding var draggingId: String?
  @Binding var expandedAreas: Set<String>

  private let haptic = UIImpactFeedbackGenerator(style: .light)

  func dropEntered(info: DropInfo) {
    guard let id = draggingId else { return }
    haptic.impactOccurred()
    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
      reorder(draggedId: id)
    }
  }

  func performDrop(info: DropInfo) -> Bool {
    draggingId = nil
    return true
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  private func reorder(draggedId: String) {
    if draggedId.hasPrefix("area:") {
      let aid = String(draggedId.dropFirst(5))
      guard let from = areas.firstIndex(where: { $0.id == aid }) else { return }
      switch targetKind {
      case .area(let overId, _):
        guard aid != overId, let to = areas.firstIndex(where: { $0.id == overId }) else { return }
        let item = areas.remove(at: from)
        areas.insert(item, at: to > from ? to - 1 : to)
      case .project:
        return  // dragging area over a project: ignore for now
      }
    } else if draggedId.hasPrefix("project:") {
      let pid = String(draggedId.dropFirst(8))
      switch targetKind {
      case .area(let areaId, _):
        // Drop project onto area row → move project into that area (append)
        moveProject(pid: pid, toAreaId: areaId, insertBefore: nil)
        expandedAreas.insert(areaId)
      case .project(let areaId, let overProjectId, _):
        guard pid != overProjectId else { return }
        moveProject(pid: pid, toAreaId: areaId, insertBefore: overProjectId)
      }
    }
  }

  private func moveProject(pid: String, toAreaId: String, insertBefore: String?) {
    guard let idx = projects.firstIndex(where: { $0.id == pid }) else { return }
    var p = projects[idx]
    projects.remove(at: idx)
    projectAreaOverrides[pid] = toAreaId
    p.sortOrder = nextSortOrder(in: toAreaId, before: insertBefore)
    // Reflow sortOrders in target area
    var siblings = projects.filter { ($0.id == p.id ? toAreaId : (projectAreaOverrides[$0.id] ?? $0.area)) == toAreaId }
      .sorted { $0.sortOrder < $1.sortOrder }
    if let beforeId = insertBefore, let pos = siblings.firstIndex(where: { $0.id == beforeId }) {
      siblings.insert(p, at: pos)
    } else {
      siblings.append(p)
    }
    for (i, sibling) in siblings.enumerated() {
      if let j = projects.firstIndex(where: { $0.id == sibling.id }) {
        projects[j].sortOrder = i * 10
      } else if sibling.id == p.id {
        var np = sibling
        np.sortOrder = i * 10
        projects.append(np)
      }
    }
  }

  private func nextSortOrder(in areaId: String, before: String?) -> Int {
    0  // actual ordering recomputed below
  }
}

// MARK: - Routes

enum Route: Hashable {
  case filter(TaskFilter)
  case area(Area)
  case project(Project)
  case agents
  case agent(Agent)
}
