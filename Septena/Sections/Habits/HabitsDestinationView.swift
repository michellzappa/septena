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
  @State private var viewing: HabitDayItem? = nil
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
  /// Per-habit 30-day completion rate (id → percent), shown in each row's
  /// trailing slot instead of the time-of-day. Computed in one query on load
  /// and after any write.
  @State private var rates: [String: Int] = [:]

  /// Per-bucket fold state for *today*. `nil` means "follow the clock" — the
  /// current bucket is open with its countdown, the others tuck behind their
  /// headers, and the open one advances as time passes. The first manual tap
  /// freezes it to an explicit collapsed set so nothing jumps afterwards.
  @State private var collapsedBuckets: Set<String>? = nil
  // Habits is an editable dual section: Log = the actionable checklist
  // (time-travelable); Patterns = whole-stack completion heatmap. Default Log —
  // the checklist is the morning surface, so no empty-state nudge here.
  @State private var mode: DrawerMode = .remembered(for: "habits", default: .log)
  @State private var history: [CompletionDay] = []

  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  /// Server section key; accent comes from the user's Septena config so the
  /// hue matches the webapp / sidebar / Next tab without hard-coding.
  private var accent: Color { theme.color(for: "habits") }

  var body: some View {
    SectionDrawer(sectionKey: "habits",
                  quickAdd: DrawerQuickAdd("New habit") { creating = true },
                  currentDate: $viewingDate,
                  mode: $mode,
                  log: {
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
    }, patterns: {
      CompletionPatternsSection(title: "Completion", accent: accent,
                                days: history, loading: !model.hasLoaded)
      byHabitSection
    })
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load()
      await loadRates()
      await loadHistory()
    }
    .sectionReload(on: viewingDate, onDataChange: true,
                   forSections: ["habits"]) { await reloadPastDay() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      if note.affectsSection("habits") { Task { await loadRates(); await loadHistory() } }
    }
    // Tapping a habit opens its detail "infobox" (streak + history +
    // consistency); the row's checkbox still checks it off. "Edit" in the
    // detail swaps to the editor for the same habit.
    .adaptiveDetail(item: $viewing) { habit in
      LoggableDetailView(
        title: habit.name,
        emoji: habit.emoji,
        accent: accent,
        doneVerb: "done",
        fetch: { ChecklistMirror.habitCompletionDates(context: $0, habitID: habit.id) },
        skippedFetch: { ChecklistMirror.habitSkippedDates(context: $0, habitID: habit.id) },
        onEdit: { viewing = nil; editing = habit }
      )
    }
    .adaptiveDetail(item: $editing) { habit in
      EditHabitSheet(
        original: habit,
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
          Text("Nothing logged on this day.")
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

  /// 30-day completion-rate query runs over the habits' whole state table —
  /// the largest checklist table — so route it through the background reader
  /// instead of the view's main context, or it hitches the push transition.
  private func loadRates() async {
    rates = await MirrorReader.shared.read { ChecklistMirror.habitCompletionRates(context: $0) }
  }

  /// Whole-stack daily completion for the Patterns heatmap (trailing ~17 weeks).
  private func loadHistory() async {
    let resp = await MirrorReader.shared.read {
      ChecklistMirror.loadHabitsHistory(context: $0, days: 119)
    }
    history = resp.daily.map { CompletionDay(date: $0.date, done: $0.done, total: $0.total) }
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

  // MARK: - Patterns breakdown

  /// Per-habit drill-in for Patterns mode — every habit in the stack, tap to
  /// open its consistency heatmap (the same detail the Log rows open). Subtitle
  /// reuses the already-loaded 30-day completion rate, so no extra query.
  private var byHabitSection: some View {
    let rows = model.habits.map { habit in
      BreakdownRow(id: habit.id,
                   title: habit.emoji.map { "\($0) \(habit.name)" } ?? habit.name,
                   detail: "\(rates[habit.id] ?? 0)% last 30 days")
    }
    return SectionBreakdownList(
      title: "By habit", rows: rows, accent: accent,
      selectedID: viewing?.id,
      onTap: { id in viewing = model.habits.first { $0.id == id } }
    )
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
            Button { viewing = habit } label: {
              HabitRow(habit: habit, model: model, checklistMutator: checklistMutator, tint: accent,
                       onDelete: { delete(habit) }, completionRate: rates[habit.id] ?? 0)
            }
            .buttonStyle(.plain)
            .transition(.opacity)
          }
        }
      }
    }
  }
}
