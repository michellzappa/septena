import SwiftUI

// CommitMotion — the shared vocabulary of "log committed" flourishes.
//
// The idea proven by the Mood meter: the celebration should *match what
// was logged*, not be a generic reward for the tap. Mood mapped its four
// affect quadrants onto four distinct motions; this lifts those motions
// out of the Mood section so every section can map its own data axis onto
// the same primitives (caffeine dose, training PR, gut Bristol, …).
//
// One envelope, many characters: every primitive lives in the same
// full-canvas geometry and the same ~0.7–1.1s window. Only the motion
// varies — that consistency is what keeps the flourishes feeling like one
// language rather than a pile of unrelated gimmicks.

/// The choreography to play when a log commits. Each section picks the
/// case that matches *its* data (see the per-section mapping at the call
/// site, e.g. `MoodQuadrant.commitMotion`). Restraint is a valid output:
/// `.sink` is an acknowledgment, not a celebration.
enum CommitMotion: Equatable {
  /// Upward confetti fan — quick, celebratory. (Mood HAP / generic "logged".)
  case burst
  /// Sharp ring pulse + brief flash — releasing tension. (Mood HAN.)
  case snap
  /// Slow gentle outward bloom — settling / a sigh. (Mood LAP.)
  case bloom
  /// A single dot settling downward and fading — quiet acknowledgment,
  /// no celebration. (Mood LAN.)
  case sink
}

/// Renders a `CommitMotion` as a full-canvas, non-interactive overlay.
/// Drop it in an `.overlay { }` (in-sheet, blocking dismiss) or let the
/// app-root `LogCommitOverlay` render it (non-blocking) — same renderer
/// either way.
///
/// Reduce Motion is honored *here*, centrally, so no caller can forget:
/// the whole flourish is skipped. That's a hard opt-out — the `.snap`
/// primitive includes a full-screen luminance flash that is
/// seizure-adjacent and must never fire when motion is reduced. The commit
/// haptic + the data change already confirm the log, so nothing is lost
/// beyond decoration.
struct CommitFlourish: View {
  let motion: CommitMotion
  let accent: Color
  /// Increment to fire a fresh run. Same `.task(id:)` contract as
  /// `ConfettiBurst` — the primitive watches it and replays on each bump.
  let trigger: Int

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      if !reduceMotion {
        switch motion {
        case .burst:
          // count/duration match the original Mood HAP burst exactly.
          ConfettiBurst(trigger: trigger, accent: accent, count: 20, duration: 1.0)
        case .snap:  SnapFlourish(color: accent, trigger: trigger)
        case .bloom: BloomFlourish(color: accent, trigger: trigger)
        case .sink:  SinkFlourish(color: accent, trigger: trigger)
        }
      }
    }
    .allowsHitTesting(false)
  }
}

// MARK: - snap — sharp ring pulse + brief flash (releasing tension)

private struct SnapFlourish: View {
  let color: Color
  let trigger: Int

  @State private var ringScale: CGFloat = 0.3
  @State private var ringOpacity: Double = 0.0
  @State private var flashOpacity: Double = 0.0

  var body: some View {
    ZStack {
      // Brief screen flash — the "tension snap" feeling.
      Rectangle()
        .fill(color.opacity(flashOpacity))
        .ignoresSafeArea()
      // Ring expanding outward.
      Circle()
        .strokeBorder(color.opacity(ringOpacity), lineWidth: 3)
        .frame(width: 220, height: 220)
        .scaleEffect(ringScale)
    }
    .task(id: trigger) {
      guard trigger > 0 else { return }
      ringScale = 0.3
      ringOpacity = 0.9
      flashOpacity = 0.35
      withAnimation(.easeOut(duration: 0.85)) {
        ringScale = 2.6
        ringOpacity = 0
      }
      withAnimation(.easeOut(duration: 0.6)) {
        flashOpacity = 0
      }
    }
  }
}

// MARK: - bloom — slow gentle outward bloom (settling / sigh)

private struct BloomFlourish: View {
  let color: Color
  let trigger: Int

  @State private var scale: CGFloat = 0.5
  @State private var opacity: Double = 0

  var body: some View {
    Circle()
      .fill(
        RadialGradient(colors: [color.opacity(opacity * 0.6),
                                color.opacity(0)],
                       center: .center,
                       startRadius: 0,
                       endRadius: 160)
      )
      .frame(width: 320, height: 320)
      .scaleEffect(scale)
      .task(id: trigger) {
        guard trigger > 0 else { return }
        scale = 0.5
        opacity = 1.0
        withAnimation(.easeOut(duration: 1.1)) {
          scale = 1.5
          opacity = 0
        }
      }
  }
}

// MARK: - sink — inward sink (acknowledgment, no celebration)
//
// A single small dot in the accent color appears, then slowly settles
// downward and fades. The kinetic version of a quiet exhale — explicit
// that you logged, no fanfare.

private struct SinkFlourish: View {
  let color: Color
  let trigger: Int

  @State private var yOffset: CGFloat = -20
  @State private var opacity: Double = 0
  @State private var scale: CGFloat = 1.0

  var body: some View {
    Circle()
      .fill(color.opacity(opacity * 0.65))
      .frame(width: 18, height: 18)
      .scaleEffect(scale)
      .offset(y: yOffset)
      .task(id: trigger) {
        guard trigger > 0 else { return }
        yOffset = -20
        opacity = 0
        scale = 1.0
        withAnimation(.easeOut(duration: 0.22)) {
          opacity = 1.0
        }
        withAnimation(.easeIn(duration: 0.95).delay(0.08)) {
          yOffset = 80
          scale = 0.6
          opacity = 0
        }
      }
  }
}
