import Foundation

// The in-app orchestrator: grounds a task, routes per the AI dial (AIPolicy),
// and either resolves the step inline (on-device) or parks it for the async
// provider (the user's Claude). One entry point — `advance(task:)`. Press-to-
// advance: a UI affordance calls this; nothing auto-runs.
//
// PCC (iOS 27, Xcode 27 builds only): `PCCReasoningProvider` registers below —
// the router already prefers it over Claude when `AIPolicy` admits it. On the
// 26 toolchain the guarded line vanishes and nothing else changes.

@MainActor
enum ConversationEngine {
  private static var syncProviders: [AIProviderKind: any ReasoningProvider] {
    // Foundation Models (and so the on-device provider) is macOS/iOS 26+.
    // Below that floor the dictionary is simply empty for `.onDevice` and the
    // router falls through to the async provider, exactly as it does when the
    // model is present but unavailable.
    var p: [AIProviderKind: any ReasoningProvider] = [:]
    if #available(macOS 26.0, iOS 26.0, *) { p[.onDevice] = OnDeviceReasoningProvider() }
    #if compiler(>=6.4)
    if #available(iOS 27.0, macOS 27.0, *) { p[.applePCC] = PCCReasoningProvider() }
    #endif
    return p
  }

  /// Advance one step. Acts only when it's the agent's move (no open question,
  /// not terminal). Returns the route taken (for UI feedback).
  @discardableResult
  static func advance(task: SeptenaTask, claudeConnected: Bool = false) async -> ReasoningRoute {
    let convo = task.conversation
    guard !convo.isTerminal, !convo.hasOpenProviderQuestion else { return .noProvider }

    let step: ConvoTurn.Step = convo.confirmedIntent == nil ? .confirm : .decide
    let request = ReasoningRequest(
      taskID: task.id, title: task.title, step: step,
      confirmedIntent: convo.confirmedIntent, context: ground(task), priorTurns: convo.thread
    )
    let route = ReasoningRouter.route(request, providers: syncProviders, claudeConnected: claudeConnected)
    let m = SeptenaServices.shared.taskMutator
    switch route {
    case .useSync(let kind):
      if let p = syncProviders[kind], let result = try? await p.resolve(request) {
        m.appendConvoTurn(id: task.id, result.turn)
      }
    case .parkForAsync:
      m.setConvoAssignee(id: task.id, .claude)   // → pending_reasoning; the user's Claude drains it
    case .noProvider:
      break
    }
    return route
  }

  /// Deterministic grounding (`compute`) — the facts a provider reasons over.
  /// Minimal for now (notes + placement); expand per step/disposition.
  private static func ground(_ task: SeptenaTask) -> [String] {
    var facts: [String] = []
    if let n = task.notes, !n.isEmpty { facts.append("notes: \(n)") }
    if let a = task.area { facts.append("area: \(a)") }
    if let p = task.project { facts.append("project: \(p)") }
    return facts
  }
}
