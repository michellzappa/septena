import SwiftUI

// MoodCommitAnimation — the visual flourish that plays after the user
// taps Log on AddMoodPage. The choreography varies by quadrant so the
// celebration *matches the affect*: a confetti-style upward burst would
// feel tonally wrong on an LAN ("Hopeless") log, and a slow inward
// fade would feel deflated on a HAP ("Ecstatic") log.
//
// Same geometry (full-canvas overlay) and same duration window
// (~700ms) across quadrants — only the particle motion / opacity /
// shape varies. Keeps the page rhythm consistent while letting the
// affect peek through.

struct MoodCommitAnimation: View {
  let quadrant: MoodQuadrant
  /// Increment to fire a new run. Same trigger contract as ConfettiBurst
  /// — `.task(id:)` watches it and replays on each increment.
  let trigger: Int

  // Reduce Motion suppresses the whole flourish. These are post-commit
  // decorations — the success haptic and the page dismissing already
  // confirm the log — so honoring the opt-out costs nothing. Gating here
  // (rather than inside each quadrant) is what keeps the HAN screen-flash
  // from ever rendering: a full-screen luminance flash is seizure-adjacent
  // and must never fire when the user has asked for reduced motion.
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      if !reduceMotion {
        switch quadrant {
        case .hap: HAPBurst(color: quadrant.color, trigger: trigger)
        case .han: HANPulse(color: quadrant.color, trigger: trigger)
        case .lap: LAPBloom(color: quadrant.color, trigger: trigger)
        case .lan: LANSink(color: quadrant.color, trigger: trigger)
        }
      }
    }
    .allowsHitTesting(false)
  }
}

// MARK: - HAP — confetti fan upward (quick + celebratory)

private struct HAPBurst: View {
  let color: Color
  let trigger: Int
  var body: some View {
    ConfettiBurst(trigger: trigger, accent: color, count: 20, duration: 1.0)
  }
}

// MARK: - HAN — sharp ring pulse + brief flash (releasing tension)

private struct HANPulse: View {
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

// MARK: - LAP — slow gentle outward bloom (settling / sigh)

private struct LAPBloom: View {
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

// MARK: - LAN — inward sink (acknowledgment, no celebration)
//
// A single small dot in the quadrant color appears, then slowly settles
// downward and fades. The kinetic version of a quiet exhale — explicit
// that you logged, no fanfare.

private struct LANSink: View {
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
