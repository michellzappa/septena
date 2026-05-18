import SwiftUI

// Habits mini-app — full-day list grouped by time-of-day bucket. Reached
// by tapping the Habits tile on the Week dashboard. Reuses NextItemsModel
// for loading + optimistic mutations and HabitRow for the row UI, so the
// behavior is identical to the Next tab's current-bucket strip — just
// showing every bucket rather than only "now".

struct HabitsDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()
  @State private var editing: HabitDayItem? = nil

  /// Server section key; accent comes from the user's Septena config so the
  /// hue matches the webapp / sidebar / Next tab without hard-coding.
  private var accent: Color { theme.color(for: "habits") }

  var body: some View {
    List {
      summary
      ForEach(model.habitBuckets, id: \.self) { bucket in
        bucketSection(bucket)
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Habits")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load(client: client)
    }
    .sheet(item: $editing) { habit in
      EditHabitSheet(
        original: habit,
        buckets: model.habitBuckets,
        onSave: { updated in
          if let idx = model.habits.firstIndex(where: { $0.id == updated.id }) {
            model.habits[idx] = updated
          }
        }
      )
    }
  }

  private func delete(_ habit: HabitDayItem) {
    outbox.enqueue(
      method: "DELETE",
      path: "/api/habits/delete/\(habit.id)",
      body: nil,
      kind: "habits.delete"
    )
    model.habits.removeAll { $0.id == habit.id }
    Haptics.warning()
  }

  // MARK: - Sections

  private var summary: some View {
    let total = model.habits.count
    let done = model.habits.filter { $0.done }.count
    let skipped = model.habits.filter { $0.skipped }.count
    return Section {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(done)/\(total)")
            .font(.system(.title2, design: .rounded).weight(.semibold))
            .foregroundStyle(accent)
          Text("done today")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if skipped > 0 {
          VStack(alignment: .trailing, spacing: 2) {
            Text("\(skipped)")
              .font(.system(.title3, design: .rounded).weight(.semibold))
              .foregroundStyle(.secondary)
            Text("skipped")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func bucketSection(_ bucket: String) -> some View {
    let items = model.habits.filter { $0.bucket == bucket }
    let doneCount = items.filter { $0.done }.count
    if !items.isEmpty {
      Section {
        ForEach(items) { habit in
          Button { editing = habit } label: {
            HabitRow(habit: habit, model: model, outbox: outbox, tint: accent)
          }
          .buttonStyle(.plain)
          .listRowInsets(EdgeInsets())
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
              delete(habit)
            } label: {
              Label("Delete", systemImage: "trash")
            }
            Button {
              model.skipHabit(habit, skipped: !habit.skipped, outbox: outbox)
            } label: {
              Label(habit.skipped ? "Unskip" : "Skip",
                    systemImage: habit.skipped ? "arrow.uturn.left" : "forward.end")
            }
            .tint(Theme.inkSecondary)
          }
        }
      } header: {
        HStack {
          Text(bucket.capitalized)
          Spacer()
          Text("\(doneCount)/\(items.count)")
            .monospacedDigit()
        }
      }
    }
  }
}
