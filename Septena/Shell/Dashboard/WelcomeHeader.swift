import SwiftUI
import FoundationModels

// Centered greeting at the top of the dashboard home.
//
// The line is written on-device by the system language model (Apple
// Intelligence), personalised with the name + tone set in Settings.
// Generation is 0.3–1s+ and the app opens faster than that, so we never
// block on it:
//
//   1. A persistent cache (`@AppStorage`), keyed by the time band the line was
//      written for, means re-opening within the same band is instant — and a
//      line is never reused outside its band (no "almost noon" after noon).
//   2. The clock ticks every 60s; when it crosses into a new band the line
//      refreshes, so the greeting tracks the actual time of day.
//   3. While a cold line is in flight we keep the previous line (or the plain
//      fallback) and cross-fade the generated line in when it lands.
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

  /// The fine-grained time band the greeting is written for. Doubles as the
  /// cache key, so a cached line is reused ONLY within the same band it was
  /// generated for — "late morning" can't survive into the afternoon.
  private var band: TimeBand { .from(date: now) }

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
      .task(id: "\(stamp)|\(band.rawValue)|\(currentSignature)") { await refresh() }
  }

  @MainActor
  private func refresh() async {
    var cache = WelcomeCache.load(cacheJSON, stamp: stamp)

    // Already have a valid line for THIS band + data snapshot? Show it, done.
    if let entry = cache.lines[band.rawValue], entry.sig == currentSignature {
      line = entry.text
      return
    }

    // Otherwise the previous line belongs to a stale band/snapshot — drop to
    // the always-time-correct fallback so we never show "almost noon" at 12:35,
    // then cross-fade the freshly generated line in over it.
    line = ""

    guard OnDeviceAI.isAvailable, !name.isEmpty else {
      #if DEBUG
      print("[Welcome] not generating — available=\(OnDeviceAI.isAvailable), name=\(name.isEmpty ? "empty" : "set"), reason=\(OnDeviceAI.unavailableReason ?? "n/a")")
      #endif
      return
    }
    WelcomeGenerator.prewarm()

    guard let generated = await WelcomeGenerator.line(
      name: name, date: now, tone: tone, context: context?.phrase
    ) else { return }
    cache.lines[band.rawValue] = WelcomeCache.Entry(text: generated, sig: currentSignature)
    cacheJSON = cache.encoded()
    // Animate the swap so the box grows/shrinks (and content below slides)
    // rather than snapping to the new line count.
    withAnimation(.smooth(duration: 0.4)) { line = generated }
  }

  /// Tap-to-reroll: force a fresh line for the current phase and cache it.
  /// A fresh session at default temperature almost always yields a new line.
  @MainActor
  private func regenerate() async {
    guard !isGenerating, OnDeviceAI.isAvailable, !name.isEmpty else { return }
    isGenerating = true
    defer { isGenerating = false }

    guard let generated = await WelcomeGenerator.line(
      name: name, date: now, tone: tone, context: context?.phrase
    ) else { return }
    var cache = WelcomeCache.load(cacheJSON, stamp: stamp)
    cache.lines[band.rawValue] = WelcomeCache.Entry(text: generated, sig: currentSignature)
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

  // Derive from `DayBucket` so the greeting honors the user's configured
  // time-of-day cutoffs (Settings ▸ Time of Day) and never disagrees with
  // the bucket headers, the "Now" marker, or the Next list.
  static func resolve(at date: Date) -> WelcomePhase {
    switch DayBucket.from(date: date) {
    case .morning:   return .morning
    case .afternoon: return .afternoon
    case .evening:   return .evening
    }
  }
}

// MARK: - Time band
//
// Fine-grained time-of-day, far more specific than the three coarse phases —
// so the line can say "late morning" / "just past noon" instead of a blanket
// "good morning". Drives BOTH the model's descriptor and the cache key, so a
// cached line is only ever reused inside the exact window it was written for.

enum TimeBand: String, CaseIterable {
  case earlyMorning, morning, lateMorning, midday, afternoon, earlyEvening, evening, night

  static func from(date: Date) -> TimeBand {
    switch Calendar.current.component(.hour, from: date) {
    case 5..<8:   return .earlyMorning
    case 8..<11:  return .morning
    case 11..<12: return .lateMorning
    case 12..<14: return .midday
    case 14..<17: return .afternoon
    case 17..<19: return .earlyEvening
    case 19..<22: return .evening
    default:      return .night
    }
  }

  var descriptor: String {
    switch self {
    case .earlyMorning: return "early morning, just after dawn"
    case .morning:      return "mid-morning"
    case .lateMorning:  return "late morning"
    case .midday:       return "midday, just past noon, around lunch"
    case .afternoon:    return "mid-afternoon"
    case .earlyEvening: return "early evening, around dusk"
    case .evening:      return "evening"
    case .night:        return "late at night"
    }
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
                   date: Date,
                   tone: WelcomeTone,
                   context: String?) async -> String? {
    // Enough temperature that each reroll varies, but not so high it drifts
    // into wrong facts (like naming the wrong weekday).
    let options = GenerationOptions(temperature: 0.9)
    let today = date.formatted(.dateTime.weekday(.wide))
    let request = prompt(name: name, date: date, tone: tone, context: context)

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
        print("[Welcome] generation failed: \(error)")
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
                             date: Date,
                             tone: WelcomeTone,
                             context: String?) -> String {
    let weekday = date.formatted(.dateTime.weekday(.wide))
    let clock = date.formatted(date: .omitted, time: .shortened)
    let when = TimeBand.from(date: date).descriptor
    let length = context == nil ? "roughly two to five words" : "roughly four to eight words"
    let contextBlock = context.map {
      """

      \(name)'s day right now: \($0).
      If something here fits, weave in ONE detail warmly and lightly — anticipate
      what's coming up, or nod to progress. Never scold, nag, count, or list it back.
      """
    } ?? ""
    return """
    Write ONE short, characterful greeting for the home screen of \(name)'s personal app.

    Right now it is \(clock) on \(weekday) — \(when).
    Tone: \(tone.direction)\(contextBlock)

    Greet \(name) for THIS specific moment. Fit the stated time of day — but do
    NOT claim a precise minute (avoid "almost noon", "just past nine"); the line
    may stay up for a while, so keep it true for the whole \(when) window.
    Keep it brief — \(length), ending with the name \(name).
    Reach for something with a little life; never the plainest greeting.

    Examples of the range and tone (don't reuse verbatim):
    - Bright and early, \(name)
    - Halfway through \(weekday), \(name)
    - Easing into the afternoon, \(name)
    - Winding down, \(name)
    - Burning the midnight oil, \(name)?

    Guidelines:
    - Always end with the name \(name).
    - Match the stated time of day — never say morning in the afternoon or vice versa.
    - Today is \(weekday). If you name a day, it MUST be \(weekday) — never any other day.
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
