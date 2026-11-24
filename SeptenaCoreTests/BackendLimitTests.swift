import Foundation
import Testing

/// Verifies typed HTTP 402 `{ error, limit, upsell, message }` decoding,
/// classification, upsell resolution, and poll-only fallback policy for
/// issue #264 (`docs/SYNC_SUBSCRIPTION_SPEC.md` §6.3, §6.4 findings 5 & 8).
@Suite struct BackendLimitTests {

  @Test func decodesDeviceNotSyncing402() {
    let json = """
      {
        "error": "device_not_syncing",
        "limit": "devices",
        "upsell": "second_device",
        "message": "This device is not syncing. A free account syncs one device."
      }
      """
    let decoded = BackendLimitError.decode(from: Data(json.utf8))
    #expect(decoded.error == "device_not_syncing")
    #expect(decoded.limit == "devices")
    #expect(decoded.upsell == "second_device")
    #expect(decoded.kind == .deviceNotSyncing)
    #expect(decoded.isAttachmentLimit == false)
    #expect(decoded.resolvedUpsellID == "second_device")
    #expect(decoded.upsellNote?.id == "second_device")
    #expect(decoded.userMessage == "This device is not syncing. A free account syncs one device.")
  }

  @Test func decodesLiveSyncNotInPlan402WithNullUpsellAndMessage() {
    let json = """
      {
        "error": "live_sync_not_in_plan",
        "limit": "liveSync",
        "upsell": null,
        "message": null
      }
      """
    let decoded = BackendLimitError.decode(from: Data(json.utf8))
    #expect(decoded.error == "live_sync_not_in_plan")
    #expect(decoded.limit == "liveSync")
    #expect(decoded.upsell == nil)
    #expect(decoded.message == nil)
    #expect(decoded.kind == .liveSyncNotInPlan)
    #expect(decoded.resolvedUpsellID == nil)
    #expect(decoded.upsellNote == nil)
    #expect(!decoded.userMessage.isEmpty)
  }

  @Test func decodesAttachmentLimits402() {
    let freeJSON = """
      {
        "error": "attachments_not_in_plan",
        "limit": "attachmentsGB",
        "upsell": "file_elsewhere",
        "message": "This file is on another device. Plus syncs files and images to all your devices."
      }
      """
    let freeLimit = BackendLimitError.decode(from: Data(freeJSON.utf8))
    #expect(freeLimit.kind == .attachmentsNotInPlan)
    #expect(freeLimit.isAttachmentLimit == true)
    #expect(freeLimit.resolvedUpsellID == "file_elsewhere")
    #expect(freeLimit.upsellNote?.id == "file_elsewhere")

    let quotaJSON = """
      {
        "error": "attachment_quota",
        "limit": "attachmentsGB",
        "upsell": "file_elsewhere",
        "message": "Attachment storage limit reached."
      }
      """
    let quotaLimit = BackendLimitError.decode(from: Data(quotaJSON.utf8))
    #expect(quotaLimit.kind == .attachmentQuota)
    #expect(quotaLimit.isAttachmentLimit == true)
    #expect(quotaLimit.resolvedUpsellID == "file_elsewhere")
    #expect(quotaLimit.userMessage == "Attachment storage limit reached.")
  }

  @Test func decodesAllOtherSpec63LimitCodes() {
    let cases: [(String, String, String, BackendLimitError.Kind)] = [
      ("history_edge", "changeLogDays", "history_edge", .historyEdge),
      ("agent_runs", "agentRunsPerMonth", "agent_runs", .agentRuns),
      ("connector_cap", "connectorWritesPerDay", "connector_cap", .connectorCap),
      ("share_create", "createShares", "share_create", .shareCreate),
    ]
    for (error, limit, upsell, expected) in cases {
      let json = """
        {"error":"\(error)","limit":"\(limit)","upsell":"\(upsell)","message":null}
        """
      let decoded = BackendLimitError.decode(from: Data(json.utf8))
      #expect(decoded.kind == expected)
      #expect(decoded.resolvedUpsellID == upsell)
      #expect(decoded.upsellNote?.id == upsell)
      #expect(!decoded.userMessage.contains("402"))
    }
  }

  @Test func classifiesFutureErrorCodesByLimitOrUpsellAndHandlesMalformedBodies() {
    // Future 24h device-move cooldown code (spec §6.4 finding 2) with unknown error string.
    let cooldownJSON = """
      {"error":"slot_move_cooldown","limit":"devices","upsell":"second_device","message":"You can move sync once a day."}
      """
    let cooldown = BackendLimitError.decode(from: Data(cooldownJSON.utf8))
    #expect(cooldown.kind == .deviceNotSyncing)
    #expect(cooldown.resolvedUpsellID == "second_device")
    #expect(cooldown.userMessage == "You can move sync once a day.")

    // Completely unknown future limit code still decodes without failing or showing raw 402.
    let unknownJSON = """
      {"error":"future_cap","limit":"futureLimit","upsell":null,"message":null}
      """
    let unknown = BackendLimitError.decode(from: Data(unknownJSON.utf8))
    #expect(unknown.kind == .other("future_cap"))
    #expect(!unknown.userMessage.contains("402"))

    // Empty / non-JSON 402 body degrades cleanly.
    let empty = BackendLimitError.decode(from: Data())
    #expect(empty.error == "plan_limit")
    #expect(empty.kind == .other("plan_limit"))
    #expect(!empty.userMessage.contains("402"))
  }

  @Test func liveSyncBlockedDisablesSocketAndPollsAtMostEvery2Minutes() {
    #expect(TaskSyncPollPolicy.pollWhileSocketDown <= 120)

    // Free account with liveSync blocked: never opens the WebSocket.
    #expect(TaskSyncPollPolicy.shouldConnectSocket(
      isRunning: true, appActive: true, signedIn: true,
      deviceNotSyncing: false, liveSyncBlocked: true
    ) == false)

    // Non-syncing second device: never opens the WebSocket.
    #expect(TaskSyncPollPolicy.shouldConnectSocket(
      isRunning: true, appActive: true, signedIn: true,
      deviceNotSyncing: true, liveSyncBlocked: false
    ) == false)

    // Active Plus device in foreground: opens WebSocket.
    #expect(TaskSyncPollPolicy.shouldConnectSocket(
      isRunning: true, appActive: true, signedIn: true,
      deviceNotSyncing: false, liveSyncBlocked: false
    ) == true)

    // Poll interval in poll-only mode is 120s (at most 2 minutes).
    #expect(TaskSyncPollPolicy.nextPollInterval(
      wsConnected: false, liveSyncBlocked: true, pollBackoff: 0
    ) == 120)

    // Even if wsConnected were stale, liveSyncBlocked keeps base at 120s.
    #expect(TaskSyncPollPolicy.nextPollInterval(
      wsConnected: true, liveSyncBlocked: true, pollBackoff: 0
    ) == 120)

    // With live socket connected on Plus, safety poll is 600s.
    #expect(TaskSyncPollPolicy.nextPollInterval(
      wsConnected: true, liveSyncBlocked: false, pollBackoff: 0
    ) == 600)
  }
}
