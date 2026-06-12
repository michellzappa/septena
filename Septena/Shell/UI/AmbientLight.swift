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
  // ONE table describes the whole sky: near-black night, sky-blue day,
  // dawn warmth and dusk ember at the transitions, with the transition
  // positions anchored to sunrise/sunset (SolarClock — real, location-based
  // times when the user enables it; the fixed design day otherwise). The
  // solar ring strokes it as a conic gradient; the glow and halo *sample*
  // it at "now", so the light behind the dial is always literally the color
  // of the sky the ring shows at the current hour.

  private typealias RGB = (r: Double, g: Double, b: Double)
  private static let nightRGB: RGB = (0.07, 0.09, 0.20)
  private static let dayRGB: RGB   = (0.36, 0.62, 0.98)
  private static let dawnRGB: RGB  = (1.00, 0.64, 0.42)
  private static let duskRGB: RGB  = (1.00, 0.48, 0.32)

  /// The sky's color stops over the day, in HOURS (0..24). Sunrise/sunset
  /// are clamped into a sane visual band so an extreme computed time (or a
  /// polar-adjacent fix) can't fold the gradient onto itself.
  private static func skyStops(times: SolarClock.Times) -> [(hour: Double, rgb: RGB)] {
    let sr = min(10, max(4, times.sunriseHour))
    let ss = min(22, max(15, times.sunsetHour))
    return [
      (0, nightRGB),
      (sr - 2, nightRGB),
      (sr, dawnRGB),
      (sr + 2, dayRGB),
      (ss - 2.5, dayRGB),
      (ss, duskRGB),
      (min(23.9, ss + 2.5), nightRGB),
      (24, nightRGB),
    ]
  }

  /// The 24-hour "solar ring" — the Apple-Watch-Solar-style day band the
  /// hero dial wears. Stop locations are fractions of the day (0 =
  /// midnight), matching the dial's angle convention (midnight at top,
  /// clockwise) — stroke a circle with this as a conic gradient starting
  /// at -90°.
  @MainActor
  static func solarRing(times: SolarClock.Times) -> Gradient {
    Gradient(stops: skyStops(times: times).map {
      .init(color: Color(red: $0.rgb.r, green: $0.rgb.g, blue: $0.rgb.b),
            location: $0.hour / 24)
    })
  }

  /// The sky's color at a given hour — a linear sample of the same stops
  /// the ring draws.
  @MainActor
  static func sky(atHour hour: Double, times: SolarClock.Times) -> Color {
    let stops = skyStops(times: times)
    let h = min(24, max(0, hour))
    guard let upper = stops.firstIndex(where: { $0.hour >= h }), upper > 0 else {
      let s = stops.first!.rgb
      return Color(red: s.r, green: s.g, blue: s.b)
    }
    let lo = stops[upper - 1], hi = stops[upper]
    let span = max(0.0001, hi.hour - lo.hour)
    let t = (h - lo.hour) / span
    return Color(red: lo.rgb.r + (hi.rgb.r - lo.rgb.r) * t,
                 green: lo.rgb.g + (hi.rgb.g - lo.rgb.g) * t,
                 blue: lo.rgb.b + (hi.rgb.b - lo.rgb.b) * t)
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
