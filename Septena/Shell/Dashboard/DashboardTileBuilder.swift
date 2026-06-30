import Foundation
import SwiftData
import SwiftUI

struct DashboardTileDerived {
  var trainEffortSeries90: [Double] = []
  var weightActual30: [Double?] = []
  var githubCounts90: [Int] = []
  var githubStreak: Int = 0
}

struct DashboardTileContext {
  var modelContext: ModelContext
  var clockNow: Date
  var clockToday: String
  var dailies: NextItemsModel
  var habitHistory: [Int]
  var choreHistory: [Int]
  var cardio: CardioHistoryResponse?
  var trainingSessionDates: Set<String>
  var trainingSessionTypes: [SessionTypeConfig]
  var supplementHistory: [Int]
  var taskCounts: TasksCounts?
  var tasksHistory: TasksHistory?
  var ouraNights: [OuraNight]
  var nutritionStats: NutritionStatsResponse?
  var nutritionTrackFasting: Bool
  var nutritionHeatmapMetricRaw: String
  var todayProteinSum: Double
  var todayKcalSum: Double
  var nutritionTarget: MacrosConfig?
  var groceries: [GroceryItem]
  var bodyRows: [WithingsRow]
  var githubContributions: GitHubContributions
  var gutToday: GutDayResponse?
  var gutHistory: [GutHistoryPoint]
  var moodToday: MoodDayResponse?
  var moodHistory: [MoodHistoryPoint]
  var hydrationToday: Int
  var hydrationHistory: [Int]
  var hydrationTargetMl: Int
  var intakeTiles: [IntakeTileDTO]
  var recentTraining: [ExerciseEntry]
  var derived: DashboardTileDerived

  var weeklySessionCount: Int {
    let cutoff = sinceDate(daysBack: 7)
    return trainingSessionDates.filter { $0 >= cutoff }.count
  }

  func sinceDate(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: clockNow) ?? clockNow
    return DashboardTileBuilder.ymdFormatter.string(from: d)
  }
}

@MainActor
enum DashboardTileBuilder {
  static let historyDays = 90
  static let ymdFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
  }()

  static func domainData(for domain: HomepageDomain, ctx: DashboardTileContext, theme: SectionTheme) -> HomepageDomainData? {
    Instance(ctx: ctx, theme: theme).domainData(for: domain)
  }

  static func intakeKindDomainData(_ t: IntakeTileDTO, ctx: DashboardTileContext, theme: SectionTheme) -> HomepageDomainData {
    Instance(ctx: ctx, theme: theme).intakeKindDomainData(t)
  }

  static func visibleItems(for domain: HomepageDomain, ctx: DashboardTileContext, theme: SectionTheme) -> [HomepageDomainData] {
    if domain == .intake, !ctx.intakeTiles.isEmpty {
      return ctx.intakeTiles.map { intakeKindDomainData($0, ctx: ctx, theme: theme) }
    }
    return domainData(for: domain, ctx: ctx, theme: theme).map { [$0] } ?? []
  }

  static func buildCatalog(ctx: DashboardTileContext, theme: SectionTheme, visibleDomains: [HomepageDomain]) -> TileWidgetCatalog {
    let now = ctx.clockNow
    var sections: [TileSectionOption] = []
    var tiles: [String: TileWidgetWire] = [:]
    for domain in visibleDomains {
      for item in visibleItems(for: domain, ctx: ctx, theme: theme) {
        let hex = accentHex(for: item, ctx: ctx, theme: theme)
        let display = item.tileDisplay(accentHex: hex)
        sections.append(.init(itemID: item.id, title: item.title, iconSymbol: item.icon))
        tiles[item.id] = TileWidgetWire(from: display, updatedAt: now)
      }
    }
    return TileWidgetCatalog(sections: sections, tiles: tiles)
  }

  static func buildMacroSnapshot(ctx: DashboardTileContext, theme: SectionTheme) -> MacroWidgetWire? {
    MacroWidgetBuilder.buildSnapshot(context: ctx.modelContext, date: ctx.clockToday)
  }

  static func accentHex(for item: HomepageDomainData, ctx: DashboardTileContext, theme: SectionTheme) -> String {
    if let hex = item.accentHex { return hex }
    if let itemID = item.itemID, itemID.hasPrefix("intake:") {
      let kindID = String(itemID.dropFirst("intake:".count))
      if let tile = ctx.intakeTiles.first(where: { $0.id == kindID }) { return tile.color }
    }
    return theme.token(for: item.domain.rawValue)
  }

  static func computeDerived(
      recentTraining: [ExerciseEntry],
      sessionTypes: [SessionTypeConfig],
      github: GitHubContributions,
      bodyRows: [WithingsRow],
      now: Date
    ) -> DashboardTileDerived {
      var d = DashboardTileDerived()
      let cal = Calendar.current
      let fmt = DashboardTileBuilder.ymdFormatter
      func dayKeys(_ n: Int) -> [String] {
        (0..<n).reversed().compactMap {
          cal.date(byAdding: .day, value: -$0, to: now).map(fmt.string(from:))
        }
      }
      let d90 = dayKeys(90)

      // Training effort → one combined 90-day daily-effort series. Every
      // modality is already converted to comparable effort-minutes
      // (`effortContribution`), so summing strength-like (which folds in
      // mobility/yoga) + cardio gives an honest "total time invested per
      // day" — the series the Dense tile draws as raw spikes + a 7-day
      // trend.
      let effort = effortByDate(recentTraining, sessionTypes: sessionTypes)
      d.trainEffortSeries90 = d90.map { (effort.strengthLike[$0] ?? 0) + (effort.cardio[$0] ?? 0) }

      // GitHub daily counts (90d) + current streak (consecutive days back).
      let gByDate = Dictionary(github.days.map { ($0.date, $0.count) },
                               uniquingKeysWith: { a, _ in a })
      d.githubCounts90 = d90.map { gByDate[$0] ?? 0 }
      var streak = 0
      for day in dayKeys(366).reversed() {
        if (gByDate[day] ?? 0) > 0 { streak += 1 } else { break }
      }
      d.githubStreak = streak

      // Body — actual weigh-ins for the last 30 days (nil on gap days).
      var wByDate: [String: Double] = [:]
      for r in bodyRows { if let w = r.weightKg { wByDate[r.date] = w } }
      let startToday = cal.startOfDay(for: now)
      d.weightActual30 = (0..<30).reversed().map { off -> Double? in
        guard let dd = cal.date(byAdding: .day, value: -off, to: startToday) else { return nil }
        return wByDate[fmt.string(from: dd)]
      }
      return d
    }

  static func effortContribution(for e: ExerciseEntry,
                                           sessionTypes: [SessionTypeConfig])
      -> (kind: SessionKind, minutes: Double)
    {
      // Resolve modality: prefer the routine's configured kind, fall back
      // to the seed mapping, then refine an ambiguous `.mixed` from fields.
      var kind = sessionTypes
        .first { $0.id.caseInsensitiveCompare(e.session) == .orderedSame }?.kind
        ?? SessionKind.defaulted(for: e.session)
      // Yoga/mobility can hide inside a mixed or mislabeled routine — catch
      // it by exercise name so it never lands in the cardio bucket.
      if let ex = e.exercise?.lowercased(),
         ex.contains("yoga") || ex.contains("stretch") || ex.contains("mobility") {
        kind = .mobility
      }
      if kind == .mixed {
        let looksCardio = (e.distanceM ?? 0) > 0
          || ((e.durationMin ?? 0) > 0 && e.weight == nil)
        kind = looksCardio ? .cardio : .strength
      }

      let dur = e.durationMin ?? 0
      switch kind {
      case .cardio:
        if dur > 0 { return (.cardio, dur) }
        // Distance-only run/ride: estimate ~6 min/km so it still counts.
        if let m = e.distanceM, m > 0 { return (.cardio, m / 1000.0 * 6.0) }
        return (.cardio, 0)
      case .mobility:
        // Yoga is time-based; counts as effort, never as cardio/Z2.
        return (.mobility, dur)
      case .strength, .mixed:
        if dur > 0 { return (.strength, dur) }
        // No clock on a lift → estimate from set count (~3.5 min/set incl.
        // rest). Reps/weight don't change wall-clock effort.
        if let s = e.sets.flatMap(Int.init), s > 0 {
          return (.strength, Double(s) * 3.5)
        }
        return (.strength, 0)
      }
    }

  static func effortByDate(_ entries: [ExerciseEntry],
                                     sessionTypes: [SessionTypeConfig])
      -> (strengthLike: [String: Double], cardio: [String: Double])
    {
      var strengthLike: [String: Double] = [:]
      var cardio: [String: Double] = [:]
      for e in entries {
        let c = effortContribution(for: e, sessionTypes: sessionTypes)
        guard c.minutes > 0 else { continue }
        if c.kind == .cardio {
          cardio[e.date, default: 0] += c.minutes
        } else {
          strengthLike[e.date, default: 0] += c.minutes
        }
      }
      return (strengthLike, cardio)
    }

  static func avgBristol(_ entries: [GutEntry]) -> Double? {
      guard !entries.isEmpty else { return nil }
      return Double(entries.reduce(0) { $0 + $1.bristol }) / Double(entries.count)
    }


  @MainActor
  private struct Instance {
    let ctx: DashboardTileContext
    let theme: SectionTheme

    func domainData(for domain: HomepageDomain) -> HomepageDomainData? {
      switch domain {
      case .tasks: return tasksDomainData()
      case .habits: return habitsDomainData()
      case .training: return trainingDomainData()
      case .chores: return choresDomainData()
      case .supplements: return supplementsDomainData()
      case .sleep: return sleepDomainData()
      case .nutrition: return nutritionDomainData()
      case .hydration: return hydrationDomainData()
      case .groceries: return groceriesDomainData()
      case .intake: return intakeDomainData()
      case .body: return bodyDomainData()
      case .gut: return gutDomainData()
      case .mood: return moodDomainData()
      case .symptoms: return symptomsDomainData()
      case .medications: return medicationsDomainData()
      case .activity: return activityDomainData()
      case .github: return githubDomainData()
      }
    }

      func intakeKindDomainData(_ t: IntakeTileDTO) -> HomepageDomainData {
        let accent = AdaptiveColor.adaptive(t.color) ?? theme.color(for: "intake")
        var stats: [DomainStat] = [.init(label: "Today", value: "\(t.todayCount)")]
        if IntakeObjective.emphasizesStreak(t.objective),
           let days = intakeDaysSince(t.lastEventAt), days >= 1 {
          stats.append(.init(label: IntakeObjective.streakLabel(t.objective), value: "\(days)d"))
        }
        return HomepageDomainData(
          domain: .intake,
          itemID: "intake:\(t.id)",
          iconSymbol: t.symbol,
          title: t.name,
          accent: accent,
          // Per-kind color must survive every accentHex-driven path (Heatmap
          // single-column rows, widget wire). Without it those fall back to the
          // generic "intake" section token, collapsing all trackers to one color.
          accentHex: t.color,
          headline: "\(t.todayCount) today",
          headlineStats: stats,
          progress: nil,
          history: .bars(t.dailyCounts),
          tap: .openIntakeKind(t.id)
        )
      }
      func tasksDomainData() -> HomepageDomainData {
        let openToday = ctx.taskCounts.map { $0.todayCount + $0.reviewCount } ?? 0
        let toSort = ctx.taskCounts?.triageCount ?? 0
        let upcoming = ctx.taskCounts?.upcomingCount ?? 0
        let doneToday = ctx.tasksHistory?.daily.last?.done ?? 0
        let totalToday = doneToday + openToday
        let bars = ctx.tasksHistory?.daily.map(\.done) ?? []
        return HomepageDomainData(
          domain: .tasks,
          title: String(localized: "Tasks", comment: "Section name"),
          accent: theme.color(for: "tasks"),
          headline: "\(openToday) open · \(doneToday)/\(totalToday) done",
          headlineStats: [
            .init(label: "Today", value: "\(openToday)"),
            .init(label: "Inbox", value: "\(toSort)"),
            .init(label: "Upcoming", value: "\(upcoming)"),
          ],
          progress: .init(label: "Done today",
                          current: Double(doneToday),
                          target: Double(max(totalToday, 1))),
          history: .bars(bars),
          tap: .switchToTasksTab
        )
      }

      func habitsDomainData() -> HomepageDomainData {
        let total = ctx.dailies.habits.count
        let done = ctx.dailies.habits.filter { $0.done }.count
        let skipped = ctx.dailies.habits.filter { $0.skipped }.count
        return HomepageDomainData(
          domain: .habits,
          title: String(localized: "Habits", comment: "Section name"),
          accent: theme.color(for: "habits"),
          headline: skipped > 0
            ? "\(done)/\(total) · \(skipped) skipped"
            : "\(done)/\(total)",
          headlineStats: [
            .init(label: "Done", value: "\(done)"),
            .init(label: "Skipped", value: "\(skipped)"),
            .init(label: "Total", value: "\(total)"),
          ],
          progress: .init(label: "Today",
                          current: Double(done),
                          target: Double(max(total, 1))),
          history: .bars(ctx.habitHistory),
          tap: .openSheet(.habits)
        )
      }

      // MARK: Unified training "effort"
      //
      // Strength volume (weight×sets×reps, in the thousands) and cardio
      // minutes (tens) can't share an axis — cardio gets crushed to an
      // invisible sliver, so a real 25-min session looks like nothing
      // happened. Fix: convert every modality to one comparable unit —
      // **effort-minutes** — so any session visibly moves the needle.
      // Yoga/mobility is classified on its own so it counts as effort but
      // never inflates the cardio (Z2) totals.

      /// Classify one entry's modality and its effort-minute contribution.
      /// Static + `sessionTypes` passed in so it runs inside `computeDerived`
      /// off the render path.


      /// Daily effort-minutes split into the two series the training
      /// visualization already uses: `cardio` keeps its own band, while
      /// `strengthLike` folds strength + mobility/yoga together (yoga counts
      /// as effort but never as cardio). Keyed by ISO date.


      // MARK: - Derived tile cache
      //
      // The three data-heavy tiles (Training, Body, GitHub) used to reshape
      // their series *inside* the view body — iterating every training entry,
      // every weigh-in, and building a 366-day date array on each render. That
      // ran for every visible tile on every redraw (taps, logs, scroll), which
      // is what made the homepage janky. Compute it ONCE whenever the underlying
      // data changes (`recomputeDerived`); the tiles just read the cached result.




      /// Recompute the ctx.derived tile cache from current state — cheap relative to
      /// reshaping per-render. Called whenever Training / Body / GitHub inputs land.
      @MainActor
      func trainingDomainData() -> HomepageDomainData {
        // Sessions + Z2 minutes are always **trailing 7 days** so they read
        // sensibly against the weekly target (`targetWeeklyMin`, default
        // 150). The training data window is 90 days for the heatmap strip,
        // but the headline / progress are weekly stats — independent of the
        // history-series window.
        let sessionCount = ctx.weeklySessionCount
        let minutes = Int(ctx.cardio?.daily.last?.rolling7d ?? 0)
        let target = ctx.cardio?.targetWeeklyMin ?? 150
        // One combined 90-day effort-minutes series (all modalities), from the
        // precomputed cache. Drawn as `.dailyTrend`: the raw per-day exercise
        // (the filled body) plus its trailing-7d mean (the line through it) —
        // both from this single series, in one chart. The headline carries the
        // literal this-week numbers (sessions + Z2 minutes).
        let effortSeries = ctx.derived.trainEffortSeries90
        return HomepageDomainData(
          domain: .training,
          title: String(localized: "Training", comment: "Section name"),
          accent: theme.color(for: "training"),
          headline: "\(sessionCount) sessions · \(minutes)/\(target) min",
          headlineStats: [
            .init(label: "Sessions", value: "\(sessionCount)"),
            .init(label: "Z2", value: "\(minutes)", unit: "min"),
          ],
          progress: .init(label: "Weekly Z2",
                          current: Double(minutes),
                          target: Double(max(target, 1)),
                          unit: "min"),
          history: .dailyTrend(daily: effortSeries),
          tap: .openSheet(.training),
          // `.dailyTrend` draws the raw daily fill + its own 7-day mean line,
          // so the generic `smoothSparkline` flag (which smooths a `.bars`
          // series) doesn't apply here.
          smoothSparkline: false
        )
      }

      func choresDomainData() -> HomepageDomainData {
        let todayISO = ctx.clockToday
        let serverDoneIDs = Set(ctx.dailies.chores
                                  .filter { $0.lastCompleted == todayISO }
                                  .map(\.id))
        let doneIDs = serverDoneIDs.union(ctx.dailies.completedChores)
        let dueToday = ctx.dailies.chores.filter {
          $0.daysOverdue == 0 && !doneIDs.contains($0.id)
        }.count
        let overdue = ctx.dailies.chores.filter {
          $0.daysOverdue > 0 && !doneIDs.contains($0.id)
        }.count
        let done = doneIDs.count
        let total = dueToday + overdue + done
        return HomepageDomainData(
          domain: .chores,
          title: String(localized: "Chores", comment: "Section name"),
          accent: theme.color(for: "chores"),
          headline: overdue > 0
            ? "\(done)/\(total) · \(overdue) overdue"
            : "\(done)/\(total)",
          headlineStats: [
            .init(label: "Due", value: "\(dueToday)"),
            .init(label: "Overdue", value: "\(overdue)"),
            .init(label: "Done", value: "\(done)"),
          ],
          progress: .init(label: "Today",
                          current: Double(done),
                          target: Double(max(total, 1))),
          history: .bars(ctx.choreHistory),
          tap: .openSheet(.chores)
        )
      }

      func supplementsDomainData() -> HomepageDomainData {
        let total = ctx.dailies.supplements.count
        let done = ctx.dailies.supplements.filter { $0.done }.count
        return HomepageDomainData(
          domain: .supplements,
          title: String(localized: "Supplements", comment: "Section name"),
          accent: theme.color(for: "supplements"),
          headline: "\(done)/\(total)",
          headlineStats: [
            .init(label: "Done", value: "\(done)"),
            .init(label: "Total", value: "\(total)"),
          ],
          progress: .init(label: "Today",
                          current: Double(done),
                          target: Double(max(total, 1))),
          history: .bars(ctx.supplementHistory),
          tap: .openSheet(.supplements)
        )
      }

      func sleepDomainData() -> HomepageDomainData {
        let last = ctx.ouraNights.first
        let lastH = last?.totalH ?? 0
        let score = last?.sleepScore.map { "\($0)" } ?? "—"
        // Oura only records completed nights, so the array ends at yesterday.
        // Append a 0 for today (no sleep recorded yet) so buildLevelMap anchors
        // bars[0] to today-90 instead of today-89, giving the week-rounded first
        // column's Monday cell an actual data entry rather than a phantom gap.
        let bars = ctx.ouraNights.reversed().map { $0.sleepScore ?? 0 } + [0]
        return HomepageDomainData(
          domain: .sleep,
          title: String(localized: "Sleep", comment: "Section name"),
          accent: theme.color(for: "sleep"),
          headline: lastH > 0
            ? "\(formatHoursShort(lastH)) · score \(score)"
            : "—",
          headlineStats: [
            .init(label: "Hours", value: formatHoursShort(lastH)),
            .init(label: "Score", value: score),
          ],
          progress: nil,
          history: .bars(bars),
          tap: .openSheet(.sleep),
          trailingTodayPending: true,
          autoscaleSparkline: true
        )
      }

      func nutritionDomainData() -> HomepageDomainData {
        let accent = theme.color(for: "nutrition")
        let state = currentFastingState(now: ctx.clockNow)
        let metric = NutritionHeatmapMetric(rawValue: ctx.nutritionHeatmapMetricRaw) ?? .protein

        // History series: the heatmap metric preference picks which series
        // every mode renders. Only honor the "fasting" pick when the master
        // toggle is on, otherwise the picker preference is dormant.
        let history: HistorySeries = {
          if ctx.nutritionTrackFasting, metric == .fasting {
            let windows = ctx.nutritionStats?.fasting ?? []
            let hours = windows.map { Int(($0.hours ?? 0).rounded()) }
            return .bars(hours.isEmpty ? Array(repeating: 0, count: 90) : hours)
          }
          let bars = ctx.nutritionStats?.daily.map { Int($0.proteinG) }
                    ?? Array(repeating: 0, count: 90)
          return .bars(bars)
        }()

        if ctx.nutritionTrackFasting, case .fasting(_, let since, let totalMin) = state {
          let targetMin = ctx.nutritionTarget?.fasting?.min ?? FastingDefaults.targetMinH
          let h = totalMin / 60, m = totalMin % 60
          return HomepageDomainData(
            domain: .nutrition,
            title: String(localized: "Nutrition", comment: "Section name"),
            accent: accent,
            headline: "\(h)h \(m)m fasting · since \(since)",
            headlineStats: [
              .init(label: "Fasting", value: "\(h)h \(m)m"),
              .init(label: "Since", value: since),
            ],
            progress: .init(label: "Fast vs target",
                            current: min(Double(totalMin) / 60, targetMin),
                            target: max(targetMin, 1),
                            unit: "h"),
            history: history,
            tap: .openSheet(.nutrition)
          )
        }

        let proteinTarget = ctx.nutritionTarget?.protein.min ?? 150
        return HomepageDomainData(
          domain: .nutrition,
          title: String(localized: "Nutrition", comment: "Section name"),
          accent: accent,
          headline: "\(Int(ctx.todayProteinSum))g protein · \(Int(ctx.todayKcalSum)) kcal",
          headlineStats: [
            .init(label: "Protein", value: "\(Int(ctx.todayProteinSum))", unit: "g"),
            .init(label: "Kcal", value: "\(Int(ctx.todayKcalSum))"),
          ],
          progress: .init(label: "Today's protein",
                          current: ctx.todayProteinSum,
                          target: max(proteinTarget, 1),
                          unit: "g"),
          history: history,
          tap: .openSheet(.nutrition)
        )
      }

      func groceriesDomainData() -> HomepageDomainData {
        let lowCount = ctx.groceries.filter { $0.low }.count
        let stocked = ctx.groceries.count - lowCount
        let missingPerDay = groceriesMissingPerDay()
        return HomepageDomainData(
          domain: .groceries,
          title: String(localized: "Groceries", comment: "Section name"),
          accent: theme.color(for: "groceries"),
          headline: lowCount > 0
            ? "\(lowCount) low · \(stocked) stocked"
            : "\(stocked) stocked",
          headlineStats: [
            .init(label: "Low", value: "\(lowCount)"),
            .init(label: "Stocked", value: "\(stocked)"),
            .init(label: "Items", value: "\(ctx.groceries.count)"),
          ],
          progress: ctx.groceries.isEmpty ? nil : DomainProgress(
            label: "Stocked",
            current: Double(stocked),
            target: Double(ctx.groceries.count)
          ),
          history: .bars(missingPerDay),
          tap: .openSheet(.groceries)
        )
      }

      func bodyDomainData() -> HomepageDomainData {
        let latest = ctx.bodyRows.first
        let weight = latest?.weightKg
        let fat = latest?.fatPct
        let actualSeries = ctx.derived.weightActual30
        let present = actualSeries.compactMap { $0 }
        let avg = present.isEmpty ? 0.0 : present.reduce(0, +) / Double(present.count)
        let centeredValues: [Double?] = actualSeries.map { $0.map { $0 - avg } }
        let fatTarget: Double = 18
        return HomepageDomainData(
          domain: .body,
          title: String(localized: "Body", comment: "Section name"),
          accent: theme.color(for: "body"),
          headline: {
            let parts = [
              weight.map { String(format: "%.1f \(WeightUnit.current.suffix)", WeightUnit.current.display($0)) },
              fat.map { String(format: "%.1f%%", $0) },
            ].compactMap { $0 }
            return parts.isEmpty ? "—" : parts.joined(separator: " · ")
          }(),
          headlineStats: [
            .init(label: "Weight",
                  value: weight.map { String(format: "%.1f", WeightUnit.current.display($0)) } ?? "—",
                  unit: WeightUnit.current.suffix),
            .init(label: "Fat",
                  value: fat.map { String(format: "%.1f", $0) } ?? "—",
                  unit: "%"),
          ],
          progress: .init(label: "Body fat target",
                          current: fat.map { min($0, fatTarget * 2) } ?? 0,
                          target: fatTarget,
                          unit: "%"),
          history: .centered(values: centeredValues, baseline: avg),
          tap: .openSheet(.body)
        )
      }

      // MARK: - GitHub
      //
      // Read-only contribution tile. `ctx.githubContributions` is the per-device
      // GraphQL fetch (Keychain token, no CloudKit); the tile shows daily
      // commit counts and the destination view owns the year heatmap. When the
      // user hasn't connected GitHub the series is all-zero and the tile reads
      // "0 this week" — same honest empty state as Sleep without Oura.

      // GitHub daily counts + streak are precomputed in `computeDerived`
      // (off the render path) and read via `ctx.derived.githubCounts90` /
      // `ctx.derived.githubStreak`.

      func githubDomainData() -> HomepageDomainData {
        let counts = ctx.derived.githubCounts90
        let today = counts.last ?? 0
        let week = counts.suffix(7).reduce(0, +)
        let streak = ctx.derived.githubStreak
        return HomepageDomainData(
          domain: .github,
          title: String(localized: "GitHub", comment: "Section name"),
          accent: theme.color(for: "github"),
          headline: today > 0 ? "\(today) today · \(week) this week" : "\(week) this week",
          headlineStats: [
            .init(label: "Today", value: "\(today)"),
            .init(label: "Streak", value: "\(streak)", unit: "d"),
            .init(label: "Year", value: "\(ctx.githubContributions.total)"),
          ],
          progress: nil,
          history: .bars(counts),
          tap: .openSheet(.github)
        )
      }

      func gutDomainData() -> HomepageDomainData {
        let count = ctx.gutToday?.movementCount ?? 0
        let avgBristol = DashboardTileBuilder.avgBristol(ctx.gutToday?.entries ?? [])
        let bars = ctx.gutHistory.map { $0.movements }
        let dailyTarget = 2
        return HomepageDomainData(
          domain: .gut,
          title: String(localized: "Gut", comment: "Section name"),
          accent: theme.color(for: "gut"),
          headline: "\(count)",
          headlineStats: [
            .init(label: "Today", value: "\(count)"),
            .init(label: "Avg Bristol",
                  value: avgBristol.map { String(format: "%.1f", $0) } ?? "—"),
          ],
          progress: .init(label: "Today / typical",
                          current: Double(min(count, dailyTarget)),
                          target: Double(dailyTarget)),
          history: .bars(bars.isEmpty ? Array(repeating: 0, count: 90) : bars),
          tap: .openSheet(.gut)
        )
      }
      func symptomsDomainData() -> HomepageDomainData {
        let today = ctx.clockToday
        let rows = fetchSymptoms(from: lastNDays(DashboardTileBuilder.historyDays).first ?? today, to: today)
        let todayRows = rows.filter { $0.date == today }
        let peak = todayRows.map(\.severity).max() ?? 0
        let avg = todayRows.isEmpty
          ? 0
          : Double(todayRows.reduce(0) { $0 + $1.severity }) / Double(todayRows.count)
        let history = symptomsHistory(days: DashboardTileBuilder.historyDays)
        return HomepageDomainData(
          domain: .symptoms,
          title: String(localized: "Symptoms", comment: "Section name"),
          accent: theme.color(for: "symptoms"),
          headline: "\(todayRows.count) · peak \(peak)",
          headlineStats: [
            .init(label: "Today", value: "\(todayRows.count)"),
            .init(label: "Peak", value: "\(peak)", unit: "/10"),
            .init(label: "Average", value: avg.decimalString(1), unit: "/10"),
          ],
          progress: .init(label: "Peak severity", current: Double(peak), target: 10, unit: "/10"),
          history: .bars(history),
          tap: .openSheet(.symptoms)
        )
      }

      func symptomsHistory(days: Int) -> [Int] {
        let dates = lastNDays(days)
        guard let start = dates.first, let end = dates.last else { return [] }
        let rows = fetchSymptoms(from: start, to: end)
        let grouped = Dictionary(grouping: rows, by: \.date)
        return dates.map { grouped[$0]?.map(\.severity).max() ?? 0 }
      }

      func fetchSymptoms(from start: String, to end: String) -> [SymptomEventEntity] {
        let descriptor = FetchDescriptor<SymptomEventEntity>(
          predicate: #Predicate { $0.date >= start && $0.date <= end }
        )
        return (try? ctx.modelContext.fetch(descriptor)) ?? []
      }

      func medicationsDomainData() -> HomepageDomainData {
        let today = ctx.clockToday
        let active = fetchMedicationDefinitions().filter { !$0.archived }
        let rows = fetchMedicationDoses(from: lastNDays(DashboardTileBuilder.historyDays).first ?? today, to: today)
        let todayRows = rows.filter { $0.date == today }
        let taken = todayRows.filter { $0.status == "taken" }.count
        let skipped = todayRows.filter { $0.status == "skipped" || $0.status == "missed" }.count
        let routine = active.filter { ($0.scheduleKind ?? "daily") == "daily" }
        let target = max(routine.count, 1)
        return HomepageDomainData(
          domain: .medications,
          title: String(localized: "Medications", comment: "Section name"),
          accent: theme.color(for: "medications"),
          headline: routine.isEmpty ? "\(taken) taken" : "\(taken)/\(routine.count) taken",
          headlineStats: [
            .init(label: "Taken", value: "\(taken)"),
            .init(label: "Skipped", value: "\(skipped)"),
            .init(label: "Active", value: "\(active.count)"),
          ],
          progress: routine.isEmpty ? nil : .init(label: "Taken today", current: Double(min(taken, target)), target: Double(target)),
          history: .bars(medicationsHistory(days: DashboardTileBuilder.historyDays)),
          tap: .openSheet(.medications)
        )
      }

      func medicationsHistory(days: Int) -> [Int] {
        let dates = lastNDays(days)
        guard let start = dates.first, let end = dates.last else { return [] }
        let rows = fetchMedicationDoses(from: start, to: end).filter { $0.status == "taken" }
        let grouped = Dictionary(grouping: rows, by: \.date)
        return dates.map { grouped[$0]?.count ?? 0 }
      }

      func fetchMedicationDefinitions() -> [MedicationDefinitionEntity] {
        (try? ctx.modelContext.fetch(FetchDescriptor<MedicationDefinitionEntity>())) ?? []
      }

      func fetchMedicationDoses(from start: String, to end: String) -> [MedicationDoseEventEntity] {
        let descriptor = FetchDescriptor<MedicationDoseEventEntity>(
          predicate: #Predicate { $0.date >= start && $0.date <= end }
        )
        return (try? ctx.modelContext.fetch(descriptor)) ?? []
      }

      func activityDomainData() -> HomepageDomainData? {
        guard let snap = activitySnapshot() else { return nil }
        let stepsTarget = 8000
        return HomepageDomainData(
          domain: .activity,
          title: String(localized: "Activity", comment: "Section name"),
          accent: theme.color(for: "activity"),
          headline: "\(snap.steps) steps · \(snap.exMin) min",
          headlineStats: [
            .init(label: "Steps", value: "\(snap.steps)"),
            .init(label: "Active",
                  value: "\(Int(snap.kcal))",
                  unit: "kcal"),
            .init(label: "Exercise",
                  value: "\(snap.exMin)",
                  unit: "m"),
          ],
          progress: .init(label: "Steps target",
                          current: Double(min(snap.steps, stepsTarget)),
                          target: Double(stepsTarget)),
          // The heatmap / dense layouts render the full window, so feed the
          // 90-day step series from the synced entity — NOT `snap.bars`, which is
          // only the trailing 7 days the tile histogram needs. (This is why the
          // drawer showed full history but the heatmap looked near-empty.)
          history: .bars(activityStepBars(days: DashboardTileBuilder.historyDays)),
          tap: .openSheet(.activity)
        )
      }

      /// Steps per day for the trailing `days`, oldest → newest, gap-filled with
      /// 0, drawn from the persisted `ActivityDayEntity` rows. Feeds the homepage
      /// heatmap/dense modes (90-day window) the same way other sections do.
      func activityStepBars(days: Int) -> [Int] {
        let keys = lastNDays(days)
        let rows = fetchActivityDays(from: keys.first ?? "", to: keys.last ?? "")
        let byDate = Dictionary(rows.map { ($0.date, $0.stepCount ?? 0) },
                                uniquingKeysWith: { a, _ in a })
        return keys.map { byDate[$0] ?? 0 }
      }

      /// Today's numbers + trailing-7-day step bars for the Activity surfaces.
      /// Prefers the live HealthKit snapshot on iOS; falls back to the synced
      /// `ActivityDayEntity` rows so macOS (no HealthKit) and a cold cache still
      /// render. Returns nil only when there's genuinely nothing to show.
      struct ActivitySnapshot {
        let steps: Int
        let kcal: Double
        let exMin: Int
        let bars: [Int]   // trailing 7 days, oldest → newest
      }

      func activitySnapshot() -> ActivitySnapshot? {
        let bridge = HealthKitBridge.shared
        let dates = lastNDays(7)
        let rows = fetchActivityDays(from: dates.first ?? "", to: dates.last ?? "")
        guard bridge.isAvailable || !rows.isEmpty else { return nil }
        let byDate = Dictionary(rows.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let today = dates.last ?? ctx.clockToday
        let todayRow = byDate[today]
        let steps = bridge.isAvailable ? bridge.stepsToday           : (todayRow?.stepCount ?? 0)
        let kcal  = bridge.isAvailable ? bridge.activeKcalToday      : (todayRow?.activeKcal ?? 0)
        let exMin = bridge.isAvailable ? bridge.exerciseMinutesToday : (todayRow?.exerciseMinutes ?? 0)
        let bars  = bridge.isAvailable ? Array(bridge.stepsHistory.suffix(7))
                                       : dates.map { byDate[$0]?.stepCount ?? 0 }
        return ActivitySnapshot(steps: steps, kcal: kcal, exMin: exMin, bars: bars)
      }

      func fetchActivityDays(from start: String, to end: String) -> [ActivityDayEntity] {
        let descriptor = FetchDescriptor<ActivityDayEntity>(
          predicate: #Predicate { $0.date >= start && $0.date <= end }
        )
        return (try? ctx.modelContext.fetch(descriptor)) ?? []
      }

      func lastNDays(_ n: Int) -> [String] {
        let cal = Calendar.current
        let fmt = DashboardTileBuilder.ymdFormatter
        let anchor = SeptenaDate.startOfDay(for: ctx.clockToday) ?? ctx.clockNow
        return (0..<n).reversed().compactMap { offset in
          cal.date(byAdding: .day, value: -offset, to: anchor).map(fmt.string(from:))
        }
      }

      /// Chores already toggled this session — hidden from both menus so we
      func groceriesMissingPerDay() -> [Int] {
        let missingToday = ctx.groceries.filter { $0.low }.count
        GroceryStockHistory.record(missing: missingToday)
        return GroceryStockHistory.series(days: 30)
      }

      // MARK: - Intake (consumables) tiles
      //
      func intakeDaysSince(_ date: Date?) -> Int? {
        guard let date else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day],
                                  from: cal.startOfDay(for: date),
                                  to: cal.startOfDay(for: ctx.clockNow)).day
      }

      /// Aggregate row for the non-Tiles layout modes (Dense / Heatmap / Rings /
      func intakeDomainData() -> HomepageDomainData {
        let totalToday = ctx.intakeTiles.reduce(0) { $0 + $1.todayCount }
        return HomepageDomainData(
          domain: .intake,
          title: SectionManifest.byKey["intake"]?.defaultLabel ?? "Intake",
          accent: theme.color(for: "intake"),
          headline: "\(ctx.intakeTiles.count) trackers · \(totalToday) today",
          headlineStats: [
            .init(label: "Trackers", value: "\(ctx.intakeTiles.count)"),
            .init(label: "Today", value: "\(totalToday)"),
          ],
          progress: nil,
          history: nil,
          tap: .openSheet(.intake)
        )
      }

      func formatHoursShort(_ h: Double) -> String {
        let total = Int((h * 60).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
      }

      /// Live fasting state ctx.derived from `ctx.nutritionStats`. Returns `.fed`
      /// when tracking is off or the stats payload isn't loaded yet, so
      /// callers can branch with a single switch.
      func currentFastingState(now: Date) -> FastingState {
        guard let stats = ctx.nutritionStats else { return .fed }
        let inputs = FastingStateInputs(
          todayLatestMeal: stats.todayLatestMeal,
          todayMealCount: stats.todayMealCount ?? 0,
          yesterdayLastMeal: stats.yesterdayLastMeal
        )
        return computeFastingState(inputs: inputs, now: now)
      }
      func moodDomainData() -> HomepageDomainData {
        let today = ctx.moodToday?.logCount ?? 0
        let bars = ctx.moodHistory.map { $0.logs }
        return HomepageDomainData(
          domain: .mood,
          title: String(localized: "Mood", comment: "Section name"),
          accent: theme.color(for: "mood"),
          headline: "\(today) of 3 today",
          headlineStats: [
            .init(label: "Today",  value: "\(today)"),
            .init(label: "Target", value: "3"),
          ],
          progress: .init(label: "Today / target",
                          current: Double(min(today, 3)),
                          target: 3),
          history: .bars(bars.isEmpty ? Array(repeating: 0, count: 90) : bars),
          tap: .openSheet(.mood)
        )
      }

    func hydrationDomainData() -> HomepageDomainData {
        HomepageDomainData(
          domain: .hydration,
          title: String(localized: "Hydration", comment: "Section name"),
          accent: theme.color(for: "hydration"),
          headline: "\(ctx.hydrationToday) of \(ctx.hydrationTargetMl) ml",
          headlineStats: [
            .init(label: "Today",  value: "\(ctx.hydrationToday)", unit: "ml"),
            .init(label: "Target", value: "\(ctx.hydrationTargetMl)", unit: "ml"),
          ],
          progress: .init(label: "Today / target",
                          current: Double(min(ctx.hydrationToday, ctx.hydrationTargetMl)),
                          target: Double(max(ctx.hydrationTargetMl, 1)),
                          unit: "ml"),
          history: .bars(ctx.hydrationHistory.isEmpty
                           ? Array(repeating: 0, count: 90) : ctx.hydrationHistory),
          tap: .openSheet(.hydration)
        )
      }
  }
}
