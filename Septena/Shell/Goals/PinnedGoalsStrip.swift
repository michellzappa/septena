import SwiftUI
import SwiftData

// PinnedGoalsStrip — the user's pinned goals, surfaced at the top of the Week
// dashboard above the section-tile grid. A goal is "pinned" (GoalEntity.pinned)
// from the Goals tab; this strip renders nothing until at least one is, so the
// dashboard is unchanged for users who pin nothing.
//
// Each pinned goal is mapped to a HomepageDomainData and rendered through the
// SAME `HomepageTileLayout` the section tiles use — so a pinned goal matches the
// current layout mode (heatmap when others are heatmaps, sparkline when they're
// sparklines), not a bespoke renderer. The metric type only shapes the *data*:
// a habit-backed goal contributes its daily completion series, which reads as a
// consistency/streak heatmap; other metrics show the target progress + headline.

struct PinnedGoalsStrip: View {
  let layoutMode: HomepageLayoutMode
  let columns: [GridItem]

  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var context

  /// Live set of pinned goals, ordered the same way the Goals tab orders them.
  @Query(filter: #Predicate<GoalEntity> { $0.pinned },
         sort: \GoalEntity.sortIndex) private var pinned: [GoalEntity]

  @State private var editing: Goal? = nil
  @State private var availableSections: [SectionConfig] = []

  private var goalMutator: GoalMutator { SeptenaServices.shared.goalMutator }

  /// Trailing window for a habit-backed goal's consistency series — 12 weeks,
  /// enough to read a streak in the heatmap without crowding the tile.
  private static let historyDays = 84
  private static let ymd: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  var body: some View {
    if !pinned.isEmpty {
      VStack(alignment: .leading, spacing: Theme.tileGap) {
        Text("Pinned")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
          .padding(.leading, 4)

        HomepageTileLayout(
          mode: layoutMode,
          items: pinned.map(domainData),
          columns: columns,
          onTap: handleTap
        ) { item in
          Button { unpin(item) } label: {
            Label("Unpin from dashboard", systemImage: "pin.slash")
          }
        }
      }
      .task {
        availableSections = SettingsMirror.loadSections(context: context)
          .filter { $0.key != "goals" }
      }
      .sheet(item: $editing) { goal in
        EditGoalSheet(
          goal: goal,
          availableSections: availableSections,
          theme: theme,
          mutator: goalMutator,
          onUpdate: { _ in },
          onDelete: { _ in }
        )
      }
    }
  }

  // MARK: - Tap / unpin

  private func handleTap(_ action: DomainTapAction) {
    guard case .openGoal(let id) = action,
          let entity = pinned.first(where: { $0.id == id }) else { return }
    editing = Goal(entity)
  }

  private func unpin(_ item: HomepageDomainData) {
    guard let id = goalID(from: item) else { return }
    goalMutator.setPinned(id: id, pinned: false)
    Haptics.tick()
  }

  private func goalID(from item: HomepageDomainData) -> String? {
    guard let raw = item.itemID, raw.hasPrefix("goal:") else { return nil }
    return String(raw.dropFirst("goal:".count))
  }

  // MARK: - Goal → tile view-model

  private func domainData(_ entity: GoalEntity) -> HomepageDomainData {
    let goal = Goal(entity)
    let sectionKey = goal.metricKey.flatMap { GoalMetricCatalog.sectionKey(for: $0) }
      ?? goal.sections.first
    let accent = sectionKey.map { theme.color(for: $0) } ?? .secondary
    let icon = sectionKey.map { theme.icon(for: $0) } ?? "target"
    // `domain` only ever feeds the id/icon fallbacks, both overridden below —
    // so a goal whose section has no dashboard domain still renders fine.
    let domain = sectionKey.flatMap(HomepageDomain.init(rawValue:)) ?? .habits

    let title = goal.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? goal.text

    var headline = title
    var stats: [DomainStat] = []
    var progress: DomainProgress? = nil
    if let p = GoalMetricEvaluator.evaluate(goal: goal, context: context) {
      let cur = trimmed(p.current)
      let tgt = trimmed(p.target)
      headline = "\(cur) / \(tgt) \(p.unitLabel)"
      stats = [DomainStat(label: windowLabel(goal.metricWindow), value: cur, unit: p.unitLabel)]
      progress = DomainProgress(label: "of \(tgt)", current: p.current, target: p.target,
                                unit: p.unitLabel)
    }

    return HomepageDomainData(
      domain: domain,
      itemID: "goal:\(goal.id)",
      iconSymbol: icon,
      title: title,
      accent: accent,
      headline: headline,
      headlineStats: stats,
      progress: progress,
      history: habitHistory(for: goal),
      tap: .openGoal(goal.id)
    )
  }

  /// A habit-backed goal contributes the underlying habit's daily completion
  /// (0/1 per day) so the shared heatmap renderer draws the streak. Other
  /// metrics return nil (the tile shows headline + progress only) — those
  /// series can come later without touching the renderer.
  private func habitHistory(for goal: Goal) -> HistorySeries? {
    guard let key = goal.metricKey,
          key.hasPrefix("habits."), key.hasSuffix(".done_week") else { return nil }
    let habitID = String(key.dropFirst("habits.".count).dropLast(".done_week".count))
    let done = Set(ChecklistMirror.habitCompletionDates(context: context, habitID: habitID))
    let cal = Calendar.current
    let series: [Int] = stride(from: Self.historyDays - 1, through: 0, by: -1).map { back in
      let day = cal.date(byAdding: .day, value: -back, to: Date()) ?? Date()
      return done.contains(Self.ymd.string(from: day)) ? 1 : 0
    }
    return .bars(series)
  }

  private func windowLabel(_ window: String?) -> String {
    window == "today" ? "Today" : "This week"
  }

  /// Whole numbers print without a decimal; fractional values to one place.
  private func trimmed(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
  }
}
