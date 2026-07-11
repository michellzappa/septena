import Foundation
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif

// In-app reasoning orchestration — the provider seam the AI dial (AIPolicy) drives.
//
// Engine-independent and availability-gated by design:
//   • on-device (Foundation Models) and the user's Claude (async, over MCP) both
//     work on the 26.0 floor.
//   • Apple Private Cloud Compute slots in on iOS 27 via the SAME protocol WITHOUT
//     blocking 26: PCC's symbols don't exist in the 26 SDK, so everything PCC here
//     sits behind `#if compiler(>=6.4)` (the Swift bundled with Xcode 27) + runtime
//     `#available`. Built with the 26 toolchain this file is unchanged.

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

#if compiler(>=6.4) && canImport(FoundationModels)
/// Process-wide Private Cloud Compute model handle (iOS 27+). ONE instance so
/// every consumer (coach backend, reasoning provider, settings status board)
/// observes the same availability and quota state.
@available(iOS 27.0, macOS 27.0, watchOS 27.0, *)
enum PCCModel {
  static let shared = PrivateCloudComputeLanguageModel()
}
#endif

/// Whether the app may actually ROUTE work to Private Cloud Compute — a
/// SEPARATE, stricter switch than `PrivateCloudComputeLanguageModel.availability`.
///
/// The trap this guards against: on a device with Apple Intelligence, PCC's
/// `availability` reports `.available` even when the app lacks the
/// `com.apple.developer.private-cloud-compute` entitlement — but *constructing
/// or using* a PCC session without that entitlement TRAPS (an uncatchable
/// crash, not a thrown error). So availability alone must never select the PCC
/// backend. Routing stays OFF until the entitlement is granted, added to the
/// hand-maintained `*.entitlements`, and this flag is flipped on (Settings ▸
/// Claude & AI). Default false = safe: on-device is used and nothing ever
/// touches a PCC symbol at runtime.
enum PCCConfig {
  static let routingEnabledKey = "septena.ai.pccRoutingEnabled"
  static var routingEnabled: Bool {
    UserDefaults.standard.bool(forKey: routingEnabledKey)   // default false
  }

  /// How hard PCC thinks before answering — one knob for every PCC call, so
  /// the user owns the quality/latency/quota tradeoff (a deeper level answers
  /// better but is slower and spends the daily allowance faster). Stored as a
  /// plain string here (SeptenaCore compiles on the 26 floor); the PCC code
  /// maps it to `ContextOptions.ReasoningLevel` behind `#available`.
  static let reasoningKey = "septena.ai.pccReasoning"
  enum Reasoning: String, CaseIterable, Sendable {
    case light, balanced, thorough   // → .light / .moderate / .deep
    var title: String {
      switch self {
      case .light:    return "Light"
      case .balanced: return "Balanced"
      case .thorough: return "Thorough"
      }
    }
  }
  /// Default `.balanced` (maps to `.moderate`) — the sensible middle.
  static var reasoning: Reasoning {
    Reasoning(rawValue: UserDefaults.standard.string(forKey: reasoningKey) ?? "") ?? .balanced
  }
}

/// PCC-readiness seam. Real on the 27 SDK; false on the 26 toolchain (the
/// guarded block is skipped entirely, so this file still compiles on 26).
/// The `routingEnabled` check is FIRST so `&&` short-circuits before any PCC
/// symbol is touched — until the user opts in, `PCCModel.shared` is never even
/// constructed, so an un-entitled binary can't trap here.
@MainActor
enum ProviderAvailability {
  static var pccAvailable: Bool {
    #if compiler(>=6.4) && canImport(FoundationModels)
    if #available(iOS 27.0, macOS 27.0, watchOS 27.0, *) {
      return PCCConfig.routingEnabled && PCCModel.shared.isAvailable
    }
    #endif
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
