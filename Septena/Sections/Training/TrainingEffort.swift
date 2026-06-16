import SwiftUI

// Effort axis for a strength set — one canonical value, two presentations.
//
// The value stored on the entry never changes: it stays one of the canonical
// difficulty keys (`easy` / `moderate` / `hard`), the same contract shared with
// CloudKit, the MCP tools and `docs/CloudKitSchema.md`. The user-chosen *scale*
// only swaps how that rung is shown and entered — plain difficulty words, or
// RIR (reps in reserve), the proximity-to-failure number lifters program by.
//
// RIR is exposed 3…1 (easy→hard) only. "max" (RIR 0, taken to failure) is
// intentionally not offered yet; legacy `max` rows fold into `hard` on read.

enum EffortScale: String, CaseIterable, Identifiable {
  case difficulty
  case rir

  var id: String { rawValue }

  var label: String {
    switch self {
    case .difficulty: return "Difficulty"
    case .rir:        return "RIR"
    }
  }

  /// `@AppStorage` key. Device-local, matching the "Track fasting" / Next-linger
  /// idiom for section display prefs — pure presentation, so no CloudKit sync.
  static let storageKey = "training.effortScale"
}

/// One rung of the effort axis. `key` is the canonical string persisted on the
/// entry; everything else is presentation.
struct EffortLevel: Identifiable, Hashable {
  let key: String     // canonical: easy | moderate | hard
  let label: String   // Easy | Moderate | Hard
  let short: String   // Easy | Med | Hard  (pill-width)
  let rir: Int        // 3 | 2 | 1 — higher RIR = easier (more reps left)
  var id: String { key }
}

enum TrainingEffort {
  /// Ordered easy → hard. Exposed rungs only (no "max" yet).
  static let levels: [EffortLevel] = [
    EffortLevel(key: "easy",     label: "Easy",     short: "Easy", rir: 3),
    EffortLevel(key: "moderate", label: "Moderate", short: "Med",  rir: 2),
    EffortLevel(key: "hard",     label: "Hard",     short: "Hard", rir: 1),
  ]

  /// Fold any stored/legacy spelling onto a canonical key. `medium` was written
  /// by an older logger; `max` predates dropping the 4th rung and folds into
  /// `hard`. Returns nil for empty/unknown (treated as "unrated").
  static func canonicalKey(_ raw: String?) -> String? {
    switch (raw ?? "").lowercased() {
    case "easy":               return "easy"
    case "moderate", "medium": return "moderate"
    case "hard", "max":        return "hard"
    default:                   return nil
    }
  }

  static func level(forKey raw: String?) -> EffortLevel? {
    guard let key = canonicalKey(raw) else { return nil }
    return levels.first { $0.key == key }
  }

  /// Number shown on a pill / in a label for this rung under `scale`.
  /// Difficulty: ordinal 1…3 easy→hard. RIR: reps-in-reserve 3…1.
  static func number(for level: EffortLevel, scale: EffortScale) -> Int {
    switch scale {
    case .difficulty: return 4 - level.rir   // rir 3→1, 2→2, 1→3
    case .rir:        return level.rir
    }
  }

  /// Full label for a stored key under `scale`, e.g. "Hard" or "RIR 1".
  /// Returns nil when the entry carries no recognizable rung.
  static func displayLabel(forKey raw: String?, scale: EffortScale) -> String? {
    guard let lvl = level(forKey: raw) else { return nil }
    switch scale {
    case .difficulty: return lvl.label
    case .rir:        return "RIR \(lvl.rir)"
    }
  }
}
