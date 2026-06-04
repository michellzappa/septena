import SwiftUI
import FoundationModels

// Centered greeting at the top of the dashboard home.
//
// The line is written on-device by the system language model (Apple
// Intelligence), personalised with the name + tone set in Settings.
// Generation is 0.3–1s+ and the app opens faster than that, so we never
// block on it:
//
//   1. A persistent cache (`@AppStorage`) means the second open of any phase
//      is instant. Most opens are instant.
//   2. Without live context we pre-generate the rest of today's phases in the
//      background, so morning→afternoon→evening rollovers are already cached.
//   3. While a cold line is in flight we render the plain fallback greeting
//      and cross-fade the generated line in when it lands.
//
// Data-aware mode (Settings → Welcome) injects a short phrase built from the
// dashboard's already-loaded state — no new fetch. Because that snapshot
// shifts through the day it can't be pre-generated, and it's cached against a
// coarse signature so small changes don't trigger fresh calls.
//
// No Apple Intelligence / no name → it degrades to the plain greeting.

/// Live, already-loaded context the header may weave into the greeting.
struct WelcomeContext {
  /// Human phrase the model can nod to, e.g. "3 habits still to check off".
  let phrase: String
  /// Coarse fingerprint of that phrase. The line only regenerates when this
  /// changes, so checking off a single item doesn't trigger a new call.
  let signature: String
}

struct WelcomeHeader: View {
  let now: Date
  var context: WelcomeContext? = nil

  @AppStorage(SettingsKey.welcomeName) private var name: String = ""
  @AppStorage(SettingsKey.welcomeTone) private var toneRaw: String = WelcomeTone.warm.rawValue
  @AppStorage(SettingsKey.welcomeCache) private var cacheJSON: String = ""
  @State private var line: String = ""
  @State private var isGenerating = false
  @State private var rerollTick = 0

  private var tone: WelcomeTone { WelcomeTone(rawValue: toneRaw) ?? .warm }
  private var phase: WelcomePhase { .resolve(at: now) }
  private var currentSignature: String { context?.signature ?? "" }

  /// Invalidates the cache when the day, name or tone changes.
  private var stamp: String {
    "\(Int(now.timeIntervalSince1970 / 86_400))|\(name)|\(tone.rawValue)"
  }

  private var fallback: String {
    name.isEmpty ? phase.greeting : "\(phase.greeting), \(name)"
  }

  var body: some View {
    Text(line.isEmpty ? fallback : line)
      .font(.septenaWelcomeTitle)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity)
      .contentTransition(.opacity)
      .opacity(isGenerating ? 0.5 : 1)
      .animation(.easeInOut(duration: 0.2), value: isGenerating)
      .contentShape(.rect)
      .onTapGesture { Task { await regenerate() } }
      .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: rerollTick)
      .accessibilityElement(children: .combine)
      .accessibilityHint("Double tap for a new greeting")
      .accessibilityAction(named: "New greeting") { Task { await regenerate() } }
      .task(id: "\(stamp)|\(phase.rawValue)|\(currentSignature)") { await refresh() }
  }

  @MainActor
  private func refresh() async {
    var cache = WelcomeCache.load(cacheJSON, stamp: stamp)

    // Instant if we already have a valid line for this phase + data snapshot.
    if let entry = cache.lines[phase.rawValue], entry.sig == currentSignature {
      line = entry.text
    }

    guard OnDeviceAI.isAvailable, !name.isEmpty else {
      #if DEBUG
      print("[Welcome] not generating — available=\(OnDeviceAI.isAvailable), name=\(name.isEmpty ? "empty" : "set"), reason=\(OnDeviceAI.unavailableReason ?? "n/a")")
      #endif
      return
    }
    WelcomeGenerator.prewarm()

    // Data-aware lines depend on the live snapshot, so we can't pre-generate
    // future phases; without context we pre-fill the rest of the day.
    let phases = context == nil ? WelcomePhase.upcoming(from: phase) : [phase]
    for p in phases {
      let sig = (p == phase) ? currentSignature : ""
      if let entry = cache.lines[p.rawValue], entry.sig == sig { continue }
      let phrase = (p == phase) ? context?.phrase : nil
      guard let generated = await WelcomeGenerator.line(
        name: name, phase: p, date: now, tone: tone, context: phrase
      ) else { continue }
      cache.lines[p.rawValue] = WelcomeCache.Entry(text: generated, sig: sig)
      cacheJSON = cache.encoded()
      // Animate the swap so the box grows/shrinks (and content below slides)
      // rather than snapping to the new line count.
      if p == phase { withAnimation(.smooth(duration: 0.4)) { line = generated } }
    }
  }

  /// Tap-to-reroll: force a fresh line for the current phase and cache it.
  /// A fresh session at default temperature almost always yields a new line.
  @MainActor
  private func regenerate() async {
    guard !isGenerating, OnDeviceAI.isAvailable, !name.isEmpty else { return }
    isGenerating = true
    defer { isGenerating = false }

    guard let generated = await WelcomeGenerator.line(
      name: name, phase: phase, date: now, tone: tone, context: context?.phrase
    ) else { return }
    var cache = WelcomeCache.load(cacheJSON, stamp: stamp)
    cache.lines[phase.rawValue] = WelcomeCache.Entry(text: generated, sig: currentSignature)
    cacheJSON = cache.encoded()
    withAnimation(.smooth(duration: 0.4)) { line = generated }
    rerollTick += 1  // fires the haptic
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

// MARK: - Tone

enum WelcomeTone: String, CaseIterable, Identifiable {
  case warm, dry, minimal

  var id: String { rawValue }

  var label: String {
    switch self {
    case .warm:    return "Warm"
    case .dry:     return "Dry"
    case .minimal: return "Minimal"
    }
  }

  /// Voice direction handed to the model.
  var direction: String {
    switch self {
    case .warm:    return "Warm and friendly, with a little heart."
    case .dry:     return "Dry and understated — a touch of wit, never gushing."
    case .minimal: return "Minimal and plain — a clean greeting, nothing extra."
    }
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

  static func line(name: String,
                   phase: WelcomePhase,
                   date: Date,
                   tone: WelcomeTone,
                   context: String?) async -> String? {
    // Enough temperature that each reroll varies, but not so high it drifts
    // into wrong facts (like naming the wrong weekday).
    let options = GenerationOptions(temperature: 0.9)
    let today = date.formatted(.dateTime.weekday(.wide))
    let request = prompt(name: name, phase: phase, date: date, tone: tone, context: context)

    // Up to two attempts: reject any line that names a day other than today.
    for attempt in 0..<2 {
      do {
        let raw = try await LanguageModelSession().respond(to: request, options: options).content
        let cleaned = sanitize(raw)
        if !namesWrongWeekday(cleaned, today: today) { return cleaned }
        #if DEBUG
        print("[Welcome] rejected wrong-weekday line (attempt \(attempt)): \(cleaned)")
        #endif
      } catch {
        #if DEBUG
        print("[Welcome] generation failed for \(phase.rawValue): \(error)")
        #endif
        return nil
      }
    }
    return nil
  }

  /// True if the line names any weekday other than today's — guards against
  /// the model confidently greeting the wrong day.
  private static func namesWrongWeekday(_ text: String, today: String) -> Bool {
    let lower = text.lowercased()
    return Calendar.current.weekdaySymbols.contains { day in
      day.caseInsensitiveCompare(today) != .orderedSame && lower.contains(day.lowercased())
    }
  }

  private static func prompt(name: String,
                             phase: WelcomePhase,
                             date: Date,
                             tone: WelcomeTone,
                             context: String?) -> String {
    let weekday = date.formatted(.dateTime.weekday(.wide))
    let length = context == nil ? "roughly two to five words" : "roughly four to eight words"
    let contextBlock = context.map {
      """

      Today so far: \($0).
      You may nod to this warmly and lightly — never scold, count, or imply they're behind.
      """
    } ?? ""
    return """
    Write ONE short, characterful greeting for the home screen of \(name)'s personal app.

    Time of day: \(phase.rawValue).
    Day: \(weekday).
    Tone: \(tone.direction)\(contextBlock)

    Keep it brief — \(length), ending with the name \(name).
    Give it a little personality and specificity to the moment. Do NOT default
    to the plainest "Good \(phase.rawValue), \(name)" — reach for something with a bit of life.

    Examples of the range and tone:
    - Rise and shine, \(name)
    - Happy \(weekday), \(name)
    - Evening already, \(name)?
    - Back at it, \(name)

    Guidelines:
    - Always end with the name \(name).
    - Today is \(weekday). If you name a day, it MUST be \(weekday) — never any other day.
    - Fit the time of day; the day of the week may flavor it, but don't force it.
    - Grounded and human, never corporate or saccharine.
    - Vary it each time — surprise me a little.
    - No emoji. No quotation marks.

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
/// `@AppStorage`; a changed `stamp` (new day, name or tone) resets it. Each
/// entry carries the data-context signature it was generated for, so a stale
/// data-aware line is rebuilt when the snapshot meaningfully changes.
private struct WelcomeCache: Codable {
  struct Entry: Codable {
    var text: String
    var sig: String
  }

  var stamp: String
  var lines: [String: Entry]

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
