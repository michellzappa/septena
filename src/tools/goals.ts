import type { CloudKitClient } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD } from "../tz.js";

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

function newId(len = 4): string {
  const buf = new Uint8Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => SHORTID_ALPHABET[b & 31]).join("");
}

function optStr(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

function optNum(v: unknown): number | undefined {
  return typeof v === "number" ? v : undefined;
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

  const goals = res.records.map((r) => {
    const g: Record<string, unknown> = {
      id: r.recordName.replace(/^goal:/, ""),
      text: optStr(r.fields.text?.value) ?? "",
      sections: (r.fields.sections?.value as string[] | undefined) ?? [],
      created: optStr(r.fields.created?.value),
      sortIndex: (r.fields.sortIndex?.value as number) ?? 0,
    };
    // Measurement attachment (quant goals) — kept in lockstep with the in-app
    // server's goals_list so an agent sees targets, ranges and progress, not
    // just the title. Omitted on free-text goals; metricTargetUpper present ⇒
    // a "between" range band [metricTarget, metricTargetUpper].
    const metricKey = optStr(r.fields.metricKey?.value);
    if (metricKey) {
      g.metricKey = metricKey;
      const w = optStr(r.fields.metricWindow?.value); if (w) g.metricWindow = w;
      const c = optStr(r.fields.metricComparator?.value); if (c) g.metricComparator = c;
      const t = optNum(r.fields.metricTarget?.value); if (t !== undefined) g.metricTarget = t;
      const u = optNum(r.fields.metricTargetUpper?.value); if (u !== undefined) g.metricTargetUpper = u;
      const b = optNum(r.fields.metricBaseline?.value); if (b !== undefined) g.metricBaseline = b;
    }
    return g;
  });

  return { goals };
}

export async function createGoal(client: CloudKitClient, input: CreateGoalInput) {
  const tz = await getEffectiveTimezone(client);
  const id = newId(4);
  const fields: Record<string, { value: unknown }> = {
    text: { value: input.text },
    sections: { value: input.sections ?? [] },
    created: { value: todayYMD(tz) },
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
