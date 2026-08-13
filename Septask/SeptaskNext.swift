import SwiftUI

// The Next feed — suggestions plus the chores / habits / supplements trio —
// composition only, per the Septask charter: every model and row view here is
// the SAME type Septena's Next tab renders (NextItemsModel / HabitRow /
// NextSuggestionRow …). What differs is the container.
//
// One host: `SeptaskNextPage` — standalone page for the AppKit sidebar
// destination, the iPhone Next tab, and the iPad SwiftUI sidebar destination.
// Same cuts from Septena's Next tab.
//
// Deliberate deltas from Septena's Next page, all composition-shaped:
//   • No "Tasks Today" block — Today IS that block (this page sits beside it).
//   • No "Done Today" log — forward glance only.
//   • No training suggestion — its destination is a Septena-sized surface
//     Septask doesn't compile. Mood check-in and meal logging present locally
//     (see SeptaskRootView / SeptaskKitNext modal switch).
//   • No List selection / keyboard cursor across Next rows.

// MARK: - Shared feed

/// The actionable Next body — suggestions + trio — used by the standalone
/// Next page. Owns the models and reload wiring so hosts can't drift.
struct SeptaskNextFeed: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(NavigationState.self) private var nav
  @Environment(ChecklistMutator.self) private var checklistMutator

  @State private var model = NextItemsModel()
  @State private var suggestionsModel = NextSuggestionsModel()

  @AppStorage(NextLinger.supplementsKey) private var lingerSupplements = NextLinger.supplementsDefault
  @AppStorage(NextLinger.habitsKey) private var lingerHabits = NextLinger.habitsDefault

  /// Section keys whose `.septenaDataChanged` posts the suggestions engine
  /// actually consumes — mirrors `NextView.suggestionKeys`.
  private static let suggestionKeys: Set<String> =
    ["intake", "nutrition", "training", "mood"]

  /// Trio blocks in the user's saved order. Tasks never render here — Today
  /// (or the Tasks lists) owns that block.
  private var orderedKeys: [String] {
    NextFeed.nextSectionKeys(from: settingsStore.sections).filter { $0 != "tasks" }
  }

  /// Sync paint-from-cache open count — iPad sidebar badge and AppKit
  /// `KitNextCount`. Same membership as `openCount` below (suggestions −
  /// skips − training, chores, habits/supplements due now with linger).
  @MainActor
  static func openCount(today: String, now: Date) -> Int {
    let model = NextItemsModel()
    model.paintFromCache(today: today, now: now)
    let suggestions = NextSuggestionsModel()
    suggestions.paintFromCache(today: today)

    let defaults = UserDefaults.standard
    let lingerHabits = (defaults.object(forKey: NextLinger.habitsKey) as? Bool)
      ?? NextLinger.habitsDefault
    let lingerSupplements = (defaults.object(forKey: NextLinger.supplementsKey) as? Bool)
      ?? NextLinger.supplementsDefault

    let visibleSuggestions = suggestions.suggestions.filter {
      !suggestions.skipped.contains($0.id) && $0.kind != .training
    }
    let habitsNow = model.openHabits.filter {
      DayBucket.isDueNow(bucketKey: $0.bucket, linger: lingerHabits)
    }
    let supplementsNow = model.openSupplements.filter {
      DayBucket.isDueNow(bucketKey: $0.bucket, linger: lingerSupplements)
    }
    return visibleSuggestions.count + model.openChores.count
      + habitsNow.count + supplementsNow.count
  }

  /// Suggestions minus today's skips, minus training (no in-app destination
  /// in Septask — see the file header).
  private var visibleSuggestions: [NextSuggestion] {
    suggestionsModel.suggestions.filter {
      !suggestionsModel.skipped.contains($0.id) && $0.kind != .training
    }
  }

  private var habitsNow: [HabitDayItem] {
    model.openHabits.filter { DayBucket.isDueNow(bucketKey: $0.bucket, linger: lingerHabits) }
  }

  private var supplementsNow: [SupplementDayItem] {
    model.openSupplements.filter { DayBucket.isDueNow(bucketKey: $0.bucket, linger: lingerSupplements) }
  }

  /// Everything still actionable — drives empty state.
  private var openCount: Int {
    visibleSuggestions.count + model.openChores.count
      + habitsNow.count + supplementsNow.count
  }

  var body: some View {
    Group {
      if openCount == 0 && model.hasLoaded {
        emptyRow
      } else {
        if !visibleSuggestions.isEmpty { suggestionsBlock }
        ForEach(orderedKeys, id: \.self) { key in
          trioBlock(for: key)
        }
      }
    }
    .task {
      model.paintFromCache(today: clock.today, now: clock.now)
      suggestionsModel.paintFromCache(today: clock.today)
      async let a: () = model.load(today: clock.today, now: clock.now)
      async let b: () = suggestionsModel.load(now: clock.now)
      _ = await (a, b)
    }
    // Scoped data changes reload only the models that consume them; inbound
    // CloudKit batches reload both from the mirror. (Mirrors NextView, minus
    // the Done-log path this feed doesn't render.)
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      if note.isCloudKitBatch {
        Task {
          async let a: () = model.load(today: clock.today, now: clock.now)
          async let b: () = suggestionsModel.load(now: clock.now)
          _ = await (a, b)
        }
        return
      }
      guard note.affectsAnySection(of: Self.suggestionKeys) else { return }
      Task { await suggestionsModel.load(now: clock.now) }
    }
    .onChange(of: clock.today) { _, _ in
      Task {
        async let a: () = model.load(today: clock.today, now: clock.now)
        async let b: () = suggestionsModel.load(now: clock.now)
        _ = await (a, b)
      }
    }
  }

  // MARK: - Block chrome

  private var emptyRow: some View {
    Text("Nothing here yet")
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.horizontal, TaskCardMetrics.contentInset)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .taskCardChrome(.solo)
  }

  /// Sub-block header — the Suggested / trio titles. A step down from a page
  /// / section-group header: smaller, lighter, and gray, so a block inside
  /// Next never competes with a task section header for the same rung.
  @ViewBuilder
  private func blockHeader(_ title: String, trailing: (() -> AnyView)? = nil) -> some View {
    HStack(spacing: 8) {
      Text(title)
        .scaledFont(size: (Theme.groupHeaderFontSize + 13) / 2,
                    weight: .medium, relativeTo: .subheadline)
        .foregroundStyle(Theme.inkSecondary)
      Spacer()
      if let trailing { trailing() }
    }
    .padding(.leading, TaskCardMetrics.headerLeading)
    .padding(.trailing, TaskCardMetrics.margin)
    .padding(.top, 12)
    .padding(.bottom, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Card a block's rows — the same continuous-card treatment task rows get.
  @ViewBuilder
  private func carded<Item: Identifiable, Row: View>(
    _ items: [Item], @ViewBuilder row: @escaping (Item) -> Row
  ) -> some View {
    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
      row(item)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taskCardChrome(TaskCardPosition(index: idx, count: items.count))
    }
  }

  // MARK: - Blocks

  private var suggestionsBlock: some View {
    VStack(alignment: .leading, spacing: 0) {
      blockHeader(String(localized: "Suggested", comment: "Next page — suggestions block header"))
      carded(visibleSuggestions) { suggestion in
        NextSuggestionRow(
          suggestion: suggestion,
          model: suggestionsModel,
          nav: nav,
          tint: suggestion.kindColor.flatMap(AdaptiveColor.adaptive)
            ?? theme.color(for: suggestion.kind.sectionKey)
        )
      }
    }
  }

  /// Bucketed block titles mirror Next's `bucketSectionHeader`: the current
  /// bucket's name prefixes the noun, with the time-left chip when strict.
  private func bucketTrailing(strict: Bool) -> (() -> AnyView)? {
    guard strict else { return nil }
    let bucket = DayBucket.current.rawValue
    return { AnyView(BucketTimeLeft(bucket: bucket, font: .footnote.weight(.semibold))) }
  }

  @ViewBuilder
  private func trioBlock(for key: String) -> some View {
    switch key {
    case "chores":
      if !model.openChores.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          blockHeader(String(localized: "Chores", comment: "Next page — chores block header"))
          carded(model.openChores) { chore in
            ChoreRow(chore: chore, model: model, checklistMutator: checklistMutator,
                     tint: theme.color(for: "chores"), showsTodayBadge: false)
          }
        }
      }
    case "habits":
      if !habitsNow.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          blockHeader("\(DayBucket.label(forKey: DayBucket.current.rawValue)) \(String(localized: "Habits", comment: "Next page — habits block header"))",
                      trailing: bucketTrailing(strict: !lingerHabits))
          carded(habitsNow) { habit in
            HabitRow(habit: habit, model: model, checklistMutator: checklistMutator,
                     tint: theme.color(for: "habits"))
          }
        }
      }
    case "supplements":
      if !supplementsNow.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          blockHeader("\(DayBucket.label(forKey: DayBucket.current.rawValue)) \(String(localized: "Supplements", comment: "Next page — supplements block header"))",
                      trailing: bucketTrailing(strict: !lingerSupplements))
          carded(supplementsNow) { supp in
            SupplementRow(supplement: supp, model: model, checklistMutator: checklistMutator,
                          tint: theme.color(for: "supplements"))
          }
        }
      }
    default:
      // `orderedKeys` only yields NextBlocks members; "tasks" is filtered
      // above. A new member without a case here should fail loudly in debug.
      let _ = { assertionFailure("SeptaskNextFeed has no case for Next block '\(key)'") }()
      EmptyView()
    }
  }
}

// MARK: - Standalone page (AppKit sidebar + iOS tab / iPad split)

/// Full-page Next feed — AppKit sidebar, iPhone tab, and iPad SwiftUI
/// sidebar destination. Suggestion destinations (mood / nutrition) present
/// as sheets here on macOS so the AppKit host doesn't need its own modal
/// switch; on iOS `SeptaskRootView` already owns that sheet.
struct SeptaskNextPage: View {
  #if os(macOS)
  @Environment(NavigationState.self) private var nav
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var dayClock
  @Environment(TaskMutator.self) private var taskMutator
  @Environment(AreasMutator.self) private var areasMutator
  @Environment(ProjectsMutator.self) private var projectsMutator
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(LogCommitCenter.self) private var logCommit
  @Environment(ChecklistMutator.self) private var checklistMutator
  #endif

  var body: some View {
    #if os(iOS)
    scrollContent
      .modifier(SeptaskNextPageChrome())
    #else
    macPage
    #endif
  }

  private var scrollContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        pageHeader
        SeptaskNextFeed()
      }
      .padding(.bottom, 24)
    }
    .background(Theme.groupedBackground.ignoresSafeArea())
  }

  #if os(macOS)
  private var macPage: some View {
    @Bindable var nav = nav
    return scrollContent
      .sheet(item: $nav.presentedModal) { modal in
        switch modal {
        case .addInfo(let section) where section == .nutrition:
          withEnvironment(NewNutritionEntrySheet())
            .septenaModalSheet(macWidth: 560, macHeight: 600)
        case .moodCheckin:
          withEnvironment(AddMoodPage(anchorTime: dayClock.now, date: dayClock.today))
            .septenaModalSheet(macWidth: 560, macHeight: 600)
        default:
          EmptyView()
        }
      }
  }
  #endif

  private var pageHeader: some View {
    HStack(spacing: Theme.iconTextGap) {
      Image(systemName: "arrow.right")
        .scaledFont(size: 22, weight: .semibold)
        .foregroundStyle(Theme.inkSecondary)
        .frame(width: 28, alignment: .center)
      Text("Next")
        .scaledFont(size: 28, weight: .bold, relativeTo: .largeTitle)
        .foregroundStyle(Theme.inkPrimary)
      Spacer()
    }
    .padding(.leading, TaskCardMetrics.headerLeading)
    .padding(.trailing, TaskCardMetrics.margin)
    .padding(.top, 28)
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  #if os(macOS)
  /// Re-inject the environment onto presented sheets — same belt-and-
  /// suspenders as `SeptaskRootView.withEnvironment` against `@Observable`
  /// loss across a presentation boundary.
  private func withEnvironment<V: View>(_ content: V) -> some View {
    content
      .environment(nav)
      .environment(theme)
      .environment(dayClock)
      .environment(taskMutator)
      .environment(areasMutator)
      .environment(projectsMutator)
      .environment(ckEngine)
      .environment(settingsStore)
      .environment(logCommit)
      .environment(checklistMutator)
  }
  #endif
}

#if os(iOS)
/// iPhone tab: gear in this page's nav bar. iPad split: the sidebar already
/// publishes chrome, so don't draw a second gear here.
private struct SeptaskNextPageChrome: ViewModifier {
  @Environment(\.usesPushNavigation) private var usesPushNavigation

  func body(content: Content) -> some View {
    if usesPushNavigation {
      content
    } else {
      content
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .pageChrome(id: "next", title: "Next")
    }
  }
}
#endif
