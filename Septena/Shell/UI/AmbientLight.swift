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
}

/// The radial glow behind the day dial. Self-observes `DayClock` so the
/// minute tick re-renders only this view, never the parent dashboard (same
/// isolation pattern as `WelcomeHeaderSection`). Phase changes are rare
/// (four a day) and cross-fade slowly — light shifting, not a UI event.
struct AmbientGlow: View {
  @Environment(DayClock.self) private var clock
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let phase = AmbientLight.Phase.from(date: clock.now)
    let (inner, outer) = phase.tint
    // Slightly stronger in dark mode, where a faint wash would vanish
    // against near-black; still far below "background" strength.
    let boost: Double = colorScheme == .dark ? 1.35 : 1.0
    RadialGradient(
      colors: [inner.opacity(0.16 * boost),
               outer.opacity(0.09 * boost),
               .clear],
      center: .center,
      startRadius: 0,
      endRadius: 220
    )
    .animation(.easeInOut(duration: 2.0), value: phase)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
