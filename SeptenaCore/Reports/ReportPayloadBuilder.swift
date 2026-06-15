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
    "sleep", "body", "hydration",
    "symptoms", "medications", "intake",
  ]

  public static func build(bundle: ReportBundle,
                           meta: [String: ReportSectionMeta],
                           owner: String,
                           weightUnit: String = "kg",
                           context: ModelContext) -> ReportPayload {
    let days = max(1, bundle.windowDays)
    let sections: [ReportSection] = bundle.sectionKeys.map { key in
      let m = meta[key] ?? ReportSectionMeta(label: key.capitalized, colorHex: "#64748b")
      return section(for: key, label: m.label, colorHex: m.colorHex, days: days, weightUnit: weightUnit, context: context)
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
                              weightUnit: String,
                              context: ModelContext) -> ReportSection {
    switch key {
    case "habits":      return habits(label, colorHex, days, context)
    case "supplements": return supplements(label, colorHex, days, context)
    case "chores":      return chores(label, colorHex, days, context)
    case "gut":         return gut(label, colorHex, days, context)
    case "training":    return training(label, colorHex, days, weightUnit, context)
    case "nutrition":   return nutrition(label, colorHex, days, context)
    case "mood":        return mood(label, colorHex, days, context)
    case "activity":    return activity(label, colorHex, days, context)
    case "sleep":       return sleep(label, colorHex, days, context)
    case "body":        return body(label, colorHex, days, weightUnit, context)
    case "hydration":   return hydration(label, colorHex, days, context)
    case "symptoms":    return symptoms(label, colorHex, days, context)
    case "medications": return medications(label, colorHex, days, context)
    case "intake":      return intake(label, colorHex, days, context)
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

  private static func training(_ label: String, _ color: String, _ days: Int, _ weightUnit: String, _ ctx: ModelContext) -> ReportSection {
    let cardio = ChecklistMirror.loadTrainingCardioHistory(context: ctx, days: days)
    let since = isoDaysAgo(days)
    let entries = ChecklistMirror.loadTrainingEntries(context: ctx, since: since)
    let sessionDates = Set(entries.map { $0.date })
    let strength = entries.filter { ($0.weight ?? 0) > 0 }

    // Volume per day = Σ(weight × sets × reps). Skips entries with non-numeric
    // sets/reps (e.g. "AMRAP").
    var volByDate: [String: Double] = [:]
    for e in strength {
      guard let w = e.weight, let s = intOf(e.sets), let r = intOf(e.reps) else { continue }
      volByDate[e.date, default: 0] += w * Double(s) * Double(r)
    }
    let totalCardio = cardio.daily.map { $0.minutes }.reduce(0, +)
    let totalVol = volByDate.values.reduce(0, +)

    var stats = [ReportStat(label: "Sessions", value: "\(sessionDates.count)", detail: "days trained, last \(days)d")]
    if totalVol > 0 {
      stats.append(ReportStat(label: "Total volume", value: trimNum(totalVol) + " \(weightUnit)", detail: "weight × sets × reps"))
    }
    if totalCardio > 0 { stats.append(ReportStat(label: "Cardio", value: "\(totalCardio) min")) }
    if cardio.targetWeeklyMin > 0 { stats.append(ReportStat(label: "Weekly cardio target", value: "\(cardio.targetWeeklyMin) min")) }

    var charts: [ReportChart] = []
    if !volByDate.isEmpty {
      let pts = volByDate.keys.sorted().map { ReportPoint(label: $0, value: volByDate[$0]!) }
      charts.append(ReportChart(title: "Training volume per day", kind: .bar, unit: weightUnit, points: pts))
    }
    let cardioActive = cardio.daily.filter { $0.minutes > 0 }
    if !cardioActive.isEmpty {
      charts.append(ReportChart(title: "Cardio minutes per day", kind: .bar, unit: "min",
                                points: cardio.daily.map { ReportPoint(label: $0.date, value: Double($0.minutes)) },
                                target: cardio.targetWeeklyMin > 0 ? Double(cardio.targetWeeklyMin) / 7.0 : nil))
    }

    // Per-exercise progression — working weight over time for the most-trained
    // strength lifts (cap at 6 so the report stays scannable).
    let byExercise = Dictionary(grouping: strength.filter { !($0.exercise ?? "").isEmpty },
                                by: { $0.exercise! })
    let ranked = byExercise.sorted { $0.value.count > $1.value.count }
    for (name, es) in ranked.prefix(6) {
      var maxByDate: [String: Double] = [:]
      for e in es { if let w = e.weight { maxByDate[e.date] = max(maxByDate[e.date] ?? 0, w) } }
      let pts = maxByDate.keys.sorted().map { ReportPoint(label: $0, value: maxByDate[$0]!) }
      if pts.count >= 2 {
        charts.append(ReportChart(title: "\(name) — working weight", kind: .line, unit: weightUnit, points: pts))
      }
    }

    // Exercises table: working set, best, and frequency per lift.
    var rows: [[String]] = []
    for (name, es) in ranked {
      let sorted = es.sorted { ($0.loggedAt ?? $0.date) < ($1.loggedAt ?? $1.date) }
      guard let last = sorted.last else { continue }
      let best = es.compactMap { $0.weight }.max()
      rows.append([
        name,
        setString(last, unit: weightUnit),
        best.map { trimNum($0) + " \(weightUnit)" } ?? "—",
        "\(Set(es.map { $0.date }).count)",
      ])
    }
    var tables: [ReportTable] = []
    if !rows.isEmpty {
      tables.append(ReportTable(title: "Exercises", columns: ["Exercise", "Last set", "Best", "Sessions"], rows: rows))
    }

    // Weekly volume by muscle group — sets per primary muscle, normalized to a
    // per-week landmark (the way a coach programs volume). Joins entries to the
    // exercise catalog's primaryMuscle.
    let defs = ChecklistMirror.loadExerciseDefinitions(context: ctx)
    var nameToMuscle: [String: Muscle] = [:]
    for d in defs {
      guard let m = d.primaryMuscle else { continue }
      nameToMuscle[d.name.lowercased()] = m
      for a in (d.aliases ?? []) { nameToMuscle[a.lowercased()] = m }
    }
    var setsByMuscle: [Muscle: Int] = [:]
    for e in strength {
      guard let nm = e.exercise?.lowercased(), let m = nameToMuscle[nm], let s = intOf(e.sets) else { continue }
      setsByMuscle[m, default: 0] += s
    }
    if !setsByMuscle.isEmpty {
      let weeks = max(1.0, Double(days) / 7.0)
      let mrows = setsByMuscle.sorted { $0.value > $1.value }.map { (m, sets) in
        [m.label, "\(sets)", String(format: "%.1f", Double(sets) / weeks)]
      }
      tables.append(ReportTable(title: "Volume by muscle", columns: ["Muscle", "Sets", "Sets / wk"], rows: mrows))
    }

    // Session notes — one per session (date), most recent first.
    var seenDates = Set<String>()
    var notes: [String] = []
    for e in entries where !(e.note ?? "").isEmpty {
      guard !seenDates.contains(e.date) else { continue }
      seenDates.insert(e.date)
      notes.append("\(SeptenaDate.friendlyLabel(e.date)) — \(e.note!)")
      if notes.count >= 8 { break }
    }

    let unavailable = sessionDates.isEmpty && cardioActive.isEmpty
    return ReportSection(key: "training", label: label, colorHex: color, stats: stats, charts: charts,
                         tables: tables, notes: notes, unavailable: unavailable)
  }

  private static func nutrition(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let resp = ChecklistMirror.buildNutritionStatsResponse(context: ctx, days: days)
    let withData = resp.daily.filter { $0.kcal > 0 }
    func avg(_ f: (NutritionDailyPoint) -> Double?) -> Double {
      let v = withData.compactMap(f); return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }
    let cfg = NutritionPrefs.loadMacrosConfig()
    func mid(_ r: MacroRange?) -> Double? { r.map { ($0.min + $0.max) / 2 } }

    var stats = [
      ReportStat(label: "Avg energy", value: "\(Int(avg { $0.kcal }.rounded())) kcal", detail: "per logged day"),
      ReportStat(label: "Avg protein", value: "\(Int(avg { $0.proteinG }.rounded())) g"),
      ReportStat(label: "Avg carbs", value: "\(Int(avg { $0.carbsG }.rounded())) g"),
      ReportStat(label: "Avg fat", value: "\(Int(avg { $0.fatG }.rounded())) g"),
    ]
    let avgFiber = avg { $0.fiberG }
    if avgFiber > 0 { stats.append(ReportStat(label: "Avg fiber", value: "\(Int(avgFiber.rounded())) g")) }
    stats.append(ReportStat(label: "Days logged", value: "\(withData.count)"))
    if let fast = resp.avgFastH { stats.append(ReportStat(label: "Avg fast", value: String(format: "%.1f h", fast))) }

    var charts: [ReportChart] = []
    if !withData.isEmpty {
      charts.append(ReportChart(title: "Energy per day", kind: .line, unit: "kcal",
                                points: resp.daily.map { ReportPoint(label: $0.date, value: $0.kcal) }, target: mid(cfg?.kcal)))
      charts.append(ReportChart(title: "Protein per day", kind: .line, unit: "g",
                                points: resp.daily.map { ReportPoint(label: $0.date, value: $0.proteinG) }, target: mid(cfg?.protein)))
      charts.append(ReportChart(title: "Carbs per day", kind: .line, unit: "g",
                                points: resp.daily.map { ReportPoint(label: $0.date, value: $0.carbsG) }, target: mid(cfg?.carbs)))
      charts.append(ReportChart(title: "Fat per day", kind: .line, unit: "g",
                                points: resp.daily.map { ReportPoint(label: $0.date, value: $0.fatG) }, target: mid(cfg?.fat)))
      if resp.daily.contains(where: { ($0.fiberG ?? 0) > 0 }) {
        charts.append(ReportChart(title: "Fiber per day", kind: .line, unit: "g",
                                  points: resp.daily.map { ReportPoint(label: $0.date, value: $0.fiberG ?? 0) }, target: mid(cfg?.fiber)))
      }
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
    // Dominant-quadrant distribution — the actual mood content.
    let quadrants = Dictionary(grouping: logged.compactMap { $0.dominantQuadrant }, by: { $0 })
      .mapValues { $0.count }
    let totalQ = quadrants.values.reduce(0, +)
    if totalQ > 0 {
      let pleasant = (quadrants["hap"] ?? 0) + (quadrants["lap"] ?? 0)
      stats.append(ReportStat(label: "Pleasant", value: "\(Int((Double(pleasant) / Double(totalQ) * 100).rounded()))%",
                              detail: "of logged days"))
      if let top = quadrants.max(by: { $0.value < $1.value }) {
        stats.append(ReportStat(label: "Most common", value: quadrantLabel(top.key)))
      }
    }
    var tables: [ReportTable] = []
    if totalQ > 0 {
      let order = ["hap", "lap", "lan", "han"]
      let rows = order.compactMap { q -> [String]? in
        let c = quadrants[q] ?? 0
        guard c > 0 else { return nil }
        return [quadrantLabel(q), "\(c)", "\(Int((Double(c) / Double(totalQ) * 100).rounded()))%"]
      }
      tables.append(ReportTable(title: "Mood balance", columns: ["State", "Days", "Share"], rows: rows))
    }
    let charts = logged.isEmpty ? [] : [ReportChart(title: "Check-ins per day", kind: .bar,
                                                    points: resp.daily.map { ReportPoint(label: $0.date, value: Double($0.logs)) })]
    return ReportSection(key: "mood", label: label, colorHex: color, stats: stats, charts: charts,
                         tables: tables, unavailable: logged.isEmpty)
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
    let kcal = rows.compactMap { $0.activeKcal }.filter { $0 > 0 }
    if !kcal.isEmpty {
      stats.append(ReportStat(label: "Avg active energy", value: "\(Int((kcal.reduce(0,+) / Double(kcal.count)).rounded())) kcal"))
    }
    var charts: [ReportChart] = []
    if !steps.isEmpty {
      charts.append(ReportChart(title: "Steps per day", kind: .line, unit: "steps",
                                points: rows.compactMap { r in r.stepCount.map { ReportPoint(label: r.date, value: Double($0)) } }))
    }
    if !exMin.isEmpty {
      charts.append(ReportChart(title: "Exercise minutes per day", kind: .bar, unit: "min",
                                points: rows.compactMap { r in r.exerciseMinutes.map { ReportPoint(label: r.date, value: Double($0)) } }))
    }
    return ReportSection(key: "activity", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: steps.isEmpty && exMin.isEmpty)
  }

  private static func sleep(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let since = isoDaysAgo(days)
    let desc = FetchDescriptor<OuraNightEntity>(
      predicate: #Predicate { $0.id >= since },
      sortBy: [SortDescriptor(\.id)]
    )
    let rows = (try? ctx.fetch(desc)) ?? []
    let scores = rows.compactMap { $0.sleepScore }
    let durations = rows.compactMap { $0.totalH }
    let readiness = rows.compactMap { $0.readinessScore }
    var stats: [ReportStat] = []
    if !scores.isEmpty {
      stats.append(ReportStat(label: "Avg sleep score", value: "\(scores.reduce(0,+) / scores.count)"))
    }
    if !durations.isEmpty {
      let avg = durations.reduce(0,+) / Double(durations.count)
      stats.append(ReportStat(label: "Avg duration", value: String(format: "%.1f h", avg)))
    }
    if !readiness.isEmpty {
      stats.append(ReportStat(label: "Avg readiness", value: "\(readiness.reduce(0,+) / readiness.count)"))
    }
    func avgD(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0,+) / Double(xs.count) }
    func avgI(_ xs: [Int]) -> Int { xs.isEmpty ? 0 : xs.reduce(0,+) / xs.count }
    let deep = rows.compactMap { $0.deepH }, rem = rows.compactMap { $0.remH }
    if !deep.isEmpty { stats.append(ReportStat(label: "Avg deep", value: String(format: "%.1f h", avgD(deep)))) }
    if !rem.isEmpty { stats.append(ReportStat(label: "Avg REM", value: String(format: "%.1f h", avgD(rem)))) }
    let hrv = rows.compactMap { $0.hrv }, rhr = rows.compactMap { $0.restingHr }, eff = rows.compactMap { $0.efficiency }
    if !hrv.isEmpty { stats.append(ReportStat(label: "Avg HRV", value: "\(avgI(hrv)) ms")) }
    if !rhr.isEmpty { stats.append(ReportStat(label: "Avg resting HR", value: "\(avgI(rhr)) bpm")) }
    if !eff.isEmpty { stats.append(ReportStat(label: "Avg efficiency", value: "\(avgI(eff))%")) }
    stats.append(ReportStat(label: "Nights", value: "\(max(scores.count, durations.count))"))

    var charts: [ReportChart] = []
    if !scores.isEmpty {
      charts.append(ReportChart(title: "Sleep score", kind: .line,
                                points: rows.compactMap { r in r.sleepScore.map { ReportPoint(label: r.id, value: Double($0)) } }))
    }
    if !durations.isEmpty {
      charts.append(ReportChart(title: "Total sleep", kind: .line, unit: "h",
                                points: rows.compactMap { r in r.totalH.map { ReportPoint(label: r.id, value: $0) } }))
    }
    if !hrv.isEmpty {
      charts.append(ReportChart(title: "HRV", kind: .line, unit: "ms",
                                points: rows.compactMap { r in r.hrv.map { ReportPoint(label: r.id, value: Double($0)) } }))
    }
    if !rhr.isEmpty {
      charts.append(ReportChart(title: "Resting heart rate", kind: .line, unit: "bpm",
                                points: rows.compactMap { r in r.restingHr.map { ReportPoint(label: r.id, value: Double($0)) } }))
    }
    return ReportSection(key: "sleep", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: scores.isEmpty && durations.isEmpty)
  }

  private static func body(_ label: String, _ color: String, _ days: Int, _ weightUnit: String, _ ctx: ModelContext) -> ReportSection {
    let since = isoDaysAgo(days)
    let desc = FetchDescriptor<WithingsRowEntity>(
      predicate: #Predicate { $0.id >= since },
      sortBy: [SortDescriptor(\.id)]
    )
    let rows = (try? ctx.fetch(desc)) ?? []
    let toUnit = weightUnit == "lb" ? 2.20462 : 1.0
    let weights = rows.compactMap { r in r.weightKg.map { (r.id, $0 * toUnit) } }
    let fats = rows.compactMap { r in r.fatPct.map { (r.id, $0) } }
    let muscle = rows.compactMap { r in r.muscleMassKg.map { (r.id, $0 * toUnit) } }
    var stats: [ReportStat] = []
    if let last = weights.last {
      let delta = weights.first.map { last.1 - $0.1 } ?? 0
      let sign = delta > 0 ? "+" : ""
      stats.append(ReportStat(label: "Weight", value: "\(trimNum(last.1)) \(weightUnit)",
                              detail: weights.count > 1 ? "\(sign)\(trimNum(delta)) over window" : nil))
    }
    if let last = fats.last {
      stats.append(ReportStat(label: "Body fat", value: String(format: "%.1f%%", last.1)))
    }
    if let last = muscle.last {
      stats.append(ReportStat(label: "Muscle mass", value: "\(trimNum(last.1)) \(weightUnit)"))
    }
    stats.append(ReportStat(label: "Weigh-ins", value: "\(weights.count)"))
    var charts: [ReportChart] = []
    if !weights.isEmpty {
      charts.append(ReportChart(title: "Weight", kind: .line, unit: weightUnit,
                                points: weights.map { ReportPoint(label: $0.0, value: $0.1) }))
    }
    if !fats.isEmpty {
      charts.append(ReportChart(title: "Body fat", kind: .line, unit: "%",
                                points: fats.map { ReportPoint(label: $0.0, value: $0.1) }))
    }
    if !muscle.isEmpty {
      charts.append(ReportChart(title: "Muscle mass", kind: .line, unit: weightUnit,
                                points: muscle.map { ReportPoint(label: $0.0, value: $0.1) }))
    }
    return ReportSection(key: "body", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: weights.isEmpty && fats.isEmpty)
  }

  private static func hydration(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let ml = ChecklistMirror.loadHydrationDailyMl(context: ctx, days: days)  // oldest→newest, length days
    let base = SeptenaDate.parse(SeptenaDate.today) ?? Date()
    let active = ml.filter { $0 > 0 }
    let avg = active.isEmpty ? 0 : active.reduce(0,+) / active.count
    let stats = [
      ReportStat(label: "Avg intake", value: "\(avg) ml", detail: "per logged day"),
      ReportStat(label: "Days logged", value: "\(active.count)"),
    ]
    var charts: [ReportChart] = []
    if !active.isEmpty {
      let n = ml.count
      let points: [ReportPoint] = ml.enumerated().map { (i, v) in
        let d = Calendar.current.date(byAdding: .day, value: -(n - 1 - i), to: base) ?? base
        return ReportPoint(label: SeptenaDate.format(d) ?? SeptenaDate.today, value: Double(v))
      }
      charts.append(ReportChart(title: "Daily intake", kind: .bar, unit: "ml", points: points))
    }
    return ReportSection(key: "hydration", label: label, colorHex: color, stats: stats, charts: charts,
                         unavailable: active.isEmpty)
  }

  private static func symptoms(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let since = isoDaysAgo(days)
    let events = (try? ctx.fetch(FetchDescriptor<SymptomEventEntity>(
      predicate: #Predicate { $0.date >= since }, sortBy: [SortDescriptor(\.date)]))) ?? []
    guard !events.isEmpty else {
      return ReportSection(key: "symptoms", label: label, colorHex: color, unavailable: true)
    }
    let defs = (try? ctx.fetch(FetchDescriptor<SymptomDefinitionEntity>())) ?? []
    let titles = Dictionary(defs.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    let byId = Dictionary(grouping: events, by: { $0.symptomID })
    let stats = [
      ReportStat(label: "Episodes", value: "\(events.count)", detail: "last \(days)d"),
      ReportStat(label: "Distinct symptoms", value: "\(byId.count)"),
      ReportStat(label: "Days affected", value: "\(Set(events.map { $0.date }).count)"),
    ]
    let rows = byId.sorted { $0.value.count > $1.value.count }.map { (id, evs) -> [String] in
      let avg = Double(evs.map { $0.severity }.reduce(0, +)) / Double(evs.count)
      let last = evs.map { $0.date }.max() ?? ""
      return [titles[id] ?? id, "\(evs.count)", String(format: "%.1f", avg), SeptenaDate.friendlyLabel(last)]
    }
    let table = ReportTable(title: "Symptoms", columns: ["Symptom", "Episodes", "Avg severity", "Last"], rows: rows)
    let perDay = Dictionary(grouping: events, by: { $0.date }).mapValues { $0.count }
    let chart = ReportChart(title: "Episodes per day", kind: .bar,
                            points: perDay.keys.sorted().map { ReportPoint(label: $0, value: Double(perDay[$0]!)) })
    return ReportSection(key: "symptoms", label: label, colorHex: color, stats: stats, charts: [chart], tables: [table])
  }

  private static func medications(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let since = isoDaysAgo(days)
    let events = (try? ctx.fetch(FetchDescriptor<MedicationDoseEventEntity>(
      predicate: #Predicate { $0.date >= since }, sortBy: [SortDescriptor(\.date)]))) ?? []
    guard !events.isEmpty else {
      return ReportSection(key: "medications", label: label, colorHex: color, unavailable: true)
    }
    let defs = (try? ctx.fetch(FetchDescriptor<MedicationDefinitionEntity>())) ?? []
    let titles = Dictionary(defs.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    let byId = Dictionary(grouping: events, by: { $0.medicationID })
    let stats = [
      ReportStat(label: "Doses logged", value: "\(events.count)", detail: "last \(days)d"),
      ReportStat(label: "Medications", value: "\(byId.count)"),
    ]
    let rows = byId.sorted { $0.value.count > $1.value.count }.map { (id, evs) -> [String] in
      let last = evs.map { $0.date }.max() ?? ""
      return [titles[id] ?? id, "\(evs.count)", SeptenaDate.friendlyLabel(last)]
    }
    let table = ReportTable(title: "Medications", columns: ["Medication", "Doses", "Last"], rows: rows)
    return ReportSection(key: "medications", label: label, colorHex: color, stats: stats, tables: [table])
  }

  private static func intake(_ label: String, _ color: String, _ days: Int, _ ctx: ModelContext) -> ReportSection {
    let since = isoDaysAgo(days)
    let events = (try? ctx.fetch(FetchDescriptor<IntakeEventEntity>(
      predicate: #Predicate { $0.date >= since }, sortBy: [SortDescriptor(\.date)]))) ?? []
    guard !events.isEmpty else {
      return ReportSection(key: "intake", label: label, colorHex: color, unavailable: true)
    }
    let kinds = (try? ctx.fetch(FetchDescriptor<IntakeKindEntity>())) ?? []
    let kindByID = Dictionary(kinds.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let byKind = Dictionary(grouping: events, by: { $0.kindID })
    let stats = [
      ReportStat(label: "Entries", value: "\(events.count)", detail: "last \(days)d"),
      ReportStat(label: "Trackers", value: "\(byKind.count)"),
    ]
    let rows = byKind.sorted { $0.value.count > $1.value.count }.map { (id, evs) -> [String] in
      let k = kindByID[id]
      let name = k?.name ?? id
      let total: String
      if k?.metricMode == "sumAmount" {
        let sum = evs.compactMap { $0.amount }.reduce(0, +)
        total = "\(trimNum(sum)) \(k?.unit ?? "")".trimmingCharacters(in: .whitespaces)
      } else {
        total = "\(evs.count)×"
      }
      return [name, total, "\(evs.count)"]
    }
    let table = ReportTable(title: "Intake", columns: ["Tracker", "Total", "Entries"], rows: rows)
    return ReportSection(key: "intake", label: label, colorHex: color, stats: stats, tables: [table])
  }

  // MARK: - Helpers

  private static func intOf(_ s: String?) -> Int? {
    guard let s else { return nil }
    return Int(s.trimmingCharacters(in: .whitespaces))
  }

  private static func trimNum(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
  }

  /// "80 kg · 3×5" from an entry's weight/sets/reps (any part may be absent).
  private static func setString(_ e: ExerciseEntry, unit: String) -> String {
    var parts: [String] = []
    if let w = e.weight { parts.append("\(trimNum(w)) \(unit)") }
    if let s = e.sets, let r = e.reps, !s.isEmpty, !r.isEmpty { parts.append("\(s)×\(r)") }
    else if let r = e.reps, !r.isEmpty { parts.append("\(r) reps") }
    return parts.isEmpty ? "—" : parts.joined(separator: " · ")
  }

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
