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
  /// Day the drawer's date strip is pointing at. Drives summary +
  /// bucket list, and which day toggles write to when browsing the past
  /// via the date strip — time-travel mode IS the backfill UX.
  @State private var viewingDate: String = SeptenaDate.today
  /// Past-day habit state for `viewingDate`. Loaded when
  /// `viewingDate != today` so we don't drag NextItemsModel off the
  /// "today" track.
  @State private var pastDay: HabitsDayResponse? = nil

  /// Per-bucket fold state for *today*. `nil` means "follow the clock" — the
  /// current bucket is open with its countdown, the others tuck behind their
  /// headers, and the open one advances as time passes. The first manual tap
  /// freezes it to an explicit collapsed set so nothing jumps afterwards.
  @State private var collapsedBuckets: Set<String>? = nil

  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  /// Server section key; accent comes from the user's Septena config so the
  /// hue matches the webapp / sidebar / Next tab without hard-coding.
  private var accent: Color { theme.color(for: "habits") }

  var body: some View {
    SectionDrawer(sectionKey: "habits",
                  onLog: { _ in creating = true },
                  currentDate: $viewingDate) {
      if isViewingToday {
        // Today folds into an accordion: the current time bucket is open with
        // a "time left" countdown, the others tuck behind their headers. The
        // minute tick lets the open bucket follow the clock until the user
        // taps a header (which freezes the fold state).
        TimelineView(.periodic(from: .now, by: 60)) { _ in
          ForEach(model.habitBuckets, id: \.self) { bucket in
            bucketSection(bucket)
          }
        }
      } else {
        pastDaySection
      }
    }
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load()
    }
    .sectionReload(on: viewingDate, onDataChange: true) { await reloadPastDay() }
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
    CheckableRow(
      tint: accent,
      isDone: item.done,
      isInactive: item.done,
      leadingEmoji: item.emoji ?? "•",
      title: item.name,
      onToggle: {
        // `viewingDate` is never today here (past-day rows only render when
        // not viewing today), so the streak-milestone path in `completeHabit`
        // is unreachable — write directly and use the canonical done/undone
        // haptic, matching today rows and the supplements past-day row.
        let next = !item.done
        checklistMutator.toggleHabit(id: item.id, date: viewingDate, done: next)
        if next { Haptics.success() } else { Haptics.tap() }
      }
    )
  }

  private func reloadPastDay() async {
    guard !isViewingToday else { pastDay = nil; return }
    let date = viewingDate
    pastDay = await MirrorReader.shared.read { ctx in
      ChecklistMirror.loadHabitsDay(context: ctx, date: date)
    }
  }

  private func delete(_ habit: HabitDayItem) {
    checklistMutator.deleteHabit(id: habit.id)
    model.habits.removeAll { $0.id == habit.id }
    Haptics.warning()
  }

  // MARK: - Sections

  /// Whether `bucket` is unfolded right now. Until the user taps a header
  /// (`collapsedBuckets == nil`) only the live bucket is open; after, we
  /// honor the frozen collapsed set.
  private func isExpanded(_ bucket: String) -> Bool {
    if let collapsedBuckets { return !collapsedBuckets.contains(bucket) }
    return DayBucket(rawValue: bucket) == DayBucket.current
  }

  private func toggleBucket(_ bucket: String) {
    withAnimation(.snappy) {
      // First tap seeds from the current auto-open state (only the live
      // bucket open) so the accordion freezes exactly as shown, then flips
      // the tapped one.
      var set = collapsedBuckets ?? Set(model.habitBuckets.filter {
        DayBucket(rawValue: $0) != DayBucket.current
      })
      if set.contains(bucket) { set.remove(bucket) } else { set.insert(bucket) }
      collapsedBuckets = set
    }
    Haptics.tap()
  }

  @ViewBuilder
  private func bucketSection(_ bucket: String) -> some View {
    // Full bucket — completed/skipped habits stay in place (struck through)
    // for the rest of today rather than fading out, so the drawer always
    // shows what was logged. (The homepage Next feed still hides done.)
    let all = model.habits.filter { $0.bucket == bucket }
    let doneCount = all.filter { $0.done }.count
    if !all.isEmpty {
      BucketDisclosure(bucket: bucket,
                       trailing: "\(doneCount)/\(all.count)",
                       isExpanded: isExpanded(bucket),
                       onToggle: { toggleBucket(bucket) }) {
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
