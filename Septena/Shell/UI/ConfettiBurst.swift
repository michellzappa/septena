import SwiftUI

/// Tasteful confetti burst — a dozen small accent-colored particles
/// that fan upward from the anchor point, rotate, and fade out over
/// ~0.8s. Built for the "exercise done" celebration in the training
/// logger but kept generic so it can sit behind future PRs, streak
/// milestones, etc.
///
/// Usage:
/// ```
/// @State private var burst = 0
///
/// Button("Done") {
///   …action…
///   burst += 1
/// }
/// .overlay { ConfettiBurst(trigger: burst, accent: .orange) }
/// ```
///
/// Each increment of `trigger` spawns a fresh batch — no manual
/// "reset" needed. The view returns to invisible automatically once
/// the animation finishes, so it's safe to leave permanently attached.
struct ConfettiBurst: View {
  /// Increment to fire a new burst. The view watches this via
  /// `.task(id:)` so consecutive bursts replace each other cleanly.
  let trigger: Int
  /// Particle colour. Single-tone keeps the celebration tasteful —
  /// no rainbow-party effect. Caller usually passes the section
  /// accent so the burst feels native to the surface.
  let accent: Color
  /// How many particles per burst. Twelve reads as "celebration"
  /// without being noisy. Keep it small if you're animating many
  /// rows at once.
  var count: Int = 12
  /// Total animation duration in seconds.
  var duration: Double = 0.8

  @State private var particles: [Particle] = []

  var body: some View {
    ZStack {
      ForEach(particles) { p in
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(accent.opacity(p.opacity))
          .frame(width: p.size, height: p.size)
          .rotationEffect(.degrees(p.rotation))
          .offset(p.offset)
      }
    }
    .allowsHitTesting(false)
    .task(id: trigger) {
      guard trigger > 0 else { return }
      // Spawn new particles at the anchor with random outward
      // velocities. Each one gets a unique target offset / rotation
      // so the burst never looks tiled.
      particles = (0..<count).map { _ in
        let angle = Double.random(in: -.pi ... 0)              // fan upward
        let distance = Double.random(in: 30...80)
        return Particle(
          id: UUID(),
          size: .random(in: 4...7),
          startOffset: .zero,
          endOffset: CGSize(width: cos(angle) * distance,
                            height: sin(angle) * distance),
          rotation: .random(in: -180...180),
          opacity: 1.0
        )
      }
      // Use SwiftUI animation to interpolate `offset` and `opacity`
      // from start → end. Setting opacity to ~0 inside withAnimation
      // gives the natural fade-out tail.
      withAnimation(.easeOut(duration: duration)) {
        for i in particles.indices {
          particles[i].offset = particles[i].endOffset
          particles[i].opacity = 0
        }
      }
      // Wait for the animation to finish, then drop the particles
      // so the view is back to zero work between bursts.
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      particles = []
    }
  }

  private struct Particle: Identifiable, Equatable {
    let id: UUID
    let size: CGFloat
    var startOffset: CGSize
    var endOffset: CGSize
    let rotation: Double
    var opacity: Double
    var offset: CGSize = .zero
  }
}
