import SwiftUI

// Chores mini-app — full chore list split into Today (due or overdue),
// Done today, and Later (future-dated). Reached from the Week dashboard's
// Chores tile. Reuses NextItemsModel for loading + optimistic mutations
// and ChoreRow for row UI; tap edits, long-press exposes defer / delete
// (the app-wide list-row menu pattern — no swipe actions anywhere).

struct ChoresDestinationView: View {
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()
  @State private var editing: ChoreItem? = nil
  @State private var creating = false
  @State private var history: [ChoreHistoryPoint] = []
  /// `.sheet(item:)` needs Identifiable; String isn't, so wrap.
  private struct BackfillDate: Identifiable { let id: String }
  @State private var backfillDate: BackfillDate? = nil

  private var accent: Color { theme.color(for: "chores") }

  /// Server's chores list is unsorted; bucket here for the three sections.
  /// "Today" includes overdue (daysOverdue > 0) and due-today (== 0).
  private var today: [ChoreItem] {
    model.chores
      // A just-completed chore lingers here (struck through) for the settle
      // beat before it fades into "Done today" — same as the Next page. The
      // `actedChores` clause keeps it; the beat clears that set.
      .filter { $0.daysOverdue >= 0
        && (model.actedChores.contains($0.id) || !model.completedChores.contains($0.id)) }
      .sorted { ($0.daysOverdue, $0.name) > ($1.daysOverdue, $1.name) }
  }

  private var doneToday: [ChoreItem] {
    model.chores.filter {
      model.completedChores.contains($0.id) && !model.actedChores.contains($0.id)
    }
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
                  title: "Chores",
                  onLog: { _ in creating = true }) {
      summary
      if !today.isEmpty {
        DrawerSection("Today", padding: .none) { ForEach(today) { row(for: $0) } }
      }
      if !doneToday.isEmpty {
        DrawerSection("Done today", padding: .none) { ForEach(doneToday) { row(for: $0) } }
      }
      if !later.isEmpty {
        DrawerSection("Later", padding: .none) { ForEach(later) { row(for: $0) } }
      }
      if !history.isEmpty {
        ChecklistHeatmapSection(
          title: "Chore consistency",
          noun: "chore",
          accent: accent,
          daily: history,
          date: { $0.date },
          done: { $0.completed },
          total: { $0.total },
          onTapDay: { iso in backfillDate = BackfillDate(id: iso) }
        )
      }
    }
    .trackScreen("chores")
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load()
      // History is computed locally from the CloudKit-backed mirror.
      let resp = ChecklistMirror.loadChoresHistory(
        context: LocalStore.shared.container.mainContext, days: 365)
      history = resp.daily
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
    .sheet(item: $backfillDate) { wrap in
      BackfillChoresSheet(date: wrap.id)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
  }

  /// Single source of truth for chore rows in all three sections. Tap
  /// opens the editor; the row's own long-press context menu (provided
  /// by `ChoreRow`) covers defer + delete.
  @ViewBuilder
  private func row(for chore: ChoreItem) -> some View {
    Button { editing = chore } label: {
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

  private var summary: some View {
    let overdueCount = model.chores.filter {
      $0.daysOverdue > 0 && !model.completedChores.contains($0.id)
    }.count
    let dueTodayCount = model.chores.filter {
      $0.daysOverdue == 0 && !model.completedChores.contains($0.id)
    }.count
    let doneCount = doneToday.count
    var stats: [Stat] = [
      Stat(value: "\(dueTodayCount)", label: "due today", tint: accent),
    ]
    if overdueCount > 0 {
      stats.append(Stat(value: "\(overdueCount)", label: "overdue",
                        tint: Theme.overdueRed))
    }
    stats.append(Stat(value: "\(doneCount)", label: "done"))
    return DrawerSection { StatStrip(stats: stats) }
  }
}
