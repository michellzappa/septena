import Foundation
import SeptenaSharedCore

// Derived view-state for a task's conversation — COMPUTED, never stored. The
// stored facts live in `TaskConvo`; this is a pure projection the UI badge and
// the reasoning queue read. Phase 1: docs/TASK_CONVERSATIONS_PHASE1.md.
// The projection (stage, badge, next action, pending reasoning) runs in the
// shared Rust core (ADR 0025), the same one the other clients use.

/// Where the conversation sits in its lifecycle.
enum ConvoStage { case open, clarifying, inProgress, awaitingHuman, terminal }

/// Ball-in-whose-court — the daily-driver signal on a task row. (`youOnly` for
/// the `human_only` disposition arrives with that breadth phase; Phase 1 is
/// `agent_doable`, so needsYou / working / done / wontDo.)
enum ConvoBadge { case needsYou, working, done, wontDo }

struct ConvoDerived {
  var stage: ConvoStage
  var badge: ConvoBadge?        // nil = no conversation worth surfacing
  var nextAction: String
  var pendingReasoning: Bool
}

extension TaskConvo {
  /// The core's conversation facts (`conversation_state`, ADR 0025). The
  /// predicates below read it, so every client shares one rule. A claim lease
  /// is wall-clock time on the backend, so this reads the real clock.
  func coreState(at now: Date = Date()) -> ConversationState? {
    try? conversationState(conversation: coreConversation, now: SharedCoreValues.instant(now))
  }

  /// True when the last turn is a provider turn still awaiting the human's tap
  /// (it offered options and no user turn followed). The 🟡 state.
  var hasOpenProviderQuestion: Bool { coreState()?.hasOpenProviderQuestion ?? false }

  /// True when an agent finished work and handed the task back for the human
  /// to verify and accept or send back (`#87`). Single source of truth for the
  /// Review smart list and badge. A single-field read: it stays in Swift.
  var needsHumanReview: Bool { endState == .needsVerify }

  /// True when the conversation is waiting on a human action — either verifying
  /// finished agent work (`needs_verify`) or answering an open choice card.
  var awaitsHuman: Bool { coreState()?.awaitsHuman ?? needsHumanReview }

  /// There's a conversation worth surfacing at all.
  var hasStarted: Bool { coreState()?.hasStarted ?? false }

  /// SINGLE source of truth for the reasoning queue, shared by the in-app
  /// backend filter and the badge: marked for Claude, OR last provider turn
  /// low-confidence — and not terminal or stopped. Computed by the shared core.
  func isPendingReasoning() -> Bool {
    coreProjection(at: Date())?.pendingReasoning ?? false
  }

  /// This conversation in the shared core's shape. A claim counts only with a
  /// claimant, as in `isClaimed(at:)`.
  var coreConversation: TaskConversation {
    TaskConversation(
      confirmedIntent: confirmedIntent,
      thread: coreTurns.map {
        ConversationTurn(sequence: Int64($0.seq), role: $0.role.rawValue, options: $0.options, confidence: $0.confidence)
      },
      artifactExists: artifact != nil,
      handoffExists: handoff != nil,
      endState: endState?.rawValue,
      endStateNote: endStateNote,
      assignee: assignee?.rawValue,
      stoppedAt: stoppedAt.map(SharedCoreValues.instant),
      claimUntil: claimedBy == nil ? nil : claimUntil.map(SharedCoreValues.instant)
    )
  }

  /// The turns the core reads: the last turn and the last provider turn.
  /// Sending only these keeps a core call the same cost for any thread
  /// length; the core's answers depend on nothing else in the thread.
  private var coreTurns: [ConvoTurn] {
    guard let last = thread.max(by: { $0.seq < $1.seq }) else { return [] }
    guard last.role != .provider,
          let provider = thread.filter({ $0.role == .provider }).max(by: { $0.seq < $1.seq }) else { return [last] }
    return [provider, last]
  }

  /// The core's projection; nil only if the core rejects the input.
  func coreProjection(at now: Date) -> ConversationProjection? {
    try? deriveConversation(conversation: coreConversation, now: SharedCoreValues.instant(now))
  }
}

/// The stages of agent work in progress (docs/TASK_FACTORY_SPEC.md §3).
/// Derived, never stored. Raw values are the core's stage ids; `working`,
/// `queued` and `stopped` are also group ids of the `review` destination in
/// `registry/destinations.json`. The core's `yourTurn` and `review` stages
/// wait on the user: they are the Questions and Finished work groups.
enum AgentStage: String, CaseIterable, Sendable {
  case working, queued, stopped, done

  /// The Review group that shows this stage, or nil for `done` (the Logbook
  /// holds finished agent work).
  var reviewGroup: ReviewGroup? {
    switch self {
    case .working: return .working
    case .queued: return .queued
    case .stopped: return .stopped
    case .done: return nil
    }
  }
}

extension TaskConvo {
  /// The agent stage of this conversation, or nil when the task is not
  /// agent work in progress: nobody works on it, or it waits on the user.
  func agentStage(at now: Date) -> AgentStage? {
    coreState(at: now)?.agentStage.flatMap(AgentStage.init(rawValue:))
  }

}

/// The groups of the Review list (docs/REVIEW_SPEC.md §1), in order. Raw
/// values are the group ids of the `review` destination in
/// `registry/destinations.json`, which owns titles and icons. Review holds
/// everything about your agent and what waits on you (ADR 0046).
enum ReviewGroup: String, CaseIterable, Sendable {
  /// `waiting`: the open task waits on a person (`waitingOn`, docs/REVIEW_SPEC.md §6).
  case questions, finished, waiting, working, queued, stopped, faded

  /// Device-local: whether the Faded group is open. It starts closed.
  static let fadedExpandedKey = "septena.tasks.reviewFadedExpanded"

  /// Registry title + symbol for this group's section header.
  var group: RegistryDestinationGroup? {
    RegistryDestinations.groups[.review]?.first { $0.id == rawValue }
  }

  /// True for the groups that wait on the user. Only they count in the
  /// Review badge; Waiting, agent work in progress and Faded do not.
  var countsInBadge: Bool { self == .questions || self == .finished }
}

extension TaskConvo {
  /// The Review group this conversation puts an open task in: a question or
  /// finished work waits on the user, then a task that waits on a person
  /// (`waiting`, docs/REVIEW_SPEC.md §6), and agent work in progress shows by
  /// its stage. A claim lease is backend wall-clock time, so this reads the
  /// real clock (as `deriveConvo` does).
  func reviewGroup(at now: Date = Date(), waiting: Bool = false) -> ReviewGroup? {
    guard let state = coreState(at: now) else { return waiting ? .waiting : nil }
    if let id = state.reviewGroup, let group = ReviewGroup(rawValue: id) { return group }
    if waiting { return .waiting }
    return state.agentStage.flatMap(AgentStage.init(rawValue:))?.reviewGroup
  }
}

extension TaskConvo {
  /// The agent's move, or an agent holds the task now: such a task never fades.
  func isAgentTurn(at now: Date) -> Bool {
    isClaimed(at: now) || deriveConvo(self).badge == .working
  }
}

/// Pure projection of a conversation into UI/queue state, computed by the
/// shared core. A claim lease is wall-clock time on the backend, not the
/// app's day, and this projection is nonisolated, so it reads the real clock.
func deriveConvo(_ convo: TaskConvo) -> ConvoDerived {
  guard let p = convo.coreProjection(at: Date()) else {
    return ConvoDerived(stage: .open, badge: nil, nextAction: "No conversation yet", pendingReasoning: false)
  }
  return ConvoDerived(stage: ConvoStage(core: p.stage), badge: p.badge.flatMap(ConvoBadge.init(core:)),
                      nextAction: p.nextAction, pendingReasoning: p.pendingReasoning)
}

extension ConvoStage {
  /// The core's stage names: open, clarifying, inProgress, awaitingHuman, terminal.
  init(core: String) {
    switch core {
    case "clarifying": self = .clarifying
    case "inProgress": self = .inProgress
    case "awaitingHuman": self = .awaitingHuman
    case "terminal": self = .terminal
    default: self = .open
    }
  }
}

extension ConvoBadge {
  /// The core's badge names: needsYou, working, done, wontDo.
  init?(core: String) {
    switch core {
    case "needsYou": self = .needsYou
    case "working": self = .working
    case "done": self = .done
    case "wontDo": self = .wontDo
    default: return nil
    }
  }
}
