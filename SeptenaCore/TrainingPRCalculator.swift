import Foundation
import SwiftData

/// Estimated one-rep max from a single logged set.
///
/// Top-level (not nested in `TrainingPRCalculator`) so it stays free of
/// MainActor isolation: it is pure arithmetic, and both the PR baseline and
/// the 90-day progress chart read it. Having one estimator is the point —
/// two copies of Epley drift apart the moment one of them grows a guard.
enum OneRepMax {
  /// Above this many reps a submaximal estimate says more about work capacity
  /// than about maximal strength, and the standard formulas (Epley, Brzycki,
  /// Lombardi) diverge by double digits. Declining to estimate beats printing
  /// a number nobody should train off, so a 20-rep set produces no e1RM at
  /// all rather than a fantasy one.
  static let repCap = 12

  /// Epley (`w · (1 + r/30)`), or nil when the set can't honestly produce an
  /// estimate: no load, no reps, or more reps than `repCap`. A single is the
  /// measurement rather than an estimate, so it comes back unchanged instead
  /// of gaining Epley's 3.3 %.
  static func estimate(weightKg: Double?, reps: Int?) -> Double? {
    guard let w = weightKg, w > 0, let r = reps, r >= 1, r <= repCap else { return nil }
    return r == 1 ? w : w * (1 + Double(r) / 30)
  }
}

// PRBaseline "best ever" stats per exercise. Drives the PR pill in
// TrainingExerciseCard: when the current draft exceeds the relevant
// baseline field, the card shows a "PR" badge. Computed once at
// session start so the user sees a stable threshold for the whole
// workout — no flicker as they edit.
//
// Comparison uses lowercased exercise name (the same key the rest of
// the training pipeline uses) so casing drift doesn't hide history.
// Same-day entries are included; we don't filter them out because
// a PR set earlier in the same session legitimately moves the bar.

/// Compact snapshot of a single past entry for a given exercise.
/// Used by the active-session card's "last 3 sessions" mini-table.
/// All numeric fields are optional — strength entries leave the
/// cardio fields nil and vice versa; the renderer picks the columns
/// to show based on the entry's type.
struct RecentExerciseEntry: Hashable, Sendable, Codable {
  let date: String           // YYYY-MM-DD
  let weight: Double?
  let sets: String?
  let reps: String?
  let durationMin: Double?
  let distanceM: Double?
  let level: Double?
  let difficulty: String?
}

// Top-level (not nested in TrainingPRCalculator) so DraftSession's
// synthesized Codable conformance — which can't cross actor isolation
// boundaries on nested types — stays clean.
struct PRBaseline: Hashable, Sendable, Codable {
  /// Best estimated 1-rep-max across all sets for this exercise.
  /// Epley formula: weight * (1 + reps/30). Strength only.
  var e1RM: Double?
  /// The actual lift that produced the e1RM, so a record can always name its
  /// source — "142.5 kg est. from 100×10" is a different claim from "from
  /// 140×1". When no set was eligible for an estimate (every one past
  /// `OneRepMax.repCap`), this falls back to the heaviest set logged, so a
  /// high-rep-only exercise still has a record to show.
  var bestWeight: Double?
  var bestReps: Int?
  /// Cardio peaks. Distinct so a PR can fire on either axis.
  var bestDistanceM: Double?
  var bestDurationMin: Double?
  /// True when at least one historical entry exists, even if no
  /// numeric fields were set — used to suppress "PR" on first-ever
  /// attempts (no baseline = nothing to beat).
  var hasHistory: Bool

  static let empty = PRBaseline(e1RM: nil, bestWeight: nil, bestReps: nil,
                                bestDistanceM: nil, bestDurationMin: nil,
                                hasHistory: false)
}

@MainActor
enum TrainingPRCalculator {
  /// Batch-compute baselines for a list of exercise names (case-
  /// insensitive). One fetch over all ExerciseEntryEntity rows, then
  /// a single pass per exercise. Returns a map keyed by lowercased
  /// exercise name; callers should look up using the same casing.
  static func baselines(for exerciseNames: [String],
                        in context: ModelContext) -> [String: PRBaseline] {
    let wanted = Set(exerciseNames.map { exerciseKey($0) })
    guard !wanted.isEmpty else { return [:] }
    let entries = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>())) ?? []
    let grouped = Dictionary(grouping: entries.filter {
      wanted.contains(exerciseKey($0.exercise))
    }, by: { exerciseKey($0.exercise) })

    var out: [String: PRBaseline] = [:]
    for (key, rows) in grouped {
      out[key] = baseline(from: rows)
    }
    return out
  }

  /// Top `limit` most-recent entries per exercise, newest first. Same
  /// case-insensitive keying as `baselines(for:in:)`. Built from the
  /// same fetch so callers can reuse it; computed-in-tandem is fine
  /// because both walk every ExerciseEntryEntity anyway.
  static func recents(for exerciseNames: [String],
                      in context: ModelContext,
                      limit: Int = 3) -> [String: [RecentExerciseEntry]] {
    let wanted = Set(exerciseNames.map { exerciseKey($0) })
    guard !wanted.isEmpty else { return [:] }
    let entries = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>(
      sortBy: [SortDescriptor(\.date, order: .reverse),
               SortDescriptor(\.loggedAt, order: .reverse)]
    ))) ?? []
    let filtered = entries.filter { wanted.contains(exerciseKey($0.exercise)) }
    let grouped = Dictionary(grouping: filtered, by: { exerciseKey($0.exercise) })

    var out: [String: [RecentExerciseEntry]] = [:]
    for (key, rows) in grouped {
      out[key] = rows.prefix(limit).map { row in
        RecentExerciseEntry(
          date: row.date,
          weight: row.weight,
          sets: row.sets,
          reps: row.reps,
          durationMin: row.durationMin,
          distanceM: row.distanceM,
          level: row.level,
          difficulty: row.difficulty
        )
      }
    }
    return out
  }

  private static func baseline(from rows: [ExerciseEntryEntity]) -> PRBaseline {
    var e1RM: Double?
    var bestW: Double?
    var bestR: Int?
    var bestDist: Double?
    var bestDur: Double?

    // Heaviest load ever put on the bar, regardless of reps. Tracked
    // separately because the rep cap makes e1RM optional: without this an
    // exercise only ever logged for 15s would show no record at all.
    var heaviestW: Double?
    var heaviestR: Int?

    for row in rows {
      // Strength PR via Epley e1RM. Only counts when both weight AND a
      // parseable rep count are present, and only inside the rep range an
      // estimate means anything in; sets count doesn't enter the formula
      // because e1RM is per-set, not per-session.
      if let w = row.weight, w > 0 {
        let r = parseInt(row.reps)
        if let estimate = OneRepMax.estimate(weightKg: w, reps: r),
           e1RM == nil || estimate > e1RM! {
          e1RM = estimate
          bestW = w
          bestR = r
        }
        if w > (heaviestW ?? 0) {
          heaviestW = w
          heaviestR = r
        }
      }
      if let d = row.distanceM, d > 0 {
        bestDist = max(bestDist ?? 0, d)
      }
      if let m = row.durationMin, m > 0 {
        bestDur = max(bestDur ?? 0, m)
      }
    }
    if e1RM == nil {
      bestW = heaviestW
      bestR = heaviestR
    }
    return PRBaseline(e1RM: e1RM, bestWeight: bestW, bestReps: bestR,
                    bestDistanceM: bestDist, bestDurationMin: bestDur,
                    hasHistory: true)
  }

  // `ExerciseEntryEntity.reps` is stored as String (allows "AMRAP" or
  // mixed-rep notes). Only the leading integer counts for PR math.
  private static func parseInt(_ s: String?) -> Int? {
    guard let s else { return nil }
    let prefix = s.prefix { $0.isNumber }
    return Int(prefix)
  }

  /// Returns true if the draft entry beats the baseline on any axis
  /// relevant to its type. Conservative — requires strict inequality
  /// so re-logging the last session doesn't flag a PR.
  static func isPR(draft: DraftEntry, baseline: PRBaseline) -> Bool {
    guard baseline.hasHistory else { return false }
    if draft.isCardio {
      if let d = draft.distanceM, d > 0,
         let best = baseline.bestDistanceM, d > best { return true }
      if let m = draft.durationMin, m > 0,
         let best = baseline.bestDurationMin, m > best { return true }
      return false
    }
    // Strength: compare estimated 1RM. A set past the rep cap produces no
    // estimate, so it can't fire the pill — which is the point: 20 reps at a
    // light load is a work-capacity set, not a strength record.
    guard let estimate = OneRepMax.estimate(weightKg: draft.weight,
                                            reps: parseInt(draft.reps)),
          let best = baseline.e1RM else { return false }
    return estimate > best
  }
}
