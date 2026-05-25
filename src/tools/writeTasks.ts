import type { CloudKitClient } from "../cloudkit.js";

// Mutators for Task records. Uses CKWS records/modify with forceUpdate.
// Identity for new tasks: base32-6 shortid per identifiers.md.

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

export function newTaskId(): string {
  const buf = new Uint8Array(6);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => SHORTID_ALPHABET[b & 31]).join("");
}

function todayYMD(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
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
    due: { type: "string", description: "YYYY-MM-DD" },
    area: { type: "string", description: "Area id (e.g. 'envisioning')" },
    project: { type: "string", description: "Project id (e.g. 'septena')" },
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
    due: { type: ["string", "null"], description: "YYYY-MM-DD, or null to clear" },
    area: { type: ["string", "null"] },
    project: { type: ["string", "null"] },
    status: { type: "string", enum: ["open", "cancelled"] },
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
  due?: string;
  area?: string;
  project?: string;
}

export interface UpdateTaskInput {
  id: string;
  title?: string;
  today?: boolean;
  scheduled?: string | null;
  due?: string | null;
  area?: string | null;
  project?: string | null;
  status?: "open" | "cancelled";
}

// ---- Implementations ----

export async function createTask(client: CloudKitClient, input: CreateTaskInput) {
  const id = newTaskId();
  const fields: Record<string, { value: unknown }> = {
    title: { value: input.title },
    status: { value: "open" },
    created: { value: todayYMD() },
    today: { value: input.today ? 1 : 0 },
  };
  if (input.today) fields.todaySetOn = { value: todayYMD() };
  if (input.scheduled) fields.scheduled = { value: input.scheduled };
  if (input.due) fields.deadline = { value: input.due };
  if (input.area) fields.area = { value: input.area };
  if (input.project) fields.project = { value: input.project };

  await modifyRecords(client, [
    { operationType: "create", record: { recordType: "Task", recordName: id, fields } },
  ]);
  return { id, title: input.title };
}

export async function completeTask(client: CloudKitClient, input: { id: string }) {
  const fields = await lookupRecord(client, input.id);
  if (!fields) throw new Error(`Task not found: ${input.id}`);
  const recurrenceUnit = fields.recurrenceUnit?.value as string | undefined;
  if (recurrenceUnit && recurrenceUnit.length > 0) {
    throw new Error(
      `Task ${input.id} is recurring (every ${recurrenceUnit}). Complete it in the Septena app so the next occurrence spawns.`,
    );
  }
  const completedAt = new Date().toISOString();
  await modifyRecords(client, [
    {
      operationType: "forceUpdate",
      record: {
        recordType: "Task",
        recordName: input.id,
        fields: {
          status: { value: "done" },
          completedAt: { value: completedAt },
          today: { value: 0 },
          todaySetOn: { value: "" },
        },
      },
    },
  ]);
  return { id: input.id, status: "done", completedAt };
}

export async function updateTask(client: CloudKitClient, input: UpdateTaskInput) {
  const fields: Record<string, { value: unknown }> = {};
  const updated: string[] = [];
  if (input.title !== undefined) { fields.title = { value: input.title }; updated.push("title"); }
  if (input.today !== undefined) {
    fields.today = { value: input.today ? 1 : 0 };
    fields.todaySetOn = { value: input.today ? todayYMD() : "" };
    updated.push("today");
  }
  if (input.scheduled !== undefined) { fields.scheduled = { value: input.scheduled ?? "" }; updated.push("scheduled"); }
  if (input.due !== undefined) { fields.deadline = { value: input.due ?? "" }; updated.push("deadline"); }
  if (input.area !== undefined) {
    fields.area = { value: input.area ?? "" };
    if (input.area) fields.project = { value: "" };
    updated.push("area");
  }
  if (input.project !== undefined) {
    fields.project = { value: input.project ?? "" };
    if (input.project) fields.area = { value: "" };
    updated.push("project");
  }
  if (input.status !== undefined) { fields.status = { value: input.status }; updated.push("status"); }

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
