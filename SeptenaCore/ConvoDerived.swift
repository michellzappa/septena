import Foundation

// Derived view-state for a task's conversation — COMPUTED, never stored. The
// stored facts live in `TaskConvo`; this is a pure projection the UI badge and
// the reasoning queue read. Phase 1: docs/TASK_CONVERSATIONS_PHASE1.md.

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
  /// Most recent provider turn, if any.
  var lastProviderTurn: ConvoTurn? { thread.last { $0.role == .provider } }

  /// True when the last turn is a provider turn still awaiting the human's tap
  /// (it offered options and no user turn followed). The 🟡 state.
  var hasOpenProviderQuestion: Bool {
    guard let last = thread.last else { return false }
    return last.role == .provider && (last.options?.isEmpty == false)
  }

  /// There's a conversation worth surfacing at all.
  var hasStarted: Bool { !thread.isEmpty || confirmedIntent != nil }

  /// SINGLE source of truth for the reasoning queue, shared by the in-app
  /// backend filter and the badge (the gateway mirrors this rule in TS): marked
  /// for Claude, OR last provider turn low-confidence — and not terminal.
  func isPendingReasoning() -> Bool {
    guard !isTerminal else { return false }
    if assignee == .claude { return true }
    if let c = lastProviderTurn?.confidence, c < 0.5 { return true }
    return false
  }
}

/// Pure projection of a conversation into UI/queue state.
func deriveConvo(_ convo: TaskConvo) -> ConvoDerived {
  let pending = convo.isPendingReasoning()

  if convo.isTerminal {
    let badge: ConvoBadge = (convo.endState == .wontDo) ? .wontDo : .done
    return ConvoDerived(stage: .terminal, badge: badge,
                        nextAction: convo.endStateNote ?? "Resolved",
                        pendingReasoning: false)
  }

  guard convo.hasStarted else {
    return ConvoDerived(stage: .open, badge: nil,
                        nextAction: "No conversation yet", pendingReasoning: pending)
  }

  if convo.hasOpenProviderQuestion {
    return ConvoDerived(stage: .awaitingHuman, badge: .needsYou,
                        nextAction: "Tap to answer", pendingReasoning: pending)
  }

  // Agent owes the next move (just confirmed, or the user just chose).
  let stage: ConvoStage = (convo.confirmedIntent == nil) ? .clarifying : .inProgress
  return ConvoDerived(stage: stage, badge: .working,
                      nextAction: "Claude's move", pendingReasoning: pending)
}
