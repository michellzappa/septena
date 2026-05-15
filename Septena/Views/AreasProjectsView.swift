import SwiftUI

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
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(NavigationState.self) private var nav

  @State private var draftName: String
  @State private var draftNotes: String
  @State private var originalNotes: String
  @State private var areas: [Area] = []
  @State private var projects: [Project] = []
  @State private var projectProgress: [String: Double] = [:]
  @State private var errorMessage: String?
  @FocusState private var notesFocused: Bool

  init(area: Area) {
    self.area = area
    _draftName = State(initialValue: area.title)
    _draftNotes = State(initialValue: area.context ?? "")
    _originalNotes = State(initialValue: area.context ?? "")
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          Image(systemName: "square.stack.3d.up.fill")
            .font(.system(size: 20))
            .foregroundStyle(Theme.iconMuted)
            .frame(width: 24, height: 24)
          ClickToEditTitle(placeholder: "Area", text: $draftName) { newName in
            commitName(newName)
          }
        }

        // Notes — backed by Area.context. The TextField is ALWAYS in the
        // tree (overlay pattern with opacity), so @FocusState survives the
        // display→edit handoff. A markdown-rendered Text overlays on top
        // when the field isn't focused and has content; tap → start editing.
        // Pressing Return inserts a newline (axis: .vertical); the field
        // grows to ~12 lines then scrolls internally.
        notesField($draftNotes, focused: $notesFocused)
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.top, 12)
      .padding(.bottom, 16)
      // Observe focus from a stable parent — if `.onChange` lives on the
      // TextField, blurring removes the field (the `if` branch flips), and
      // the observer is torn down before its closure can fire. Attaching it
      // here means the commit always runs when focus leaves.
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

      // Tasks directly in this area (no project). Projects are listed above
      // and own their own task lists, so compact.
      TaskListView(filter: .area(area.id), embedded: true, excludeProjectedTasks: true)
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
  }

  private var projectsInArea: [Project] {
    projects.filter { $0.area == area.id && $0.status == .active }
  }

  @ViewBuilder
  private func projectRow(_ project: Project) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      ProjectProgressIcon(progress: projectProgress[project.id] ?? 0,
                          tint: theme.accent,
                          diameter: 14,
                          lineWidth: 1.2)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      Text(project.title)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Theme.inkPrimary)
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Theme.iconMuted)
      Spacer()
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 8)
    .frame(minHeight: Theme.rowHeight)
    .contentShape(Rectangle())
  }

  private func load() async {
    async let a = client.areas()
    async let p = client.projects()
    async let allInArea = client.list(view: "all", area: area.id)
    areas = (try? await a) ?? []
    projects = (try? await p) ?? []

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
    if let items = try? await allInArea.items {
      var done: [String: Int] = [:]
      var total: [String: Int] = [:]
      for t in items {
        guard let pid = t.project else { continue }
        switch t.status {
        case .done:                done[pid, default: 0] += 1; total[pid, default: 0] += 1
        case .open:                total[pid, default: 0] += 1
        case .cancelled, .someday: break
        }
      }
      projectProgress = total.reduce(into: [:]) { acc, kv in
        acc[kv.key] = Double(done[kv.key] ?? 0) / Double(kv.value)
      }
    }
  }

  private func commitName(_ trimmed: String) {
    var next = areas
    if let idx = next.firstIndex(where: { $0.id == area.id }) {
      next[idx].title = trimmed
    }
    Task {
      do { areas = try await client.replaceAreas(next) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func commitNotes() {
    guard draftNotes != originalNotes else { return }
    originalNotes = draftNotes
    var next = areas
    if let idx = next.firstIndex(where: { $0.id == area.id }) {
      next[idx].context = draftNotes.isEmpty ? nil : draftNotes
    }
    Task {
      do { areas = try await client.replaceAreas(next) }
      catch { errorMessage = error.localizedDescription }
    }
  }
}

// MARK: - Project detail (rename + notes + task list)

struct ProjectDetailView: View {
  let project: Project
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss

  @State private var draftName: String
  @State private var draftNotes: String
  @State private var originalName: String
  @State private var originalNotes: String
  @State private var status: ProjectStatus
  @State private var errorMessage: String?
  @State private var showingDeleteConfirm = false
  @State private var showingMoreActions = false
  @State private var showingMoveToArea = false
  @State private var areas: [Area] = []
  /// Fraction of this project's tasks that are done (0...1). Drives the pie
  /// icon next to the project title — reloads whenever the page appears so it
  /// reflects completions made elsewhere too.
  @State private var progress: Double = 0
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
        HStack(spacing: 12) {
          ProjectProgressIcon(progress: progress, tint: theme.accent,
                              diameter: 20, lineWidth: 2)
            .frame(width: 24, height: 24)
          ClickToEditTitle(placeholder: "Project", text: $draftName) { newName in
            commitNameTo(newName)
          }
        }

        // Notes — see AreaDetailView for the overlay-pattern rationale.
        notesField($draftNotes, focused: $notesFocused)

      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.top, 12)
      .padding(.bottom, 16)
      // Observe focus from a stable parent — if `.onChange` lives on the
      // TextField, blurring removes the field (the `if` branch flips), and
      // the observer is torn down before its closure can fire.
      .onChange(of: notesFocused) { _, focused in
        if !focused { commitNotes() }
      }

      Hairline()

      TaskListView(filter: .project(project.id), embedded: true)
    }
    .background(Theme.paperBackground)
    .septenaInlineTitle()
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { showingMoreActions = true } label: {
          Image(systemName: "ellipsis.circle").foregroundStyle(Theme.inkSecondary)
        }
      }
    }
    .sheet(isPresented: $showingMoreActions) {
      ActionSheet(title: project.title, actions: [
        .init(title: "Move to Area…", icon: "folder",
              perform: { showingMoveToArea = true }),
        .init(title: "Mark Done", icon: "checkmark.circle",
              perform: { setStatus(.done) }),
        .init(title: "Cancel Project", icon: "xmark.circle",
              perform: { setStatus(.cancelled) }),
        .init(title: "Delete Project", icon: "trash", role: .destructive,
              perform: { showingDeleteConfirm = true }),
      ])
      .presentationDetents([.height(360)])
      .septenaSheetChrome()
    }
    .sheet(isPresented: $showingMoveToArea) {
      AreaPickerSheet(areas: areas, currentAreaId: project.area) { newAreaId in
        moveToArea(newAreaId)
      }
      .presentationDetents([.medium, .large])
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
    .onAppear { Task { await loadProgress() } }
  }

  private func loadAreas() async {
    areas = (try? await client.areas()) ?? []
  }

  /// The project struct in nav.path is the snapshot from when the sidebar
  /// last refreshed; its `notes` may be older than what's on the server.
  /// Pull the latest record and update the draft — but only when the user
  /// isn't actively typing, so we never clobber an unsaved edit.
  private func rehydrateNotes() async {
    guard !notesFocused,
          let fresh = (try? await client.projects())?.first(where: { $0.id == project.id })
    else { return }
    let serverNotes = fresh.notes ?? ""
    if serverNotes != draftNotes {
      draftNotes = serverNotes
      originalNotes = serverNotes
    }
  }

  private func moveToArea(_ newAreaId: String?) {
    Haptics.tick()
    Task {
      do {
        _ = try await client.updateProject(id: project.id, area: .some(newAreaId))
        // Project's `area` value is captured in `let project`; the route
        // identity changes on the next sidebar refresh.
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func loadProgress() async {
    do {
      let all = try await client.list(view: "all", project: project.id).items
      var done = 0, total = 0
      for t in all {
        switch t.status {
        case .done:                done += 1; total += 1
        case .open:                total += 1
        case .cancelled, .someday: break
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


// MARK: - Area picker (used by Project "Move to Area…")

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
  }

  @ViewBuilder
  private func row(label: String, icon: String, selected: Bool) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 15))
        .foregroundStyle(Theme.iconMuted)
        .frame(width: 22)
      Text(label).foregroundStyle(Theme.inkPrimary)
      Spacer()
      if selected {
        Image(systemName: "checkmark")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Theme.inkSecondary)
      }
    }
    .contentShape(Rectangle())
  }
}
