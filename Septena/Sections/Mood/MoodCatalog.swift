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
  /// HAP/HAN/LAP/LAN academic shorthand). Title-cased — these are
  /// proper names for the quadrants, not sentence fragments.
  var title: String {
    switch self {
    case .hap: return String(localized: "High Energy, Pleasant", comment: "Mood quadrant title")
    case .han: return String(localized: "High Energy, Unpleasant", comment: "Mood quadrant title")
    case .lan: return String(localized: "Low Energy, Unpleasant", comment: "Mood quadrant title")
    case .lap: return String(localized: "Low Energy, Pleasant", comment: "Mood quadrant title")
    }
  }

  /// One-word affective summary used in the quadrant card subtitle.
  var blurb: String {
    switch self {
    case .hap: return String(localized: "Activated · Positive", comment: "Mood quadrant subtitle")
    case .han: return String(localized: "Activated · Negative", comment: "Mood quadrant subtitle")
    case .lan: return String(localized: "Quiet · Negative", comment: "Mood quadrant subtitle")
    case .lap: return String(localized: "Quiet · Positive", comment: "Mood quadrant subtitle")
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

  /// Spring physics tuned to embody the quadrant's affect. Used for
  /// finer-grained interactions (chip cascade entry, header pop-in)
  /// where the animation should feel native rather than spectacular.
  var spring: Animation {
    switch self {
    case .hap: return .spring(duration: 0.42, bounce: 0.32)
    case .han: return .spring(duration: 0.38, bounce: 0.18)
    case .lap: return .spring(duration: 0.55, bounce: 0.28)
    case .lan: return .spring(duration: 0.58, bounce: 0.12)
    }
  }

  /// Slower spring used for the marquee transition between the 2×2
  /// quadrant grid and the 3×3 emotion grid. Long enough that the
  /// matched-geometry expand is legible as an event, not just a
  /// near-instant snap. Same bounce profile as `spring` so the
  /// quadrant's character carries through.
  var expandSpring: Animation {
    switch self {
    case .hap: return .spring(duration: 0.85, bounce: 0.34)
    case .han: return .spring(duration: 0.80, bounce: 0.20)
    case .lap: return .spring(duration: 1.05, bounce: 0.30)
    case .lan: return .spring(duration: 1.15, bounce: 0.14)
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

  /// Display-localized form of `word`. Storage and lookup keep the canonical
  /// English `word` (persisted on `MoodEvent.emotion`); only the UI shows this.
  var displayWord: String { MoodCatalog.localizedWord(word) }

  /// 0...1 — how far this cell sits from the circumplex's neutral center
  /// along the path toward its quadrant's signature pole. Used to drive
  /// chip color saturation in the step-2 picker so the cells at the
  /// quadrant's affective peak look the most "themselves."
  ///
  /// Each quadrant's pole is the corner farthest from the circumplex
  /// origin:
  ///   HAP: arousal 3, valence 3 → Ecstatic
  ///   HAN: arousal 3, valence 1 → Enraged
  ///   LAN: arousal 1, valence 1 → Despondent
  ///   LAP: arousal 1, valence 3 → Tranquil
  ///
  /// The "opposite corner" within each quadrant — closest to neutral —
  /// returns 0 (e.g. HAP's Focused at a=1, v=1).
  var intensity: Double {
    let a = Double(arousal - 1)         // 0...2
    let v = Double(valence - 1)         // 0...2
    let arousalDist: Double = {
      switch quadrant {
      case .hap, .han: return a         // pole at high arousal
      case .lap, .lan: return 2 - a     // pole at low arousal
      }
    }()
    let valenceDist: Double = {
      switch quadrant {
      case .hap, .lap: return v         // pole at high valence (pleasant)
      case .han, .lan: return 2 - v     // pole at low valence (unpleasant)
      }
    }()
    return (arousalDist + valenceDist) / 4
  }
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

  /// Display-only localization of an emotion word. Storage and lookup keep the
  /// canonical English `word` (see `MoodEvent.emotion`); the UI shows this.
  /// Keys are literal so they extract into the catalog.
  static func localizedWord(_ word: String) -> String {
    switch word {
    case "Excited":      return String(localized: "Excited", comment: "Mood emotion")
    case "Elated":       return String(localized: "Elated", comment: "Mood emotion")
    case "Ecstatic":     return String(localized: "Ecstatic", comment: "Mood emotion")
    case "Eager":        return String(localized: "Eager", comment: "Mood emotion")
    case "Upbeat":       return String(localized: "Upbeat", comment: "Mood emotion")
    case "Joyful":       return String(localized: "Joyful", comment: "Mood emotion")
    case "Focused":      return String(localized: "Focused", comment: "Mood emotion")
    case "Alive":        return String(localized: "Alive", comment: "Mood emotion")
    case "Content":      return String(localized: "Content", comment: "Mood emotion")
    case "Enraged":      return String(localized: "Enraged", comment: "Mood emotion")
    case "Panicked":     return String(localized: "Panicked", comment: "Mood emotion")
    case "Stressed":     return String(localized: "Stressed", comment: "Mood emotion")
    case "Angry":        return String(localized: "Angry", comment: "Mood emotion")
    case "Anxious":      return String(localized: "Anxious", comment: "Mood emotion")
    case "Frustrated":   return String(localized: "Frustrated", comment: "Mood emotion")
    case "Irritated":    return String(localized: "Irritated", comment: "Mood emotion")
    case "Tense":        return String(localized: "Tense", comment: "Mood emotion")
    case "Restless":     return String(localized: "Restless", comment: "Mood emotion")
    case "Bored":        return String(localized: "Bored", comment: "Mood emotion")
    case "Discouraged":  return String(localized: "Discouraged", comment: "Mood emotion")
    case "Disappointed": return String(localized: "Disappointed", comment: "Mood emotion")
    case "Sad":          return String(localized: "Sad", comment: "Mood emotion")
    case "Lonely":       return String(localized: "Lonely", comment: "Mood emotion")
    case "Glum":         return String(localized: "Glum", comment: "Mood emotion")
    case "Drained":      return String(localized: "Drained", comment: "Mood emotion")
    case "Hopeless":     return String(localized: "Hopeless", comment: "Mood emotion")
    case "Despondent":   return String(localized: "Despondent", comment: "Mood emotion")
    case "Mellow":       return String(localized: "Mellow", comment: "Mood emotion")
    case "Easygoing":    return String(localized: "Easygoing", comment: "Mood emotion")
    case "Pleased":      return String(localized: "Pleased", comment: "Mood emotion")
    case "Calm":         return String(localized: "Calm", comment: "Mood emotion")
    case "Grateful":     return String(localized: "Grateful", comment: "Mood emotion")
    case "Loved":        return String(localized: "Loved", comment: "Mood emotion")
    case "Relaxed":      return String(localized: "Relaxed", comment: "Mood emotion")
    case "Serene":       return String(localized: "Serene", comment: "Mood emotion")
    case "Tranquil":     return String(localized: "Tranquil", comment: "Mood emotion")
    default:             return word
    }
  }
}
