import SwiftUI

// Chores mini-app — full chore list split into Today (due or overdue)
// and Later (future-dated). Reached from the Week dashboard's
// Chores tile. Reuses NextItemsModel for loading + optimistic mutations
// and ChoreRow for row UI; tap edits, long-press exposes defer / delete
// (the app-wide list-row menu pattern — no swipe actions anywhere).

struct ChoresDestinationView: View {
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()
  @State private var viewing: ChoreItem? = nil
  @State private var editing: ChoreItem? = nil
  @State private var creating = false
  // Chores is a dual section: Log = today/later task list; Patterns = daily
  // completion heatmap. No time travel (the list is forward-looking). Default
  // Log — the task list is the surface you act on.
  @State private var mode: DrawerMode = .remembered(for: "chores", default: .log)
  @State private var history: [CompletionDay] = []

  private var accent: Color { theme.color(for: "chores") }

  /// Server's chores list is unsorted; bucket here for the three sections.
  /// "Today" includes overdue (daysOverdue > 0) and due-today (== 0).
  private var today: [ChoreItem] {
    model.chores
      // A completed chore stays here (struck through) for the rest of today
      // rather than fading out, so the drawer always shows what was done.
      // (The homepage Next feed still hides done.)
      .filter { $0.daysOverdue >= 0 }
      .sorted { ($0.daysOverdue, $0.name) > ($1.daysOverdue, $1.name) }
  }

  /// Soonest first (least-negative `daysOverdue`) → furthest away last, so
  /// the user sees what's coming up next at the top of the Later section.
  private var later: [ChoreItem] {
    model.chores
      .filter { $0.daysOverdue < 0 && !model.completedChores.contains($0.id) }
      .sorted {
        if $0.daysOverdue != $1.daysOverdue { return $0.daysOverdue > $1.daysOverdue }
        return $0.name < $1.name
      }
  }

  var body: some View {
    SectionDrawer(sectionKey: "chores",
                  quickAdd: DrawerQuickAdd("New chore") { creating = true },
                  mode: $mode,
                  log: {
      choresSummary
      if !today.isEmpty {
        DrawerSection("Today", padding: .none) { ForEach(today) { row(for: $0) } }
      }
      if !later.isEmpty {
        DrawerSection("Later", padding: .none) { ForEach(later) { row(for: $0) } }
      }
    }, patterns: {
      CompletionPatternsSection(title: "Completion", accent: accent,
                                days: history, loading: !model.hasLoaded)
      byChoreSection
    })
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load()
      await loadHistory()
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      if note.affectsSection("chores") { Task { await loadHistory() } }
    }
    // Tapping a chore opens its detail "infobox" (history + learned cadence);
    // the row's own checkbox still completes it. From the detail, "Edit" swaps
    // to the editor for the same chore.
    .adaptiveDetail(item: $viewing) { chore in
      ChoreDetailView(chore: chore, onEdit: {
        viewing = nil
        editing = chore
      })
    }
    .adaptiveDetail(item: $editing) { chore in
      EditChoreSheet(
        original: chore,
        onDone: { updated in
          if let updated, let idx = model.chores.firstIndex(where: { $0.id == updated.id }) {
            model.chores[idx] = updated
          }
        }
      )
    }
    .adaptiveDetail(isPresented: $creating) {
      EditChoreSheet(
        original: nil,
        onDone: { _ in Task { await model.load() } }
      )
    }
  }

  /// Top-of-Log day readout — what's pressing right now.
  @ViewBuilder
  private var choresSummary: some View {
    if !model.chores.isEmpty {
      let overdue = model.chores.filter { $0.daysOverdue > 0 && !model.completedChores.contains($0.id) }.count
      let dueToday = model.chores.filter { $0.daysOverdue == 0 && !model.completedChores.contains($0.id) }.count
      DrawerSummary(stats: [
        Stat(value: "\(overdue)", label: "overdue", tint: accent),
        Stat(value: "\(dueToday)", label: "due today", tint: accent),
      ])
    }
  }

  /// Per-chore drill-in for Patterns mode — every chore, tap to open its
  /// detail (completion history + learned cadence; same detail the Log rows
  /// open). Subtitle shows when it was last done.
  private var byChoreSection: some View {
    let rows = model.chores
      .sorted { $0.name < $1.name }
      .map { chore in
        BreakdownRow(id: chore.id,
                     title: chore.emoji.map { "\($0) \(chore.name)" } ?? chore.name,
                     detail: chore.lastCompleted.map { "last done \(LogDetailFormat.relativeDay($0))" }
                       ?? "not done yet")
      }
    return SectionBreakdownList(
      title: "By chore", rows: rows, accent: accent,
      selectedID: viewing?.id,
      onTap: { id in viewing = model.chores.first { $0.id == id } }
    )
  }

  /// Single source of truth for chore rows in all three sections. Tap
  /// opens the editor; the row's own long-press context menu (provided
  /// by `ChoreRow`) covers defer + delete.
  @ViewBuilder
  private func row(for chore: ChoreItem) -> some View {
    Button { viewing = chore } label: {
      ChoreRow(chore: chore, model: model, checklistMutator: checklistMutator, tint: accent,
               onDelete: { delete(chore) })
    }
    .buttonStyle(.plain)
    .transition(.opacity)
  }

  private func delete(_ chore: ChoreItem) {
    checklistMutator.deleteChore(id: chore.id)
    model.chores.removeAll { $0.id == chore.id }
    Haptics.warning()
  }

  /// Daily completed/total for the Patterns heatmap (trailing ~17 weeks).
  private func loadHistory() async {
    let resp = await MirrorReader.shared.read {
      ChecklistMirror.loadChoresHistory(context: $0, days: 119)
    }
    history = resp.daily.map { CompletionDay(date: $0.date, done: $0.completed, total: $0.total) }
  }

}
