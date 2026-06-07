import Foundation
import FoundationModels

// The model abstraction — the chat UI and CoachSession never know which
// model answers. Today: Apple on-device Foundation Models, streaming. When
// a reasoning model arrives (Private Cloud Compute / Claude), it's a NEW
// conformance + one line in the factory. Forward seams kept: a `CoachScope`
// (which sections it may read; enforced today by a pre-filtered snapshot,
// later at the tool boundary) and structured extras (follow-ups, goal).

@MainActor
protocol CoachBackend {
  /// Stream one turn as cumulative text snapshots (each yield is the full
  /// reply-so-far). Stateful: retains prior turns for the conversation.
  func stream(_ userText: String) -> AsyncThrowingStream<String, Error>

  /// Short follow-up questions the person might tap next. `[]` if unsupported.
  func suggestFollowUps() async -> [String]

  /// Summarize the conversation into one adoptable goal sentence, or nil.
  func proposeGoal() async -> String?
}

@Generable
private struct FollowUpsOut: Codable { let questions: [String] }

@Generable
private struct GoalOut: Codable { let goal: String }

/// Today's backend: Apple Foundation Models, fully on-device. Holds ONE
/// `LanguageModelSession` for the conversation (it retains its transcript
/// across calls) and seeds persona + facts on the first turn only.
@MainActor
final class FoundationModelsBackend: CoachBackend {
  private let session = LanguageModelSession()
  private let instructions: String
  private let scope: CoachScope     // unused on-device (snapshot pre-filtered); the tool-backend hook
  private var primed = false

  // Last exchange, kept for follow-up generation off a throwaway session.
  private var lastUser = ""
  private var lastAnswer = ""

  init(instructions: String, scope: CoachScope) {
    self.instructions = instructions
    self.scope = scope
    session.prewarm()
  }

  func stream(_ userText: String) -> AsyncThrowingStream<String, Error> {
    let prompt: String
    if primed {
      prompt = userText
    } else {
      prompt = instructions + "\n\nThe person opens with:\n" + userText
      primed = true
    }
    lastUser = userText

    return AsyncThrowingStream { continuation in
      let task = Task { @MainActor in
        do {
          var latest = ""
          for try await partial in session.streamResponse(to: prompt) {
            latest = partial.content
            continuation.yield(partial.content)
          }
          self.lastAnswer = latest
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func suggestFollowUps() async -> [String] {
    guard !lastAnswer.isEmpty else { return [] }
    // Throwaway session so the meta-question never pollutes the transcript.
    let helper = LanguageModelSession()
    let prompt = """
      Given this coaching exchange, suggest 3 very short follow-up questions \
      the person might tap next. First person, each under 6 words, no numbering.

      Them: \(lastUser)
      Coach: \(lastAnswer)
      """
    let out = try? await helper.respond(to: prompt, generating: FollowUpsOut.self)
    return Array((out?.content.questions ?? []).prefix(3))
  }

  func proposeGoal() async -> String? {
    let prompt = """
      Summarize our conversation into ONE specific, adoptable goal the person \
      could commit to. Imperative, concrete, under 12 words. Just the goal text.
      """
    let out = try? await session.respond(to: prompt, generating: GoalOut.self)
    let text = out?.content.goal.trimmingCharacters(in: .whitespacesAndNewlines)
    return (text?.isEmpty == false) ? text : nil
  }
}

/// Fallback when no model is available (Simulator, ineligible device,
/// Apple Intelligence off). Degrades to "here are your numbers".
@MainActor
final class EchoBackend: CoachBackend {
  func stream(_ userText: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield("On-device AI isn't available here yet, so I can't chat — but your recent numbers are summarized above. Turn on Apple Intelligence in Settings to enable the coach.")
      continuation.finish()
    }
  }
  func suggestFollowUps() async -> [String] { [] }
  func proposeGoal() async -> String? { nil }
}

@MainActor
enum CoachBackendFactory {
  /// Pick the best backend available. The commented branch is the post–iOS 27
  /// Private Cloud Compute drop-in: add the conformance, uncomment, ship.
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
