import SwiftUI
import SwiftData

// Floating ⌘K palette. Substring + token scoring across tasks, projects,
// and areas — fast, predictable, no ML. Selection routes via NavigationState
// (project/area for entity hits; for tasks, jumps to the containing list).

struct QuickFindView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(NavigationState.self) private var nav
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme
  @Environment(TrainingDraftStore.self) private var trainingDraft
  @Environment(\.a11yMotion) private var motion
  @Query private var tasks: [TaskEntity]
  @Query private var projects: [ProjectEntity]
  @Query private var areas: [AreaEntity]

  @State private var query: String = ""
  @State private var selection: Int = 0

  private static let resultLimit = 12

  var body: some View {
    NavigationStack {
      content
        .background(Theme.paperBackground)
        .navigationTitle("Search")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
        }
        .searchable(
          text: $query,
          placement: .navigationBarDrawer(displayMode: .always),
          prompt: "Search tasks, projects, areas…"
        )
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
    .onAppear {
      // Pre-warm the session-type list so the training launcher reads
      // populated on first ⌘K. Cheap; the store keeps a cached copy.
      Task { await trainingDraft.refreshCatalog(client: client) }
    }
    .onChange(of: query) { selection = 0 }
  }

  @ViewBuilder
  private var content: some View {
    let rows = hits
    if rows.isEmpty {
      if query.isEmpty {
        trainingLauncher
      } else {
        ContentUnavailableView.search(text: query)
      }
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, hit in
              QuickFindRow(hit: hit, selected: idx == selection)
                .id(idx)
                .contentShape(Rectangle())
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

  // MARK: - Scoring

  private var hits: [QuickFindHit] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let tokens = trimmed.lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !tokens.isEmpty else { return [] }

    var out: [QuickFindHit] = []

    for t in tasks {
      let s = score(title: t.title, body: t.notes, tokens: tokens)
      guard s > 0 else { continue }
      out.append(QuickFindHit(
        id: "t:\(t.id)",
        kind: .task(done: t.status == .done, today: t.today),
        title: t.title,
        subtitle: taskSubtitle(t),
        score: s + (t.status == .done ? -3 : 0),
        route: routeForTask(t)
      ))
    }
    for p in projects {
      let s = score(title: p.title, body: combine(p.notes, p.context), tokens: tokens)
      guard s > 0 else { continue }
      out.append(QuickFindHit(
        id: "p:\(p.id)",
        kind: .project(done: p.status == .done),
        title: p.title,
        subtitle: areaTitle(forId: p.area),
        score: s + 1 + (p.status == .done ? -3 : 0),
        route: .project(Project(p))
      ))
    }
    for a in areas {
      let s = score(title: a.title, body: a.context, tokens: tokens)
      guard s > 0 else { continue }
      out.append(QuickFindHit(
        id: "a:\(a.id)",
        kind: .area,
        title: a.title,
        subtitle: nil,
        score: s + 1,
        route: .area(Area(a))
      ))
    }

    return out
      .sorted { ($0.score, $1.title) > ($1.score, $0.title) }
      .prefix(Self.resultLimit)
      .map { $0 }
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
      return .project(Project(p))
    }
    if let aid = t.area, let a = areas.first(where: { $0.id == aid }) {
      return .area(Area(a))
    }
    let today = SeptenaDate.today
    if t.today { return .filter(.today) }
    if let s = t.scheduled, s <= today { return .filter(.today) }
    if let d = t.due, d <= today { return .filter(.today) }
    if t.scheduled != nil || t.due != nil { return .filter(.upcoming) }
    if t.status == .done { return .filter(.logbook) }
    return .filter(.inbox)
  }

  private func taskSubtitle(_ t: TaskEntity) -> String? {
    if let pid = t.project, let p = projects.first(where: { $0.id == pid }) {
      return p.title
    }
    if let aid = t.area, let a = areas.first(where: { $0.id == aid }) {
      return a.title
    }
    if t.status == .done { return "Logbook" }
    if t.today { return "Today" }
    return nil
  }

  private func areaTitle(forId id: String?) -> String? {
    guard let id, let a = areas.first(where: { $0.id == id }) else { return nil }
    return a.title
  }

  private func combine(_ a: String?, _ b: String?) -> String? {
    switch (a, b) {
    case let (x?, y?): return "\(x) \(y)"
    case let (x?, nil): return x
    case let (nil, y?): return y
    default: return nil
    }
  }

  private func activateSelected() {
    let rows = hits
    guard rows.indices.contains(selection) else { return }
    nav.path = [rows[selection].route]
    dismiss()
  }

  // MARK: - Training launcher
  //
  // Mirrors the webapp's ⌘K training page. Empty-query state pins a
  // "Resume" row if a draft exists, then lists session types with "Last
  // Nd ago" + Suggested badges. Tapping a row presents the logger sheet.

  private var trainingAccent: Color { theme.color(for: "training") }

  @ViewBuilder
  private var trainingLauncher: some View {
    let types = trainingDraft.sessionTypes
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        Text("Start training")
          .font(.septenaLabel)
          .foregroundStyle(Theme.inkSecondary)
          .padding(.horizontal, 20)
          .padding(.top, 14)
          .padding(.bottom, 6)
        if let d = trainingDraft.draft {
          launcherRow(
            emoji: d.emoji ?? "▶",
            title: "Resume \(d.label)",
            subtitle: "\(d.doneCount)/\(max(d.totalCount,1)) done",
            badge: nil,
            tint: trainingAccent
          ) {
            nav.showTrainingSession = true
            dismiss()
          }
        }
        if types.isEmpty {
          HStack {
            ProgressView().controlSize(.small)
            Text("Loading session types…")
              .font(.septenaMeta)
              .foregroundStyle(Theme.inkSecondary)
          }
          .padding(.horizontal, 20).padding(.vertical, 10)
        } else {
          ForEach(types) { type in
            let days = trainingDraft.daysAgo[type.id]
            launcherRow(
              emoji: type.emoji ?? "💪",
              title: type.label,
              subtitle: days.map {
                $0 == 0 ? "Today" :
                $0 == 1 ? "1 day ago" : "\($0) days ago"
              } ?? "No prior session",
              badge: trainingDraft.suggested == type.id ? "Suggested" : nil,
              tint: trainingAccent
            ) {
              startType(type)
            }
          }
        }
      }
      .padding(.bottom, 12)
    }
  }

  private func launcherRow(emoji: String,
                           title: String,
                           subtitle: String,
                           badge: String?,
                           tint: Color,
                           action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Text(emoji).font(.title3).frame(width: 22)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.septenaTaskTitle)
            .foregroundStyle(Theme.inkPrimary)
          Text(subtitle)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
        }
        Spacer()
        if let badge {
          Text(badge)
            .font(.septenaBadge)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6)
  }

  private func startType(_ type: SessionTypeConfig) {
    Task {
      await trainingDraft.start(type: type, client: client)
      nav.showTrainingSession = true
      dismiss()
    }
  }
}

// MARK: - Row + hit model

private struct QuickFindHit: Identifiable, Hashable {
  enum Kind: Hashable {
    case task(done: Bool, today: Bool)
    case project(done: Bool)
    case area
  }
  let id: String
  let kind: Kind
  let title: String
  let subtitle: String?
  let score: Int
  let route: Route
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
      Text(kindLabel)
        .font(Font.septenaMeta)
        .foregroundStyle(Theme.inkSecondary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(selected ? Theme.rowSelected : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .padding(.horizontal, 6)
  }

  @ViewBuilder
  private var icon: some View {
    switch hit.kind {
    case .task(let done, let today):
      Image(systemName: done ? "checkmark.square"
                              : today ? "sun.max" : "square")
        .font(.system(size: 14, weight: .regular))
    case .project:
      Image(systemName: "circle.dashed")
        .font(.system(size: 14, weight: .regular))
    case .area:
      Image(systemName: "square.stack")
        .font(.system(size: 14, weight: .regular))
    }
  }

  private var iconTint: Color {
    switch hit.kind {
    case .task(let done, _): return done ? Theme.inkSecondary : Theme.inkPrimary
    case .project(let done): return done ? Theme.inkSecondary : Theme.tasksAccent
    case .area: return Theme.tasksAccent
    }
  }

  private var kindLabel: String {
    switch hit.kind {
    case .task(let done, _): return done ? "Done" : "Task"
    case .project(let done): return done ? "Project · Done" : "Project"
    case .area: return "Area"
    }
  }
}
