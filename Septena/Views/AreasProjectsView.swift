import SwiftUI

// MARK: - Area detail (rename + project list + tasks scoped to area)

struct AreaDetailView: View {
  let area: Area
  @EnvironmentObject var client: SeptenaClient
  @EnvironmentObject var nav: NavigationState

  @State private var draftName: String
  @State private var originalName: String
  @State private var areas: [Area] = []
  @State private var projects: [Project] = []
  @State private var errorMessage: String?
  @FocusState private var titleFocused: Bool

  init(area: Area) {
    self.area = area
    _draftName = State(initialValue: area.title)
    _originalName = State(initialValue: area.title)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
          Image(systemName: "square.stack.3d.up.fill")
            .font(.system(size: 24))
            .foregroundStyle(Theme.iconMuted)
          TextField("Area", text: $draftName)
            .font(.septenaScreenTitle)
            .foregroundStyle(Theme.inkPrimary)
            .focused($titleFocused)
            .submitLabel(.done)
            .onSubmit { commitName() }
            .onChange(of: titleFocused) { _, focused in
              if !focused { commitName() }
            }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 12)

        ForEach(projectsInArea) { project in
          Button { nav.path.append(.project(project)) } label: {
            projectRow(project)
          }
          .buttonStyle(.plain)
        }
      }

      // Tasks directly in this area (no project). Projects are listed above
      // and own their own task lists, so Things-style.
      TaskListView(filter: .area(area.id), embedded: true, excludeProjectedTasks: true)
    }
    .background(Theme.paperBackground)
    .navigationBarTitleDisplayMode(.inline)
    .alert("Error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .task { await load() }
  }

  private var projectsInArea: [Project] {
    projects.filter { $0.area == area.id && $0.status == .active }
  }

  @ViewBuilder
  private func projectRow(_ project: Project) -> some View {
    // Icon + text geometry matches taskBody's checkbox / title so the column
    // lines up with the area-direct task rows below.
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .stroke(Theme.iconMuted, lineWidth: 1.5)
          .frame(width: 18, height: 18)
        Circle()
          .trim(from: 0, to: 0.25)
          .stroke(Theme.iconMuted, lineWidth: 6)
          .frame(width: 12, height: 12)
          .rotationEffect(.degrees(-90))
      }
      .frame(width: 20, alignment: .center)
      .padding(.top, 2)

      Text(project.title)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(Theme.inkPrimary)
      Image(systemName: "chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.iconMuted)
        .padding(.top, 4)
      Spacer()
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 12)
    .frame(minHeight: Theme.rowHeight)
    .contentShape(Rectangle())
  }

  private func load() async {
    async let a = client.areas()
    async let p = client.projects()
    areas = (try? await a) ?? []
    projects = (try? await p) ?? []
  }

  private func commitName() {
    let trimmed = draftName.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != originalName else {
      if trimmed.isEmpty { draftName = originalName }
      return
    }
    originalName = trimmed
    var next = areas
    if let idx = next.firstIndex(where: { $0.id == area.id }) {
      next[idx].title = trimmed
    }
    Task {
      do {
        areas = try await client.replaceAreas(next)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

// MARK: - Project detail (rename + notes + task list)

struct ProjectDetailView: View {
  let project: Project
  @EnvironmentObject var client: SeptenaClient
  @EnvironmentObject var theme: SectionTheme
  @Environment(\.dismiss) private var dismiss

  @State private var draftName: String
  @State private var draftNotes: String
  @State private var originalName: String
  @State private var originalNotes: String
  @State private var status: ProjectStatus
  @State private var errorMessage: String?
  @State private var showingDeleteConfirm = false
  @State private var showingMoreActions = false
  @FocusState private var titleFocused: Bool
  @FocusState private var notesFocused: Bool

  init(project: Project) {
    self.project = project
    _draftName = State(initialValue: project.title)
    _draftNotes = State(initialValue: project.notes ?? "")
    _originalName = State(initialValue: project.title)
    _originalNotes = State(initialValue: project.notes ?? "")
    _status = State(initialValue: project.status)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        // Editable serif title — same shape as ScreenTitle but with a TextField.
        HStack(spacing: 12) {
          // Pie glyph — matches SidebarProjectRow.
          ZStack {
            Circle()
              .stroke(Theme.iconMuted, lineWidth: 2)
              .frame(width: 22, height: 22)
            Circle()
              .trim(from: 0, to: 0.25)
              .stroke(Theme.iconMuted, lineWidth: 8)
              .frame(width: 14, height: 14)
              .rotationEffect(.degrees(-90))
          }
          .frame(width: 28, height: 28)
          TextField("Project", text: $draftName)
            .font(.septenaScreenTitle)
            .foregroundStyle(Theme.inkPrimary)
            .focused($titleFocused)
            .submitLabel(.next)
            .onSubmit { notesFocused = true }
            .onChange(of: titleFocused) { _, focused in
              if !focused { commitName() }
            }
        }

        // Notes: render basic markdown (bold/italic/code/links) when not
        // focused; tap to edit raw text.
        if notesFocused || draftNotes.isEmpty {
          TextField("Notes", text: $draftNotes, axis: .vertical)
            .font(.septenaNotes)
            .foregroundStyle(Theme.inkSecondary)
            .focused($notesFocused)
            .lineLimit(1...8)
            .onChange(of: notesFocused) { _, focused in
              if !focused { commitNotes() }
            }
        } else {
          Text(.init(draftNotes))
            .font(.septenaNotes)
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { notesFocused = true }
        }

      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.top, 12)
      .padding(.bottom, 16)

      Hairline()

      TaskListView(filter: .project(project.id), embedded: true)
    }
    .background(Theme.paperBackground)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { showingMoreActions = true } label: {
          Image(systemName: "ellipsis.circle").foregroundStyle(Theme.inkSecondary)
        }
      }
    }
    .sheet(isPresented: $showingMoreActions) {
      ActionSheet(title: project.title, actions: [
        .init(title: "Mark Done", icon: "checkmark.circle",
              perform: { setStatus(.done) }),
        .init(title: "Cancel Project", icon: "xmark.circle",
              perform: { setStatus(.cancelled) }),
        .init(title: "Delete Project", icon: "trash", role: .destructive,
              perform: { showingDeleteConfirm = true }),
      ])
      .presentationDetents([.height(320)])
    }
    .alert("Delete \(project.title)?", isPresented: $showingDeleteConfirm) {
      Button("Delete", role: .destructive) { deleteProject() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Tasks in this project keep their data but lose their project link.")
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

  private func commitName() {
    let trimmed = draftName.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != originalName else {
      if trimmed.isEmpty { draftName = originalName }
      return
    }
    originalName = trimmed
    Task {
      do { _ = try await client.updateProject(id: project.id, title: trimmed) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func commitNotes() {
    guard draftNotes != originalNotes else { return }
    originalNotes = draftNotes
    Task {
      do { _ = try await client.updateProject(id: project.id, notes: draftNotes) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func setStatus(_ newStatus: ProjectStatus) {
    switch newStatus {
    case .done: Haptics.success()
    case .cancelled: Haptics.warning()
    case .active: Haptics.tick()
    }
    status = newStatus
    Task {
      do { _ = try await client.updateProject(id: project.id, status: newStatus.rawValue) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func deleteProject() {
    Haptics.warning()
    Task {
      do {
        try await client.deleteProject(id: project.id)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

