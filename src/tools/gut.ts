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

function currentHHMMSS(): string {
  return new Date().toTimeString().slice(0, 8);
}

function optStr(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

type ModifyOp =
  | { operationType: "create" | "forceUpdate"; record: { recordType: string; recordName: string; fields: Record<string, { value: unknown }> } }
  | { operationType: "delete"; record: { recordName: string } };

interface CKModifyResponse {
  records: Array<{ recordName: string; serverErrorCode?: string; reason?: string }>;
}

async function modify(client: CloudKitClient, ops: ModifyOp[]): Promise<CKModifyResponse> {
  return client.post<CKModifyResponse>("records/modify", {
    zoneID: { zoneName: client.zoneName },
    operations: ops,
  });
}

// ---- JSON Schemas ----

export const listGutEventsJsonSchema = {
  type: "object",
  properties: {
    date:  { type: "string", description: "YYYY-MM-DD filter. Omit to return the last 7 days." },
    from:  { type: "string", description: "YYYY-MM-DD range start (inclusive). Ignored if date is set." },
    to:    { type: "string", description: "YYYY-MM-DD range end (inclusive). Defaults to today." },
    limit: { type: "integer", minimum: 1, maximum: 500, default: 100 },
  },
} as const;

export const logGutEventJsonSchema = {
  type: "object",
  required: ["bristol"],
  properties: {
    date:             { type: "string",  description: "YYYY-MM-DD. Defaults to today." },
    time:             { type: "string",  description: "HH:MM or HH:MM:SS. Defaults to now." },
    bristol:          { type: "integer", minimum: 1, maximum: 7, description: "Bristol Stool Scale type (1–7)." },
    blood:            { type: "boolean", description: "Blood present." },
    volume:           { type: "string",  enum: ["small", "medium", "large"] },
    discomfortLevel:  { type: "string",  description: "Subjective discomfort descriptor." },
    discomfortStart:  { type: "string",  description: "HH:MM when discomfort began." },
    discomfortEnd:    { type: "string",  description: "HH:MM when discomfort ended." },
    note:             { type: "string" },
  },
} as const;

export const deleteGutEventJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", description: "GutEvent id." } },
} as const;

// ---- Types ----

export interface ListGutEventsInput { date?: string; from?: string; to?: string; limit?: number }
export interface LogGutEventInput {
  date?: string;
  time?: string;
  bristol: number;
  blood?: boolean;
  volume?: string;
  discomfortLevel?: string;
  discomfortStart?: string;
  discomfortEnd?: string;
  note?: string;
}

// ---- Implementations ----

export async function listGutEvents(client: CloudKitClient, input: ListGutEventsInput) {
  const filters = [];
  if (input.date) {
    filters.push({ fieldName: "date", comparator: "EQUALS" as const, fieldValue: { value: input.date } });
  } else {
    const to   = input.to   ?? todayYMD();
    const from = input.from ?? (() => { const d = new Date(); d.setDate(d.getDate() - 6); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; })();
    filters.push({ fieldName: "date", comparator: "GREATER_THAN_OR_EQUALS" as const, fieldValue: { value: from } });
    filters.push({ fieldName: "date", comparator: "LESS_THAN_OR_EQUALS" as const, fieldValue: { value: to } });
  }

  const res = await client.queryRecords({
    recordType: "GutEvent",
    filterBy: filters,
    sortBy: [{ fieldName: "date", ascending: false }, { fieldName: "time", ascending: false }],
    resultsLimit: input.limit ?? 100,
  });

  const events = res.records.map((r) => ({
    id:              r.recordName.replace(/^gut-event:/, ""),
    date:            optStr(r.fields.date?.value)  ?? "",
    time:            optStr(r.fields.time?.value)  ?? "",
    bristol:         (r.fields.bristol?.value  as number) ?? 0,
    blood:           ((r.fields.blood?.value   as number) ?? 0) !== 0,
    volume:          optStr(r.fields.volume?.value),
    discomfortLevel: optStr(r.fields.discomfortLevel?.value),
    discomfortStart: optStr(r.fields.discomfortStart?.value),
    discomfortEnd:   optStr(r.fields.discomfortEnd?.value),
    note:            optStr(r.fields.note?.value),
  }));

  return { events };
}

export async function logGutEvent(client: CloudKitClient, input: LogGutEventInput) {
  const id = newId(6);
  const date = input.date ?? todayYMD();
  const time = input.time ?? currentHHMMSS();
  const fields: Record<string, { value: unknown }> = {
    date:    { value: date },
    time:    { value: time },
    bristol: { value: input.bristol },
    blood:   { value: input.blood ? 1 : 0 },
  };
  if (input.volume)           fields.volume           = { value: input.volume };
  if (input.discomfortLevel)  fields.discomfortLevel  = { value: input.discomfortLevel };
  if (input.discomfortStart)  fields.discomfortStart  = { value: input.discomfortStart };
  if (input.discomfortEnd)    fields.discomfortEnd    = { value: input.discomfortEnd };
  if (input.note)             fields.note             = { value: input.note };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "GutEvent",
    recordName: `gut-event:${id}`,
    fields,
    protectedFields: ["date", "time", "bristol"],
  });

  return droppedFields.length > 0
    ? { id, date, time, bristol: input.bristol, droppedFields }
    : { id, date, time, bristol: input.bristol };
}

export async function deleteGutEvent(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `gut-event:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}
