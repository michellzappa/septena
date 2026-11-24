import Foundation

// Typed HTTP 402 limit-body handling (docs/SYNC_SUBSCRIPTION_SPEC.md §6.3, §6.4).
//
// The backend enforces every plan limit from one table (`registry/plans.json`
// `limits`) and answers HTTP 402 with `{ error, limit, upsell, message }`:
//   - `error`: machine code (`device_not_syncing`, `live_sync_not_in_plan`,
//     `attachments_not_in_plan`, `attachment_quota`, …)
//   - `limit`: plan table key (`devices`, `liveSync`, `attachmentsGB`, …)
//   - `upsell`: moment id from `registry/plans.json` `upsells`, or null when
//     the app falls back quietly (live sync → poll)
//   - `message`: registry upsell copy, or null when `upsell` is null
//
// Pure Foundation + generated registry constants so `SeptenaCoreTests` can
// exercise every limit body and poll-policy decision without a host app.

/// Decoded HTTP 402 refusal body from the task backend.
struct BackendLimitError: Decodable, Equatable, Sendable {
  /// Known plan-limit refusal kinds (spec §6.3, §6.4).
  enum Kind: Equatable, Sendable {
    /// This device does not hold a sync slot (`limit: "devices"`, `upsell: "second_device"`),
    /// or `POST /v1/entitlement/device` hit the 24-hour move cooldown (finding 2).
    case deviceNotSyncing
    /// Live WebSocket nudge is not in the plan (`limit: "liveSync"`, `upsell: null`).
    /// The app falls back to polling `/v1/sync/pull` at most every 2 minutes.
    case liveSyncNotInPlan
    /// Free account does not sync attachment bytes (`limit: "attachmentsGB"`, `upsell: "file_elsewhere"`).
    case attachmentsNotInPlan
    /// Account exceeded its attachment storage quota (`limit: "attachmentsGB"`, `upsell: "file_elsewhere"`).
    case attachmentQuota
    /// Change history window edge (`limit: "changeLogDays"`, `upsell: "history_edge"`).
    case historyEdge
    /// Monthly agent run cap (`limit: "agentRunsPerMonth"`, `upsell: "agent_runs"`).
    case agentRuns
    /// Daily connector write cap (`limit: "connectorWritesPerDay"`, `upsell: "connector_cap"`).
    case connectorCap
    /// Creating a shared project requires Plus (`limit: "createShares"`, `upsell: "share_create"`).
    case shareCreate
    /// A future 402 code this build does not know by name yet.
    case other(String)
  }

  let error: String
  let limit: String?
  let upsell: String?
  let message: String?

  init(error: String, limit: String? = nil, upsell: String? = nil, message: String? = nil) {
    self.error = error
    self.limit = limit
    self.upsell = upsell
    self.message = message
  }

  /// Classified limit kind. Matches `error` first, then falls back to `limit`
  /// and `upsell` so minor server code additions (like a move-cooldown code
  /// carrying `limit: "devices"` / `upsell: "second_device"`) still route to
  /// the right handler.
  var kind: Kind {
    switch error {
    case "device_not_syncing", "device_move_limited", "device_move_cooldown":
      return .deviceNotSyncing
    case "live_sync_not_in_plan":
      return .liveSyncNotInPlan
    case "attachments_not_in_plan":
      return .attachmentsNotInPlan
    case "attachment_quota":
      return .attachmentQuota
    case "history_edge", "history_not_in_plan":
      return .historyEdge
    case "agent_runs", "agent_runs_exceeded", "agent_runs_limit":
      return .agentRuns
    case "connector_cap", "connector_writes_exceeded", "connector_writes_limit":
      return .connectorCap
    case "share_create", "shares_not_in_plan":
      return .shareCreate
    default:
      switch limit {
      case "devices": return .deviceNotSyncing
      case "liveSync": return .liveSyncNotInPlan
      case "attachmentsGB": return .attachmentsNotInPlan
      case "changeLogDays": return .historyEdge
      case "agentRunsPerMonth": return .agentRuns
      case "connectorWritesPerDay": return .connectorCap
      case "createShares": return .shareCreate
      default: break
      }
      switch upsell {
      case "second_device": return .deviceNotSyncing
      case "file_elsewhere": return .attachmentsNotInPlan
      case "history_edge": return .historyEdge
      case "agent_runs": return .agentRuns
      case "connector_cap": return .connectorCap
      case "share_create": return .shareCreate
      default: return .other(error)
      }
    }
  }

  /// True for either attachment upload 402 (`attachments_not_in_plan` or
  /// `attachment_quota`).
  var isAttachmentLimit: Bool {
    switch kind {
    case .attachmentsNotInPlan, .attachmentQuota: return true
    default: return false
    }
  }

  /// Canonical upsell moment id from `registry/plans.json` (`upsells`), or nil
  /// when the limit falls back quietly (live sync → poll).
  var resolvedUpsellID: String? {
    if let upsell, !upsell.isEmpty { return upsell }
    switch kind {
    case .deviceNotSyncing: return "second_device"
    case .liveSyncNotInPlan: return nil
    case .attachmentsNotInPlan, .attachmentQuota: return "file_elsewhere"
    case .historyEdge: return "history_edge"
    case .agentRuns: return "agent_runs"
    case .connectorCap: return "connector_cap"
    case .shareCreate: return "share_create"
    case .other: return nil
    }
  }

  /// Matching registry upsell note (`RegistryPlans.upsell(_:)`), if present.
  var upsellNote: RegistryPlanNote? {
    resolvedUpsellID.flatMap { RegistryPlans.upsell($0) }
  }

  /// Clean user-facing copy (never raw "The server answered 402 (...)").
  var userMessage: String {
    if let message, !message.isEmpty { return message }
    if let note = upsellNote { return "\(note.title). \(note.detail)" }
    return RegistryPlans.headline
  }

  /// Decodes any HTTP 402 response body. Never fails: malformed or empty 402
  /// bodies still decode to a typed `BackendLimitError` so an HTTP 402 never
  /// surfaces as a raw sync error.
  static func decode(from data: Data) -> BackendLimitError {
    if let decoded = try? JSONDecoder().decode(BackendLimitError.self, from: data),
       !decoded.error.isEmpty {
      return decoded
    }
    if let raw = try? JSONDecoder().decode(ErrorOnly.self, from: data),
       let code = raw.error, !code.isEmpty {
      return BackendLimitError(error: code)
    }
    return BackendLimitError(error: "plan_limit")
  }

  private struct ErrorOnly: Decodable {
    let error: String?
  }
}

/// Pure polling and live-socket policy for `TaskSyncEngine` (spec §6.3, §6.4
/// finding 8). Kept UI- and SwiftData-free so unit tests verify the exact
/// intervals and reconnect gating.
enum TaskSyncPollPolicy {
  /// Poll interval while live sync is unavailable (free plan poll-only mode,
  /// or socket down): at most 2 minutes while the app is in front (spec §6.4
  /// finding 8).
  static let pollWhileSocketDown: TimeInterval = 120
  /// Safety pull while the live WebSocket is up, for a nudge the socket dropped.
  static let pollWhileSocketUp: TimeInterval = 600
  /// Backoff cap after transient network/server errors.
  static let pollMax: TimeInterval = 900

  /// Whether the engine may open `/v1/sync/ws`. False when live sync was
  /// refused by the plan (`live_sync_not_in_plan`) or this device does not hold
  /// a sync slot (`device_not_syncing`).
  static func shouldConnectSocket(
    isRunning: Bool,
    appActive: Bool,
    signedIn: Bool,
    deviceNotSyncing: Bool,
    liveSyncBlocked: Bool
  ) -> Bool {
    isRunning && appActive && signedIn && !deviceNotSyncing && !liveSyncBlocked
  }

  /// Base pull interval before transient-error backoff.
  static func baseInterval(wsConnected: Bool, liveSyncBlocked: Bool) -> TimeInterval {
    (wsConnected && !liveSyncBlocked) ? pollWhileSocketUp : pollWhileSocketDown
  }

  /// Sleep duration for the next fallback poll tick.
  static func nextPollInterval(
    wsConnected: Bool,
    liveSyncBlocked: Bool,
    pollBackoff: TimeInterval
  ) -> TimeInterval {
    let base = baseInterval(wsConnected: wsConnected, liveSyncBlocked: liveSyncBlocked)
    return min(pollMax, max(base, pollBackoff))
  }
}
