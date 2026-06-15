import Foundation
import SwiftData

// MARK: - ReportPayloadBuilder
//
// Computes an aggregates-only `ReportPayload` from the local SwiftData mirror.
// Designed to run off-main on `MirrorReader` — it takes a `ModelContext` and
// returns a `Sendable` payload. It only reads the on-device mirror (no network,
// no `@MainActor` stores): section display metadata is resolved on-main by the
// caller and passed in as `meta`.
//
// Sections without a local aggregate source yet (sleep, body, github,
// symptoms, medications, goals, …) are emitted as `unavailable` so the report
// honestly reflects what was selected. See docs/PRACTITIONER_REPORTS_SPEC.md.

public enum ReportPayloadBuilder {

  /// Section keys this prototype can compute live aggregates for.
  public static let supportedKeys: Set<String> = [
    "habits", "supplements", "chores", "gut",
    "training", "nutrition", "mood", "activity",
  ]

  public static func build(bundle: ReportBundle,
                           meta: [String: ReportSectionMeta],
                           owner: String,
                           context: ModelContext) -> ReportPayload {
    let days = max(1, bundle.windowDays)
    let sections: [ReportSection] = bundle.sectionKeys.map { key in
      let m = meta[key] ?? ReportSectionMeta(label: key.capitalized, colorHex: "#64748b")
      return section(for: key, label: m.label, colorHex: m.colorHex, days: days, context: context)
    }
    return ReportPayload(
      title: bundle.title,
      note: bundle.note,
      owner: owner,
      windowDays: days,
      asOf: SeptenaDate.today,
      sections: sections
    )
  }

  // MARK: - Per-section dispatch

  private static func section(for key: String,
                              label: String,
                              colorHex: String,
                              days: Int,
                              context: ModelContext) -> ReportSection {
    switch key {
    case "habits":      return habits(label, colorHex, days, context)
    case "supplements": return supplements(label, colorHex, days, context)
    case "chores":      return chores(label, colorHex, days, context)
    case "gut":         return gut(label, colorHex, days, context)
    case "training":    return training(label, colorHex, days, context)
    case "nutrition":   return nutrition(label, colorHex, days, context)
    case "mood":        return mood(label, colorHex, days, context)
    case "activity":    return activity(label, colorHex, days, context)
    default:
      return ReportSection(key: key, label: label, colorHex: colorHex, unavailable: true)
    }
  }

  // MARK: - Sections

  private static func habits(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let resp = ChecklistMirror.loadHabitsHistory(context: ctx, days: days)
    let pts = resp.daily.map { ReportPoint(label: $0.date, value: Double($0.percent)) }
    let tracked = resp.daily.filter { $0.total > 0 }
    let avg = tracked.isEmpty ? 0 : tracked.map { Double($0.percent) }.reduce(0, +) / Double(tracked.count)
    var stats = [
      ReportStat(label: "Avg completion", value: "\(Int(avg.rounded()))%"),
      ReportStat(label: "Days tracked", value: "\(tracked.count)"),
    ]
    if let best = tracked.max(by: { $0.percent < $1.percent }) {
      stats.append(ReportStat(label: "Best day", value: "\(best.percent)%", detail: SeptenaDate.friendlyLabel(best.date)))
    }
    let charts = tracked.isEmpty ? [] : [ReportChart(title: "Daily completion", kind: .heatmap, unit: "%", points: pts)]
    return ReportSection(key: "habits", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: tracked.isEmpty)
  }

  private static func supplements(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let resp = ChecklistMirror.loadSupplementsHistory(context: ctx, days: days)
    let pts = resp.daily.map { ReportPoint(label: $0.date, value: Double($0.percent)) }
    let tracked = resp.daily.filter { $0.total > 0 }
    let avg = tracked.isEmpty ? 0 : tracked.map { Double($0.percent) }.reduce(0, +) / Double(tracked.count)
    let stats = [
      ReportStat(label: "Avg adherence", value: "\(Int(avg.rounded()))%"),
      ReportStat(label: "Days tracked", value: "\(tracked.count)"),
    ]
    let charts = tracked.isEmpty ? [] : [ReportChart(title: "Daily adherence", kind: .heatmap, unit: "%", points: pts)]
    return ReportSection(key: "supplements", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: tracked.isEmpty)
  }

  private static func chores(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let resp = ChecklistMirror.loadChoresHistory(context: ctx, days: days)
    let pts = resp.daily.map { ReportPoint(label: $0.date, value: Double($0.completed)) }
    let totalDone = resp.daily.map { $0.completed }.reduce(0, +)
    let active = resp.daily.filter { $0.completed > 0 }
    let stats = [
      ReportStat(label: "Completed", value: "\(totalDone)", detail: "last \(days)d"),
      ReportStat(label: "Active days", value: "\(active.count)"),
    ]
    let charts = active.isEmpty ? [] : [ReportChart(title: "Chores completed per day", kind: .bar, points: pts)]
    return ReportSection(key: "chores", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: active.isEmpty)
  }

  private static func gut(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let resp = ChecklistMirror.loadGutHistory(context: ctx, days: days)
    let withData = resp.daily.filter { $0.movements > 0 }
    let totalMoves = resp.daily.map { $0.movements }.reduce(0, +)
    let avgPerDay = withData.isEmpty ? 0 : Double(totalMoves) / Double(withData.count)
    let bristolVals = resp.daily.compactMap { $0.avgBristol }
    let avgBristol = bristolVals.isEmpty ? nil : bristolVals.reduce(0, +) / Double(bristolVals.count)
    var stats = [
      ReportStat(label: "Movements", value: "\(totalMoves)", detail: "last \(days)d"),
      ReportStat(label: "Avg / active day", value: String(format: "%.1f", avgPerDay)),
    ]
    if let b = avgBristol {
      stats.append(ReportStat(label: "Avg Bristol", value: String(format: "%.1f", b), detail: "type 1–7"))
    }
    var charts: [ReportChart] = []
    if !withData.isEmpty {
      charts.append(ReportChart(title: "Movements per day", kind: .bar,
                                points: resp.daily.map { ReportPoint(label: $0.date, value: Double($0.movements)) }))
    }
    if !bristolVals.isEmpty {
      charts.append(ReportChart(title: "Average Bristol", kind: .line, unit: "type",
                                points: resp.daily.compactMap { d in d.avgBristol.map { ReportPoint(label: d.date, value: $0) } }))
    }
    return ReportSection(key: "gut", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: withData.isEmpty)
  }

  private static func training(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let cardio = ChecklistMirror.loadTrainingCardioHistory(context: ctx, days: days)
    let since = isoDaysAgo(days)
    let entries = ChecklistMirror.loadTrainingEntries(context: ctx, since: since)
    let sessionDates = Set(entries.map { $0.date })
    let totalCardio = cardio.daily.map { $0.minutes }.reduce(0, +)
    var stats = [
      ReportStat(label: "Sessions", value: "\(sessionDates.count)", detail: "days trained"),
      ReportStat(label: "Cardio", value: "\(totalCardio) min", detail: "last \(days)d"),
    ]
    if cardio.targetWeeklyMin > 0 {
      stats.append(ReportStat(label: "Weekly target", value: "\(cardio.targetWeeklyMin) min"))
    }
    var charts: [ReportChart] = []
    let cardioActive = cardio.daily.filter { $0.minutes > 0 }
    if !cardioActive.isEmpty {
      charts.append(ReportChart(title: "Cardio minutes per day", kind: .bar,
                                points: cardio.daily.map { ReportPoint(label: $0.date, value: Double($0.minutes)) }))
    }
    let unavailable = sessionDates.isEmpty && cardioActive.isEmpty
    return ReportSection(key: "training", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: unavailable)
  }

  private static func nutrition(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let resp = ChecklistMirror.buildNutritionStatsResponse(context: ctx, days: days)
    let withData = resp.daily.filter { $0.kcal > 0 }
    let avgKcal = withData.isEmpty ? 0 : withData.map { $0.kcal }.reduce(0, +) / Double(withData.count)
    let avgProtein = withData.isEmpty ? 0 : withData.map { $0.proteinG }.reduce(0, +) / Double(withData.count)
    var stats = [
      ReportStat(label: "Avg energy", value: "\(Int(avgKcal.rounded())) kcal", detail: "per logged day"),
      ReportStat(label: "Avg protein", value: "\(Int(avgProtein.rounded())) g"),
      ReportStat(label: "Days logged", value: "\(withData.count)"),
    ]
    if let fast = resp.avgFastH {
      stats.append(ReportStat(label: "Avg fast", value: String(format: "%.1f h", fast)))
    }
    var charts: [ReportChart] = []
    if !withData.isEmpty {
      charts.append(ReportChart(title: "Energy per day", kind: .line, unit: "kcal",
                                points: resp.daily.map { ReportPoint(label: $0.date, value: $0.kcal) }))
      charts.append(ReportChart(title: "Protein per day", kind: .line, unit: "g",
                                points: resp.daily.map { ReportPoint(label: $0.date, value: $0.proteinG) }))
    }
    return ReportSection(key: "nutrition", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: withData.isEmpty)
  }

  private static func mood(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let resp = ChecklistMirror.loadMoodHistory(context: ctx, days: days)
    let logged = resp.daily.filter { $0.logs > 0 }
    let totalLogs = resp.daily.map { $0.logs }.reduce(0, +)
    var stats = [
      ReportStat(label: "Check-ins", value: "\(totalLogs)", detail: "last \(days)d"),
      ReportStat(label: "Days logged", value: "\(logged.count)"),
    ]
    // Dominant-quadrant distribution as a small breakdown chip.
    let quadrants = Dictionary(grouping: logged.compactMap { $0.dominantQuadrant }, by: { $0 })
      .mapValues { $0.count }
    if let top = quadrants.max(by: { $0.value < $1.value }) {
      stats.append(ReportStat(label: "Most common", value: quadrantLabel(top.key)))
    }
    let charts = logged.isEmpty ? [] : [ReportChart(title: "Check-ins per day", kind: .bar,
                                                    points: resp.daily.map { ReportPoint(label: $0.date, value: Double($0.logs)) })]
    return ReportSection(key: "mood", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: logged.isEmpty)
  }

  private static func activity(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let since = isoDaysAgo(days)
    let descriptor = FetchDescriptor<ActivityDayEntity>(
      predicate: #Predicate { $0.date >= since },
      sortBy: [SortDescriptor(\.date)]
    )
    let rows = (try? ctx.fetch(descriptor)) ?? []
    let steps = rows.compactMap { $0.stepCount }.filter { $0 > 0 }
    let avgSteps = steps.isEmpty ? 0 : steps.reduce(0, +) / steps.count
    let exMin = rows.compactMap { $0.exerciseMinutes }.filter { $0 > 0 }
    let totalEx = exMin.reduce(0, +)
    var stats = [
      ReportStat(label: "Avg steps", value: avgSteps.formatted(), detail: "per active day"),
      ReportStat(label: "Days with data", value: "\(steps.count)"),
    ]
    if totalEx > 0 {
      stats.append(ReportStat(label: "Exercise", value: "\(totalEx) min", detail: "last \(days)d"))
    }
    let charts = steps.isEmpty ? [] : [ReportChart(title: "Steps per day", kind: .line, unit: "steps",
                                                  points: rows.compactMap { r in r.stepCount.map { ReportPoint(label: r.date, value: Double($0)) } })]
    return ReportSection(key: "activity", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: steps.isEmpty)
  }

  // MARK: - Helpers

  private static func isoDaysAgo(_ n: Int) -> String {
    let base = SeptenaDate.parse(SeptenaDate.today) ?? Date()
    let d = Calendar.current.date(byAdding: .day, value: -n, to: base) ?? base
    return SeptenaDate.format(d) ?? SeptenaDate.today
  }

  private static func quadrantLabel(_ raw: String) -> String {
    switch raw {
    case "hap": return "High energy, pleasant"
    case "lap": return "Low energy, pleasant"
    case "lan": return "Low energy, unpleasant"
    case "han": return "High energy, unpleasant"
    default:    return raw
    }
  }
}
