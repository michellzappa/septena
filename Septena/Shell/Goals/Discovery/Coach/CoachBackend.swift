import Foundation
import FoundationModels

// The model abstraction — and the whole point of the design. The chat UI
// and CoachSession never know which model answers. Today that's Apple's
// on-device Foundation Models; when a stronger model arrives (Private
// Cloud Compute / Claude), it's a NEW conformance + one line in the
// factory. Nothing above this file changes.
//
// Two forward seams baked in now so the upgrade stays additive:
//   • returns a structured `CoachReply` (text today; citations/actions later)
//   • carries a `CoachScope` (which sections it may read) — enforced today by
//     a pre-filtered snapshot, later at the tool boundary.

@MainActor
protocol CoachBackend {
  /// One conversational turn. Implementations are stateful — they retain
  /// prior turns so the conversation has memory for its lifetime.
  func reply(to userText: String) async throws -> CoachReply
}

/// Today's backend: Apple Foundation Models, fully on-device. Holds ONE
/// `LanguageModelSession` for the whole conversation (the session retains
/// its transcript across `respond` calls), and seeds the persona + facts
/// on the first turn only — matching the bare-init pattern already proven
/// in VirtuePromptService / PurposePromptService.
@MainActor
final class FoundationModelsBackend: CoachBackend {
  private let session = LanguageModelSession()
  private let instructions: String
  private let scope: CoachScope     // unused on-device (snapshot is pre-filtered); the tool-backend hook
  private var primed = false

  init(instructions: String, scope: CoachScope) {
    self.instructions = instructions
    self.scope = scope
    session.prewarm()
  }

  func reply(to userText: String) async throws -> CoachReply {
    let prompt: String
    if primed {
      prompt = userText
    } else {
      // Fold the persona + computed facts into the first turn. The
      // session carries them forward for every later turn.
      prompt = instructions + "\n\nThe person opens with:\n" + userText
      primed = true
    }
    let text = try await session.respond(to: prompt).content
    return CoachReply(text: text)
  }
}

/// Fallback when no model is available (Simulator, ineligible device,
/// Apple Intelligence off). The experience degrades to "here are your
/// numbers" rather than breaking.
@MainActor
final class EchoBackend: CoachBackend {
  func reply(to userText: String) async throws -> CoachReply {
    CoachReply(text: "On-device AI isn't available here yet, so I can't chat — but your recent numbers are summarized above. Turn on Apple Intelligence in Settings to enable the coach.")
  }
}

@MainActor
enum CoachBackendFactory {
  /// Pick the best backend currently available. The commented branch is
  /// the post–iOS 27 / Private Cloud Compute drop-in: add the conformance,
  /// uncomment, ship.
  static func make(instructions: String, scope: CoachScope) -> CoachBackend {
    // if PrivateCloudComputeBackend.isAvailable {
    //   return PrivateCloudComputeBackend(instructions: instructions, scope: scope)
    // }
    if OnDeviceAI.isAvailable {
      return FoundationModelsBackend(instructions: instructions, scope: scope)
    }
    return EchoBackend()
  }
}
