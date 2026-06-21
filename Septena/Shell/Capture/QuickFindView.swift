import SwiftUI
import SwiftData

// Floating search palette for the Tasks domain. Substring + token scoring
// across tasks, projects, and areas — fast, predictable, no ML. Selection
// routes via NavigationState (project/area for entity hits; for tasks, jumps
// to the containing list). Scoped to tasks only — it does not search or
// launch other sections.

struct QuickFindView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(NavigationState.self) private var nav
  @Environment(\.a11yMotion) private var motion
  @Query private var tasks: [TaskEntity]
  @Query private var projects: [ProjectEntity]
  @Query private var areas: [AreaEntity]

  @State private var query: String = ""
  @FocusState private var searchFocused: Bool
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
        #if os(iOS)
        .searchable(
          text: $query,
          placement: .navigationBarDrawer(displayMode: .always),
          prompt: "Search tasks, projects, areas…"
        )
        #else
        .searchable(
          text: $query,
          prompt: "Search tasks, projects, areas…"
        )
        #endif
        .searchFocused($searchFocused)
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
      // Reliably focus the search field on open (macOS doesn't auto-focus
      // `.searchable` the way iOS does), so you can type immediately.
      searchFocused = true
    }
    .onChange(of: query) { selection = 0 }
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

    for t in tasks where t.deletedAt == nil {   // Recently-Deleted tasks aren't searchable
      let s = score(title: t.title, body: t.notes, tokens: tokens)
      guard s > 0 else { continue }
      out.append(QuickFindHit(
        id: "t:\(t.id)",
        kind: .task(done: t.status == .done, today: t.today),
        title: t.title,
        subtitle: taskSubtitle(t),
        score: s + (t.status == .done ? -1 : 0),
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
    if t.status == .done { return "Completed" }
    if t.isOnToday { return "Today" }
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

  // MARK: - Empty state

  // Before anything is typed: a quiet hint that this palette searches the
  // Tasks domain only.
  private var emptyPrompt: some View {
    ContentUnavailableView {
      Label("Search Tasks", systemImage: "magnifyingglass")
    } description: {
      Text("Find any task, project, or area.")
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
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .padding(.horizontal, 6)
  }

  @ViewBuilder
  private var icon: some View {
    switch hit.kind {
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
    case .task(let done, _): return done ? Theme.inkSecondary : Theme.inkPrimary
    case .project(let done): return done ? Theme.inkSecondary : Color.accentColor
    case .area: return Color.accentColor
    }
  }
}
