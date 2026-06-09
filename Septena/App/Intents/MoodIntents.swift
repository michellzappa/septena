import AppIntents
import Foundation

// Mood — affect check-in. Mood is the LEAST headless-friendly section: in
// the app it's a 2D affect circumplex (valence × arousal) where you tap a
// quadrant and then a specific cell in a 3×3 emotion grid, landing on exact
// arousal/valence coordinates (each 1…3) plus a vocabulary word. A voice /
// Shortcuts call can't reasonably drive a 2D grid, so this is a deliberately
// REDUCED-FIDELITY log: the user names a quadrant (and optionally a free-text
// emotion + note), and we synthesize the rest.
//
// The mutator (`MoodMutator.logEntry`) requires non-optional `arousal` and
// `valence` Ints (1…3) — the circumplex coordinates the UI would normally
// supply. With only a quadrant in hand we map each quadrant to its in-quadrant
// corner so the entry (a) lands in the correct quadrant and (b) reads with the
// right valence sign for the `mood.avg_valence_week` aim metric. See
// `MoodQuadrantChoice.coordinates`. Boot + auto-enable come from SectionLogIntent;
// the Siri phrases live in `SeptenaShortcuts` (SectionLogIntent.swift).
// Mutator + entity types come from SeptenaCore (same module — no import).
//
// NOTE: `logEntry` also mirrors the sample into Apple Health via
// `HealthKitBridge.writeMood(quadrant:valence:emotion:date:)`. That happens
// inside the mutator from the quadrant/valence/emotion we pass — no extra
// arguments here, but it means a headless log can produce a HealthKit write.

// MARK: - Enums

/// The four quadrants of the affect circumplex, surfaced to Siri / Shortcuts
/// as a pickable value. Raw value is the token the mutator stores in
/// `quadrant` — it must match `MoodQuadrantChoice` (the in-app enum in
/// MoodCatalog.swift): hap / han / lan / lap. Labels mirror that enum's
/// `.title`.
///
/// This is a separate type from the SwiftUI `MoodQuadrantChoice` on purpose: an
/// `AppEnum` carries display metadata the OS extracts statically, and keeping
/// the two decoupled means the picker can't accidentally drift onto a
/// SwiftUI/`Color` dependency. The raw strings are the contract between them.
enum MoodQuadrantChoice: String, AppEnum {
  case pleasantEnergetic = "hap"   // high arousal, pleasant
  case unpleasantEnergetic = "han" // high arousal, unpleasant
  case unpleasantCalm = "lan"      // low arousal, unpleasant
  case pleasantCalm = "lap"        // low arousal, pleasant

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Mood" }

  static var caseDisplayRepresentations: [MoodQuadrantChoice: DisplayRepresentation] {
    [
      .pleasantEnergetic: "High Energy, Pleasant",
      .unpleasantEnergetic: "High Energy, Unpleasant",
      .unpleasantCalm: "Low Energy, Unpleasant",
      .pleasantCalm: "Low Energy, Pleasant",
    ]
  }

  /// Circumplex coordinates `(arousal, valence)`, each 1…3, that the mutator
  /// requires. We pick each quadrant's in-quadrant corner: the committing
  /// extreme on both axes (3 = high / pleasant, 1 = low / unpleasant). Only
  /// the extremes unambiguously place an entry in a quadrant (2 is the neutral
  /// midpoint), and these exact pairs resolve to a real cell in
  /// `MoodCatalog`'s grid, so the synthesized row stays internally consistent.
  var coordinates: (arousal: Int, valence: Int) {
    switch self {
    case .pleasantEnergetic: return (3, 3)
    case .unpleasantEnergetic: return (3, 1)
    case .unpleasantCalm: return (1, 1)
    case .pleasantCalm: return (1, 3)
    }
  }

  /// Plain-English fallback stored as the `emotion` when the caller gives no
  /// free-text word. Deliberately the neutral quadrant name rather than the
  /// grid's extreme word (e.g. "Ecstatic" / "Enraged"): a quadrant-only voice
  /// log means "I'm somewhere in here," not "I'm at the pole." Mirrors the
  /// in-app `MoodQuadrant.title`. The stored string is shown verbatim on read
  /// (the app does not re-derive it from coordinates), so this label is safe.
  var defaultEmotion: String {
    switch self {
    case .pleasantEnergetic: return "High Energy, Pleasant"
    case .unpleasantEnergetic: return "High Energy, Unpleasant"
    case .unpleasantCalm: return "Low Energy, Unpleasant"
    case .pleasantCalm: return "Low Energy, Pleasant"
    }
  }
}

// MARK: - Intents

/// The daily log action: record a mood check-in by quadrant. Reduced-fidelity
/// vs. the in-app 2D picker — see the file header.
struct LogMoodIntent: SectionLogIntent {
  static let sectionKey = "mood"
  static let title: LocalizedStringResource = "Log Mood"
  static let description = IntentDescription(
    "Log how you feel by affect quadrant. A simplified version of the in-app circumplex check-in.")

  @Parameter(title: "Mood")
  var quadrant: MoodQuadrantChoice

  @Parameter(title: "Emotion", requestValueDialog: "Which word fits best?")
  var emotion: String?

  @Parameter(title: "Note")
  var note: String?

  static var parameterSummary: some ParameterSummary {
    Summary("Log a \(\.$quadrant) mood") {
      \.$emotion
      \.$note
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    let coords = quadrant.coordinates
    let trimmedEmotion = emotion?.trimmingCharacters(in: .whitespacesAndNewlines)
    let word = (trimmedEmotion?.isEmpty ?? true) ? quadrant.defaultEmotion : trimmedEmotion!
    SeptenaServices.shared.moodMutator.logEntry(
      date: SeptenaDate.today,
      time: nowTimeString(),
      quadrant: quadrant.rawValue,
      arousal: coords.arousal,
      valence: coords.valence,
      emotion: word,
      note: note)
    return .result(dialog: "Logged your mood: \(word).")
  }

  /// Current HH:mm:ss, matching the in-app AddMoodPage quick-log (which
  /// formats `time` with "HH:mm:ss").
  private func nowTimeString() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: .now)
  }
}
