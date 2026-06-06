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
  @State private var editing: ChoreItem? = nil
  @State private var creating = false

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
                  onLog: { _ in creating = true }) {
      if !today.isEmpty {
        DrawerSection("Today", padding: .none) { ForEach(today) { row(for: $0) } }
      }
      if !later.isEmpty {
        DrawerSection("Later", padding: .none) { ForEach(later) { row(for: $0) } }
      }
    }
    .trackScreen("chores")
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load()
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

}
