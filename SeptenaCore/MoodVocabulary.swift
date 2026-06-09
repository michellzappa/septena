// MoodVocabulary — the canonical 4×9 mood word grid (Russell's Circumplex of
// Affect: valence × arousal), single-sourced so every surface that lets you
// pick an emotion agrees on the words AND their coordinates.
//
// The phone's `MoodCatalog` layers display localization on top of this; the
// watch's quick-log mood picker reads it directly. Keeping the words in one
// dependency-free place (no SwiftUI) means the watch's 3×3 grid and the phone's
// can't drift, and a `MoodEvent` logged from either carries the same canonical
// English `emotion` + `arousal`/`valence` the other will render.
public enum MoodVocabulary {
  /// One emotion cell: the canonical English word and its grid coordinates.
  public struct Emotion: Sendable, Hashable {
    public let word: String     // canonical English (persisted on MoodEvent.emotion)
    public let quadrant: String // hap / han / lan / lap
    public let arousal: Int     // 1…3 (higher = more activated)
    public let valence: Int     // 1…3 (higher = more pleasant)
    public init(word: String, quadrant: String, arousal: Int, valence: Int) {
      self.word = word; self.quadrant = quadrant
      self.arousal = arousal; self.valence = valence
    }
  }

  /// The four quadrant keys, in the canonical affect layout order
  /// (top row = high arousal; right column = pleasant).
  public static let quadrants = ["han", "hap", "lan", "lap"]

  /// 9 words per quadrant, ordered left→right then top→bottom — i.e. row 0 is
  /// arousal 3 (top), col 0 is valence 1 (left). Matches `MoodCatalog`.
  public static func words(for quadrant: String) -> [String] {
    switch quadrant {
    case "hap":
      return ["Excited",   "Elated",      "Ecstatic",
              "Eager",     "Upbeat",      "Joyful",
              "Focused",   "Alive",       "Content"]
    case "han":
      return ["Enraged",   "Panicked",    "Stressed",
              "Angry",     "Anxious",     "Frustrated",
              "Irritated", "Tense",       "Restless"]
    case "lan":
      return ["Bored",     "Discouraged", "Disappointed",
              "Sad",       "Lonely",      "Glum",
              "Drained",   "Hopeless",    "Despondent"]
    case "lap":
      return ["Mellow",    "Easygoing",   "Pleased",
              "Calm",      "Grateful",    "Loved",
              "Relaxed",   "Serene",      "Tranquil"]
    default:
      return []
    }
  }

  /// The 3×3 grid for a quadrant as coordinate-tagged cells. Index maps
  /// row-major: row 0 = arousal 3 (top), col 0 = valence 1 (left).
  public static func grid(for quadrant: String) -> [Emotion] {
    words(for: quadrant).enumerated().map { idx, word in
      let row = idx / 3
      let col = idx % 3
      return Emotion(word: word, quadrant: quadrant,
                     arousal: 3 - row, valence: col + 1)
    }
  }
}
