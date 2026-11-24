import Foundation
import SeptenaSharedCore

// The sync decisions of the shared core (`sync.rs`, ADR 0025, vectors
// `registry/conformance/sync-engine.json`), wrapped in plain Swift values.
// This file is the only one in TaskBackend/ that imports the core: its type
// names (`PushOutcome`, …) clash with the backend client's.

enum TaskSyncDecisions {

  /// What to do with one pulled page.
  enum PullStep: Equatable {
    /// Apply it; the pull is caught up.
    case apply
    /// Apply it and ask again from `nextCursor`.
    case applyAndContinue(nextCursor: Int)
    /// Wipe the local task data and pull from 0.
    case reset
    /// Stop: the server answered something the protocol forbids.
    case fail(String)
  }

  static func pullStep(cursor: Int, resetRequired: Bool, nextSince: Int, hasMore: Bool,
                       resetsSoFar: Int) -> PullStep {
    let decision = checkPullPage(
      cursor: Int64(cursor),
      page: PullPageHeader(resetRequired: resetRequired, nextSince: Int64(nextSince), hasMore: hasMore),
      resetsSoFar: UInt32(clamping: resetsSoFar))
    switch decision {
    case .apply: return .apply
    case .applyAndContinue(let next): return .applyAndContinue(nextCursor: Int(next))
    case .reset: return .reset
    case .fail(let reason): return .fail(reason)
    }
  }

  /// nil when a push response answers the sent ops one for one, in order;
  /// otherwise why it cannot be applied.
  static func pushResponseProblem(sentIDs: [String], resultIDs: [String]) -> String? {
    switch planPushResponse(sentIds: sentIDs, outcome: .response(resultIds: resultIDs)) {
    case .applyResults: return nil
    case .fail(let reason): return reason
    default: return "unexpected plan for a push response"
    }
  }
}
