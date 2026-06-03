import SwiftUI
import FoundationModels

// Centered greeting at the top of the dashboard home.
//
// The line is written on-device by the system language model (Apple
// Intelligence), personalised with the name set in Settings. Generation is
// 0.3–1s+ and the app opens faster than that, so we never block on it:
//
//   1. A persistent cache (`@AppStorage`) means the second open of any phase
//      is instant. Most opens are instant.
//   2. When a phase is generated we keep going and pre-generate the rest of
//      today's phases in the background, so morning→afternoon→evening
//      rollovers are already cached. The only cold moment is the first open
//      of a fresh day.
//   3. While a cold line is in flight we render the plain fallback greeting
//      and cross-fade the generated line in when it lands.
//
// No Apple Intelligence / no name → it degrades to the plain greeting.

struct WelcomeHeader: View {
  let now: Date

  @AppStorage(SettingsKey.welcomeName) private var name: String = ""
  @AppStorage(SettingsKey.welcomeCache) private var cacheJSON: String = ""
  @State private var line: String = ""
  @State private var isGenerating = false

  private var phase: WelcomePhase { .resolve(at: now) }

  /// Invalidates the cache when the day rolls over or the name changes.
  private var stamp: String {
    "\(Int(now.timeIntervalSince1970 / 86_400))|\(name)"
  }

  private var fallback: String {
    name.isEmpty ? phase.greeting : "\(phase.greeting), \(name)"
  }

  var body: some View {
    Text(line.isEmpty ? fallback : line)
      .font(.septenaWelcomeTitle)
      .multilineTextAlignment(.center)
      .contentTransition(.opacity)
      .opacity(isGenerating ? 0.5 : 1)
      .animation(.easeInOut(duration: 0.4), value: line)
      .animation(.easeInOut(duration: 0.2), value: isGenerating)
      .frame(maxWidth: .infinity)
      .contentShape(.rect)
      .onTapGesture { Task { await regenerate() } }
      .accessibilityElement(children: .combine)
      .accessibilityHint("Double tap for a new greeting")
      .accessibilityAction(named: "New greeting") { Task { await regenerate() } }
      .task(id: "\(stamp)|\(phase.rawValue)") { await refresh() }
  }

  @MainActor
  private func refresh() async {
    var cache = WelcomeCache.load(cacheJSON, stamp: stamp)

    // Show the cached current-phase line instantly, if we have one.
    if let cached = cache.lines[phase.rawValue] { line = cached }

    guard OnDeviceAI.isAvailable, !name.isEmpty else { return }
    WelcomeGenerator.prewarm()

    // Generate the current phase first (if missing), then fill the rest of
    // the day ahead so later rollovers are instant.
    for p in WelcomePhase.upcoming(from: phase) where cache.lines[p.rawValue] == nil {
      guard let generated = await WelcomeGenerator.line(name: name, phase: p, date: now) else { continue }
      cache.lines[p.rawValue] = generated
      cacheJSON = cache.encoded()
      if p == phase { line = generated }  // cross-fades in over the fallback
    }
  }

  /// Tap-to-reroll: force a fresh line for the current phase and cache it.
  /// A fresh session at default temperature almost always yields a new line.
  @MainActor
  private func regenerate() async {
    guard !isGenerating, OnDeviceAI.isAvailable, !name.isEmpty else { return }
    isGenerating = true
    defer { isGenerating = false }

    guard let generated = await WelcomeGenerator.line(name: name, phase: phase, date: now) else { return }
    var cache = WelcomeCache.load(cacheJSON, stamp: stamp)
    cache.lines[phase.rawValue] = generated
    cacheJSON = cache.encoded()
    line = generated
  }
}

// MARK: - Phases

enum WelcomePhase: String, CaseIterable {
  case morning, afternoon, evening

  var greeting: String {
    switch self {
    case .morning:   return "Good morning"
    case .afternoon: return "Good afternoon"
    case .evening:   return "Good evening"
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

  /// Phases from `phase` to the end of the day — used to pre-generate the
  /// remaining phases once the current one is ready.
  static func upcoming(from phase: WelcomePhase) -> [WelcomePhase] {
    let all = WelcomePhase.allCases
    guard let i = all.firstIndex(of: phase) else { return all }
    return Array(all[i...])
  }
}

// MARK: - On-device generation

private enum WelcomeGenerator {
  /// Loads the model assets ahead of the first real call so the cold-start
  /// line lands sooner. Fire-and-forget hint; safe to call repeatedly.
  @MainActor static func prewarm() {
    guard OnDeviceAI.isAvailable else { return }
    LanguageModelSession().prewarm()
  }

  static func line(name: String, phase: WelcomePhase, date: Date) async -> String? {
    let session = LanguageModelSession()
    guard let raw = try? await session.respond(to: prompt(name: name, phase: phase, date: date)).content else {
      return nil
    }
    return sanitize(raw)
  }

  private static func prompt(name: String, phase: WelcomePhase, date: Date) -> String {
    let weekday = date.formatted(.dateTime.weekday(.wide))
    return """
    Write ONE very short greeting for the home screen of \(name)'s personal app.

    Time of day: \(phase.rawValue).
    Day: \(weekday).

    It must read like a quick hello — at most three words plus the name.
    Examples of the right length and tone:
    - Morning, \(name)
    - Evening already, \(name)
    - Happy \(weekday), \(name)
    - Ready, \(name)?

    Guidelines:
    - Always include the name \(name).
    - Fit the time of day; the day of the week may flavor it, but don't force it.
    - Grounded and human, never corporate.
    - No emoji. No quotation marks.
    - Avoid filler like "Have a great day".

    Respond with only the greeting line, nothing else.
    """
  }

  /// The model is constrained, but guard against stray newlines, wrapping
  /// quotes or trailing punctuation slipping into the title.
  private static func sanitize(_ s: String) -> String {
    var t = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    while let last = t.last, ".!,;:".contains(last) { t.removeLast() }
    return t.trimmingCharacters(in: .whitespaces)
  }
}

// MARK: - Cache

/// Today's generated lines, keyed by phase. Persisted as JSON in
/// `@AppStorage`; a changed `stamp` (new day or new name) resets it.
private struct WelcomeCache: Codable {
  var stamp: String
  var lines: [String: String]

  static func load(_ json: String, stamp: String) -> WelcomeCache {
    if let data = json.data(using: .utf8),
       let cached = try? JSONDecoder().decode(WelcomeCache.self, from: data),
       cached.stamp == stamp {
      return cached
    }
    return WelcomeCache(stamp: stamp, lines: [:])
  }

  func encoded() -> String {
    guard let data = try? JSONEncoder().encode(self) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }
}
