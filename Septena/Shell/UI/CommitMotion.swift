import SwiftUI

// CommitMotion — the shared vocabulary of "log committed" flourishes, plus
// the standard commit path every section routes through.
//
// The idea proven by the Mood meter: the celebration should *match what
// was logged*, not be a generic reward for the tap. Mood mapped its four
// affect quadrants onto four distinct motions; this lifts those motions
// out of the Mood section so every section can map its own data axis onto
// the same primitives (caffeine dose, training PR, gut Bristol, …).
//
// One envelope, many characters: every primitive lives in the same
// full-canvas geometry and the same ~0.7–1.1s window. Only the motion —
// and, optionally, its intensity — varies. That consistency is what keeps
// the flourishes feeling like one language rather than a pile of gimmicks.

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
/// `intensity` scales the *loudness* of the motion (1 = the canonical
/// Mood-calibrated strength). Sections that carry a magnitude — caffeine
/// mg, training effort — pass a normalized value so a big log reads
/// bigger. `.sink` ignores it on purpose: a quiet acknowledgment stays
/// quiet regardless of magnitude.
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
  /// Loudness multiplier; 1 reproduces the original Mood calibration.
  var intensity: Double = 1
  /// Increment to fire a fresh run. Same `.task(id:)` contract as
  /// `ConfettiBurst` — the primitive watches it and replays on each bump.
  let trigger: Int

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      if !reduceMotion {
        switch motion {
        case .burst:
          // count scales with intensity; at 1.0 it's the original 20.
          ConfettiBurst(trigger: trigger, accent: accent,
                        count: burstCount, duration: 1.0)
        case .snap:  SnapFlourish(color: accent, intensity: intensity, trigger: trigger)
        case .bloom: BloomFlourish(color: accent, intensity: intensity, trigger: trigger)
        case .sink:  SinkFlourish(color: accent, trigger: trigger)
        }
      }
    }
    .allowsHitTesting(false)
  }

  private var burstCount: Int {
    // 20 at intensity 1; clamped so a huge log can't flood the canvas and
    // a tiny one still reads as a celebration.
    min(40, max(8, Int((20 * intensity).rounded())))
  }
}

// MARK: - snap — sharp ring pulse + brief flash (releasing tension)

private struct SnapFlourish: View {
  let color: Color
  var intensity: Double = 1
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
      // Flash brightness + final ring reach scale with intensity; both
      // resolve to the original 0.35 / 2.6 at intensity 1.
      flashOpacity = min(0.6, 0.35 * intensity)
      withAnimation(.easeOut(duration: 0.85)) {
        ringScale = 2.0 + 0.6 * intensity
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
  var intensity: Double = 1
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
          // Final reach scales with intensity; 1.5 at intensity 1.
          scale = 1.0 + 0.5 * intensity
          opacity = 0
        }
      }
  }
}

// MARK: - sink — inward sink (acknowledgment, no celebration)
//
// A single small dot in the accent color appears, then slowly settles
// downward and fades. The kinetic version of a quiet exhale — explicit
// that you logged, no fanfare. Deliberately ignores intensity: restraint
// is the whole point of this primitive.

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

// MARK: - The standard commit path
//
// Two ways a section confirms a log, both routing through `CommitFlourish`
// so the haptic / VoiceOver / motion language stays identical everywhere:
//
//  • Non-blocking (`CommitFeedback.commit`): the triggering sheet dismisses
//    immediately and the flourish plays at the app root over the dashboard.
//    Right for high-frequency logs — training sets, caffeine, gut.
//  • Blocking (`.commitFlourish` modifier): the flourish plays in-sheet and
//    the caller's dismiss is delayed so it reads in context. Right for
//    low-frequency "moment" logs — mood, a finished session, a PR.

@MainActor
enum CommitFeedback {
  /// How long an in-sheet (blocking) flourish plays before its host
  /// dismisses. The per-quadrant Mood motions all complete within ~0.85s;
  /// the buffer lets the final frame settle. Perceived tap→dismiss ≈ 1.15s.
  static let blockingDismissDelay: Duration = .milliseconds(1150)

  /// The shared non-blocking commit path. Runs `write` (persist + any
  /// caller-side refresh), the success haptic, an optional VoiceOver
  /// announcement, then fires the app-root flourish. Call from any
  /// foreground log site that dismisses immediately.
  ///
  /// `logCommit` is optional: some hosts (Home-Screen quick actions) don't
  /// inherit the root environment. When it's nil the write + haptic +
  /// announcement still confirm the log — only the visual is skipped, which
  /// is also exactly what Reduce Motion does.
  static func commit(motion: CommitMotion,
                     accent: Color,
                     intensity: Double = 1,
                     announce: String? = nil,
                     logCommit: LogCommitCenter?,
                     write: () -> Void) {
    write()
    Haptics.success()
    if let announce { A11y.announce(announce) }
    logCommit?.fire(.flourish(motion: motion, accent: accent, intensity: intensity))
  }
}

extension View {
  /// In-sheet (blocking) commit flourish. Renders a `CommitFlourish`
  /// overlay keyed to `trigger`; on each bump it plays for the standard
  /// window then runs `onComplete` — typically `dismiss()`. Replaces the
  /// hand-rolled `Task { sleep; dismiss() }` pattern at blocking log sites.
  ///
  /// The overlay is inert until `trigger > 0`, so it's safe to attach
  /// permanently. Pass the motion/accent the caller froze at commit time.
  func commitFlourish(motion: CommitMotion,
                      accent: Color,
                      intensity: Double = 1,
                      trigger: Int,
                      onComplete: @escaping () -> Void) -> some View {
    overlay {
      CommitFlourish(motion: motion, accent: accent,
                     intensity: intensity, trigger: trigger)
        .transition(.opacity)
        .task(id: trigger) {
          guard trigger > 0 else { return }
          try? await Task.sleep(for: CommitFeedback.blockingDismissDelay)
          onComplete()
        }
    }
  }
}
