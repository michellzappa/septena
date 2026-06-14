import SwiftUI
import SwiftData

// Backfill sheet for supplements — opens when the user taps a past cell in
// the SupplementsDestinationView heatmap. Mirrors `BackfillHabitsSheet`:
// every supplement definition rendered with its state for the picked
// date, tapping toggles via the mutator with `date:` filled in.

struct BackfillSupplementsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme

  let date: String

  @State private var response: SupplementsDayResponse? = nil

  private var accent: Color { theme.color(for: "supplements") }

  var body: some View {
    NavigationStack {
      List {
        if let resp = response {
          if resp.items.isEmpty {
            ContentUnavailableView(
              "No supplements yet",
              systemImage: theme.icon(for: "supplements"),
              description: Text("Add a supplement first, then come back to backfill.")
            )
          } else {
            Section {
              ForEach(resp.items) { item in
                row(for: item)
              }
            }
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
      if note.affectsSection("supplements") { reload() }
    }
  }

  private func row(for item: SupplementDayItem) -> some View {
    Button {
      let next = !item.done
      checklistMutator.toggleSupplement(id: item.id, date: date, done: next)
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
    response = ChecklistMirror.loadSupplementsDay(context: modelContext, date: date)
  }
}
