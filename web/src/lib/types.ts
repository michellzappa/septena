import { z } from "zod";

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
      createdAt: z.number().optional(),
      lastUsedAt: z.number().nullable().optional(),
      active: z.boolean().optional(),
    }),
  ),
});
export type AccessSummary = z.infer<typeof zAccessSummary>;

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
  acknowledgedAt?: string | null;
  touchedAt?: string | null;
  deferCount?: number | null;
  fadedAt?: string | null;
  dropReason?: string | null;
  effort?: string | null;
  deletedAt?: string | null;
  updatedAt?: string | null;
  rev?: number;
  [key: string]: unknown;
}

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

export interface ProjectRow {
  id: string;
  title: string;
  status: "active" | "done" | "cancelled" | string;
  area?: string | null;
  created?: string | null;
  completedAt?: string | null;
  notes?: string | null;
  noteRev?: number | null;
  notesProposal?: NotesProposal | null;
  githubRepo?: string | null;
  position?: number | null;
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
