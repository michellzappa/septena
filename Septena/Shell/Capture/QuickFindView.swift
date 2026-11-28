import SwiftUI
import SwiftData

// Command Bar (⌘K, alias ⇧⌘F) and Search tab for Tasks. Runs contextual task
// actions, global app commands, or jumps to lists, projects, areas, and tasks.
// Prefix with `>` to filter to commands only.

struct QuickFindView: View {
  /// Hosted as a real Search TAB (Septask's iOS 26 separated trailing slot)
  /// rather than a modal Command Bar: drop the Cancel button and don't
  /// `dismiss()` on activation — routing to a result just switches tabs.
  /// Default `false` keeps the modal (⌘K / ⇧⌘F / menu) Command Bar everywhere.
  var embedded: Bool = false
  @Environment(\.dismiss) private var dismiss
  @Environment(NavigationState.self) private var nav
  @Environment(\.a11yMotion) private var motion
  @Query private var tasks: [TaskEntity]
  @Query private var projects: [ProjectEntity]
  @Query private var areas: [AreaEntity]

  @State private var query: String = ""
  @FocusState private var searchFocused: Bool
  @State private var selection: Int = 0
  @State private var snapshotTaskActions: TaskActions? = nil

  private static let resultLimit = 24

  private var searchPrompt: String {
    embedded ? RegistrySurfaces.quickFindPlaceholder : RegistrySurfaces.quickFindCommandPlaceholder
  }

  var body: some View {
    searchHost
      .onChange(of: query) { selection = 0 }
      .onAppear {
        if !embedded {
          snapshotTaskActions = ActiveTaskCommandBridge.current()
        }
      }
  }

  /// Two hosting contracts for the SAME UI:
  ///  • Modal Command Bar (⌘K / ⇧⌘F / menu): the search bar is pinned in the
  ///    nav-bar drawer and focus is forced on appear, so it opens type-ready.
  ///  • Search TAB (Septask's iOS 26 detached slot): the tab morphs into the
  ///    system's own search field, which requires `.searchable` on the
  ///    `NavigationStack` with DEFAULT placement. Forcing `.navigationBarDrawer`
  ///    + on-appear focus inside a `role: .search` tab collides with that
  ///    system presentation, which aborts the search session ("Unable to
  ///    search" / a cancelled search) even though results still render. So the
  ///    tab lets the system own placement and focus.
  @ViewBuilder
  private var searchHost: some View {
    if embedded {
      NavigationStack { stackContent }
        .searchable(text: $query, prompt: searchPrompt)
    } else {
      NavigationStack {
        stackContent
          #if os(iOS)
          .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: searchPrompt
          )
          #else
          .searchable(text: $query, prompt: searchPrompt)
          #endif
          .searchFocused($searchFocused)
      }
      .onAppear {
        // Reliably focus the search field on open (macOS doesn't auto-focus
        // `.searchable` the way iOS does), so you can type immediately.
        searchFocused = true
      }
    }
  }

  private var stackContent: some View {
    content
      .background(Theme.paperBackground)
      .navigationTitle(RegistryActions.title(.appQuickFind))
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        if !embedded {
          ToolbarItem(placement: .cancellationAction) {
            DrawerCloseButton { dismiss() }
          }
        }
      }
      // `.onSubmit(of: .search)` sits inside the stack for both contracts — the
      // `.searchable` environment (whether on the stack or its content) reaches
      // here either way.
      .onSubmit(of: .search, activateSelected)
      .onKeyPress(.upArrow) {
        selection = max(0, selection - 1)
        return .handled
      }
      .onKeyPress(.downArrow) {
        selection = min(max(0, hits.count - 1), selection + 1)
        return .handled
      }
  }

  @ViewBuilder
  private var content: some View {
    let rows = hits
    if rows.isEmpty {
      if query.isEmpty {
        emptyPrompt
      } else {
        ContentUnavailableView.search(text: query)
      }
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, hit in
              QuickFindRow(hit: hit, selected: idx == selection)
                .id(idx)
                .contentShape(Rectangle())
                .rowHover()
                .onTapGesture { selection = idx; activateSelected() }
            }
          }
          .padding(.vertical, 4)
        }
        .onChange(of: selection) { _, new in
          motion.run(.easeOut(duration: 0.08)) {
            proxy.scrollTo(new, anchor: .center)
          }
        }
      }
    }
  }

  // MARK: - Commands

  private var availableCommands: [QuickFindCommand] {
    var out: [QuickFindCommand] = []

    func shortcutText(for id: RegistryActionID) -> String? {
      guard let caps = RegistryActions.shortcut(for: id)?.keycaps, !caps.isEmpty else { return nil }
      return caps.joined()
    }

    func appendAction(
      _ id: RegistryActionID,
      variant: RegistryTitleVariant = .base,
      keywords: [String] = [],
      contextual: Bool,
      run: @escaping () -> Void
    ) {
      guard RegistryActions.isAvailableOnPlatform(id) else { return }
      out.append(QuickFindCommand(
        id: id.rawValue,
        title: RegistryActions.title(id, variant),
        shortcut: shortcutText(for: id),
        symbol: RegistryActions.sfSymbols[id] ?? "command",
        keywords: keywords,
        isContextual: contextual,
        run: run
      ))
    }

    // Contextual row commands from the live task list selection (modal only).
    if !embedded, let taskActions = snapshotTaskActions {
      let rowSpecs: [(RegistryActionID, [String])] = [
        (.taskToggleComplete, ["done", "check", "finish", "tick"]),
        (.taskDo, ["focus", "start", "now"]),
        (.taskToggleToday, ["today", "schedule"]),
        (.taskWhen, ["schedule", "date", "defer", "later"]),
        (.taskMove, ["project", "area", "file", "folder"]),
        (.taskTags, ["tag", "label"]),
        (.taskDeadline, ["due", "date"]),
        (.taskReminder, ["alarm", "notify", "alert"]),
        (.taskToggleStar, ["star", "pin"]),
        (.taskWaitingOn, ["wait", "delegate", "follow up"]),
        (.taskGotItBack, ["waiting", "received", "unblock"]),
        (.taskEditDetails, ["rename", "edit", "title"]),
        (.taskDuplicate, ["clone", "copy"]),
        (.taskCopy, ["clipboard"]),
        (.taskClearSchedule, ["unschedule", "anytime", "clear"]),
        (.taskCancel, ["drop", "wont do", "cancel"]),
        (.taskDelete, ["trash", "remove"]),
      ]
      for (actionId, keywords) in rowSpecs {
        guard let handler = taskActions.handler(for: actionId) else { continue }
        appendAction(actionId, keywords: keywords, contextual: true, run: handler)
      }
    }

    // Global commands.
    let sidebarHidden = nav.sidebarVisibility == .detailOnly
    appendAction(.appNewTask, keywords: ["add", "create", "task"], contextual: false) {
      nav.shouldStartCreating = true
    }
    appendAction(.appQuickAdd, keywords: ["add", "capture", "inbox"], contextual: false) {
      nav.presentAddInfo()
    }
    appendAction(.sidebarNewProject, keywords: ["add", "create", "project"], contextual: false) {
      nav.shouldCreateProject = true
    }
    appendAction(.sidebarNewArea, keywords: ["add", "create", "area"], contextual: false) {
      nav.shouldCreateArea = true
    }
    appendAction(.appToggleSidebar, variant: sidebarHidden ? .add : .remove,
                 keywords: ["sidebar", "navigation", "panel"], contextual: false) {
      nav.sidebarVisibility = nav.sidebarVisibility == .detailOnly ? .all : .detailOnly
    }
    appendAction(.appSettings, keywords: ["preferences", "prefs", "account", "theme", "sync"], contextual: false) {
      nav.showSettings = true
    }
    appendAction(.appKeyboardShortcuts, keywords: ["keys", "hotkeys", "help"], contextual: false) {
      nav.showKeyboardShortcuts = true
    }

    return out
  }

  private var smartListHits: [QuickFindHit] {
    TaskDestinations.sidebarRoutes.map { route in
      QuickFindHit(
        id: "l:\(route.id)",
        taskID: nil,
        kind: .list(symbol: route.icon),
        title: route.title,
        subtitle: nil,
        shortcut: nil,
        score: 0,
        route: route,
        command: nil
      )
    }
  }

  // MARK: - Scoring

  private var hits: [QuickFindHit] {
    let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let commandsOnly = raw.hasPrefix(">")
    let trimmed = commandsOnly
      ? String(raw.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
      : raw

    if commandsOnly {
      return scoredCommands(for: trimmed)
    }

    guard !trimmed.isEmpty else {
      guard !embedded else { return [] }
      let cmds = availableCommands
      let contextual = cmds.filter(\.isContextual).prefix(6).map { cmd in
        QuickFindHit(
          id: "c:\(cmd.id)", taskID: nil, kind: .command(symbol: cmd.symbol),
          title: cmd.title, subtitle: nil, shortcut: cmd.shortcut,
          score: 0, route: nil, command: cmd
        )
      }
      let global = cmds.filter { !$0.isContextual }.prefix(6).map { cmd in
        QuickFindHit(
          id: "c:\(cmd.id)", taskID: nil, kind: .command(symbol: cmd.symbol),
          title: cmd.title, subtitle: nil, shortcut: cmd.shortcut,
          score: 0, route: nil, command: cmd
        )
      }
      return Array(contextual) + smartListHits + Array(global)
    }

    let tokens = trimmed.lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !tokens.isEmpty else { return [] }

    var out: [QuickFindHit] = scoredCommands(for: trimmed)

    for route in TaskDestinations.sidebarRoutes {
      let s = score(title: route.title, body: nil, tokens: tokens)
      guard s > 0 else { continue }
      out.append(QuickFindHit(
        id: "l:\(route.id)",
        taskID: nil,
        kind: .list(symbol: route.icon),
        title: route.title,
        subtitle: nil,
        shortcut: nil,
        score: s + 4,
        route: route,
        command: nil
      ))
    }

    let context = LocalStore.shared.container.mainContext
    let tagsByID = LocalCache.tagsByID(in: context)
    let refTexts = TaskRefLookup.searchTexts(in: context)
    // A pasted link: the tasks that point at the item come first, whatever
    // way the link is spelled there.
    let pointing = Dictionary(uniqueKeysWithValues: (TaskRefLookup.taskIDs(forLink: trimmed, in: context) ?? [])
      .enumerated().map { ($0.element, $0.offset) })

    for t in tasks where t.deletedAt == nil && !t.isHeading {   // Recently-Deleted rows + project headings aren't searchable
      let tagText = t.tagIDs.compactMap { tagsByID[$0]?.name }.map { "\($0) #\($0)" }.joined(separator: " ")
      let found = score(title: t.title,
                        body: [t.notes, tagText, refTexts[t.id]].compactMap { $0 }.joined(separator: " "),
                        tokens: tokens)
      let s = found + (pointing[t.id].map { 10_000 - $0 } ?? 0)
      guard s > 0 else { continue }
      out.append(QuickFindHit(
        id: "t:\(t.id)",
        taskID: t.id,
        kind: .task(done: t.status.isFinished, today: t.isOnToday),
        title: t.title,
        subtitle: taskSubtitle(t),
        shortcut: nil,
        score: s + (t.status.isFinished ? (pointing[t.id] == nil ? -1 : -5_000) : 0),
        route: routeForTask(t),
        command: nil
      ))
    }
    for p in projects {
      let s = score(title: p.title, body: p.notes, tokens: tokens)
      guard s > 0 else { continue }
      out.append(QuickFindHit(
        id: "p:\(p.id)",
        taskID: nil,
        kind: .project(done: p.status == .done),
        title: p.title,
        subtitle: areaTitle(forId: p.area),
        shortcut: nil,
        score: s + 1 + (p.status == .done ? -3 : 0),
        route: .project(id: p.id),
        command: nil
      ))
    }
    for a in areas {
      let s = score(title: a.title, body: a.context, tokens: tokens)
      guard s > 0 else { continue }
      out.append(QuickFindHit(
        id: "a:\(a.id)",
        taskID: nil,
        kind: .area,
        title: a.title,
        subtitle: nil,
        shortcut: nil,
        score: s + 1,
        route: .area(id: a.id),
        command: nil
      ))
    }

    return out
      .sorted { ($0.score, $1.title) > ($1.score, $0.title) }
      .prefix(Self.resultLimit)
      .map { $0 }
  }

  private func scoredCommands(for trimmed: String) -> [QuickFindHit] {
    let cmds = availableCommands
    if trimmed.isEmpty {
      return cmds.map { cmd in
        QuickFindHit(
          id: "c:\(cmd.id)", taskID: nil, kind: .command(symbol: cmd.symbol),
          title: cmd.title, subtitle: nil, shortcut: cmd.shortcut,
          score: cmd.isContextual ? 50 : 25, route: nil, command: cmd
        )
      }
    }
    let tokens = trimmed.lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !tokens.isEmpty else { return [] }
    return cmds.compactMap { cmd in
      let s = score(title: cmd.title, body: cmd.keywords.joined(separator: " "), tokens: tokens)
      guard s > 0 else { return nil }
      return QuickFindHit(
        id: "c:\(cmd.id)",
        taskID: nil,
        kind: .command(symbol: cmd.symbol),
        title: cmd.title,
        subtitle: nil,
        shortcut: cmd.shortcut,
        score: s + (cmd.isContextual ? 8 : 3),
        route: nil,
        command: cmd
      )
    }
  }

  private func score(title: String, body: String?, tokens: [String]) -> Int {
    let t = title.lowercased()
    let b = body?.lowercased() ?? ""
    var total = 0
    for tok in tokens {
      let inTitle = t.contains(tok)
      let inBody = b.contains(tok)
      if !inTitle && !inBody { return 0 }
      if inTitle {
        total += 10
        if t.hasPrefix(tok) { total += 6 }
        else if t.contains(" \(tok)") { total += 3 }
      }
      if inBody { total += 2 }
    }
    if t == tokens.joined(separator: " ") { total += 20 }
    return total
  }

  // MARK: - Routing helpers

  private func routeForTask(_ t: TaskEntity) -> Route {
    if let pid = t.project, let p = projects.first(where: { $0.id == pid }) {
      return .project(id: p.id)
    }
    if let aid = t.area, let a = areas.first(where: { $0.id == aid }) {
      return .area(id: a.id)
    }
    if t.isOnToday { return .filter(.today) }
    if t.scheduled != nil || t.deadline != nil { return .filter(.upcoming) }
    if t.status == .done { return .filter(.logbook) }
    // Loose, unratified captures live in the triage band on Today.
    return .filter(.today)
  }

  private func taskSubtitle(_ t: TaskEntity) -> String? {
    if let pid = t.project, let p = projects.first(where: { $0.id == pid }) {
      return p.title
    }
    if let aid = t.area, let a = areas.first(where: { $0.id == aid }) {
      return a.title
    }
    if t.status == .done { return RegistrySurfaces.quickFindCompletedLabel }
    if t.isOnToday { return TaskFilter.today.title }
    return nil
  }

  private func areaTitle(forId id: String?) -> String? {
    guard let id, let a = areas.first(where: { $0.id == id }) else { return nil }
    return a.title
  }

  private func activateSelected() {
    let rows = hits
    guard rows.indices.contains(selection) else { return }
    let hit = rows[selection]
    if let command = hit.command {
      if !embedded { dismiss() }
      // Let the modal sheet finish dismissing before presenting follow-up
      // pickers or sheets (When, Move, Tags, Settings, Quick Add).
      DispatchQueue.main.async { command.run() }
      return
    }
    if let route = hit.route {
      if let taskID = hit.taskID {
        nav.revealTask(id: taskID, in: route)
      } else {
        nav.go(to: route)
      }
    }
    // Modal palette closes itself; the search TAB stays put — routing already
    // switched the frontmost tab to the result's list.
    if !embedded { dismiss() }
  }

  // MARK: - Empty state

  // Before anything is typed: a quiet hint that this palette searches the
  // Tasks domain only.
  private var emptyPrompt: some View {
    ContentUnavailableView {
      Label(RegistrySurfaces.quickFindEmptyTitle, systemImage: "magnifyingglass")
    } description: {
      Text(RegistrySurfaces.quickFindEmptyDetail)
    }
  }
}

// MARK: - Row + hit model

private struct QuickFindCommand {
  let id: String
  let title: String
  let shortcut: String?
  let symbol: String
  let keywords: [String]
  let isContextual: Bool
  let run: () -> Void
}

private struct QuickFindHit: Identifiable {
  enum Kind {
    case command(symbol: String)
    case list(symbol: String)
    case task(done: Bool, today: Bool)
    case project(done: Bool)
    case area
  }
  let id: String
  /// Non-nil only for a task result. Areas and projects navigate normally.
  let taskID: String?
  let kind: Kind
  let title: String
  let subtitle: String?
  let shortcut: String?
  let score: Int
  let route: Route?
  let command: QuickFindCommand?
}

private struct QuickFindRow: View {
  let hit: QuickFindHit
  let selected: Bool

  var body: some View {
    HStack(spacing: 12) {
      icon
        .frame(width: 18, height: 18)
        .foregroundStyle(iconTint)
      VStack(alignment: .leading, spacing: 1) {
        Text(hit.title)
          .font(Font.septenaTaskTitle)
          .foregroundStyle(Theme.inkPrimary)
          .lineLimit(1)
        if let sub = hit.subtitle {
          Text(sub)
            .font(Font.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if let shortcut = hit.shortcut, !shortcut.isEmpty {
        Text(shortcut)
          .font(Font.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      }
    }
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.vertical, 11)
    // Palette-row selection: the canonical neutral `listSelectionFill`, drawn
    // as the sanctioned inset shape (`InsetSelectionBackground`). This used to
    // paint `Color.accentColor.opacity(0.18)` clipped and THEN re-padded, which
    // both invented a second (hue-tinted) selection language and made the
    // highlight read as a chip floating on top of the row.
    .background(InsetSelectionBackground(isSelected: selected,
                                         horizontalInset: Theme.Spacing.xs + 2,
                                         verticalInset: 0))
  }

  @ViewBuilder
  private var icon: some View {
    switch hit.kind {
    case .command(let symbol):
      Image(systemName: symbol)
        .scaledFont(size: 14, weight: .regular)
    case .list(let symbol):
      Image(systemName: symbol)
        .scaledFont(size: 14, weight: .regular)
    case .task(let done, let today):
      Image(systemName: done ? "checkmark.square"
                              : today ? "sun.max" : "square")
        .scaledFont(size: 14, weight: .regular)
    case .project:
      Image(systemName: "circle.dashed")
        .scaledFont(size: 14, weight: .regular)
    case .area:
      Image(systemName: "square.stack")
        .scaledFont(size: 14, weight: .regular)
    }
  }

  private var iconTint: Color {
    switch hit.kind {
    case .command: return Theme.inkSecondary
    case .list: return Theme.inkSecondary
    case .task(let done, _): return done ? Theme.inkSecondary : Theme.inkPrimary
    case .project(let done): return done ? Theme.inkSecondary : Color.accentColor
    case .area: return Color.accentColor
    }
  }
}
