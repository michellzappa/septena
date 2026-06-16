import SwiftUI

// Supplements mini-app — single flat list of today's stack. Simpler than
// Habits (no time-of-day bucketing) and Chores (no defer / overdue);
// supplements are taken or not, that's it. Reuses NextItemsModel and the
// promoted SupplementRow.

struct SupplementsDestinationView: View {
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  @State private var model = NextItemsModel()
  @State private var viewing: SupplementDayItem? = nil
  @State private var editing: SupplementDayItem? = nil
  @State private var creating = false
  /// Day the drawer's date strip is pointing at; toggles write to this
  /// day when browsing the past via the date strip.
  @State private var viewingDate: String = SeptenaDate.today
  /// Past-day state for `viewingDate`. Loaded when not viewing today.
  @State private var pastDay: SupplementsDayResponse? = nil
  /// Per-supplement 30-day completion rate (id → percent), shown in each row's
  /// trailing slot instead of the time-of-day. One query on load + after writes.
  @State private var rates: [String: Int] = [:]

  /// Per-bucket fold state for *today*. `nil` means "follow the clock" — the
  /// current time bucket is open with its countdown, the other time buckets
  /// tuck behind their headers. "Anytime" never folds (handled separately).
  /// The first manual tap freezes it to an explicit collapsed set.
  @State private var collapsedBuckets: Set<String>? = nil
  // Supplements is an editable dual section: Log = the actionable stack
  // (time-travelable); Patterns = whole-stack adherence heatmap. Default Log;
  // the checklist is the surface you act on, so no empty-state nudge.
  @State private var mode: DrawerMode = .remembered(for: "supplements", default: .log)
  @State private var history: [CompletionDay] = []

  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  private var accent: Color { theme.color(for: "supplements") }

  var body: some View {
    SectionDrawer(sectionKey: "supplements",
                  quickAdd: DrawerQuickAdd("New supplement") { creating = true },
                  currentDate: $viewingDate,
                  mode: $mode,
                  log: {
      if isViewingToday {
        todaySections
      } else {
        pastDaySection
      }
    }, patterns: {
      CompletionPatternsSection(title: "Adherence", accent: accent,
                                days: history, loading: !model.hasLoaded)
      bySupplementSection
    })
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load()
      await loadRates()
      await loadHistory()
    }
    .sectionReload(on: viewingDate, onDataChange: true,
                   forSections: ["supplements"]) { await reloadPastDay() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      if note.affectsSection("supplements") { Task { await loadRates(); await loadHistory() } }
    }
    // Tapping a supplement opens its detail "infobox" (streak + history +
    // consistency); the row's checkbox still marks it taken. "Edit" swaps to
    // the editor for the same supplement.
    .adaptiveDetail(item: $viewing) { supp in
      LoggableDetailView(
        title: supp.name,
        emoji: supp.emoji,
        accent: accent,
        doneVerb: "taken",
        fetch: { ChecklistMirror.supplementCompletionDates(context: $0, supplementID: supp.id) },
        onEdit: { viewing = nil; editing = supp }
      )
    }
    .adaptiveDetail(item: $editing) { supp in
      EditSupplementSheet(
        original: supp,
        onDone: { updated in
          if let updated, let idx = model.supplements.firstIndex(where: { $0.id == updated.id }) {
            model.supplements[idx] = updated
          }
        }
      )
    }
    .adaptiveDetail(isPresented: $creating) {
      EditSupplementSheet(
        original: nil,
        onDone: { _ in Task { await model.load() } }
      )
    }
  }

  // MARK: - Patterns breakdown

  /// Per-supplement drill-in for Patterns mode — every supplement in the stack,
  /// tap to open its consistency heatmap (same detail the Log rows open).
  /// Subtitle reuses the already-loaded 30-day rate, so no extra query.
  private var bySupplementSection: some View {
    let rows = model.supplements.map { supp in
      BreakdownRow(id: supp.id,
                   title: supp.emoji.map { "\($0) \(supp.name)" } ?? supp.name,
                   detail: "\(rates[supp.id] ?? 0)% last 30 days")
    }
    return SectionBreakdownList(
      title: "By supplement", rows: rows, accent: accent,
      selectedID: viewing?.id,
      onTap: { id in viewing = model.supplements.first { $0.id == id } }
    )
  }

  // MARK: - Today

  // Full day's stack — taken supplements stay in place (struck through) for
  // the rest of today rather than fading out, so the drawer always shows what
  // was logged. (The homepage Next feed still hides done + filters by bucket.)
  // When nothing is bucketed the stack renders as one flat "Today" list
  // (unchanged); the moment a supplement gets a time of day it groups into
  // morning / afternoon / evening / anytime sections, like Habits.
  @ViewBuilder
  private var todaySections: some View {
    let sections = Self.groupedSections(model.supplements)
    if model.hasLoaded && model.supplements.isEmpty {
      ContentUnavailableView("No supplements yet",
                             systemImage: theme.icon(for: "supplements"),
                             description: Text("Tap + to add a supplement."))
    } else if Self.isFlat(sections) {
      if !model.supplements.isEmpty {
        DrawerSection("Today", padding: .none) {
          ForEach(model.supplements) { supp in todayRow(supp) }
        }
      }
    } else {
      // Accordion on today: the current time bucket opens with a "time left"
      // countdown, the other time buckets fold behind their headers. "Anytime"
      // has no cutoff and is always actionable, so it stays open. The minute
      // tick lets the open bucket follow the clock until the user taps.
      TimelineView(.periodic(from: .now, by: 60)) { _ in
        ForEach(sections, id: \.key) { section in
          if section.key == DayBucket.anytimeKey {
            bucketSection(section.key, items: section.items) { todayRow($0) }
          } else {
            BucketDisclosure(bucket: section.key,
                             trailing: "\(section.items.filter(\.done).count)/\(section.items.count)",
                             isExpanded: isExpanded(section.key),
                             onToggle: { toggleBucket(section.key) }) {
              DrawerSection(padding: .none) {
                ForEach(section.items) { item in todayRow(item) }
              }
            }
          }
        }
      }
    }
  }

  // MARK: - Accordion fold state (today)

  /// Whether `key` is unfolded right now. "Anytime" is always open; otherwise
  /// until the user taps a header (`collapsedBuckets == nil`) only the live
  /// time bucket is open, and after that we honor the frozen collapsed set.
  private func isExpanded(_ key: String) -> Bool {
    if key == DayBucket.anytimeKey { return true }
    if let collapsedBuckets { return !collapsedBuckets.contains(key) }
    return DayBucket(rawValue: key) == DayBucket.current
  }

  private func toggleBucket(_ key: String) {
    withAnimation(.snappy) {
      // First tap seeds from the current auto-open state (only the live time
      // bucket open) so the accordion freezes exactly as shown, then flips the
      // tapped one. "Anytime" is excluded — it never folds.
      var set = collapsedBuckets ?? Set(
        Self.groupedSections(model.supplements)
          .map(\.key)
          .filter { $0 != DayBucket.anytimeKey && DayBucket(rawValue: $0) != DayBucket.current }
      )
      if set.contains(key) { set.remove(key) } else { set.insert(key) }
      collapsedBuckets = set
    }
    Haptics.tap()
  }

  private func todayRow(_ supp: SupplementDayItem) -> some View {
    Button { viewing = supp } label: {
      SupplementRow(supplement: supp, model: model, checklistMutator: checklistMutator, tint: accent,
                    onDelete: { delete(supp) }, completionRate: rates[supp.id] ?? 0)
    }
    .buttonStyle(.plain)
    .transition(.opacity)
  }

  // MARK: - Bucket grouping

  /// Group a day's supplements into ordered sections: the day's time buckets
  /// (morning → evening) first, then an "Anytime" catch-all for unbucketed
  /// ones. Empty buckets drop out. Order within a bucket is the incoming
  /// (sortIndex) order, which `Dictionary(grouping:)` preserves.
  static func groupedSections(_ items: [SupplementDayItem]) -> [(key: String, items: [SupplementDayItem])] {
    let order = DayBucket.allCases.map(\.rawValue) + [DayBucket.anytimeKey]
    let byKey = Dictionary(grouping: items) { $0.bucket ?? DayBucket.anytimeKey }
    return order.compactMap { key in
      guard let group = byKey[key], !group.isEmpty else { return nil }
      return (key: key, items: group)
    }
  }

  /// True when nothing is bucketed — the only section is "Anytime" (or there
  /// are none) — so the stack renders as one flat list (the pre-bucketing
  /// look). Keeps the feature invisible until the user opts a supplement in.
  static func isFlat(_ sections: [(key: String, items: [SupplementDayItem])]) -> Bool {
    sections.allSatisfy { $0.key == DayBucket.anytimeKey }
  }

  // Shared header + card for one bucket section, used by today and past-day.
  @ViewBuilder
  private func bucketSection<RowView: View>(_ key: String,
                                            items: [SupplementDayItem],
                                            @ViewBuilder row: @escaping (SupplementDayItem) -> RowView) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      DayBucketHeader(bucket: key,
                      trailing: "\(items.filter(\.done).count)/\(items.count)")
        .padding(.horizontal, 16)
      DrawerSection(padding: .none) {
        ForEach(items) { item in row(item) }
      }
    }
  }

  // MARK: - Past-day section

  @ViewBuilder
  private var pastDaySection: some View {
    if let resp = pastDay {
      if resp.items.isEmpty {
        DrawerSection {
          Text("Nothing logged on this day.")
            .foregroundStyle(.secondary)
        }
      } else {
        let sections = Self.groupedSections(resp.items)
        if Self.isFlat(sections) {
          DrawerSection(padding: .none) {
            ForEach(resp.items) { item in pastDayRow(item) }
          }
        } else {
          ForEach(sections, id: \.key) { section in
            bucketSection(section.key, items: section.items) { pastDayRow($0) }
          }
        }
      }
    } else {
      DrawerSection { ProgressView() }
    }
  }

  // Mirrors `SupplementRow` (today) exactly: shared `TaskCheckbox` glyph, same
  // fonts/padding/strikethrough treatment, checkbox-only tap target. Only the
  // write target differs — it commits to `viewingDate`, not today.
  private func pastDayRow(_ item: SupplementDayItem) -> some View {
    CheckableRow(
      tint: accent,
      isDone: item.done,
      isInactive: item.done,
      leadingEmoji: item.emoji ?? "•",
      title: item.name,
      onToggle: {
        let next = !item.done
        checklistMutator.toggleSupplement(id: item.id, date: viewingDate, done: next)
        if next { Haptics.success() } else { Haptics.tap() }
      }
    )
  }

  /// Route the 30-day rate query through the background reader rather than the
  /// view's main context, so it can't hitch the push transition. Mirrors Habits.
  private func loadRates() async {
    rates = await MirrorReader.shared.read { ChecklistMirror.supplementCompletionRates(context: $0) }
  }

  /// Whole-stack daily adherence for the Patterns heatmap (trailing ~17 weeks).
  private func loadHistory() async {
    let resp = await MirrorReader.shared.read {
      ChecklistMirror.loadSupplementsHistory(context: $0, days: 119)
    }
    history = resp.daily.map { CompletionDay(date: $0.date, done: $0.done, total: $0.total) }
  }

  private func reloadPastDay() async {
    guard !isViewingToday else { pastDay = nil; return }
    let date = viewingDate
    pastDay = await MirrorReader.shared.read { ctx in
      ChecklistMirror.loadSupplementsDay(context: ctx, date: date)
    }
  }

  private func delete(_ supp: SupplementDayItem) {
    checklistMutator.deleteSupplement(id: supp.id)
    model.supplements.removeAll { $0.id == supp.id }
    Haptics.warning()
  }

}
