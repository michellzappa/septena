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
  /// Which model backs this coach — surfaced to the user as a small caption
  /// (`AIModelTagBadge`) so it's visible whether a reply came from on-device
  /// or Private Cloud Compute.
  var modelTag: AIModelTag { get }

  /// Stream one turn as cumulative text snapshots (each yield is the full
  /// reply-so-far). Stateful: retains prior turns for the conversation.
  func stream(_ userText: String) -> AsyncThrowingStream<String, Error>

  /// Short follow-up questions the person might tap next. `[]` if unsupported.
  func suggestFollowUps() async -> [String]

  /// Summarize the conversation into one adoptable goal sentence, or nil.
  func proposeGoal() async -> String?

  /// Propose ONE structured commitment from the conversation. `metricKeys`
  /// are the measurement keys the coach may attach (from the goal catalog,
  /// scoped to this coach's sections). Returns nil if nothing fits. The
  /// proposal is NEVER executed by the model — the UI confirm-gates it.
  func proposeCommitment(metricKeys: [String]) async -> CoachCommitmentOut?
}

@Generable
private struct FollowUpsOut: Codable { let questions: [String] }

@Generable
private struct GoalOut: Codable { let goal: String }

/// Structured commitment the model proposes. Flat, non-optional fields with
/// sentinels (empty string / 0) so guided generation always fills them; the
/// session validates `metricKey` against the catalog before trusting it.
@Generable
struct CoachCommitmentOut: Codable {
  let goal: String         // imperative, concrete, under 12 words
  let measurable: Bool     // true if one of the provided metric keys fits
  let metricKey: String    // EXACT key from the provided list, or ""
  let comparator: String   // "gte" | "lte" | "eq" | "range", or ""
  let lower: Double        // primary/lower target
  let upper: Double        // upper bound (range only; else 0)
}

/// Today's backend: Apple Foundation Models, fully on-device. Holds ONE
/// `LanguageModelSession` for the conversation (it retains its transcript
/// across calls) and seeds persona + facts on the first turn only.
@MainActor
final class FoundationModelsBackend: CoachBackend {
  let modelTag: AIModelTag = .onDevice
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

  func proposeCommitment(metricKeys: [String]) async -> CoachCommitmentOut? {
    let keyList = metricKeys.isEmpty
      ? "(none available — keep it a plain text commitment, measurable=false)"
      : metricKeys.joined(separator: ", ")
    let prompt = """
      Turn our conversation into ONE specific commitment the person could adopt. \
      Imperative, concrete, under 12 words.

      If it can be measured by one of these metric keys, set measurable=true, \
      metricKey to the EXACT key, comparator to one of gte/lte/eq/range, lower to \
      the target number (and upper as well when comparator is range, e.g. a \
      "between X and Y" band). Otherwise set measurable=false, metricKey="", \
      comparator="", lower=0, upper=0.

      Available metric keys: \(keyList)
      """
    return try? await session.respond(to: prompt, generating: CoachCommitmentOut.self).content
  }
}

/// Fallback when no model is available (Simulator, ineligible device,
/// Apple Intelligence off). Degrades to "here are your numbers".
@MainActor
final class EchoBackend: CoachBackend {
  let modelTag: AIModelTag = .none
  func stream(_ userText: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield("On-device AI isn't available here yet, so I can't chat — but your recent numbers are summarized above. Turn on Apple Intelligence in Settings to enable the coach.")
      continuation.finish()
    }
  }
  func suggestFollowUps() async -> [String] { [] }
  func proposeGoal() async -> String? { nil }
  func proposeCommitment(metricKeys: [String]) async -> CoachCommitmentOut? { nil }
}

#if compiler(>=6.4)
/// iOS 27+: the same coach on Apple's Private Cloud Compute model — a 32K
/// window (the seeded facts block regularly crowds the on-device 8K one) and
/// real reasoning, with the same privacy story (prompts aren't stored; still
/// zero inference cost to Septena). Reasoning depth is the user's one PCC knob
/// (`PCCConfig.reasoning`, default balanced), applied to every call so quality/
/// latency/quota stays a single choice. Follow-up chips stay on-device — a
/// throwaway meta-question shouldn't spend PCC quota.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class PrivateCloudComputeBackend: CoachBackend {
  let modelTag: AIModelTag = .privateCloudCompute
  private let session: LanguageModelSession
  private let instructions: String
  private let scope: CoachScope     // same forward seam as the on-device backend
  private var primed = false

  private var lastUser = ""
  private var lastAnswer = ""

  init(instructions: String, scope: CoachScope) {
    self.instructions = instructions
    self.scope = scope
    self.session = LanguageModelSession(model: PCCModel.shared)
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
          for try await partial in self.session.streamResponse(
            to: prompt, contextOptions: PCCReasoning.contextOptions
          ) {
            latest = partial.content
            continuation.yield(partial.content)
          }
          self.lastAnswer = latest
          continuation.finish()
        } catch let error as PrivateCloudComputeLanguageModel.Error {
          // Predictable PCC states degrade to a spoken line, not a failure.
          switch error {
          case .quotaLimitReached:
            continuation.yield("You've used today's Private Cloud Compute allowance, so I can't reach the bigger model right now — it resets daily. Reopen the coach to continue on-device.")
          case .networkFailure:
            continuation.yield("Private Cloud Compute needs a network connection and I can't reach it right now. Reopen the coach to continue on-device.")
          default:
            continuation.yield("Private Cloud Compute is unavailable right now. Reopen the coach to continue on-device.")
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func suggestFollowUps() async -> [String] {
    guard !lastAnswer.isEmpty, OnDeviceAI.isAvailable else { return [] }
    // On-device throwaway session — never pollutes the PCC transcript or quota.
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
    let out = try? await session.respond(
      to: prompt, generating: GoalOut.self,
      contextOptions: PCCReasoning.contextOptions
    )
    let text = out?.content.goal.trimmingCharacters(in: .whitespacesAndNewlines)
    return (text?.isEmpty == false) ? text : nil
  }

  func proposeCommitment(metricKeys: [String]) async -> CoachCommitmentOut? {
    let keyList = metricKeys.isEmpty
      ? "(none available — keep it a plain text commitment, measurable=false)"
      : metricKeys.joined(separator: ", ")
    let prompt = """
      Turn our conversation into ONE specific commitment the person could adopt. \
      Imperative, concrete, under 12 words.

      If it can be measured by one of these metric keys, set measurable=true, \
      metricKey to the EXACT key, comparator to one of gte/lte/eq/range, lower to \
      the target number (and upper as well when comparator is range, e.g. a \
      "between X and Y" band). Otherwise set measurable=false, metricKey="", \
      comparator="", lower=0, upper=0.

      Available metric keys: \(keyList)
      """
    return try? await session.respond(
      to: prompt, generating: CoachCommitmentOut.self,
      contextOptions: PCCReasoning.contextOptions
    ).content
  }
}
#endif

@MainActor
enum CoachBackendFactory {
  /// Pick the best backend available. PCC outranks on-device for the coach —
  /// its facts block wants the bigger window and proposals want reasoning —
  /// but ONLY when the AI dial admits it: `AIPolicy.admissibleProviders` is
  /// the single authority, so `onDeviceOnly` and `useMyClaude` never reach
  /// PCC, and the dev force-provider override works here too.
  static func make(instructions: String, scope: CoachScope) -> CoachBackend {
    #if compiler(>=6.4)
    if #available(iOS 27.0, macOS 27.0, *),
       AIPolicy.admissibleProviders(claudeConnected: false,
                                    pccAvailable: ProviderAvailability.pccAvailable)
         .contains(.applePCC) {
      return PrivateCloudComputeBackend(instructions: instructions, scope: scope)
    }
    #endif
    if OnDeviceAI.isAvailable {
      return FoundationModelsBackend(instructions: instructions, scope: scope)
    }
    return EchoBackend()
  }
}
