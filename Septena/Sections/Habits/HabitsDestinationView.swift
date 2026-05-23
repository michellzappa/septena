import SwiftUI

// Habits mini-app — full-day list grouped by time-of-day bucket. Reached
// by tapping the Habits tile on the Week dashboard. Reuses NextItemsModel
// for loading + optimistic mutations and HabitRow for the row UI, so the
// behavior is identical to the Next tab's current-bucket strip — just
// showing every bucket rather than only "now".

struct HabitsDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()
  @State private var editing: HabitDayItem? = nil
  @State private var creating = false
  @State private var history: [HabitHistoryPoint] = []

  /// Server section key; accent comes from the user's Septena config so the
  /// hue matches the webapp / sidebar / Next tab without hard-coding.
  private var accent: Color { theme.color(for: "habits") }

  var body: some View {
    List {
      summary
      ForEach(model.habitBuckets, id: \.self) { bucket in
        bucketSection(bucket)
      }
      if !history.isEmpty {
        ChecklistHeatmapSection(
          title: "Habit consistency",
          noun: "habit",
          accent: accent,
          daily: history,
          date: { $0.date },
          done: { $0.done },
          total: { $0.total }
        )
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Habits")
    .trackScreen("habits")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { creating = true } label: { Image(systemName: "plus") }
          .tint(accent)
      }
    }
    .task {
      model.paintFromCache()
      await model.load(client: client)
      // History is computed locally from the CloudKit-backed mirror.
      let resp = ChecklistMirror.loadHabitsHistory(
        context: LocalStore.shared.container.mainContext, days: 365)
      history = resp.daily
    }
    .sheet(item: $editing) { habit in
      EditHabitSheet(
        original: habit,
        buckets: model.habitBuckets,
        onDone: { updated in
          if let updated, let idx = model.habits.firstIndex(where: { $0.id == updated.id }) {
            model.habits[idx] = updated
          }
        }
      )
    }
    .sheet(isPresented: $creating) {
      EditHabitSheet(
        original: nil,
        buckets: model.habitBuckets,
        onDone: { _ in Task { await model.load(client: client) } }
      )
      #if os(iOS)
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      #endif
    }
  }

  private func delete(_ habit: HabitDayItem) {
    checklistMutator.deleteHabit(id: habit.id)
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
            HabitRow(habit: habit, model: model, checklistMutator: checklistMutator, tint: accent,
                     onDelete: { delete(habit) })
          }
          .buttonStyle(.plain)
          .listRowInsets(EdgeInsets())
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
