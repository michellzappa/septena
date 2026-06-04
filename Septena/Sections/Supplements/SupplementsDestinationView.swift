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
  @State private var editing: SupplementDayItem? = nil
  @State private var creating = false
  /// Day the drawer's date strip is pointing at; toggles write to this
  /// day when browsing the past via the date strip.
  @State private var viewingDate: String = SeptenaDate.today
  /// Past-day state for `viewingDate`. Loaded when not viewing today.
  @State private var pastDay: SupplementsDayResponse? = nil

  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  private var accent: Color { theme.color(for: "supplements") }

  var body: some View {
    SectionDrawer(sectionKey: "supplements",
                  title: "Supplements",
                  onLog: { _ in creating = true },
                  currentDate: $viewingDate) {
      if isViewingToday {
        todaySections
      } else {
        pastDaySection
      }
    }
    .trackScreen("supplements")
    .tint(accent)
    .task {
      model.paintFromCache()
      await model.load()
    }
    .onChange(of: viewingDate) { _, _ in reloadPastDay() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reloadPastDay()
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
      ContentUnavailableView("No supplements configured",
                             systemImage: theme.icon(for: "supplements"),
                             description: Text("Tap + to add a supplement."))
    } else if Self.isFlat(sections) {
      if !model.supplements.isEmpty {
        DrawerSection("Today", padding: .none) {
          ForEach(model.supplements) { supp in todayRow(supp) }
        }
      }
    } else {
      ForEach(sections, id: \.key) { section in
        bucketSection(section.key, items: section.items) { todayRow($0) }
      }
    }
  }

  private func todayRow(_ supp: SupplementDayItem) -> some View {
    Button { editing = supp } label: {
      SupplementRow(supplement: supp, model: model, checklistMutator: checklistMutator, tint: accent,
                    onDelete: { delete(supp) })
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
          Text("No supplements configured.")
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
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(tint: accent, isDone: item.done) {
        let next = !item.done
        checklistMutator.toggleSupplement(id: item.id, date: viewingDate, done: next)
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
    pastDay = ChecklistMirror.loadSupplementsDay(context: modelContext, date: viewingDate)
  }

  private func delete(_ supp: SupplementDayItem) {
    checklistMutator.deleteSupplement(id: supp.id)
    model.supplements.removeAll { $0.id == supp.id }
    Haptics.warning()
  }

}
