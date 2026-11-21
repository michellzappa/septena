// GENERATED FILE — DO NOT EDIT BY HAND.
// Source: registry/entities.json, registry/rules.json
// Regenerate: node scripts/gen-registries.mjs

import Foundation

/// Wire schema size and count limits shared with the backend (`registry/entities.json`).
enum RegistryEntityLimits {
  static let textMax: Int = 2000
  static let notesMax: Int = 100000
  static let attachmentPointerMax: Int = 4000
  static let stampMax: Int = 40
  static let maxAttachmentBytes: Int64 = 26214400
  static let maxUserAttachmentBytes: Int64 = 2147483648
  static let maxOpsPerPush: Int = 500
  static let maxPull: Int = 1000
  static let maxSubtasks: Int = 500
  static let maxArtifactRefs: Int = 100
  static let turnProviderMax: Int = 32
  static let turnQuestionMax: Int = 10000
  static let turnOptionMax: Int = 500
  static let turnMaxOptions: Int = 20
  static let turnChosenMax: Int = 500
  static let turnOtherTextMax: Int = 10000
  static let turnNoteMax: Int = 100000
}

/// Wire schema regex strings shared with the backend (`registry/entities.json`).
enum RegistryEntityPatterns {
  static let id = "^[A-Za-z0-9._:-]{1,128}$"
  static let clientOpId = "^[A-Za-z0-9_-]{8,64}$"
  static let day = "^\\d{4}-\\d{2}-\\d{2}$"
  static let stamp = "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}"
}

/// Canonical enum wire strings shared with the backend (`registry/entities.json`).
enum RegistryEntityEnums {
  static let taskStatus: [String] = ["open", "done", "cancelled"]
  static let projectStatus: [String] = ["active", "done", "cancelled"]
  static let taskKind: [String] = ["heading"]
  static let recurrenceUnit: [String] = ["day", "week", "month", "year"]
  static let convoAssignee: [String] = ["me", "local", "claude"]
  static let convoEndState: [String] = ["agent_done", "human_done", "agent_assisted_done", "needs_verify", "decomposed", "reminder_set", "promoted_to_today", "wont_do", "open"]
  static let convoHandoffActionType: [String] = ["open_url", "compose", "call", "none"]
  static let convoTurnRole: [String] = ["user", "provider"]
  static let convoTurnStep: [String] = ["confirm", "ground", "scope", "decide", "work"]
  static let telemetryLevel: [String] = ["none", "minimal", "balanced", "full"]
  static let entityNames: [String] = ["task", "area", "project", "attachment", "convo", "setting"]
  static let deletableEntities: [String] = ["task", "area", "project", "attachment"]
}

/// Domain thresholds and retention constants shared across platforms (`registry/rules.json`).
enum RegistryRules {
  static let cueDecayDays: Int = 7
  static let fadeWindowDays: Int = 14
  static let fadeGraceDays: Int = 1
  static let fadeMinOpacity: Double = 0.55
  static let fadeSweepWeekday: Int = 1
  static let recentlyDeletedDays: Int = 30
  static let upcomingCalendarDays: Int = 30
  static let toastDurationSeconds: Int = 7
  static let agentRunBudget: Int = 5
  static let claimTtlDefaultSeconds: Int = 1800
  static let claimTtlMaxSeconds: Int = 14400
  static let tombstoneTtlDays: Int = 90
  static let clientOpTtlDays: Int = 30
  static let changeLogTtlDays: Int = 365
}
