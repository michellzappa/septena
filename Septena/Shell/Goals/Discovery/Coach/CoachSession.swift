import SwiftData
import SwiftUI

// Conversation state for one coach. The visible transcript is PERSISTED per
// coach (SwiftData + CloudKit via CoachMessageMutator), so it survives closing
// the chat, relaunching, and reaches other devices. Built each time the chat
// opens (and on window change): rehydrates the stored transcript, rebuilds the
// facts snapshot, and hands persona + facts to a model-agnostic backend.
//
// Caveat: the on-device model's OWN memory is not restored — a fresh backend
// is created each time, so the coach "reads" the history the user sees but
// doesn't internally remember prior turns across launches/window changes.

@MainActor
@Observable
final class CoachSession {
  struct Message: Identifiable {
    enum Role { case coach, user }
    let id = UUID()
    let role: Role
    var text: String
    // Tappable follow-up questions offered after a coach reply.
    var followUps: [String] = []
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
  /// The full persona + data context seeded into the model on the first
  /// turn. Exposed so it can be inspected / copied for testing elsewhere.
  let systemPrompt: String
  var isThinking = false

  private let backend: CoachBackend

  init(domain: CoachDomain, window: CoachWindow, context: ModelContext, excluding: Set<String> = []) {
    self.domain = domain
    self.window = window
    // Pills enumerate the WHOLE preset (so muted sections still show, ready
    // to re-enable); the snapshot excludes the muted ones from the model.
    self.pills = CoachContextBuilder.availability(for: domain, window: window, context: context)
    let facts = CoachContextBuilder.snapshot(for: domain, window: window, context: context, excluding: excluding)
    // The user's per-coach voice (tone dials + custom note) is dialed into the
    // persona; the shared discipline floor is unaffected.
    let voice = CoachVoiceStore.load(domain)
    let instructions = domain.persona(voice: voice) + "\n\n" + facts
    self.systemPrompt = instructions
    // Pills = permission: the coach may only read the preset's sections that
    // aren't muted. Enforced today by the pre-filtered snapshot above.
    let allKeys = Set(domain.sectionKeys ?? CoachContextBuilder.supportedKeys)
    let scope = CoachScope(permitted: allKeys.subtracting(excluding))
    self.backend = CoachBackendFactory.make(instructions: instructions, scope: scope)

    // Rehydrate the persisted transcript. First-ever open seeds + persists the
    // deterministic opener so the stored history reads naturally from line one.
    let store = SeptenaServices.shared.coachMessageMutator
    let stored = store.messages(forCoachKey: domain.rawValue)
    if stored.isEmpty {
      self.messages = [Message(role: .coach, text: domain.opener)]
      store.append(coachKey: domain.rawValue, role: "coach", text: domain.opener)
    } else {
      self.messages = stored.map {
        Message(role: $0.role == "user" ? .user : .coach, text: $0.text)
      }
    }
  }

  /// Whether the coach can actually converse (vs. the echo fallback).
  var isLive: Bool { OnDeviceAI.isAvailable }

  /// True while a reply is streaming but no text has arrived yet — drives
  /// the "Thinking…" row, which gives way to the bubble once tokens flow.
  var awaitingFirstToken: Bool {
    guard isThinking, let last = messages.last else { return false }
    return last.role == .coach && last.text.isEmpty
  }

  func send(_ text: String) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isThinking else { return }

    messages.append(Message(role: .user, text: trimmed))
    store.append(coachKey: domain.rawValue, role: "user", text: trimmed)
    isThinking = true
    defer { isThinking = false }

    let coachIndex = messages.count
    messages.append(Message(role: .coach, text: ""))   // placeholder, fills as it streams

    do {
      for try await partial in backend.stream(trimmed) {
        messages[coachIndex].text = partial
      }
      if messages[coachIndex].text.isEmpty {
        messages[coachIndex].text = "…"
      }
      Haptics.success()
      let followUps = await backend.suggestFollowUps()
      messages[coachIndex].followUps = followUps
    } catch {
      messages[coachIndex].text = messages[coachIndex].text.isEmpty
        ? "Sorry — I lost my train of thought. Try that again?"
        : messages[coachIndex].text
    }
    // Persist the final coach reply (one row, not per-token) so the stored
    // transcript matches what the user saw.
    store.append(coachKey: domain.rawValue, role: "coach", text: messages[coachIndex].text)
  }

  /// The persisted-transcript store for this coach.
  private var store: CoachMessageMutator { SeptenaServices.shared.coachMessageMutator }

  /// Wipe this coach's saved conversation and start over from the opener.
  func clearTranscript() {
    store.clear(coachKey: domain.rawValue)
    messages = [Message(role: .coach, text: domain.opener)]
    store.append(coachKey: domain.rawValue, role: "coach", text: domain.opener)
  }

  /// Ask the model to distill the conversation into one adoptable goal.
  func proposeGoal() async -> String? {
    await backend.proposeGoal()
  }

  /// Ask the model for a structured commitment, validate its metric against
  /// the catalog (never trust a hallucinated key), and append it as a
  /// confirm-gated card. Returns the action, or nil if nothing usable came
  /// back. The model proposes; the UI's Confirm is what writes.
  @discardableResult
  func proposeCommitment() async -> CoachProposedAction? {
    let scopeKeys = Set(domain.sectionKeys ?? [])
    let metrics = GoalMetricCatalog.metrics(for: scopeKeys)
    guard let out = await backend.proposeCommitment(metricKeys: metrics.map(\.key)) else { return nil }
    let text = out.goal.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    var action = CoachProposedAction(section: domain.sectionKeys?.first ?? "goals",
                                     title: text, goalText: text)

    // Trust a metric only if it's a real catalog key, the comparator is known,
    // and a range carries a sane upper. Otherwise it's a plain-text commitment.
    let validComparators: Set<String> = ["gte", "lte", "eq", "range"]
    if out.measurable,
       let metric = GoalMetricCatalog.metric(for: out.metricKey),
       validComparators.contains(out.comparator),
       (out.comparator != "range" || out.upper > out.lower) {
      action.metricKey = metric.key
      action.metricWindow = metric.window
      action.metricComparator = out.comparator
      action.metricTarget = out.lower
      action.metricUpper = out.comparator == "range" ? out.upper : nil
      action.sections = [metric.sectionKey]
      action.section = metric.sectionKey
    } else {
      action.sections = domain.sectionKeys?.first.map { [$0] } ?? []
    }

    // Display-only (not persisted) — an ephemeral affordance; once accepted it
    // becomes a real, persisted goal.
    messages.append(Message(role: .coach,
                            text: "Here's a commitment from our chat — add it?",
                            actions: [action]))
    return action
  }
}
