import SwiftData
import SwiftUI

// Ephemeral conversation state for one coach. Created when the chat opens,
// dropped when it closes — nothing persisted (v1). Builds the facts
// snapshot once at init, hands persona + facts to a model-agnostic
// backend, and tracks the visible transcript.

@MainActor
@Observable
final class CoachSession {
  struct Message: Identifiable {
    enum Role { case coach, user }
    let id = UUID()
    let role: Role
    var text: String
    // Populated only by reasoning backends; dormant on-device today.
    var citations: [CoachCitation] = []
    var actions: [CoachProposedAction] = []
  }

  let domain: CoachDomain
  let window: CoachWindow
  private(set) var messages: [Message]
  /// The sections (with entry counts) feeding this conversation — rendered
  /// as pills so the user can "see" what the coach is talking to.
  let pills: [CoachDataPill]
  var isThinking = false

  private let backend: CoachBackend

  init(domain: CoachDomain, window: CoachWindow, context: ModelContext, excluding: Set<String> = []) {
    self.domain = domain
    self.window = window
    // Pills enumerate the WHOLE preset (so muted sections still show, ready
    // to re-enable); the snapshot excludes the muted ones from the model.
    self.pills = CoachContextBuilder.availability(for: domain, window: window, context: context)
    let facts = CoachContextBuilder.snapshot(for: domain, window: window, context: context, excluding: excluding)
    let instructions = domain.persona + "\n\n" + facts
    // Pills = permission: the coach may only read the preset's sections that
    // aren't muted. Enforced today by the pre-filtered snapshot above.
    let allKeys = Set(domain.sectionKeys ?? CoachContextBuilder.supportedKeys)
    let scope = CoachScope(permitted: allKeys.subtracting(excluding))
    self.backend = CoachBackendFactory.make(instructions: instructions, scope: scope)
    self.messages = [Message(role: .coach, text: domain.opener)]
  }

  /// Whether the coach can actually converse (vs. the echo fallback).
  var isLive: Bool { OnDeviceAI.isAvailable }

  func send(_ text: String) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isThinking else { return }

    messages.append(Message(role: .user, text: trimmed))
    isThinking = true
    defer { isThinking = false }

    do {
      let reply = try await backend.reply(to: trimmed)
      messages.append(Message(role: .coach, text: reply.text,
                              citations: reply.citations, actions: reply.actions))
      Haptics.success()
    } catch {
      messages.append(Message(role: .coach,
                              text: "Sorry — I lost my train of thought. Try that again?"))
    }
  }
}
