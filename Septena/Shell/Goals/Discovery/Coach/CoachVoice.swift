import Foundation

// CoachVoice — the user-tunable "how should this coach talk to me" layer.
//
// One universal schema (the SAME four dials for every coach); each coach just
// stores its own values. Presets ship distinct *defaults* so the coaches feel
// different out of the box, but every dial exists on every coach. The Custom
// coach additionally carries a free-text note that's appended verbatim.
//
// Each dial value maps to a deterministic prompt fragment (no free-text
// injection from the dials themselves), so the floor discipline in
// `CoachDomain.sharedDiscipline` — cite real numbers, never invent data — can
// never be dialed away.

// MARK: - Dials

enum VoiceWarmth: String, Codable, CaseIterable, Identifiable {
  case gentle, balanced, direct
  var id: String { rawValue }
  var label: String { switch self { case .gentle: "Gentle"; case .balanced: "Balanced"; case .direct: "Direct" } }
  var fragment: String? {
    switch self {
    case .gentle:   return "Lead with warmth and encouragement; be supportive before you're critical."
    case .balanced: return nil
    case .direct:   return "Be matter-of-fact and direct; skip the cushioning."
    }
  }
}

enum VoiceBrevity: String, Codable, CaseIterable, Identifiable {
  case terse, balanced, detailed
  var id: String { rawValue }
  var label: String { switch self { case .terse: "Brief"; case .balanced: "Balanced"; case .detailed: "Detailed" } }
  /// Brevity always owns the length instruction (the shared block no longer
  /// fixes it), so every value emits a fragment.
  var fragment: String {
    switch self {
    case .terse:    return "Keep replies very short — one or two sentences."
    case .balanced: return "Keep replies short — two to four sentences."
    case .detailed: return "A short paragraph is fine when it genuinely helps; still no rambling."
    }
  }
}

enum VoiceChallenge: String, Codable, CaseIterable, Identifiable {
  case supportive, balanced, pushy
  var id: String { rawValue }
  var label: String { switch self { case .supportive: "Supportive"; case .balanced: "Balanced"; case .pushy: "Pushy" } }
  var fragment: String? {
    switch self {
    case .supportive: return "Affirm effort and progress; don't push hard or pile on."
    case .balanced:   return nil
    case .pushy:      return "Hold them accountable; question excuses and push toward the next concrete step."
    }
  }
}

enum VoiceFormality: String, Codable, CaseIterable, Identifiable {
  case casual, neutral, formal
  var id: String { rawValue }
  var label: String { switch self { case .casual: "Casual"; case .neutral: "Neutral"; case .formal: "Formal" } }
  var fragment: String? {
    switch self {
    case .casual:  return "Speak casually, like a friend — contractions, plain language."
    case .neutral: return nil
    case .formal:  return "Keep a composed, professional tone."
    }
  }
}

// MARK: - Voice

struct CoachVoice: Codable, Equatable {
  var warmth: VoiceWarmth
  var brevity: VoiceBrevity
  var challenge: VoiceChallenge
  var formality: VoiceFormality
  /// Custom coach only: free-text the user appends to the persona. Empty
  /// elsewhere. Bounded in length by the editor.
  var note: String

  init(warmth: VoiceWarmth, brevity: VoiceBrevity,
       challenge: VoiceChallenge, formality: VoiceFormality, note: String = "") {
    self.warmth = warmth
    self.brevity = brevity
    self.challenge = challenge
    self.formality = formality
    self.note = note
  }

  /// Per-coach starting positions — the SAME dials, set differently, so each
  /// coach has a distinct out-of-box voice the user can then retune.
  static func defaults(for domain: CoachDomain) -> CoachVoice {
    switch domain {
    case .training:
      return .init(warmth: .balanced, brevity: .terse, challenge: .pushy, formality: .casual)
    case .food:
      return .init(warmth: .gentle, brevity: .balanced, challenge: .supportive, formality: .casual)
    case .accountability:
      return .init(warmth: .direct, brevity: .terse, challenge: .pushy, formality: .neutral)
    case .wholeLife:
      return .init(warmth: .gentle, brevity: .detailed, challenge: .balanced, formality: .neutral)
    case .custom:
      return .init(warmth: .balanced, brevity: .balanced, challenge: .balanced, formality: .neutral)
    }
  }

  /// One-line human summary of the current dials — the editor's live preview
  /// and a nice subtitle. e.g. "Direct · brief · pushy · casual".
  var summary: String {
    [warmth.label, brevity.label, challenge.label, formality.label]
      .map { $0.lowercased() }
      .joined(separator: " · ")
  }

  /// The instruction block injected between the coach's role intro and the
  /// shared discipline floor. Returns the dialed fragments as bullet lines
  /// plus any custom note. Never empty (brevity always contributes).
  func instructionBlock() -> String {
    var lines: [String] = []
    if let f = warmth.fragment { lines.append(f) }
    lines.append(brevity.fragment)
    if let f = challenge.fragment { lines.append(f) }
    if let f = formality.fragment { lines.append(f) }
    var block = "HOW TO SPEAK:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      block += "\n- The person specifically asked: \(trimmed)"
    }
    return block
  }
}

// MARK: - Store

/// Per-coach voice persistence, backed by SwiftData + CloudKit (record type
/// "CoachVoice", one row per coach keyed by coach key). The Core-side
/// `CoachVoiceMutator` speaks raw strings; this façade maps to/from the typed
/// dials. Falls back to the coach's `defaults` when the user never tuned it.
@MainActor
enum CoachVoiceStore {
  private static var mutator: CoachVoiceMutator { SeptenaServices.shared.coachVoiceMutator }

  static func load(_ domain: CoachDomain) -> CoachVoice {
    guard let e = mutator.voice(forCoachKey: domain.rawValue) else {
      return .defaults(for: domain)
    }
    let fallback = CoachVoice.defaults(for: domain)
    return CoachVoice(
      warmth: VoiceWarmth(rawValue: e.warmth) ?? fallback.warmth,
      brevity: VoiceBrevity(rawValue: e.brevity) ?? fallback.brevity,
      challenge: VoiceChallenge(rawValue: e.challenge) ?? fallback.challenge,
      formality: VoiceFormality(rawValue: e.formality) ?? fallback.formality,
      note: e.note
    )
  }

  static func save(_ voice: CoachVoice, for domain: CoachDomain) {
    mutator.save(coachKey: domain.rawValue,
                 warmth: voice.warmth.rawValue,
                 brevity: voice.brevity.rawValue,
                 challenge: voice.challenge.rawValue,
                 formality: voice.formality.rawValue,
                 note: voice.note)
  }

  static func reset(_ domain: CoachDomain) {
    mutator.delete(coachKey: domain.rawValue)
  }
}
