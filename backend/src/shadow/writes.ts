import { z } from "zod";
import type { Env } from "../env.js";
import { randomId } from "../util.js";
import { localServerTimestamp, todayYMD } from "../tz.js";
import { checklistOccurrenceID, nextScheduledDate, occurrenceID } from "../recurrence.js";
import { applyDateAction, nextOccurrenceDates, normalizeTaskDates, taskRefId, taskViewMembership, type CoreDateAction, type CoreTask } from "../core/index.js";
import { storeFor } from "../api/session.js";
import { MAX_REFS_PER_TASK, MAX_TAGS_PER_TASK, TAG_NAME_MAX, zId } from "../store/columns.js";
import { zPushBody, type Op, type OpResult } from "../store/ops.js";
import { AGENT_WRITE_RULES, isAgentActor, type Row, type TaskStore } from "../store/TaskStore.js";
import {
  type CreateTaskInput,
  type RecurrenceRuleInput,
  type UpdateTaskInput,
  confirmedIntentFor,
  newTaskId,
  normalizeArtifact,
  normalizeHandoff,
  planCreate,
  planUpdate,
  recurrenceWarning,
  unknownContainerMessage,
  updateNeedsStoredSchedule,
} from "../tools/writeTasks.js";
import { type ConvoTurn, appendNotes, notesRev, replaceNotesSection } from "../tools/taskShared.js";
import { type ResolvedRef, parseRefArg, resolveRefs, snapshotFor, zRefKeys, zRefs } from "./refs.js";
import { SURFACES_CATALOG } from "../generated/registries.js";

// Task WRITE tools for the connector on api.septena.app (src/shadow/mcp.ts),
// executed as TaskStore pushes. Same names, arguments, result shapes and error
// messages as the live CloudKit tools (src/tools/writeTasks.ts); the
// data-source-free logic (provenance, update planning, repeat-rule parsing,
// container errors, conversation normalizing, warnings) is the SAME functions,
// imported from there.
//
// Every call is ONE push (a create with a `from` reference is ONE captureTask): one transaction in the user's Durable Object, one
// `{rev}` nudge to the user's connected app sockets (TaskStore.push
// broadcasts whenever an op applied). The actor in the change log is
// `mcp:claude`. clientOpIds are minted here, random per call, one per op.
//
// Where the backend row model differs from the CloudKit record, the app's own
// TasksBackend is the reference, not the live gateway:
//   - A new task gets `position` at the top of the list (TaskOrder.topPosition)
//     and `created`/`todaySetOn`; a task given a project drops its area.
//   - A re-home (new area/project) puts the row at the top of its new list.
//   - A row that lands on Today gets `todayPosition` = its `position`, the
//     app's rule for a row's Today slot (TaskBackendMapping, §12).
//   - Completion honours `recurrencePaused` and the series' logical slot
//     (`recurrenceAnchorDate`), and the occurrence carries the series fields.

export const MCP_ACTOR = "mcp:claude";

/// An op before its clientOpId is minted.
type NewOp = Op extends infer O ? (O extends Op ? Omit<O, "clientOpId"> : never) : never;

/// TaskOrder.gap in the app (SeptenaCore/Persistence.swift).
const ORDER_GAP = 1024;

/// The DO's methods as plain async calls. Typed from TaskStore's own
/// declarations: the generated RPC stub type recurses too deep on JSON rows.
type StoreMethod =
  | "readTasks" | "readReviewTasks" | "readOpenQuestions" | "readTask" | "readAreas" | "readProjects" | "readConvoCandidates" | "readTaskLinks"
  | "readTaskRefs" | "findByRef" | "isDismissed" | "newRefId"
  | "readChecklistItems" | "readChecklistItem" | "readChecklistCounts"
  | "readTags" | "readTagByName"
  | "readOrderTop" | "readSetting" | "push" | "captureTask" | "claim" | "release" | "agentEvents" | "history" | "head"
  | "addUsage" | "connectionName"
  | "readNote" | "noteRevisions" | "readContainer" | "readContainerTasks";
export type StoreRpc = {
  [K in StoreMethod]: (...a: Parameters<TaskStore[K]>) => Promise<ReturnType<TaskStore[K]>>;
};
export const rpcStoreFor = (env: Env, userId: string) => storeFor(env, userId) as unknown as StoreRpc;

// ---- argument schemas (validated before anything reaches the store) ----

const zDay = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD");
const zTime24 = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, "expected HH:MM");
const zTime24OrClear = z.union([zTime24, z.literal("")]).nullable();
/// "" clears, as on the live connector, which writes "" to CloudKit.
const zDayOrClear = z.union([zDay, z.literal("")]).nullable();
const zOrdinalWeekday = z.object({
  ordinal: z.number(),
  weekday: z.number(),
});
const zRecurrence = z.object({
  unit: z.string().optional(),
  interval: z.number().optional(),
  after_completion: z.boolean().optional(),
  afterCompletion: z.boolean().optional(),
  weekdays: z.array(z.number()).nullable().optional(),
  month_day: z.number().nullable().optional(),
  monthDay: z.number().nullable().optional(),
  ordinal_weekday: zOrdinalWeekday.nullable().optional(),
  ordinalWeekday: zOrdinalWeekday.nullable().optional(),
}).nullable();

export const zWriteArgs = {
  tasks_create: z.object({
    title: z.string().min(1),
    today: z.boolean().optional(),
    starred: z.boolean().optional(),
    scheduled: zDay.optional(),
    start_time: zTime24.nullable().optional(),
    startTime: zTime24.nullable().optional(),
    duration_minutes: z.number().int().min(5).max(1440).nullable().optional(),
    durationMinutes: z.number().int().min(5).max(1440).nullable().optional(),
    time_zone: z.string().max(64).nullable().optional(),
    timeZone: z.string().max(64).nullable().optional(),
    deadline: zDay.optional(),
    due: zDay.optional(),
    area: z.string().optional(),
    project: z.string().optional(),
    notes: z.string().optional(),
    recurrence: zRecurrence.optional(),
    reminder_at: z.string().nullable().optional(),
    reminderAt: z.string().nullable().optional(),
    reminder_mode: z.enum(["floating", "fixed"]).nullable().optional(),
    reminderMode: z.enum(["floating", "fixed"]).nullable().optional(),
    checklist: z.array(z.string().min(1).max(2000)).max(200).optional(),
    tags: z.array(z.string().trim().min(1).max(TAG_NAME_MAX)).max(MAX_TAGS_PER_TASK).optional(),
    refs: zRefs.optional(),
    allow_duplicate: z.boolean().optional(),
    origin: z.enum(["user_request", "agent_suggestion"]).optional(),
  }),
  tasks_complete: z.object({ id: zId }),
  tasks_update: z.object({
    id: zId,
    title: z.string().optional(),
    today: z.boolean().optional(),
    starred: z.boolean().optional(),
    scheduled: zDayOrClear.optional(),
    start_time: zTime24OrClear.optional(),
    startTime: zTime24OrClear.optional(),
    duration_minutes: z.number().int().min(5).max(1440).nullable().optional(),
    durationMinutes: z.number().int().min(5).max(1440).nullable().optional(),
    time_zone: z.string().max(64).nullable().optional(),
    timeZone: z.string().max(64).nullable().optional(),
    deadline: zDayOrClear.optional(),
    due: zDayOrClear.optional(),
    area: z.string().nullable().optional(),
    project: z.string().nullable().optional(),
    status: z.enum(["open", "cancelled"]).optional(),
    notes: z.string().nullable().optional(),
    notes_append: z.string().min(1).optional(),
    notes_section: z.object({ heading: z.string().min(1), body: z.string() }).optional(),
    notes_rev: z.string().min(1).max(64).optional(),
    recurrence: zRecurrence.optional(),
    reminder_at: z.string().nullable().optional(),
    reminderAt: z.string().nullable().optional(),
    reminder_mode: z.enum(["floating", "fixed"]).nullable().optional(),
    reminderMode: z.enum(["floating", "fixed"]).nullable().optional(),
    tags: z.array(z.string().trim().min(1).max(TAG_NAME_MAX)).max(MAX_TAGS_PER_TASK).nullable().optional(),
    refs: zRefs.optional(),
    refs_remove: zRefKeys.optional(),
  }),
  tasks_defer: z.object({ id: zId, until: zDay }),
  tasks_move_to_today: z.object({ id: zId }),
  tasks_thread_append: z.object({
    id: zId,
    turn: z.object({
      role: z.enum(["user", "provider"]),
      step: z.enum(["confirm", "ground", "scope", "decide", "work"]),
      provider: z.enum(["onDevice", "claude", "applePCC"]).optional(),
      confidence: z.number().min(0).max(1).optional(),
      question: z.string().optional(),
      options: z.array(z.string()).optional(),
      chosen: z.string().optional(),
      otherText: z.string().optional(),
      inReplyTo: z.number().int().positive().optional(),
      note: z.string().optional(),
      ts: z.string().datetime({ offset: true }).optional(),
    }),
  }),
  tasks_set_acceptance: z.object({ id: zId, acceptance: z.string() }),
  tasks_set_endstate: z.object({
    id: zId,
    endState: z.enum([
      "agent_done", "human_done", "agent_assisted_done", "needs_verify", "decomposed",
      "reminder_set", "promoted_to_today", "wont_do", "open",
    ]),
    note: z.string().optional(),
  }),
  tasks_set_assignee: z.object({ id: zId, assignee: z.enum(["me", "local", "claude"]).nullable() }),
  tasks_set_artifact: z.object({
    id: zId,
    artifact: z.object({
      kind: z.string().optional(),
      title: z.string(),
      body: z.string().optional(),
      refs: z.array(z.string()).optional(),
    }),
  }),
  tasks_set_handoff: z.object({
    id: zId,
    handoff: z.object({
      instruction: z.string(),
      actionType: z.enum(["open_url", "compose", "call", "none"]).optional(),
      payload: z.string().optional(),
    }),
  }),
  tasks_checklist_add: z.object({
    task_id: zId,
    items: z.array(z.string().min(1).max(2000)).min(1).max(200),
  }),
  tasks_checklist_update: z.object({
    id: zId,
    title: z.string().min(1).max(2000).optional(),
    checked: z.boolean().optional(),
    position: z.number().finite().optional(),
  }),
  tasks_checklist_delete: z.object({
    id: zId,
  }),
};
export type WriteToolName = keyof typeof zWriteArgs;
export const WRITE_TOOL_NAMES = Object.keys(zWriteArgs) as WriteToolName[];

export interface WriteContext {
  store: StoreRpc;
  /// IANA zone from the pairing; decides "today" and the completion stamp.
  timeZone: string;
  /// Who the change log credits. Absent = the MCP agent (`MCP_ACTOR`). The
  /// app REST surface (`/v1/tasks`, the watch) passes `app:<client>` so the
  /// store treats the write as the human, not an agent.
  actor?: string;
  /// Provenance stamped on a created task. Absent = the MCP connector.
  source?: { source: string; sourceClient: string };
  /// The connector's registered client name ("Claude", "Claude Code",
  /// "Codex"): the agent a task created over MCP names as its author
  /// (`sourceClient`). Absent or blank = the registry fallback name.
  agentName?: string;
}

/// The registry's name for an agent author when the connection has no
/// client name (`surfaces.json` `taskPage.provenance.agentFallbackName`).
const PROVENANCE_BLOCK = SURFACES_CATALOG.taskPage.blocks.find((b) => b.kind === "provenance");
export const AGENT_FALLBACK_NAME: string =
  PROVENANCE_BLOCK && "agentFallbackName" in PROVENANCE_BLOCK ? PROVENANCE_BLOCK.agentFallbackName : "Claude";

/// The `sourceClient` an MCP-created task carries: the connector's client
/// name, without control characters, cut to the column's 64 characters.
export function agentSourceClient(name: string | undefined): string {
  const clean = (name ?? "").replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 64);
  return clean || AGENT_FALLBACK_NAME;
}

/// The change log actor for an MCP write by the connection named `name`:
/// `mcp:<name>`, so history says which agent changed what. No name = the
/// legacy `MCP_ACTOR`.
export function mcpActorFor(name: string | undefined): string {
  const clean = (name ?? "").replace(/[\u0000-\u001f\u007f@]/g, "").trim().slice(0, 64);
  return clean ? `mcp:${clean}` : MCP_ACTOR;
}

/// The agent's display name in an `mcp:` actor: `mcp:Claude Code` and the
/// agent loop's `mcp:<agent>@<client>` give the name; the legacy
/// `mcp:claude` gives the registry fallback name.
export function agentNameFromActor(actor: string): string {
  const name = actor.replace(/^mcp:/, "").split("@")[0].trim();
  return !name || name === "claude" ? AGENT_FALLBACK_NAME : name;
}

/// Runs one validated write tool. Throws a plain Error (the tool error the
/// live connector would give) on a missing task, an unknown container or a
/// bad repeat rule.
export async function runWriteTool(ctx: WriteContext, name: WriteToolName, args: Record<string, unknown>): Promise<unknown> {
  switch (name) {
    case "tasks_create":
      return createTask(ctx, args as unknown as CreateTaskInput);
    case "tasks_complete":
      return completeTask(ctx, args.id as string);
    case "tasks_update":
      return updateTask(ctx, args as unknown as UpdateTaskInput);
    case "tasks_defer":
      return updateTask(ctx, { id: args.id as string, today: false, scheduled: args.until as string });
    case "tasks_move_to_today":
      return updateTask(ctx, { id: args.id as string, today: true, scheduled: null });
    case "tasks_thread_append":
      return threadAppend(ctx, args as { id: string; turn: Omit<ConvoTurn, "seq" | "ts"> & { ts?: string } });
    case "tasks_set_acceptance": {
      const acceptance = args.acceptance as string;
      await writeConvo(ctx, args.id as string, { acceptance });
      return { id: args.id, acceptance };
    }
    case "tasks_set_endstate": {
      const endState = args.endState as string;
      await writeConvo(ctx, args.id as string, { endState, endStateNote: (args.note as string | undefined) ?? null });
      return { id: args.id, endState };
    }
    case "tasks_set_assignee": {
      const assignee = (args.assignee as "me" | "local" | "claude" | null) ?? null;
      await writeConvo(ctx, args.id as string, { assignee });
      return { id: args.id, assignee: assignee ?? "auto" };
    }
    case "tasks_set_artifact": {
      const a = args.artifact as { kind?: string; title: string; body?: string; refs?: string[] };
      await writeConvo(ctx, args.id as string, { artifact: dropUndefined(normalizeArtifact(a)) });
      return { id: args.id, artifact: a.title };
    }
    case "tasks_set_handoff": {
      const h = args.handoff as { instruction: string; actionType?: "open_url" | "compose" | "call" | "none"; payload?: string };
      await writeConvo(ctx, args.id as string, { handoff: dropUndefined(normalizeHandoff(h)) });
      return { id: args.id, handoff: h.instruction };
    }
    case "tasks_checklist_add":
      return checklistAdd(ctx, args.task_id as string, args.items as string[]);
    case "tasks_checklist_update":
      return checklistUpdate(ctx, args as { id: string; title?: string; checked?: boolean; position?: number });
    case "tasks_checklist_delete":
      return checklistDelete(ctx, args.id as string);
  }
}

// ---- push plumbing ----

/// One push for the whole call. The ops are checked against the same schema
/// /v1/sync/push uses, so this path can never store what an app push could
/// not.
async function push(store: StoreRpc, actor: string | undefined, ops: NewOp[]): Promise<OpResult[]> {
  const { result } = await store.push(mintOps(ops), actor ?? MCP_ACTOR);
  return result.results;
}

/// The ops with their clientOpIds, checked.
function mintOps(ops: NewOp[]): Op[] {
  const base = `mcp-${randomId(12)}`;
  const withIds = ops.map((op, i) => ({ ...op, clientOpId: `${base}-${i}` })) as Op[];
  const parsed = zPushBody.safeParse({ ops: withIds });
  if (!parsed.success) {
    throw new Error(`Invalid task fields: ${parsed.error.issues.slice(0, 5).map((i) => `${i.path.slice(2).join(".")} ${i.message}`).join("; ")}`);
  }
  return withIds;
}

const applied = (r: OpResult | undefined) => r?.status === "applied";

/// A rejected or dropped op on an existing task means the task is gone (or
/// never existed): the live connector's error for that.
function requireApplied(r: OpResult | undefined, id: string): void {
  if (applied(r) || r?.status === "noop") return;
  if (r?.status === "dropped" || (r?.status === "rejected" && /unknown_task|missing_required/.test(r.reason))) {
    throw new Error(`Task not found: ${id}`);
  }
  if (r?.status === "rejected" && r.reason === "stopped") {
    throw new Error(`Task ${id} was not changed: the user stopped agent work on it. Only the user can resume it in Septena.`);
  }
  if (r?.status === "rejected" && r.reason === "paused") {
    throw new Error(`Task ${id} was not changed (paused): ${AGENT_WRITE_RULES.paused}`);
  }
  if (r?.status === "rejected" && r.reason === "human_accepts") {
    throw new Error(`Task ${id} was not completed (human_accepts): ${r.rule ?? AGENT_WRITE_RULES.human_accepts}`);
  }
  throw new Error(`Task ${id} was not changed: ${r?.status === "rejected" ? r.reason : "no result"}`);
}

async function topPosition(store: StoreRpc): Promise<number> {
  return ((await store.readOrderTop()) ?? 0) - ORDER_GAP;
}

async function assertKnownContainer(store: StoreRpc, kind: "area" | "project", id: string | null | undefined) {
  if (!id) return;
  const rows = kind === "area" ? await store.readAreas(500) : await store.readProjects("all", 500);
  const message = unknownContainerMessage(kind, id, rows.map((r) => ({ id: r.id as string, title: str(r.title) ?? "" })));
  if (message) throw new Error(message);
}

/// Resolve human tag names case-insensitively against the store's live tags,
/// producing `tag` upsert ops for any missing tags (unless `allowCreate` is
/// false). Deduplicates case-insensitively and caps at `MAX_TAGS_PER_TASK`.
async function resolveTagNames(
  store: StoreRpc,
  rawNames: string[],
  allowCreate: boolean,
): Promise<{ tagIds: string[]; tagNames: string[]; tagOps: NewOp[] }> {
  const existing = await store.readTags();
  const byLower = new Map<string, { id: string; name: string }>();
  for (const r of existing) {
    const name = str(r.name);
    if (name) byLower.set(name.toLowerCase(), { id: r.id as string, name });
  }
  const tagIds: string[] = [];
  const tagNames: string[] = [];
  const tagOps: NewOp[] = [];
  const seenIds = new Set<string>();
  for (const raw of rawNames) {
    const trimmed = raw.trim();
    if (!trimmed) continue;
    const key = trimmed.toLowerCase();
    let entry = byLower.get(key);
    if (!entry) {
      if (!allowCreate) continue;
      const id = `tag-${randomId(10)}`;
      entry = { id, name: trimmed };
      byLower.set(key, entry);
      tagOps.push({ op: "upsert", entity: "tag", id, fields: { name: trimmed } });
    }
    if (!seenIds.has(entry.id) && tagIds.length < MAX_TAGS_PER_TASK) {
      seenIds.add(entry.id);
      tagIds.push(entry.id);
      tagNames.push(entry.name);
    }
  }
  return { tagIds, tagNames, tagOps };
}

/// The insert of one reference.
function refInsert(taskId: string, id: string, r: ResolvedRef, position: number, now: string): NewOp {
  const snapshot = snapshotFor(r);
  return {
    op: "upsert", entity: "taskRef", id,
    fields: { taskId, key: r.ref.key, role: r.role ?? "about", ...(snapshot ? { snapshot } : {}), position, createdAt: now },
  };
}

/// The reference part of a write's result: what is on the task now, and what
/// the store refused (an agent's reference while agents are paused). Nothing
/// is dropped without a word.
function refResult(refs: ResolvedRef[], results: (OpResult | undefined)[]) {
  const ok = refs.filter((_, i) => applied(results[i]) || results[i]?.status === "noop");
  const refused = refs.flatMap((r, i) => {
    const res = results[i];
    return res?.status === "rejected" ? [{ key: r.ref.key, reason: res.reason, ...(res.rule ? { rule: res.rule } : {}) }] : [];
  });
  return {
    ...(ok.length > 0 ? { refs: ok.map((r) => ({ key: r.ref.key, kind: r.ref.kind, role: r.role ?? "about" })) } : {}),
    ...(refused.length > 0 ? { refs_refused: refused } : {}),
  };
}

/// Whether an open row with these date fields is on Today: the core's rule
/// (pinned, or a When date or deadline that has arrived).
function onToday(
  t: { today?: unknown; scheduled?: unknown; deadline?: unknown; deferredDeadline?: unknown }, today: string,
): boolean {
  return taskViewMembership(
    {
      status: "open", today: t.today === true, scheduled: str(t.scheduled) ?? null,
      deadline: str(t.deadline) ?? null, deferredDeadline: str(t.deferredDeadline) ?? null,
    },
    today, new Date().toISOString(),
  ).isOnToday;
}

/// A stored or planned row as the core reads it.
function coreRow(r: Record<string, unknown>): CoreTask {
  const n = (v: unknown) => (typeof v === "number" ? v : null);
  return {
    id: str(r.id), title: str(r.title), status: str(r.status) ?? "open", kind: str(r.kind) ?? null,
    area: str(r.area) ?? null, project: str(r.project) ?? null,
    created: str(r.created) ?? null, createdAt: str(r.createdAt) ?? null,
    scheduled: str(r.scheduled) ?? null, deadline: str(r.deadline) ?? null,
    deferredDeadline: str(r.deferredDeadline) ?? null,
    today: r.today === true, todaySetOn: str(r.todaySetOn) ?? null,
    source: str(r.source) ?? null, acknowledgedAt: str(r.acknowledgedAt) ?? null,
    starred: r.starred === true,
    recurrenceUnit: str(r.recurrenceUnit) ?? null,
    recurrenceAfterCompletion: typeof r.recurrenceAfterCompletion === "boolean" ? r.recurrenceAfterCompletion : null,
    recurrenceAnchorDate: str(r.recurrenceAnchorDate) ?? null,
    deletedAt: str(r.deletedAt) ?? null, fadedAt: str(r.fadedAt) ?? null,
    startTime: str(r.startTime) ?? null, durationMinutes: n(r.durationMinutes), timeZone: str(r.timeZone) ?? null,
    reminderAt: str(r.reminderAt) ?? null, reminderSnoozedUntil: str(r.reminderSnoozedUntil) ?? null,
    reminderDismissedAt: str(r.reminderDismissedAt) ?? null,
  };
}

/// The date part of an update, as spec §4 actions the core decides (D4,
/// #291): When (Today pin or day), then deadline, then time slot, each on
/// the fields the one before it left. Returns the changed columns. The
/// agent cue is only cleared for a human surface (`human`): an agent that
/// re-dates its own proposal has not ratified it.
function planDateEdits(
  old: Record<string, unknown>,
  p: { today?: boolean; scheduled?: string | null; deadline?: string | null;
       startTime?: string | null; durationMinutes?: number | null; timeZone?: string | null },
  today: string, now: string, human: boolean,
): Record<string, unknown> {
  const actions: CoreDateAction[] = [];
  const day = (v: string | null | undefined) => (v === "" || v === undefined ? null : v);
  const when = day(p.scheduled);
  if (p.today === true) {
    actions.push({ type: "putOnToday" });
    if (when) actions.push({ type: "scheduleFor", day: when });
  } else if (p.today === false) {
    // A day with the unpin is a move to that day (the deadline stays, Q1; an
    // arrived one no longer holds the task on Today, Q8);
    // an unpin alone is Remove from Today (A3, arrived dates go too, Q2).
    if (p.scheduled === undefined) actions.push({ type: "removeFromToday" });
    else actions.push(when ? { type: "scheduleFor", day: when } : { type: "clearWhenDate" });
  } else if (p.scheduled !== undefined) {
    actions.push(when ? { type: "scheduleFor", day: when } : { type: "clearWhenDate" });
  }
  if (p.deadline !== undefined) actions.push({ type: "setDeadline", day: day(p.deadline) });
  if (p.startTime !== undefined || p.durationMinutes !== undefined || p.timeZone !== undefined) {
    actions.push({
      type: "setTimeSlot",
      startTime: p.startTime !== undefined ? p.startTime : str(old.startTime) ?? null,
      durationMinutes: p.durationMinutes !== undefined ? p.durationMinutes : (typeof old.durationMinutes === "number" ? old.durationMinutes : null),
      timeZone: p.timeZone !== undefined ? p.timeZone : str(old.timeZone) ?? null,
    });
  }
  const row: Record<string, unknown> = { ...old };
  const changed: Record<string, unknown> = {};
  for (const action of actions) {
    const patch = applyDateAction(coreRow(row), action, today, now);
    Object.assign(row, patch);
    Object.assign(changed, patch);
  }
  if (!human) delete changed.acknowledgedAt;
  return changed;
}

function recurrenceColumns(rule: RecurrenceRuleInput | null): Record<string, unknown> {
  if (!rule) {
    return {
      recurrenceUnit: null,
      recurrenceInterval: 1,
      recurrenceAfterCompletion: true,
      recurrencePaused: false,
      recurrenceWeekdays: null,
      recurrenceMonthDay: null,
      recurrenceOrdinalWeekday: null,
    };
  }
  return {
    recurrenceUnit: rule.unit,
    recurrenceInterval: rule.interval,
    recurrenceAfterCompletion: rule.afterCompletion,
    recurrencePaused: false,
    recurrenceWeekdays: rule.weekdays && rule.weekdays.length > 0 ? rule.weekdays : null,
    recurrenceMonthDay: rule.monthDay ?? null,
    recurrenceOrdinalWeekday: rule.ordinalWeekday ?? null,
  };
}

// ---- tasks ----

async function createTask(ctx: WriteContext, input: CreateTaskInput) {
  const { store } = ctx;
  await assertKnownContainer(store, "area", input.area);
  await assertKnownContainer(store, "project", input.project);
  // Validate the rule and the references BEFORE creating anything.
  const plan = planCreate(input);
  const refs = resolveRefs(input.refs ?? []);

  let id = newTaskId();
  for (let i = 0; i < 3 && (await store.readTask(id)); i++) id = newTaskId();

  const today = todayYMD(ctx.timeZone);
  const now = new Date().toISOString();
  const position = await topPosition(store);
  const fields: Record<string, unknown> = {
    title: input.title,
    status: "open",
    created: today,
    createdAt: now,
    source: ctx.source?.source ?? "mcp",
    sourceClient: ctx.source?.sourceClient ?? agentSourceClient(ctx.agentName),
    today: input.today === true,
    starred: input.starred === true,
    position,
  };
  if (input.today) fields.todaySetOn = today;
  // A human capture (the watch) is engaged by definition.
  if (plan.committed || ctx.source) fields.acknowledgedAt = now;
  if (input.scheduled) fields.scheduled = input.scheduled;
  if (plan.startTime) {
    fields.startTime = plan.startTime;
    if (plan.durationMinutes !== null) fields.durationMinutes = plan.durationMinutes;
    if (plan.timeZone) fields.timeZone = plan.timeZone;
  }
  if (plan.deadline) fields.deadline = plan.deadline;
  // A project implies its area: the app stores one or the other.
  if (input.project) fields.project = input.project;
  else if (input.area) fields.area = input.area;
  if (input.notes) fields.notes = input.notes;
  if (plan.rule) {
    Object.assign(fields, recurrenceColumns(plan.rule));
    fields.recurrenceSeriesID = id;
    if (!plan.rule.afterCompletion && input.scheduled) fields.recurrenceAnchorDate = input.scheduled;
  }
  if (plan.reminder?.reminderAt) {
    fields.reminderAt = plan.reminder.reminderAt;
    fields.reminderMode = plan.reminder.reminderMode;
  }
  // The date invariants (I1–I8): a pin with a future When date keeps the
  // date, a pin with an arrived one keeps the pin.
  Object.assign(fields, normalizeTaskDates(coreRow(fields), today));
  if (onToday(fields, today)) fields.todayPosition = position;

  const ops: NewOp[] = [];
  let resolvedTagNames: string[] = [];
  if (input.tags && input.tags.length > 0) {
    const paused = (await store.readSetting("agentsPaused")) === true;
    const resolved = await resolveTagNames(store, input.tags, !paused);
    ops.push(...resolved.tagOps);
    if (resolved.tagIds.length > 0) fields.tags = resolved.tagIds;
    resolvedTagNames = resolved.tagNames;
  }
  const taskOpIdx = ops.length;
  ops.push({ op: "upsert", entity: "task", id, fields });
  const createdChecklist: Array<{ id: string; title: string; position: number }> = [];
  if (input.checklist && input.checklist.length > 0) {
    for (let i = 0; i < input.checklist.length; i++) {
      const stepTitle = input.checklist[i].trim();
      if (!stepTitle) continue;
      const itemId = `chk-${randomId(10)}`;
      const pos = (createdChecklist.length + 1) * ORDER_GAP;
      ops.push({
        op: "upsert",
        entity: "checklistItem",
        id: itemId,
        fields: { taskId: id, title: stepTitle, checked: false, position: pos, createdAt: now },
      });
      createdChecklist.push({ id: itemId, title: stepTitle, position: pos });
    }
  }

  const refOpIdx = ops.length;
  refs.forEach((ref, i) => ops.push(refInsert(id, taskRefId(id, ref.ref.key, 0), ref, (i + 1) * ORDER_GAP, now)));

  // A task made from an item outside Septena: the store checks for one that
  // exists in the same call as the insert (§6.2).
  const fromKeys = refs.filter((ref) => ref.role === "from").map((ref) => ref.ref.key);
  let results: OpResult[];
  let followUp: { id: string; title: string } | null = null;
  if (fromKeys.length > 0) {
    const outcome = await store.captureTask(
      mintOps(ops), ctx.actor ?? MCP_ACTOR,
      { taskId: id, fromKeys, allowDuplicate: input.allow_duplicate === true, suggestion: !plan.committed && !ctx.source },
    );
    if (outcome.existing) {
      const { id: existingId, title, status, area, project, keys } = outcome.existing;
      return {
        id: existingId, title, placement: "existing", status,
        ...(area ? { area } : {}), ...(project ? { project } : {}), matched_keys: keys,
      };
    }
    if (outcome.dismissed) {
      return {
        title: input.title, placement: "dismissed", matched_keys: outcome.dismissed,
        rule: "The user turned down a proposal made from this item. Do not propose it again.",
      };
    }
    results = outcome.results;
    followUp = outcome.followUp;
  } else {
    results = await push(store, ctx.actor, ops);
  }
  const r = results[taskOpIdx];
  if (!applied(r)) throw new Error(`Task was not created: ${r?.status === "rejected" ? r.reason : r?.status ?? "no result"}`);
  return {
    id,
    title: input.title,
    placement: plan.placement,
    ...plan.echo,
    ...(resolvedTagNames.length > 0 ? { tags: resolvedTagNames } : {}),
    ...(createdChecklist.length > 0 ? { checklist: createdChecklist } : {}),
    ...refResult(refs, results.slice(refOpIdx)),
    ...(followUp ? { follow_up: followUp } : {}),
  };
}

async function updateTask(ctx: WriteContext, input: UpdateTaskInput) {
  const { store } = ctx;
  await assertKnownContainer(store, "area", input.area);
  await assertKnownContainer(store, "project", input.project);
  const current = await store.readTask(input.id);
  if (!current) throw new Error(`Task not found: ${input.id}`);
  const old = current.task;
  input = resolveNotesEdit(input, str(old.notes));
  const storedScheduled = updateNeedsStoredSchedule(input) ? (str(old.scheduled) ?? null) : undefined;
  const { fields: p, updated } = planUpdate(input, storedScheduled);
  const hasTagChange = input.tags !== undefined;
  const refOps = await planRefs(store, input);
  if (updated.length === 0 && !hasTagChange) {
    if (refOps.ops.length === 0) return { id: input.id, updated: refOps.updated };
    const results = await push(store, ctx.actor, refOps.ops);
    for (const r of results) requireApplied(r, input.id);
    return { id: input.id, updated: refOps.updated };
  }

  const today = todayYMD(ctx.timeZone);
  const clear = (v: string | null) => (v === "" ? null : v);
  const fields: Record<string, unknown> = {};
  if (p.title !== undefined) fields.title = p.title;
  if (p.starred !== undefined) fields.starred = p.starred;
  // Every date field goes through the core's actions (spec §4).
  Object.assign(fields, planDateEdits(old, p, today, new Date().toISOString(), !!ctx.source));
  if (p.reminderAt !== undefined) {
    fields.reminderAt = p.reminderAt;
    fields.reminderMode = p.reminderMode ?? null;
    fields.reminderSnoozedUntil = null;
    fields.reminderDismissedAt = null;
  }
  if (p.area !== undefined) fields.area = clear(p.area);
  if (p.project !== undefined) fields.project = clear(p.project);
  if (p.heading !== undefined) fields.heading = null;
  if (p.status !== undefined) fields.status = p.status;
  if (p.notes !== undefined) fields.notes = clear(p.notes);
  if (p.recurrence !== undefined) {
    Object.assign(fields, recurrenceColumns(p.recurrence));
    if (p.recurrence) {
      // One row, not the series: the app's setRecurrence for the addressed row.
      fields.recurrenceSeriesID = str(old.recurrenceSeriesID) ?? input.id;
      const scheduledAfter = fields.scheduled !== undefined ? (fields.scheduled as string | null) : str(old.scheduled) ?? null;
      fields.recurrenceAnchorDate = p.recurrence.afterCompletion ? null : (str(old.recurrenceAnchorDate) ?? scheduledAfter);
    }
  }

  // A row that enters a new area/project lands at the top of that list, as
  // in the app (TasksBackend.moveToList). Headings keep their place.
  const after = { ...old, ...fields } as Row;
  const entersNewHome = (p.area || p.project)
    && (str(after.area) !== str(old.area) || str(after.project) !== str(old.project))
    && str(old.kind) !== "heading";
  if (entersNewHome) fields.position = await topPosition(store);
  // A row that lands on Today starts at its list position there.
  if (onToday(after, today) && (!onToday(old, today) || fields.position !== undefined)) {
    fields.todayPosition = (fields.position as number | undefined) ?? num(old.position) ?? (await topPosition(store));
  }

  const ops: NewOp[] = [];
  if (input.tags !== undefined) {
    updated.push("tags");
    if (input.tags === null || input.tags.length === 0) {
      fields.tags = null;
    } else {
      // Never auto-create tags when the task is stopped or agents are paused;
      // the task op itself still hits TaskStore so the store refuses cleanly.
      const allowCreate = !current.convo?.stoppedAt && (await store.readSetting("agentsPaused")) !== true;
      const resolved = await resolveTagNames(store, input.tags, allowCreate);
      if (allowCreate) ops.push(...resolved.tagOps);
      fields.tags = resolved.tagIds.length > 0 ? resolved.tagIds : null;
    }
  }
  const taskOpIdx = ops.length;
  ops.push({ op: "upsert", entity: "task", id: input.id, fields });
  ops.push(...refOps.ops);

  const results = await push(store, ctx.actor, ops);
  requireApplied(results[taskOpIdx], input.id);
  // The task changed. A refused reference (agents are paused) is named, so
  // the caller does not retry the fields that landed.
  const refused = results.slice(taskOpIdx + 1).flatMap((r) =>
    r.status === "rejected" ? [{ reason: r.reason, ...(r.rule ? { rule: r.rule } : {}) }] : []);
  if (refused.length === 0) updated.push(...refOps.updated);
  return { id: input.id, updated, ...(refused.length > 0 ? { refs_refused: refused } : {}), ...(p.notes !== undefined ? { notesRev: notesRev(clear(p.notes)) } : {}) };
}

/// The ops of `refs` (add or update by key) and `refs_remove`. Removals go
/// first, so a full task can replace a reference in one call.
async function planRefs(store: StoreRpc, input: UpdateTaskInput): Promise<{ ops: NewOp[]; updated: string[] }> {
  const ops: NewOp[] = [];
  const updated: string[] = [];
  if (!input.refs?.length && !input.refs_remove?.length) return { ops, updated };
  const refs = resolveRefs(input.refs ?? []);
  const remove = new Set((input.refs_remove ?? []).map((k, i) => parseRefArg(k, `refs_remove[${i}]`).key));
  if (refs.some((r) => remove.has(r.ref.key))) throw new Error("The same key is in refs and refs_remove.");
  const live = new Map((await store.readTaskRefs(input.id)).map((r) => [r.key as string, r]));
  for (const key of remove) {
    const row = live.get(key);
    if (!row) continue;
    ops.push({ op: "delete", entity: "taskRef", id: row.id as string });
    live.delete(key);
  }
  if (ops.length > 0) updated.push("refs_remove");
  const removed = ops.length;
  const fresh = refs.filter((r) => !live.has(r.ref.key));
  if (live.size + fresh.length > MAX_REFS_PER_TASK) {
    throw new Error(`A task has at most ${MAX_REFS_PER_TASK} references. Nothing was written.`);
  }
  for (const r of refs) {
    const row = live.get(r.ref.key);
    if (!row) continue;
    const fields: Record<string, unknown> = {};
    if (r.role !== undefined && r.role !== row.role) fields.role = r.role;
    if (r.snapshot !== undefined) fields.snapshot = snapshotFor(r);
    if (Object.keys(fields).length > 0) ops.push({ op: "upsert", entity: "taskRef", id: row.id as string, fields });
  }
  const now = new Date().toISOString();
  let position = Math.max(0, ...[...live.values()].map((r) => num(r.position) ?? 0));
  for (const r of fresh) {
    position += ORDER_GAP;
    ops.push(refInsert(input.id, await store.newRefId(input.id, r.ref.key), r, position, now));
  }
  if (ops.length > removed) updated.push("refs");
  return { ops, updated };
}

/// Turns notes_append / notes_section into a plain `notes` write against the
/// stored text, after the notes_rev check. Throws a conflict that carries the
/// current notes and rev when the notes changed since the agent's read.
function resolveNotesEdit(input: UpdateTaskInput, stored: string | undefined): UpdateTaskInput {
  const edits = [input.notes !== undefined, input.notes_append !== undefined, input.notes_section !== undefined]
    .filter(Boolean).length;
  if (edits > 1) throw new Error("Pass only one of notes, notes_append and notes_section.");
  if (input.notes_rev !== undefined && input.notes_rev !== notesRev(stored)) {
    throw new Error(
      `conflict: the notes changed since notes_rev ${input.notes_rev}. Nothing was written. ` +
      `Current notesRev: ${notesRev(stored)}. Current notes:\n${stored ?? ""}`,
    );
  }
  const { notes_append, notes_section, notes_rev: _rev, ...rest } = input;
  if (notes_append !== undefined) return { ...rest, notes: appendNotes(stored, notes_append) };
  if (notes_section !== undefined) return { ...rest, notes: replaceNotesSection(stored, notes_section.heading, notes_section.body) };
  return rest;
}

async function completeTask(ctx: WriteContext, id: string) {
  const { store } = ctx;
  const current = await store.readTask(id);
  if (!current) throw new Error(`Task not found: ${id}`);
  const src = current.task;
  // Already terminal: report the existing completion, and never spawn a
  // second occurrence from a row that already advanced its series.
  if (src.status === "done") {
    return { id, status: "done", completedAt: str(src.completedAt) ?? null, alreadyComplete: true };
  }
  const completedAt = localServerTimestamp(ctx.timeZone);
  const ops: NewOp[] = [
    // `today` is kept: done rows are hidden by status, and un-completing
    // returns the row to where it was (as the app).
    { op: "upsert", entity: "task", id, fields: { status: "done", completedAt } },
  ];

  let recurrence: { nextOccurrence?: { id: string; scheduled: string }; recurrenceWarning?: string } = {};
  let occurrenceOp = -1;
  const unit = str(src.recurrenceUnit);
  // Don't batch a next-occurrence insert alongside a completion the store will
  // refuse (stopped or Claude-assigned): `ops[0]` still hits TaskStore so the
  // store remains the single enforcer, without leaving an orphan occurrence.
  // The store refuses only agents: a person who completes the task here (the
  // watch, the desk orb) keeps the series going.
  const refusable = isAgentActor(ctx.actor ?? MCP_ACTOR);
  const canSpawnOccurrence = !refusable || (!current.convo?.stoppedAt && current.convo?.assignee !== "claude");
  if (unit && src.recurrencePaused !== true && canSpawnOccurrence) {
    const interval = Number(src.recurrenceInterval ?? 1) || 1;
    const afterCompletion = src.recurrenceAfterCompletion === true;
    const weekdays = Array.isArray(src.recurrenceWeekdays) && src.recurrenceWeekdays.length > 0
      ? (src.recurrenceWeekdays as number[])
      : undefined;
    const monthDay = typeof src.recurrenceMonthDay === "number" ? src.recurrenceMonthDay : undefined;
    const ordinalWeekday = src.recurrenceOrdinalWeekday && typeof src.recurrenceOrdinalWeekday === "object"
      ? (src.recurrenceOrdinalWeekday as { ordinal: number; weekday: number })
      : undefined;
    // Same date and id rule as the app (Recurrence.nextDate with the logical
    // slot, Recurrence.occurrenceID), so a completion here and one in the app
    // converge on ONE occurrence row.
    const next = nextScheduledDate({
      completedOn: completedAt.slice(0, 10),
      scheduled: str(src.scheduled) ?? null,
      logicalScheduled: str(src.recurrenceAnchorDate) ?? null,
      rule: { unit, interval, afterCompletion, weekdays, monthDay, ordinalWeekday },
    });
    if (!next) {
      recurrence = { recurrenceWarning: recurrenceWarning.noNextDate(id, unit) };
    } else {
      const occId = occurrenceID(id, next);
      recurrence = { nextOccurrence: { id: occId, scheduled: next } };
      if (!(await store.readTask(occId))) {
        const today = todayYMD(ctx.timeZone);
        const now = new Date().toISOString();
        const position = await topPosition(store);
        const fields: Record<string, unknown> = {
          title: str(src.title) ?? "",
          status: "open",
          created: today,
          starred: src.starred === true,
          ...(Array.isArray(src.tags) && src.tags.length > 0 ? { tags: src.tags } : {}),
          ...recurrenceColumns({ unit, interval, afterCompletion, weekdays, monthDay, ordinalWeekday }),
          recurrenceSeriesID: str(src.recurrenceSeriesID) ?? id,
          position,
          createdAt: now,
        };
        for (const k of ["area", "project", "heading", "kind", "notes", "sourceClient", "source"] as const) {
          if (str(src[k])) fields[k] = src[k];
        }
        // The next row's date fields are the core's (spec A10): the new day,
        // no deadline, no pin, the same time slot, the reminder moved with
        // the day, the slot of a fixed repeat, and an agent row arriving
        // acknowledged (completing it was engagement with the series).
        Object.assign(fields, nextOccurrenceDates(coreRow(src), next, now));
        if (fields.reminderAt) fields.reminderMode = str(src.reminderMode) ?? "floating";
        if (onToday(fields, today)) fields.todayPosition = position;
        occurrenceOp = ops.length;
        ops.push({ op: "upsert", entity: "task", id: occId, fields });

        // Copy active checklist items onto the spawned occurrence, reset to
        // unchecked with deterministic IDs so phone + agent completions converge.
        const sourceItems = await store.readChecklistItems(id);
        for (let i = 0; i < sourceItems.length; i++) {
          const item = sourceItems[i];
          const itemId = checklistOccurrenceID(occId, i, item.id as string);
          ops.push({
            op: "upsert",
            entity: "checklistItem",
            id: itemId,
            fields: {
              taskId: occId,
              title: str(item.title) ?? "",
              checked: false,
              checkedAt: null,
              position: num(item.position) ?? (i + 1) * ORDER_GAP,
              createdAt: now,
            },
          });
        }

        // The occurrence is about the same things (spec §4.2). The other roles
        // belong to the completed row.
        for (const ref of await store.readTaskRefs(id)) {
          if (ref.role !== "about") continue;
          const key = ref.key as string;
          ops.push({
            op: "upsert",
            entity: "taskRef",
            id: taskRefId(occId, key, 0),
            fields: {
              taskId: occId, key, role: "about",
              ...(ref.snapshot ? { snapshot: ref.snapshot } : {}),
              ...(num(ref.position) !== undefined ? { position: num(ref.position) } : {}),
              createdAt: now,
            },
          });
        }
      }
    }
  }

  const results = await push(store, ctx.actor, ops);
  if (results[0]?.status === "rejected" && results[0].reason === "human_accepts") {
    return {
      id,
      completed: false,
      reason: "human_accepts",
      rule: results[0].rule ?? AGENT_WRITE_RULES.human_accepts,
    };
  }
  requireApplied(results[0], id);
  if (occurrenceOp >= 0 && !applied(results[occurrenceOp]) && recurrence.nextOccurrence) {
    // Dropped: that occurrence was deleted before (for example by an undo in
    // the app), and a deleted row stays deleted.
    recurrence = { recurrenceWarning: recurrenceWarning.createFailed(id, recurrence.nextOccurrence.scheduled) };
  }
  return { id, status: "done", completedAt, ...recurrence };
}

// ---- checklists ----

async function checklistAdd(ctx: WriteContext, taskId: string, items: string[]) {
  const { store } = ctx;
  const current = await store.readTask(taskId);
  if (!current) throw new Error(`Task not found: ${taskId}`);
  const existing = await store.readChecklistItems(taskId);
  let maxPos = 0;
  for (const row of existing) {
    const p = num(row.position);
    if (p !== undefined && p > maxPos) maxPos = p;
  }
  const now = new Date().toISOString();
  const ops: NewOp[] = [];
  const added: Array<{ id: string; title: string; position: number }> = [];
  for (const raw of items) {
    const title = raw.trim();
    if (!title) continue;
    maxPos += ORDER_GAP;
    const id = `chk-${randomId(10)}`;
    ops.push({
      op: "upsert",
      entity: "checklistItem",
      id,
      fields: { taskId, title, checked: false, position: maxPos, createdAt: now },
    });
    added.push({ id, title, position: maxPos });
  }
  if (ops.length === 0) return { task_id: taskId, added: [] };
  const results = await push(store, ctx.actor, ops);
  for (let i = 0; i < results.length; i++) {
    requireApplied(results[i], added[i].id);
  }
  return { task_id: taskId, added };
}

async function checklistUpdate(
  ctx: WriteContext,
  input: { id: string; title?: string; checked?: boolean; position?: number },
) {
  const { store } = ctx;
  const current = await store.readChecklistItem(input.id);
  if (!current) throw new Error(`Checklist item not found: ${input.id}`);
  const fields: Record<string, unknown> = {};
  if (input.title !== undefined) fields.title = input.title.trim();
  if (input.checked !== undefined) {
    fields.checked = input.checked;
    fields.checkedAt = input.checked ? new Date().toISOString() : null;
  }
  if (input.position !== undefined) fields.position = input.position;
  if (Object.keys(fields).length === 0) return { id: input.id, updated: [] };
  const [r] = await push(store, ctx.actor, [{ op: "upsert", entity: "checklistItem", id: input.id, fields }]);
  requireApplied(r, input.id);
  return { id: input.id, updated: Object.keys(fields) };
}

async function checklistDelete(ctx: WriteContext, id: string) {
  const { store } = ctx;
  const current = await store.readChecklistItem(id);
  if (!current) throw new Error(`Checklist item not found: ${id}`);
  const [r] = await push(store, ctx.actor, [{ op: "delete", entity: "checklistItem", id }]);
  requireApplied(r, id);
  return { id, deleted: true };
}

// ---- conversations ----

async function threadAppend(
  ctx: WriteContext,
  input: { id: string; turn: Omit<ConvoTurn, "seq" | "ts"> & { ts?: string } },
) {
  const t = input.turn;
  const turn = dropUndefined({
    role: t.role,
    step: t.step,
    provider: t.provider,
    confidence: t.confidence,
    question: t.question,
    options: t.options,
    chosen: t.chosen,
    otherText: t.otherText,
    inReplyTo: t.inReplyTo,
    note: t.note,
    ts: t.ts ?? new Date().toISOString(),
  });
  const ops: NewOp[] = [{ op: "appendTurn", taskId: input.id, turn }];
  const confirmedIntent = confirmedIntentFor(t);
  if (confirmedIntent !== undefined) {
    ops.push({ op: "upsert", entity: "convo", id: input.id, fields: { confirmedIntent } });
  }
  const results = await push(ctx.store, ctx.actor, ops);
  requireApplied(results[0], input.id);
  const r = results[0];
  return { id: input.id, seq: r.status === "applied" ? r.seq : undefined };
}

/// The app's Send back (`TasksBackend.sendBackConvo`): the user's note as a
/// turn, the task open again and back with the agent. One push.
export async function sendBackReview(ctx: WriteContext, id: string, note: string): Promise<{ id: string; seq?: number }> {
  const results = await push(ctx.store, ctx.actor, [
    { op: "appendTurn", taskId: id, turn: { role: "user", step: "work", note, ts: new Date().toISOString() } },
    { op: "upsert", entity: "convo", id, fields: { endState: "open", endStateNote: null, stoppedAt: null, assignee: "claude" } },
  ]);
  requireApplied(results[0], id);
  requireApplied(results[1], id);
  const r = results[0];
  return { id, seq: r.status === "applied" ? r.seq : undefined };
}

/// The app's Accept on a review: complete the task, then acknowledge one an
/// agent added (`TasksBackend.acknowledge`).
export async function acceptReview(ctx: WriteContext, id: string): Promise<object> {
  const before = await ctx.store.readTask(id);
  const done = await completeTask(ctx, id);
  if (before?.task.source === "mcp" && !before.task.acknowledgedAt) {
    await push(ctx.store, ctx.actor, [{ op: "upsert", entity: "task", id, fields: { acknowledgedAt: new Date().toISOString() } }]);
  }
  return done;
}

async function writeConvo(ctx: WriteContext, id: string, fields: Record<string, unknown>): Promise<void> {
  const [r] = await push(ctx.store, ctx.actor, [{ op: "upsert", entity: "convo", id, fields }]);
  requireApplied(r, id);
}

// ---- helpers ----

function dropUndefined<T extends Record<string, unknown>>(o: T): T {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(o)) if (v !== undefined) out[k] = v;
  return out as T;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}
