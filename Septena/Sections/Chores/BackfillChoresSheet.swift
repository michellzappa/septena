import SwiftUI
import SwiftData

// Backfill sheet for chores — opens when the user taps a past cell in the
// ChoresDestinationView heatmap. Lists every chore definition with a
// checkbox indicating whether it was completed on the picked day. Tap to
// add a missed completion via `completeChore(id:date:)`, or to remove an
// erroneous one via `uncompleteChore(id:date:)`. Cadence isn't relevant
// here — a chore completion is just an event on a day.

struct BackfillChoresSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme

  let date: String

  @State private var chores: [ChoreItem] = []
  /// IDs of chores with a `complete` event on `date`. Reloaded on
  /// `.septenaDataChanged` so toggles update the checkmarks live.
  @State private var doneIDs: Set<String> = []

  private var accent: Color { theme.color(for: "chores") }

  var body: some View {
    NavigationStack {
      List {
        if chores.isEmpty {
          Section { ProgressView() }
        } else {
          Section {
            ForEach(chores) { chore in
              row(for: chore)
            }
          }
        }
      }
      #if os(iOS)
      .listStyle(.insetGrouped)
      #endif
      .navigationTitle(SeptenaDate.friendlyLabel(date))
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .tint(accent)
    }
    .task { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
  }

  private func row(for chore: ChoreItem) -> some View {
    let isDone = doneIDs.contains(chore.id)
    return Button {
      if isDone {
        checklistMutator.uncompleteChore(id: chore.id, date: date)
      } else {
        checklistMutator.completeChore(id: chore.id, date: date)
      }
      Haptics.tick()
    } label: {
      HStack(spacing: 12) {
        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isDone ? accent : .secondary)
          .font(.title3)
        if let e = chore.emoji, !e.isEmpty {
          Text(e)
        }
        Text(chore.name)
          .foregroundStyle(.primary)
          .strikethrough(isDone, color: .secondary)
        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func reload() {
    chores = ChecklistMirror.loadChores(context: modelContext)
    // Fetch all `complete` events for the picked date, indexed by choreID.
    // Filtering client-side is fine — chore events table is small (one row
    // per (chore, day) and most chores fire weekly at most).
    let events = (try? modelContext.fetch(FetchDescriptor<ChoreEventEntity>())) ?? []
    doneIDs = Set(
      events
        .filter { $0.date == date && $0.action == "complete" }
        .map { $0.choreID }
    )
  }
}
