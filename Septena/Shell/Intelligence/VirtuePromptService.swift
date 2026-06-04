import Foundation
import FoundationModels

// On-device interpreter for the Examined Week mini app. Same engine as
// PurposePromptService — Apple's Foundation Models, fully local. The
// summarizer does all the counting; this service only turns the routed
// evidence into language. Strict contract: mirror, don't judge; cite the
// numbers it's given; never invent data.

@Generable
struct VirtueReadingOut: Codable {
  let virtue: String   // temperance | wisdom | courage | justice
  let status: String   // steady | mixed | strained | unknown
  let read: String
  let tension: String
}

@Generable
struct VirtueReadingsResponse: Codable {
  let readings: [VirtueReadingOut]
}

/// A virtue's reflection as the UI renders it — the model's prose mapped
/// back onto the strongly-typed `Virtue` / `VirtueStatus`.
struct VirtueReading: Identifiable {
  let virtue: Virtue
  let status: VirtueStatus
  let read: String
  let tension: String

  var id: String { virtue.rawValue }
}

final class VirtuePromptService {
  /// Ask the on-device model for one reading per virtue. Throws if the
  /// model is unavailable or generation fails — callers fall back to
  /// `fallbackReadings`.
  func generateReadings(summary: VirtueWeekSummary) async throws -> [VirtueReading] {
    let session = LanguageModelSession()
    let result = try await session.respond(to: buildPrompt(summary: summary),
                                            generating: VirtueReadingsResponse.self)
    return merged(result.content.readings, summary: summary)
  }

  /// Deterministic, model-free reading built straight from the routed
  /// evidence. Used when the on-device model is unavailable or errors —
  /// the experience still works, just without the prose polish.
  func fallbackReadings(summary: VirtueWeekSummary) -> [VirtueReading] {
    Virtue.allCases.map { fallback(for: $0, summary: summary) }
  }

  // MARK: - Mapping

  /// Map the model's loosely-typed output back onto the four virtues,
  /// preserving canonical order and backfilling anything the model
  /// dropped or returned malformed.
  private func merged(_ outputs: [VirtueReadingOut], summary: VirtueWeekSummary) -> [VirtueReading] {
    Virtue.allCases.map { virtue in
      guard let out = outputs.first(where: { $0.virtue.lowercased().contains(virtue.rawValue) }) else {
        return fallback(for: virtue, summary: summary)
      }
      let read = out.read.trimmingCharacters(in: .whitespacesAndNewlines)
      let tension = out.tension.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !read.isEmpty else { return fallback(for: virtue, summary: summary) }
      let status = VirtueStatus(rawValue: out.status.lowercased()) ?? summary.bundle(for: virtue).status
      return VirtueReading(virtue: virtue,
                           status: status,
                           read: read,
                           tension: tension.isEmpty ? "—" : tension)
    }
  }

  private func fallback(for virtue: Virtue, summary: VirtueWeekSummary) -> VirtueReading {
    let ev = summary.bundle(for: virtue)
    guard ev.hasData else {
      return VirtueReading(virtue: virtue, status: .unknown,
                           read: "No logged signal this week.",
                           tension: "Nothing tracked here yet.")
    }
    let highlights = ev.signals.filter { $0.valence != .neutral }.prefix(2).map(\.text)
    let read = highlights.isEmpty
      ? ev.signals.prefix(2).map(\.text).joined(separator: ". ")
      : highlights.joined(separator: ". ")
    let tension = ev.signals.first { $0.valence == .strain }?.text
      ?? ev.signals.first { $0.valence == .neutral }?.text
      ?? "—"
    return VirtueReading(virtue: virtue, status: ev.status, read: read, tension: tension)
  }

  // MARK: - Prompt

  private func buildPrompt(summary: VirtueWeekSummary) -> String {
    """
    You are a reflective mirror, not a judge or a coach. Below is a reader's
    summary of someone's last 7 days of self-tracked life, already distilled
    into evidence for four cardinal virtues. Every fact is computed and true —
    do not invent, add, or recompute any numbers.

    For EACH virtue (temperance, wisdom, courage, justice) return:
    - virtue: the lowercase name
    - status: one of steady | mixed | strained | unknown. Trust the [hint]
      unless the evidence clearly contradicts it. Use "unknown" only when there
      is no logged signal.
    - read: ONE plain sentence describing what the week shows for this virtue.
      Cite at least one concrete number from the evidence. Descriptive.
    - tension: ONE plain sentence naming the single most honest friction or
      gap. If there genuinely is none, say so briefly.

    Rules:
    - Mirror, don't scold. No advice, no "you should", no pep talk.
    - No scores, no grades, no emoji.
    - Never mention data that isn't in the evidence below.
    - Keep each field under ~30 words.
    - Avoid the words: nuanced, holistic, journey, synergy, leverage.

    EVIDENCE:
    \(summary.promptText)
    """
  }
}
