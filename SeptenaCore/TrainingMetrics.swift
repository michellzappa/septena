import Foundation
import SwiftData

/// The three weekly training numbers — strength hard sets, cardio minutes, and
/// session count — plus goal-aware target resolution, in one place so the
/// in-app strength/cardio cards, the Goals progress bars, and the watch
/// training-ring complication can't drift.
///
/// "Week" is the app-wide trailing 7 days (today + previous 6), never the
/// calendar week (see CLAUDE.md). Targets prefer a real goal on the matching
/// metric key and fall back to the built-in defaults (the former hardcodes)
/// when the user has set none — so nothing changes for users who never open the
/// Goals surface, and setting a target = editing the goal keeps every surface in
/// sync (the same targets-as-goals bridge nutrition uses).
/// Effort-rating coverage over a window of strength work.
///
/// Top-level (not nested in `TrainingMetrics`) so it stays free of MainActor
/// isolation and can be accumulated from either the SwiftData entity or the
/// Training drawer's own value type — one rule for "counts as rated", in one
/// place, rather than a copy per row shape.
struct EffortCoverage: Equatable, Sendable {
  /// Sets logged on strength entries in the window.
  private(set) var sets = 0
  /// Of those, sets whose entry carries a difficulty we recognize.
  private(set) var rated = 0

  var fraction: Double { sets > 0 ? Double(rated) / Double(sets) : 0 }

  /// True when enough of the window is unrated that the hard-set figure
  /// understates the work done. Under this much unrated the gap is noise, not
  /// a finding worth putting on screen.
  var isUnderReported: Bool { sets > 0 && fraction < 0.6 }

  mutating func add(sets n: Int, difficulty: String?) {
    guard n > 0 else { return }
    sets += n
    if Self.isRated(difficulty) { rated += n }
  }

  /// Whether a stored difficulty string is one we understand. Mirrors
  /// `TrainingMetrics.difficultyWeight`'s folding — including `easy`, which
  /// *is* a rating; it just earns no stimulus credit.
  static func isRated(_ raw: String?) -> Bool {
    switch (raw ?? "").lowercased() {
    case "easy", "moderate", "medium", "hard", "max", "failure": return true
    default:                                                     return false
    }
  }
}

@MainActor
enum TrainingMetrics {
  // MARK: Metric keys — the bridge between training data and the Goals system.

  static let hardSetsKey      = "training.hard_sets_week"
  static let cardioMinutesKey = "training.cardio_minutes_week"
  static let sessionCountKey  = "training.session_count"

  // MARK: Built-in defaults (formerly hardcoded in the view + watch publisher).

  /// Productive hypertrophy band (Schoenfeld et al.) — 12 hard sets/week to
  /// drive a stimulus, 20 as the soft ceiling before a deload.
  static let defaultHardSetsTarget:  Double = 12
  static let defaultHardSetsCeiling: Double = 20
  static let defaultCardioWeeklyMin: Double = 150   // WHO Zone-2 weekly minutes
  static let defaultSessionTarget:   Double = 4

  // MARK: Values

  /// Trailing-7-day cutoff (today + previous 6), as a YYYY-MM-DD string.
  static func weekCutoff(today: String) -> String {
    let anchor = SeptenaDate.startOfDay(for: today) ?? Date()
    return SeptenaDate.format(Calendar.current.date(byAdding: .day, value: -6, to: anchor))
      ?? today
  }

  /// This week's entries (trailing 7 days, inclusive of today).
  static func entriesThisWeek(context: ModelContext, today: String) -> [ExerciseEntryEntity] {
    let cutoff = weekCutoff(today: today)
    return (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      predicate: #Predicate { $0.date >= cutoff && $0.date <= today }
    ))) ?? []
  }

  static func isCardio(_ e: ExerciseEntryEntity) -> Bool {
    (e.distanceM ?? 0) > 0 || ((e.durationMin ?? 0) > 0 && e.weight == nil)
  }
  static func isStrength(_ e: ExerciseEntryEntity) -> Bool {
    e.weight != nil && !isCardio(e)
  }

  /// Difficulty → stimulus weight. Mirror of `TrainingEffort.canonicalKey`'s
  /// folding (kept here so SeptenaCore doesn't depend on the app UI layer):
  /// hard/max = 1.0, moderate/medium = 0.5, easy/unrated = 0. `failure` is the
  /// hosted MCP gateway's word for to-failure and folds onto max — without it
  /// a set logged through the gateway scored zero stimulus.
  static func difficultyWeight(_ raw: String?) -> Double {
    switch (raw ?? "").lowercased() {
    case "hard", "max", "failure": return 1.0
    case "moderate", "medium":     return 0.5
    default:                       return 0
    }
  }

  /// Effective hard sets = Σ sets × difficulty weight over strength entries.
  static func hardSets(_ entries: [ExerciseEntryEntity]) -> Double {
    var total = 0.0
    for e in entries where isStrength(e) {
      guard let s = Int(e.sets ?? ""), s > 0 else { continue }
      total += Double(s) * difficultyWeight(e.difficulty)
    }
    return total
  }

  /// How much of a window's strength volume actually carries an effort rating.
  ///
  /// `hardSets` scores an unrated set as zero stimulus, which is the right
  /// default — an unrated set is not evidence of a hard one — but it makes the
  /// headline number quietly speak for sets nobody rated. 6 hard sets out of
  /// 20 logged is a very different week depending on whether 4 or 18 of them
  /// were rated, and only the denominator can tell those apart.
  static func effortCoverage(_ entries: [ExerciseEntryEntity]) -> EffortCoverage {
    var out = EffortCoverage()
    for e in entries where isStrength(e) {
      out.add(sets: Int(e.sets ?? "") ?? 0, difficulty: e.difficulty)
    }
    return out
  }

  /// Summed `durationMin` over cardio entries.
  static func cardioMinutes(_ entries: [ExerciseEntryEntity]) -> Double {
    entries.filter(isCardio).reduce(0.0) { $0 + ($1.durationMin ?? 0) }
  }

  /// Distinct training days (multiple session types in one day = one session).
  static func sessionCount(_ entries: [ExerciseEntryEntity]) -> Double {
    Double(Set(entries.map { $0.date }).count)
  }

  // MARK: Goal-aware targets

  private static func goal(_ key: String, context: ModelContext) -> Goal? {
    LocalCache.goals(in: context).first { $0.metricKey == key }
  }

  /// (target, ceiling) for weekly hard sets. A range goal supplies both bounds;
  /// a single-bound goal supplies the target and keeps the default ceiling;
  /// no goal falls back to the productive 12–20 band.
  static func hardSetsBand(context: ModelContext) -> (target: Double, ceiling: Double) {
    if let g = goal(hardSetsKey, context: context), let lo = g.metricTarget, lo > 0 {
      let hi = g.metricTargetUpper ?? defaultHardSetsCeiling
      return (lo, max(hi, lo))
    }
    return (defaultHardSetsTarget, defaultHardSetsCeiling)
  }

  static func cardioMinutesTarget(context: ModelContext) -> Double {
    if let g = goal(cardioMinutesKey, context: context),
       let t = g.metricTargetUpper ?? g.metricTarget, t > 0 { return t }
    return defaultCardioWeeklyMin
  }

  static func sessionTarget(context: ModelContext) -> Double {
    if let g = goal(sessionCountKey, context: context),
       let t = g.metricTargetUpper ?? g.metricTarget, t > 0 { return t }
    return defaultSessionTarget
  }
}

// MARK: - Per-exercise progress history

/// Which progression number a 90-day history chart plots, keyed off the
/// exercise's shape. Strength tracks estimated 1-rep-max (the standard
/// load-progress proxy); cardio tracks speed (m/min, formatted km/h at the
/// edge); mobility tracks session length.
enum TrainingProgressMetric: String, Sendable, Codable {
  case oneRepMax   // strength — kg (Epley e1RM, or raw weight when reps absent)
  case topWeight   // strength — kg (heaviest load logged that day, reps ignored)
  case pace        // cardio — m/min (distance ÷ duration)
  case duration    // mobility — minutes
}

/// One plotted point: the best value logged on a given day for an exercise.
struct TrainingProgressPoint: Hashable, Sendable, Codable {
  let date: Date
  let value: Double
}

/// A compact 90-day progress series for a single exercise — what the
/// in-session card draws instead of a last-3 table. Chronological, one
/// point per training day (the day's best value), plus the window mean
/// for the cardio average-pace line.
struct TrainingProgressSeries: Sendable {
  let metric: TrainingProgressMetric
  let points: [TrainingProgressPoint]
  /// Mean of the daily values across the window (drives the pace avg rule).
  let average: Double?

  var latest: Double? { points.last?.value }
  var best: Double? { points.map(\.value).max() }
  var isEmpty: Bool { points.isEmpty }
}

@MainActor
extension TrainingMetrics {
  /// Build the trailing `daysBack`-day progress series for one exercise.
  /// Groups entries by day and keeps the day's best value so multiple sets
  /// collapse to one point; sorted oldest→newest for charting. Case-
  /// insensitive exercise match (same `exerciseKey` the rest of training
  /// uses), so casing/separator drift doesn't hide history.
  static func progressSeries(for exercise: String,
                             metric: TrainingProgressMetric,
                             in context: ModelContext,
                             today: String,
                             daysBack: Int = 90) -> TrainingProgressSeries {
    let key = exerciseKey(exercise)
    let anchor = SeptenaDate.startOfDay(for: today) ?? Date()
    let cutoff = SeptenaDate.format(
      Calendar.current.date(byAdding: .day, value: -(daysBack - 1), to: anchor)
    ) ?? today
    // Predicate trims by date (indexed string compare); the exercise key is
    // computed, so match it in the post-fetch filter.
    let rows = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      predicate: #Predicate { $0.date >= cutoff }
    ))) ?? []

    // day-string → best value so far that day
    var bestByDay: [String: Double] = [:]
    for e in rows where exerciseKey(e.exercise) == key {
      guard let v = value(of: e, metric: metric) else { continue }
      if let existing = bestByDay[e.date] { bestByDay[e.date] = max(existing, v) }
      else { bestByDay[e.date] = v }
    }

    let points = bestByDay
      .compactMap { (day, v) -> TrainingProgressPoint? in
        guard let d = SeptenaDate.parse(day) else { return nil }
        return TrainingProgressPoint(date: d, value: v)
      }
      .sorted { $0.date < $1.date }

    let avg = points.isEmpty ? nil
      : points.reduce(0.0) { $0 + $1.value } / Double(points.count)
    return TrainingProgressSeries(metric: metric, points: points, average: avg)
  }

  /// The single progression value for an entry under a given metric, or nil
  /// when the entry lacks the fields that metric needs.
  private static func value(of e: ExerciseEntryEntity,
                            metric: TrainingProgressMetric) -> Double? {
    progressValue(metric: metric, weight: e.weight, reps: e.reps,
                  distanceM: e.distanceM, durationMin: e.durationMin)
  }

  /// The plotted value for one (weight, reps, distance, duration) tuple under a
  /// metric — same rules the history series uses, exposed so the in-session
  /// editor can plot the set being entered *right now* against its own trend.
  /// Nil when the fields that metric needs are absent.
  static func progressValue(metric: TrainingProgressMetric,
                            weight: Double?, reps: String?,
                            distanceM: Double?, durationMin: Double?) -> Double? {
    switch metric {
    case .oneRepMax:
      guard let w = weight, w > 0 else { return nil }
      // No rep count logged — plot the load itself, which is at least a
      // measurement. With a rep count, the shared estimator applies, and past
      // its rep cap the day simply produces no point rather than a fantasy
      // one (or a cliff back down to the raw load, which would read as a
      // regression on the chart).
      guard let r = Int(reps ?? ""), r > 0 else { return w }
      return OneRepMax.estimate(weightKg: w, reps: r)
    case .topWeight:
      // Heaviest load actually put on the bar that day — reps ignored. The
      // honest "am I loading more?" line, distinct from e1RM which rises when
      // you add reps at the same weight.
      guard let w = weight, w > 0 else { return nil }
      return w
    case .pace:
      guard let d = distanceM, d > 0, let m = durationMin, m > 0 else { return nil }
      return d / m
    case .duration:
      guard let m = durationMin, m > 0 else { return nil }
      return m
    }
  }
}
