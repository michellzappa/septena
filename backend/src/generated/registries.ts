// GENERATED FILE — DO NOT EDIT BY HAND.
// Source: registry/entities.json, registry/rules.json
// Regenerate: node scripts/gen-registries.mjs

export const ENTITY_PATTERNS = {
  id: "^[A-Za-z0-9._:-]{1,128}$",
  clientOpId: "^[A-Za-z0-9_-]{8,64}$",
  day: "^\\d{4}-\\d{2}-\\d{2}$",
  stamp: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}",
} as const;

export const ENTITY_LIMITS = {
  textMax: 2000,
  notesMax: 100000,
  attachmentPointerMax: 4000,
  stampMax: 40,
  maxAttachmentBytes: 26214400,
  maxUserAttachmentBytes: 2147483648,
  maxOpsPerPush: 500,
  maxPull: 1000,
  maxSubtasks: 500,
  maxArtifactRefs: 100,
  turnProviderMax: 32,
  turnQuestionMax: 10000,
  turnOptionMax: 500,
  turnMaxOptions: 20,
  turnChosenMax: 500,
  turnOtherTextMax: 10000,
  turnNoteMax: 100000,
} as const;

export const ENTITY_ENUMS = {
  taskStatus: ["open","done","cancelled"] as const,
  projectStatus: ["active","done","cancelled"] as const,
  taskKind: ["heading"] as const,
  recurrenceUnit: ["day","week","month","year"] as const,
  convoAssignee: ["me","local","claude"] as const,
  convoEndState: ["agent_done","human_done","agent_assisted_done","needs_verify","decomposed","reminder_set","promoted_to_today","wont_do","open"] as const,
  convoHandoffActionType: ["open_url","compose","call","none"] as const,
  convoTurnRole: ["user","provider"] as const,
  convoTurnStep: ["confirm","ground","scope","decide","work"] as const,
  telemetryLevel: ["none","minimal","balanced","full"] as const,
} as const;

export const DELETABLE_ENTITIES = ["task","area","project","attachment"] as const;

export const DOMAIN_RULES = {
  cueDecayDays: 7,
  fadeWindowDays: 14,
  fadeGraceDays: 1,
  fadeMinOpacity: 0.55,
  fadeSweepWeekday: 1,
  recentlyDeletedDays: 30,
  upcomingCalendarDays: 30,
  toastDurationSeconds: 7,
  agentRunBudget: 5,
  claimTtlDefaultSeconds: 1800,
  claimTtlMaxSeconds: 14400,
  tombstoneTtlDays: 90,
  clientOpTtlDays: 30,
  changeLogTtlDays: 365,
} as const;
