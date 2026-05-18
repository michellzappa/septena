import SwiftUI

// Chores mini-app — full chore list split into Today (due or overdue),
// Done today, and Later (future-dated). Reached from the Week dashboard's
// Chores tile. Reuses NextItemsModel for loading + optimistic mutations
// and ChoreRow for row UI, so swipe vocab (Tomorrow / Weekend defer) and
// completion behavior match the Next tab exactly.

struct ChoresDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()
  @State private var editing: ChoreItem? = nil

  private var accent: Color { theme.color(for: "chores") }

  /// Server's chores list is unsorted; bucket here for the three sections.
  /// "Today" includes overdue (daysOverdue > 0) and due-today (== 0).
  private var today: [ChoreItem] {
    model.chores
      .filter { $0.daysOverdue >= 0 && !model.completedChores.contains($0.id) }
      .sorted { ($0.daysOverdue, $0.name) > ($1.daysOverdue, $1.name) }
  }

  private var doneToday: [ChoreItem] {
    model.chores.filter { model.completedChores.contains($0.id) }
  }

  private var later: [ChoreItem] {
    model.chores
      .filter { $0.daysOverdue < 0 && !model.completedChores.contains($0.id) }
      .sorted { ($0.daysOverdue, $0.name) < ($1.daysOverdue, $1.name) }
  }

  var body: some View {
    List {
      summary
      if !today.isEmpty {
        Section("Today") {
          ForEach(today) { chore in
            Button { editing = chore } label: {
              ChoreRow(chore: chore, model: model, outbox: outbox, tint: accent)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) {
                delete(chore)
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        }
      }
      if !doneToday.isEmpty {
        Section("Done today") {
          ForEach(doneToday) { chore in
            Button { editing = chore } label: {
              ChoreRow(chore: chore, model: model, outbox: outbox, tint: accent)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) {
                delete(chore)
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        }
      }
      if !later.isEmpty {
        Section("Later") {
          ForEach(later) { chore in
            Button { editing = chore } label: {
              ChoreRow(chore: chore, model: model, outbox: outbox, tint: accent)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) {
                delete(chore)
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        }
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Chores")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load(client: client)
    }
    .sheet(item: $editing) { chore in
      EditChoreSheet(
        original: chore,
        onSave: { updated in
          if let idx = model.chores.firstIndex(where: { $0.id == updated.id }) {
            model.chores[idx] = updated
          }
        }
      )
    }
  }

  private func delete(_ chore: ChoreItem) {
    outbox.enqueue(
      method: "DELETE",
      path: "/api/chores/definitions/\(chore.id)",
      body: nil,
      kind: "chores.delete"
    )
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
    return Section {
      HStack(alignment: .top, spacing: 24) {
        stat(value: "\(dueTodayCount)", label: "due today", tint: accent)
        if overdueCount > 0 {
          stat(value: "\(overdueCount)", label: "overdue", tint: Theme.overdueRed)
        }
        Spacer()
        stat(value: "\(doneCount)", label: "done", tint: .secondary, alignment: .trailing)
      }
    }
  }

  private func stat(value: String, label: String, tint: Color,
                    alignment: HorizontalAlignment = .leading) -> some View {
    VStack(alignment: alignment, spacing: 2) {
      Text(value)
        .font(.system(.title2, design: .rounded).weight(.semibold))
        .foregroundStyle(tint)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
