import SwiftUI

// Mood's affect → motion mapping.
//
// The Mood section's choice of which data axis drives the commit flourish:
// the logged quadrant. HAP celebrates (burst), HAN releases tension (snap),
// LAP settles (bloom), LAN quietly acknowledges (sink) — so the celebration
// *matches the affect*. The motions themselves live in `CommitMotion`
// (shared across sections) and are played via the `.commitFlourish` modifier
// on `AddMoodPage`. This mapping is the pattern every other section copies:
// pick the data axis, pick the motion.

extension MoodQuadrant {
  /// Re-tuning a quadrant's "feel" is a one-line edit here — the motion
  /// vocabulary itself stays in `CommitMotion`.
  var commitMotion: CommitMotion {
    switch self {
    case .hap: return .burst
    case .han: return .snap
    case .lap: return .bloom
    case .lan: return .sink
    }
  }
}
