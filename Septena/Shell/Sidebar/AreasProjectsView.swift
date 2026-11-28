import SwiftUI
import SwiftData

// MARK: - Notes field shared by Area / Project detail

/// Multi-line notes editor with a markdown preview when blurred.
///
/// The TextField is ALWAYS in the view tree (hidden via `.opacity` and a
/// zero height), not conditionally rendered — that's what fixes the previous
/// "edit only once" bug, where swapping Text↔TextField on focus change tore
/// down the freshly-mounted field before `@FocusState` could land on it.
///
/// Layout:
///   • Focused (or empty): the TextField (axis .vertical, lineLimit 1...12)
///     edits the raw markdown.
///   • Blurred with content: the rendered preview shows the first
///     `previewLines` lines. Longer notes get a "Show more" toggle; expanding
///     pushes the tasks below down. A tap on a clamped preview expands it; a
///     tap on a full preview starts editing.
/// `selection` lets the project view drop the cursor under the first heading
/// of a freshly inserted notes template (`ContainerNotes.template`).
func notesField(_ text: Binding<String>,
                placeholder: String,
                selection: Binding<TextSelection?> = .constant(nil),
                focused: FocusState<Bool>.Binding,
                onShowHistory: (() -> Void)? = nil) -> some View {
  ContainerNotesField(text: text, placeholder: placeholder,
                      selection: selection, focused: focused,
                      onShowHistory: onShowHistory)
}

struct ContainerNotesField: View {
  @Binding var text: String
  let placeholder: String
  @Binding var selection: TextSelection?
  var focused: FocusState<Bool>.Binding
  var onShowHistory: (() -> Void)? = nil

  @State private var expanded = false
  @State private var clampedHeight: CGFloat = 0
  @State private var fullHeight: CGFloat = 0

  private var showRender: Bool { !focused.wrappedValue && !text.isEmpty }
  /// The preview is cut off at `previewLines`. Measured, not guessed from the
  /// line count, because a single long paragraph wraps past 3 lines too.
  private var isClamped: Bool { !expanded && fullHeight > clampedHeight + 1 }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ZStack(alignment: .topLeading) {
        TextField(placeholder, text: $text, selection: $selection, axis: .vertical)
          .textFieldStyle(.plain)
          .focusEffectDisabled()
          .font(.septenaNotes)
          .foregroundStyle(Theme.inkSecondary)
          .focused(focused)
          .lineLimit(1...12)
          // Hidden field must not hold the header open at its own height
          // while the (shorter) clamped preview shows.
          .frame(height: showRender ? 0 : nil, alignment: .top)
          .clipped()
          .opacity(showRender ? 0 : 1)
          .allowsHitTesting(!showRender)

        if showRender {
          let rendered = markdownAttributed(text)
          Text(rendered)
            .font(.septenaNotes)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(expanded ? nil : RegistryPlaceNotes.previewLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
              clampedHeight = $0
            }
            // The same text at full height, invisible: its height tells
            // whether the clamp cut anything off.
            .background(alignment: .topLeading) {
              Text(rendered)
                .font(.septenaNotes)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                  fullHeight = $0
                }
            }
            .textSelection(.enabled)
            .contentShape(Rectangle())
            .septenaEditableTitleCursor()
            .onTapGesture {
              if isClamped {
                a11yAnimate { expanded = true }
              } else {
                focused.wrappedValue = true
              }
            }
        }
      }

      if showRender && (isClamped || expanded) {
        Button {
          a11yAnimate { expanded.toggle() }
        } label: {
          HStack(spacing: 4) {
            Text(expanded ? RegistryPlaceNotes.showLessTitle : RegistryPlaceNotes.showMoreTitle)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
              .imageScale(.small)
          }
          .font(.septenaLabel)
          .foregroundStyle(Theme.inkSecondary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .contextMenu {
      if let onShowHistory {
        Button(action: onShowHistory) {
          Label(ContainerNotesCopy.historyMenuTitle, systemImage: "clock.arrow.circlepath")
        }
      }
    }
  }
}

/// Render the raw notes string for the blurred preview.
///
/// `ContainerNotes.previewLines` reads the lines, for this shell and AppKit.
/// `#`/`##` headings are semibold; `###` (agent log bylines) a quiet label.
func markdownAttributed(_ raw: String) -> AttributedString {
  let lines = ContainerNotes.previewLines(raw)
  var out = AttributedString()
  for (index, line) in lines.enumerated() {
    if index > 0 { out += AttributedString("\n") }
    out += renderNotesLine(line)
  }
  return out
}

private func renderNotesLine(_ line: NotesPreviewLine) -> AttributedString {
  switch line {
  case .blank:
    return AttributedString("")
  case .heading(let level, let text):
    var attr = ContainerNotes.inlineMarkdown(text)
    if level >= 3 {
      // `### <day> · <agent>` is how an agent log entry starts
      // (ContainerNotes): a quiet byline, not a section title.
      attr.font = .septenaLabel
      attr.foregroundColor = Theme.inkSecondary
    } else {
      attr.font = .system(size: level == 1 ? 18 : 16, weight: .semibold)
      attr.foregroundColor = Theme.inkPrimary
    }
    return attr
  case .item(let depth, let marker, let text):
    return AttributedString(String(repeating: "  ", count: depth) + marker + " ")
      + ContainerNotes.inlineMarkdown(text)
  case .quote(let text):
    var attr = ContainerNotes.inlineMarkdown(text)
    attr.font = Font.septenaNotes.italic()
    return attr
  case .body(let text):
    return ContainerNotes.inlineMarkdown(text)
  }
}

// MARK: - Area detail (rename + project list + tasks scoped to area)

struct AreaDetailView: View {
  let area: Area
  @Environment(DayClock.self) private var clock
  @Environment(NavigationState.self) private var nav
  @Environment(\.usesPushNavigation) private var usesPushNavigation
  @Environment(\.scenePhase) private var scenePhase
  @Environment(AreasMutator.self) private var areasMutator
  @Environment(ProjectsMutator.self) private var projectsMutator
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(\.modelContext) private var modelContext

  @State private var draftName: String
  @State private var draftNotes: String
  @State private var originalNotes: String
  @State private var notesProposal: NotesProposal?
  @State private var showingNotesHistory = false
  @State private var showingNewProject = false
  @State private var draftEmoji: String
  @State private var originalEmoji: String
  @State private var showingEmojiEditor = false
  @State private var areas: [Area]
  @State private var projects: [Project]
  @State private var projectProgress: [String: Double] = [:]
  @State private var projectOpenCounts: [String: Int] = [:]
  @State private var errorMessage: String?
  @State private var toastStore = SeptenaToastStore()
  @FocusState private var notesFocused: Bool
  /// Global task sort — read/written here so flipping it from this menu
  /// re-renders the embedded TaskListView, which reads the same key.

  init(area: Area) {
    self.area = area
    _draftName = State(initialValue: area.title)
    _draftNotes = State(initialValue: area.context ?? "")
    _originalNotes = State(initialValue: area.context ?? "")
    _notesProposal = State(initialValue: area.notesProposal)
    _draftEmoji = State(initialValue: area.emoji ?? "")
    _originalEmoji = State(initialValue: area.emoji ?? "")
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
    _projectOpenCounts = State(initialValue: LocalCache.projectOpenCounts(in: ctx))
  }

  /// done / (done + open) per project in this area. Tasks filed in a project
  /// carry `project`, not `area`, so area-scoped task lists miss them — read
  /// the same entity aggregate the sidebar uses instead.
  private static func cachedProjectProgress(areaId: String,
                                            context: ModelContext) -> [String: Double] {
    let ratios = LocalCache.projectCompletionRatios(in: context)
    // StructureCache, not a fresh fetch: SwiftUI re-runs this view's init on
    // every parent render.
    let ids = Set(StructureCache.snapshot(in: context).projects
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
      excludeProjectedTasks: true,
      embeddedNavRowIDs: navRowIDs,
      onActivateNavRow: activateNavRow
    ) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: Theme.iconTextGap) {
            Button {
              notesFocused = false
              #if os(iOS)
              Haptics.press()
              #endif
              showingEmojiEditor = true
            } label: {
              AreaIcon(diameter: Theme.checkboxTap,
                       emoji: draftEmoji.isEmpty ? nil : draftEmoji)
                .frame(width: Theme.checkboxTap, height: Theme.checkboxTap)
                .contentShape(Rectangle())
                .inlineHover(capsule: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Emoji")
            .popover(isPresented: $showingEmojiEditor) {
              EmojiPickerContent(emoji: $draftEmoji) { commitEmoji($0) }
            }
            ClickToEditTitle(placeholder: "Area", text: $draftName,
                             onCommit: { commitName($0) }) {
              if nav.showsTitleNavMenu(usesPushNavigation: usesPushNavigation) {
                TaskNavMenu { NavMenuChevron() }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          if let proposal = notesProposal {
            NotesProposalCard(
              proposal: proposal,
              currentNotes: draftNotes,
              onAccept: acceptProposal,
              onReject: rejectProposal
            )
          }
          notesField($draftNotes, placeholder: ContainerNotes.areaPlaceholder, focused: $notesFocused,
                     onShowHistory: TaskHistory.isAvailable ? { showingNotesHistory = true } : nil)
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
        // The block shows also when the area has no projects yet, so the
        // "New Project" row at its foot is always there (#706). The row is
        // the last slot of the same card.
        projectsSectionHeader
        let areaProjects = projectsInArea
        let cardCount = areaProjects.count + 1
        ForEach(Array(areaProjects.enumerated()), id: \.element.id) { idx, project in
          // The card wears the selection fill from touch-down, like a
          // sidebar row (`NavigationPressStyle`, SelectionLanguage.swift).
          // ↑/↓ reach the row and Return opens it, as on a task row (#850);
          // the keyboard selection wears the same card fill as a press.
          SelectableNavRowReader(id: Self.navRowID(project: project.id)) { selected in
            NavigationPressReader { pressed in
              Button { openProject(project) } label: {
                projectRow(project)
              }
              .buttonStyle(NavigationPressStyle(hoverCornerRadius: Theme.cornerRadiusSmall))
              .modifier(TaskMoveDrop(perform: { ids in
                handleProjectDrop(ids: ids, project: project)
              }))
              .taskCardChrome(TaskCardPosition(index: idx, count: cardCount),
                              isSelected: pressed || selected)
            }
          }
        }
        SelectableNavRowReader(id: Self.newProjectNavRowID) { selected in
          NavigationPressReader { pressed in
            Button {
              startNewProject()
            } label: {
              newProjectRow
            }
            .buttonStyle(NavigationPressStyle(hoverCornerRadius: Theme.cornerRadiusSmall))
            .taskCardChrome(TaskCardPosition(index: areaProjects.count, count: cardCount),
                            isSelected: pressed || selected)
          }
        }
      }
    }
    .septenaToastOverlay(store: toastStore)
    .septenaInlineTitle()
    // A blur is not the only way out of the notes field. Leaving the page
    // (Back, a swipe, a sidebar tap) or the app can end the field with no
    // blur, and the draft then never reached the store (#617).
    .onDisappear { commitNotes() }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { commitNotes() }
    }
    #if os(iOS)
    .toolbar {
      ToolbarItem(placement: usesPushNavigation ? .primaryAction : .topBarTrailing) {
        areaOverflowMenu
      }
      if !usesPushNavigation {
        ToolbarItem(placement: .topBarTrailing) { QuickFindToolbarButton() }
      }
    }
    #else
    .toolbar {
      ToolbarItem(placement: .primaryAction) { areaOverflowMenu }
    }
    #endif
    .sheet(isPresented: $showingNewProject) {
      NewProjectSheet(areas: areas, initialAreaId: area.id) { title, areaId in
        createProjectInArea(title: title, areaId: areaId)
      }
      .presentationDetents([.medium])
      .septenaSheetChrome()
    }
    .sheet(isPresented: $showingNotesHistory) {
      NotesHistorySheet(
        container: .area,
        containerID: area.id,
        containerTitle: draftName,
        currentNotes: draftNotes,
        onRestore: restoreNotes
      )
      .presentationDetents([.medium, .large])
      .septenaSheetChrome()
    }
    .alert(RegistryPrompts.errorTitle, isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button(RegistryPrompts.errorConfirmTitle) { errorMessage = nil }
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
      notesProposal = fresh.notesProposal
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      Task { await load() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaStructureChanged)) { _ in
      Task { await load() }
    }
  }

  private var areaOverflowMenu: some View {
    OverflowMenu {
      Button {
        showingNewProject = true
      } label: {
        Label(RegistryActions.title(.areaNewProject), systemImage: "plus")
      }
      Divider()
      // Sort By for this area's tasks (docs/LIST_SORT_SPEC.md §6).
      ListSortMenu(filter: .area(area.id))
    }
  }

  private func createProjectInArea(title: String, areaId: String?) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    Haptics.commit()
    Task {
      do {
        let project = try await projectsMutator.create(title: trimmed, area: areaId)
        // Recorded at the gesture, after the create lands: undo removes it.
        TaskUndo.recordProjectCreate(project, projects: projectsMutator)
        await load()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private var projectsInArea: [Project] {
    projects.filter { $0.area == area.id && $0.status == .active }
  }

  // MARK: Keyboard rows (#850)

  private static let newProjectNavRowID = SelectableNavRow.id("new-project")

  private static func navRowID(project id: String) -> String {
    SelectableNavRow.id("project." + id)
  }

  /// The project card's rows in screen order: each project, then "New
  /// Project". They lead the area list's ↑/↓ order.
  private var navRowIDs: [String] {
    projectsInArea.map { Self.navRowID(project: $0.id) } + [Self.newProjectNavRowID]
  }

  /// Return on a project card row does what its click does.
  private func activateNavRow(_ id: String) {
    if id == Self.newProjectNavRowID {
      startNewProject()
    } else if let project = projectsInArea.first(where: { Self.navRowID(project: $0.id) == id }) {
      openProject(project)
    }
  }

  private func startNewProject() {
    notesFocused = false
    Haptics.press()
    showingNewProject = true
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
    nav.go(to: .project(id: project.id), push: !usesPushNavigation)
    #endif
  }

  /// Drop 1 or more dragged tasks onto one of this area's project rows:
  /// re-home them in relative order, record one shared undo step, and show an
  /// undoable confirmation toast (`docs/MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md` §6.2).
  private func handleProjectDrop(ids: [String], project: Project) -> Bool {
    guard !ids.isEmpty else { return false }
    if TaskDragIDs.isNewTaskPayload(ids) {
      Haptics.commit()
      openProject(project)
      nav.requestNewTask()
      return true
    }
    let moving: [SeptenaTask] = ids.compactMap { id in
      guard let task = LocalCache.task(id: id, in: modelContext),
            !task.isHeading,
            task.project != project.id else { return nil }
      return task
    }
    guard !moving.isEmpty else { return false }
    Haptics.commit()
    let undoBefore = moving.map(TaskUndo.FilingSnapshot.init)
    taskMutator.moveToList(ids: moving.map(\.id), area: nil, project: project.id, acknowledge: true)
    TaskUndo.recordMove(before: undoBefore, context: modelContext, mutator: taskMutator)
    let ticket = TaskUndoTicket()
    let message = RegistryToasts.movedBulk(count: moving.count, destination: project.title)
    toastStore.show(message) {
      ticket.undo { TaskUndo.restore(undoBefore, using: taskMutator) }
      Task { await load() }
    }
    Task { await load() }
    return true
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

  /// Foot of the project card: the "New Project" add line (#706). Same
  /// language as the quick-add line (`QuickAddTriggerRow`): a quiet glyph in
  /// the checkbox column and the title in secondary ink.
  private var newProjectRow: some View {
    HStack(alignment: .center, spacing: Theme.iconTextGap) {
      Image(systemName: "plus")
        .scaledFont(size: 13, weight: .medium)
        .foregroundStyle(Theme.inkSecondary)
        .frame(width: Theme.checkboxTap, alignment: .center)
        .offset(x: -Theme.checkboxLeadingNudge)
      Text(RegistryActions.title(.areaNewProject))
        .font(.septenaTaskTitle)
        .foregroundStyle(Theme.inkSecondary)
      Spacer()
    }
    .padding(.horizontal, TaskCardMetrics.contentInset)
    .padding(.vertical, Theme.rowVPaddingTight)
    .frame(minHeight: Theme.rowHeight)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(RegistryActions.title(.areaNewProject))
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private func projectRow(_ project: Project) -> some View {
    HStack(alignment: .center, spacing: Theme.iconTextGap) {
      // Ink (not accent) ring, sized + nudged to sit exactly over the task
      // checkboxes in the card below — the same treatment the mixed-list group
      // headers give a project ring.
      Group {
        if project.checklistMode == nil {
          ProjectProgressIcon(progress: projectProgress[project.id] ?? 0, tint: Theme.inkSecondary, diameter: 14)
        } else {
          Image(systemName: "checklist").foregroundStyle(Theme.inkSecondary)
        }
      }
      .frame(width: Theme.checkboxTap, alignment: .center)
      .offset(x: -Theme.checkboxLeadingNudge)

      Text(project.title)
        .font(.septenaTaskTitle.weight(.semibold))
        .foregroundStyle(Theme.inkPrimary)
      Image(systemName: "chevron.right")
        .scaledFont(size: 10, weight: .semibold)
        .foregroundStyle(Theme.iconMuted)
      Spacer()
      SidebarCount(count: projectOpenCounts[project.id] ?? 0)
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
    projectOpenCounts = LocalCache.projectOpenCounts(in: modelContext)

    // Rehydrate the notes field from the freshly-loaded area record. The
    // route in nav.path holds the snapshot from when the sidebar last
    // refreshed, so coming back to this screen would otherwise show pre-save
    // notes even though the server has the new value. Guard on focus so we
    // never clobber a draft the user is actively typing.
    if let fresh = areas.first(where: { $0.id == area.id }) {
      notesProposal = fresh.notesProposal
      if !notesFocused {
        let serverNotes = fresh.context ?? ""
        if serverNotes != draftNotes {
          draftNotes = serverNotes
          originalNotes = serverNotes
        }
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
  }

  private func commitName(_ trimmed: String) {
    Task {
      do { try await areasMutator.rename(id: area.id, to: trimmed) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func commitNotes() {
    guard draftNotes != originalNotes else { return }
    let value = draftNotes
    originalNotes = value
    Task {
      do {
        try await areasMutator.setContext(id: area.id,
                                          context: value.isEmpty ? nil : value)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func acceptProposal() {
    guard let proposal = notesProposal else { return }
    let before = draftNotes.isEmpty ? nil : draftNotes
    let merged = ContainerNotes.replacingBrief(in: before, with: proposal.body)
    Haptics.commit()
    notesFocused = false
    draftNotes = merged
    originalNotes = merged
    notesProposal = nil
    TaskUndo.recordAreaProposalDecision(
      id: area.id,
      accepted: true,
      beforeNotes: before,
      afterNotes: merged.isEmpty ? nil : merged,
      proposal: proposal,
      areas: areasMutator
    )
    Task {
      do { try await areasMutator.acceptNotesProposal(id: area.id) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func rejectProposal() {
    guard let proposal = notesProposal else { return }
    let current = draftNotes.isEmpty ? nil : draftNotes
    Haptics.commit()
    notesProposal = nil
    TaskUndo.recordAreaProposalDecision(
      id: area.id,
      accepted: false,
      beforeNotes: current,
      afterNotes: current,
      proposal: proposal,
      areas: areasMutator
    )
    Task {
      do { try await areasMutator.rejectNotesProposal(id: area.id) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func restoreNotes(_ restored: String) {
    let before = draftNotes.isEmpty ? nil : draftNotes
    let after = restored.isEmpty ? nil : restored
    guard (before ?? "") != (after ?? "") else { return }
    Haptics.commit()
    notesFocused = false
    draftNotes = restored
    originalNotes = restored
    TaskUndo.recordAreaNotesRestore(id: area.id, before: before, after: after, areas: areasMutator)
    Task {
      do { try await areasMutator.setContext(id: area.id, context: after) }
      catch { errorMessage = error.localizedDescription }
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
}

// MARK: - Project detail (rename + notes + task list)

struct ProjectDetailView: View {
  let project: Project
  @Environment(DayClock.self) private var clock
  @Environment(NavigationState.self) private var nav
  @Environment(ProjectsMutator.self) private var projectsMutator
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(\.usesPushNavigation) private var usesPushNavigation
  @Environment(\.scenePhase) private var scenePhase

  @State private var draftName: String
  @State private var draftNotes: String
  @State private var originalName: String
  @State private var originalNotes: String
  @State private var notesProposal: NotesProposal?
  @State private var showingNotesHistory = false
  @State private var status: ProjectStatus
  @State private var errorMessage: String?
  @State private var showingDeleteConfirm = false
  @State private var showingMoveToArea = false
  @State private var areas: [Area] = []
  /// Fraction of this project's tasks that are done (0...1). Drives the pie
  /// icon next to the project title — reloads whenever the page appears so it
  /// reflects completions made elsewhere too.
  @State private var progress: Double = 0
  @FocusState private var notesFocused: Bool
  /// Cursor for the notes field; set when the template is inserted.
  @State private var notesSelection: TextSelection?
  /// Global task sort — kept in sync via @AppStorage so flipping it from
  /// this menu instantly re-renders the embedded TaskListView (which reads
  /// the same key).

  init(project: Project) {
    self.project = project
    _draftName = State(initialValue: project.title)
    _draftNotes = State(initialValue: project.notes ?? "")
    _originalName = State(initialValue: project.title)
    _originalNotes = State(initialValue: project.notes ?? "")
    _notesProposal = State(initialValue: project.notesProposal)
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
  ///
  /// Reads the memoized ratios (`ProjectProgressCache`), the same numbers the
  /// sidebar ring draws. This runs from `init`, which SwiftUI re-runs on every
  /// parent render; it used to build a row object for every project task in
  /// the store, logbook included, each time.
  private static func cachedProgress(projectId: String,
                                     context: ModelContext) -> Double? {
    LocalCache.projectCompletionRatios(in: context)[projectId]
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
            Group {
              if project.checklistMode == nil {
                ProjectProgressIcon(progress: progress, tint: Theme.inkSecondary, diameter: 14)
              } else {
                Image(systemName: "checklist").foregroundStyle(Theme.inkSecondary)
              }
            }
            .frame(width: Theme.checkboxTap, alignment: .center)
            .offset(x: -Theme.checkboxLeadingNudge)
            ClickToEditTitle(placeholder: "Project", text: $draftName,
                             onCommit: { commitNameTo($0) }) {
              if nav.showsTitleNavMenu(usesPushNavigation: usesPushNavigation) {
                TaskNavMenu { NavMenuChevron() }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let share = project.share {
              Button { SeptaskSharing.present(projectID: project.id) } label: {
                MemberAvatars(share: share)
                  .frame(minHeight: 44)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
          if let proposal = notesProposal {
            NotesProposalCard(
              proposal: proposal,
              currentNotes: draftNotes,
              onAccept: acceptProposal,
              onReject: rejectProposal
            )
          }
          notesField($draftNotes, placeholder: ContainerNotes.projectPlaceholder,
                     selection: $notesSelection, focused: $notesFocused,
                     onShowHistory: TaskHistory.isAvailable ? { showingNotesHistory = true } : nil)
        }
        // Match the area page: park the header on the task cards' content
        // column so the progress ring sits over the checkboxes below.
        .padding(.leading, TaskCardMetrics.headerLeading)
        .padding(.trailing, TaskCardMetrics.margin)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .onChange(of: notesFocused) { _, focused in
          if focused {
            // Empty notes start from the template headings, cursor under
            // the first one (docs/PROJECT_NOTES_SPEC.md §6).
            if draftNotes.isEmpty {
              draftNotes = ContainerNotes.template
              notesSelection = TextSelection(
                insertionPoint: ContainerNotes.templateCursorIndex(in: draftNotes))
            }
          } else {
            // A template nobody typed into is not notes: keep them empty.
            if ContainerNotes.isUntouchedTemplate(draftNotes) { draftNotes = "" }
            commitNotes()
          }
        }

        Hairline()
      }
    }
    .septenaInlineTitle()
    // A blur is not the only way out of the notes field. Leaving the page
    // (Back, a swipe, a sidebar tap) or the app can end the field with no
    // blur, and the draft then never reached the store (#617).
    .onDisappear { commitNotes() }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { commitNotes() }
    }
    .toolbar { projectDetailToolbar }
    .sheet(isPresented: $showingMoveToArea) {
      MovePickerSheet(areas: areas, projects: [], currentAreaId: project.area,
                      noneTitle: String(localized: "No Area")) { newAreaId, _ in
        moveToArea(newAreaId)
      }
      .presentationDetents([.medium, .large])
      .septenaSheetChrome()
    }
    .sheet(isPresented: $showingNotesHistory) {
      NotesHistorySheet(
        container: .project,
        containerID: project.id,
        containerTitle: draftName,
        currentNotes: draftNotes,
        onRestore: restoreNotes
      )
      .presentationDetents([.medium, .large])
      .septenaSheetChrome()
    }
    .confirmationDialog(deleteCopy.title, isPresented: $showingDeleteConfirm,
                        titleVisibility: .visible) {
      Button(deleteCopy.confirmTitle ?? "", role: .destructive) { deleteProject() }
      Button(RegistryPrompts.cancelTitle, role: .cancel) {}
    } message: {
      Text(deleteCopy.message)
    }
    .alert(RegistryPrompts.errorTitle, isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button(RegistryPrompts.errorConfirmTitle) { errorMessage = nil }
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
      notesProposal = fresh.notesProposal
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

  /// Project actions overflow. On Septena Life's iPad regular canvas the
  /// window-level chrome owns the trailing buttons (a detail-page nav-bar "···"
  /// would float behind the global "+"), so the overflow renders only in the
  /// iPhone compact nav bar there. Septask has no window-level overlay bar, so
  /// it keeps the overflow in the detail nav bar on iPad and unfolded iPhone Duo
  /// just like macOS.
  @ToolbarContentBuilder
  private var projectDetailToolbar: some ToolbarContent {
    #if os(iOS)
    if !usesPushNavigation {
      ToolbarItem(placement: .topBarTrailing) { projectOverflowMenu }
      ToolbarItem(placement: .topBarTrailing) { QuickFindToolbarButton() }
    } else {
      ToolbarItem(placement: .primaryAction) { projectOverflowMenu }
    }
    #else
    ToolbarItem(placement: .primaryAction) { projectOverflowMenu }
    #endif
  }

  private var projectOverflowMenu: some View {
    OverflowMenu {
      Button {
        nav.shouldCreateHeading = true
      } label: {
        Label(RegistryActions.title(.sectionNew), systemImage: "rectangle.split.1x2")
      }
      // Sort By for this project's tasks (docs/LIST_SORT_SPEC.md §6).
      ListSortMenu(filter: .project(project.id))
      Divider()
      Button {
        showingMoveToArea = true
      } label: {
        Label(RegistryActions.title(.projectMove), systemImage: RegistryIcons.sfSymbol(for: "action.move"))
      }
      Button {
        SeptaskSharing.present(projectID: project.id)
      } label: {
        Label(RegistryActions.title(.projectShare), systemImage: RegistryIcons.sfSymbol(for: "action.share_project"))
      }
      Divider()
      Button {
        setStatus(.done)
      } label: {
        Label(RegistryActions.title(.projectMarkDone), systemImage: "checkmark.circle")
      }
      Button {
        setStatus(.cancelled)
      } label: {
        Label(RegistryActions.title(.projectCancel), systemImage: "xmark.circle")
      }
      // A shared project ends from its Share screen.
      if project.share == nil {
        Divider()
        Button(role: .destructive) {
          showingDeleteConfirm = true
        } label: {
          Label(RegistryActions.title(.projectDelete), systemImage: "trash")
        }
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
    guard let fresh else { return }
    notesProposal = fresh.notesProposal
    guard !notesFocused else { return }
    let serverNotes = fresh.notes ?? ""
    if serverNotes != draftNotes {
      draftNotes = serverNotes
      originalNotes = serverNotes
    }
  }

  private func moveToArea(_ newAreaId: String?) {
    let oldAreaId = project.area
    guard oldAreaId != newAreaId else { return }
    Haptics.commit()
    let mutator = projectsMutator
    let projectId = project.id
    Task {
      do {
        try await mutator.setArea(id: projectId, area: newAreaId)
        TaskUndo.record(
          name: String(localized: "Move Project", comment: "AreaPickerSheet: undo action"),
          undo: { Task { try? await mutator.setArea(id: projectId, area: oldAreaId) } },
          redo: { Task { try? await mutator.setArea(id: projectId, area: newAreaId) } }
        )
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
        case .cancelled, .checklistChecked: break
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
    // A template nobody typed into is not notes (the blur clears it too).
    let value = ContainerNotes.isUntouchedTemplate(draftNotes) ? "" : draftNotes
    guard value != originalNotes else { return }
    let from = originalNotes
    originalNotes = value
    Task {
      do { try await projectsMutator.setNotes(id: project.id, notes: value, from: from) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func acceptProposal() {
    guard let proposal = notesProposal else { return }
    let before = draftNotes.isEmpty ? nil : draftNotes
    let merged = ContainerNotes.replacingBrief(in: before, with: proposal.body)
    Haptics.commit()
    notesFocused = false
    draftNotes = merged
    originalNotes = merged
    notesProposal = nil
    TaskUndo.recordProjectProposalDecision(
      id: project.id,
      accepted: true,
      beforeNotes: before,
      afterNotes: merged.isEmpty ? nil : merged,
      proposal: proposal,
      projects: projectsMutator
    )
    Task {
      do { try await projectsMutator.acceptNotesProposal(id: project.id) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func rejectProposal() {
    guard let proposal = notesProposal else { return }
    let current = draftNotes.isEmpty ? nil : draftNotes
    Haptics.commit()
    notesProposal = nil
    TaskUndo.recordProjectProposalDecision(
      id: project.id,
      accepted: false,
      beforeNotes: current,
      afterNotes: current,
      proposal: proposal,
      projects: projectsMutator
    )
    Task {
      do { try await projectsMutator.rejectNotesProposal(id: project.id) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func restoreNotes(_ restored: String) {
    let before = draftNotes.isEmpty ? nil : draftNotes
    let after = restored.isEmpty ? nil : restored
    guard (before ?? "") != (after ?? "") else { return }
    Haptics.commit()
    notesFocused = false
    draftNotes = restored
    originalNotes = restored
    TaskUndo.recordProjectNotesRestore(id: project.id, before: before, after: after, projects: projectsMutator)
    Task {
      do { try await projectsMutator.setNotes(id: project.id, notes: after) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  private func setStatus(_ newStatus: ProjectStatus) {
    Haptics.projectStatusChanged(to: newStatus)
    status = newStatus
    Task {
      do { try await projectsMutator.setStatus(id: project.id, status: newStatus) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  /// The delete confirmation (`RegistryPrompts.deleteProject`, shared with
  /// the sidebar and the AppKit sheet): counts the tasks that go to Recently
  /// Deleted. Counted only while the dialog is up: the body reads this on
  /// every pass.
  private var deleteCopy: RegistryPromptCopy {
    guard showingDeleteConfirm else {
      return RegistryPromptCopy(id: .deleteProject, title: "", message: "", confirmTitle: nil, options: [])
    }
    return RegistryPrompts.deleteProject(id: project.id, title: project.title, context: modelContext)
  }

  private func deleteProject() {
    Haptics.warning()
    // Capture before the delete; record at the gesture (CLAUDE.md: undo is
    // recorded at the user gesture, never inside a mutator).
    let undoSnapshot = TaskUndo.projectDeleteSnapshot(id: project.id, projects: projectsMutator,
                                                      context: modelContext)
    let projects = projectsMutator
    // The process-wide mutator, not a new `@Environment(TaskMutator.self)`:
    // this view is shared, and an environment read that one app forgot to
    // inject crashes at launch (CLAUDE.md, Septask).
    let tasks = SeptenaServices.shared.taskMutator
    Task {
      do {
        try await projectsMutator.delete(id: project.id)
        if let undoSnapshot {
          TaskUndo.recordProjectDelete(undoSnapshot, projects: projects, mutator: tasks)
        }
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
