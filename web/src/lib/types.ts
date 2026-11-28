import { z } from "zod";
import type { ENTITY_ENUMS } from "./generated/registries.ts";

// Boundary schemas and types for the Septena web client (WEB_CLIENT_SPEC.md).

export const zDeviceStartResponse = z.object({
  code: z.string(),
  pollSecret: z.string(),
  expiresIn: z.number(),
  interval: z.number(),
  qr: z.object({
    size: z.number().int().positive(),
    modules: z.string(),
  }),
});
export type DeviceStartResponse = z.infer<typeof zDeviceStartResponse>;

export const zSessionResponse = z.object({
  accessToken: z.string(),
  expiresIn: z.number(),
  userId: z.string(),
});
export type SessionResponse = z.infer<typeof zSessionResponse>;

// Sign-in methods this server has turned on (GET /v1/auth/methods, ADR 0047).
export const zAuthMethodEntry = z.object({
  id: z.string(),
  web: z.boolean().optional(),
  native: z.boolean().optional(),
});
export type AuthMethodEntry = z.infer<typeof zAuthMethodEntry>;

export const zAuthMethodsResponse = z.object({
  methods: z.array(zAuthMethodEntry),
});
export type AuthMethodsResponse = z.infer<typeof zAuthMethodsResponse>;

// Linked sign-in methods on the signed-in account (GET /v1/auth/identities, #643).
export const zLinkedIdentity = z.object({
  id: z.string(),
  provider: z.string(),
  label: z.string(),
  createdAt: z.number(),
});
export type LinkedIdentity = z.infer<typeof zLinkedIdentity>;

export const zLinkedIdentitiesResponse = z.object({
  identities: z.array(zLinkedIdentity),
  canRemove: z.boolean(),
});
export type LinkedIdentitiesResponse = z.infer<typeof zLinkedIdentitiesResponse>;

export type OidcRedeemSignInResult =
  | { status: "signed_in"; session: SessionResponse }
  | { status: "account_exists"; email: string; provider: string; linkToken?: string; codeSent?: boolean };

// POST /v1/auth/email/start (202).
export const zEmailStartResponse = z.object({
  status: z.literal("sent"),
  expiresInSeconds: z.number(),
  codeLength: z.number().int().min(4).max(10).optional(),
});
export type EmailStartResponse = z.infer<typeof zEmailStartResponse>;

export const zWsTicketResponse = z.object({
  ticket: z.string(),
  expiresIn: z.number(),
});
export type WsTicketResponse = z.infer<typeof zWsTicketResponse>;

export const zPullResponse = z.object({
  resetRequired: z.literal(true).optional(),
  changes: z.array(
    z.object({
      entity: z.string(),
      row: z.record(z.string(), z.unknown()),
    }),
  ),
  nextSince: z.number().int().min(0),
  hasMore: z.boolean(),
});
export type PullResponse = z.infer<typeof zPullResponse>;

export const zOpResult = z.discriminatedUnion("status", [
  z.object({ clientOpId: z.string(), status: z.literal("applied"), rev: z.number(), seq: z.number().optional() }),
  z.object({ clientOpId: z.string(), status: z.literal("noop") }),
  z.object({ clientOpId: z.string(), status: z.literal("dropped"), rev: z.number(), reason: z.literal("deleted") }),
  z.object({
    clientOpId: z.string(),
    status: z.literal("rejected"),
    reason: z.string(),
    rule: z.string().optional(),
  }),
]);
export type OpResult = z.infer<typeof zOpResult>;

export const zPushResponse = z.object({
  appliedThrough: z.number(),
  results: z.array(zOpResult),
});
export type PushResponse = z.infer<typeof zPushResponse>;

export const zAccessSummary = z.object({
  devices: z.array(
    z.object({
      sid: z.string(),
      client: z.string().nullable().optional(),
      firstSeen: z.number().optional(),
      lastSeen: z.number().optional(),
      createdAt: z.number().optional(),
      lastUsedAt: z.number().optional(),
      current: z.boolean().optional(),
      syncing: z.boolean().optional(),
    }),
  ),
  connections: z.array(
    z.object({
      id: z.string(),
      clientId: z.string().optional(),
      name: z.string().nullable().optional(),
      clientName: z.string().optional(),
      scope: z.string().optional(),
      createdAt: z.number().optional(),
      lastUsed: z.number().nullable().optional(),
      lastUsedAt: z.number().nullable().optional(),
      active: z.boolean().optional(),
    }),
  ),
  // The agent count and the plan's agent slots (null = no limit).
  agents: z.object({ count: z.number(), limit: z.number().nullable().optional() }).optional(),
});
export type AccessSummary = z.infer<typeof zAccessSummary>;

// GET /v1/entitlement: the account's plan as the server enforces it
// (docs/SYNC_SUBSCRIPTION_SPEC.md §6). The app reads it; it never decides.
export const zEntitlement = z.object({
  active: z.boolean(),
  plan: z.enum(["free", "plus", "pro"]).nullable().optional(),
  trialEndsAt: z.number().nullable().optional(),
  entitlements: z.array(
    z.object({
      source: z.string(),
      plan: z.string().nullable().optional(),
      expiresAt: z.number().nullable().optional(),
      active: z.boolean().optional(),
    }),
  ),
});
export type Entitlement = z.infer<typeof zEntitlement>;

// POST /v1/access/keys (#86): the key appears in this reply only.
export const zCreatedAgentKey = z.object({
  id: z.string(),
  key: z.string().startsWith("sk1."),
  name: z.string(),
  scope: z.string(),
});

export const zChangeEntry = z.object({
  rev: z.number(),
  entity: z.string(),
  id: z.string(),
  op: z.string().optional(),
  actor: z.string(),
  at: z.string(),
  before: z.record(z.string(), z.unknown()).nullable().optional(),
  after: z.record(z.string(), z.unknown()).nullable().optional(),
});
export type ChangeEntry = z.infer<typeof zChangeEntry>;

export const zChangesResponse = z.object({
  changes: z.array(zChangeEntry),
});

export const zIcalFeedSettings = z.object({
  enabled: z.boolean(),
  scope: z.enum(["all", "timed"]),
  url: z.string().nullable(),
  webcalUrl: z.string().nullable(),
  createdAt: z.string().nullable(),
});
export type IcalFeedSettings = z.infer<typeof zIcalFeedSettings>;

export interface OrdinalWeekday {
  ordinal: number;
  weekday: number;
}

export interface TaskRow {
  id: string;
  title: string;
  status: "open" | "done" | "cancelled" | string;
  kind?: string | null;
  heading?: string | null;
  area?: string | null;
  project?: string | null;
  created?: string | null;
  createdAt?: string | null;
  scheduled?: string | null;
  startTime?: string | null;
  durationMinutes?: number | null;
  timeZone?: string | null;
  deadline?: string | null;
  deferredDeadline?: string | null;
  today?: boolean;
  starred?: boolean;
  tags?: string[] | null;
  todaySetOn?: string | null;
  completedAt?: string | null;
  notes?: string | null;
  position?: number | null;
  todayPosition?: number | null;
  recurrenceUnit?: "day" | "week" | "month" | "year" | string | null;
  recurrenceInterval?: number | null;
  recurrenceAfterCompletion?: boolean | null;
  recurrencePaused?: boolean | null;
  recurrenceSeriesID?: string | null;
  recurrenceAnchorDate?: string | null;
  recurrenceWeekdays?: number[] | null;
  recurrenceMonthDay?: number | null;
  recurrenceOrdinalWeekday?: OrdinalWeekday | null;
  reminderAt?: string | null;
  reminderMode?: "floating" | "fixed" | string | null;
  reminderSnoozedUntil?: string | null;
  reminderDismissedAt?: string | null;
  source?: string | null;
  sourceClient?: string | null;
  /** How the task was added (registry enum taskAddedVia). Set once at creation, never on edits. */
  addedVia?: TaskAddedVia | null;
  acknowledgedAt?: string | null;
  touchedAt?: string | null;
  deferCount?: number | null;
  fadedAt?: string | null;
  dropReason?: string | null;
  /** The person the task waits on (ADR 0053), 1 to 80 characters, or null. */
  waitingOn?: string | null;
  /** The day the wait began, YYYY-MM-DD, or null. Cleared with `waitingOn`. */
  waitingSince?: string | null;
  /** Shared projects: member id of who does this task. */
  assignedTo?: string | null;
  /** Shared projects: member id of who set `assignedTo` (server-owned). */
  assignedBy?: string | null;
  /** Shared projects: day `assignedTo` was set, YYYY-MM-DD (server-owned). */
  assignedAt?: string | null;
  /** Derived input for core view membership; never stored or pushed. */
  assignedToOther?: boolean;
  effort?: string | null;
  deletedAt?: string | null;
  updatedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

/** How a task was added (ADR 0064 beta measurement), from registry/entities.json. */
export type TaskAddedVia = (typeof ENTITY_ENUMS.taskAddedVia)[number];

export interface NotesProposal {
  body: string;
  agent: string;
  at: string;
  why: string | null;
}

export interface AreaRow {
  id: string;
  title: string;
  context?: string | null;
  noteRev?: number | null;
  notesProposal?: NotesProposal | null;
  emoji?: string | null;
  position?: number | null;
  deletedAt?: string | null;
  updatedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

/**
 * An account's avatar (#857, backend/src/store/avatar.ts). Decode it with
 * `normalizeAvatar` (lib/avatar.ts): an unknown kind draws initials, an
 * unknown color draws the default color (Persimmon).
 */
export interface Avatar {
  kind: "initials" | "emoji" | "photo" | string;
  /** An id from tokens.json `avatarColors`. */
  color: string;
  /** 1 to 3 letters the person typed. Absent: derive them from the name. */
  initials?: string;
  emoji?: string;
  /** Changes with every new photo: the cache key and the `?v=` of the photo URL. */
  photoId?: string;
  /** Ms since epoch. 0: the default avatar that nobody set. */
  updatedAt: number;
}

export interface ShareMember {
  id: string;
  name: string;
  role: string;
  /** Absent on rows from before #857: the member draws initials on the default color. */
  avatar?: Avatar | null;
}

export interface ProjectShareInfo {
  id: string;
  role: string;
  me: string;
  members: ShareMember[];
}

export type ProjectChecklistMode = "plain" | "groceries";

export interface ProjectRow {
  id: string;
  title: string;
  status: "active" | "done" | "cancelled" | string;
  checklistMode?: ProjectChecklistMode | null;
  area?: string | null;
  created?: string | null;
  completedAt?: string | null;
  notes?: string | null;
  noteRev?: number | null;
  notesProposal?: NotesProposal | null;
  githubRepo?: string | null;
  position?: number | null;
  share?: ProjectShareInfo | null;
  deletedAt?: string | null;
  updatedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

export interface ChecklistItemRow {
  id: string;
  taskId: string;
  title: string;
  checked?: boolean;
  checkedAt?: string | null;
  position?: number | null;
  createdAt?: string | null;
  deletedAt?: string | null;
  updatedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

export interface TagRow {
  id: string;
  name: string;
  color?: string | null;
  position?: number | null;
  deletedAt?: string | null;
  updatedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

export interface RefSnapshot {
  title?: string;
  subtitle?: string;
  date?: string;
  url?: string;
  rawId?: string;
  account?: string;
}

export interface TaskRefRow {
  id: string;
  taskId: string;
  key: string;
  kind?: string | null;
  role?: "about" | "from" | "blocked_by" | "follow_up" | string | null;
  snapshot?: RefSnapshot | null;
  position?: number | null;
  createdBy?: string | null;
  lastSeenAt?: string | null;
  createdAt?: string | null;
  deletedAt?: string | null;
  updatedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

export interface AttachmentRow {
  id: string;
  taskId: string;
  filename: string;
  contentType: string;
  byteCount: number;
  position?: number | null;
  createdAt?: string | null;
  uploadedAt?: string | null;
  deletedAt?: string | null;
  updatedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

export interface ConvoArtifact {
  kind: string;
  title: string;
  body: string;
  refs?: string[];
}

export interface ConvoHandoff {
  instruction: string;
  actionType: "open_url" | "compose" | "call" | "none" | string;
  payload?: string;
}

export interface ConvoRow {
  id: string; // matches taskId
  confirmedIntent?: string | null;
  acceptance?: string | null;
  subtasks?: string[] | null;
  artifact?: ConvoArtifact | null;
  handoff?: ConvoHandoff | null;
  endState?: string | null;
  endStateNote?: string | null;
  assignee?: "me" | "local" | "claude" | string | null;
  stoppedAt?: string | null;
  claimedBy?: string | null;
  claimUntil?: string | null;
  endStateAt?: string | null;
  runsSinceUser?: number | null;
  deletedAt?: string | null;
  updatedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

export interface TurnRow {
  id: string; // synthetic key `${taskId}:${seq}`
  taskId: string;
  seq: number;
  role: "user" | "provider" | string;
  step: "confirm" | "ground" | "scope" | "decide" | "work" | string;
  provider?: string | null;
  confidence?: number | null;
  question?: string | null;
  options?: string[] | null;
  chosen?: string | null;
  otherText?: string | null;
  inReplyTo?: number | null;
  note?: string | null;
  ts: string;
  [key: string]: unknown;
}

export interface WireTurn {
  role: "user" | "provider";
  step: "confirm" | "ground" | "scope" | "decide" | "work";
  provider?: string | null;
  confidence?: number | null;
  question?: string | null;
  options?: string[] | null;
  chosen?: string | null;
  otherText?: string | null;
  inReplyTo?: number | null;
  note?: string | null;
  ts: string;
}

export type SyncedEntity =
  | "task"
  | "area"
  | "project"
  | "checklistItem"
  | "tag"
  | "taskRef"
  | "convo"
  | "attachment"
  | "setting";

export type DeletableSyncedEntity =
  | "task"
  | "area"
  | "project"
  | "checklistItem"
  | "tag"
  | "taskRef"
  | "attachment";

export type OutboxOp =
  | {
      clientOpId: string;
      op: "upsert";
      entity: SyncedEntity;
      id: string;
      fields: Record<string, unknown>;
      queuedAt: number;
    }
  | {
      clientOpId: string;
      op: "delete";
      entity: DeletableSyncedEntity;
      id: string;
      queuedAt: number;
    }
  | {
      clientOpId: string;
      op: "appendTurn";
      taskId: string;
      turn: WireTurn;
      queuedAt: number;
    };

export interface NotSyncedItem {
  clientOpId: string;
  entity: string;
  id: string;
  reason: string;
  at: number;
}

export interface StoreSnapshot {
  tasks: TaskRow[];
  areas: AreaRow[];
  projects: ProjectRow[];
  checklistItems: ChecklistItemRow[];
  tags: TagRow[];
  taskRefs: TaskRefRow[];
  convos: ConvoRow[];
  turns: TurnRow[];
  attachments: AttachmentRow[];
  settings: Record<string, unknown>;
  outbox: OutboxOp[];
  cursor: number;
  userId: string | null;
  lastSyncedAt: number | null;
}

export type SmartDestination =
  | "today"
  | "review"
  | "agent"
  | "upcoming"
  | "repeating"
  | "anytime"
  | "starred"
  | "logbook"
  | "faded";

export type ActiveDestination =
  | { kind: "smart"; id: SmartDestination }
  | { kind: "area"; id: string }
  | { kind: "project"; id: string };

// GET /v1/beta?platform=web (docs/BETA_ONBOARDING_SPEC.md §7, ADR 0064). The
// checklist is a normal project the server seeds in the tester's list; the app
// shows only the one-time Today card. Every word on it comes from `copy`; a
// non-tester gets `{ member: false }` and the app shows nothing.
export const zBetaCopy = z.object({
  cardTitle: z.string(),
  cardBody: z.string(),
  cardOpen: z.string(),
  cardDismiss: z.string(),
});
export const zBetaMember = z.object({
  member: z.literal(true),
  /** The seeded checklist project, or null when the server has none. */
  projectId: z.string().nullable(),
  cardDismissedAt: z.number().nullable(),
  copy: zBetaCopy,
});
export const zBetaState = z.discriminatedUnion("member", [z.object({ member: z.literal(false) }), zBetaMember]);
export type BetaMember = z.infer<typeof zBetaMember>;
export type BetaState = z.infer<typeof zBetaState>;
/** POST /v1/beta/progress: the only write is closing the Today card. */
export type BetaProgress = { dismissCard: true };
