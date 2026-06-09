import Foundation

// In-app reasoning orchestration — the provider seam the AI dial (AIPolicy) drives.
//
// Engine-independent and availability-gated by design:
//   • on-device (Foundation Models) and the user's Claude (async, over MCP) both
//     work on the 26.0 floor.
//   • Apple Private Cloud Compute slots in on iOS 27 via the SAME protocol WITHOUT
//     blocking 26: PCC's symbols don't exist in the 26 SDK, so the PCC provider is
//     added behind `#available` once Xcode 27 lands (see `ProviderAvailability` +
//     the commented branch in `ConversationEngine.syncProviders`). Nothing here
//     references an iOS-27 symbol, so it compiles on 26.

/// One reasoning step the engine wants resolved.
struct ReasoningRequest {
  let taskID: String
  let title: String
  let step: ConvoTurn.Step
  let confirmedIntent: String?
  let context: [String]        // grounded facts (deterministic `compute`)
  let priorTurns: [ConvoTurn]
}

/// What a provider produced — a proposed provider turn to append.
struct ReasoningResult {
  var turn: ConvoTurn
  var confidence: Double?
}

/// Sync providers resolve inline; asyncPull (the user's Claude over MCP) is
/// drained from the `pending_reasoning` queue, not called here.
enum ProviderDelivery { case sync, asyncPull }

@MainActor
protocol ReasoningProvider {
  var kind: AIProviderKind { get }
  var delivery: ProviderDelivery { get }
  var isAvailable: Bool { get }
  func canHandle(_ request: ReasoningRequest) -> Bool
  func resolve(_ request: ReasoningRequest) async throws -> ReasoningResult
}

enum ReasoningRoute: Equatable {
  case useSync(AIProviderKind)   // resolve inline with this provider
  case parkForAsync              // only the user's Claude is admissible → queue it
  case noProvider                // nothing admissible/capable → back to the human
}

/// PCC-readiness seam. Returns false on the 26 SDK and references NO iOS-27
/// symbols, so it compiles today. On Xcode 27: inside the `#available` branch,
/// return real `PrivateCloudComputeLanguageModel` availability + the entitlement
/// check. Until then `auto` simply never offers PCC — on-device + Claude still work.
@MainActor
enum ProviderAvailability {
  static var pccAvailable: Bool {
    if #available(iOS 27, macOS 27, *) {
      return false   // TODO(Xcode 27): real PCC availability + entitlement
    }
    return false
  }
}

@MainActor
enum ReasoningRouter {
  /// Walk the admissible list (most-private-first per `AIPolicy`); return the
  /// first available, capable SYNC provider; else park for the async Claude if
  /// admissible; else nothing.
  static func route(_ request: ReasoningRequest,
                    providers: [AIProviderKind: any ReasoningProvider],
                    claudeConnected: Bool) -> ReasoningRoute {
    let admissible = AIPolicy.admissibleProviders(claudeConnected: claudeConnected,
                                                  pccAvailable: ProviderAvailability.pccAvailable)
    for kind in admissible where kind != .claude {
      if let p = providers[kind], p.isAvailable, p.delivery == .sync, p.canHandle(request) {
        return .useSync(kind)
      }
    }
    return admissible.contains(.claude) ? .parkForAsync : .noProvider
  }
}
