import type { CloudKitClient } from "../cloudkit.js";
import { logEvent } from "../util.js";
import { getEffectiveTimezone, localServerTimestamp, todayYMD } from "../tz.js";
import { nextScheduledDate, occurrenceID } from "../recurrence.js";
import { listAreas } from "./listAreas.js";
import { listProjects } from "./listProjects.js";
import { awaitsReasoning, convoSummary, type ConvoTurn, type TaskConvo } from "./taskShared.js";

export type { ConvoTurn, TaskConvo } from "./taskShared.js";

// Reject writes that point a task at an area/project id with no matching
// container. CloudKit stores the FK string verbatim, so an unknown id becomes a
// dangling reference that never surfaces under any real area/project. Empty /
// undefined (clearing the field) is always allowed. Thrown as a plain Error so
// the calling model sees it as a tool error and can self-correct against
// tasks_list_areas / tasks_list_projects.
async function validateContainer(
  client: CloudKitClient,
  kind: "area" | "project",
  id: string | null | undefined,
): Promise<void> {
  if (!id) return;
  const valid =
    kind === "area"
      ? (await listAreas(client, { limit: 500 })).areas
      : (await listProjects(client, { status: "all", limit: 500 })).projects;
  const message = unknownContainerMessage(kind, id, valid);
  if (message) throw new Error(message);
}

/// The tool error for a task pointed at an area/project id that does not
/// exist, or null when `id` is one of `valid`. Pure: shared with the task
/// backend connector (src/shadow/writes.ts), which reads the containers from
/// the TaskStore instead of CloudKit.
export function unknownContainerMessage(
  kind: "area" | "project",
  id: string,
  valid: ReadonlyArray<{ id: string; title: string }>,
): string | null {
  if (valid.some((c) => c.id === id)) return null;
  const known = valid.map((c) => `${c.id} (${c.title})`).join(", ");
  return `unknown ${kind} id '${id}'. Use tasks_list_${kind}s for valid ids. Known: ${known}`;
}

// Mutators for Task records. Uses CKWS records/modify with forceUpdate.
// Identity for new tasks: base32-6 shortid per identifiers.md.

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

/// Six characters from SHORTID_ALPHABET. Rejection sampling keeps every
/// character uniform: `b & 31` used to index past the 31-character alphabet
/// one time in 32, dropping that character and leaving a short id.
export function newTaskId(): string {
  const n = SHORTID_ALPHABET.length;
  const limit = 256 - (256 % n);
  let id = "";
  while (id.length < 6) {
    const buf = new Uint8Array(12);
    crypto.getRandomValues(buf);
    for (const b of buf) {
      if (b < limit && id.length < 6) id += SHORTID_ALPHABET[b % n];
    }
  }
  return id;
}

interface CKModifyResponse {
  records: Array<{
    recordName: string;
    fields?: Record<string, { value: unknown }>;
    reason?: string;
    serverErrorCode?: string;
  }>;
}

async function modifyRecords(
  client: CloudKitClient,
  ops: Array<{
    operationType: "create" | "update" | "forceUpdate";
    record: { recordType: string; recordName: string; fields: Record<string, { value: unknown }> };
  }>,
): Promise<CKModifyResponse> {
  return client.post<CKModifyResponse>("records/modify", {
    zoneID: { zoneName: client.zoneName },
    operations: ops,
  });
}

async function lookupRecord(
  client: CloudKitClient,
  recordName: string,
): Promise<Record<string, { value: unknown }> | null> {
  const res = await client.post<CKModifyResponse>("records/lookup", {
    zoneID: { zoneName: client.zoneName },
    records: [{ recordName }],
  });
  const r = res.records[0];
  if (!r || r.serverErrorCode === "NOT_FOUND") return null;
  return r.fields ?? {};
}

// ---- Schemas (one-to-one with the CLI repo) ----

/**
 * Repeat rule shared by `tasks_create` and `tasks_update`. Mirrors the app's
 * own `Recurrence` JSON (`unit` / `interval` / `after_completion`), so a rule
 * set from chat is byte-identical to one set in the repeat picker. Nullable so
 * an update can clear it.
 *
 * LOCKSTEP: septena/SeptenaCore/MCP/MCPToolCatalog.swift `recurrenceSchema`.
 */
export const recurrenceJsonSchema = {
  type: ["object", "null"],
  description:
    "Repeat rule. Completing the task generates the next occurrence. after_completion=true counts the interval from the day you tick it off (\"every 3 days after completion\"); false counts from the previous scheduled date, which is what keeps a weekly task on its weekday (\"every Monday\") and REQUIRES the task to have a scheduled date. Pass null to clear an existing rule.",
  required: ["unit"],
  properties: {
    unit: { type: "string", enum: ["day", "week", "month"] },
    interval: { type: "integer", minimum: 1, default: 1, description: "Every N units. 1 = daily/weekly/monthly." },
    after_completion: {
      type: "boolean",
      default: true,
      description: "Anchor: true = from completion, false = from the previous scheduled date.",
    },
  },
} as const;

export const createTaskJsonSchema = {
  type: "object",
  required: ["title"],
  properties: {
    title: { type: "string", minLength: 1 },
    today: { type: "boolean", default: false },
    scheduled: { type: "string", description: "YYYY-MM-DD" },
    deadline: { type: "string", description: "YYYY-MM-DD (hard deadline)" },
    area: { type: "string", description: "Area id (e.g. 'envisioning')" },
    project: { type: "string", description: "Project id (e.g. 'septena')" },
    notes: { type: "string", description: "Free-text note body for the task." },
    recurrence: recurrenceJsonSchema,
    origin: {
      type: "string",
      enum: ["user_request", "agent_suggestion"],
      description:
        "Provenance. user_request = the user explicitly asked (lands committed, placed where specified). agent_suggestion = you surfaced it proactively (lands unratified in the inbox to review). Omit to use this connection's default (the gateway defaults to a proposal — secure by default).",
    },
  },
} as const;

export const completeTaskJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string" } },
} as const;

export const updateTaskJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id: { type: "string" },
    title: { type: "string" },
    today: { type: "boolean" },
    scheduled: { type: ["string", "null"], description: "YYYY-MM-DD, or null to clear" },
    deadline: { type: ["string", "null"], description: "YYYY-MM-DD, or null to clear" },
    area: { type: ["string", "null"] },
    project: { type: ["string", "null"] },
    status: { type: "string", enum: ["open", "cancelled"] },
    notes: { type: ["string", "null"], description: 'Free-text note body, or null/"" to clear' },
    recurrence: recurrenceJsonSchema,
  },
} as const;

export const deferTaskJsonSchema = {
  type: "object",
  required: ["id", "until"],
  properties: { id: { type: "string" }, until: { type: "string", description: "YYYY-MM-DD" } },
} as const;

export const moveToTodayJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string" } },
} as const;

export interface CreateTaskInput {
  title: string;
  today?: boolean;
  scheduled?: string;
  deadline?: string;
  /** Legacy alias for `deadline` — still accepted on input for back-compat. */
  due?: string;
  area?: string;
  project?: string;
  notes?: string;
  recurrence?: RecurrenceInput | null;
  /**
   * Provenance (docs/TASK_ROW_LANGUAGE_SPEC.md §3.4). `user_request` commits the
   * task (placed where specified); `agent_suggestion` (or omitted — the gateway's
   * secure-by-default) lands it as an unratified proposal in the triage inbox.
   */
  origin?: "user_request" | "agent_suggestion";
}

export interface UpdateTaskInput {
  id: string;
  title?: string;
  today?: boolean;
  scheduled?: string | null;
  deadline?: string | null;
  /** Legacy alias for `deadline` — still accepted on input for back-compat. */
  due?: string | null;
  area?: string | null;
  project?: string | null;
  status?: "open" | "cancelled";
  notes?: string | null;
  recurrence?: RecurrenceInput | null;
}

/** Wire form of a repeat rule. `afterCompletion` is accepted as an alias for
 *  `after_completion`: a model guessing the camelCase spelling would otherwise
 *  silently get the OPPOSITE anchor. */
export interface RecurrenceInput {
  unit?: string;
  interval?: number;
  after_completion?: boolean;
  afterCompletion?: boolean;
}

/**
 * Decodes and validates a wire repeat rule. Throws rather than dropping a
 * malformed one: a repeat the caller believes it set, that silently never
 * landed, is the worst outcome here — the task just quietly stops coming back.
 *
 * `scheduled` is the date the task will have AFTER this call. A fixed rule
 * (`after_completion: false`) has nothing to anchor to without one and would
 * degrade into an after-completion rule, so it is rejected instead.
 *
 * LOCKSTEP: septena/SeptenaCore/MCP/MCPDispatch.swift `recurrenceArg`.
 */
export function parseRecurrenceInput(
  raw: RecurrenceInput | null | undefined,
  scheduled: string | null | undefined,
): { unit: string; interval: number; afterCompletion: boolean } | null {
  if (raw === null) return null;          // explicit clear
  if (raw === undefined) return null;
  const unit = String(raw.unit ?? "");
  if (unit !== "day" && unit !== "week" && unit !== "month") {
    throw new Error("recurrence.unit must be one of: day, week, month");
  }
  const interval = raw.interval === undefined ? 1 : Number(raw.interval);
  if (!Number.isInteger(interval) || interval < 1) {
    throw new Error("recurrence.interval must be 1 or greater");
  }
  const afterCompletion = raw.after_completion ?? raw.afterCompletion ?? true;
  if (!afterCompletion && !scheduled) {
    throw new Error(
      "recurrence.after_completion=false anchors on the task's scheduled date, " +
        "so the task needs one. Set 'scheduled' in this same call, or use " +
        "after_completion=true to count from the completion day instead.",
    );
  }
  return { unit, interval, afterCompletion };
}

export type RecurrenceRuleInput = { unit: string; interval: number; afterCompletion: boolean };

/** The `recurrence` block a write echoes back: the same shape it accepts. */
export function recurrenceEcho(rule: RecurrenceRuleInput) {
  return { unit: rule.unit, interval: rule.interval, after_completion: rule.afterCompletion };
}

/**
 * The data-source-free part of `tasks_create`: the parsed rule, provenance
 * and the result echo. Throws on a bad rule, before anything is written.
 * Shared by the CloudKit tool below and the task backend connector.
 */
export function planCreate(input: CreateTaskInput) {
  const rule = parseRecurrenceInput(input.recurrence, input.scheduled);
  // Provenance (docs/TASK_ROW_LANGUAGE_SPEC.md §3.4): only an explicit
  // `user_request` commits; anything else lands as a proposal.
  const committed = input.origin === "user_request";
  const placement: "committed" | "inbox_proposal" = committed ? "committed" : "inbox_proposal";
  const deadline = input.deadline ?? input.due;
  const echo = rule ? { recurrence: recurrenceEcho(rule) } : {};
  return { rule, committed, placement, deadline, echo };
}

/**
 * A `tasks_update` call as data-source-free field writes. `null` clears a
 * field; an absent key leaves it alone. `heading: null` is set when the task
 * moves to a new area/project. `recurrence` is the parsed rule (null clears).
 */
export interface TaskUpdatePlan {
  fields: {
    title?: string;
    today?: boolean;
    scheduled?: string | null;
    deadline?: string | null;
    area?: string | null;
    project?: string | null;
    heading?: null;
    status?: "open" | "cancelled";
    notes?: string | null;
    recurrence?: RecurrenceRuleInput | null;
  };
  updated: string[];
}

/// True when validating the call's repeat rule needs the task's stored
/// `scheduled` date: a fixed-anchor rule, with no `scheduled` in this call.
export function updateNeedsStoredSchedule(input: UpdateTaskInput): boolean {
  const wantsFixedAnchor =
    input.recurrence !== undefined &&
    input.recurrence !== null &&
    (input.recurrence.after_completion ?? input.recurrence.afterCompletion ?? true) === false;
  return wantsFixedAnchor && input.scheduled === undefined;
}

/**
 * The data-source-free part of `tasks_update`. `storedScheduled` is the
 * task's current `scheduled`, needed only when `updateNeedsStoredSchedule`.
 * Throws on a bad repeat rule. Shared by the CloudKit tool below and the task
 * backend connector.
 */
export function planUpdate(input: UpdateTaskInput, storedScheduled?: string | null): TaskUpdatePlan {
  const f: TaskUpdatePlan["fields"] = {};
  const updated: string[] = [];
  if (input.title !== undefined) { f.title = input.title; updated.push("title"); }
  if (input.today !== undefined) { f.today = input.today; updated.push("today"); }
  if (input.scheduled !== undefined) { f.scheduled = input.scheduled ?? null; updated.push("scheduled"); }
  const updDeadline = input.deadline !== undefined ? input.deadline : input.due;
  if (updDeadline !== undefined) { f.deadline = updDeadline ?? null; updated.push("deadline"); }
  // Re-home clears BOTH the cross-field container AND any stale project section
  // FK (`heading`) — LOCKSTEP with the app's TasksBackend.moveToArea/
  // moveToProject (app repo docs/DRAG_AND_DROP.md §4).
  if (input.area !== undefined) {
    f.area = input.area ?? null;
    if (input.area) {
      f.project = null;
      f.heading = null;
    }
    updated.push("area");
  }
  if (input.project !== undefined) {
    f.project = input.project ?? null;
    if (input.project) {
      f.area = null;
      f.heading = null;
    }
    updated.push("project");
  }
  if (input.status !== undefined) { f.status = input.status; updated.push("status"); }
  if (input.notes !== undefined) { f.notes = input.notes ?? null; updated.push("notes"); }
  // Recurrence last, so it validates against the schedule this call may have
  // just set. Present-with-null clears; absent leaves the rule alone.
  if (input.recurrence !== undefined) {
    const effectiveScheduled = input.scheduled !== undefined ? input.scheduled : storedScheduled;
    f.recurrence = parseRecurrenceInput(input.recurrence, effectiveScheduled);
    updated.push("recurrence");
  }
  return { fields: f, updated };
}

/// Tool-result warnings for a recurring completion whose series could not
/// advance. Shared wording for both connectors.
export const recurrenceWarning = {
  noNextDate: (id: string, unit: string) =>
    `Task ${id} is recurring (every ${unit}) but the next date could not be calculated, ` +
    `so no new occurrence was created. It was still marked done.`,
  createFailed: (id: string, next: string) =>
    `Task ${id} was marked done, but its next occurrence (due ${next}) could not be created. ` +
    `It will reappear when the task is next opened in the Septena app.`,
};

/** CloudKit field triple for a rule (or the cleared form when null). */
function recurrenceFields(
  rule: { unit: string; interval: number; afterCompletion: boolean } | null,
): Record<string, { value: unknown }> {
  if (!rule) {
    return {
      recurrenceUnit: { value: "" },
      recurrenceInterval: { value: 1 },
      recurrenceAfterCompletion: { value: 1 },
    };
  }
  return {
    recurrenceUnit: { value: rule.unit },
    recurrenceInterval: { value: rule.interval },
    recurrenceAfterCompletion: { value: rule.afterCompletion ? 1 : 0 },
  };
}

// ---- Implementations ----

export async function createTask(client: CloudKitClient, input: CreateTaskInput) {
  await validateContainer(client, "area", input.area);
  await validateContainer(client, "project", input.project);
  // Validate the rule BEFORE creating anything, so a bad repeat can't leave a
  // stray non-recurring task behind.
  const plan = planCreate(input);
  const createRule = plan.rule;
  const id = newTaskId();
  const fields: Record<string, { value: unknown }> = {
    title: { value: input.title },
    status: { value: "open" },
    createdAt: { value: Date.now() },       // epoch ms → CloudKit TIMESTAMP (NSDate); canonical creation instant
    source: { value: "mcp" },               // provenance: created via the MCP gateway
    sourceClient: { value: "Claude" },      // only Claude connects today; plumb clientId through later
    today: { value: input.today ? 1 : 0 },
  };
  // Provenance (docs/TASK_ROW_LANGUAGE_SPEC.md §3.4): a *committed* task is
  // acknowledged at birth so it never wears the unseen-proposal cue and leaves
  // the triage band immediately. A *proposal* stays unacknowledged → triage
  // inbox → rendered dashed. The gateway is a consumer connection, so it
  // defaults to a proposal (secure by default); only an explicit `user_request`
  // commits.
  const committed = plan.committed;
  if (committed) fields.acknowledgedAt = { value: Date.now() };
  if (input.scheduled) fields.scheduled = { value: input.scheduled };
  const createDeadline = plan.deadline;
  if (createDeadline) fields.deadline = { value: createDeadline };
  if (input.area) fields.area = { value: input.area };
  if (input.project) fields.project = { value: input.project };
  // Plaintext field (Web Services can't see the encrypted `notes`; the app
  // reads `notesText` first, same pattern as project notes).
  if (input.notes) fields.notesText = { value: input.notes };
  if (createRule) Object.assign(fields, recurrenceFields(createRule));

  // createWithFieldFallback drops unknown fields and retries, so this is safe
  // to ship before the CloudKit prod schema learns source/sourceClient/createdAt
  // — those are intentionally NOT protected, so creates keep succeeding (fields
  // silently dropped) until the schema catches up, then provenance sticks
  // automatically. It also inspects serverErrorCode, unlike the old raw
  // modifyRecords path which reported success even when CloudKit rejected the create.
  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "Task",
    recordName: id,
    fields,
    protectedFields: ["title", "status"],
  });

  // Signals exactly when the prod schema catches up: a non-empty list here
  // (containing source/sourceClient/createdAt) means provenance isn't sticking yet.
  const placement = plan.placement;
  const echo = plan.echo;
  if (droppedFields.length > 0) {
    logEvent("task_create_dropped_fields", { id, droppedFields });
    return { id, title: input.title, placement, ...echo, droppedFields };
  }
  return { id, title: input.title, placement, ...echo };
}

export async function completeTask(client: CloudKitClient, input: { id: string }) {
  const tz = await getEffectiveTimezone(client);
  const fields = await lookupRecord(client, input.id);
  if (!fields) throw new Error(`Task not found: ${input.id}`);
  // Already terminal: report the existing completion instead of re-stamping it,
  // and never spawn a SECOND occurrence from a row that already advanced its
  // series. The app guards the same way (`guard entity.status == .open`), which
  // matters now that completion has a side effect beyond the row itself.
  if ((fields.status?.value as string | undefined) === "done") {
    return {
      id: input.id,
      status: "done",
      completedAt: (fields.completedAt?.value as string | undefined) ?? null,
      alreadyComplete: true,
    };
  }
  const completedAt = localServerTimestamp(tz);
  await modifyRecords(client, [
    {
      operationType: "forceUpdate",
      record: {
        recordType: "Task",
        recordName: input.id,
        fields: {
          status: { value: "done" },
          completedAt: { value: completedAt },
          // Do NOT clear `today`: the status guard hides done tasks from every
          // view, and clearing it loses the Today placement on un-complete
          // (matches the app's TasksBackend.complete). Never lose data.
        },
      },
    },
  ]);
  // Recurring tasks used to be REFUSED here, because only the app could
  // advance the series. The app's TasksBackend.complete now spawns the next
  // occurrence itself, so this does too — a refusal would leave the gateway
  // telling users something untrue about their own data.
  const recurrence = await spawnNextOccurrence(client, input.id, fields, tz, completedAt);
  return { id: input.id, status: "done", completedAt, ...recurrence };
}

/**
 * Create the next instance of a recurring task, mirroring the app's
 * `CloudKitTasksBackend.createRecurringOccurrence`.
 *
 * Idempotent by construction: the record name is derived from
 * (source id + next scheduled date), so the same completion arriving from the
 * phone and from chat converges on ONE record instead of racing to make two.
 * We still look it up first to avoid a pointless write.
 *
 * Never throws. The task is already marked done at this point, and failing the
 * whole tool call after a successful completion would tell the model the
 * completion didn't happen. A series that couldn't advance comes back as a
 * `recurrenceWarning` on the result instead.
 */
async function spawnNextOccurrence(
  client: CloudKitClient,
  sourceID: string,
  source: Record<string, { value: unknown }>,
  tz: string,
  completedAt: string,
): Promise<{ nextOccurrence?: { id: string; scheduled: string }; recurrenceWarning?: string }> {
  const unit = (source.recurrenceUnit?.value as string | undefined) ?? "";
  if (!unit) return {};

  const interval = Number(source.recurrenceInterval?.value ?? 1) || 1;
  const afterCompletion = Number(source.recurrenceAfterCompletion?.value ?? 0) === 1;
  const scheduled = (source.scheduled?.value as string | undefined) || null;

  const next = nextScheduledDate({
    completedOn: completedAt.slice(0, 10),
    scheduled,
    rule: { unit, interval, afterCompletion },
  });
  if (!next) {
    logEvent("recurrence_next_date_failed", { id: sourceID, unit, interval });
    return { recurrenceWarning: recurrenceWarning.noNextDate(sourceID, unit) };
  }

  const id = occurrenceID(sourceID, next);
  if (await lookupRecord(client, id)) {
    logEvent("recurrence_occurrence_exists", { id, sourceID });
    return { nextOccurrence: { id, scheduled: next } };
  }

  const sourceProvenance = source.source?.value as string | undefined;
  const fields: Record<string, { value: unknown }> = {
    title: { value: source.title?.value ?? "" },
    status: { value: "open" },
    created: { value: todayYMD(tz) },
    scheduled: { value: next },
    // A deadline belonged to the occurrence that was just completed — the new
    // one gets its next scheduled date, not an already-expired deadline.
    today: { value: 0 },
    recurrenceUnit: { value: unit },
    recurrenceInterval: { value: interval },
    recurrenceAfterCompletion: { value: afterCompletion ? 1 : 0 },
    createdAt: { value: Date.now() },
  };
  if (source.area?.value) fields.area = { value: source.area.value };
  if (source.project?.value) fields.project = { value: source.project.value };
  if (source.heading?.value) fields.heading = { value: source.heading.value };
  if (source.kind?.value) fields.kind = { value: source.kind.value };
  // Only the plaintext body carries over: `notes` is an encrypted field that
  // CloudKit Web Services cannot read, so the gateway can't copy it. The app,
  // which can, copies both. Documented divergence, not an oversight.
  if (source.notesText?.value) fields.notesText = { value: source.notesText.value };
  if (sourceProvenance) fields.source = { value: sourceProvenance };
  if (source.sourceClient?.value) fields.sourceClient = { value: source.sourceClient.value };
  // Completing an agent-authored row IS engagement with the recurring task, so
  // the next occurrence shouldn't reappear wearing a fresh "unseen" cue.
  if (sourceProvenance === "mcp") fields.acknowledgedAt = { value: Date.now() };
  else if (source.acknowledgedAt?.value) fields.acknowledgedAt = { value: source.acknowledgedAt.value };
  // `position` is deliberately NOT set. The app puts a new occurrence at the
  // top of the list, which needs a read of every task's order key; the gateway
  // has no read-before-write here (same call it already makes for chat moves),
  // so the row falls back to ordering by `createdAt` — which, for a task
  // created right now, lands it at the top anyway.

  try {
    const { droppedFields } = await client.createWithFieldFallback({
      recordType: "Task",
      recordName: id,
      fields,
      protectedFields: ["title", "status", "scheduled", "recurrenceUnit"],
    });
    if (droppedFields.length > 0) {
      logEvent("recurrence_create_dropped_fields", { id, droppedFields });
    }
    return { nextOccurrence: { id, scheduled: next } };
  } catch (err) {
    logEvent("recurrence_create_failed", { id, sourceID, error: String(err) });
    return { recurrenceWarning: recurrenceWarning.createFailed(sourceID, next) };
  }
}

export async function updateTask(client: CloudKitClient, input: UpdateTaskInput) {
  await validateContainer(client, "area", input.area);
  await validateContainer(client, "project", input.project);
  // Only pay for a read when the rule actually needs an anchor and this call
  // didn't supply one — everything else stays a blind forceUpdate.
  let storedScheduled: string | null | undefined;
  if (updateNeedsStoredSchedule(input)) {
    const existing = await lookupRecord(client, input.id);
    storedScheduled = (existing?.scheduled?.value as string | undefined) || null;
  }
  const { fields: p, updated } = planUpdate(input, storedScheduled);
  // CloudKit encoding: a cleared string field is "", a bool is 1/0. Divergence,
  // on purpose: on a re-home the app also resets `position` so the row lands at
  // the top of the destination; a chat move here deliberately does NOT (no
  // read-before-write, and landing order matters far less for an agent move) —
  // the row keeps its existing order key. The task backend connector does
  // reset it (src/shadow/writes.ts), where the read is cheap.
  // Plan key order is kept, so the request body is the one this tool sent
  // before the plan was extracted.
  const fields: Record<string, { value: unknown }> = {};
  for (const key of Object.keys(p) as Array<keyof typeof p>) {
    switch (key) {
      case "today": fields.today = { value: p.today ? 1 : 0 }; break;
      // notes → plaintext `notesText`; null/"" writes an empty string (clear),
      // matching the in-app server's clear-on-empty semantics.
      case "notes": fields.notesText = { value: p.notes ?? "" }; break;
      case "recurrence": Object.assign(fields, recurrenceFields(p.recurrence ?? null)); break;
      case "heading": fields.heading = { value: "" }; break;
      default: fields[key] = { value: p[key] ?? "" };
    }
  }

  if (updated.length === 0) return { id: input.id, updated: [] };

  await modifyRecords(client, [
    { operationType: "forceUpdate", record: { recordType: "Task", recordName: input.id, fields } },
  ]);
  return { id: input.id, updated };
}

export async function deferTask(client: CloudKitClient, input: { id: string; until: string }) {
  return updateTask(client, { id: input.id, today: false, scheduled: input.until });
}

export async function moveToToday(client: CloudKitClient, input: { id: string }) {
  return updateTask(client, { id: input.id, today: true, scheduled: null });
}

// ---- Task Conversations ----
//
// LOCKSTEP with the in-app server (app repo: SeptenaCore/MCP/MCPDispatch.swift +
// MCPToolCatalog.swift) and the shape in SeptenaCore/TaskConvo.swift. Any change
// here must land there too, or the two MCP surfaces silently diverge. Spec:
// docs/TASK_CONVERSATIONS_PLAN.md / _PHASE0.md in the app repo.
//
// The whole conversation is ONE plaintext `conversationJSON` field on the Task
// record — plaintext so Web Services can read/write it (encrypted fields are
// invisible here, same reason `notesText` exists). These verbs read-modify-write
// that blob. The field auto-registers in the dev CloudKit schema on the app's
// first native write; gateway writes assume it exists (dev-only until ship).

// ConvoTurn / TaskConvo and the summary rules live in taskShared.ts, shared
// with the read-only task-backend preview (src/shadow/).

function decodeConvo(fields: Record<string, { value: unknown }> | null): TaskConvo {
  const raw = fields?.conversationJSON?.value;
  if (typeof raw !== "string" || raw.length === 0) return { thread: [], subtasks: [] };
  try {
    const c = JSON.parse(raw) as Partial<TaskConvo>;
    return { ...c, thread: c.thread ?? [], subtasks: c.subtasks ?? [] };
  } catch {
    return { thread: [], subtasks: [] };
  }
}

async function readConvo(client: CloudKitClient, id: string): Promise<TaskConvo> {
  const fields = await lookupRecord(client, id);
  if (!fields) throw new Error(`Task not found: ${id}`);
  return decodeConvo(fields);
}

async function writeConvo(client: CloudKitClient, id: string, convo: TaskConvo): Promise<void> {
  await modifyRecords(client, [
    {
      operationType: "forceUpdate",
      record: { recordType: "Task", recordName: id, fields: { conversationJSON: { value: JSON.stringify(convo) } } },
    },
  ]);
}

/// A confirm-step turn carrying a `chosen` also caches confirmedIntent in the
/// SAME write (richer `note` wins over the bare button label). Mirrors the app.
/// Undefined when the turn sets nothing. Shared with the task backend connector.
export function confirmedIntentFor(turn: Pick<ConvoTurn, "step" | "chosen" | "note">): string | undefined {
  if (turn.step === "confirm" && turn.chosen) return turn.note ?? turn.chosen;
  return undefined;
}

/// The stored artifact for a `tasks_set_artifact` call (kind defaults to
/// "note", body to ""). Shared with the task backend connector.
export function normalizeArtifact(a: { kind?: string; title: string; body?: string; refs?: string[] }): NonNullable<TaskConvo["artifact"]> {
  return { kind: a.kind ?? "note", title: a.title, body: a.body ?? "", refs: a.refs };
}

/// The stored handoff for a `tasks_set_handoff` call (actionType defaults to
/// "none"). Shared with the task backend connector.
export function normalizeHandoff(h: {
  instruction: string;
  actionType?: "open_url" | "compose" | "call" | "none";
  payload?: string;
}): NonNullable<TaskConvo["handoff"]> {
  return { instruction: h.instruction, actionType: h.actionType ?? "none", payload: h.payload };
}

function nextSeq(c: TaskConvo): number {
  return c.thread.reduce((m, t) => Math.max(m, t.seq), 0) + 1;
}

export const threadGetJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string" } },
} as const;

export const threadAppendJsonSchema = {
  type: "object",
  required: ["id", "turn"],
  properties: {
    id: { type: "string" },
    turn: {
      type: "object",
      required: ["role", "step"],
      properties: {
        role: { type: "string", enum: ["user", "provider"] },
        step: { type: "string", enum: ["confirm", "ground", "scope", "decide", "work"] },
        provider: { type: "string", enum: ["onDevice", "claude", "applePCC"] },
        confidence: { type: "number" },
        question: { type: "string" },
        options: { type: "array", items: { type: "string" } },
        chosen: { type: "string" },
        otherText: { type: "string" },
        inReplyTo: { type: "integer" },
        note: { type: "string" },
      },
    },
  },
} as const;

export const setAcceptanceJsonSchema = {
  type: "object",
  required: ["id", "acceptance"],
  properties: { id: { type: "string" }, acceptance: { type: "string" } },
} as const;

export const setEndStateJsonSchema = {
  type: "object",
  required: ["id", "endState"],
  properties: {
    id: { type: "string" },
    endState: {
      type: "string",
      enum: ["agent_done", "human_done", "agent_assisted_done", "needs_verify", "decomposed", "reminder_set", "promoted_to_today", "wont_do", "open"],
    },
    note: { type: "string", description: "e.g. needs_verify: what to verify" },
  },
} as const;

export const setAssigneeJsonSchema = {
  type: "object",
  required: ["id", "assignee"],
  properties: {
    id: { type: "string" },
    assignee: { type: ["string", "null"], enum: ["me", "local", "claude"] },
  },
} as const;

export const pendingReasoningJsonSchema = {
  type: "object",
  properties: { limit: { type: "integer" } },
} as const;

export async function threadGet(client: CloudKitClient, input: { id: string }) {
  const conversation = await readConvo(client, input.id);
  return { id: input.id, conversation };
}

export const getTaskJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string" } },
} as const;

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

// One-call "where is this task, what's its state?" — every core field plus a
// compact conversation summary, regardless of which view (or none) the task
// lives in. Use tasks_thread_get for the full turn-by-turn conversation.
export async function getTask(client: CloudKitClient, input: { id: string }) {
  const fields = await lookupRecord(client, input.id);
  if (!fields) throw new Error(`Task not found: ${input.id}`);
  // Project headings (section dividers) are not to-dos — read as not-found over
  // MCP, mirroring listTasks and the iOS in-app server (TaskEntity.isHeading).
  if (optionalString(fields.kind?.value) === "heading") {
    throw new Error(`Task not found: ${input.id}`);
  }
  const convo = decodeConvo(fields);
  return {
    id: input.id,
    title: (fields.title?.value as string) ?? "",
    status: (fields.status?.value as string) ?? "open",
    today: ((fields.today?.value as number) ?? 0) !== 0,
    scheduled: optionalString(fields.scheduled?.value),
    deadline: optionalString(fields.deadline?.value),
    area: optionalString(fields.area?.value),
    project: optionalString(fields.project?.value),
    completedAt: optionalString(fields.completedAt?.value),
    source: optionalString(fields.source?.value),
    notes: optionalString(fields.notesText?.value),
    convo: convoSummary(convo),
  };
}

export async function threadAppend(
  client: CloudKitClient,
  input: { id: string; turn: Omit<ConvoTurn, "seq" | "ts"> & { ts?: string } },
) {
  const convo = await readConvo(client, input.id);
  const turn: ConvoTurn = { ...input.turn, seq: nextSeq(convo), ts: input.turn.ts ?? new Date().toISOString() };
  convo.thread.push(turn);
  const confirmedIntent = confirmedIntentFor(turn);
  if (confirmedIntent !== undefined) convo.confirmedIntent = confirmedIntent;
  await writeConvo(client, input.id, convo);
  return { id: input.id, seq: turn.seq };
}

export async function setAcceptance(client: CloudKitClient, input: { id: string; acceptance: string }) {
  const convo = await readConvo(client, input.id);
  convo.acceptance = input.acceptance;
  await writeConvo(client, input.id, convo);
  return { id: input.id, acceptance: input.acceptance };
}

export async function setEndState(client: CloudKitClient, input: { id: string; endState: string; note?: string }) {
  const convo = await readConvo(client, input.id);
  convo.endState = input.endState;
  convo.endStateNote = input.note;
  await writeConvo(client, input.id, convo);
  return { id: input.id, endState: input.endState };
}

export async function setAssignee(
  client: CloudKitClient,
  input: { id: string; assignee: "me" | "local" | "claude" | null },
) {
  const convo = await readConvo(client, input.id);
  convo.assignee = input.assignee ?? undefined;
  await writeConvo(client, input.id, convo);
  return { id: input.id, assignee: input.assignee ?? "auto" };
}

export const setArtifactJsonSchema = {
  type: "object",
  required: ["id", "artifact"],
  properties: {
    id: { type: "string" },
    artifact: {
      type: "object",
      required: ["title"],
      properties: {
        kind: { type: "string", description: "e.g. availability-table, draft-email, summary" },
        title: { type: "string" },
        body: { type: "string" },
        refs: { type: "array", items: { type: "string" } },
      },
    },
  },
} as const;

export const setHandoffJsonSchema = {
  type: "object",
  required: ["id", "handoff"],
  properties: {
    id: { type: "string" },
    handoff: {
      type: "object",
      required: ["instruction"],
      properties: {
        instruction: { type: "string" },
        actionType: { type: "string", enum: ["open_url", "compose", "call", "none"] },
        payload: { type: "string", description: "URL / email / phone for the action" },
      },
    },
  },
} as const;

export async function setArtifact(
  client: CloudKitClient,
  input: { id: string; artifact: { kind?: string; title: string; body?: string; refs?: string[] } },
) {
  const convo = await readConvo(client, input.id);
  convo.artifact = normalizeArtifact(input.artifact);
  await writeConvo(client, input.id, convo);
  return { id: input.id, artifact: input.artifact.title };
}

export async function setHandoff(
  client: CloudKitClient,
  input: { id: string; handoff: { instruction: string; actionType?: "open_url" | "compose" | "call" | "none"; payload?: string } },
) {
  const convo = await readConvo(client, input.id);
  convo.handoff = normalizeHandoff(input.handoff);
  await writeConvo(client, input.id, convo);
  return { id: input.id, handoff: input.handoff.instruction };
}

// Tasks awaiting reasoning: explicitly marked for Claude, OR whose last provider
// turn was low-confidence — and not yet terminal. Client-side filter on the blob
// (CKQuery can't reach into JSON). Mirrors the in-app `pendingReasoning`.
export async function pendingReasoning(client: CloudKitClient, input: { limit?: number }) {
  const limit = input.limit ?? 50;
  const res = await client.queryRecords({
    recordType: "Task",
    filterBy: [{ fieldName: "status", comparator: "EQUALS" as const, fieldValue: { value: "open" } }],
    fetchAll: true,
  });
  const tasks: Array<{ id: string; title: string; confirmedIntent?: string; assignee?: string }> = [];
  for (const r of res.records) {
    const raw = r.fields.conversationJSON?.value;
    if (typeof raw !== "string" || raw.length === 0) continue;
    const c = decodeConvo(r.fields);
    if (awaitsReasoning(c)) {
      tasks.push({
        id: r.recordName,
        title: (r.fields.title?.value as string) ?? "",
        confirmedIntent: c.confirmedIntent,
        assignee: c.assignee,
      });
      if (tasks.length >= limit) break;
    }
  }
  return { tasks };
}
