import SwiftUI

// Mood catalog — the four quadrants of Russell's Circumplex Model of
// Affect (valence × arousal), each with a 3×3 sub-grid of emotion words.
//
// Word sources: drawn from published affect-circumplex coordinates
// (Russell 1980, Posner/Russell/Peterson 2005, Feldman-Barrett valence-
// arousal mappings) so the vocabulary is open and academic rather than
// derived from the proprietary Mood Meter / RULER list.

enum MoodQuadrant: String, CaseIterable, Identifiable, Hashable {
  case hap   // High arousal, Pleasant   (yellow)
  case han   // High arousal, uNpleasant (red)
  case lan   // Low arousal, uNpleasant  (blue)
  case lap   // Low arousal, Pleasant    (green)

  var id: String { rawValue }

  /// Plain-English label per the user's preference (chosen over the
  /// HAP/HAN/LAP/LAN academic shorthand). Keeps the UI inviting while
  /// the sub-grid axes still convey the circumplex.
  var title: String {
    switch self {
    case .hap: return "High energy, pleasant"
    case .han: return "High energy, unpleasant"
    case .lan: return "Low energy, unpleasant"
    case .lap: return "Low energy, pleasant"
    }
  }

  /// One-word affective summary used in the quadrant card subtitle.
  var blurb: String {
    switch self {
    case .hap: return "Activated · positive"
    case .han: return "Activated · negative"
    case .lan: return "Quiet · negative"
    case .lap: return "Quiet · positive"
    }
  }

  /// Quadrant tint. Matches the "How We Feel" / Mood Meter color
  /// convention (yellow/red/blue/green) since that mapping is now broadly
  /// recognized — but values are tuned for dark mode legibility.
  var color: Color {
    switch self {
    case .hap: return Color(red: 0.95, green: 0.78, blue: 0.20)
    case .han: return Color(red: 0.93, green: 0.36, blue: 0.30)
    case .lan: return Color(red: 0.42, green: 0.55, blue: 0.92)
    case .lap: return Color(red: 0.45, green: 0.78, blue: 0.52)
    }
  }
}

struct MoodEmotion: Hashable, Identifiable {
  let quadrant: MoodQuadrant
  /// 1...3. Higher = more activated (closer to the high-arousal pole).
  let arousal: Int
  /// 1...3. Higher = more pleasant (closer to the pleasant pole).
  let valence: Int
  let word: String
  var id: String { "\(quadrant.rawValue)-\(arousal)-\(valence)" }
}

enum MoodCatalog {
  /// Lookup the catalog emotion for a stored event's coordinates. Falls
  /// back to the stored `emotion` string when the coordinates land
  /// outside 1...3 (shouldn't happen, but keeps reads total).
  static func emotion(quadrant: String, arousal: Int, valence: Int) -> MoodEmotion? {
    guard let q = MoodQuadrant(rawValue: quadrant) else { return nil }
    return grid(for: q).first { $0.arousal == arousal && $0.valence == valence }
  }

  /// The 3×3 emotion grid for a quadrant. Index by `(arousal, valence)`
  /// — both 1...3. Higher arousal = more activated; higher valence =
  /// more pleasant.
  static func grid(for q: MoodQuadrant) -> [MoodEmotion] {
    words(for: q).enumerated().map { idx, word in
      // Row-major: row 0 = arousal 3 (top), row 2 = arousal 1 (bottom).
      // Col 0 = valence 1 (left), col 2 = valence 3 (right).
      let row = idx / 3
      let col = idx % 3
      return MoodEmotion(quadrant: q,
                         arousal: 3 - row,
                         valence: col + 1,
                         word: word)
    }
  }

  /// 9 words per quadrant. Order is left→right, top→bottom in the picker.
  private static func words(for q: MoodQuadrant) -> [String] {
    switch q {
    case .hap:
      return ["Excited",   "Elated",     "Ecstatic",
              "Eager",     "Upbeat",     "Joyful",
              "Focused",   "Alive",      "Content"]
    case .han:
      return ["Enraged",   "Panicked",   "Stressed",
              "Angry",     "Anxious",    "Frustrated",
              "Irritated", "Tense",      "Restless"]
    case .lan:
      return ["Bored",     "Discouraged","Disappointed",
              "Sad",       "Lonely",     "Glum",
              "Drained",   "Hopeless",   "Despondent"]
    case .lap:
      return ["Mellow",    "Easygoing",  "Pleased",
              "Calm",      "Grateful",   "Loved",
              "Relaxed",   "Serene",     "Tranquil"]
    }
  }
}
