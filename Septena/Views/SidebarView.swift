import SwiftUI

// compact homepage on iPhone: the root screen IS the sidebar.
// QuickFind + smart lists + areas/projects + Settings. See docs/reference/navigation.md.

struct SidebarRootView: View {
  @EnvironmentObject var client: SeptenaClient
  @EnvironmentObject var nav: NavigationState
  @EnvironmentObject var theme: SectionTheme

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

  var body: some View {
    #if os(macOS)
    sidebarMac
    #else
    sidebarPhone
    #endif
  }

  /// iPhone / iPad layout: scrolling list with a floating Magic Plus over it.
  /// Settings is the discreet last row of the scroll.
  @ViewBuilder
  private var sidebarPhone: some View {
    ZStack(alignment: .bottomTrailing) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          smartLists.padding(.top, 12).padding(.bottom, 12)
          areasAndProjects
          Hairline().padding(.top, 16).padding(.bottom, 4)
          settingsRow
          Spacer(minLength: 120)
        }
      }
      .background(Theme.sidebarBackground)
      .septenaHideNavBar()

      MagicPlusButton { showingCreateMenu = true }
        .padding(.trailing, Theme.hPadding)
        .padding(.bottom, 20)
    }
    .modifier(SidebarSheets(
      showingCreateMenu: $showingCreateMenu,
      showingNewProject: $showingNewProject,
      showingNewArea: $showingNewArea,
      newAreaName: $newAreaName,
      errorMessage: $errorMessage,
      areas: areas,
      onNewTodo: { nav.showingQuickEntry = true },
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

  /// macOS layout: scroll above, fixed bottom bar with "+ New List" and a
  /// settings glyph — mirrors the reference design's sidebar chrome.
  @ViewBuilder
  private var sidebarMac: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          smartLists.padding(.top, 12).padding(.bottom, 12)
          areasAndProjects
          Spacer(minLength: 24)
        }
      }
      .background(Theme.sidebarBackground)

      Divider()

      HStack(spacing: 0) {
        Button { showingNewProject = true } label: {
          HStack(spacing: 6) {
            Image(systemName: "plus")
              .font(.system(size: 12, weight: .semibold))
            Text("New List")
              .font(.system(size: 13, weight: .regular))
          }
          .foregroundStyle(Theme.inkSecondary)
          .padding(.vertical, 8)
          .padding(.horizontal, 4)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Spacer()

        Button { nav.path = [.settings] } label: {
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, Theme.hPadding)
      .background(Theme.sidebarBackground)
    }
    .modifier(SidebarSheets(
      showingCreateMenu: $showingCreateMenu,
      showingNewProject: $showingNewProject,
      showingNewArea: $showingNewArea,
      newAreaName: $newAreaName,
      errorMessage: $errorMessage,
      areas: areas,
      onNewTodo: { nav.showingQuickEntry = true },
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

  @ViewBuilder
  private var smartLists: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Icon-tint rule: Today wears the accent because it's the verb of the
      // app; everything else sits in muted gray so the sidebar feels calm.
      sidebarButton(.filter(.inbox)) {
        SmartListRow(icon: "tray.fill", tint: Theme.iconMuted, title: "Inbox",
                     count: counts?.inboxCount)
      }
      .padding(.bottom, 10)

      sidebarButton(.filter(.today)) {
        // Two separate signals, both visible when relevant:
        //   • red pill = overdue (reviewCount) — surfaces what needs action
        //   • gray count = pinned-for-today (todayCount) — the "regular" total
        // Each hides independently when zero. They represent disjoint sets of
        // tasks server-side, so showing both together isn't double-counting.
        SmartListRow(icon: "sun.max.fill", tint: theme.accent,
                     title: "Today",
                     overdueBadge: counts?.reviewCount,
                     count: counts?.todayCount)
      }
      sidebarButton(.next) {
        SmartListRow(icon: "arrow.right", tint: Theme.iconMuted, title: "Next",
                     count: nextCount)
      }
      sidebarButton(.filter(.upcoming)) {
        SmartListRow(icon: "calendar", tint: Theme.iconMuted, title: "Upcoming",
                     count: counts?.upcomingCount)
      }
      sidebarButton(.filter(.unscheduled)) {
        SmartListRow(icon: "rectangle.stack.fill", tint: Theme.iconMuted,
                     title: "Unscheduled",
                     count: counts?.unscheduledCount)
      }
      sidebarButton(.filter(.logbook)) {
        SmartListRow(icon: "checkmark.square.fill", tint: Theme.iconMuted,
                     title: "Logbook")
      }
      .padding(.top, 10)
    }
    .padding(.horizontal, Theme.hPadding)
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
    RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(fill)
      .padding(.horizontal, -4)
  }

  // MARK: - Areas and projects

  @ViewBuilder
  private var areasAndProjects: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(topLevelProjects) { project in
        sidebarButton(.project(project)) {
          SidebarProjectRow(name: project.title,
                            progress: projectProgress[project.id] ?? 0,
                            count: projectOpenCount[project.id] ?? 0)
        }
      }

      if !topLevelProjects.isEmpty && !areas.isEmpty {
        Spacer().frame(height: 12)
      }

      ForEach(areas) { area in
        areaBlock(area)
      }
    }
    .padding(.horizontal, Theme.hPadding)
  }

  @ViewBuilder
  private func areaBlock(_ area: Area) -> some View {
    let projectsInArea = projects.filter { $0.area == area.id && $0.status == .active }

    VStack(alignment: .leading, spacing: 0) {
      // macOS sidebar already reads as a single quiet column; the hairline
      // between areas adds visual noise without grouping value. iOS keeps it
      // since the wider row spacing there benefits from an explicit divider.
      #if os(iOS)
      Hairline()
        .padding(.top, 12)
        .padding(.bottom, 6)
      #else
      Spacer().frame(height: 12)
      #endif

      sidebarButton(.area(area)) {
        SidebarAreaRow(name: area.title, count: areaOpenCount[area.id] ?? 0)
      }
      // Drag the area header to reorder. The whole block accepts drops so the
      // user can drop "above this area" without aiming at a 1pt hairline.
      .draggable(area.id) {
        // Drag preview — keep it close to the actual row look.
        Text(area.title)
          .font(.system(size: Theme.sidebarAreaTitleSize, weight: .semibold))
          .foregroundStyle(Theme.inkPrimary)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(Theme.cardSurface)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
      }

      ForEach(projectsInArea) { project in
        sidebarButton(.project(project)) {
          SidebarProjectRow(name: project.title,
                            progress: projectProgress[project.id] ?? 0,
                            count: projectOpenCount[project.id] ?? 0)
        }
      }
    }
    .dropDestination(for: String.self) { items, _ in
      guard let droppedId = items.first, droppedId != area.id else { return false }
      reorderArea(droppedId, before: area.id)
      return true
    }
  }

  /// Move the area with id `movedId` to the position immediately before
  /// `targetId`, then sync to the server.
  private func reorderArea(_ movedId: String, before targetId: String) {
    guard let from = areas.firstIndex(where: { $0.id == movedId }),
          let to = areas.firstIndex(where: { $0.id == targetId }),
          from != to else { return }
    Haptics.tick()
    var next = areas
    let item = next.remove(at: from)
    // After removal the target's index may have shifted by one.
    let insertAt = (from < to) ? to - 1 : to
    next.insert(item, at: insertAt)
    areas = next
    Task {
      do {
        areas = try await client.replaceAreas(next)
      } catch {
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
      async let next = client.list(view: "next")
      areas = try await a
      projects = try await p
      counts = try await c
      nextCount = (try? await next.items.count)

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
      // Area count = loose-in-area + sum of its projects' open counts.
      var areaCounts: [String: Int] = areaDirectOpen
      for project in projects {
        guard let aid = project.area, let n = projOpen[project.id] else { continue }
        areaCounts[aid, default: 0] += n
      }
      areaOpenCount = areaCounts
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Sidebar primitives

struct SmartListRow: View {
  let icon: String
  let tint: Color
  let title: String
  /// Red pill — used for "needs attention" (overdue / review).
  var overdueBadge: Int? = nil
  /// Muted gray count — neutral signal for how much sits behind the row
  /// (Inbox count, etc). Always rendered to the right of any overdue pill.
  var count: Int? = nil

  var body: some View {
    HStack(spacing: Theme.sidebarRowSpacing) {
      Image(systemName: icon)
        .font(.system(size: Theme.sidebarIconSize))
        .foregroundStyle(tint)
        .frame(width: Theme.sidebarIconSize + 4, alignment: .center)
      Text(title)
        .font(.system(size: Theme.sidebarTitleSize, weight: Theme.sidebarTitleWeight))
        .foregroundStyle(Theme.inkPrimary)
      Spacer()
      if let b = overdueBadge, b > 0 {
        Text("\(b)")
          .font(.septenaBadge)
          .foregroundStyle(.white)
          .frame(minWidth: 18, minHeight: 18)
          .padding(.horizontal, 5)
          .background(Theme.overdueRed)
          .clipShape(Capsule())
      }
      if let n = count, n > 0 {
        Text("\(n)")
          .font(.system(size: 12, weight: .regular))
          .foregroundStyle(Theme.inkSecondary.opacity(0.6))
      }
    }
    .frame(height: Theme.sidebarSmartRowHeight)
    .contentShape(Rectangle())
  }
}

struct SidebarAreaRow: View {
  let name: String
  /// Open task count rolled up across the area (loose + projects in it).
  var count: Int = 0

  var body: some View {
    HStack(spacing: Theme.sidebarRowSpacing) {
      Image(systemName: "square.stack.3d.up.fill")
        .font(.system(size: Theme.sidebarIconSize - 4))
        .foregroundStyle(Theme.iconMuted)
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
  private var resolvedLineWidth: CGFloat { lineWidth ?? 0.9 }
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
  let onCreate: (String, String?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var selectedAreaId: String?

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
private struct SidebarSheets: ViewModifier {
  @Binding var showingCreateMenu: Bool
  @Binding var showingNewProject: Bool
  @Binding var showingNewArea: Bool
  @Binding var newAreaName: String
  @Binding var errorMessage: String?
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
      .sheet(isPresented: $showingNewProject) {
        NewProjectSheet(areas: areas, onCreate: onCreateProject)
          .presentationDetents([.medium])
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
