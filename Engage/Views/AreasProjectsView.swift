import SwiftUI

// Area detail = editable title + list of projects in the area + unassigned tasks.
// See docs/things-reference/screens.md §4

struct AreaDetailView: View {
  let area: Area
  @EnvironmentObject var client: ConvexClient
  @EnvironmentObject var nav: NavigationState

  @State private var draftName: String
  @State private var originalName: String
  @State private var projects: [Project] = []
  @State private var tasks: [EngageTask] = []
  @State private var recentlyCompleted: Set<String> = []
  @State private var isCreating = false
  @State private var newTitle = ""
  @State private var newNotes = ""
  @FocusState private var titleFocused: Bool

  init(area: Area) {
    self.area = area
    _draftName = State(initialValue: area.name)
    _originalName = State(initialValue: area.name)
  }

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: "hexagon")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
          TextField("Area", text: $draftName)
            .font(.thingsScreenTitle)
            .foregroundStyle(.primary)
            .focused($titleFocused)
            .submitLabel(.done)
            .onSubmit { commitName() }
            .onChange(of: titleFocused) { _, focused in
              if !focused { commitName() }
            }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 8)
        .padding(.bottom, 16)

        if !areaProjects.isEmpty {
          ForEach(areaProjects) { project in
            NavigationLink(value: Route.project(project)) {
              HStack(spacing: 10) {
                Image(systemName: "circle")
                  .font(.system(size: 18))
                  .foregroundStyle(.secondary)
                Text(project.name)
                  .font(.thingsSectionHeader)
                  .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                  .font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(.secondary)
              }
              .padding(.horizontal, Theme.hPadding)
              .padding(.vertical, 14)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Hairline()
          }
        }

        if !areaTasks.isEmpty {
          ForEach(areaTasks) { task in
            NavigationLink(value: task) {
              ThingsTaskRow(task: task) { toggle(task) }
            }
            .buttonStyle(.plain)
            Hairline()
          }
        }

        if areaProjects.isEmpty && areaTasks.isEmpty && !isCreating {
          Text("Empty")
            .font(.thingsMeta)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 40)
        }

        if isCreating {
          InlineNewTaskRow(
            title: $newTitle, notes: $newNotes,
            defaultWhen: "Anytime", defaultWhenIcon: "square.stack.3d.up.fill", defaultWhenTint: Theme.anytimeTeal,
            onCommit: { commitNewTask() }, onCancel: { cancelNewTask() }
          )
          .padding(.top, 8)
        }

        Spacer(minLength: 120)
      }
    }
    .background(Color(.systemBackground))

    if !isCreating {
      MagicPlusButton {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isCreating = true }
      }
      .padding(.trailing, Theme.hPadding)
      .padding(.bottom, 20)
    }
    }
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
  }

  private func cancelNewTask() {
    withAnimation(.easeOut(duration: 0.2)) { isCreating = false }
    newTitle = ""; newNotes = ""
  }

  private func commitNewTask() {
    let t = newTitle.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { cancelNewTask(); return }
    let n = newNotes.isEmpty ? nil : newNotes
    Task {
      try? await client.taskCreate(
        title: t, notes: n, origin: .human, owner: "human",
        area: area.id, project: nil
      )
      newTitle = ""; newNotes = ""
      await load()
    }
  }

  private var areaProjects: [Project] {
    projects.filter { $0.area == area.id && $0.status == .active }
      .sorted { $0.sortOrder < $1.sortOrder }
  }

  private var areaTasks: [EngageTask] {
    tasks.filter { $0.area == area.id && $0.project == nil && isVisible($0) }
  }

  private func isVisible(_ task: EngageTask) -> Bool {
    task.status == .open || recentlyCompleted.contains(task.id)
  }

  private func commitName() {
    let trimmed = draftName.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != originalName else {
      if trimmed.isEmpty { draftName = originalName }
      return
    }
    originalName = trimmed
    Task {
      try? await client.areaUpdate(id: area.id, patch: ["name": trimmed])
    }
  }

  private func toggle(_ task: EngageTask) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if task.status == .open {
      recentlyCompleted.insert(task.id)
      Task {
        try? await client.taskComplete(id: task.id, completedBy: "human")
        await load()
      }
    } else if recentlyCompleted.contains(task.id) {
      recentlyCompleted.remove(task.id)
      Task {
        try? await client.taskUpdate(
          id: task.id,
          patch: ["status": "open", "completedAt": NSNull(), "completedBy": NSNull()],
          actor: "human"
        )
        await load()
      }
    }
  }

  private func load() async {
    async let p = try? await client.projectsList()
    async let t = try? await client.tasksList()
    projects = (await p) ?? []
    tasks = (await t) ?? []
  }
}

// Project detail = editable title + editable notes + task list

struct ProjectDetailView: View {
  let project: Project
  @EnvironmentObject var client: ConvexClient
  @EnvironmentObject var nav: NavigationState

  @State private var draftName: String
  @State private var draftNotes: String
  @State private var originalName: String
  @State private var originalNotes: String
  @State private var tasks: [EngageTask] = []
  @State private var recentlyCompleted: Set<String> = []
  @State private var isCreating = false
  @State private var newTitle = ""
  @State private var newNotes = ""
  @FocusState private var titleFocused: Bool
  @FocusState private var notesFocused: Bool

  init(project: Project) {
    self.project = project
    _draftName = State(initialValue: project.name)
    _draftNotes = State(initialValue: project.notes ?? "")
    _originalName = State(initialValue: project.name)
    _originalNotes = State(initialValue: project.notes ?? "")
  }

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle")
              .font(.system(size: 24))
              .foregroundStyle(.secondary)
              .padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
              TextField("Project", text: $draftName)
                .font(.thingsScreenTitle)
                .foregroundStyle(.primary)
                .focused($titleFocused)
                .submitLabel(.next)
                .onSubmit { notesFocused = true }
                .onChange(of: titleFocused) { _, focused in
                  if !focused { commitName() }
                }
              TextField("Notes", text: $draftNotes, axis: .vertical)
                .font(.thingsMeta)
                .foregroundStyle(.secondary)
                .focused($notesFocused)
                .lineLimit(1...6)
                .onChange(of: notesFocused) { _, focused in
                  if !focused { commitNotes() }
                }
            }
          }
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, 8)
          .padding(.bottom, 20)

          if !visibleTasks.isEmpty {
            ForEach(visibleTasks) { task in
              NavigationLink(value: task) {
                ThingsTaskRow(task: task) { toggle(task) }
              }
              .buttonStyle(.plain)
              Hairline()
            }
          } else if !isCreating {
            Text("No tasks")
              .font(.thingsMeta)
              .foregroundStyle(.secondary)
              .padding(.horizontal, Theme.hPadding)
              .padding(.top, 40)
          }

          if isCreating {
            InlineNewTaskRow(
              title: $newTitle, notes: $newNotes,
              defaultWhen: "Anytime", defaultWhenIcon: "square.stack.3d.up.fill", defaultWhenTint: Theme.anytimeTeal,
              onCommit: { commitNewTask() }, onCancel: { cancelNewTask() }
            )
            .padding(.top, 8)
          }

          Spacer(minLength: 120)
        }
      }
      .background(Color(.systemBackground))

      if !isCreating {
        MagicPlusButton {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isCreating = true }
        }
        .padding(.trailing, Theme.hPadding)
        .padding(.bottom, 20)
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
  }

  private var visibleTasks: [EngageTask] {
    tasks.filter {
      $0.project == project.id && ($0.status == .open || recentlyCompleted.contains($0.id))
    }
  }

  private func toggle(_ task: EngageTask) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if task.status == .open {
      recentlyCompleted.insert(task.id)
      Task {
        try? await client.taskComplete(id: task.id, completedBy: "human")
        await load()
      }
    } else if recentlyCompleted.contains(task.id) {
      recentlyCompleted.remove(task.id)
      Task {
        try? await client.taskUpdate(
          id: task.id,
          patch: ["status": "open", "completedAt": NSNull(), "completedBy": NSNull()],
          actor: "human"
        )
        await load()
      }
    }
  }

  private func commitName() {
    let trimmed = draftName.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != originalName else {
      if trimmed.isEmpty { draftName = originalName }
      return
    }
    originalName = trimmed
    Task { try? await client.projectUpdate(id: project.id, patch: ["name": trimmed]) }
  }

  private func commitNotes() {
    guard draftNotes != originalNotes else { return }
    originalNotes = draftNotes
    Task { try? await client.projectUpdate(id: project.id, patch: ["notes": draftNotes]) }
  }

  private func cancelNewTask() {
    withAnimation(.easeOut(duration: 0.2)) { isCreating = false }
    newTitle = ""
    newNotes = ""
  }

  private func commitNewTask() {
    let t = newTitle.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { cancelNewTask(); return }
    let n = newNotes.isEmpty ? nil : newNotes
    Task {
      try? await client.taskCreate(
        title: t, notes: n, origin: .human, owner: "human",
        area: project.area, project: project.id
      )
      newTitle = ""; newNotes = ""
      await load()
    }
  }

  private func load() async {
    tasks = (try? await client.tasksList()) ?? []
  }
}

// Legacy stubs kept for compatibility with any leftover references.

struct AreasView: View {
  var body: some View { SidebarView() }
}

struct ProjectsView: View {
  var body: some View { SidebarView() }
}

struct InboxView: View {
  var body: some View { TaskListView(filter: .inbox) }
}
