import SwiftUI

// Centered time-of-day greeting at the top of the dashboard home.
// Mirrors the webapp's `overview-dashboard` welcome: a phase-scoped
// greeting plus a deterministic subtitle that stays stable within a day.
//
// Phase 1 keeps the phase table hardcoded with the same copy the webapp
// ships by default. When the generative pass lands later, swap
// `WelcomePhase.resolve` for a provider — the view stays the same.

struct WelcomeHeader: View {
  let now: Date

  private var phase: WelcomePhase { WelcomePhase.resolve(at: now) }
  private var subtitle: String { phase.subtitle(on: now) }

  var body: some View {
    VStack(spacing: 4) {
      Text(phase.greeting)
        .font(.septenaScreenTitle)
        .multilineTextAlignment(.center)
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

enum WelcomePhase: String, CaseIterable {
  case morning, afternoon, evening

  var greeting: String {
    switch self {
    case .morning:   return "Good morning"
    case .afternoon: return "Good afternoon"
    case .evening:   return "Good evening"
    }
  }

  var subtitles: [String] {
    switch self {
    case .morning:
      return ["Start your day strong — check habits and supplements"]
    case .afternoon:
      return ["Midday check-in — how's nutrition and training?"]
    case .evening:
      return ["Wind down — review the day and prep for tomorrow"]
    }
  }

  static func resolve(at date: Date) -> WelcomePhase {
    let hour = Calendar.current.component(.hour, from: date)
    switch hour {
    case ..<11:  return .morning
    case ..<17:  return .afternoon
    default:     return .evening
    }
  }

  /// Pick a subtitle deterministically from (phase, calendar day) so the
  /// line is stable across re-renders within a day but rotates when the
  /// phase rolls over or a new day starts.
  func subtitle(on date: Date) -> String {
    let subs = subtitles
    guard !subs.isEmpty else { return "" }
    let day = Int(date.timeIntervalSince1970 / 86_400)
    var hash = 0
    for ch in (rawValue + "\(day)").unicodeScalars {
      hash = (hash &* 31 &+ Int(ch.value)) & 0x7fff_ffff
    }
    return subs[hash % subs.count]
  }
}
