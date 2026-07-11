import Foundation
import FoundationModels

// On-device reasoning provider for Task Conversations — Apple Foundation Models,
// available on the 26.0 floor (no iOS 27 needed). Handles the cheap clarify step
// (confirm); steps that need the web / deep reasoning escalate (router falls
// through to the user's Claude, or — on iOS 27 — Private Cloud Compute).

@Generable
private struct ConfirmReadings: Codable {
  let readings: [String]
}

@MainActor
struct OnDeviceReasoningProvider: ReasoningProvider {
  var kind: AIProviderKind { .onDevice }
  var delivery: ProviderDelivery { .sync }
  var isAvailable: Bool { OnDeviceAI.isAvailable }

  func canHandle(_ request: ReasoningRequest) -> Bool {
    // On-device does the clarify step well. `decide`/`work` may need the web or
    // stronger reasoning, so they fall through to the next admissible provider.
    request.step == .confirm
  }

  func resolve(_ request: ReasoningRequest) async throws -> ReasoningResult {
    let session = LanguageModelSession()
    let ctx = request.context.isEmpty ? "" : "\nContext: \(request.context.joined(separator: "; "))."
    let prompt = """
    A user wrote this to-do: "\(request.title)".\(ctx)
    It may be ambiguous. Offer 2–3 short, distinct readings of what they most likely \
    mean — each a tappable option, max ~6 words. Don't pick one; surface the plausible few.
    """
    let out = try await session.respond(to: prompt, generating: ConfirmReadings.self).content
    let options = Array(out.readings.prefix(3)).filter { !$0.isEmpty }
    let turn = ConvoTurn(
      seq: 0, role: .provider, step: .confirm, provider: .onDevice,
      confidence: 0.6,
      question: "“\(request.title)” — what did you mean?",
      options: options.isEmpty ? nil : options,
      ts: Date()
    )
    return ReasoningResult(turn: turn, confidence: 0.6)
  }
}

#if compiler(>=6.4)

/// Maps the user's one reasoning knob (`PCCConfig.reasoning`) to the SDK level.
/// The single source of truth for every PCC call (Coach + task conversations)
/// so there's no per-site drift. iOS-27-gated because `ContextOptions` symbols
/// don't exist on the 26 SDK.
@available(iOS 27.0, macOS 27.0, *)
enum PCCReasoning {
  static var contextOptions: ContextOptions {
    let level: ContextOptions.ReasoningLevel
    switch PCCConfig.reasoning {
    case .light:    level = .light
    case .balanced: level = .moderate
    case .thorough: level = .deep
    }
    return ContextOptions(reasoningLevel: level)
  }
}

// Private Cloud Compute provider (iOS 27+) — the escalation rung between
// on-device and the user's async Claude. Same request/turn contract; a
// reasoning-capable model with a 32K window, still inside Apple's privacy
// boundary (prompts not stored), still zero inference cost to Septena.
// Dormant until built with Xcode 27 AND the PCC entitlement is granted
// (`ProviderAvailability.pccAvailable` stays false without it).

@available(iOS 27.0, macOS 27.0, *)
@Generable
private struct DecideProposal: Codable {
  let recommendation: String   // one sentence: the proposed next move
  let options: [String]        // 2–3 short tappable choices, recommended first
}

@available(iOS 27.0, macOS 27.0, *)
@MainActor
struct PCCReasoningProvider: ReasoningProvider {
  var kind: AIProviderKind { .applePCC }
  var delivery: ProviderDelivery { .sync }
  var isAvailable: Bool { ProviderAvailability.pccAvailable }

  func canHandle(_ request: ReasoningRequest) -> Bool {
    // `decide` is the step on-device declines (needs real reasoning); PCC also
    // covers `confirm` for when the on-device model is absent (router walks
    // most-private-first, so on-device still wins confirm when it can). `work`
    // may need the web — it still parks for the user's Claude.
    request.step == .confirm || request.step == .decide
  }

  func resolve(_ request: ReasoningRequest) async throws -> ReasoningResult {
    let session = LanguageModelSession(model: PCCModel.shared)
    let ctx = request.context.isEmpty ? "" : "\nContext: \(request.context.joined(separator: "; "))."

    switch request.step {
    case .decide:
      let intent = request.confirmedIntent.map { "\nConfirmed intent: \($0)." } ?? ""
      let history = request.priorTurns.suffix(6).compactMap { turn -> String? in
        let text = turn.chosen ?? turn.otherText ?? turn.question ?? turn.note
        guard let text, !text.isEmpty else { return nil }
        return "\(turn.role == .user ? "them" : "assistant"): \(text)"
      }.joined(separator: "\n")
      let prompt = """
      A user's to-do: "\(request.title)".\(intent)\(ctx)
      \(history.isEmpty ? "" : "Conversation so far:\n\(history)\n")
      Propose how to proceed. Give ONE one-sentence recommendation and 2–3 short \
      tappable options (max ~6 words each), the recommended move first. The user \
      decides — never assume the action is taken.
      """
      // Reasoning level is the user's one PCC knob (default balanced/.moderate).
      let out = try await session.respond(
        to: prompt, generating: DecideProposal.self,
        contextOptions: PCCReasoning.contextOptions
      ).content
      let options = Array(out.options.prefix(3)).filter { !$0.isEmpty }
      let turn = ConvoTurn(
        seq: 0, role: .provider, step: .decide, provider: .applePCC,
        confidence: 0.75,
        question: out.recommendation,
        options: options.isEmpty ? nil : options,
        ts: Date()
      )
      return ReasoningResult(turn: turn, confidence: 0.75)

    default:
      // confirm — same contract as the on-device provider.
      let prompt = """
      A user wrote this to-do: "\(request.title)".\(ctx)
      It may be ambiguous. Offer 2–3 short, distinct readings of what they most likely \
      mean — each a tappable option, max ~6 words. Don't pick one; surface the plausible few.
      """
      let out = try await session.respond(to: prompt, generating: ConfirmReadings.self).content
      let options = Array(out.readings.prefix(3)).filter { !$0.isEmpty }
      let turn = ConvoTurn(
        seq: 0, role: .provider, step: .confirm, provider: .applePCC,
        confidence: 0.7,
        question: "“\(request.title)” — what did you mean?",
        options: options.isEmpty ? nil : options,
        ts: Date()
      )
      return ReasoningResult(turn: turn, confidence: 0.7)
    }
  }
}
#endif
