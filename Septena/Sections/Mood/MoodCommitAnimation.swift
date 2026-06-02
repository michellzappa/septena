import SwiftUI

// MoodCommitAnimation — maps the logged affect quadrant onto a shared
// CommitMotion so the celebration *matches the affect*: confetti for the
// high-arousal-positive log, a tension-snap for high-arousal-negative, a
// slow bloom for the calm quadrant, a quiet downward sink for the low
// quadrant.
//
// The motions themselves now live in `CommitFlourish` (shared across every
// section). What remains here is only the Mood section's *choice of axis* —
// which dimension of the logged data drives the motion. That mapping is the
// pattern every other section follows: pick the data axis, pick the motion.

struct MoodCommitAnimation: View {
  let quadrant: MoodQuadrant
  /// Increment to fire a new run. Forwarded straight to `CommitFlourish`.
  let trigger: Int

  var body: some View {
    CommitFlourish(motion: quadrant.commitMotion,
                   accent: quadrant.color,
                   trigger: trigger)
  }
}

private extension MoodQuadrant {
  /// Affect → motion. HAP celebrates, HAN releases tension, LAP settles,
  /// LAN quietly acknowledges. Re-tuning a quadrant's "feel" is a one-line
  /// edit here — the motion vocabulary itself stays in `CommitMotion`.
  var commitMotion: CommitMotion {
    switch self {
    case .hap: return .burst
    case .han: return .snap
    case .lap: return .bloom
    case .lan: return .sink
    }
  }
}
