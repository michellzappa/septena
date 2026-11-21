import { z } from "zod";
import type { Env } from "../env.js";
import { randomId } from "../util.js";
import { localServerTimestamp, todayYMD } from "../tz.js";
import { checklistOccurrenceID, nextScheduledDate, occurrenceID } from "../recurrence.js";
import { shiftReminderForRecurrence, shiftReminderOnReschedule } from "../reminders.js";
import { storeFor } from "../api/session.js";
import { zId } from "../store/columns.js";
import { zPushBody, type Op, type OpResult } from "../store/ops.js";
import { AGENT_WRITE_RULES, type Row, type TaskStore } from "../store/TaskStore.js";
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
import type { ConvoTurn } from "../tools/taskShared.js";

// Task WRITE tools for the connector on api.septena.app (src/shadow/mcp.ts),
// executed as TaskStore pushes. Same names, arguments, result shapes and error
// messages as the live CloudKit tools (src/tools/writeTasks.ts); the
// data-source-free logic (provenance, update planning, repeat-rule parsing,
// container errors, conversation normalizing, warnings) is the SAME functions,
// imported from there.
//
// Every call is ONE push: one transaction in the user's Durable Object, one
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
  | "readTasks" | "readTask" | "readAreas" | "readProjects" | "readConvoCandidates"
  | "readChecklistItems" | "readChecklistItem" | "readChecklistCounts"
  | "readOrderTop" | "readSetting" | "push" | "claim" | "release" | "agentEvents" | "history" | "head"
  | "readNote" | "noteRevisions" | "readContainer" | "readContainerTasks";
export type StoreRpc = {
  [K in StoreMethod]: (...a: Parameters<TaskStore[K]>) => Promise<ReturnType<TaskStore[K]>>;
};
export const rpcStoreFor = (env: Env, userId: string) => storeFor(env, userId) as unknown as StoreRpc;

// ---- argument schemas (validated before anything reaches the store) ----

const zDay = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD");
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
    origin: z.enum(["user_request", "agent_suggestion"]).optional(),
  }),
  tasks_complete: z.object({ id: zId }),
  tasks_update: z.object({
    id: zId,
    title: z.string().optional(),
    today: z.boolean().optional(),
    starred: z.boolean().optional(),
    scheduled: zDayOrClear.optional(),
    deadline: zDayOrClear.optional(),
    due: zDayOrClear.optional(),
    area: z.string().nullable().optional(),
    project: z.string().nullable().optional(),
    status: z.enum(["open", "cancelled"]).optional(),
    notes: z.string().nullable().optional(),
    recurrence: zRecurrence.optional(),
    reminder_at: z.string().nullable().optional(),
    reminderAt: z.string().nullable().optional(),
    reminder_mode: z.enum(["floating", "fixed"]).nullable().optional(),
    reminderMode: z.enum(["floating", "fixed"]).nullable().optional(),
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
async function push(store: StoreRpc, ops: NewOp[]): Promise<OpResult[]> {
  const base = `mcp-${randomId(12)}`;
  const withIds = ops.map((op, i) => ({ ...op, clientOpId: `${base}-${i}` })) as Op[];
  const parsed = zPushBody.safeParse({ ops: withIds });
  if (!parsed.success) {
    throw new Error(`Invalid task fields: ${parsed.error.issues.slice(0, 5).map((i) => `${i.path.slice(2).join(".")} ${i.message}`).join("; ")}`);
  }
  const { result } = await store.push(withIds, MCP_ACTOR);
  return result.results;
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
    throw new Error(`Task ${id} was not changed: the user stopped agent work on it. Only the user can resume it in Septask.`);
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

/// The app's `TaskEntity.isOnToday`: pinned, or scheduled / deadline arrived.
function onToday(t: { today?: unknown; scheduled?: unknown; deadline?: unknown }, today: string): boolean {
  const s = str(t.scheduled);
  const d = str(t.deadline);
  return t.today === true || (!!s && s <= today) || (!!d && d <= today);
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
  // Validate the rule BEFORE creating anything.
  const plan = planCreate(input);

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
    source: "mcp",
    sourceClient: "Claude",
    today: input.today === true,
    starred: input.starred === true,
    position,
  };
  if (input.today) fields.todaySetOn = today;
  if (plan.committed) fields.acknowledgedAt = now;
  if (input.scheduled) fields.scheduled = input.scheduled;
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
  if (onToday(fields, today)) fields.todayPosition = position;

  const ops: NewOp[] = [{ op: "upsert", entity: "task", id, fields }];
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

  const results = await push(store, ops);
  const r = results[0];
  if (!applied(r)) throw new Error(`Task was not created: ${r?.status === "rejected" ? r.reason : r?.status ?? "no result"}`);
  return {
    id,
    title: input.title,
    placement: plan.placement,
    ...plan.echo,
    ...(createdChecklist.length > 0 ? { checklist: createdChecklist } : {}),
  };
}

async function updateTask(ctx: WriteContext, input: UpdateTaskInput) {
  const { store } = ctx;
  await assertKnownContainer(store, "area", input.area);
  await assertKnownContainer(store, "project", input.project);
  const current = await store.readTask(input.id);
  if (!current) throw new Error(`Task not found: ${input.id}`);
  const old = current.task;
  const storedScheduled = updateNeedsStoredSchedule(input) ? (str(old.scheduled) ?? null) : undefined;
  const { fields: p, updated } = planUpdate(input, storedScheduled);
  if (updated.length === 0) return { id: input.id, updated: [] };

  const today = todayYMD(ctx.timeZone);
  const clear = (v: string | null) => (v === "" ? null : v);
  const fields: Record<string, unknown> = {};
  if (p.title !== undefined) fields.title = p.title;
  if (p.today !== undefined) {
    fields.today = p.today;
    fields.todaySetOn = p.today ? today : null;
  }
  if (p.starred !== undefined) fields.starred = p.starred;
  if (p.scheduled !== undefined) {
    const nextSched = clear(p.scheduled);
    fields.scheduled = nextSched;
    if (p.reminderAt === undefined) {
      const shifted = shiftReminderOnReschedule({
        reminderAt: str(old.reminderAt),
        oldScheduled: str(old.scheduled),
        newScheduled: nextSched,
      });
      if (shifted !== str(old.reminderAt)) {
        fields.reminderAt = shifted;
        fields.reminderSnoozedUntil = null;
        fields.reminderDismissedAt = null;
      }
    }
  }
  if (p.reminderAt !== undefined) {
    fields.reminderAt = p.reminderAt;
    fields.reminderMode = p.reminderMode ?? null;
    fields.reminderSnoozedUntil = null;
    fields.reminderDismissedAt = null;
  }
  if (p.deadline !== undefined) fields.deadline = clear(p.deadline);
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

  const [r] = await push(store, [{ op: "upsert", entity: "task", id: input.id, fields }]);
  requireApplied(r, input.id);
  return { id: input.id, updated };
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
  const canSpawnOccurrence = !current.convo?.stoppedAt && current.convo?.assignee !== "claude";
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
          scheduled: next,
          // A deadline belonged to the completed occurrence.
          today: false,
          starred: src.starred === true,
          ...recurrenceColumns({ unit, interval, afterCompletion, weekdays, monthDay, ordinalWeekday }),
          recurrenceSeriesID: str(src.recurrenceSeriesID) ?? id,
          recurrenceAnchorDate: afterCompletion ? null : next,
          position,
          createdAt: now,
        };
        for (const k of ["area", "project", "heading", "kind", "notes", "sourceClient"] as const) {
          if (str(src[k])) fields[k] = src[k];
        }
        const shiftedReminder = shiftReminderForRecurrence({
          sourceReminderAt: str(src.reminderAt),
          sourceScheduled: str(src.recurrenceAnchorDate) ?? str(src.scheduled),
          nextScheduled: next,
        });
        if (shiftedReminder) {
          fields.reminderAt = shiftedReminder;
          fields.reminderMode = str(src.reminderMode) ?? "floating";
        }
        if (str(src.source)) fields.source = src.source;
        // Completing an agent-authored row is engagement with the series, so
        // the next occurrence does not show a fresh "unseen" cue.
        if (src.source === "mcp") fields.acknowledgedAt = now;
        else if (str(src.acknowledgedAt)) fields.acknowledgedAt = src.acknowledgedAt;
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
      }
    }
  }

  const results = await push(store, ops);
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
  const results = await push(store, ops);
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
  const [r] = await push(store, [{ op: "upsert", entity: "checklistItem", id: input.id, fields }]);
  requireApplied(r, input.id);
  return { id: input.id, updated: Object.keys(fields) };
}

async function checklistDelete(ctx: WriteContext, id: string) {
  const { store } = ctx;
  const current = await store.readChecklistItem(id);
  if (!current) throw new Error(`Checklist item not found: ${id}`);
  const [r] = await push(store, [{ op: "delete", entity: "checklistItem", id }]);
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
  const results = await push(ctx.store, ops);
  requireApplied(results[0], input.id);
  const r = results[0];
  return { id: input.id, seq: r.status === "applied" ? r.seq : undefined };
}

async function writeConvo(ctx: WriteContext, id: string, fields: Record<string, unknown>): Promise<void> {
  const [r] = await push(ctx.store, [{ op: "upsert", entity: "convo", id, fields }]);
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
