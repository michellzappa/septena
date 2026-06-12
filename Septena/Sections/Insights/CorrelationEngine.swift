import Foundation
import SwiftData

// CorrelationEngine — client-side cross-section correlation discovery.
//
// Mirrors septena-app's /insights page math (api/insights.py + the
// components/insights-dashboard.tsx prior logic):
//   • Pearson r with lag-aware alignment (0, 1, 2-day lags; keep best |r|)
//   • Slope (per +1 unit of predictor) from the same regression
//   • Permutation p-values (200 shuffles, deterministic seed) — used to
//     classify trusted vs exploratory
//   • Tertile bucket analysis on x-sorted data → centerX, meanY, n per
//     bucket; monotonicity check across buckets
//   • Physiological priors per pair: if r contradicts the expected
//     direction, demote to exploratory and surface a confound badge
//   • Binary predictor handling (habits / supplements taken/not): require
//     ≥ MIN_STATE_N samples in the minority state to avoid 28-vs-2 false
//     positives
//
// Reads from the local SwiftData store (CloudKit-mirrored) for every
// section except Oura sleep, which still pulls through the existing
// /api/health/oura read endpoint. No new backend endpoint — keeps us
// aligned with the CloudKit migration posture (memory: project_cloudkit
// _migration).
struct CorrelationEngine {

  // MARK: - Configuration (match webapp constants)

  static let minN = 15
  static let strongR = 0.35
  static let strongP = 0.05
  static let minStateN = 4
  static let permutations = 200
  static let lagsToTest = [0, 1, 2]

  // MARK: - Result memo
  //
  // A full run is pairs × lags × (regression + 200-permutation p) over up to
  // a year of features — far too expensive to repeat on every drawer open.
  // Cache the last result and serve it while nothing it derives from has
  // moved: same window, same day (windows are today-anchored), and no data
  // change since it was computed. Any in-app log bumps the stamp via the
  // scoped/unscoped `.septenaDataChanged` posts; `.septenaOuraChanged`
  // covers provider ingests that bypass the generic notification.

  @MainActor private static var cache:
    (days: Int, today: String, stamp: Int, result: Result)?
  @MainActor private static var dataStamp = 0
  @MainActor private static var stampObserversInstalled = false

  @MainActor private static func installStampObserversIfNeeded() {
    guard !stampObserversInstalled else { return }
    stampObserversInstalled = true
    for name: Notification.Name in [.septenaDataChanged, .septenaOuraChanged] {
      NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated { dataStamp += 1 }
      }
    }
  }

  /// The memoized result for `days`, if still current — lets the caller skip
  /// the Oura fetch AND the stats run on a same-day reopen. Nil after any
  /// data change, day rollover, or for a window that wasn't the last one run.
  @MainActor
  static func cachedResult(days: Int) -> Result? {
    installStampObserversIfNeeded()
    guard let c = cache, c.days == days,
          c.today == SeptenaDate.today, c.stamp == dataStamp else { return nil }
    return c.result
  }

  // MARK: - Feature spec / pair spec

  enum Direction { case positive, negative, unknown
    var symbol: String? { self == .positive ? "+" : (self == .negative ? "-" : nil) }
  }

  struct FeatureSpec: Hashable {
    let key: String
    let label: String
    let section: String
    let unit: String
    let binary: Bool
  }

  struct PairSpec: Identifiable {
    let predictor: FeatureSpec
    let target: FeatureSpec
    let lagPreference: Int?   // if non-nil, only this lag is evaluated
    let expected: Direction
    let titleOverride: String?
    var id: String {
      "\(predictor.key)→\(target.key)@\(lagPreference.map(String.init) ?? "auto")"
    }
    var title: String {
      titleOverride ?? "\(predictor.label) → \(target.label)"
    }
  }

  // MARK: - Day features

  struct DayFeatures {
    var values: [String: Double] = [:]
  }

  // MARK: - Output

  /// One evaluated row. Mirrors the on-the-wire shape from the webapp,
  /// extended with slope, monotonicity, confound flag, and a buckets
  /// summary so the UI can render the dense tile without re-walking the
  /// points.
  struct EvaluatedPair: Identifiable {
    let spec: PairSpec
    let r: Double
    let n: Int
    let lag: Int
    let p: Double
    let slope: Double
    let meanX: Double
    let meanY: Double
    let buckets: [Bucket]
    let monotonic: Bool
    let expectedSign: Direction
    let confound: Bool   // r sign contradicts expected (with |r| >= 0.2)
    let binary: Bool
    let stateMinority: Int
    let stateMajority: Int
    let tier: Tier
    /// Benjamini-Hochberg FDR-adjusted p across the whole candidate set.
    /// `.trusted` requires this < `strongP`, not just the raw permutation p.
    let qValue: Double
    let points: [CorrelationPairPoint]
    var id: String { spec.id }
    var absR: Double { abs(r) }
  }

  struct Bucket { let centerX: Double; let meanY: Double; let n: Int; let xMin: Double; let xMax: Double }

  enum Tier: String { case trusted, exploratory, insufficient }

  struct Result {
    let evaluated: [EvaluatedPair]            // n >= minN (trusted + exploratory)
    let insufficient: [InsufficientPair]      // 1 <= n < minN
    let supplementsTable: [SupplementSleepRow]
    let coveredDays: Int
    let dateRange: ClosedRange<String>?
  }

  struct InsufficientPair: Identifiable {
    let spec: PairSpec
    let n: Int
    var id: String { spec.id }
  }

  /// Supplement → sleep score taken-vs-off breakdown.
  struct SupplementSleepRow: Identifiable {
    let supplementID: String
    let label: String
    let emoji: String
    let takenMean: Double
    let takenN: Int
    let offMean: Double
    let offN: Int
    var delta: Double { takenMean - offMean }
    var meetsBar: Bool { abs(delta) >= 3 && takenN >= 10 && offN >= 10 }
    var strength: String {
      let a = abs(delta)
      if !meetsBar { return "below bar" }
      return a >= 5 ? "strong" : "moderate"
    }
    var id: String { supplementID }
  }

  // MARK: - Public entry point

  @MainActor
  static func runEverything(
    context: ModelContext,
    ouraNights: [OuraNight],
    days: Int = 365
  ) async -> Result {
    if let cached = cachedResult(days: days) { return cached }
    // Snapshot the stamp BEFORE extracting, so a write that lands mid-run
    // invalidates this result instead of being silently absorbed into it.
    let stampAtStart = dataStamp
    let extraction = extract(context: context, ouraNights: ouraNights, days: days)

    // The universe is "everything you actively track," not a curated list.
    // Active sections come straight from the enabled SectionEntity set; an
    // empty set (fresh account before the mirror hydrates) means "all."
    let activeSections: Set<String> = {
      let rows = (try? context.fetch(FetchDescriptor<SectionEntity>())) ?? []
      return Set(rows.filter { $0.isEnabled }.map { $0.id })
    }()

    // Pull plugin-declared daily features from active sections (GitHub today;
    // any section that adopts `correlationFeatures` flows in with no engine
    // edit). Merge their series into the bag and their metadata into the
    // catalog. Built-in features stay catalogued in `legacyCatalog`.
    var features = extraction.features
    var catalog = featureCatalog(habits: extraction.habits,
                                 supplements: extraction.supplements)
    for plugin in SectionRegistry.all
    where activeSections.isEmpty || activeSections.contains(plugin.manifest.key) {
      for pf in plugin.correlationFeatures(context: context) {
        catalog[pf.key] = CatalogEntry(label: pf.label, section: pf.section,
                                       unit: pf.unit, role: pf.role,
                                       distribution: pf.distribution)
        for (date, value) in pf.series {
          var f = features[date] ?? DayFeatures()
          f.values[pf.key] = value
          features[date] = f
        }
      }
    }

    // Keys with actual data this window → the eligible feature set.
    var availableKeys = Set<String>()
    for (_, f) in features { availableKeys.formUnion(f.values.keys) }

    // Auto-pair every eligible predictor against every eligible OUTCOME from
    // a different section; curated specs are overlaid as direction/lag hints,
    // not as the gate. (Subsumes the old curated + autoBinary lists.)
    let allPairs = autoPairs(catalog: catalog,
                             availableKeys: availableKeys,
                             activeSections: activeSections,
                             curated: curatedPairs())

    // Everything above touched SwiftData / the plugin registry, so it stayed
    // on the main actor — it's predicate-bounded fetches, cheap. Everything
    // below is pure math over the extracted value types, and it's the
    // expensive part (pairs × lags × regression + 200-permutation p-values),
    // so it runs detached instead of freezing the UI for the whole run.
    let featuresSnapshot = features
    let supplements = extraction.supplements
    let result = await Task.detached(priority: .userInitiated) {
      evaluateStatistics(features: featuresSnapshot,
                         allPairs: allPairs,
                         supplements: supplements)
    }.value

    cache = (days: days, today: SeptenaDate.today,
             stamp: stampAtStart, result: result)
    return result
  }

  /// The statistics pass — pure functions over the extracted feature series.
  /// No SwiftData, no UI types; safe to run off the main actor.
  private nonisolated static func evaluateStatistics(
    features: [String: DayFeatures],
    allPairs: [PairSpec],
    supplements: [(id: String, label: String, emoji: String)]
  ) -> Result {
    var evaluated: [EvaluatedPair] = []
    var insufficient: [InsufficientPair] = []
    var seen = Set<String>()

    for spec in allPairs {
      if seen.contains(spec.id) { continue }
      seen.insert(spec.id)

      // For binary predictors with a state-N issue, treat as insufficient.
      let lagsForThis: [Int] = spec.lagPreference.map { [$0] } ?? lagsToTest
      var best: (lag: Int, points: [CorrelationPairPoint])? = nil

      for lag in lagsForThis {
        let pts = scatterPoints(features: features,
                                predictor: spec.predictor.key,
                                target: spec.target.key,
                                lag: lag)
        if best == nil || pts.count > best!.points.count {
          best = (lag, pts)
        }
      }
      let points = best?.points ?? []
      let lag = best?.lag ?? (spec.lagPreference ?? 0)

      // Insufficient n
      if points.count < minN {
        if points.count > 0 {
          insufficient.append(InsufficientPair(spec: spec, n: points.count))
        }
        continue
      }

      // Binary predictor: enforce minority-state sample count
      var binary = spec.predictor.binary
      var stateMinority = 0
      var stateMajority = 0
      let xs = points.map(\.x)
      let ys = points.map(\.y)
      if !binary { binary = isBinary(xs) }
      if binary {
        let ones = xs.filter { $0 > 0.5 }.count
        let zeros = xs.count - ones
        stateMinority = min(ones, zeros)
        stateMajority = max(ones, zeros)
        if stateMinority < minStateN {
          insufficient.append(InsufficientPair(spec: spec, n: points.count))
          continue
        }
      }

      // Best-lag selection: evaluate r at each candidate lag, keep max |r|.
      var pickedR: Double? = nil
      var pickedLag = lag
      var pickedPoints = points
      var pickedSlope = 0.0
      var pickedMeanX = 0.0
      var pickedMeanY = 0.0
      for cand in lagsForThis {
        let candPts = scatterPoints(features: features,
                                    predictor: spec.predictor.key,
                                    target: spec.target.key,
                                    lag: cand)
        guard candPts.count >= minN else { continue }
        if binary {
          let cxs = candPts.map(\.x)
          let ones = cxs.filter { $0 > 0.5 }.count
          let zeros = cxs.count - ones
          if min(ones, zeros) < minStateN { continue }
        }
        let cxs = candPts.map(\.x)
        let cys = candPts.map(\.y)
        guard let stats = regression(cxs, cys) else { continue }
        if pickedR == nil || abs(stats.r) > abs(pickedR!) {
          pickedR = stats.r
          pickedLag = cand
          pickedPoints = candPts
          pickedSlope = stats.slope
          pickedMeanX = stats.meanX
          pickedMeanY = stats.meanY
        }
      }
      guard let r = pickedR else {
        insufficient.append(InsufficientPair(spec: spec, n: points.count))
        continue
      }

      // Permutation p
      let pVal = permutationP(xs: pickedPoints.map(\.x),
                              ys: pickedPoints.map(\.y),
                              rObs: r)

      // Tertile buckets + monotonicity
      let buckets = tertileBuckets(points: pickedPoints)
      let monotonic = isMonotonic(buckets: buckets)

      // Confound check vs physiological prior
      var confound = false
      if let exp = spec.expected.symbol, abs(r) >= 0.2 {
        let sign = r >= 0 ? "+" : "-"
        if sign != exp { confound = true }
      }

      // Provisional tier — finalised in the FDR pass below, once every
      // candidate's p-value is known (trusted gates on the q-value, not p).
      evaluated.append(EvaluatedPair(
        spec: spec,
        r: r,
        n: pickedPoints.count,
        lag: pickedLag,
        p: pVal,
        slope: pickedSlope,
        meanX: pickedMeanX,
        meanY: pickedMeanY,
        buckets: buckets,
        monotonic: monotonic,
        expectedSign: spec.expected,
        confound: confound,
        binary: binary,
        stateMinority: stateMinority,
        stateMajority: stateMajority,
        tier: .exploratory,
        qValue: 1.0,
        points: pickedPoints
      ))
    }

    // FDR across the full candidate set. Trusted = strong, monotonic,
    // non-confounded AND survives Benjamini-Hochberg (q < strongP). With a
    // wide auto-paired universe this is what keeps the top tier honest —
    // raw p < 0.05 alone would mint ~1-in-20 false positives.
    let qMap = benjaminiHochberg(evaluated.map { (id: $0.id, p: $0.p) })
    evaluated = evaluated.map { e in
      let q = qMap[e.id] ?? 1.0
      let trusted = e.absR >= strongR && e.monotonic && !e.confound && q < strongP
      return EvaluatedPair(
        spec: e.spec, r: e.r, n: e.n, lag: e.lag, p: e.p, slope: e.slope,
        meanX: e.meanX, meanY: e.meanY, buckets: e.buckets, monotonic: e.monotonic,
        expectedSign: e.expectedSign, confound: e.confound, binary: e.binary,
        stateMinority: e.stateMinority, stateMajority: e.stateMajority,
        tier: trusted ? .trusted : .exploratory, qValue: q, points: e.points)
    }

    evaluated.sort { $0.absR > $1.absR }

    // Supplements → sleep score table
    let supplementsTable = supplementsSleepTable(
      features: features,
      supplements: supplements
    )

    let dateKeys = features.keys.sorted()
    let dateRange = dateKeys.first.flatMap { lo in
      dateKeys.last.map { hi in lo...hi }
    }

    return Result(
      evaluated: evaluated,
      insufficient: insufficient.sorted { $0.n > $1.n },
      supplementsTable: supplementsTable,
      coveredDays: features.count,
      dateRange: dateRange
    )
  }

  // MARK: - Extraction

  struct Extraction {
    let features: [String: DayFeatures]
    let habits: [(id: String, label: String, emoji: String)]
    let supplements: [(id: String, label: String, emoji: String)]
  }

  private static func extract(
    context: ModelContext,
    ouraNights: [OuraNight],
    days: Int
  ) -> Extraction {
    let calendar = Calendar.current
    let fmt = isoFormatter
    let today = calendar.startOfDay(for: Date())
    guard let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
      return Extraction(features: [:], habits: [], supplements: [])
    }
    let cutoffStr = fmt.string(from: cutoff)

    var bag: [String: DayFeatures] = [:]

    // --- Oura (sleep / health)
    for n in ouraNights where n.date >= cutoffStr {
      var f = bag[n.date] ?? DayFeatures()
      if let v = n.sleepScore     { f.values["sleep_score"] = Double(v) }
      if let v = n.readinessScore { f.values["readiness"]   = Double(v) }
      if let v = n.hrv            { f.values["hrv"]         = Double(v) }
      if let v = n.restingHr      { f.values["resting_hr"]  = Double(v) }
      if let v = n.totalH         { f.values["total_h"]     = v }
      if let v = n.deepH          { f.values["deep_h"]      = v }
      if let v = n.remH           { f.values["rem_h"]       = v }
      bag[n.date] = f
    }

    // --- Training
    if let entries = try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      predicate: #Predicate { $0.date >= cutoffStr }
    )) {
      for e in entries {
        var f = bag[e.date] ?? DayFeatures()
        let kind = e.sessionType.lowercased()
        if kind.contains("cardio") {
          f.values["cardio_min", default: 0] += (e.durationMin ?? 0)
        } else if kind.contains("yoga") || kind.contains("mobility") || kind.contains("stretch") {
          f.values["mobility_min", default: 0] += (e.durationMin ?? 0)
        } else {
          let reps = Double(e.reps ?? "") ?? 0
          let sets = Double(e.sets ?? "") ?? 0
          let w    = e.weight ?? 0
          let vol  = w * reps * sets / 1000.0
          if vol > 0 { f.values["training_volume", default: 0] += vol }
        }
        bag[e.date] = f
      }
    }

    // --- Nutrition (daily summaries — protein, carbs, fat, fiber, kcal,
    //     last meal hour, fasting window)
    if let summaries = try? context.fetch(FetchDescriptor<NutritionDailySummaryEntity>(
      predicate: #Predicate { $0.date >= cutoffStr }
    )) {
      // For fasting window we need consecutive day pairs — gather sorted.
      let sorted = summaries.sorted { $0.date < $1.date }
      for (idx, s) in sorted.enumerated() {
        var f = bag[s.date] ?? DayFeatures()
        if let v = s.proteinG { f.values["protein_g"] = v }
        if let v = s.carbsG   { f.values["carbs_g"]   = v }
        if let v = s.fatG     { f.values["fat_g"]     = v }
        if let v = s.fiberG   { f.values["fiber_g"]   = v }
        if let v = s.kcal     { f.values["kcal"]      = v }
        if let last = s.lastLoggedAt {
          let hour = decimalHour(date: last, calendar: calendar)
          f.values["last_meal_hour"] = hour
        }
        // Fasting window: hours between yesterday's last meal and today's
        // first meal. Caps at 24h to keep one bad data day from skewing.
        if let first = s.firstLoggedAt, idx > 0,
           let prevLast = sorted[idx - 1].lastLoggedAt {
          let secs = first.timeIntervalSince(prevLast)
          if secs > 0 {
            let h = min(24.0, secs / 3600.0)
            f.values["fasting_window"] = h
          }
        }
        bag[s.date] = f
      }
    }

    // --- Habits (completion % + per-habit binary)
    var habitsMeta: [(id: String, label: String, emoji: String)] = []
    if let defs = try? context.fetch(FetchDescriptor<HabitDefinitionEntity>()) {
      habitsMeta = defs.map { ($0.id, $0.title, $0.emoji ?? "") }
                       .sorted { $0.label < $1.label }
    }
    if let states = try? context.fetch(FetchDescriptor<HabitDayStateEntity>(
      predicate: #Predicate { $0.date >= cutoffStr }
    )), !habitsMeta.isEmpty {
      let denom = Double(habitsMeta.count)
      let grouped = Dictionary(grouping: states, by: { $0.date })
      // Iterate over EVERY date in the window so days with no state rows
      // still count as 0 done.
      var date = cutoffStr
      let endStr = fmt.string(from: today)
      while date <= endStr {
        var f = bag[date] ?? DayFeatures()
        let dayStates = grouped[date] ?? []
        let done = Double(dayStates.filter { $0.done }.count)
        f.values["habit_completion"] = (done / denom) * 100.0
        // Per-habit binary
        let doneSet = Set(dayStates.filter { $0.done }.map { $0.habitID })
        for h in habitsMeta {
          f.values["habit:\(h.id)"] = doneSet.contains(h.id) ? 1.0 : 0.0
        }
        bag[date] = f
        guard let next = calendar.date(byAdding: .day, value: 1, to: fmt.date(from: date) ?? today) else { break }
        date = fmt.string(from: next)
      }
    }

    // --- Supplements (per-supplement binary)
    var suppsMeta: [(id: String, label: String, emoji: String)] = []
    if let defs = try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>()) {
      suppsMeta = defs.map { ($0.id, $0.title, $0.emoji ?? "") }
                      .sorted { $0.label < $1.label }
    }
    if let states = try? context.fetch(FetchDescriptor<SupplementDayStateEntity>(
      predicate: #Predicate { $0.date >= cutoffStr }
    )), !suppsMeta.isEmpty {
      let grouped = Dictionary(grouping: states, by: { $0.date })
      var date = cutoffStr
      let endStr = fmt.string(from: today)
      while date <= endStr {
        var f = bag[date] ?? DayFeatures()
        let dayStates = grouped[date] ?? []
        let doneSet = Set(dayStates.filter { $0.done }.map { $0.supplementID })
        for s in suppsMeta {
          f.values["supp:\(s.id)"] = doneSet.contains(s.id) ? 1.0 : 0.0
        }
        bag[date] = f
        guard let next = calendar.date(byAdding: .day, value: 1, to: fmt.date(from: date) ?? today) else { break }
        date = fmt.string(from: next)
      }
    }

    // --- Gut (avg Bristol per day + movements count)
    if let events = try? context.fetch(FetchDescriptor<GutEventEntity>(
      predicate: #Predicate { $0.date >= cutoffStr }
    )) {
      var byDay: [String: (sum: Int, count: Int)] = [:]
      for e in events {
        var agg = byDay[e.date] ?? (0, 0)
        agg.sum += e.bristol; agg.count += 1
        byDay[e.date] = agg
      }
      for (date, agg) in byDay where agg.count > 0 {
        var f = bag[date] ?? DayFeatures()
        f.values["bristol"] = Double(agg.sum) / Double(agg.count)
        f.values["gut_movements"] = Double(agg.count)
        bag[date] = f
      }
    }

    // --- 3-day rolling fiber (smoothed predictor for gut)
    let datesSorted = bag.keys.sorted()
    for (i, d) in datesSorted.enumerated() {
      var window: [Double] = []
      for k in max(0, i - 2)...i {
        if let v = bag[datesSorted[k]]?.values["fiber_g"] { window.append(v) }
      }
      if window.count >= 2 {
        var f = bag[d] ?? DayFeatures()
        f.values["fiber_g_3d"] = window.reduce(0, +) / Double(window.count)
        bag[d] = f
      }
    }

    return Extraction(features: bag, habits: habitsMeta, supplements: suppsMeta)
  }

  // MARK: - Curated pairs (port of insights-dashboard.tsx lines 933-953)

  static func curatedPairs() -> [PairSpec] {
    // Predictors
    let trainingVol = FeatureSpec(key: "training_volume",   label: "Training volume",   section: "training",  unit: "k",   binary: false)
    let cardioMin   = FeatureSpec(key: "cardio_min",        label: "Cardio min",        section: "training",  unit: "min", binary: false)
    let mobilityMin = FeatureSpec(key: "mobility_min",      label: "Mobility min",      section: "training",  unit: "min", binary: false)
    let proteinG    = FeatureSpec(key: "protein_g",         label: "Protein",           section: "nutrition", unit: "g",   binary: false)
    let fiberG      = FeatureSpec(key: "fiber_g",           label: "Fiber",             section: "nutrition", unit: "g",   binary: false)
    let fiber3d     = FeatureSpec(key: "fiber_g_3d",        label: "Fiber 3-day avg",   section: "nutrition", unit: "g/d", binary: false)
    let kcalF       = FeatureSpec(key: "kcal",              label: "Calories",          section: "nutrition", unit: "kcal",binary: false)
    let lastMealH   = FeatureSpec(key: "last_meal_hour",    label: "Last meal hour",    section: "nutrition", unit: "h",   binary: false)
    let fasting     = FeatureSpec(key: "fasting_window",    label: "Fasting window",    section: "nutrition", unit: "h",   binary: false)
    let habitPct    = FeatureSpec(key: "habit_completion",  label: "Habit completion",  section: "habits",    unit: "%",   binary: false)
    let totalH      = FeatureSpec(key: "total_h",           label: "Sleep hours",       section: "sleep",     unit: "h",   binary: false)
    let sleepScore  = FeatureSpec(key: "sleep_score",       label: "Sleep score",       section: "sleep",     unit: "",    binary: false)

    // Targets
    let tSleepScore = FeatureSpec(key: "sleep_score",  label: "Sleep score",   section: "sleep",   unit: "",    binary: false)
    let tReadiness  = FeatureSpec(key: "readiness",    label: "Readiness",     section: "sleep",   unit: "",    binary: false)
    let tHRV        = FeatureSpec(key: "hrv",          label: "HRV",           section: "sleep",   unit: "ms",  binary: false)
    let tRHR        = FeatureSpec(key: "resting_hr",   label: "Resting HR",    section: "sleep",   unit: "bpm", binary: false)
    let tBristol    = FeatureSpec(key: "bristol",      label: "Bristol",       section: "gut",     unit: "",    binary: false)
    let tTrainNext  = FeatureSpec(key: "training_volume", label: "Next-day training", section: "training", unit: "k", binary: false)

    func P(_ predictor: FeatureSpec, _ target: FeatureSpec, _ lag: Int?, _ expected: Direction, _ title: String? = nil) -> PairSpec {
      PairSpec(predictor: predictor, target: target, lagPreference: lag, expected: expected, titleOverride: title)
    }

    return [
      P(trainingVol, tSleepScore, 0, .positive),
      P(totalH,      tHRV,        0, .positive),
      P(proteinG,    tReadiness,  0, .positive),
      P(sleepScore,  tTrainNext,  1, .positive, "Sleep score → Next-day training"),
      P(fasting,     tReadiness,  0, .unknown),
      P(cardioMin,   tRHR,        0, .negative),
      P(lastMealH,   tSleepScore, 0, .negative),
      P(habitPct,    tReadiness,  0, .positive),
      P(trainingVol, tSleepScore, 0, .positive, "Strength volume → Sleep score"),
      P(cardioMin,   tSleepScore, 0, .positive),
      P(mobilityMin, tSleepScore, 0, .positive),
      P(fiberG,      tBristol,    1, .positive, "Fiber (prev day) → Bristol"),
      P(fiber3d,     tBristol,    1, .positive),
      P(kcalF,       tSleepScore, 0, .unknown),
    ]
  }

  // (Removed `autoBinaryPairs` — habit/supplement binaries are now ordinary
  // `.lever`/`.binary` catalog features (`featureCatalog`) and auto-pair
  // against *every* active outcome, not just the three sleep targets. The
  // minority-state gate still applies in the evaluation loop.)

  // MARK: - Supplements → sleep score table

  private static func supplementsSleepTable(
    features: [String: DayFeatures],
    supplements: [(id: String, label: String, emoji: String)]
  ) -> [SupplementSleepRow] {
    var rows: [SupplementSleepRow] = []
    for s in supplements {
      var takenScores: [Double] = []
      var offScores: [Double] = []
      for (_, f) in features {
        guard let score = f.values["sleep_score"] else { continue }
        guard let v = f.values["supp:\(s.id)"] else { continue }
        if v > 0.5 { takenScores.append(score) }
        else       { offScores.append(score) }
      }
      guard takenScores.count >= 3, offScores.count >= 3 else { continue }
      let takenMean = takenScores.reduce(0, +) / Double(takenScores.count)
      let offMean   = offScores.reduce(0, +) / Double(offScores.count)
      rows.append(SupplementSleepRow(
        supplementID: s.id,
        label: s.label,
        emoji: s.emoji,
        takenMean: takenMean,
        takenN: takenScores.count,
        offMean: offMean,
        offN: offScores.count
      ))
    }
    rows.sort { abs($0.delta) > abs($1.delta) }
    return rows
  }

  // MARK: - Markdown report (port of "Copy Report")

  static func markdownReport(from result: Result) -> String {
    var lines: [String] = []
    lines.append("# Septena Insights")
    if let range = result.dateRange {
      lines.append("Window: \(range.lowerBound) → \(range.upperBound) (\(result.coveredDays) days)")
    }
    lines.append("")
    lines.append("## Context")
    lines.append("- User does not drink alcohol — don't suggest it as a confound.")
    lines.append("- User's days are largely identical (low day-of-week variance).")
    lines.append("- Trusted = n ≥ \(minN), |r| ≥ \(strongR.decimalString(2)), monotonic buckets, sign matches physiology.")
    lines.append("- Exploratory = n ≥ \(minN) but weak r, non-monotonic, or contradicts physiology.")
    lines.append("")

    func chartBlock(_ e: EvaluatedPair) -> String {
      var out: [String] = []
      out.append("### \(e.spec.title)")
      out.append("- n=\(e.n), lag=\(e.lag)d, r=\(formatR(e.r)) (\(strengthLabel(e.r))), p=\(e.p.decimalString(3))")
      let xUnit = e.spec.predictor.unit.isEmpty ? "" : " \(e.spec.predictor.unit)"
      let yUnit = e.spec.target.unit.isEmpty ? "" : " \(e.spec.target.unit)"
      out.append("- slope: \(e.slope >= 0 ? "+" : "")\(e.slope.decimalString(3))\(yUnit)/\(xUnit.isEmpty ? "1" : xUnit.trimmingCharacters(in: .whitespaces)); x̄=\(e.meanX.decimalString(2)); ȳ=\(e.meanY.decimalString(2))")
      if !e.buckets.isEmpty {
        let parts = zip(["Low", "Mid", "High"], e.buckets).map { name, b in
          "\(name)(x̄=\(b.centerX.decimalString(2)), n=\(b.n)) → ȳ=\(b.meanY.decimalString(2))"
        }
        out.append("- buckets: \(parts.joined(separator: " · "))")
      }
      if e.confound {
        out.append("- ⚠️ Direction contradicts physiology — likely confound or reverse causation.")
      }
      return out.joined(separator: "\n")
    }

    let trusted = result.evaluated.filter { $0.tier == .trusted }
    let exploratory = result.evaluated.filter { $0.tier == .exploratory }
    if !trusted.isEmpty {
      lines.append("## Trusted signals")
      for e in trusted { lines.append(chartBlock(e)); lines.append("") }
    }
    if !exploratory.isEmpty {
      lines.append("## Exploratory")
      for e in exploratory { lines.append(chartBlock(e)); lines.append("") }
    }
    if !result.supplementsTable.isEmpty {
      lines.append("## Supplements → Sleep score")
      for r in result.supplementsTable {
        let arrow = r.delta >= 0 ? "+" : ""
        let prefix = r.emoji.isEmpty ? "" : "\(r.emoji) "
        lines.append("- \(prefix)\(r.label): taken \(r.takenMean.decimalString()) (\(r.takenN)d) · off \(r.offMean.decimalString()) (\(r.offN)d) · Δ=\(arrow)\(r.delta.decimalString()) · \(r.strength)")
      }
      lines.append("")
    }
    if !result.insufficient.isEmpty {
      lines.append("## Insufficient data (n < \(minN))")
      for i in result.insufficient {
        lines.append("- \(i.spec.title) — n=\(i.n)")
      }
      lines.append("")
    }
    lines.append("## Asks")
    lines.append("- What signals here look most actionable?")
    lines.append("- Any plausible confounds I should investigate?")
    return lines.joined(separator: "\n")
  }

  // MARK: - Helpers

  static func strengthLabel(_ r: Double) -> String {
    let a = abs(r)
    let kind = r >= 0 ? "positive" : "negative"
    if a >= 0.5  { return "strong \(kind)" }
    if a >= strongR { return "moderate \(kind)" }
    if a >= 0.2  { return "weak \(kind)" }
    return "noise"
  }

  static func formatR(_ r: Double) -> String {
    "\(r >= 0 ? "+" : "")\(r.decimalString(2))"
  }

  /// Build (predictor at D-lag, target at D) points. Lag 0 = same day.
  static func scatterPoints(features: [String: DayFeatures],
                            predictor: String,
                            target: String,
                            lag: Int) -> [CorrelationPairPoint] {
    let cal = Calendar.current
    let fmt = isoFormatter
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

  /// Returns (r, slope per +1 unit, mean x, mean y) for a Pearson regression.
  static func regression(_ xs: [Double], _ ys: [Double]) -> (r: Double, slope: Double, meanX: Double, meanY: Double)? {
    guard xs.count == ys.count, xs.count >= 3 else { return nil }
    let n = Double(xs.count)
    let mx = xs.reduce(0, +) / n
    let my = ys.reduce(0, +) / n
    var num = 0.0, dx2 = 0.0, dy2 = 0.0
    for i in 0..<xs.count {
      let dx = xs[i] - mx
      let dy = ys[i] - my
      num += dx * dy; dx2 += dx * dx; dy2 += dy * dy
    }
    let denom = (dx2 * dy2).squareRoot()
    guard denom > 0, dx2 > 0 else { return nil }
    return (num / denom, num / dx2, mx, my)
  }

  /// Permutation p-value: shuffle ys K times, count |r_shuffled| ≥ |r_obs|.
  /// Uses a deterministic seed so identical inputs produce identical p
  /// values across runs (matches the webapp's `random.Random(0xC0FFEE)`).
  static func permutationP(xs: [Double], ys: [Double], rObs: Double) -> Double {
    guard xs.count == ys.count, xs.count >= 3 else { return 1.0 }
    var rng = SplitMix64(seed: 0xC0FFEE)
    var hits = 0
    let absObs = abs(rObs)
    var shuffled = ys
    for _ in 0..<permutations {
      // Fisher–Yates with seeded RNG
      for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
        let j = Int(rng.next() % UInt64(i + 1))
        shuffled.swapAt(i, j)
      }
      if let stats = regression(xs, shuffled), abs(stats.r) >= absObs {
        hits += 1
      }
    }
    return Double(hits + 1) / Double(permutations + 1)
  }

  /// Tertile buckets: split x-sorted data into 3 equal-count bins.
  /// Returns empty if n < 6 or fewer than 3 distinct x values.
  static func tertileBuckets(points: [CorrelationPairPoint]) -> [Bucket] {
    guard points.count >= 6 else { return [] }
    let sorted = points.sorted { $0.x < $1.x }
    let distinctXs = Set(sorted.map(\.x))
    guard distinctXs.count >= 3 else { return [] }
    let n = sorted.count
    let cut1 = n / 3
    let cut2 = (2 * n) / 3
    let bins: [[CorrelationPairPoint]] = [
      Array(sorted[0..<cut1]),
      Array(sorted[cut1..<cut2]),
      Array(sorted[cut2..<n]),
    ]
    return bins.compactMap { b -> Bucket? in
      guard !b.isEmpty else { return nil }
      let xs = b.map(\.x); let ys = b.map(\.y)
      return Bucket(
        centerX: xs.reduce(0, +) / Double(xs.count),
        meanY:   ys.reduce(0, +) / Double(ys.count),
        n:       b.count,
        xMin:    xs.min() ?? 0,
        xMax:    xs.max() ?? 0
      )
    }
  }

  static func isMonotonic(buckets: [Bucket]) -> Bool {
    guard buckets.count >= 3 else { return false }
    let ys = buckets.map(\.meanY)
    let increasing = ys[0] <= ys[1] && ys[1] <= ys[2]
    let decreasing = ys[0] >= ys[1] && ys[1] >= ys[2]
    return increasing || decreasing
  }

  static func isBinary(_ xs: [Double]) -> Bool {
    Set(xs.map { Int(($0 * 1000).rounded()) }).count <= 2
  }

  private static func hourOfDay(_ hhmm: String) -> Double? {
    let parts = hhmm.split(separator: ":")
    guard let h = parts.first.flatMap({ Double($0) }) else { return nil }
    let m = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
    return h + m / 60.0
  }

  private static func decimalHour(date: Date, calendar: Calendar) -> Double {
    Double(calendar.component(.hour, from: date))
      + Double(calendar.component(.minute, from: date)) / 60.0
  }

  static let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .iso8601)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()
}

// MARK: - Deterministic RNG (SplitMix64)

private struct SplitMix64 {
  var state: UInt64
  init(seed: UInt64) { self.state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E3779B97F4A7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
  }
}
