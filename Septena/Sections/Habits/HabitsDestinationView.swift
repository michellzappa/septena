import SwiftUI

// Habits mini-app — full-day list grouped by time-of-day bucket. Reached
// by tapping the Habits tile on the Week dashboard. Reuses NextItemsModel
// for loading + optimistic mutations and HabitRow for the row UI, so the
// behavior is identical to the Next tab's current-bucket strip — just
// showing every bucket rather than only "now".

struct HabitsDestinationView: View {
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()
  @State private var editing: HabitDayItem? = nil
  @State private var creating = false
  @State private var history: [HabitHistoryPoint] = []
  /// Day the drawer's date strip is pointing at. Drives summary +
  /// bucket list + heatmap hiding when on a past day. Heatmap tap
  /// updates this instead of opening a modal backfill sheet —
  /// time-travel mode IS the backfill UX.
  @State private var viewingDate: String = SeptenaDate.today
  /// Past-day habit state for `viewingDate`. Loaded when
  /// `viewingDate != today` so we don't drag NextItemsModel off the
  /// "today" track.
  @State private var pastDay: HabitsDayResponse? = nil

  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  /// Server section key; accent comes from the user's Septena config so the
  /// hue matches the webapp / sidebar / Next tab without hard-coding.
  private var accent: Color { theme.color(for: "habits") }

  var body: some View {
    SectionDrawer(sectionKey: "habits",
                  title: "Habits",
                  onLog: { _ in creating = true },
                  currentDate: $viewingDate) {
      if isViewingToday {
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
            // Heatmap tap now jumps the date strip rather than opening
            // a modal — same pattern as Caffeine / Gut / Nutrition.
            onTapDay: { iso in viewingDate = iso }
          )
        }
      } else {
        pastDaySection
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
    .onChange(of: viewingDate) { _, _ in reloadPastDay() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reloadPastDay()
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
  }

  // MARK: - Past-day section
  //
  // Renders `loadHabitsDay(date:)` inline for `viewingDate`, mirroring
  // the rows that BackfillHabitsSheet uses but without the modal
  // chrome. Toggles write at `viewingDate` so the user can correct
  // historical state directly from the drawer.

  @ViewBuilder
  private var pastDaySection: some View {
    if let resp = pastDay {
      let allItems = resp.buckets.flatMap { resp.grouped[$0] ?? [] }
      if allItems.isEmpty {
        DrawerSection {
          Text("No habits defined.")
            .foregroundStyle(.secondary)
        }
      } else {
        ForEach(resp.buckets, id: \.self) { bucket in
          let items = resp.grouped[bucket] ?? []
          if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              DayBucketHeader(bucket: bucket,
                              trailing: "\(items.filter(\.done).count)/\(items.count)")
                .padding(.horizontal, 16)
              DrawerSection(padding: .none) {
                ForEach(items) { item in
                  pastDayRow(item)
                }
              }
            }
          }
        }
      }
    } else {
      DrawerSection { ProgressView() }
    }
  }

  private func pastDayRow(_ item: HabitDayItem) -> some View {
    Button {
      let next = !item.done
      checklistMutator.toggleHabit(id: item.id, date: viewingDate, done: next)
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
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }
    .buttonStyle(.plain)
  }

  private func reloadPastDay() {
    guard !isViewingToday else { pastDay = nil; return }
    pastDay = ChecklistMirror.loadHabitsDay(context: modelContext, date: viewingDate)
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
