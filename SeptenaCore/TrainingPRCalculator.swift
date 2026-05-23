import Foundation
import SwiftData

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

// Top-level (not nested in TrainingPRCalculator) so DraftSession's
// synthesized Codable conformance — which can't cross actor isolation
// boundaries on nested types — stays clean.
struct PRBaseline: Hashable, Sendable, Codable {
  /// Best estimated 1-rep-max across all sets for this exercise.
  /// Epley formula: weight * (1 + reps/30). Strength only.
  var e1RM: Double?
  /// The actual lift that produced the e1RM, for display ("PR vs 60×8").
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
    let wanted = Set(exerciseNames.map { $0.lowercased() })
    guard !wanted.isEmpty else { return [:] }
    let entries = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>())) ?? []
    let grouped = Dictionary(grouping: entries.filter {
      wanted.contains($0.exercise.lowercased())
    }, by: { $0.exercise.lowercased() })

    var out: [String: PRBaseline] = [:]
    for (key, rows) in grouped {
      out[key] = baseline(from: rows)
    }
    return out
  }

  private static func baseline(from rows: [ExerciseEntryEntity]) -> PRBaseline {
    var e1RM: Double?
    var bestW: Double?
    var bestR: Int?
    var bestDist: Double?
    var bestDur: Double?

    for row in rows {
      // Strength PR via Epley e1RM. Only counts when both weight AND
      // a parseable rep count are present; sets count doesn't enter
      // the formula because e1RM is per-set, not per-session.
      if let w = row.weight, w > 0, let r = parseInt(row.reps), r > 0 {
        let estimate = w * (1.0 + Double(r) / 30.0)
        if e1RM == nil || estimate > e1RM! {
          e1RM = estimate
          bestW = w
          bestR = r
        }
      }
      if let d = row.distanceM, d > 0 {
        bestDist = max(bestDist ?? 0, d)
      }
      if let m = row.durationMin, m > 0 {
        bestDur = max(bestDur ?? 0, m)
      }
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
    // Strength: compare estimated 1RM
    guard let w = draft.weight, w > 0,
          let r = parseInt(draft.reps), r > 0,
          let best = baseline.e1RM else { return false }
    let estimate = w * (1.0 + Double(r) / 30.0)
    return estimate > best
  }
}
