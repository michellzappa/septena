import Foundation

// Correlation feature model — the vocabulary the discovery engine reasons
// over. A "feature" is one daily numeric series a section contributes
// (date → value), tagged with the metadata the engine needs to pair and
// rank it WITHOUT a hand-written list of relationships.
//
// Phase 0 of the "smart, not predetermined" correlations refactor:
//   • Universe = every ACTIVE section's features, auto-paired — not a
//     curated pair list. Built-in sections are catalogued here; new
//     sections opt in via `SectionPlugin.correlationFeatures` and flow in
//     with no engine edit (GitHub is the first).
//   • Role + distribution travel with each feature so later phases
//     (surprise-ranking, per-series deconfounding, N-of-1 experiments)
//     slot in without a migration. Phase 0 consumes `series` + `role`;
//     `distribution` is recorded but not yet branched on.

/// Soft prior about a feature's agency — not a hard gate. The engine pairs
/// PREDICTOR → OUTCOME, so any feature can predict an outcome, but only
/// outcomes are pairing *targets* (that's the QS question: "what moves the
/// things I care about?").
enum CorrelationRole: String, Codable, Hashable {
  /// A behaviour you choose — caffeine, training, a supplement, bedtime.
  case lever
  /// A state/result you care about — sleep score, HRV, gut, commits.
  case outcome
  /// Context with no clear agency; usable as a predictor, never a target.
  case neutral
}

/// Distribution shape — picked up by later phases to choose the right
/// correlation method and the right deconfounding. Declared now so the
/// capability is complete; Phase 0 records but doesn't yet branch on it.
enum CorrelationDistribution: String, Codable, Hashable {
  case continuous, count, binary
}

/// One section-contributed daily series plus the metadata the engine needs
/// to pair, gate, and (later) rank it. Returned by
/// `SectionPlugin.correlationFeatures`.
struct CorrelationFeature {
  let key: String
  let label: String
  let section: String
  let unit: String
  let role: CorrelationRole
  let distribution: CorrelationDistribution
  /// date ("yyyy-MM-dd") → value. Missing days are simply absent — the
  /// engine aligns on shared dates and never zero-fills a gap.
  let series: [String: Double]
}

extension CorrelationEngine {

  // MARK: - Feature catalog

  /// Declarative metadata (section / label / unit / role / distribution)
  /// for every feature `extract()` produces from the built-in SwiftData
  /// sections. This is the ONE place those facts live — the engine no
  /// longer encodes section relationships as a hand-written pair list.
  /// Sections migrated to `SectionPlugin.correlationFeatures` (e.g. GitHub)
  /// don't need an entry here; they declare their own.
  struct CatalogEntry {
    let label: String
    let section: String
    let unit: String
    let role: CorrelationRole
    let distribution: CorrelationDistribution
  }

  static let legacyCatalog: [String: CatalogEntry] = [
    // Sleep / Oura — outcomes
    "sleep_score":  .init(label: "Sleep score", section: "sleep", unit: "",    role: .outcome, distribution: .continuous),
    "readiness":    .init(label: "Readiness",   section: "sleep", unit: "",    role: .outcome, distribution: .continuous),
    "hrv":          .init(label: "HRV",         section: "sleep", unit: "ms",  role: .outcome, distribution: .continuous),
    "resting_hr":   .init(label: "Resting HR",  section: "sleep", unit: "bpm", role: .outcome, distribution: .continuous),
    "total_h":      .init(label: "Sleep hours", section: "sleep", unit: "h",   role: .outcome, distribution: .continuous),
    "deep_h":       .init(label: "Deep sleep",  section: "sleep", unit: "h",   role: .outcome, distribution: .continuous),
    "rem_h":        .init(label: "REM sleep",   section: "sleep", unit: "h",   role: .outcome, distribution: .continuous),
    // Training — levers
    "training_volume": .init(label: "Training volume", section: "training", unit: "k",   role: .lever, distribution: .continuous),
    "cardio_min":      .init(label: "Cardio min",      section: "training", unit: "min", role: .lever, distribution: .continuous),
    "mobility_min":    .init(label: "Mobility min",    section: "training", unit: "min", role: .lever, distribution: .continuous),
    // Nutrition — levers
    "protein_g":      .init(label: "Protein",        section: "nutrition", unit: "g",    role: .lever, distribution: .continuous),
    "carbs_g":        .init(label: "Carbs",          section: "nutrition", unit: "g",    role: .lever, distribution: .continuous),
    "fat_g":          .init(label: "Fat",            section: "nutrition", unit: "g",    role: .lever, distribution: .continuous),
    "fiber_g":        .init(label: "Fiber",          section: "nutrition", unit: "g",    role: .lever, distribution: .continuous),
    "fiber_g_3d":     .init(label: "Fiber 3-day avg",section: "nutrition", unit: "g/d",  role: .lever, distribution: .continuous),
    "kcal":           .init(label: "Calories",       section: "nutrition", unit: "kcal", role: .lever, distribution: .continuous),
    "last_meal_hour": .init(label: "Last meal hour", section: "nutrition", unit: "h",    role: .lever, distribution: .continuous),
    "fasting_window": .init(label: "Fasting window", section: "nutrition", unit: "h",    role: .lever, distribution: .continuous),
    // Caffeine — levers
    "caffeine_g":         .init(label: "Caffeine grams",     section: "caffeine", unit: "g", role: .lever, distribution: .continuous),
    "caffeine_cups":      .init(label: "Caffeine cups",      section: "caffeine", unit: "",  role: .lever, distribution: .count),
    "last_caffeine_hour": .init(label: "Last caffeine hour", section: "caffeine", unit: "h", role: .lever, distribution: .continuous),
    // Cannabis — levers
    "cannabis_sessions": .init(label: "Cannabis sessions", section: "cannabis", unit: "", role: .lever, distribution: .count),
    "cannabis_g":        .init(label: "Cannabis grams",    section: "cannabis", unit: "g", role: .lever, distribution: .continuous),
    // Habits — lever (aggregate; per-habit binaries are added dynamically)
    "habit_completion":  .init(label: "Habit completion",  section: "habits",   unit: "%", role: .lever, distribution: .continuous),
    // Gut — outcomes
    "bristol":       .init(label: "Bristol",       section: "gut", unit: "", role: .outcome, distribution: .continuous),
    "gut_movements": .init(label: "Gut movements", section: "gut", unit: "", role: .outcome, distribution: .count),
  ]

  /// The static catalog plus the per-habit / per-supplement binary features,
  /// which are data-dependent (one per definition) and so can't be static.
  static func featureCatalog(
    habits: [(id: String, label: String, emoji: String)],
    supplements: [(id: String, label: String, emoji: String)]
  ) -> [String: CatalogEntry] {
    var c = legacyCatalog
    for h in habits {
      let lbl = h.emoji.isEmpty ? h.label : "\(h.emoji) \(h.label)"
      c["habit:\(h.id)"] = .init(label: lbl, section: "habits", unit: "", role: .lever, distribution: .binary)
    }
    for s in supplements {
      let lbl = s.emoji.isEmpty ? s.label : "\(s.emoji) \(s.label)"
      c["supp:\(s.id)"] = .init(label: lbl, section: "supplements", unit: "", role: .lever, distribution: .binary)
    }
    return c
  }

  // MARK: - Auto-pairing

  /// Generate the candidate universe: every eligible predictor → every
  /// eligible OUTCOME from a different section. Eligible = the feature has
  /// data this window AND its section is active. Curated specs are overlaid
  /// as direction/lag/title *hints* on the matching auto-pair — they enrich,
  /// they don't gate. (`activeSections` empty = treat all as active, for a
  /// fresh account before the section mirror hydrates.)
  ///
  /// Perf note: pairs scale with (#predictors × #outcomes × lags). With a
  /// large habit/supplement catalog this grows; revisit with a relevance
  /// pre-filter if recompute ever stalls. Not silently capped today.
  static func autoPairs(
    catalog: [String: CatalogEntry],
    availableKeys: Set<String>,
    activeSections: Set<String>,
    curated: [PairSpec]
  ) -> [PairSpec] {
    var hint: [String: (expected: Direction, lag: Int?, title: String?)] = [:]
    for c in curated {
      hint["\(c.predictor.key)>\(c.target.key)"] = (c.expected, c.lagPreference, c.titleOverride)
    }

    func isActive(_ section: String) -> Bool {
      activeSections.isEmpty || activeSections.contains(section)
    }
    let eligible = catalog.filter { availableKeys.contains($0.key) && isActive($0.value.section) }

    func spec(_ key: String, _ e: CatalogEntry) -> FeatureSpec {
      FeatureSpec(key: key, label: e.label, section: e.section,
                  unit: e.unit, binary: e.distribution == .binary)
    }

    var pairs: [PairSpec] = []
    for (tKey, tEntry) in eligible where tEntry.role == .outcome {
      let target = spec(tKey, tEntry)
      for (pKey, pEntry) in eligible where pKey != tKey && pEntry.section != tEntry.section {
        let predictor = spec(pKey, pEntry)
        let h = hint["\(pKey)>\(tKey)"]
        let lag = h?.lag ?? defaultLagPreference(predictor: pEntry, target: tEntry)
        pairs.append(PairSpec(predictor: predictor,
                              target: target,
                              lagPreference: lag,
                              expected: h?.expected ?? .unknown,
                              titleOverride: h?.title ?? nil))
      }
    }
    return pairs
  }

  /// Conservative default lag hints for broad section families. Nil means
  /// "let the engine compare 0/1/2 days and keep the strongest supported
  /// relationship"; non-nil means the timing is obvious enough that scanning
  /// other days would mostly add false-discovery pressure.
  static func defaultLagPreference(predictor: CatalogEntry, target: CatalogEntry) -> Int? {
    if target.section == "sleep" {
      switch predictor.section {
      case "caffeine", "nutrition", "training", "habits", "supplements", "medications":
        return 0
      default:
        return nil
      }
    }
    if target.section == "gut", predictor.section == "nutrition" { return 1 }
    return nil
  }

  // MARK: - Multiple-comparisons control

  /// Benjamini-Hochberg FDR. Returns id → q-value (adjusted p). Step-up
  /// with monotonic enforcement. With a wide auto-paired universe, raw
  /// p < 0.05 would mint ~1-in-20 spurious "trusted" hits; gating the top
  /// tier on q keeps it honest (and legitimately empty until evidence
  /// accrues).
  static func benjaminiHochberg(_ items: [(id: String, p: Double)]) -> [String: Double] {
    let m = items.count
    guard m > 0 else { return [:] }
    let ascending = items.enumerated().sorted { $0.element.p < $1.element.p }
    var adjusted = [Double](repeating: 1.0, count: m)
    var runningMin = 1.0
    // Walk from the largest p (rank m) down to 1, enforcing q monotonicity.
    for rank in stride(from: m, through: 1, by: -1) {
      let p = ascending[rank - 1].element.p
      let raw = p * Double(m) / Double(rank)
      runningMin = min(runningMin, raw)
      adjusted[rank - 1] = min(1.0, runningMin)
    }
    var q: [String: Double] = [:]
    for rank in 0..<m { q[ascending[rank].element.id] = adjusted[rank] }
    return q
  }
}
