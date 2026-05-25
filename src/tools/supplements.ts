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

function currentHHMM(): string {
  const d = new Date();
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
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

export const listSupplementsJsonSchema = {
  type: "object",
  properties: {
    date: { type: "string", description: "YYYY-MM-DD. Defaults to today." },
  },
} as const;

export const createSupplementJsonSchema = {
  type: "object",
  required: ["title"],
  properties: {
    title: { type: "string", minLength: 1 },
    emoji: { type: "string" },
  },
} as const;

export const updateSupplementJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id: { type: "string" },
    title: { type: "string" },
    emoji: { type: ["string", "null"] },
  },
} as const;

export const deleteSupplementJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string" } },
} as const;

export const toggleSupplementJsonSchema = {
  type: "object",
  required: ["id", "done"],
  properties: {
    id: { type: "string" },
    date: { type: "string", description: "YYYY-MM-DD. Defaults to today." },
    done: { type: "boolean" },
  },
} as const;

// ---- Types ----

export interface ListSupplementsInput { date?: string }
export interface CreateSupplementInput { title: string; emoji?: string }
export interface UpdateSupplementInput { id: string; title?: string; emoji?: string | null }
export interface ToggleSupplementInput { id: string; date?: string; done: boolean }

// ---- Implementations ----

export async function listSupplements(client: CloudKitClient, input: ListSupplementsInput) {
  const date = input.date ?? todayYMD();
  const [defsRes, eventsRes] = await Promise.all([
    client.queryRecords({
      recordType: "SupplementDefinition",
      sortBy: [{ fieldName: "sortIndex", ascending: true }],
      resultsLimit: 200,
    }),
    client.queryRecords({
      recordType: "SupplementEvent",
      filterBy: [{ fieldName: "date", comparator: "EQUALS", fieldValue: { value: date } }],
      resultsLimit: 200,
    }),
  ]);

  const byID = new Map<string, { done: boolean; note?: string; time?: string }>();
  for (const r of eventsRes.records) {
    const sid = optStr(r.fields.supplementID?.value);
    if (sid) {
      byID.set(sid, {
        done: ((r.fields.done?.value as number) ?? 0) !== 0,
        note: optStr(r.fields.note?.value),
        time: optStr(r.fields.time?.value),
      });
    }
  }

  const supplements = defsRes.records.map((r) => {
    const id = r.recordName.slice("supplement-def:".length);
    const ev = byID.get(id);
    return {
      id,
      title: optStr(r.fields.title?.value) ?? "",
      emoji: optStr(r.fields.emoji?.value),
      sortIndex: (r.fields.sortIndex?.value as number) ?? 0,
      done: ev?.done ?? false,
      note: ev?.note,
      time: ev?.time,
    };
  });

  return { date, supplements };
}

export async function createSupplement(client: CloudKitClient, input: CreateSupplementInput) {
  const id = newId(4);
  const fields: Record<string, { value: unknown }> = {
    title: { value: input.title },
    sortIndex: { value: 0 },
  };
  if (input.emoji) fields.emoji = { value: input.emoji };
  await modify(client, [{
    operationType: "create",
    record: { recordType: "SupplementDefinition", recordName: `supplement-def:${id}`, fields },
  }]);
  return { id, title: input.title };
}

export async function updateSupplement(client: CloudKitClient, input: UpdateSupplementInput) {
  const fields: Record<string, { value: unknown }> = {};
  const updated: string[] = [];
  if (input.title !== undefined) { fields.title = { value: input.title }; updated.push("title"); }
  if (input.emoji !== undefined) { fields.emoji = { value: input.emoji ?? "" }; updated.push("emoji"); }
  if (!updated.length) return { id: input.id, updated: [] };
  await modify(client, [{
    operationType: "forceUpdate",
    record: { recordType: "SupplementDefinition", recordName: `supplement-def:${input.id}`, fields },
  }]);
  return { id: input.id, updated };
}

export async function deleteSupplement(client: CloudKitClient, input: { id: string }) {
  const eventsRes = await client.queryRecords({
    recordType: "SupplementEvent",
    filterBy: [{ fieldName: "supplementID", comparator: "EQUALS", fieldValue: { value: input.id } }],
    resultsLimit: 500,
  });
  const ops: ModifyOp[] = [
    ...eventsRes.records.map((r) => ({ operationType: "delete" as const, record: { recordName: r.recordName } })),
    { operationType: "delete", record: { recordName: `supplement-def:${input.id}` } },
  ];
  await modify(client, ops);
  return { id: input.id, deletedEvents: eventsRes.records.length };
}

export async function toggleSupplement(client: CloudKitClient, input: ToggleSupplementInput) {
  const date = input.date ?? todayYMD();
  const stateID = `supplement:${date}:${input.id}`;
  const recordName = `supplement-event:${stateID}`;

  if (!input.done) {
    const res = await modify(client, [{ operationType: "delete", record: { recordName } }]);
    if (res.records[0]?.serverErrorCode && res.records[0].serverErrorCode !== "NOT_FOUND") {
      throw new Error(`Failed to delete supplement event: ${res.records[0].serverErrorCode}`);
    }
    return { id: input.id, date, done: false };
  }

  const fields: Record<string, { value: unknown }> = {
    date: { value: date },
    supplementID: { value: input.id },
    done: { value: 1 },
    time: { value: currentHHMM() },
  };

  const createRes = await modify(client, [{
    operationType: "create",
    record: { recordType: "SupplementEvent", recordName, fields },
  }]);
  const code = createRes.records[0]?.serverErrorCode;
  if (code === "CONFLICT" || code === "EXISTS" || code === "UNIQUE_FIELD_ERROR") {
    await modify(client, [{
      operationType: "forceUpdate",
      record: { recordType: "SupplementEvent", recordName, fields },
    }]);
  } else if (code) {
    throw new Error(`Failed to toggle supplement: ${code}`);
  }

  return { id: input.id, date, done: true };
}
