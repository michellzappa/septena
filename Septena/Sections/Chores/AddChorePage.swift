import SwiftUI

// Chores palette — actionable rows only (days_overdue >= 0). Tap completes
// for today. Type-to-create with cadence 7d default.

struct AddChorePage: View {
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var chores: [ChoreItem] = []
  @State private var working = false

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    let tint = AddInfoSection.chores.accent(theme: theme)
    let actionable = chores
      .filter { $0.daysOverdue >= 0 }
      .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
    let exactMatch = chores.contains { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }

    List {
      if !trimmed.isEmpty, !exactMatch {
        Section {
          Button { create(name: trimmed) } label: {
            AddInfoRow(
              title: "Add: “\(trimmed)”",
              subtitle: "Every 7 days",
              systemImage: "plus.circle.fill",
              tint: tint
            )
          }
          .buttonStyle(.plain)
          .disabled(working)
        }
      }
      if !actionable.isEmpty {
        Section("Actionable") {
          ForEach(actionable) { chore in
            Button { complete(chore) } label: {
              AddInfoRow(
                title: chore.name,
                subtitle: subtitle(for: chore),
                tint: tint
              )
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .task { await load() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private func subtitle(for chore: ChoreItem) -> String {
    let n = chore.daysOverdue
    if n == 0 { return "Due today" }
    if n == 1 { return "1 day late" }
    return "\(n) days late"
  }

  private func complete(_ chore: ChoreItem) {
    checklistMutator.completeChore(id: chore.id, date: SeptenaDate.today)
    AddInfoSection.chores.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func create(name: String) {
    guard !working else { return }
    working = true
    _ = checklistMutator.createChore(name: name, cadenceDays: 7)
    working = false
    AddInfoSection.chores.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func load() async {
    // Chores are CloudKit-authoritative — read directly from the local mirror.
    chores = ChecklistMirror.loadChores(context: LocalStore.shared.container.mainContext, today: SeptenaDate.today)
  }
}
