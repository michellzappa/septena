import Foundation
import SwiftData

// Goal-measurement substrate. The shape of a metric, the window helpers
// every plugin uses, the progress math the UI renders — all live here.
// The actual metric *declarations* and the per-section evaluators live
// in each section's plugin file, so adding a section adds its metrics
// in one place. `GoalMetricCatalog.all` flat-maps across the registry.

// MARK: - Metric

struct GoalMetric: Hashable, Identifiable {
  let key: String         // stable id stored on the goal
  let label: String       // user-facing picker row
  let sectionKey: String  // home section — implies auto-visibility
  let window: String      // baked in for v1: today | calendarWeek
  let unitLabel: String   // "sessions", "cups", "g", ...

  var id: String { key }
}

// MARK: - Catalog (registry-driven)

@MainActor
enum GoalMetricCatalog {
  /// Union of every plugin's declared aim metrics. Order = registry order
  /// then per-plugin declaration order. Computed; no cache — the registry
  /// is tiny and the catalog rebuilds whenever the picker opens.
  static var all: [GoalMetric] {
    // Source the shared main context so data-dependent metrics (intake's
    // per-kind set) reflect live kinds. Catalog is recomputed per read (no
    // cache), so call sites stay unchanged — none need to pass a context.
    let ctx = LocalStore.shared.container.mainContext
    return SectionRegistry.all.flatMap { $0.aimMetrics(context: ctx) }
  }

  static func metric(for key: String) -> GoalMetric? {
    all.first { $0.key == key }
  }

  /// Picker filter: metrics whose home section is in the goal's tag set.
  /// Empty tag set returns everything (lets the user attach a metric even
  /// on an untagged goal — rare, but supported).
  static func metrics(for sectionKeys: Set<String>) -> [GoalMetric] {
    let all = self.all
    return sectionKeys.isEmpty ? all : all.filter { sectionKeys.contains($0.sectionKey) }
  }

  /// The section a metric inherently belongs to — used by the strip
  /// filter as a safety net so a measured goal lands in its home section
  /// even when the user didn't double-tag it.
  static func sectionKey(for metricKey: String) -> String? {
    metric(for: metricKey)?.sectionKey
  }
}

// MARK: - Progress

struct GoalMetricProgress {
  let current: Double
  let target: Double
  let comparator: String  // "gte" | "lte" | "eq" | "range"
  let unitLabel: String
  /// Upper bound for a `range` goal (`target` is the lower bound). Nil for
  /// one-sided comparators. When present, the goal is a maintenance band and
  /// the UI renders a band-with-marker rather than a fill bar.
  let targetUpper: Double?
  /// Optional starting value. When present (and meaningful for the
  /// comparator), `fraction` measures distance traveled from baseline
  /// toward target instead of raw current/target. Nil = use the simple
  /// math, appropriate for count/sum metrics whose natural floor is 0.
  let baseline: Double?

  /// 0…1 bar fraction. Two modes:
  ///
  /// **Without baseline** (counts, sums — natural floor of 0):
  /// - gte: current/target
  /// - lte: 1 − current/target (over-target reads as 0)
  /// - eq:  1 − distance/target, peaks at target, falls off either side
  ///
  /// **With baseline** (latest-shape metrics like body weight):
  /// - lte: (baseline − current) / (baseline − target) — losing weight
  /// - gte: (current − baseline) / (target − baseline) — gaining muscle
  /// - eq:  baseline doesn't help symmetric goals; fall through to the
  ///        no-baseline math (eq is a maintenance shape)
  ///
  /// Target = 0 stays specially handled either way.
  /// Whether this is a two-sided maintenance band.
  var isRange: Bool { comparator == "range" && targetUpper != nil }

  /// For a band: the visible 0…1 fractions of the band edges and the current
  /// marker, over a domain padded so an out-of-band reading still shows. nil
  /// for non-range goals.
  var band: (lower: Double, upper: Double, marker: Double)? {
    guard isRange, let upper = targetUpper, upper > target else { return nil }
    let span = upper - target
    let pad = max(span * 0.5, 1)
    let domainMin = Swift.min(target - pad, current)
    let domainMax = Swift.max(upper + pad, current)
    let width = domainMax - domainMin
    guard width > 0 else { return nil }
    func f(_ v: Double) -> Double { Swift.min(1, Swift.max(0, (v - domainMin) / width)) }
    return (f(target), f(upper), f(current))
  }

  var fraction: Double {
    if isRange { return hit ? 1 : 0 }   // range renders a band, not a fill
    if target == 0 {
      switch comparator {
      case "gte": return 1
      default:    return current == 0 ? 1 : 0
      }
    }
    // Baseline-aware path. Only used when the baseline is on the *far*
    // side of the target from the goal direction (e.g. lte target=22,
    // baseline=25 means we're trying to come down). If baseline matches
    // target or is already past it, fall through to the simple math.
    if let baseline, comparator != "eq", baseline != target {
      let span = abs(baseline - target)
      let travelled = comparator == "lte"
        ? (baseline - current)   // lte: distance descended
        : (current - baseline)   // gte: distance ascended
      return min(1.0, max(0.0, travelled / span))
    }
    let raw: Double
    switch comparator {
    case "lte":
      raw = (target - current) / target
    case "eq":
      raw = 1 - (abs(current - target) / target)
    default:
      raw = current / target
    }
    return min(1.0, max(0.0, raw))
  }

  /// "Hit" means the target is satisfied. For eq we allow a tolerance
  /// (±5% of target, min ±1 unit) so a 79.6kg reading counts as 80.
  var hit: Bool {
    switch comparator {
    case "lte": return current <= target
    case "range":
      guard let upper = targetUpper else { return current >= target }
      return current >= target && current <= upper
    case "eq":
      let tolerance = max(1.0, target * 0.05)
      return abs(current - target) <= tolerance
    default: return current >= target
    }
  }
}

// MARK: - Evaluator (dispatch-only)

@MainActor
enum GoalMetricEvaluator {
  static func evaluate(goal: Goal, context: ModelContext) -> GoalMetricProgress? {
    guard let key = goal.metricKey,
          let comparator = goal.metricComparator,
          let target = goal.metricTarget,
          let metric = GoalMetricCatalog.metric(for: key),
          let plugin = SectionRegistry.plugin(forKey: metric.sectionKey)
    else { return nil }

    // nil from a plugin means "no reading available" (e.g. Body before
    // the user has any Withings data). Bubble nil up so the UI hides
    // the progress bar rather than rendering 0 — which for an `lte`
    // target would misleadingly read as "hit."
    guard let current = plugin.evaluateAim(metric: metric, context: context) else {
      return nil
    }
    return GoalMetricProgress(current: current,
                              target: target,
                              comparator: comparator,
                              unitLabel: metric.unitLabel,
                              targetUpper: goal.metricTargetUpper,
                              baseline: goal.metricBaseline)
  }
}

// MARK: - Window helpers (shared by every plugin's evaluateAim)

enum GoalMetricWindow {
  /// Inclusive YYYY-MM-DD bounds for a window. Use with entities whose
  /// `date` is a string column.
  static func dateStringRange(for window: String) -> (String, String)? {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    guard let (start, end) = dateRange(for: window) else { return nil }
    var cal = Calendar.current
    cal.firstWeekday = 2
    let lastDay = cal.date(byAdding: .day, value: -1, to: end) ?? end
    return (fmt.string(from: start), fmt.string(from: lastDay))
  }

  /// Half-open Date window [start, end). Monday-first week so training
  /// schedules read the way users expect.
  static func dateRange(for window: String) -> (Date, Date)? {
    var cal = Calendar.current
    cal.firstWeekday = 2
    let now = Date()
    switch window {
    case "today":
      let start = cal.startOfDay(for: now)
      guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
      return (start, end)
    case "calendarWeek":
      guard let interval = cal.dateInterval(of: .weekOfYear, for: now) else { return nil }
      return (interval.start, interval.end)
    default:
      return nil
    }
  }
}
