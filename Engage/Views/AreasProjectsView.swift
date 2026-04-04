import SwiftUI

struct AreasView: View {
  @EnvironmentObject var client: ConvexClient
  @State private var areas: [Area] = []
  @State private var projects: [Project] = []
  @State private var isLoading = false

  var body: some View {
    Group {
      if isLoading && areas.isEmpty {
        ProgressView()
      } else {
        List {
          ForEach(areas) { area in
            NavigationLink(value: area) {
              HStack {
                if let icon = area.icon {
                  Text(icon)
                }
                Text(area.name)
              }
            }
          }

          if !projectsWithoutArea.isEmpty {
            Section("No Area") {
              ForEach(projectsWithoutArea) { project in
                NavigationLink(value: project) {
                  Text(project.name)
                }
              }
            }
          }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Areas")
        .navigationDestination(for: Area.self) { area in
          AreaDetailView(area: area)
        }
        .navigationDestination(for: Project.self) { project in
          ProjectDetailView(project: project)
        }
        .refreshable { await load() }
      }
    }
    .task { await load() }
  }

  private var projectsWithoutArea: [Project] {
    projects.filter { $0.area == nil }
  }

  private func load() async {
    isLoading = true
    do {
      async let a = client.areasList()
      async let p = client.projectsList()
      areas = try await a
      projects = try await p
    } catch {}
    isLoading = false
  }
}

struct AreaDetailView: View {
  let area: Area
  @EnvironmentObject var client: ConvexClient
  @State private var tasks: [EngageTask] = []
  @State private var isLoading = false

  var body: some View {
    Group {
      if isLoading && tasks.isEmpty {
        ProgressView()
      } else {
        List(areaTasks) { task in
          TaskRowView(task: task)
        }
        .listStyle(.plain)
        .navigationTitle(area.name)
        .refreshable { await load() }
      }
    }
    .task { await load() }
  }

  private var areaTasks: [EngageTask] {
    tasks.filter { $0.status == .open && $0.area == area.id }
  }

  private func load() async {
    isLoading = true
    do {
      tasks = try await client.tasksList()
    } catch {}
    isLoading = false
  }
}

struct ProjectsView: View {
  @EnvironmentObject var client: ConvexClient
  @State private var projects: [Project] = []
  @State private var areas: [Area] = []
  @State private var isLoading = false

  var body: some View {
    Group {
      if isLoading && projects.isEmpty {
        ProgressView()
      } else {
        List {
          ForEach(projects.filter { $0.status == .active }) { project in
            NavigationLink(value: project) {
              HStack {
                Text(project.name)
                Spacer()
                Text("\(taskCount(for: project.id)) tasks")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Projects")
        .navigationDestination(for: Project.self) { project in
          ProjectDetailView(project: project)
        }
        .refreshable { await load() }
      }
    }
    .task { await load() }
  }

  private func taskCount(for projectId: String) -> Int {
    0 // populated on detail view
  }

  private func load() async {
    isLoading = true
    do {
      async let p = client.projectsList()
      async let a = client.areasList()
      projects = try await p
      areas = try await a
    } catch {}
    isLoading = false
  }
}

struct ProjectDetailView: View {
  let project: Project
  @EnvironmentObject var client: ConvexClient
  @State private var tasks: [EngageTask] = []
  @State private var isLoading = false

  var body: some View {
    Group {
      if isLoading && tasks.isEmpty {
        ProgressView()
      } else if projectTasks.isEmpty {
        ContentUnavailableView(
          "No tasks",
          systemImage: "folder",
          description: Text("This project is empty")
        )
      } else {
        List(projectTasks) { task in
          TaskRowView(task: task)
        }
        .listStyle(.plain)
        .navigationTitle(project.name)
        .refreshable { await load() }
      }
    }
    .task { await load() }
  }

  private var projectTasks: [EngageTask] {
    tasks.filter { $0.status == .open && $0.project == project.id }
  }

  private func load() async {
    isLoading = true
    do {
      tasks = try await client.tasksList()
    } catch {}
    isLoading = false
  }
}

struct InboxView: View {
  @EnvironmentObject var client: ConvexClient
  @State private var tasks: [EngageTask] = []
  @State private var isLoading = false

  var body: some View {
    Group {
      if isLoading && tasks.isEmpty {
        ProgressView()
      } else if inboxTasks.isEmpty {
        ContentUnavailableView("Inbox zero", systemImage: "tray", description: Text("All captured"))
      } else {
        List(inboxTasks) { task in
          TaskRowView(task: task)
        }
        .listStyle(.plain)
        .refreshable { await load() }
      }
    }
    .navigationTitle("Inbox")
    .task { await load() }
  }

  private var inboxTasks: [EngageTask] {
    tasks.filter {
      $0.status == .open &&
      $0.area == nil &&
      $0.project == nil &&
      $0.due == nil &&
      $0.start == nil
    }
  }

  private func load() async {
    isLoading = true
    do {
      tasks = try await client.tasksList()
    } catch {}
    isLoading = false
  }
}
