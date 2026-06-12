import SwiftUI
import SwiftData

// MARK: - Notes field shared by Area / Project detail

/// Multi-line notes editor with inline markdown preview when blurred.
///
/// The TextField is ALWAYS in the view tree (controlled via `.opacity`),
/// not conditionally rendered — that's what fixes the previous "edit only
/// once" bug, where swapping Text↔TextField on focus change tore down the
/// freshly-mounted field before `@FocusState` could land on it.
///
/// Layout:
///   • TextField (axis .vertical, lineLimit 1...12) is the source of truth
///     for height — grows with content, scrolls internally past 12 lines.
///   • Text(AttributedString(markdown:)) overlays on top when the field
///     isn't focused and has content; tap forwards focus.
///   • Hit testing is gated on focus so taps go to the right layer.
@ViewBuilder
func notesField(_ text: Binding<String>,
                focused: FocusState<Bool>.Binding) -> some View {
  let showRender = !focused.wrappedValue && !text.wrappedValue.isEmpty
  ZStack(alignment: .topLeading) {
    TextField("Notes", text: text, axis: .vertical)
      .textFieldStyle(.plain)
      .focusEffectDisabled()
      .font(.septenaNotes)
      .foregroundStyle(Theme.inkSecondary)
      .focused(focused)
      .lineLimit(1...12)
      .opacity(showRender ? 0 : 1)
      .allowsHitTesting(!showRender)

    if showRender {
      Text(markdownAttributed(text.wrappedValue))
        .font(.septenaNotes)
        .foregroundStyle(Theme.inkSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
    }
  }
}

/// Render the raw notes string as an `AttributedString` with inline
/// markdown applied (**bold**, *italic*, `code`, [links], # headings via
/// `# Heading` rendering as bold + larger text). Falls back to plain text
/// if the parse fails.
func markdownAttributed(_ raw: String) -> AttributedString {
  // `.full` lets us honor `#`/`##` as headers; whitespace is preserved
  // so the user's line breaks survive the render.
  var opts = AttributedString.MarkdownParsingOptions()
  opts.interpretedSyntax = .full
  opts.allowsExtendedAttributes = true
  if var attr = try? AttributedString(markdown: raw, options: opts) {
    // Promote `# Heading` lines so they read as headings even though
    // AttributedString doesn't auto-style by header level on its own.
    for run in attr.runs where run.presentationIntent != nil {
      for component in run.presentationIntent?.components ?? [] {
        if case .header(let level) = component.kind {
          let size: CGFloat = level == 1 ? 18 : (level == 2 ? 16 : 15)
          attr[run.range].font = .system(size: size, weight: .semibold)
          attr[run.range].foregroundColor = Theme.inkPrimary
        }
      }
    }
    return attr
  }
  return AttributedString(raw)
}

// MARK: - Area detail (rename + project list + tasks scoped to area)

struct AreaDetailView: View {
  let area: Area
  @Environment(SectionTheme.self) private var theme
  @Environment(NavigationState.self) private var nav
  @Environment(AreasMutator.self) private var areasMutator
  @Environment(\.modelContext) private var modelContext

  @State private var draftName: String
  @State private var draftNotes: String
  @State private var originalNotes: String
  @State private var areas: [Area]
  @State private var projects: [Project]
  @State private var projectProgress: [String: Double] = [:]
  @State private var errorMessage: String?
  @FocusState private var notesFocused: Bool
  /// Global task sort — read/written here so flipping it from this menu
  /// re-renders the embedded TaskListView, which reads the same key.

  init(area: Area) {
    self.area = area
    _draftName = State(initialValue: area.title)
    _draftNotes = State(initialValue: area.context ?? "")
    _originalNotes = State(initialValue: area.context ?? "")
    // Seed area + project lists from cache before first render so the
    // project rows are present immediately on navigate-in.
    let ctx = LocalStore.shared.container.mainContext
    _areas = State(initialValue: LocalCache.areas(in: ctx))
    _projects = State(initialValue: LocalCache.projects(in: ctx))
  }

  var body: some View {
    // The title + notes + project roll-up are passed *into* TaskListView as
    // its embedded header, so the whole header scrolls away with the rows
    // instead of pinning at the top.
    TaskListView(
      filter: .area(area.id),
      embedded: true,
      excludeProjectedTasks: true
    ) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: Theme.iconTextGap) {
            AreaIcon(diameter: Theme.checkboxTap)
              .frame(width: Theme.checkboxTap, height: Theme.checkboxTap)
            ClickToEditTitle(placeholder: "Area", text: $draftName) { newName in
              commitName(newName)
            }
          }
          notesField($draftNotes, focused: $notesFocused)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 16)
        // Observe focus from a stable parent — if `.onChange` lives on the
        // TextField, blurring removes the field, the observer is torn down
        // before its closure can fire.
        .onChange(of: notesFocused) { _, focused in
          if !focused { commitNotes() }
        }

        VStack(alignment: .leading, spacing: 0) {
          ForEach(projectsInArea) { project in
            Button { nav.path = [.project(project)] } label: {
              projectRow(project)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .background(Theme.paperBackground)
    .septenaInlineTitle()
    .alert("Error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .task(id: area.id) { await load() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      Task { await load() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaStructureChanged)) { _ in
      Task { await load() }
    }
  }

  private var projectsInArea: [Project] {
    projects.filter { $0.area == area.id && $0.status == .active }
  }

  @ViewBuilder
  private func projectRow(_ project: Project) -> some View {
    HStack(alignment: .center, spacing: Theme.iconTextGap) {
      ProjectProgressIcon(progress: projectProgress[project.id] ?? 0,
                          tint: theme.accent)
        .frame(width: Theme.checkboxTap, height: Theme.checkboxTap)

      Text(project.title)
        .font(.septenaTaskTitle.weight(.semibold))
        .foregroundStyle(Theme.inkPrimary)
      Image(systemName: "chevron.right")
        .scaledFont(size: 10, weight: .semibold)
        .foregroundStyle(Theme.iconMuted)
      Spacer()
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 8)
    .frame(minHeight: Theme.rowHeight)
    .contentShape(Rectangle())
  }

  private func load() async {
    // Paint from cache first so the area screen isn't blank on cold open.
    let cachedAreas = LocalCache.areas(in: modelContext)
    let cachedProjects = LocalCache.projects(in: modelContext)
    if !cachedAreas.isEmpty { areas = cachedAreas }
    if !cachedProjects.isEmpty { projects = cachedProjects }

    async let allInArea = TaskReads.list(view: "all", area: area.id,
                                         context: modelContext)
    areas = LocalCache.areas(in: modelContext)
    projects = LocalCache.projects(in: modelContext)

    // Rehydrate the notes field from the freshly-loaded area record. The
    // route in nav.path holds the snapshot from when the sidebar last
    // refreshed, so coming back to this screen would otherwise show pre-save
    // notes even though the server has the new value. Guard on focus so we
    // never clobber a draft the user is actively typing.
    if !notesFocused, let fresh = areas.first(where: { $0.id == area.id }) {
      let serverNotes = fresh.context ?? ""
      if serverNotes != draftNotes {
        draftNotes = serverNotes
        originalNotes = serverNotes
      }
    }

    // Group tasks by project to compute progress per project.
    do {
      let items = await allInArea.items
      var done: [String: Int] = [:]
      var total: [String: Int] = [:]
      for t in items {
        guard let pid = t.project else { continue }
        switch t.status {
        case .done:                 done[pid, default: 0] += 1; total[pid, default: 0] += 1
        case .open:                 total[pid, default: 0] += 1
        case .cancelled, .someday:  break
        }
      }
      projectProgress = total.reduce(into: [:]) { acc, kv in
        acc[kv.key] = Double(done[kv.key] ?? 0) / Double(kv.value)
      }
    }
  }

  private func commitName(_ trimmed: String) {
    Task {
      do { try await areasMutator.rename(id: area.id, to: trimmed) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func commitNotes() {
    guard draftNotes != originalNotes else { return }
    originalNotes = draftNotes
    Task {
      do {
        try await areasMutator.setContext(id: area.id,
                                          context: draftNotes.isEmpty ? nil : draftNotes)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

// MARK: - Project detail (rename + notes + task list)

struct ProjectDetailView: View {
  let project: Project
  @Environment(SectionTheme.self) private var theme
  @Environment(ProjectsMutator.self) private var projectsMutator
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  @State private var draftName: String
  @State private var draftNotes: String
  @State private var draftRepo: String
  @State private var originalName: String
  @State private var originalNotes: String
  @State private var originalRepo: String
  @State private var status: ProjectStatus
  @State private var errorMessage: String?
  @State private var showingDeleteConfirm = false
  @State private var showingMoveToArea = false
  @State private var showingRepoEditor = false
  @State private var areas: [Area] = []
  /// Fraction of this project's tasks that are done (0...1). Drives the pie
  /// icon next to the project title — reloads whenever the page appears so it
  /// reflects completions made elsewhere too.
  @State private var progress: Double = 0
  @FocusState private var notesFocused: Bool
  /// Global task sort — kept in sync via @AppStorage so flipping it from
  /// this menu instantly re-renders the embedded TaskListView (which reads
  /// the same key).

  init(project: Project) {
    self.project = project
    _draftName = State(initialValue: project.title)
    _draftNotes = State(initialValue: project.notes ?? "")
    _draftRepo = State(initialValue: project.githubRepo ?? "")
    _originalName = State(initialValue: project.title)
    _originalNotes = State(initialValue: project.notes ?? "")
    _originalRepo = State(initialValue: project.githubRepo ?? "")
    _status = State(initialValue: project.status)
  }

  var body: some View {
    // Title + notes are passed *into* TaskListView as its embedded header so
    // the whole header scrolls away with the rows instead of pinning above.
    TaskListView(filter: .project(project.id), embedded: true) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: Theme.iconTextGap) {
            ProjectProgressIcon(progress: progress, tint: theme.accent,
                                diameter: Theme.checkboxTap, lineWidth: 2)
              .frame(width: Theme.checkboxTap, height: Theme.checkboxTap)
            ClickToEditTitle(placeholder: "Project", text: $draftName) { newName in
              commitNameTo(newName)
            }
          }
          notesField($draftNotes, focused: $notesFocused)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .onChange(of: notesFocused) { _, focused in
          if !focused { commitNotes() }
        }

        Hairline()
      }
    }
    .background(Theme.paperBackground)
    .septenaInlineTitle()
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button {
            showingRepoEditor = true
          } label: {
            Label("Repo…", systemImage: "chevron.left.forwardslash.chevron.right")
          }
          Button {
            showingMoveToArea = true
          } label: {
            Label("Move to Area…", systemImage: "folder")
          }
          Button {
            setStatus(.done)
          } label: {
            Label("Mark Done", systemImage: "checkmark.circle")
          }
          Button {
            setStatus(.cancelled)
          } label: {
            Label("Cancel Project", systemImage: "xmark.circle")
          }
          Divider()
          Button(role: .destructive) {
            showingDeleteConfirm = true
          } label: {
            Label("Delete Project", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis.circle").foregroundStyle(Theme.inkSecondary)
        }
      }
    }
    .sheet(isPresented: $showingMoveToArea) {
      AreaPickerSheet(areas: areas, currentAreaId: project.area) { newAreaId in
        moveToArea(newAreaId)
      }
      .presentationDetents([.medium, .large])
      .septenaSheetChrome()
    }
    .sheet(isPresented: $showingRepoEditor) {
      RepoEditorSheet(repo: $draftRepo) { commitRepo() }
        .presentationDetents([.height(180)])
        .septenaSheetChrome()
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
    .task(id: project.id) {
      await loadProgress()
      await loadAreas()
      await rehydrateNotes()
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      Task {
        await loadProgress()
        await loadAreas()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaStructureChanged)) { _ in
      Task {
        await loadAreas()
        await rehydrateNotes()
      }
    }
  }

  private func loadAreas() async {
    areas = LocalCache.areas(in: modelContext)
  }

  /// The project struct in nav.path is the snapshot from when the sidebar
  /// last refreshed; its `notes` may be older than what's on the server.
  /// Pull the latest record and update the draft — but only when the user
  /// isn't actively typing, so we never clobber an unsaved edit.
  private func rehydrateNotes() async {
    let fresh: Project? = LocalCache.projects(in: modelContext)
      .first(where: { $0.id == project.id })
    guard !notesFocused, let fresh else { return }
    let serverNotes = fresh.notes ?? ""
    if serverNotes != draftNotes {
      draftNotes = serverNotes
      originalNotes = serverNotes
    }
    if !showingRepoEditor {
      let serverRepo = fresh.githubRepo ?? ""
      if serverRepo != draftRepo {
        draftRepo = serverRepo
        originalRepo = serverRepo
      }
    }
  }

  private func moveToArea(_ newAreaId: String?) {
    Haptics.tick()
    Task {
      do {
        try await projectsMutator.setArea(id: project.id, area: newAreaId)
        // Project's `area` value is captured in `let project`; the route
        // identity changes on the next sidebar refresh.
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func loadProgress() async {
    // Compute optimistic progress from the cache first, then refresh.
    let cached = LocalCache.tasks(in: modelContext, filter: .project(project.id))
      + LocalCache.allTasks(in: modelContext).filter {
        $0.project == project.id && $0.status == .done
      }
    if !cached.isEmpty {
      var d = 0, t = 0
      for x in cached {
        switch x.status {
        case .done:                 d += 1; t += 1
        case .open:                 t += 1
        case .cancelled, .someday:  break
        }
      }
      progress = t > 0 ? Double(d) / Double(t) : 0
    }
    do {
      let all = await TaskReads.list(view: "all", project: project.id,
                                     context: modelContext).items
      var done = 0, total = 0
      for t in all {
        switch t.status {
        case .done:                 done += 1; total += 1
        case .open:                 total += 1
        case .cancelled, .someday:  break
        }
      }
      progress = total > 0 ? Double(done) / Double(total) : 0
    } catch {
      // Non-fatal — progress just stays at its previous value.
    }
  }

  private func commitNameTo(_ trimmed: String) {
    originalName = trimmed
    Task {
      do { try await projectsMutator.rename(id: project.id, to: trimmed) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func commitNotes() {
    guard draftNotes != originalNotes else { return }
    originalNotes = draftNotes
    Task {
      do { try await projectsMutator.setNotes(id: project.id, notes: draftNotes) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func commitRepo() {
    let trimmed = draftRepo.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed != draftRepo { draftRepo = trimmed }
    guard trimmed != originalRepo else { return }
    originalRepo = trimmed
    Task {
      do { try await projectsMutator.setGithubRepo(id: project.id, repo: trimmed) }
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
      do { try await projectsMutator.setStatus(id: project.id, status: newStatus) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func deleteProject() {
    Haptics.warning()
    Task {
      do {
        try await projectsMutator.delete(id: project.id)
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}


// MARK: - Area picker (used by Project "Move to Area…")

struct RepoEditorSheet: View {
  @Binding var repo: String
  let onCommit: () -> Void
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focused: Bool

  var body: some View {
    NavigationStack {
      VStack {
        HStack(spacing: 6) {
          Image(systemName: "chevron.left.forwardslash.chevron.right")
            .scaledFont(size: 11, weight: .medium)
            .foregroundStyle(Theme.inkSecondary)
          TextField("owner/repo", text: $repo)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.septenaNotes)
            .foregroundStyle(Theme.inkSecondary)
            .focused($focused)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .onSubmit { onCommit(); dismiss() }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        Spacer()
      }
      .navigationTitle("GitHub Repo")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { onCommit(); dismiss() }
        }
      }
      .onAppear { focused = true }
    }
    .macSheetFrame(width: 460, height: 200)
  }
}

struct AreaPickerSheet: View {
  let areas: [Area]
  let currentAreaId: String?
  let onPick: (String?) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Button { onPick(nil); dismiss() } label: {
          row(label: "No Area", icon: "tray", selected: currentAreaId == nil)
        }
        .buttonStyle(.plain)

        ForEach(areas) { area in
          Button { onPick(area.id); dismiss() } label: {
            row(label: area.title, icon: "square.stack.3d.up.fill",
                selected: currentAreaId == area.id)
          }
          .buttonStyle(.plain)
        }
      }
      .navigationTitle("Move to Area")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .macSheetFrame(width: 460, height: 480)
  }

  @ViewBuilder
  private func row(label: String, icon: String, selected: Bool) -> some View {
    HStack(spacing: 12) {
      if icon == "square.stack.3d.up.fill" {
        AreaIcon(diameter: 15, lineWidth: 1.1)
          .frame(width: 22)
      } else {
        Image(systemName: icon)
          .scaledFont(size: 15)
          .foregroundStyle(Theme.iconMuted)
          .frame(width: 22)
      }
      Text(label).foregroundStyle(Theme.inkPrimary)
      Spacer()
      if selected {
        Image(systemName: "checkmark")
          .scaledFont(size: 13, weight: .semibold)
          .foregroundStyle(Theme.inkSecondary)
      }
    }
    .contentShape(Rectangle())
  }
}
