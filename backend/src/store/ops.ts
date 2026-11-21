import { z } from "zod";
import { ENTITIES, ENTITY_NAMES, SETTING_KEYS, SETTING_VALUES, pushableFields, zId, type EntityName } from "./columns.js";
import { DELETABLE_ENTITIES, ENTITY_ENUMS, ENTITY_LIMITS, ENTITY_PATTERNS } from "../generated/registries.js";

// Wire shapes for POST /v1/sync/push (docs/SEPTASK_BACKEND.md §6.1).
// Validated in the Worker before anything reaches the Durable Object.

const zClientOpId = z.string().regex(new RegExp(ENTITY_PATTERNS.clientOpId));

const upsertOps = ENTITY_NAMES.filter((name) => name !== "setting").map((name) =>
  z.object({
    clientOpId: zClientOpId,
    op: z.literal("upsert"),
    entity: z.literal(name),
    id: zId,
    fields: z.object(pushableFields(ENTITIES[name])).partial().strict(),
  }).strict(),
);

// A setting upsert names its key as the id and carries only `value`, typed by
// that key's schema (columns.ts `SETTING_VALUES`). Unknown keys fail.
const settingOps = SETTING_KEYS.map((key) =>
  z.object({
    clientOpId: zClientOpId,
    op: z.literal("upsert"),
    entity: z.literal("setting"),
    id: z.literal(key),
    fields: z.object({ value: SETTING_VALUES[key].nullable() }).strict(),
  }).strict(),
);

const zDelete = z.object({
  clientOpId: zClientOpId,
  op: z.literal("delete"),
  // Conversations are deleted with their task, never on their own. Settings
  // are never deleted (columns.ts).
  entity: z.enum(DELETABLE_ENTITIES),
  id: zId,
}).strict();

export const zTurn = z.object({
  role: z.enum(ENTITY_ENUMS.convoTurnRole),
  step: z.enum(ENTITY_ENUMS.convoTurnStep),
  provider: z.string().max(ENTITY_LIMITS.turnProviderMax).nullable().optional(),
  confidence: z.number().min(0).max(1).nullable().optional(),
  question: z.string().max(ENTITY_LIMITS.turnQuestionMax).nullable().optional(),
  options: z.array(z.string().max(ENTITY_LIMITS.turnOptionMax)).max(ENTITY_LIMITS.turnMaxOptions).nullable().optional(),
  chosen: z.string().max(ENTITY_LIMITS.turnChosenMax).nullable().optional(),
  otherText: z.string().max(ENTITY_LIMITS.turnOtherTextMax).nullable().optional(),
  inReplyTo: z.number().int().positive().nullable().optional(),
  note: z.string().max(ENTITY_LIMITS.turnNoteMax).nullable().optional(),
  ts: z.string().datetime({ offset: true }),
}).strict();
export type Turn = z.infer<typeof zTurn>;

const zAppendTurn = z.object({
  clientOpId: zClientOpId,
  op: z.literal("appendTurn"),
  taskId: zId,
  turn: zTurn,
}).strict();

const zOp = z.union([...upsertOps, ...settingOps, zDelete, zAppendTurn] as unknown as [z.ZodTypeAny, z.ZodTypeAny, ...z.ZodTypeAny[]]);

export const MAX_OPS_PER_PUSH = ENTITY_LIMITS.maxOpsPerPush;

export const zPushBody = z.object({
  ops: z.array(zOp).min(1).max(MAX_OPS_PER_PUSH),
}).strict();

export type Op =
  | { clientOpId: string; op: "upsert"; entity: EntityName; id: string; fields: Record<string, unknown> }
  | { clientOpId: string; op: "delete"; entity: Exclude<EntityName, "convo" | "setting">; id: string }
  | { clientOpId: string; op: "appendTurn"; taskId: string; turn: Turn };

export type OpResult =
  | { clientOpId: string; status: "applied"; rev: number; seq?: number }
  | { clientOpId: string; status: "noop" }
  | { clientOpId: string; status: "dropped"; rev: number; reason: "deleted" }
  | { clientOpId: string; status: "rejected"; reason: string; rule?: string };

export interface PushResult {
  appliedThrough: number;
  results: OpResult[];
}

export interface PullResult {
  /// Set when `since` is older than the tombstone purge horizon: the client
  /// must discard its cache and pull again from 0.
  resetRequired?: true;
  changes: Array<{ entity: EntityName | "turn"; row: Record<string, unknown> }>;
  nextSince: number;
  hasMore: boolean;
}
