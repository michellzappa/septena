import SwiftUI
import SwiftData

// Backfill sheet for habits — opens when the user taps a past cell in the
// HabitsDestinationView heatmap. Lists every habit definition with its
// state on that specific date; tapping a row toggles it via
// `ChecklistMutator.toggleHabit(id:date:done:)`, which writes against the
// picked day rather than today. Pairs with the equivalent sheets for
// supplements and chores.

struct BackfillHabitsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme

  /// ISO date (YYYY-MM-DD) the sheet is editing. Set once at present time.
  let date: String

  @State private var response: HabitsDayResponse? = nil

  private var accent: Color { theme.color(for: "habits") }

  var body: some View {
    NavigationStack {
      List {
        if let resp = response {
          ForEach(resp.buckets, id: \.self) { bucket in
            if let items = resp.grouped[bucket], !items.isEmpty {
              Section(bucket.capitalized) {
                ForEach(items) { item in
                  row(for: item)
                }
              }
            }
          }
          if (resp.grouped.values.flatMap { $0 }).isEmpty {
            ContentUnavailableView(
              "No habits defined",
              systemImage: theme.icon(for: "habits"),
              description: Text("Add a habit first, then come back to backfill.")
            )
          }
        } else {
          Section { ProgressView() }
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
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      if note.affectsSection("habits") { reload() }
    }
  }

  private func row(for item: HabitDayItem) -> some View {
    Button {
      let next = !item.done
      checklistMutator.toggleHabit(id: item.id, date: date, done: next)
      Haptics.tick()
    } label: {
      HStack(spacing: 12) {
        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(item.done ? accent : .secondary)
          .font(.title3)
        if let e = item.emoji, !e.isEmpty {
          Text(e)
        }
        Text(item.name)
          .foregroundStyle(.primary)
          .strikethrough(item.done, color: .secondary)
        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func reload() {
    response = ChecklistMirror.loadHabitsDay(context: modelContext, date: date)
  }
}
