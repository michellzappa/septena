import type { CloudKitClient } from "../cloudkit.js";

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

function newId(len = 4): string {
  const buf = new Uint8Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => SHORTID_ALPHABET[b & 31]).join("");
}

function todayYMD(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function optStr(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

type ModifyOp =
  | { operationType: "create" | "forceUpdate"; record: { recordType: string; recordName: string; fields: Record<string, { value: unknown }> } }
  | { operationType: "delete"; record: { recordName: string } };

interface CKModifyResponse {
  records: Array<{ recordName: string; fields?: Record<string, { value: unknown }>; serverErrorCode?: string }>;
}

async function modify(client: CloudKitClient, ops: ModifyOp[]): Promise<CKModifyResponse> {
  return client.post<CKModifyResponse>("records/modify", {
    zoneID: { zoneName: client.zoneName },
    operations: ops,
  });
}

// ---- JSON Schemas ----

export const listGoalsJsonSchema = {
  type: "object",
  properties: {},
} as const;

export const createGoalJsonSchema = {
  type: "object",
  required: ["text"],
  properties: {
    text: { type: "string", minLength: 1, description: "The goal text / intention" },
    sections: {
      type: "array",
      items: { type: "string" },
      description: "Section keys to tag this goal with (e.g. ['health', 'envisioning'])",
    },
  },
} as const;

export const updateGoalJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id: { type: "string" },
    text: { type: "string", minLength: 1 },
    sections: {
      type: "array",
      items: { type: "string" },
      description: "Replaces the current section tags entirely",
    },
  },
} as const;

export const deleteGoalJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string" } },
} as const;

// ---- Types ----

export interface CreateGoalInput { text: string; sections?: string[] }
export interface UpdateGoalInput { id: string; text?: string; sections?: string[] }

// ---- Implementations ----

export async function listGoals(client: CloudKitClient) {
  const res = await client.queryRecords({
    recordType: "Goal",
    sortBy: [
      { fieldName: "sortIndex", ascending: false },
    ],
    resultsLimit: 200,
  });

  const goals = res.records.map((r) => ({
    id: r.recordName.replace(/^goal:/, ""),
    text: optStr(r.fields.text?.value) ?? "",
    sections: (r.fields.sections?.value as string[] | undefined) ?? [],
    created: optStr(r.fields.created?.value),
    sortIndex: (r.fields.sortIndex?.value as number) ?? 0,
  }));

  return { goals };
}

export async function createGoal(client: CloudKitClient, input: CreateGoalInput) {
  const id = newId(4);
  const fields: Record<string, { value: unknown }> = {
    text: { value: input.text },
    sections: { value: input.sections ?? [] },
    created: { value: todayYMD() },
    sortIndex: { value: 0 },
  };
  await modify(client, [{
    operationType: "create",
    record: { recordType: "Goal", recordName: `goal:${id}`, fields },
  }]);
  return { id, text: input.text, sections: input.sections ?? [] };
}

export async function updateGoal(client: CloudKitClient, input: UpdateGoalInput) {
  const fields: Record<string, { value: unknown }> = {};
  const updated: string[] = [];
  if (input.text !== undefined) { fields.text = { value: input.text }; updated.push("text"); }
  if (input.sections !== undefined) { fields.sections = { value: input.sections }; updated.push("sections"); }
  if (!updated.length) return { id: input.id, updated: [] };
  await modify(client, [{
    operationType: "forceUpdate",
    record: { recordType: "Goal", recordName: `goal:${input.id}`, fields },
  }]);
  return { id: input.id, updated };
}

export async function deleteGoal(client: CloudKitClient, input: { id: string }) {
  await modify(client, [{ operationType: "delete", record: { recordName: `goal:${input.id}` } }]);
  return { id: input.id, deleted: true };
}
