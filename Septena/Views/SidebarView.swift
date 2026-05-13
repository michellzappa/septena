import SwiftUI

// Things-style homepage on iPhone: the root screen IS the sidebar.
// QuickFind + smart lists + areas/projects + Settings. See docs/things-reference/navigation.md.

struct SidebarRootView: View {
  @EnvironmentObject var client: SeptenaClient
  @EnvironmentObject var nav: NavigationState
  @EnvironmentObject var theme: SectionTheme

  @State private var areas: [Area] = []
  @State private var projects: [Project] = []
  @State private var counts: TasksCounts? = nil
  @State private var areaOpenCounts: [String: Int] = [:]
  @State private var projectOpenCounts: [String: Int] = [:]
  @State private var errorMessage: String?

  /// Briefly tints the tapped row so the user sees the hit register
  /// before the push transition begins (Things-style feedback).
  @State private var pulsedRoute: Route?
  @State private var pulseToken = 0

  /// Magic Plus on the homepage offers task / project / area creation.
  @State private var showingCreateMenu = false
  @State private var showingNewProject = false
  @State private var showingNewArea = false
  @State private var newAreaName = ""

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          QuickFindBar()
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 8)
            .padding(.bottom, 16)

          smartLists
            .padding(.bottom, 12)

          areasAndProjects

          Hairline()
            .padding(.top, 16)
            .padding(.bottom, 4)

          settingsRow

          Spacer(minLength: 120)
        }
      }
      .background(Theme.paperBackground)
      .navigationBarHidden(true)

      MagicPlusButton { showingCreateMenu = true }
        .padding(.trailing, Theme.hPadding)
        .padding(.bottom, 20)
    }
    .task { await load() }
    .refreshable { await load() }
    .confirmationDialog("Create", isPresented: $showingCreateMenu, titleVisibility: .hidden) {
      Button("New To-Do")    { nav.showingQuickEntry = true }
      Button("New Project")  { showingNewProject = true }
      Button("New Area")     { newAreaName = ""; showingNewArea = true }
      Button("Cancel", role: .cancel) {}
    }
    .sheet(isPresented: $showingNewProject) {
      NewProjectSheet(areas: areas) { title, areaId in
        createProject(title: title, areaId: areaId)
      }
      .presentationDetents([.medium])
    }
    .alert("New Area", isPresented: $showingNewArea) {
      TextField("Area name", text: $newAreaName)
      Button("Create") { createArea() }
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
      sidebarButton(.filter(.inbox)) {
        SmartListRow(icon: "tray.fill", tint: Theme.inboxBlue,
                     title: "Inbox", count: counts?.inboxCount)
      }
      .padding(.bottom, 10)

      sidebarButton(.filter(.today)) {
        SmartListRow(icon: "star.fill", tint: Theme.todayYellow,
                     title: "Today",
                     overdueBadge: counts?.reviewCount,
                     count: counts?.todayCount)
      }
      Button { pulse(.next) } label: {
        SmartListRow(icon: "circle.hexagongrid.fill", tint: Theme.nextPurple,
                     title: "Next")
      }
      .buttonStyle(.plain)
      .background(pulsedRoute == .next ? theme.accent.opacity(0.14) : Color.clear)
      .animation(.easeOut(duration: 0.25), value: pulsedRoute)
      sidebarButton(.filter(.upcoming)) {
        SmartListRow(icon: "calendar", tint: Theme.upcomingRed,
                     title: "Upcoming", count: counts?.upcomingCount)
      }
      sidebarButton(.filter(.unscheduled)) {
        SmartListRow(icon: "rectangle.stack.fill", tint: Theme.unscheduledTeal,
                     title: "Unscheduled", count: counts?.unscheduledCount)
      }
      sidebarButton(.filter(.logbook)) {
        SmartListRow(icon: "checkmark.square.fill", tint: Theme.logbookGreen,
                     title: "Logbook")
      }
      .padding(.top, 10)
    }
    .padding(.horizontal, Theme.hPadding)
  }

  @ViewBuilder
  private func sidebarButton<Content: View>(_ route: Route,
                                            @ViewBuilder label: () -> Content) -> some View {
    Button { pulse(route) } label: { label() }
      .buttonStyle(.plain)
      .background(pulsedRoute == route ? theme.accent.opacity(0.14) : Color.clear)
      .animation(.easeOut(duration: 0.25), value: pulsedRoute)
  }

  /// Flash a row's background, then push the route. The pulse fades after a
  /// short delay so re-entry to the same destination re-flashes next time.
  private func pulse(_ route: Route) {
    Haptics.tap()
    pulsedRoute = route
    pulseToken &+= 1
    let token = pulseToken
    nav.path.append(route)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
      if pulseToken == token { pulsedRoute = nil }
    }
  }

  // MARK: - Areas and projects

  @ViewBuilder
  private var areasAndProjects: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(topLevelProjects) { project in
        Button { pulse(.project(project)) } label: {
          SidebarProjectRow(name: project.title,
                            count: projectOpenCounts[project.id])
            .padding(.horizontal, Theme.hPadding)
        }
        .buttonStyle(.plain)
        .background(pulsedRoute == .project(project) ? theme.accent.opacity(0.14) : Color.clear)
        .animation(.easeOut(duration: 0.25), value: pulsedRoute)
      }

      if !topLevelProjects.isEmpty && !areas.isEmpty {
        Spacer().frame(height: 12)
      }

      ForEach(areas) { area in
        areaBlock(area)
      }
    }
  }

  @ViewBuilder
  private func areaBlock(_ area: Area) -> some View {
    let projectsInArea = projects.filter { $0.area == area.id && $0.status == .active }

    VStack(alignment: .leading, spacing: 0) {
      Hairline()
        .padding(.top, 12)
        .padding(.bottom, 6)

      Button { pulse(.area(area)) } label: {
        SidebarAreaRow(name: area.title, count: areaOpenCounts[area.id])
          .padding(.horizontal, Theme.hPadding)
      }
      .buttonStyle(.plain)
      .background(pulsedRoute == .area(area) ? theme.accent.opacity(0.14) : Color.clear)
      .animation(.easeOut(duration: 0.25), value: pulsedRoute)

      ForEach(projectsInArea) { project in
        Button { pulse(.project(project)) } label: {
          SidebarProjectRow(name: project.title,
                            count: projectOpenCounts[project.id])
            .padding(.horizontal, Theme.hPadding)
        }
        .buttonStyle(.plain)
        .background(pulsedRoute == .project(project) ? theme.accent.opacity(0.14) : Color.clear)
        .animation(.easeOut(duration: 0.25), value: pulsedRoute)
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
    Button { pulse(.settings) } label: {
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
      .padding(.horizontal, Theme.hPadding)
      .frame(height: 30)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(pulsedRoute == .settings ? theme.accent.opacity(0.14) : Color.clear)
    .animation(.easeOut(duration: 0.25), value: pulsedRoute)
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
      let allItems = try await all.items.filter { $0.status == .open }
      // Area count is *direct* tasks only — projects within the area carry
      // their own counts, double-counting at the area level would be noise.
      areaOpenCounts = Dictionary(
        grouping: allItems.filter { $0.project == nil },
        by: { $0.area ?? "" }
      ).mapValues { $0.count }
      projectOpenCounts = Dictionary(
        grouping: allItems.filter { $0.project != nil },
        by: { $0.project! }
      ).mapValues { $0.count }
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Sidebar primitives

struct QuickFindBar: View {
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13))
        .foregroundStyle(Theme.inkSecondary)
      Text("Quick Find")
        .font(.system(size: 15))
        .foregroundStyle(Theme.inkSecondary)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 36)
    .background(Theme.mutedSurface)
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }
}

struct SmartListRow: View {
  let icon: String
  let tint: Color
  let title: String
  var overdueBadge: Int? = nil
  var count: Int? = nil

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 22))
        .foregroundStyle(tint)
        .saturation(0.72)
        .frame(width: 24, alignment: .center)
      Text(title)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(Theme.inkPrimary)
      Spacer()
      if let b = overdueBadge, b > 0 {
        Text("\(b)")
          .font(.septenaBadge)
          .foregroundStyle(.white)
          .frame(minWidth: 20, minHeight: 20)
          .padding(.horizontal, 6)
          .background(Theme.overdueRed)
          .clipShape(Capsule())
      }
      if let c = count, c > 0 {
        Text("\(c)")
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      }
    }
    .frame(height: 38)
    .contentShape(Rectangle())
  }
}

struct SidebarAreaRow: View {
  let name: String
  var count: Int? = nil

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "square.stack.3d.up.fill")
        .font(.system(size: 18))
        .foregroundStyle(Theme.iconMuted)
        .frame(width: 24, alignment: .center)
      Text(name)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Theme.inkPrimary)
      Spacer()
      if let c = count, c > 0 {
        Text("\(c)")
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      }
    }
    .frame(height: Theme.sidebarRowHeight)
    .contentShape(Rectangle())
  }
}

struct SidebarProjectRow: View {
  let name: String
  var count: Int? = nil

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle()
          .stroke(Theme.iconMuted, lineWidth: 1.5)
          .frame(width: 16, height: 16)
        Circle()
          .trim(from: 0, to: 0.25)
          .stroke(Theme.iconMuted, lineWidth: 6)
          .frame(width: 10, height: 10)
          .rotationEffect(.degrees(-90))
      }
      .frame(width: 24, alignment: .center)
      Text(name)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(Theme.inkPrimary)
      Spacer()
      if let c = count, c > 0 {
        Text("\(c)")
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      }
    }
    .frame(height: 36)
    .contentShape(Rectangle())
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
      .navigationBarTitleDisplayMode(.inline)
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
