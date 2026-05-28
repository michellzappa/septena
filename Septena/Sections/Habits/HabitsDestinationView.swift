import SwiftUI

// Habits mini-app — full-day list grouped by time-of-day bucket. Reached
// by tapping the Habits tile on the Week dashboard. Reuses NextItemsModel
// for loading + optimistic mutations and HabitRow for the row UI, so the
// behavior is identical to the Next tab's current-bucket strip — just
// showing every bucket rather than only "now".

struct HabitsDestinationView: View {
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()
  @State private var editing: HabitDayItem? = nil
  @State private var creating = false
  @State private var history: [HabitHistoryPoint] = []
  /// Wrapper so `.sheet(item:)` can drive the backfill sheet directly off
  /// the picked ISO date. `String` isn't `Identifiable` and we don't want
  /// to extend it globally.
  private struct BackfillDate: Identifiable { let id: String }
  @State private var backfillDate: BackfillDate? = nil

  /// Server section key; accent comes from the user's Septena config so the
  /// hue matches the webapp / sidebar / Next tab without hard-coding.
  private var accent: Color { theme.color(for: "habits") }

  var body: some View {
    SectionDrawer(sectionKey: "habits",
                  title: "Habits",
                  onLog: { _ in creating = true }) {
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
          total: { $0.total },
          onTapDay: { iso in backfillDate = BackfillDate(id: iso) }
        )
      }
    }
    .trackScreen("habits")
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load()
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
        onDone: { _ in Task { await model.load() } }
      )
      #if os(iOS)
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      #endif
    }
    .sheet(item: $backfillDate) { wrap in
      BackfillHabitsSheet(date: wrap.id)
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
    var stats: [Stat] = [
      Stat(value: "\(done)/\(total)", label: "done today", tint: accent),
    ]
    if skipped > 0 {
      stats.append(Stat(value: "\(skipped)", label: "skipped"))
    }
    return DrawerSection { StatStrip(stats: stats) }
  }

  @ViewBuilder
  private func bucketSection(_ bucket: String) -> some View {
    let items = model.habits.filter { $0.bucket == bucket }
    let doneCount = items.filter { $0.done }.count
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        DayBucketHeader(bucket: bucket,
                        trailing: "\(doneCount)/\(items.count)")
          .padding(.horizontal, 16)
        DrawerSection(padding: .none) {
          ForEach(items) { habit in
            Button { editing = habit } label: {
              HabitRow(habit: habit, model: model, checklistMutator: checklistMutator, tint: accent,
                       onDelete: { delete(habit) })
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }
}
