import { z } from "zod";
import { ENTITIES, ENTITY_NAMES, pushableFields, zId, type EntityName } from "./columns.js";

// Wire shapes for POST /v1/sync/push (docs/SEPTASK_BACKEND.md §6.1).
// Validated in the Worker before anything reaches the Durable Object.

const zClientOpId = z.string().min(8).max(64).regex(/^[A-Za-z0-9_-]+$/);

const upsertOps = ENTITY_NAMES.map((name) =>
  z.object({
    clientOpId: zClientOpId,
    op: z.literal("upsert"),
    entity: z.literal(name),
    id: zId,
    fields: z.object(pushableFields(ENTITIES[name])).partial().strict(),
  }).strict(),
);

const zDelete = z.object({
  clientOpId: zClientOpId,
  op: z.literal("delete"),
  // Conversations are deleted with their task, never on their own.
  entity: z.enum(["task", "area", "project", "attachment"]),
  id: zId,
}).strict();

export const zTurn = z.object({
  role: z.enum(["user", "provider"]),
  step: z.enum(["confirm", "ground", "scope", "decide", "work"]),
  provider: z.string().max(32).nullable().optional(),
  confidence: z.number().min(0).max(1).nullable().optional(),
  question: z.string().max(10_000).nullable().optional(),
  options: z.array(z.string().max(500)).max(20).nullable().optional(),
  chosen: z.string().max(500).nullable().optional(),
  otherText: z.string().max(10_000).nullable().optional(),
  inReplyTo: z.number().int().positive().nullable().optional(),
  note: z.string().max(100_000).nullable().optional(),
  ts: z.string().datetime({ offset: true }),
}).strict();
export type Turn = z.infer<typeof zTurn>;

const zAppendTurn = z.object({
  clientOpId: zClientOpId,
  op: z.literal("appendTurn"),
  taskId: zId,
  turn: zTurn,
}).strict();

const zOp = z.union([...upsertOps, zDelete, zAppendTurn] as unknown as [z.ZodTypeAny, z.ZodTypeAny, ...z.ZodTypeAny[]]);

export const MAX_OPS_PER_PUSH = 500;

export const zPushBody = z.object({
  ops: z.array(zOp).min(1).max(MAX_OPS_PER_PUSH),
}).strict();

export type Op =
  | { clientOpId: string; op: "upsert"; entity: EntityName; id: string; fields: Record<string, unknown> }
  | { clientOpId: string; op: "delete"; entity: Exclude<EntityName, "convo">; id: string }
  | { clientOpId: string; op: "appendTurn"; taskId: string; turn: Turn };

export type OpResult =
  | { clientOpId: string; status: "applied"; rev: number; seq?: number }
  | { clientOpId: string; status: "noop" }
  | { clientOpId: string; status: "dropped"; rev: number; reason: "deleted" }
  | { clientOpId: string; status: "rejected"; reason: string };

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
