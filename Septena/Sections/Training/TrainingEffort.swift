import SwiftUI

// Effort axis for a strength set — one canonical value, two presentations.
//
// The value stored on the entry never changes: it stays one of the canonical
// difficulty keys (`easy` / `moderate` / `hard` / `max`), the same contract
// shared with CloudKit, the MCP tools and `docs/CloudKitSchema.md`. The
// user-chosen *scale* only swaps how that rung is shown and entered — plain
// difficulty words, or RIR (reps in reserve), the proximity-to-failure number
// lifters program by.
//
// The four rungs map 1:1 onto the four reliably-distinguishable RIR anchors:
//   Max ↔ 0 (to failure) · Hard ↔ 1 · Moderate ↔ 2 · Easy ↔ 3+ (open-ended).
// RIR estimation accuracy falls apart past ~3–4, so a finer numeric scale would
// be false precision; these four cover the meaningful spread, and 0 (to failure)
// is the single most important value to be able to log.

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
  let key: String     // canonical: easy | moderate | hard | max
  let label: String   // Easy | Moderate | Hard | Max
  let short: String   // Easy | Med | Hard | Max  (pill-width)
  let rir: Int        // 3 | 2 | 1 | 0 — higher RIR = easier (more reps left)
  /// The easy end is open-ended ("3 or more reps in reserve"), so its RIR reads
  /// "3+" rather than a hard "3".
  let rirOpen: Bool
  var id: String { key }

  /// RIR shown to the user, e.g. "0", "1", "2", "3+".
  var rirLabel: String { rirOpen ? "\(rir)+" : "\(rir)" }
}

enum TrainingEffort {
  /// Ordered easy → max (left → right in the picker).
  static let levels: [EffortLevel] = [
    EffortLevel(key: "easy",     label: "Easy",     short: "Easy", rir: 3, rirOpen: true),
    EffortLevel(key: "moderate", label: "Moderate", short: "Med",  rir: 2, rirOpen: false),
    EffortLevel(key: "hard",     label: "Hard",     short: "Hard", rir: 1, rirOpen: false),
    EffortLevel(key: "max",      label: "Max",      short: "Max",  rir: 0, rirOpen: false),
  ]

  /// Fold any stored/legacy spelling onto a canonical key. `medium` was written
  /// by an older logger; `failure` is the hosted gateway's word for to-failure.
  /// Returns nil for empty/unknown (treated as "unrated").
  static func canonicalKey(_ raw: String?) -> String? {
    switch (raw ?? "").lowercased() {
    case "easy":               return "easy"
    case "moderate", "medium": return "moderate"
    case "hard":               return "hard"
    case "max", "failure":     return "max"
    default:                   return nil
    }
  }

  static func level(forKey raw: String?) -> EffortLevel? {
    guard let key = canonicalKey(raw) else { return nil }
    return levels.first { $0.key == key }
  }

  /// The number drawn on a pill for this rung under `scale`.
  /// Difficulty: ordinal 1…4 easy→max. RIR: reps-in-reserve "3+"…"0".
  static func pillNumber(for level: EffortLevel, scale: EffortScale) -> String {
    switch scale {
    case .difficulty: return "\(4 - level.rir)"   // rir 3→1 … 0→4
    case .rir:        return level.rirLabel
    }
  }

  /// Full label for a stored key under `scale`, e.g. "Max" or "RIR 0".
  /// Returns nil when the entry carries no recognizable rung.
  static func displayLabel(forKey raw: String?, scale: EffortScale) -> String? {
    guard let lvl = level(forKey: raw) else { return nil }
    switch scale {
    case .difficulty: return lvl.label
    case .rir:        return "RIR \(lvl.rirLabel)"
    }
  }
}
