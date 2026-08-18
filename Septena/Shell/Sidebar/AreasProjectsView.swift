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
        .septenaEditableTitleCursor()
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
  @Environment(DayClock.self) private var clock
  @Environment(NavigationState.self) private var nav
  @Environment(\.horizontalSizeClass) private var hSize
  @Environment(AreasMutator.self) private var areasMutator
  @Environment(\.modelContext) private var modelContext

  @State private var draftName: String
  @State private var draftNotes: String
  @State private var originalNotes: String
  @State private var draftEmoji: String
  @State private var originalEmoji: String
  @State private var showingEmojiEditor = false
  @State private var draftAttachment: AreaAttachment?
  @State private var showingAttachmentEditor = false
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
    _draftEmoji = State(initialValue: area.emoji ?? "")
    _originalEmoji = State(initialValue: area.emoji ?? "")
    _draftAttachment = State(initialValue: area.attachment)
    // Seed area + project lists from cache before first render so the
    // project rows are present immediately on navigate-in.
    let ctx = LocalStore.shared.container.mainContext
    let structure = StructureCache.snapshot(in: ctx)
    _areas = State(initialValue: structure.areas)
    _projects = State(initialValue: structure.projects)
    // Seed project rings from the local mirror so the first paint matches the
    // sidebar / project detail — don't flash empty rings while load() runs.
    _projectProgress = State(initialValue:
      Self.cachedProjectProgress(areaId: area.id, context: ctx))
  }

  /// done / (done + open) per project in this area. Tasks filed in a project
  /// carry `project`, not `area`, so area-scoped task lists miss them — read
  /// the same entity aggregate the sidebar uses instead.
  private static func cachedProjectProgress(areaId: String,
                                            context: ModelContext) -> [String: Double] {
    let ratios = LocalCache.projectCompletionRatios(in: context)
    let ids = Set(LocalCache.projects(in: context)
      .filter { $0.area == areaId && $0.status == .active }
      .map(\.id))
    return ratios.filter { ids.contains($0.key) }
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
            Button { showingEmojiEditor = true } label: {
              AreaIcon(diameter: Theme.checkboxTap,
                       emoji: draftEmoji.isEmpty ? nil : draftEmoji)
                .frame(width: Theme.checkboxTap, height: Theme.checkboxTap)
                .contentShape(Rectangle())
                .inlineHover(capsule: true)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingEmojiEditor) {
              EmojiPickerContent(emoji: $draftEmoji) { commitEmoji($0) }
            }
            ClickToEditTitle(placeholder: "Area", text: $draftName,
                             onCommit: { commitName($0) }) {
              TaskNavMenu { NavMenuChevron() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          notesField($draftNotes, focused: $notesFocused)
          AttachmentZone(attachment: draftAttachment) { showingAttachmentEditor = true }
        }
        // Park the whole header on the task cards' content column so the area
        // glyph, notes, and the project rings / task checkboxes below all line
        // up at one X — instead of the header sitting 10–18pt to their left.
        .padding(.leading, TaskCardMetrics.headerLeading)
        .padding(.trailing, TaskCardMetrics.margin)
        .padding(.top, 12)
        .padding(.bottom, 16)
        // Observe focus from a stable parent — if `.onChange` lives on the
        // TextField, blurring removes the field, the observer is torn down
        // before its closure can fire.
        .onChange(of: notesFocused) { _, focused in
          if !focused { commitNotes() }
        }

        // Projects ride in the SAME grouped-card language as the task rows below
        // (rings for projects, checkboxes for loose tasks) under a quiet
        // "Projects" header — so the area reads as one continuous list rather
        // than a differently-indented block floating above the tasks.
        if !projectsInArea.isEmpty {
          projectsSectionHeader
          let areaProjects = projectsInArea
          ForEach(Array(areaProjects.enumerated()), id: \.element.id) { idx, project in
            Button { openProject(project) } label: {
              projectRow(project)
            }
            .buttonStyle(PlainHoverRowButtonStyle())
            .taskCardChrome(TaskCardPosition(index: idx, count: areaProjects.count))
          }
        }
      }
    }
    .septenaInlineTitle()
    .sheet(isPresented: $showingAttachmentEditor) {
      AttachmentEditorSheet(initial: draftAttachment) { commitAttachment($0) }
        .presentationDetents([.height(340), .large])
        .septenaSheetChrome()
    }
    .alert("Error", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .task(id: area.id) { await load() }
    .onChange(of: area) { old, fresh in
      // ID routes resolve the live record. Adopt an external rename only when
      // this detail has no local title draft in flight.
      if draftName == old.title {
        draftName = fresh.title
      }
    }
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

  /// A project lives *inside* this area, so on the iPhone push stack append it
  /// (animates in as a pane; Back returns here, not to the sidebar) rather than
  /// replacing the path — a same-depth swap flash-appears and pops past the
  /// area. The iPad/Mac split layout renders `path.last` directly, so it keeps
  /// the flat replace.
  private func openProject(_ project: Project) {
    #if os(macOS)
    nav.go(to: .project(id: project.id))
    #else
    nav.go(to: .project(id: project.id), push: hSize == .compact)
    #endif
  }

  /// Quiet "Projects" header over the project card — matches the group-header
  /// rhythm used by the mixed task lists (title parked on the card's content
  /// column, generous top whitespace as the group break).
  private var projectsSectionHeader: some View {
    Text("Projects")
      .sectionGroupHeaderTitleStyle()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, TaskCardMetrics.headerLeading)
      .padding(.trailing, TaskCardMetrics.margin)
      .padding(.top, 4)
      .padding(.bottom, 8)
  }

  @ViewBuilder
  private func projectRow(_ project: Project) -> some View {
    HStack(alignment: .center, spacing: Theme.iconTextGap) {
      // Ink (not accent) ring, sized + nudged to sit exactly over the task
      // checkboxes in the card below — the same treatment the mixed-list group
      // headers give a project ring.
      ProjectProgressIcon(progress: projectProgress[project.id] ?? 0,
                          tint: Theme.inkSecondary, diameter: 14)
        .frame(width: Theme.checkboxTap, alignment: .center)
        .offset(x: -Theme.checkboxLeadingNudge)

      Text(project.title)
        .font(.septenaTaskTitle.weight(.semibold))
        .foregroundStyle(Theme.inkPrimary)
      Image(systemName: "chevron.right")
        .scaledFont(size: 10, weight: .semibold)
        .foregroundStyle(Theme.iconMuted)
      Spacer()
    }
    // `taskCardChrome` adds the outer card margin; this is the in-card content
    // inset, so the ring lands on the checkbox column of the card below.
    .padding(.horizontal, TaskCardMetrics.contentInset)
    // Match the tightened task rows below so the area screen reads as one
    // dense list rather than airy projects over compact tasks.
    .padding(.vertical, Theme.rowVPaddingTight)
    .frame(minHeight: Theme.rowHeight)
    .contentShape(Rectangle())
  }

  private func load() async {
    let structure = StructureCache.snapshot(in: modelContext)
    areas = structure.areas
    projects = structure.projects
    projectProgress = Self.cachedProjectProgress(areaId: area.id, context: modelContext)

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

    // Same for the glyph — keep originalEmoji in lockstep so the editor's
    // onChange doesn't echo the refreshed value back as a write.
    if !showingEmojiEditor, let fresh = areas.first(where: { $0.id == area.id }) {
      let serverEmoji = fresh.emoji ?? ""
      if serverEmoji != draftEmoji {
        originalEmoji = serverEmoji
        draftEmoji = serverEmoji
      }
    }

    // Same for the attachment pointer — refresh from the loaded record unless
    // the editor is open (so we never clobber an in-flight edit).
    if !showingAttachmentEditor, let fresh = areas.first(where: { $0.id == area.id }) {
      draftAttachment = fresh.attachment
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

  private func commitEmoji(_ value: String) {
    guard value != originalEmoji else { return }
    originalEmoji = value
    Task {
      do {
        try await areasMutator.setEmoji(id: area.id,
                                        emoji: value.isEmpty ? nil : value)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func commitAttachment(_ attachment: AreaAttachment?) {
    draftAttachment = attachment
    Task {
      do { try await areasMutator.setAttachment(id: area.id, attachment: attachment) }
      catch { errorMessage = error.localizedDescription }
    }
  }
}

// MARK: - Project detail (rename + notes + task list)

struct ProjectDetailView: View {
  let project: Project
  @Environment(DayClock.self) private var clock
  @Environment(ProjectsMutator.self) private var projectsMutator
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(\.usesPushNavigation) private var usesPushNavigation

  @State private var draftName: String
  @State private var draftNotes: String
  @State private var originalName: String
  @State private var originalNotes: String
  @State private var draftAttachment: AreaAttachment?
  @State private var status: ProjectStatus
  @State private var errorMessage: String?
  @State private var showingDeleteConfirm = false
  @State private var showingMoveToArea = false
  @State private var showingAttachmentEditor = false
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
    _originalName = State(initialValue: project.title)
    _originalNotes = State(initialValue: project.notes ?? "")
    _draftAttachment = State(initialValue: project.attachment)
    _status = State(initialValue: project.status)
    // Seed the progress ring synchronously from the local cache so the very
    // first render already shows the right fraction — otherwise it paints an
    // empty ring (progress 0), then flashes to the cached value, then to the
    // refreshed one as `loadProgress()` resolves.
    _progress = State(initialValue:
      Self.cachedProgress(projectId: project.id,
                          context: LocalStore.shared.container.mainContext) ?? 0)
  }

  /// done / (done + open) for a project, computed synchronously from the local
  /// SwiftData mirror. `nil` when the project has no tasks cached yet (so the
  /// caller can keep whatever value it already has rather than reset to 0).
  private static func cachedProgress(projectId: String,
                                     context: ModelContext) -> Double? {
    var done = 0, total = 0
    for t in LocalCache.tasksWithProject(in: context) where t.project == projectId {
      switch t.status {
      case .done: done += 1; total += 1
      case .open: total += 1
      case .cancelled: break
      }
    }
    return total > 0 ? Double(done) / Double(total) : nil
  }

  var body: some View {
    // Title + notes are passed *into* TaskListView as its embedded header so
    // the whole header scrolls away with the rows instead of pinning above.
    TaskListView(filter: .project(project.id), embedded: true) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: Theme.iconTextGap) {
            // Same glyph as the mixed-list group headers: ink (not accent),
            // diameter 14 in the checkbox-width column so it reads identically
            // wherever a project progress ring appears.
            ProjectProgressIcon(progress: progress, tint: Theme.inkSecondary, diameter: 14)
              .frame(width: Theme.checkboxTap, alignment: .center)
              .offset(x: -Theme.checkboxLeadingNudge)
            ClickToEditTitle(placeholder: "Project", text: $draftName,
                             onCommit: { commitNameTo($0) }) {
              TaskNavMenu { NavMenuChevron() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          notesField($draftNotes, focused: $notesFocused)
          AttachmentZone(attachment: draftAttachment) { showingAttachmentEditor = true }
        }
        // Match the area page: park the header on the task cards' content
        // column so the progress ring sits over the checkboxes below.
        .padding(.leading, TaskCardMetrics.headerLeading)
        .padding(.trailing, TaskCardMetrics.margin)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .onChange(of: notesFocused) { _, focused in
          if !focused { commitNotes() }
        }

        Hairline()
      }
    }
    .septenaInlineTitle()
    .toolbar { projectDetailToolbar }
    .sheet(isPresented: $showingMoveToArea) {
      AreaPickerSheet(areas: areas, currentAreaId: project.area) { newAreaId in
        moveToArea(newAreaId)
      }
      .presentationDetents([.medium, .large])
      .septenaSheetChrome()
    }
    .sheet(isPresented: $showingAttachmentEditor) {
      AttachmentEditorSheet(initial: draftAttachment) { commitAttachment($0) }
        .presentationDetents([.height(340), .large])
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
    .onChange(of: project) { old, fresh in
      // Avoid clobbering an in-flight inline title edit, but reflect changes
      // synced from Septena or another device as soon as the local draft is
      // still the old stored value.
      if draftName == old.title {
        draftName = fresh.title
        originalName = fresh.title
      }
      if !notesFocused, draftNotes == (old.notes ?? "") {
        let notes = fresh.notes ?? ""
        draftNotes = notes
        originalNotes = notes
      }
      if !showingAttachmentEditor, draftAttachment == old.attachment {
        draftAttachment = fresh.attachment
      }
      status = fresh.status
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

  /// Project actions overflow. On iPad regular the window-level chrome owns the
  /// trailing buttons (a detail-page nav-bar "···" would float behind the global
  /// "+"), so the overflow renders only in the iPhone compact nav bar and on
  /// macOS. iPad reaches the same actions via the project's sidebar context menu.
  @ToolbarContentBuilder
  private var projectDetailToolbar: some ToolbarContent {
    #if os(iOS)
    if !usesPushNavigation {
      ToolbarItem(placement: .primaryAction) { projectOverflowMenu }
    }
    #else
    ToolbarItem(placement: .primaryAction) { projectOverflowMenu }
    #endif
  }

  private var projectOverflowMenu: some View {
    OverflowMenu {
      Button {
        showingAttachmentEditor = true
      } label: {
        Label("Attach…", systemImage: "paperclip")
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
    }
  }

  private func loadAreas() async {
    areas = StructureCache.snapshot(in: modelContext).areas
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
    if !showingAttachmentEditor {
      draftAttachment = fresh.attachment
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
    // Optimistic value straight from the cache (skip when empty so we don't
    // blink to 0). Assign only on a real change so an unchanged refresh never
    // re-renders the ring.
    if let cached = Self.cachedProgress(projectId: project.id, context: modelContext),
       cached != progress {
      progress = cached
    }
    do {
      let all = await TaskReads.list(view: "all", project: project.id,
                                     today: clock.today, now: clock.now,
                                     context: modelContext).items
      var done = 0, total = 0
      for t in all {
        switch t.status {
        case .done:                 done += 1; total += 1
        case .open:                 total += 1
        case .cancelled:            break
        }
      }
      let fresh = total > 0 ? Double(done) / Double(total) : 0
      if fresh != progress { progress = fresh }
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

  private func commitAttachment(_ attachment: AreaAttachment?) {
    draftAttachment = attachment
    Task {
      do { try await projectsMutator.setAttachment(id: project.id, attachment: attachment) }
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


// MARK: - Attachment (the one read-only context feed on an area/project)

/// Inline zone under an area/project title: a tappable chip (kind glyph +
/// name) with the attachment's live feed rows beneath it — upcoming events,
/// recent commits, or latest feed entries. Muted "Attach…" affordance when
/// none is set. Tapping the chip opens `AttachmentEditorSheet`. Paints the
/// cached snapshot immediately, then refreshes from the network per-device.
struct AttachmentZone: View {
  let attachment: AreaAttachment?
  let onTap: () -> Void

  @State private var snapshot: AttachmentSnapshot?
  @State private var didAttempt = false
  @State private var failureReason: String?
  @State private var expanded = false

  /// Collapsed row count before the "Show all" expander kicks in.
  private static let collapsedCount = 3
  /// How many items to pull into the snapshot so the expander has something to
  /// reveal without a refetch.
  private static let fetchDepth = 25

  var body: some View {
    if let attachment {
      let items = visibleItems(attachment)
      let shown = expanded ? items : Array(items.prefix(Self.collapsedCount))
      VStack(alignment: .leading, spacing: 5) {
        Button(action: onTap) { chip(attachment) }
          .buttonStyle(.plain)
          .contentShape(Rectangle())

        ForEach(shown) { item in
          itemRow(item)
        }

        if items.count > Self.collapsedCount {
          Button {
            a11yAnimate(.easeInOut(duration: 0.18)) { expanded.toggle() }
          } label: {
            Text(expanded ? "Show less" : "Show all (\(items.count))")
              .scaledFont(size: 11, weight: .medium)
              .foregroundStyle(Theme.inkSecondary)
              .padding(.leading, 17)
          }
          .buttonStyle(.plain)
        }

        // A failed fetch would otherwise look identical to "just a link" —
        // make it legible, and name the reason (e.g. "HTTP 410") so a
        // server-side block is diagnosable without a debugger.
        if didAttempt && snapshot == nil {
          Text(failureReason.map { "Couldn't load — \($0)" } ?? "Couldn't load — tap to check the URL")
            .scaledFont(size: 11)
            .foregroundStyle(Theme.iconMuted)
            .padding(.leading, 17)
        }
      }
      .task(id: attachment) {
        didAttempt = false
        failureReason = nil
        expanded = false
        snapshot = AttachmentFeedLoader.shared.cached(for: attachment)
        let outcome = await AttachmentFeedLoader.shared.fetch(attachment, maxItems: Self.fetchDepth)
        if let fresh = outcome.snapshot { snapshot = fresh }
        failureReason = outcome.failureReason
        didAttempt = true
      }
    } else {
      Button(action: onTap) {
        HStack(spacing: 6) {
          Image(systemName: "paperclip")
            .scaledFont(size: 11, weight: .medium)
          Text("Attach…")
            .font(.septenaNotes)
        }
        .foregroundStyle(Theme.iconMuted)
      }
      .buttonStyle(.plain)
      .contentShape(Rectangle())
    }
  }

  /// Snapshot items after the calendar's per-attachment all-day filter.
  /// git/feed items are never all-day, so their lists pass through unchanged.
  private func visibleItems(_ attachment: AreaAttachment) -> [AttachmentFeedItem] {
    let items = snapshot?.items ?? []
    guard attachment.kind == .calendar else { return items }
    switch attachment.allDayFilter {
    case .all:  return items
    case .hide: return items.filter { !$0.isAllDay }
    case .only: return items.filter { $0.isAllDay }
    }
  }

  @ViewBuilder
  private func chip(_ attachment: AreaAttachment) -> some View {
    HStack(spacing: 6) {
      Image(systemName: attachment.kind.glyph)
        .scaledFont(size: 11, weight: .medium)
        .foregroundStyle(Theme.inkSecondary)
      Text(snapshot?.subtitle ?? attachment.displayName)
        .font(.septenaNotes)
        .foregroundStyle(Theme.inkSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private func itemRow(_ item: AttachmentFeedItem) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(item.title)
        .scaledFont(size: 13)
        .foregroundStyle(Theme.inkPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 4)
      if let detail = item.detail {
        Text(detail)
          .scaledFont(size: 11)
          .foregroundStyle(Theme.iconMuted)
          .lineLimit(1)
          .layoutPriority(1)
      }
    }
    // Align event/commit text with the chip label (past the glyph column).
    .padding(.leading, 17)
  }
}

/// Intake for the one attachment: pick a kind (repo / calendar / feed), enter
/// the ref, or remove. `onCommit(nil)` detaches.
struct AttachmentEditorSheet: View {
  let initial: AreaAttachment?
  let onCommit: (AreaAttachment?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var kind: AreaAttachment.Kind
  @State private var ref: String
  @State private var allDay: AreaAttachment.AllDayFilter
  @FocusState private var focused: Bool

  init(initial: AreaAttachment?, onCommit: @escaping (AreaAttachment?) -> Void) {
    self.initial = initial
    self.onCommit = onCommit
    _kind = State(initialValue: initial?.kind ?? .calendar)
    _ref = State(initialValue: initial?.ref ?? "")
    _allDay = State(initialValue: initial?.allDayFilter ?? .all)
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Picker("Kind", selection: $kind) {
          ForEach(AreaAttachment.Kind.allCases, id: \.self) { k in
            Text(k.label).tag(k)
          }
        }
        .pickerStyle(.segmented)

        HStack(spacing: 6) {
          Image(systemName: kind.glyph)
            .scaledFont(size: 11, weight: .medium)
            .foregroundStyle(Theme.inkSecondary)
          TextField(kind.refPlaceholder, text: $ref)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.septenaNotes)
            .foregroundStyle(Theme.inkSecondary)
            .focused($focused)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(kind == .git ? .default : .URL)
            #endif
            .onSubmit { commit() }
        }

        // Calendar-only: how to treat all-day events (trips, birthdays…).
        if kind == .calendar {
          VStack(alignment: .leading, spacing: 6) {
            Text("All-day events")
              .scaledFont(size: 11, weight: .medium)
              .foregroundStyle(Theme.iconMuted)
            Picker("All-day events", selection: $allDay) {
              ForEach(AreaAttachment.AllDayFilter.allCases, id: \.self) { f in
                Text(f.label).tag(f)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
          }
        }

        if initial != nil {
          Button(role: .destructive) {
            onCommit(nil)
            dismiss()
          } label: {
            Label("Remove Attachment", systemImage: "trash")
              .font(.septenaNotes)
          }
          .buttonStyle(.plain)
        }

        Spacer()
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.top, 12)
      .navigationTitle("Attachment")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { commit() }
        }
      }
      .onAppear { focused = true }
    }
    .macSheetFrame(width: 460, height: kind == .calendar ? 320 : 260)
  }

  private func commit() {
    onCommit(AreaAttachment(kind: kind, ref: ref,
                            allDay: kind == .calendar ? allDay : nil).normalized)
    dismiss()
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
        .buttonStyle(PlainHoverRowButtonStyle())

        ForEach(areas) { area in
          Button { onPick(area.id); dismiss() } label: {
            row(label: area.title, icon: "square.stack.3d.up.fill",
                emoji: area.emoji, selected: currentAreaId == area.id)
          }
          .buttonStyle(PlainHoverRowButtonStyle())
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
  private func row(label: String, icon: String, emoji: String? = nil, selected: Bool) -> some View {
    HStack(spacing: 12) {
      if icon == "square.stack.3d.up.fill" {
        AreaIcon(diameter: 15, lineWidth: 1.1, emoji: emoji)
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
