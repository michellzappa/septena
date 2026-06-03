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
  // Optional: this view is also hosted inside the Home-Screen-Quick-Action
  // sheet (RootTabView's `pendingSection`), which doesn't inherit the root
  // environment. A missing center degrades to "no celebration", never a
  // crash. The toggle + haptic always run.
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

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
    .adaptiveDetail(item: $editing) { habit in
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
    .adaptiveDetail(isPresented: $creating) {
      EditHabitSheet(
        original: nil,
        buckets: model.habitBuckets,
        onDone: { _ in Task { await model.load() } }
      )
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

  // Mirrors `HabitRow` (today) exactly: shared `TaskCheckbox` glyph, same
  // fonts/padding/strikethrough treatment, checkbox-only tap target. Only the
  // write target differs — it commits to `viewingDate`, not today.
  private func pastDayRow(_ item: HabitDayItem) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(tint: accent, isDone: item.done) {
        // `viewingDate` is never today here (past-day rows only render when
        // not viewing today), so the streak-milestone path in `completeHabit`
        // is unreachable — write directly and use the canonical done/undone
        // haptic, matching today rows and the supplements past-day row.
        let next = !item.done
        checklistMutator.toggleHabit(id: item.id, date: viewingDate, done: next)
        if next { Haptics.success() } else { Haptics.tap() }
      }
      .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
      Text(item.emoji ?? "•").font(.body)
      Text(item.name)
        .font(.septenaTaskTitle)
        .foregroundStyle(item.done ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(item.done)
        .opacity(item.done ? 0.5 : 1)
      Spacer()
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding)
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

  @ViewBuilder
  private func bucketSection(_ bucket: String) -> some View {
    // Full bucket — completed/skipped habits stay in place (struck through)
    // for the rest of today rather than fading out, so the drawer always
    // shows what was logged. (The homepage Next feed still hides done.)
    let all = model.habits.filter { $0.bucket == bucket }
    let doneCount = all.filter { $0.done }.count
    if !all.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        DayBucketHeader(bucket: bucket,
                        trailing: "\(doneCount)/\(all.count)")
          .padding(.horizontal, 16)
        DrawerSection(padding: .none) {
          ForEach(all) { habit in
            Button { editing = habit } label: {
              HabitRow(habit: habit, model: model, checklistMutator: checklistMutator, tint: accent,
                       onDelete: { delete(habit) })
            }
            .buttonStyle(.plain)
            .transition(.opacity)
          }
        }
      }
    }
  }
}
