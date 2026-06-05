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
  /// A run of marks dropping in sequence, one per unit — reads the
  /// *quantity* logged, not just "something happened". For countable logs
  /// (supplements taken, items cleared, a set of reps). Intensity → count.
  case cascade
  /// A bright mark joining a row of faint prior marks — continuity /
  /// repetition made visible for one beat. For recurring logs (habit
  /// toggles); the quiet everyday sibling of the `.ignition` milestone.
  /// Intensity → how much of the prior row is suggested.
  case tally
  /// A row settling onto a baseline and fading — "filed onto the done
  /// pile". For finishing a thing on a list (chores). Like `.sink`, it
  /// ignores intensity: done is binary, restraint is the point.
  case settle

  // ── Experimental (round 2) — in the gallery to be felt; not yet wired
  //    to any section. Promote the keepers, delete the rest. ───────────

  /// A full-screen sonar: huge concentric rings sweeping past the edges.
  /// Bolder, number-free cousin of `.ignition`. Candidate for ambient logs.
  case ripple
  /// A large glowing comet arcing across the screen — reads as motion
  /// *toward* something. Candidate for goals / progress-to-target.
  case arc
  /// A full-screen flood rising bottom→top like a gauge filling the page.
  /// Candidate for logs with a target (hydration, macros). Intensity →
  /// fill height.
  case fill
  /// A full-screen glowing comet sweeping across the page — an alternative
  /// "continuity" feel, distinct from `.tally`'s vertical strokes.
  case streak
}

extension CommitMotion {
  /// The haptic that pairs with this motion — same character, same window.
  /// Built here in the app layer because `Haptics` (in SeptenaCore) stays
  /// motion-agnostic; `intensity` matches the loudness the visual uses.
  /// `.sink`/`.settle` ignore intensity, exactly like their renderers.
  func hapticSpec(intensity: Double) -> HapticPatternSpec {
    // Clamp loudness into CoreHaptics' 0…1 intensity range.
    let i = Float(min(1.0, max(0.45, intensity)))
    switch self {
    case .burst:
      // Sharp pop + a short sparkle tail; sharper as the log gets bigger.
      let sharp = min(1.0, 0.6 + 0.4 * i)
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .transient, time: 0,    intensity: i,        sharpness: sharp),
        HapticBeat(kind: .transient, time: 0.09, intensity: 0.5 * i,  sharpness: sharp),
        HapticBeat(kind: .transient, time: 0.17, intensity: 0.35 * i, sharpness: sharp),
      ], fallback: .success)
    case .snap:
      // One hard release — high sharpness, the tension let go.
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .transient, time: 0, intensity: min(1.0, 0.9 * i + 0.1), sharpness: 0.95),
      ], fallback: .success)
    case .bloom:
      // Soft swell, low sharpness — matches the gradient bloom.
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .continuous, time: 0, duration: 0.4, intensity: 0.55 * i, sharpness: 0.2),
      ], fallback: .tick)
    case .sink:
      // A soft appear, then a firmer landing thump synced to the ripple.
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .transient, time: 0,   intensity: 0.3, sharpness: 0.3),
        HapticBeat(kind: .transient, time: 0.5, intensity: 0.6, sharpness: 0.45),
      ], fallback: .tick)
    case .cascade:
      // One tap per mark, timed to its bounce landing (visual: k·0.07 + ~0.22).
      let count = min(12, max(3, Int((6 * intensity).rounded())))
      let beats = (0..<count).map { k in
        HapticBeat(kind: .transient, time: Double(k) * 0.07 + 0.22, intensity: 0.6, sharpness: 0.7)
      }
      return HapticPatternSpec(beats: beats, fallback: .tap)
    case .tally:
      // One firm thump synced to the slam-down impact (~0.2s).
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .transient, time: 0.2, intensity: 0.6, sharpness: 0.6),
      ], fallback: .tick)
    case .settle:
      // Landing thunk as the row drops in, then a lighter check stamp.
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .transient, time: 0.18, intensity: 0.55, sharpness: 0.3),
        HapticBeat(kind: .transient, time: 0.36, intensity: 0.4,  sharpness: 0.6),
      ], fallback: .tick)
    case .ripple:
      // A soft transient per ring launch — calm, low sharpness.
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .transient, time: 0,    intensity: 0.45, sharpness: 0.2),
        HapticBeat(kind: .transient, time: 0.16, intensity: 0.3,  sharpness: 0.2),
        HapticBeat(kind: .transient, time: 0.32, intensity: 0.2,  sharpness: 0.2),
      ], fallback: .tick)
    case .arc:
      // A light swell following the sweep, then a transient at the landing.
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .continuous, time: 0,    duration: 0.45, intensity: 0.4 * i, sharpness: 0.4),
        HapticBeat(kind: .transient,  time: 0.46, intensity: 0.6, sharpness: 0.7),
      ], fallback: .tick)
    case .fill:
      // A rising swell as it fills, capped by a pop at full.
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .continuous, time: 0,    duration: 0.5, intensity: 0.5 * i, sharpness: 0.3),
        HapticBeat(kind: .transient,  time: 0.52, intensity: 0.65, sharpness: 0.6),
      ], fallback: .tick)
    case .streak:
      // A transient kickoff, then a light swept swell.
      return HapticPatternSpec(beats: [
        HapticBeat(kind: .transient,  time: 0,    intensity: 0.55, sharpness: 0.7),
        HapticBeat(kind: .continuous, time: 0.04, duration: 0.3, intensity: 0.35 * i, sharpness: 0.4),
      ], fallback: .tick)
    }
  }
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
  /// the renderer watches it and replays on each bump.
  let trigger: Int
  /// When true, ignore the user's "Logging animations" opt-out and always
  /// render (Reduce Motion is still honored). Set only by the Motion Gallery,
  /// where the whole point is to feel a motion on demand.
  var ignoresUserPreference: Bool = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// User opt-out for logging animations (Settings ▸ Customize). Absent → on.
  /// Suppresses the visual the same way Reduce Motion does; the commit haptic
  /// + announcement at the call site still confirm the log.
  @AppStorage(SettingsKey.loggingAnimationsEnabled) private var animationsEnabled = true

  var body: some View {
    ZStack {
      if !reduceMotion && (animationsEnabled || ignoresUserPreference) {
        switch motion {
        case .burst: BurstFlourish(color: accent, intensity: intensity, trigger: trigger)
        case .snap:  SnapFlourish(color: accent, intensity: intensity, trigger: trigger)
        case .bloom: BloomFlourish(color: accent, intensity: intensity, trigger: trigger)
        case .sink:  SinkFlourish(color: accent, trigger: trigger)
        case .cascade: CascadeFlourish(color: accent, intensity: intensity, trigger: trigger)
        case .tally:   TallyFlourish(color: accent, intensity: intensity, trigger: trigger)
        case .settle:  SettleFlourish(color: accent, trigger: trigger)
        case .ripple:  RippleFlourish(color: accent, intensity: intensity, trigger: trigger)
        case .arc:     ArcFlourish(color: accent, intensity: intensity, trigger: trigger)
        case .fill:    FillFlourish(color: accent, intensity: intensity, trigger: trigger)
        case .streak:  StreakFlourish(color: accent, intensity: intensity, trigger: trigger)
        }
      }
    }
    .allowsHitTesting(false)
  }
}

// MARK: - burst — a radial explosion of sparks + a quick core pop (celebratory)
//
// A real explosion, not a polite upward fan: sparks shoot out in every
// direction at varied speeds/sizes, spinning and arcing under a touch of
// gravity, while a bright ring punches out from the center as the "flash"
// of the burst. Intensity scales spark count and reach.

private struct BurstFlourish: View {
  let color: Color
  var intensity: Double = 1
  let trigger: Int

  @State private var sparks: [Spark] = []
  @State private var coreScale: CGFloat = 0
  @State private var coreOpacity: Double = 0

  private var count: Int {
    // 26 at intensity 1; clamped so a big log can't flood the canvas and a
    // small one still reads as an explosion.
    min(48, max(12, Int((26 * intensity).rounded())))
  }

  var body: some View {
    ZStack {
      // Core pop — a bright ring punching outward, the flash of the burst.
      Circle()
        .strokeBorder(color.opacity(coreOpacity), lineWidth: 4)
        .frame(width: 90, height: 90)
        .scaleEffect(coreScale)
      ForEach(sparks) { s in
        Group {
          if s.isRect {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
              .fill(color.opacity(s.opacity))
          } else {
            Circle().fill(color.opacity(s.opacity))
          }
        }
        .frame(width: s.size, height: s.size)
        .rotationEffect(.degrees(s.rotation))
        .offset(s.offset)
      }
    }
    .task(id: trigger) {
      guard trigger > 0 else { return }
      coreScale = 0.2; coreOpacity = 0.9
      withAnimation(.easeOut(duration: 0.35)) { coreScale = 1.7; coreOpacity = 0 }

      sparks = (0..<count).map { _ in
        let angle = Double.random(in: 0 ..< (2 * .pi))
        let distance = Double.random(in: 70...170) * (0.7 + 0.3 * intensity)
        return Spark(
          id: UUID(),
          size: .random(in: 3...9),
          end: CGSize(width: cos(angle) * distance,
                      height: sin(angle) * distance + 34), // gravity drift
          endRotation: .random(in: -260...260),
          isRect: Bool.random()
        )
      }
      withAnimation(.easeOut(duration: 0.9)) {
        for i in sparks.indices {
          sparks[i].offset = sparks[i].end
          sparks[i].rotation = sparks[i].endRotation
          sparks[i].opacity = 0
        }
      }
      try? await Task.sleep(for: .milliseconds(950))
      sparks = []
    }
  }

  private struct Spark: Identifiable {
    let id: UUID
    let size: CGFloat
    let end: CGSize
    let endRotation: Double
    let isRect: Bool
    var opacity: Double = 1
    var offset: CGSize = .zero
    var rotation: Double = 0
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

// MARK: - sink — a dot drops with a comet trail and lands with a ripple
//
// An acknowledgment you actually notice: a dot accelerates downward,
// stretching into a comet as it falls, then lands and throws off a single
// ripple. Still "settling / logged", not a celebration — but felt.
// Deliberately ignores intensity: restraint stays the point.

private struct SinkFlourish: View {
  let color: Color
  let trigger: Int

  @State private var yOffset: CGFloat = -70
  @State private var dotOpacity: Double = 0
  @State private var stretch: CGFloat = 1
  @State private var rippleScale: CGFloat = 0.2
  @State private var rippleOpacity: Double = 0

  var body: some View {
    ZStack {
      // Landing ripple at the baseline.
      Circle()
        .strokeBorder(color.opacity(rippleOpacity), lineWidth: 2.5)
        .frame(width: 70, height: 70)
        .scaleEffect(rippleScale)
        .offset(y: 60)
      // The falling dot, stretched along travel for a comet feel.
      Capsule()
        .fill(color.opacity(dotOpacity))
        .frame(width: 22, height: 22)
        .scaleEffect(x: 1, y: stretch, anchor: .center)
        .offset(y: yOffset)
    }
    .task(id: trigger) {
      guard trigger > 0 else { return }
      yOffset = -70; dotOpacity = 0; stretch = 1
      rippleScale = 0.2; rippleOpacity = 0
      withAnimation(.easeIn(duration: 0.1)) { dotOpacity = 0.9 }
      withAnimation(.easeIn(duration: 0.5)) { yOffset = 60; stretch = 1.8 }
      // Land: snap round, fade the dot, throw the ripple.
      withAnimation(.easeOut(duration: 0.25).delay(0.5)) { stretch = 1; dotOpacity = 0 }
      withAnimation(.easeOut(duration: 0.5).delay(0.5)) { rippleScale = 1.4; rippleOpacity = 0.7 }
      withAnimation(.easeOut(duration: 0.35).delay(0.78)) { rippleOpacity = 0 }
    }
  }
}

// MARK: - cascade — marks rain down and bounce into a row (quantity)
//
// One dot per unit rains from above and lands with a spring bounce +
// impact squash, staggered left→right so the eye counts them. Intensity
// sets how many (clamped so a big log can't flood the canvas and a small
// one still reads as a run).

private struct CascadeFlourish: View {
  let color: Color
  var intensity: Double = 1
  let trigger: Int

  @State private var drops: [Drop] = []

  private var count: Int {
    // 6 at intensity 1; clamped to a legible run.
    min(12, max(3, Int((6 * intensity).rounded())))
  }

  private let baseline: CGFloat = 50

  var body: some View {
    ZStack {
      ForEach(drops) { d in
        // Impact splash ring at the baseline.
        Circle()
          .strokeBorder(color.opacity(d.ringOpacity), lineWidth: 2.5)
          .frame(width: d.size * 2.6, height: d.size * 2.6)
          .scaleEffect(d.ringScale)
          .offset(x: d.x, y: baseline)
        // The falling drop.
        Circle()
          .fill(color.opacity(d.opacity))
          .frame(width: d.size, height: d.size)
          .scaleEffect(x: d.squash.width, y: d.squash.height, anchor: .bottom)
          .offset(x: d.x, y: d.y)
      }
    }
    .task(id: trigger) {
      guard trigger > 0 else { return }
      let n = count
      let spread = CGFloat(n - 1) * 16
      drops = (0..<n).map { k in
        Drop(id: UUID(),
             size: .random(in: 15...22),
             x: CGFloat(k) * 32 - spread,
             y: -150, opacity: 0,
             squash: CGSize(width: 1, height: 1),
             ringScale: 0.3, ringOpacity: 0)
      }
      for k in drops.indices {
        let t = Double(k) * 0.07
        // Faster, heavier fall with a livelier bounce.
        withAnimation(.interpolatingSpring(stiffness: 240, damping: 10).delay(t)) {
          drops[k].y = baseline
          drops[k].opacity = 0.95
        }
        // Bigger impact squash, then recover.
        withAnimation(.easeOut(duration: 0.09).delay(t + 0.22)) {
          drops[k].squash = CGSize(width: 1.45, height: 0.6)
        }
        withAnimation(.easeOut(duration: 0.18).delay(t + 0.31)) {
          drops[k].squash = CGSize(width: 1, height: 1)
        }
        // Splash ring: pop visible at impact, then expand + fade.
        withAnimation(.easeOut(duration: 0.05).delay(t + 0.2)) {
          drops[k].ringOpacity = 0.7
        }
        withAnimation(.easeOut(duration: 0.5).delay(t + 0.25)) {
          drops[k].ringScale = 1.9
          drops[k].ringOpacity = 0
        }
      }
      try? await Task.sleep(for: .seconds(Double(n) * 0.07 + 0.85))
      withAnimation(.easeOut(duration: 0.4)) {
        for i in drops.indices { drops[i].opacity = 0 }
      }
      try? await Task.sleep(for: .milliseconds(420))
      drops = []
    }
  }

  private struct Drop: Identifiable {
    let id: UUID
    let size: CGFloat
    let x: CGFloat
    var y: CGFloat
    var opacity: Double
    var squash: CGSize
    var ringScale: CGFloat
    var ringOpacity: Double
  }
}

// MARK: - tally — a new stroke slams into the row, the row flares, then clears
//
// The streak you're extending, made kinetic: the new bright stroke SLAMS
// down from above with an overshoot, the whole row flares bright on impact,
// then the entire group fades cleanly out (everything is driven by `shown`,
// so nothing lingers). The everyday sibling of `.ignition` — "one more".

private struct TallyFlourish: View {
  let color: Color
  var intensity: Double = 1
  let trigger: Int

  @State private var shown: Double = 0       // master fade — 0 at rest, cleans out
  @State private var newDrop: CGFloat = -42  // new stroke starts above the baseline
  @State private var newPunch: CGFloat = 1   // impact scale punch
  @State private var flare: Double = 0       // brightness flare across the row

  private var priors: Int {
    // How much of the prior row to suggest; 4 at intensity 1.
    min(8, max(1, Int((4 * intensity).rounded())))
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 9) {
      ForEach(0..<priors, id: \.self) { _ in
        Capsule()
          .fill(color.opacity(shown * (0.22 + 0.45 * flare)))
          .frame(width: 6, height: 38)
      }
      Capsule()
        .fill(color.opacity(shown * 0.95))
        .frame(width: 6, height: 38)
        .scaleEffect(x: 1, y: newPunch, anchor: .bottom)
        .offset(y: newDrop)
    }
    .task(id: trigger) {
      guard trigger > 0 else { return }
      shown = 0; newDrop = -42; newPunch = 1; flare = 0
      withAnimation(.easeOut(duration: 0.1)) { shown = 1 }
      // Slam down with overshoot.
      withAnimation(.spring(response: 0.26, dampingFraction: 0.45)) { newDrop = 0 }
      // Impact punch + a flare rippling through the whole row.
      withAnimation(.easeOut(duration: 0.1).delay(0.2)) { newPunch = 1.22; flare = 1 }
      withAnimation(.easeOut(duration: 0.16).delay(0.3)) { newPunch = 1 }
      withAnimation(.easeIn(duration: 0.35).delay(0.4)) { flare = 0 }
      // Hold, then clean out completely.
      withAnimation(.easeOut(duration: 0.4).delay(0.95)) { shown = 0 }
    }
  }
}

// MARK: - settle — a row drops in, gets checked, and files onto the pile
//
// A row drops from above and lands with a spring, a checkmark stamps onto
// it, then it slides down and files away — "done, put away". Distinct from
// `.sink` (a falling dot): this reads as a *thing* being completed and
// filed. Ignores intensity on purpose — finishing a list item is binary.

private struct SettleFlourish: View {
  let color: Color
  let trigger: Int

  @State private var yOffset: CGFloat = -50
  @State private var barOpacity: Double = 0
  @State private var checkScale: CGFloat = 0
  @State private var checkOpacity: Double = 0

  var body: some View {
    RoundedRectangle(cornerRadius: 7, style: .continuous)
      .fill(color.opacity(barOpacity * 0.55))
      .frame(width: 150, height: 26)
      .overlay(
        Image(systemName: "checkmark")
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(color)
          .scaleEffect(checkScale)
          .opacity(checkOpacity)
          .offset(x: -54)
      )
      .offset(y: yOffset)
      .task(id: trigger) {
        guard trigger > 0 else { return }
        yOffset = -50; barOpacity = 0; checkScale = 0; checkOpacity = 0
        withAnimation(.spring(response: 0.4, dampingFraction: 0.68)) {
          yOffset = 0; barOpacity = 1
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(0.18)) {
          checkScale = 1; checkOpacity = 1
        }
        // File away: slide down and fade.
        withAnimation(.easeIn(duration: 0.45).delay(0.72)) {
          yOffset = 60; barOpacity = 0; checkOpacity = 0
        }
      }
  }
}

// MARK: - ripple — a full-screen sonar of huge expanding rings
//
// Big concentric rings launch from center and sweep past the screen edges,
// staggered. Full-canvas and number-free — distinct from `.ignition`'s
// small rings + streak count.

private struct RippleFlourish: View {
  let color: Color
  var intensity: Double = 1
  let trigger: Int

  @State private var rings: [Ring] = []

  var body: some View {
    ZStack {
      ForEach(rings) { r in
        Circle()
          .strokeBorder(color.opacity(r.opacity), lineWidth: 3)
          .frame(width: 160, height: 160)
          .scaleEffect(r.scale)
      }
    }
    .ignoresSafeArea()
    .task(id: trigger) {
      guard trigger > 0 else { return }
      rings = (0..<3).map { _ in Ring(id: UUID(), scale: 0.1, opacity: 0.6) }
      // Scale a 160pt base well past any screen edge.
      let reach = CGFloat(6.0 + 2.5 * intensity)
      for k in rings.indices {
        withAnimation(.easeOut(duration: 1.1).delay(Double(k) * 0.18)) {
          rings[k].scale = reach
          rings[k].opacity = 0
        }
      }
      try? await Task.sleep(for: .milliseconds(1500))
      rings = []
    }
  }

  private struct Ring: Identifiable { let id: UUID; var scale: CGFloat; var opacity: Double }
}

// MARK: - arc — a large glowing comet arcing across the screen (toward a target)

private struct ArcFlourish: View {
  let color: Color
  var intensity: Double = 1
  let trigger: Int

  @State private var t: CGFloat = 0
  @State private var opacity: Double = 0

  /// Point on the top arc (left → over the top → right) at progress `t`.
  private func point(_ t: CGFloat, _ radius: CGFloat) -> CGSize {
    let theta = Double.pi * (1 - Double(t))   // pi → 0
    return CGSize(width: CGFloat(cos(theta)) * radius,
                  height: -CGFloat(sin(theta)) * radius)
  }

  var body: some View {
    GeometryReader { geo in
      // Span most of the screen width.
      let radius = min(geo.size.width, geo.size.height) * 0.45
      ZStack {
        // Soft glow underlay + crisp trail on top.
        ArcTrail(progress: t, radius: radius)
          .stroke(color.opacity(opacity * 0.5),
                  style: StrokeStyle(lineWidth: 7, lineCap: .round))
          .blur(radius: 5)
        ArcTrail(progress: t, radius: radius)
          .stroke(color.opacity(opacity * 0.9),
                  style: StrokeStyle(lineWidth: 3, lineCap: .round))
        Circle()
          .fill(color.opacity(opacity))
          .frame(width: 22, height: 22)
          .blur(radius: 0.5)
          .offset(point(t, radius))
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .ignoresSafeArea()
    .task(id: trigger) {
      guard trigger > 0 else { return }
      t = 0; opacity = 0
      withAnimation(.easeIn(duration: 0.12)) { opacity = 1 }
      withAnimation(.easeInOut(duration: 0.6)) { t = 1 }
      withAnimation(.easeOut(duration: 0.4).delay(0.55)) { opacity = 0 }
    }
  }
}

/// Trailing segment of the arc, built from the same point math as the dot
/// so the comet and its tail always align.
private struct ArcTrail: Shape {
  var progress: CGFloat
  let radius: CGFloat
  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }
  func path(in rect: CGRect) -> Path {
    var p = Path()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let start = max(0, progress - 0.35)
    let steps = 24
    for k in 0...steps {
      let s = start + (progress - start) * CGFloat(k) / CGFloat(steps)
      let theta = Double.pi * (1 - Double(s))
      let pt = CGPoint(x: center.x + CGFloat(cos(theta)) * radius,
                       y: center.y - CGFloat(sin(theta)) * radius)
      if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    return p
  }
}

// MARK: - fill — a full-screen flood rising bottom → top (toward a target)
//
// Translucent accent "liquid" rises from the bottom of the whole screen to
// a level set by intensity, holds, then fades. The page-scale version of a
// gauge filling — strong full-canvas feedback for target logs.

private struct FillFlourish: View {
  let color: Color
  var intensity: Double = 1
  let trigger: Int

  @State private var level: CGFloat = 0
  @State private var opacity: Double = 0

  private var target: CGFloat { min(1, max(0.35, CGFloat(intensity) * 0.8)) }

  var body: some View {
    GeometryReader { geo in
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        Rectangle()
          .fill(LinearGradient(
            colors: [color.opacity(0.42 * opacity), color.opacity(0.10 * opacity)],
            startPoint: .bottom, endPoint: .top))
          .frame(height: geo.size.height * level)
      }
    }
    .ignoresSafeArea()
    .task(id: trigger) {
      guard trigger > 0 else { return }
      level = 0; opacity = 0
      withAnimation(.easeIn(duration: 0.12)) { opacity = 1 }
      withAnimation(.easeOut(duration: 0.6)) { level = target }
      withAnimation(.easeOut(duration: 0.5).delay(0.85)) { opacity = 0 }
    }
  }
}

// MARK: - streak — a full-screen glowing comet sweeping across the page

private struct StreakFlourish: View {
  let color: Color
  var intensity: Double = 1
  let trigger: Int

  @State private var progress: CGFloat = 0
  @State private var opacity: Double = 0

  var body: some View {
    GeometryReader { geo in
      let travel = geo.size.width + 220
      let cx = -110 + travel * progress
      ZStack {
        // Long soft glow trailing the bright head.
        Capsule()
          .fill(color.opacity(opacity * 0.45))
          .frame(width: 190, height: 20)
          .blur(radius: 10)
        Capsule()
          .fill(color.opacity(opacity))
          .frame(width: 66, height: 11)
      }
      .position(x: cx, y: geo.size.height * 0.5)
    }
    .ignoresSafeArea()
    .task(id: trigger) {
      guard trigger > 0 else { return }
      progress = 0; opacity = 0
      withAnimation(.easeIn(duration: 0.1)) { opacity = 0.95 }
      withAnimation(.easeInOut(duration: 0.55)) { progress = 1 }
      withAnimation(.easeOut(duration: 0.25).delay(0.42)) { opacity = 0 }
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
    // Motion-matched haptic: same character as the visual, even under
    // Reduce Motion (where the visual is skipped but the haptic still fires).
    Haptics.play(motion.hapticSpec(intensity: intensity))
    if let announce { A11y.announce(announce) }
    logCommit?.fire(.flourish(motion: motion, accent: accent, intensity: intensity))
  }
}

// MARK: - SectionLog — the manifest-driven commit funnel
//
// Every section's log/edit write routes through here so the haptic +
// VoiceOver + motion language stays identical app-wide. The *motion* a new
// log plays is declared per-section on the plugin (`SectionPlugin.logFlourish`)
// — the "manifest" — so adding a section means declaring its feel in one
// place, not hand-writing a commit funnel. Sections whose motion varies with
// the entry (e.g. caffeine time-of-day) pass a `motion:` override.

/// A section's commit-flourish declaration: how a *new* log celebrates.
/// Lives on the section plugin (the app-layer manifest). `nil` there = no
/// flourish (utility sections).
struct LogFlourish: Sendable {
  /// Default motion for a new log in this section. Sections with a dynamic
  /// rule override per-call via `SectionLog.newLog(motion:)`.
  var motion: CommitMotion
}

@MainActor
enum SectionLog {
  /// Non-blocking commit of a NEW entry: runs `write` (persist + tile
  /// refresh), the success haptic, the announce, then fires the flourish at
  /// the app root. Motion resolves from the section plugin's `logFlourish`
  /// unless overridden. `accent` is the section's theme color (resolved by
  /// the caller); `logCommit` is nil-safe (skips only the visual).
  static func newLog(section sectionKey: String,
                     accent: Color,
                     motion: CommitMotion? = nil,
                     intensity: Double = 1,
                     announce: String? = nil,
                     logCommit: LogCommitCenter?,
                     write: () -> Void) {
    let resolved = motion
      ?? SectionRegistry.plugin(forKey: sectionKey)?.logFlourish?.motion
      ?? .burst
    CommitFeedback.commit(motion: resolved, accent: accent, intensity: intensity,
                          announce: announce, logCommit: logCommit, write: write)
  }

  /// Commit an EDIT: a correction, not a fresh log — quiet haptic, no
  /// flourish. `write` does the update + tile refresh.
  static func edit(write: () -> Void) {
    write()
    Haptics.tick()
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
