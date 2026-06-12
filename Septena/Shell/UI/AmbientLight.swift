import SwiftUI

// Ambient light — the time-of-day color wash on the dashboard's front door.
//
// The app already *knows* the time (DayClock drives the greeting, the Next
// buckets, the day dial); this gives that knowledge a visual register: dawn
// warms, midday stays nearly neutral, dusk embers, night cools to indigo.
// Deliberately ambient — a low-alpha glow behind the hero, never a poster
// background. Content surfaces stay on system backgrounds (DesignSpec §5.5);
// this is light falling on the page, not a new surface.
//
// ONE definition (§8). Presenters (AmbientGlow today; a future top wash)
// consume `Phase.tint` — they don't invent their own colors or hours.

enum AmbientLight {
  enum Phase: String {
    case dawn, day, dusk, night

    static func from(date: Date, calendar: Calendar = .current) -> Phase {
      switch calendar.component(.hour, from: date) {
      case 5..<8:   return .dawn
      case 8..<17:  return .day
      case 17..<21: return .dusk
      default:      return .night
      }
    }

    /// The two-stop tint pair (inner, outer). Alpha is applied by the
    /// presenter so one palette serves glows of different strengths.
    /// Midday is the quietest on purpose — neutral light is what makes
    /// dawn and dusk register as moments.
    var tint: (inner: Color, outer: Color) {
      switch self {
      case .dawn:  return (Color(red: 1.00, green: 0.64, blue: 0.42),
                           Color(red: 1.00, green: 0.82, blue: 0.55))
      case .day:   return (Color(red: 1.00, green: 0.88, blue: 0.62),
                           Color(red: 0.62, green: 0.78, blue: 1.00))
      case .dusk:  return (Color(red: 1.00, green: 0.48, blue: 0.32),
                           Color(red: 0.56, green: 0.42, blue: 0.86))
      case .night: return (Color(red: 0.42, green: 0.46, blue: 0.96),
                           Color(red: 0.22, green: 0.26, blue: 0.58))
      }
    }
  }

  // MARK: - The sky model
  //
  // ONE table describes the whole sky: near-black night, white day, dawn
  // warmth and dusk ember at the transitions, with the transition
  // positions anchored to sunrise/sunset (SolarClock — real times from the
  // device's time zone). The halo wears it as an angular gradient; the
  // glow *samples* it at "now", so the light behind the dial is always
  // literally the sky's color at the current hour.

  // Monochrome night logic, no color. Day is TRANSPARENT (plain glass —
  // sky-blue painted the hero blue, opaque white read as an HDR burn). Night
  // is a neutral DARK shade. The band simply carries night as a dark arc
  // that fades to clear over the daylight hours — a "this part of the circle
  // is night" cue, not a warm dawn/dusk wash (which read as orange blobs).
  private typealias SkyStop = (r: Double, g: Double, b: Double, a: Double)
  private static let nightStop: SkyStop = (0.08, 0.09, 0.12, 1.0)
  private static let dayStop: SkyStop   = (1.00, 1.00, 1.00, 0.0)

  /// The sky's color stops over the day, in HOURS (0..24). Sunrise/sunset
  /// are clamped into a sane visual band so an extreme computed time (or a
  /// polar-adjacent fix) can't fold the gradient onto itself.
  private static func skyStops(times: SolarClock.Times) -> [(hour: Double, stop: SkyStop)] {
    let sr = min(10, max(4, times.sunriseHour))
    let ss = min(22, max(15, times.sunsetHour))
    // Dark through the night, ramping straight to clear across ~3h around
    // sunrise and back around sunset — a luminance fade, no warm waypoint.
    return [
      (0, nightStop),
      (sr - 1.5, nightStop),
      (sr + 1.5, dayStop),
      (ss - 1.5, dayStop),
      (min(23.9, ss + 1.5), nightStop),
      (24, nightStop),
    ]
  }

  /// The 24-hour "solar ring" — the Apple-Watch-Solar-style day band the
  /// hero dial wears. Stop locations are fractions of the day (0 =
  /// midnight), matching the dial's angle convention (midnight at top,
  /// clockwise) — stroke a circle with this as a conic gradient starting
  /// at -90°. The day span is fully transparent, so the band only carries
  /// night dark and dawn/dusk warmth.
  @MainActor
  static func solarRing(times: SolarClock.Times) -> Gradient {
    Gradient(stops: skyStops(times: times).map {
      .init(color: Color(red: $0.stop.r, green: $0.stop.g, blue: $0.stop.b)
              .opacity($0.stop.a),
            location: $0.hour / 24)
    })
  }

  /// The sky's color at a given hour — a linear sample (color AND alpha) of
  /// the same stops the ring draws. Fully transparent through midday.
  @MainActor
  static func sky(atHour hour: Double, times: SolarClock.Times) -> Color {
    let stops = skyStops(times: times)
    let h = min(24, max(0, hour))
    guard let upper = stops.firstIndex(where: { $0.hour >= h }), upper > 0 else {
      let s = stops.first!.stop
      return Color(red: s.r, green: s.g, blue: s.b).opacity(s.a)
    }
    let lo = stops[upper - 1], hi = stops[upper]
    let span = max(0.0001, hi.hour - lo.hour)
    let t = (h - lo.hour) / span
    return Color(red: lo.stop.r + (hi.stop.r - lo.stop.r) * t,
                 green: lo.stop.g + (hi.stop.g - lo.stop.g) * t,
                 blue: lo.stop.b + (hi.stop.b - lo.stop.b) * t)
      .opacity(lo.stop.a + (hi.stop.a - lo.stop.a) * t)
  }

  /// Convenience: the sky right now — today's solar times sampled at
  /// `date`'s local hour. What the glow and halo wear.
  @MainActor
  static func sky(at date: Date) -> Color {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    let hour = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
    return sky(atHour: hour, times: SolarClock.today(now: date))
  }
}

/// The glow hugging the dial's disc edge, in one of two styles:
///
///   • `.sky` — the solar ring's OWN gradient, blurred and spilling off the
///     face: night side indigo, day side blue, the sunrise edge dawn-orange,
///     in the same angular positions the band holds (midnight at top).
///   • `.now` — one uniform glow in the CURRENT hour's light (the gradient
///     sampled at the minute), drifting through sunrise as time passes.
///
/// The hero keys the style off the dial's window (today → `.sky`, week →
/// `.now`) so the two treatments can be compared live with a tap. Stronger
/// in dark mode (glow is a dark-room phenomenon). Two blurred rings: a
/// tight bright one and a wide soft falloff.
struct AmbientHalo: View {
  enum Style { case sky, now }

  /// Diameter of the disc edge the halo hugs (the dial's clock face).
  let diameter: CGFloat
  var style: Style = .sky

  @Environment(DayClock.self) private var clock
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let times = SolarClock.today(now: clock.now)
    // A one-color gradient renders as a uniform ring, so both styles share
    // the same structure (and the same -90° start as the dial's geometry).
    let gradient = style == .sky
      ? AmbientLight.solarRing(times: times)
      : Gradient(colors: [AmbientLight.sky(at: clock.now)])
    let shading = AngularGradient(gradient: gradient, center: .center,
                                  angle: .degrees(-90))
    let dark = colorScheme == .dark
    ZStack {
      // Under-band wash — the strongest layer, sitting DIRECTLY beneath
      // the glass donut's band so the glass has real color to refract:
      // the band reads as stained glass, not frosted white. Sized to the
      // band's footprint (hole edge → disc edge).
      Circle()
        .stroke(shading, lineWidth: 60)
        .blur(radius: 24)
        .opacity(dark ? 0.65 : 0.50)
        .frame(width: diameter * 0.71, height: diameter * 0.71)
      Circle()
        .stroke(shading, lineWidth: 10)
        .blur(radius: 12)
        .opacity(dark ? 0.70 : 0.45)
      Circle()
        .stroke(shading, lineWidth: 26)
        .blur(radius: 26)
        .opacity(dark ? 0.45 : 0.25)
    }
    .frame(width: diameter, height: diameter)
    .animation(.easeInOut(duration: 1.5), value: times)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// The wide radial backwash behind the day dial — the same sampled sky
/// color as `AmbientHalo`, falling off to clear. Self-observes `DayClock`
/// so the minute tick re-renders only this view, never the parent
/// dashboard (same isolation pattern as `WelcomeHeaderSection`).
struct AmbientGlow: View {
  @Environment(DayClock.self) private var clock
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let sky = AmbientLight.sky(at: clock.now)
    // Slightly stronger in dark mode, where a faint wash would vanish
    // against near-black; still far below "background" strength.
    let boost: Double = colorScheme == .dark ? 1.4 : 1.0
    RadialGradient(
      colors: [sky.opacity(0.16 * boost),
               sky.opacity(0.08 * boost),
               .clear],
      center: .center,
      startRadius: 0,
      endRadius: 220
    )
    .animation(.easeInOut(duration: 1.5), value: sky)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
