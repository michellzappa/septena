import Foundation

// The in-session "aim for this" rule. Pure function of the frozen pre-session
// snapshot (`DraftSession.lastByExercise` / `recentByExercise`), so the hint
// can't drift mid-workout and the rule can be reasoned about on its own.
//
// The model is double progression, collapsed to the one axis we can actually
// know without a stored plan: **reps before load**. Load only moves when the
// last set says there's room (rated easy, or rated hard and not stalling);
// everything else earns a rep at the same weight first. That's the difference
// between a coach and a ratchet.
//
// Deliberately NOT here (see `docs/TRAINING_PT_SPEC.md`): per-exercise rep
// ranges, mesocycles, deload prescription, fatigue modelling. Those need the
// plan/template layer that doesn't exist yet.
enum TrainingProgression {

  /// A one-tap "do a little more than last time" target for a strength set.
  struct Hint: Equatable {
    let weightKg: Double
    let reps: String
    let reason: String
  }

  /// `@AppStorage` key. Device-local display pref, matching the effort-scale /
  /// auto-advance idiom for section prefs, so no CloudKit sync.
  static let enabledKey = "training.progressionHints"
  static let defaultEnabled = true

  /// Ceiling on a single session's load jump, as a fraction of the last load.
  /// The equipment step is an absolute number of kilos, so without this the
  /// same +5 kg machine step is a 5% bump on a 100 kg leg press and a 25% bump
  /// on a 20 kg cable fly. One plate is always allowed (you can't add less than
  /// the smallest thing on the rack); the cap only ever removes *extra* steps.
  static let maxJumpFraction = 0.10

  /// Today's target, or nil when there's no comparable weighted history.
  /// `recents` is newest-first and includes the last session.
  static func hint(exercise: String,
                   lastWeightKg weight: Double,
                   lastReps reps: Int,
                   lastDifficulty: String?,
                   recents: [RecentExerciseEntry]) -> Hint? {
    guard weight > 0, reps > 0 else { return nil }
    let step = WeightCadence.resolve(forExercise: exercise).step(.kg)

    func addLoad(_ steps: Int, _ reason: String) -> Hint {
      Hint(weightKg: weight + Double(cappedSteps(steps, weightKg: weight, step: step)) * step,
           reps: "\(reps)",
           reason: reason)
    }
    func addRep(_ reason: String) -> Hint {
      Hint(weightKg: weight, reps: "\(reps + 1)", reason: reason)
    }

    // Unrated is not evidence of room. Treating it as "hard" (which is what a
    // bare `default:` branch does) is how a hint layer turns into a treadmill
    // that adds load every session forever. Repeat and ask for a rating.
    guard let effort = TrainingEffort.canonicalKey(lastDifficulty) else {
      return Hint(weightKg: weight, reps: "\(reps)",
                  reason: "Last set wasn't rated. Repeat it and rate the effort.")
    }

    switch effort {
    case "max":
      // RIR 0. Already at this load's ceiling; more weight buys a failed set.
      return addRep("You went to failure. Earn a rep before adding load.")
    case "moderate":
      // RIR 2. Two reps in reserve means the *reps* have room, not the load.
      return addRep("Two reps in reserve. Earn a rep before adding load.")
    case "easy":
      return addLoad(2, "Last set was easy.")
    default:
      // Hard (RIR 1). Room for one step, unless the load already isn't moving.
      if isStalling(at: weight, recents: recents) {
        return addRep("Same load two sessions running. Earn a rep first.")
      }
      return addLoad(1, "Steady progress.")
    }
  }

  /// Steps actually granted after the proportional cap. Always at least one:
  /// the equipment's own increment is the floor of what's addable.
  static func cappedSteps(_ desired: Int, weightKg weight: Double, step: Double) -> Int {
    guard desired > 1, step > 0 else { return max(1, desired) }
    let allowed = Int((weight * maxJumpFraction / step).rounded(.down))
    return max(1, min(desired, allowed))
  }

  /// True when the two most recent logged sessions sat at today's load. Grinding
  /// the same weight is the signal to add a rep rather than another plate.
  static func isStalling(at weight: Double, recents: [RecentExerciseEntry]) -> Bool {
    let recent = recents.compactMap(\.weight).prefix(2)
    guard recent.count == 2 else { return false }
    return recent.allSatisfy { abs($0 - weight) < 0.01 }
  }
}
