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
