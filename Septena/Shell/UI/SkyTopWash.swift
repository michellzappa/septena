import SwiftUI

// Sky wash — the front door's top gradient is the *real* current sky.
//
// Reverse-engineered from Horizon (sky.dlazaro.ca,
// github.com/dnlzro/horizon, MIT): a single-scattering atmosphere model
// (Sébastien Hillaire's technique; Andrew Helmer's shader). Horizon feeds it
// one number — the sun's elevation at your approximate location — and reads
// back a zenith→horizon vertical gradient, refreshed every minute. Septena
// already has both halves: `SolarClock.elevation` (time-zone geography, no
// permission) and `DayClock`'s 60-second tick. So the wash is literally the
// sky overhead right now: blue noon, ember dusk, near-black night, and it
// follows you when you travel.
//
// This is the "future top wash" `AmbientLight` was written to host (§ the
// note there) — but it uses the PHYSICAL model, not `AmbientLight`'s
// deliberately-monochrome dial palette: realistic sky belongs at the top of
// the page (à la Health.app), where it reads as light on the page, not
// behind the glass dial (where blue once "painted the hero blue").

/// The dashboard's top gradient: the current sky, subtle, fading into the
/// page like Apple Health's colored header. A tint over the system
/// background — never a slab — so the greeting and dial stay legible in both
/// appearances (DesignSpec §5.5: light on the page, not a new surface).
///
/// Self-observes `DayClock` so the minute tick re-renders only the wash, and
/// the heavy render fires only when the sun has crossed a ~0.5° bucket (every
/// few minutes), off the main thread.
struct SkyTopWash: View {
  @Environment(DayClock.self) private var clock
  @Environment(\.colorScheme) private var colorScheme

  /// Seed synchronously so the wash is visible on the first frame — the
  /// `.task` refines off-thread when the sun moves buckets. `Date()` here
  /// (not `DayClock`) is fine: it's a one-frame placeholder until `.task`
  /// runs with `clock.now`.
  @State private var stops: [SkyAtmosphere.Stop] = SkyAtmosphere.render(
    elevation: SolarClock.elevation(now: Date())
  )
  /// Tracks which elevation bucket `stops` reflects — animation runs only on
  /// bucket transitions (sun moving through the day), never on first paint.
  @State private var lastRenderedBucket: Int?

  /// How far below the band the fade's elliptical centre sits, in frame
  /// heights. The fade's iso-opacity arcs are ellipses around that point, so a
  /// centre below the frame bows the baseline into a gentle upward arch (∩) —
  /// highest in the middle, dropping at the sides. Smaller → more pronounced
  /// arch. This is the curviness knob (see `body`).
  private let archDepth: CGFloat = 0.35

  /// Squeeze the sky's zenith→horizon ramp into the upper `skySpan` of the
  /// band, holding the horizon colour below it. The warmest stop ("the daylight
  /// below the blue") is the *last* in the ramp, so at full span it lands at the
  /// very foot — right where the curved fade goes transparent — and never
  /// shows. Pulling the ramp up reaches that warmth before the fade clears it,
  /// so the daylight band reads, then melts away. Lower → warm shows higher.
  private let skySpan: Double = 0.6

  /// ~0.5° elevation buckets — the `.task` id, so a 60s tick that doesn't
  /// move the sun a visible amount doesn't re-render the gradient.
  private var elevationBucket: Int {
    Int((SolarClock.elevation(now: clock.now) / (0.5 * Double.pi / 180)).rounded())
  }

  /// The sky colour for a stop, adjusted for the current appearance. In dark
  /// mode the sky is desaturated (pulled toward grey of the SAME brightness)
  /// before it's added with `.plusLighter`: a saturated blue added onto black
  /// reads as a vivid blue slab, whereas a desaturated cool grey reads as soft
  /// ambient light — which is the brief. Pulling toward *luminance* (not white)
  /// keeps each stop's brightness, so a near-black night stays near-black and
  /// still adds nothing — the property that makes night vanish. `desaturation`
  /// is the knob: 0 = full sky colour, 1 = pure grey.
  private func washColor(_ s: SkyAtmosphere.Stop) -> Color {
    guard colorScheme == .dark else {
      return Color(.sRGB, red: s.r, green: s.g, blue: s.b, opacity: 1)
    }
    let desaturation = 0.6
    let l = 0.2126 * s.r + 0.7152 * s.g + 0.0722 * s.b
    return Color(.sRGB,
                 red: s.r + (l - s.r) * desaturation,
                 green: s.g + (l - s.g) * desaturation,
                 blue: s.b + (l - s.b) * desaturation,
                 opacity: 1)
  }

  /// 0 while the sun is up, ramping to 1 by the end of (≈nautical) twilight at
  /// −12° elevation. Drives the star field's fade-in through dusk so they don't
  /// pop on at sunset.
  private var nightness: Double {
    let elevationDegrees = SolarClock.elevation(now: clock.now) * 180 / .pi
    return min(1, max(0, -elevationDegrees / 12))
  }

  /// The sky-colour wash itself (no stars): the vertical sky gradient melted
  /// into the page along the curved, never-cut baseline, tinted per appearance.
  private var washLayer: some View {
    LinearGradient(
      gradient: Gradient(stops: stops.map {
        // `* skySpan` lifts the ramp into the top of the band; the last stop
        // then holds the horizon colour down to the foot (see `skySpan`).
        // `washColor` desaturates the sky in dark mode (see it).
        .init(color: washColor($0), location: $0.location * skySpan)
      }),
      startPoint: .top, endPoint: .bottom
    )
    // Melt into the page along a CURVED baseline that bows up in the middle.
    // Two stacked masks (their alphas multiply):
    //   1. An ELLIPTICAL fade whose centre sits below the frame, so its
    //      iso-opacity arcs read as a gentle upward arch (∩) — highest in
    //      the middle, lower at the sides. *Elliptical*, not radial: the
    //      arcs scale with the frame, so the arch spans the full width at
    //      any aspect. (A circular radial left the far corners of a wide
    //      macOS window fully opaque, cutting a hard horizontal line.)
    //   2. A plain vertical fade as a SAFETY FLOOR — guarantees the wash is
    //      fully clear by the band's foot across the WHOLE width, so it can
    //      never end in a hard edge regardless of window proportions.
    // Held full through the dial (real colour for the glass donut to refract),
    // gone by the foot. `archDepth` controls how curvy. Full colour to the top
    // edge so the wash bleeds to the screen edge on every platform.
    .mask(
      EllipticalGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .white.opacity(0.5), location: 0.5),
          .init(color: .white, location: 1),
        ],
        center: UnitPoint(x: 0.5, y: 1 + archDepth),
        startRadiusFraction: 0.71,
        endRadiusFraction: 1.15
      )
    )
    .mask(
      LinearGradient(stops: [
        .init(color: .white, location: 0),
        .init(color: .white, location: 0.035),
        .init(color: .white, location: 0.08),
        .init(color: .white, location: 0.80),
        .init(color: .white.opacity(0.5), location: 0.92),
        .init(color: .clear, location: 1),
      ], startPoint: .top, endPoint: .bottom)
    )
    // Dark appearance: ADD the sky as light (`plusLighter`) rather than
    // paint it over the dark UI — the daytime blue then reads as a soft
    // glow instead of a strong slab, and a near-black night adds nothing
    // and disappears. Light appearance: ordinary source-over tint. Dark
    // sky is desaturated (see `washColor`) so it no longer needs to be
    // dimmed into near-nothing — 0.32 keeps a soft cool presence.
    .opacity(colorScheme == .dark ? 0.32 : 0.6)
    .blendMode(colorScheme == .dark ? .plusLighter : .normal)
  }

  // MARK: Starfield

  private struct Star {
    let x, y: Double        // unit position (y biased toward the top)
    let radius: Double      // points
    let brightness: Double  // 0…1 base alpha
    let phase: Double       // twinkle phase offset
  }

  /// A fixed, deterministically-generated star field — stable across redraws
  /// and launches (no per-frame `Date`/random). Biased denser and brighter
  /// toward the top, where the night sky is darkest. Unit positions, scaled to
  /// the Canvas at draw time.
  private static let stars: [Star] = {
    var seed: UInt64 = 0x5EED_1EAF              // any fixed seed
    func rnd() -> Double {                       // small LCG in [0, 1)
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Double(seed >> 11) / Double(1 << 53)
    }
    return (0..<72).map { _ in
      Star(x: rnd(),
           y: rnd() * rnd(),                      // squared → biased toward top
           radius: 0.4 + rnd() * 1.2,             // 0.4…1.6 pt
           brightness: 0.3 + rnd() * 0.7,         // 0.3…1.0
           phase: rnd() * 2 * .pi)
    }
  }()

  /// The star layer: cheap `Canvas` dots on a slow `TimelineView` tick so they
  /// twinkle gently. The whole field fades in with `nightness` and melts out
  /// toward the foot (its own vertical mask). Additive white over the near-black
  /// night sky. The caller gates it to night + dark, so this animates ONLY then.
  private var starfield: some View {
    TimelineView(.animation(minimumInterval: 0.7)) { tl in
      Canvas { ctx, size in
        let t = tl.date.timeIntervalSinceReferenceDate
        let n = nightness
        for star in Self.stars {
          let twinkle = 0.8 + 0.2 * sin(t * 0.9 + star.phase)
          let alpha = star.brightness * twinkle * n
          if alpha <= 0.01 { continue }
          let cx = star.x * size.width, cy = star.y * size.height
          let r = star.radius
          ctx.fill(
            Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
            with: .color(.white.opacity(min(1, alpha)))
          )
        }
      }
    }
    // Stars only in the upper sky, gone well before the wash's foot.
    .mask(
      LinearGradient(stops: [
        .init(color: .white, location: 0),
        .init(color: .white, location: 0.40),
        .init(color: .clear, location: 0.72),
      ], startPoint: .top, endPoint: .bottom)
    )
    .blendMode(.plusLighter)
    .allowsHitTesting(false)
  }

  var body: some View {
    ZStack {
      washLayer
      // A light star field over the wash — ONLY at night (faded in by
      // `nightness` through dusk) and ONLY in dark mode. By day or in light
      // mode it isn't in the tree at all, so there's no animation cost.
      if colorScheme == .dark, nightness > 0.01 {
        starfield
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .task(id: elevationBucket) {
      // Pure physics — the sky is rendered straight from the sun's true
      // elevation, no fudge. Single scattering only, so it genuinely darkens
      // to near-black through deep night and warms at the real horizon;
      // that's the atmosphere, not a stylization.
      let bucket = elevationBucket
      let elevation = SolarClock.elevation(now: clock.now)
      let computed = await Task.detached(priority: .utility) {
        SkyAtmosphere.render(elevation: elevation)
      }.value
      if let last = lastRenderedBucket, last != bucket {
        withAnimation(.easeInOut(duration: 1.2)) { stops = computed }
      } else {
        stops = computed
      }
      lastRenderedBucket = bucket
    }
  }
}
