import SwiftUI
import SwiftData

// The Next feed — suggestions plus the chores / habits / supplements trio —
// embedded at the foot of Septask's Today list so a Septask user never has to
// bounce to Septena for the day's rituals. One outer fold ("Next"), open/closed
// from the header, state persisted.
//
// Composition only, per the Septask charter: every model and row view here is
// the SAME type Septena's Next tab renders (NextItemsModel / HabitRow /
// NextSuggestionRow …). What differs is the container: Septena's Next is a
// native `List`; Today's task list is a `SelectableScrollList`
// (ScrollView/LazyVStack), so the rows wear the Tasks surface's own card
// language (`taskCardChrome`) instead of List cells — same emphasis token as
// every other card on this surface, never a second style.
//
// Deliberate deltas from Septena's Next page, all composition-shaped:
//   • No "Tasks Today" block — the Today list right above IS that block.
//   • No "Done Today" log — the completed-timeline read too recursively on a
//     surface that's already the task log; Next here is the forward glance only.
//   • No training suggestion — its destination (the live training session)
//     is a Septena-sized surface Septask doesn't compile. Mood check-in and
//     meal logging present locally (see SeptaskRootView's modal switch).
//   • No List selection / keyboard cursor across Next rows — the task list
//     owns the selection model on this surface; Next rows stay tap/long-press
//     interactive exactly like iPhone.
struct SeptaskNextFold: View {
  /// Device-local prefs. `showInTodayKey` gates the whole fold (Settings ▸
  /// General); `collapsedKey` is the fold state the header chevron toggles.
  static let showInTodayKey = "septask.next.showInToday"
  static let collapsedKey = "septask.next.collapsed"

  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  @Environment(\.modelContext) private var modelContext
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(NavigationState.self) private var nav
  @Environment(ChecklistMutator.self) private var checklistMutator

  @State private var model = NextItemsModel()
  @State private var suggestionsModel = NextSuggestionsModel()

  @AppStorage(Self.showInTodayKey) private var showInToday = true
  @AppStorage(Self.collapsedKey) private var collapsed = false
  @AppStorage(NextLinger.supplementsKey) private var lingerSupplements = NextLinger.supplementsDefault
  @AppStorage(NextLinger.habitsKey) private var lingerHabits = NextLinger.habitsDefault

  /// Section keys whose `.septenaDataChanged` posts the suggestions engine
  /// actually consumes — mirrors `NextView.suggestionKeys`.
  private static let suggestionKeys: Set<String> =
    ["intake", "nutrition", "training", "mood"]

  // MARK: - Feed slices (same rules as NextView / NextOpenSection)

  /// Trio blocks in the user's saved order. The Today list above IS the
  /// tasks block, so it never renders twice.
  private var orderedKeys: [String] {
    NextFeed.nextSectionKeys(from: settingsStore.sections).filter { $0 != "tasks" }
  }

  /// Suggestions minus today's skips, minus training (no in-app destination
  /// in Septask — see the header comment).
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

  /// Everything still actionable — drives the fold header's count and the
  /// empty state.
  private var openCount: Int {
    visibleSuggestions.count + model.openChores.count
      + habitsNow.count + supplementsNow.count
  }

  var body: some View {
    if showInToday {
      // One plain VStack row inside the task scroll (not a Group of loose
      // siblings): the load / refresh modifiers below must attach once, to a
      // single stable anchor.
      VStack(alignment: .leading, spacing: 0) {
        // The seam between the task list above and Next below — a hairline on
        // the cards' content column so the two read as distinct bands.
        Divider()
          .padding(.leading, TaskCardMetrics.headerLeading)
          .padding(.trailing, TaskCardMetrics.margin)
          .padding(.top, 8)
        foldHeader
        if !collapsed {
          if openCount == 0 && model.hasLoaded {
            emptyRow
          } else {
            if !visibleSuggestions.isEmpty { suggestionsBlock }
            ForEach(orderedKeys, id: \.self) { key in
              trioBlock(for: key)
            }
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
      // the Done-log path this fold doesn't render.)
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
  }

  // MARK: - Fold header

  /// The top-level "Next" band header — a peer of the task list's section
  /// headers (icon column over the cards, title, count, rotating chevron), so
  /// the fold reads as one more section of this surface.
  private var foldHeader: some View {
    Button {
      Haptics.tick()
      a11yAnimate(.easeInOut(duration: 0.2)) { collapsed.toggle() }
    } label: {
      HStack(spacing: Theme.iconTextGap) {
        Image(systemName: "arrow.right")
          .scaledFont(size: 16)
          .foregroundStyle(Theme.iconMuted)
          .frame(width: Theme.checkboxTap, alignment: .center)
          .offset(x: -Theme.checkboxLeadingNudge)
        Text("Next").sectionGroupHeaderTitleStyle()
        if openCount > 0 {
          Text("\(openCount)")
            .scaledFont(size: Theme.groupHeaderFontSize, weight: .regular)
            .monospacedDigit()
            .foregroundStyle(Theme.inkSecondary)
        }
        Spacer()
        Image(systemName: "chevron.down")
          .scaledFont(size: 12, weight: .semibold)
          .foregroundStyle(Theme.iconMuted)
          .rotationEffect(.degrees(collapsed ? -90 : 0))
      }
      .padding(.leading, TaskCardMetrics.headerLeading)
      .padding(.trailing, TaskCardMetrics.margin)
      .padding(.top, 12)
      .padding(.bottom, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint(collapsed ? "Expand" : "Collapse")
  }

  private var emptyRow: some View {
    Text("Nothing here yet")
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.horizontal, TaskCardMetrics.contentInset)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .taskCardChrome(.solo)
  }

  // MARK: - Block chrome

  /// Sub-block header — the Suggested / trio titles INSIDE the Next fold. A
  /// step down from `sectionGroupHeaderTitleStyle` (the task/fold headers):
  /// smaller, lighter, and gray, so a block inside Next never competes with a
  /// task section header for the same rung of the hierarchy.
  @ViewBuilder
  private func blockHeader(_ title: String, trailing: (() -> AnyView)? = nil) -> some View {
    HStack(spacing: 8) {
      Text(title)
        // Halfway between the task/fold header size (`groupHeaderFontSize`,
        // 17 mac / 20 iOS) and the first, too-small pass (13): ~15 mac /
        // ~16.5 iOS. Still lighter + gray so a block inside Next stays
        // subordinate to a task section header.
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
      blockHeader(String(localized: "Suggested", comment: "Next fold — suggestions block header"))
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
          blockHeader(String(localized: "Chores", comment: "Next fold — chores block header"))
          carded(model.openChores) { chore in
            ChoreRow(chore: chore, model: model, checklistMutator: checklistMutator,
                     tint: theme.color(for: "chores"), showsTodayBadge: false)
          }
        }
      }
    case "habits":
      if !habitsNow.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          blockHeader("\(DayBucket.label(forKey: DayBucket.current.rawValue)) \(String(localized: "Habits", comment: "Next fold — habits block header"))",
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
          blockHeader("\(DayBucket.label(forKey: DayBucket.current.rawValue)) \(String(localized: "Supplements", comment: "Next fold — supplements block header"))",
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
      let _ = { assertionFailure("SeptaskNextFold has no case for Next block '\(key)'") }()
      EmptyView()
    }
  }
}
