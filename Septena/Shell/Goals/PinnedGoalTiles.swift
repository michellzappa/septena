import SwiftUI
import SwiftData

// Pinned goal tiles on the Week dashboard — mapped to `HomepageDomainData` and
// prepended to the user's section tile order in `WeekDashboardView` (same grid,
// first placements). A goal is "pinned" (`GoalEntity.pinned`) from the Goals tab.

@MainActor
enum PinnedGoalTiles {
  /// Trailing window for a habit-backed goal's consistency series — 12 weeks,
  /// enough to read a streak in the heatmap without crowding the tile.
  private static let historyDays = 84
  private static let ymd: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  static func goalID(from item: HomepageDomainData) -> String? {
    guard let raw = item.itemID, raw.hasPrefix("goal:") else { return nil }
    return String(raw.dropFirst("goal:".count))
  }

  static func domainData(_ entity: GoalEntity,
                         theme: SectionTheme,
                         context: ModelContext,
                         today: String,
                         now: Date) -> HomepageDomainData {
    let goal = Goal(entity)
    let sectionKey = goal.metricKey.flatMap { GoalMetricCatalog.sectionKey(for: $0) }
      ?? goal.sections.first
    let accent = sectionKey.map { theme.color(for: $0) } ?? .secondary
    let icon = sectionKey.map { theme.icon(for: $0) } ?? "target"
    let domain = sectionKey.flatMap(HomepageDomain.init(rawValue:)) ?? .habits

    let title = goal.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? goal.text

    var headline = title
    var stats: [DomainStat] = []
    var progress: DomainProgress? = nil
    if let p = GoalMetricEvaluator.evaluate(goal: goal, context: context, now: now) {
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
      history: habitHistory(for: goal, context: context, today: today, now: now),
      tap: .openGoal(goal.id)
    )
  }

  private static func habitHistory(for goal: Goal, context: ModelContext,
                                   today: String, now: Date) -> HistorySeries? {
    guard let key = goal.metricKey,
          key.hasPrefix("habits."), key.hasSuffix(".done_week") else { return nil }
    let habitID = String(key.dropFirst("habits.".count).dropLast(".done_week".count))
    let done = Set(ChecklistMirror.habitCompletionDates(context: context, habitID: habitID))
    let cal = Calendar.current
    let anchor = SeptenaDate.startOfDay(for: today) ?? now
    let series: [Int] = stride(from: historyDays - 1, through: 0, by: -1).map { back in
      let day = cal.date(byAdding: .day, value: -back, to: anchor) ?? anchor
      return done.contains(ymd.string(from: day)) ? 1 : 0
    }
    return .bars(series)
  }

  private static func windowLabel(_ window: String?) -> String {
    window == "today" ? "Today" : "This week"
  }

  private static func trimmed(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
  }
}
