import type { CloudKitClient } from "../cloudkit.js";
import { logEvent } from "../util.js";
import { getEffectiveTimezone, localServerTimestamp } from "../tz.js";
import { listAreas } from "./listAreas.js";
import { listProjects } from "./listProjects.js";

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
  if (valid.some((c) => c.id === id)) return;
  const known = valid.map((c) => `${c.id} (${c.title})`).join(", ");
  throw new Error(
    `unknown ${kind} id '${id}'. Use tasks_list_${kind}s for valid ids. Known: ${known}`,
  );
}

// Mutators for Task records. Uses CKWS records/modify with forceUpdate.
// Identity for new tasks: base32-6 shortid per identifiers.md.

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

export function newTaskId(): string {
  const buf = new Uint8Array(6);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => SHORTID_ALPHABET[b & 31]).join("");
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
}

// ---- Implementations ----

export async function createTask(client: CloudKitClient, input: CreateTaskInput) {
  await validateContainer(client, "area", input.area);
  await validateContainer(client, "project", input.project);
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
  const committed = input.origin === "user_request";
  if (committed) fields.acknowledgedAt = { value: Date.now() };
  if (input.scheduled) fields.scheduled = { value: input.scheduled };
  const createDeadline = input.deadline ?? input.due;
  if (createDeadline) fields.deadline = { value: createDeadline };
  if (input.area) fields.area = { value: input.area };
  if (input.project) fields.project = { value: input.project };
  // Plaintext field (Web Services can't see the encrypted `notes`; the app
  // reads `notesText` first, same pattern as project notes).
  if (input.notes) fields.notesText = { value: input.notes };

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
  const placement = committed ? "committed" : "inbox_proposal";
  if (droppedFields.length > 0) {
    logEvent("task_create_dropped_fields", { id, droppedFields });
    return { id, title: input.title, placement, droppedFields };
  }
  return { id, title: input.title, placement };
}

export async function completeTask(client: CloudKitClient, input: { id: string }) {
  const tz = await getEffectiveTimezone(client);
  const fields = await lookupRecord(client, input.id);
  if (!fields) throw new Error(`Task not found: ${input.id}`);
  const recurrenceUnit = fields.recurrenceUnit?.value as string | undefined;
  if (recurrenceUnit && recurrenceUnit.length > 0) {
    throw new Error(
      `Task ${input.id} is recurring (every ${recurrenceUnit}). Complete it in the Septena app so the next occurrence spawns.`,
    );
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
  return { id: input.id, status: "done", completedAt };
}

export async function updateTask(client: CloudKitClient, input: UpdateTaskInput) {
  await validateContainer(client, "area", input.area);
  await validateContainer(client, "project", input.project);
  const fields: Record<string, { value: unknown }> = {};
  const updated: string[] = [];
  if (input.title !== undefined) { fields.title = { value: input.title }; updated.push("title"); }
  if (input.today !== undefined) {
    fields.today = { value: input.today ? 1 : 0 };
    updated.push("today");
  }
  if (input.scheduled !== undefined) { fields.scheduled = { value: input.scheduled ?? "" }; updated.push("scheduled"); }
  const updDeadline = input.deadline !== undefined ? input.deadline : input.due;
  if (updDeadline !== undefined) { fields.deadline = { value: updDeadline ?? "" }; updated.push("deadline"); }
  // Re-home clears BOTH the cross-field container AND any stale project section
  // FK (`heading`) — LOCKSTEP with the app's TasksBackend.moveToArea/
  // moveToProject (app repo docs/DRAG_AND_DROP.md §4). Divergence, on purpose:
  // the app also resets `position` so the row lands at the top of the
  // destination; a chat move deliberately does NOT (no read-before-write here,
  // and landing order matters far less for an agent move) — the row keeps its
  // existing order key. Documented, not an oversight.
  if (input.area !== undefined) {
    fields.area = { value: input.area ?? "" };
    if (input.area) {
      fields.project = { value: "" };
      fields.heading = { value: "" };
    }
    updated.push("area");
  }
  if (input.project !== undefined) {
    fields.project = { value: input.project ?? "" };
    if (input.project) {
      fields.area = { value: "" };
      fields.heading = { value: "" };
    }
    updated.push("project");
  }
  if (input.status !== undefined) { fields.status = { value: input.status }; updated.push("status"); }
  // notes → plaintext `notesText`; null/"" writes an empty string (clear),
  // matching the in-app server's clear-on-empty semantics.
  if (input.notes !== undefined) { fields.notesText = { value: input.notes ?? "" }; updated.push("notes"); }

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

export interface ConvoTurn {
  seq: number;
  role: "user" | "provider";          // propose (provider) vs choose (user) are separate turns
  step: "confirm" | "ground" | "scope" | "decide" | "work";
  provider?: "onDevice" | "claude";   // omitted = deterministic compute (no model)
  confidence?: number;                // provider turns; the escalation trigger
  question?: string;
  options?: string[];
  chosen?: string;
  otherText?: string;
  inReplyTo?: number;                 // user turn → the proposal turn (seq) it answers
  note?: string;
  ts: string;                         // ISO-8601 (matches the app's coders)
}

export interface TaskConvo {
  confirmedIntent?: string;
  acceptance?: string;
  thread: ConvoTurn[];
  subtasks: string[];
  artifact?: { kind: string; title: string; body: string; refs?: string[] };
  handoff?: { instruction: string; actionType: "open_url" | "compose" | "call" | "none"; payload?: string };
  endState?: string;
  endStateNote?: string;
  assignee?: "me" | "local" | "claude";
}

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

function isTerminalConvo(c: TaskConvo): boolean {
  return c.endState !== undefined && c.endState !== "open";
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
        provider: { type: "string", enum: ["onDevice", "claude"] },
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
  const lastProvider = [...convo.thread].reverse().find((t) => t.role === "provider");
  const lowConf = lastProvider?.confidence !== undefined && lastProvider.confidence < 0.5;
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
    convo: {
      confirmedIntent: convo.confirmedIntent,
      acceptance: convo.acceptance,
      assignee: convo.assignee,
      endState: convo.endState,
      turns: convo.thread.length,
      hasArtifact: !!convo.artifact,
      hasHandoff: !!convo.handoff,
      pendingReasoning: !isTerminalConvo(convo) && (convo.assignee === "claude" || lowConf),
    },
  };
}

export async function threadAppend(
  client: CloudKitClient,
  input: { id: string; turn: Omit<ConvoTurn, "seq" | "ts"> & { ts?: string } },
) {
  const convo = await readConvo(client, input.id);
  const turn: ConvoTurn = { ...input.turn, seq: nextSeq(convo), ts: input.turn.ts ?? new Date().toISOString() };
  convo.thread.push(turn);
  // A confirm-step turn carrying a `chosen` also caches confirmedIntent in the
  // SAME write (richer `note` wins over the bare button label). Mirrors the app.
  if (turn.step === "confirm" && turn.chosen) {
    convo.confirmedIntent = turn.note ?? turn.chosen;
  }
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
  convo.artifact = {
    kind: input.artifact.kind ?? "note",
    title: input.artifact.title,
    body: input.artifact.body ?? "",
    refs: input.artifact.refs,
  };
  await writeConvo(client, input.id, convo);
  return { id: input.id, artifact: input.artifact.title };
}

export async function setHandoff(
  client: CloudKitClient,
  input: { id: string; handoff: { instruction: string; actionType?: "open_url" | "compose" | "call" | "none"; payload?: string } },
) {
  const convo = await readConvo(client, input.id);
  convo.handoff = {
    instruction: input.handoff.instruction,
    actionType: input.handoff.actionType ?? "none",
    payload: input.handoff.payload,
  };
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
    if (isTerminalConvo(c)) continue;
    const lastProvider = [...c.thread].reverse().find((t) => t.role === "provider");
    const lowConf = lastProvider?.confidence !== undefined && lastProvider.confidence < 0.5;
    if (c.assignee === "claude" || lowConf) {
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
