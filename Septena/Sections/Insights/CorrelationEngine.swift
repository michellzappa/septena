import Foundation
import SwiftData

// CorrelationEngine — client-side cross-section correlation discovery.
//
// Reads from the local SwiftData store (the CloudKit-mirrored cache) plus
// the existing /api/health/oura read endpoint for sleep / HRV / readiness
// (which doesn't yet have a SwiftData entity). All Pearson + lag math
// runs in-process, so adding Insights doesn't widen the API surface — in
// line with the project's "no new endpoints during CloudKit migration"
// posture (see memory: project_cloudkit_migration).
//
// The engine builds a per-day feature dictionary keyed by ISO date and
// then tests a curated set of predictor→target pairs at lags 0, 1 and 2
// days, keeping the strongest |r|.
struct CorrelationEngine {

  // MARK: - Daily feature bag

  /// One day's worth of features, keyed by feature name. Missing values
  /// stay nil — Pearson skips any pair where either side is nil.
  struct DayFeatures {
    var values: [String: Double] = [:]
  }

  /// Metadata for each feature so the UI can label charts, pick colors,
  /// and decide which axis to clamp.
  struct FeatureSpec {
    let key: String         // matches DayFeatures.values key
    let label: String       // human-readable axis label
    let section: String     // SectionTheme key for accent color
    let unit: String        // e.g. "g", "min", "ppm" — "" for unitless
  }

  /// Predictor → target pair to evaluate. Lag is "predictor at D-lag
  /// influences target at D" — so lag=1 means yesterday's caffeine → today's
  /// sleep score. We sweep lags 0, 1, 2 and keep the strongest |r|.
  struct PairSpec {
    let predictor: FeatureSpec
    let target: FeatureSpec
  }

  // MARK: - Configuration

  static let minN = 8                  // need at least N overlapping days
  static let strongR = 0.35            // |r| threshold for "trusted"
  static let lagsToTest = [0, 1, 2]

  // MARK: - Curated pairs
  //
  // Physiology-informed: same hand-picked set the webapp's dashboard
  // renders. The auto-matrix mode (exhaustive predictor × target) could
  // be added later — for now this gives a calibrated starting point
  // that doesn't drown the user in false positives.
  static func curatedPairs() -> [PairSpec] {
    let predictors: [String: FeatureSpec] = [
      "training_volume":    .init(key: "training_volume",   label: "Training volume",     section: "training",    unit: "k"),
      "cardio_min":         .init(key: "cardio_min",        label: "Cardio minutes",      section: "training",    unit: "min"),
      "mobility_min":       .init(key: "mobility_min",      label: "Mobility minutes",    section: "training",    unit: "min"),
      "protein_g":          .init(key: "protein_g",         label: "Protein",             section: "nutrition",   unit: "g"),
      "fiber_g":            .init(key: "fiber_g",           label: "Fiber",               section: "nutrition",   unit: "g"),
      "kcal":               .init(key: "kcal",              label: "Calories",            section: "nutrition",   unit: "kcal"),
      "last_meal_hour":     .init(key: "last_meal_hour",    label: "Last meal hour",      section: "nutrition",   unit: "h"),
      "caffeine_g":         .init(key: "caffeine_g",        label: "Caffeine grams",      section: "caffeine",    unit: "g"),
      "last_caffeine_hour": .init(key: "last_caffeine_hour",label: "Last caffeine hour",  section: "caffeine",    unit: "h"),
      "cannabis_sessions":  .init(key: "cannabis_sessions", label: "Cannabis sessions",   section: "cannabis",    unit: ""),
      "habit_completion":   .init(key: "habit_completion",  label: "Habit completion",    section: "habits",      unit: "%"),
      "co2_avg":            .init(key: "co2_avg",           label: "Overnight CO₂ avg",   section: "air",         unit: "ppm"),
      "co2_peak":           .init(key: "co2_peak",          label: "Overnight CO₂ peak",  section: "air",         unit: "ppm"),
      "bedroom_temp":       .init(key: "bedroom_temp",      label: "Bedroom temp",        section: "air",         unit: "°C"),
    ]
    let targets: [String: FeatureSpec] = [
      "sleep_score":  .init(key: "sleep_score",  label: "Sleep score",   section: "sleep",   unit: ""),
      "readiness":    .init(key: "readiness",    label: "Readiness",     section: "sleep",   unit: ""),
      "hrv":          .init(key: "hrv",          label: "HRV",           section: "sleep",   unit: "ms"),
      "resting_hr":   .init(key: "resting_hr",   label: "Resting HR",    section: "sleep",   unit: "bpm"),
      "total_h":      .init(key: "total_h",      label: "Sleep hours",   section: "sleep",   unit: "h"),
      "bristol":      .init(key: "bristol",      label: "Bristol score", section: "gut",     unit: ""),
    ]

    let pairs: [(String, String)] = [
      ("training_volume",   "sleep_score"),
      ("cardio_min",        "sleep_score"),
      ("mobility_min",      "sleep_score"),
      ("training_volume",   "hrv"),
      ("cardio_min",        "resting_hr"),
      ("protein_g",         "readiness"),
      ("fiber_g",           "bristol"),
      ("kcal",              "sleep_score"),
      ("last_meal_hour",    "sleep_score"),
      ("caffeine_g",        "sleep_score"),
      ("last_caffeine_hour","sleep_score"),
      ("cannabis_sessions", "sleep_score"),
      ("cannabis_sessions", "hrv"),
      ("habit_completion",  "readiness"),
      ("co2_avg",           "sleep_score"),
      ("co2_peak",          "hrv"),
      ("bedroom_temp",      "sleep_score"),
    ]
    return pairs.compactMap { p in
      guard let pred = predictors[p.0], let tgt = targets[p.1] else { return nil }
      return PairSpec(predictor: pred, target: tgt)
    }
  }

  // MARK: - Build feature table from SwiftData + Oura

  /// Build per-day features over the trailing N-day window. Each section's
  /// own SwiftData entities are aggregated to a single scalar per day;
  /// Oura nights come straight from the `OuraNight` payload the caller
  /// pulled via SeptenaClient.
  static func buildFeatures(
    context: ModelContext,
    ouraNights: [OuraNight],
    days: Int = 30
  ) -> [String: DayFeatures] {
    let calendar = Calendar.current
    let isoFormatter = DateFormatter()
    isoFormatter.calendar = calendar
    isoFormatter.locale = Locale(identifier: "en_US_POSIX")
    isoFormatter.dateFormat = "yyyy-MM-dd"

    let today = calendar.startOfDay(for: Date())
    guard let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
      return [:]
    }
    let cutoffStr = isoFormatter.string(from: cutoff)

    var bag: [String: DayFeatures] = [:]
    func ensure(_ date: String) -> DayFeatures {
      bag[date] ?? DayFeatures()
    }

    // --- Sleep / health (Oura)
    for n in ouraNights where n.date >= cutoffStr {
      var f = ensure(n.date)
      if let v = n.sleepScore     { f.values["sleep_score"] = Double(v) }
      if let v = n.readinessScore { f.values["readiness"]   = Double(v) }
      if let v = n.hrv            { f.values["hrv"]         = Double(v) }
      if let v = n.restingHr      { f.values["resting_hr"]  = Double(v) }
      if let v = n.totalH         { f.values["total_h"]     = v }
      bag[n.date] = f
    }

    // --- Training (ExerciseEntryEntity → strength volume / cardio min / mobility min)
    if let entries = try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      predicate: #Predicate { $0.date >= cutoffStr }
    )) {
      for e in entries {
        var f = ensure(e.date)
        let kind = e.sessionType.lowercased()
        if kind.contains("cardio") {
          f.values["cardio_min", default: 0] += (e.durationMin ?? 0)
        } else if kind.contains("yoga") || kind.contains("mobility") || kind.contains("stretch") {
          f.values["mobility_min", default: 0] += (e.durationMin ?? 0)
        } else {
          // strength volume proxy: weight × reps × sets, in thousands of kg·reps
          let reps = Double(e.reps ?? "") ?? 0
          let sets = Double(e.sets ?? "") ?? 0
          let w    = e.weight ?? 0
          let vol  = w * reps * sets / 1000.0
          if vol > 0 { f.values["training_volume", default: 0] += vol }
        }
        bag[e.date] = f
      }
    }

    // --- Nutrition (NutritionDailySummaryEntity)
    if let summaries = try? context.fetch(FetchDescriptor<NutritionDailySummaryEntity>(
      predicate: #Predicate { $0.date >= cutoffStr }
    )) {
      for s in summaries {
        var f = ensure(s.date)
        if let v = s.proteinG { f.values["protein_g"] = v }
        if let v = s.fiberG   { f.values["fiber_g"]   = v }
        if let v = s.kcal     { f.values["kcal"]      = v }
        if let last = s.lastLoggedAt {
          let hour = Double(calendar.component(.hour, from: last))
                   + Double(calendar.component(.minute, from: last)) / 60.0
          f.values["last_meal_hour"] = hour
        }
        bag[s.date] = f
      }
    }

    // --- Caffeine (CaffeineEventEntity)
    if let events = try? context.fetch(FetchDescriptor<CaffeineEventEntity>(
      predicate: #Predicate { $0.date >= cutoffStr }
    )) {
      for e in events {
        var f = ensure(e.date)
        if let g = e.grams { f.values["caffeine_g", default: 0] += g }
        if let h = hourOfDay(e.time) {
          // Track the latest caffeine hour seen for the day.
          let prev = f.values["last_caffeine_hour"] ?? -1
          f.values["last_caffeine_hour"] = max(prev, h)
        }
        bag[e.date] = f
      }
    }

    // --- Cannabis (CannabisEventEntity)
    if let events = try? context.fetch(FetchDescriptor<CannabisEventEntity>(
      predicate: #Predicate { $0.date >= cutoffStr }
    )) {
      for e in events {
        var f = ensure(e.date)
        f.values["cannabis_sessions", default: 0] += 1
        bag[e.date] = f
      }
    }

    // --- Habits (completion %)
    if let defs = try? context.fetch(FetchDescriptor<HabitDefinitionEntity>()),
       let states = try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
         predicate: #Predicate { $0.date >= cutoffStr }
       )),
       !defs.isEmpty {
      let denom = Double(defs.count)
      let grouped = Dictionary(grouping: states, by: { $0.date })
      for (date, dayStates) in grouped {
        var f = ensure(date)
        let done = Double(dayStates.filter { $0.done }.count)
        f.values["habit_completion"] = (done / denom) * 100.0
        bag[date] = f
      }
    }

    // --- Air (CO2 avg / peak + bedroom temp)
    // AirReadingEntity stores raw timestamped readings; aggregate per day.
    if let readings = try? context.fetch(FetchDescriptor<AirReadingEntity>(
      predicate: #Predicate { $0.date >= cutoffStr }
    )) {
      var byDay: [String: (co2Sum: Double, co2Count: Int, co2Peak: Double, tempSum: Double, tempCount: Int)] = [:]
      for r in readings {
        var agg = byDay[r.date] ?? (0, 0, 0, 0, 0)
        if let co2 = r.co2Ppm {
          agg.co2Sum += Double(co2)
          agg.co2Count += 1
          agg.co2Peak = max(agg.co2Peak, Double(co2))
        }
        if let t = r.tempC {
          agg.tempSum += t
          agg.tempCount += 1
        }
        byDay[r.date] = agg
      }
      for (date, agg) in byDay {
        var f = ensure(date)
        if agg.co2Count > 0 {
          f.values["co2_avg"]  = agg.co2Sum / Double(agg.co2Count)
          f.values["co2_peak"] = agg.co2Peak
        }
        if agg.tempCount > 0 {
          f.values["bedroom_temp"] = agg.tempSum / Double(agg.tempCount)
        }
        bag[date] = f
      }
    }

    // --- Gut (avg Bristol per day)
    if let events = try? context.fetch(FetchDescriptor<GutEventEntity>(
      predicate: #Predicate { $0.date >= cutoffStr }
    )) {
      var byDay: [String: (sum: Int, count: Int)] = [:]
      for e in events {
        var agg = byDay[e.date] ?? (0, 0)
        agg.sum += e.bristol
        agg.count += 1
        byDay[e.date] = agg
      }
      for (date, agg) in byDay where agg.count > 0 {
        var f = ensure(date)
        f.values["bristol"] = Double(agg.sum) / Double(agg.count)
        bag[date] = f
      }
    }

    return bag
  }

  // MARK: - Correlation pass

  /// Compute curated correlations + sort by |r|. Returns rows ready to
  /// render (sorted strongest-first), plus scatter points per pair so the
  /// UI can lazy-grab them without re-walking the bag.
  struct Result {
    let rows: [CorrelationRow]
    let pointsByID: [String: [CorrelationPairPoint]]
  }

  static func run(features: [String: DayFeatures],
                  pairs: [PairSpec] = curatedPairs()) -> Result {
    var rows: [CorrelationRow] = []
    var pointsByID: [String: [CorrelationPairPoint]] = [:]

    for pair in pairs {
      var best: (r: Double, n: Int, lag: Int, points: [CorrelationPairPoint])? = nil
      for lag in lagsToTest {
        let pts = scatterPoints(features: features,
                                predictor: pair.predictor.key,
                                target:    pair.target.key,
                                lag:       lag)
        guard pts.count >= minN else { continue }
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        guard let r = pearson(xs, ys) else { continue }
        if best == nil || abs(r) > abs(best!.r) {
          best = (r, pts.count, lag, pts)
        }
      }
      guard let b = best else { continue }
      let absR = abs(b.r)
      let tier: String = absR >= strongR ? "trusted" : "exploratory"
      let row = CorrelationRow(
        predictor: pair.predictor.label,
        predictorSection: pair.predictor.section,
        predictorUnit: pair.predictor.unit,
        target: pair.target.label,
        targetSection: pair.target.section,
        targetUnit: pair.target.unit,
        r: b.r,
        n: b.n,
        lag: b.lag,
        p: nil,
        tier: tier,
        absR: absR
      )
      rows.append(row)
      pointsByID[row.id] = b.points
    }

    rows.sort { $0.absR > $1.absR }
    return Result(rows: rows, pointsByID: pointsByID)
  }

  // MARK: - Math helpers

  /// Build (predictor at D-lag, target at D) pairs for every date that
  /// has both. Lag 0 = same day; lag 1 = predictor on D-1, target on D.
  static func scatterPoints(features: [String: DayFeatures],
                            predictor: String,
                            target: String,
                            lag: Int) -> [CorrelationPairPoint] {
    let cal = Calendar.current
    let fmt = DateFormatter()
    fmt.calendar = cal
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd"

    var out: [CorrelationPairPoint] = []
    for (targetDate, targetDay) in features {
      guard let y = targetDay.values[target] else { continue }
      let predDateStr: String
      if lag == 0 {
        predDateStr = targetDate
      } else {
        guard let d = fmt.date(from: targetDate),
              let shifted = cal.date(byAdding: .day, value: -lag, to: d) else { continue }
        predDateStr = fmt.string(from: shifted)
      }
      guard let predDay = features[predDateStr],
            let x = predDay.values[predictor] else { continue }
      out.append(CorrelationPairPoint(date: targetDate, x: x, y: y))
    }
    return out.sorted { $0.date < $1.date }
  }

  static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
    guard xs.count == ys.count, xs.count >= 3 else { return nil }
    let n = Double(xs.count)
    let mx = xs.reduce(0, +) / n
    let my = ys.reduce(0, +) / n
    var num = 0.0, dx2 = 0.0, dy2 = 0.0
    for i in 0..<xs.count {
      let dx = xs[i] - mx
      let dy = ys[i] - my
      num += dx * dy
      dx2 += dx * dx
      dy2 += dy * dy
    }
    let denom = (dx2 * dy2).squareRoot()
    guard denom > 0 else { return nil }
    return num / denom
  }

  private static func hourOfDay(_ hhmm: String) -> Double? {
    let parts = hhmm.split(separator: ":")
    guard let h = parts.first.flatMap({ Double($0) }) else { return nil }
    let m = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
    return h + m / 60.0
  }
}
