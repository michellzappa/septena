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

export const listCannabisEventsJsonSchema = {
  type: "object",
  properties: {
    date:  { type: "string", description: "YYYY-MM-DD filter. Omit to return the last 7 days." },
    from:  { type: "string", description: "YYYY-MM-DD range start (inclusive). Ignored if date is set." },
    to:    { type: "string", description: "YYYY-MM-DD range end (inclusive). Defaults to today." },
    limit: { type: "integer", minimum: 1, maximum: 500, default: 100 },
  },
} as const;

export const logCannabisEventJsonSchema = {
  type: "object",
  required: ["method"],
  properties: {
    date:   { type: "string", description: "YYYY-MM-DD. Defaults to today." },
    time:   { type: "string", description: "HH:MM or HH:MM:SS. Defaults to now." },
    method: { type: "string", enum: ["vape", "edible"], description: "Intake method." },
    strain: { type: "string", description: "CannabisStrain id (from cannabis_strains_list)." },
    hit:    { type: "integer", description: "Number of hits / dose count." },
    grams:  { type: "number",  description: "Dose in grams (for edibles)." },
    effect: { type: "string",  description: "Subjective effect descriptor." },
    note:   { type: "string" },
  },
} as const;

export const deleteCannabisEventJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", description: "CannabisEvent id." } },
} as const;

export const listCannabisStrainJsonSchema = {
  type: "object",
  properties: {},
} as const;

export const createCannabisStrainJsonSchema = {
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string", minLength: 1 },
  },
} as const;

export const deleteCannabisStrainJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", description: "CannabisStrain id." } },
} as const;

// ---- Types ----

export interface ListCannabisEventsInput { date?: string; from?: string; to?: string; limit?: number }
export interface LogCannabisEventInput { date?: string; time?: string; method: string; strain?: string; hit?: number; grams?: number; effect?: string; note?: string }
export interface CreateCannabisStrainInput { name: string }

// ---- Implementations ----

export async function listCannabisEvents(client: CloudKitClient, input: ListCannabisEventsInput) {
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
    recordType: "CannabisEvent",
    filterBy: filters,
    sortBy: [{ fieldName: "date", ascending: false }, { fieldName: "time", ascending: false }],
    resultsLimit: input.limit ?? 100,
  });

  const events = res.records.map((r) => ({
    id:     r.recordName.replace(/^cannabis-event:/, ""),
    date:   optStr(r.fields.date?.value)   ?? "",
    time:   optStr(r.fields.time?.value)   ?? "",
    method: optStr(r.fields.method?.value) ?? "",
    strain: optStr(r.fields.strain?.value),
    hit:    typeof r.fields.hit?.value   === "number" ? r.fields.hit.value   : undefined,
    grams:  typeof r.fields.grams?.value === "number" ? r.fields.grams.value : undefined,
    effect: optStr(r.fields.effect?.value),
    note:   optStr(r.fields.note?.value),
  }));

  return { events };
}

export async function logCannabisEvent(client: CloudKitClient, input: LogCannabisEventInput) {
  const id = newId(6);
  const date = input.date ?? todayYMD();
  const time = input.time ?? currentHHMMSS();
  const fields: Record<string, { value: unknown }> = {
    date:   { value: date },
    time:   { value: time },
    method: { value: input.method },
  };
  if (input.strain)             fields.strain = { value: input.strain };
  if (input.hit   !== undefined) fields.hit   = { value: input.hit };
  if (input.grams !== undefined) fields.grams = { value: input.grams };
  if (input.effect)             fields.effect = { value: input.effect };
  if (input.note)               fields.note   = { value: input.note };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "CannabisEvent",
    recordName: `cannabis-event:${id}`,
    fields,
    protectedFields: ["date", "time", "method"],
  });

  return droppedFields.length > 0
    ? { id, date, time, method: input.method, droppedFields }
    : { id, date, time, method: input.method };
}

export async function deleteCannabisEvent(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `cannabis-event:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}

export async function listCannabisStrains(client: CloudKitClient) {
  const res = await client.queryRecords({
    recordType: "CannabisStrain",
    sortBy: [{ fieldName: "sortIndex", ascending: true }],
    resultsLimit: 100,
  });
  const strains = res.records.map((r) => ({
    id:   r.recordName.replace(/^cannabis-strain:/, ""),
    name: optStr(r.fields.name?.value) ?? "",
    sortIndex: (r.fields.sortIndex?.value as number) ?? 0,
  }));
  return { strains };
}

export async function createCannabisStrain(client: CloudKitClient, input: CreateCannabisStrainInput) {
  const id = newId(4);
  const res = await modify(client, [{
    operationType: "create",
    record: {
      recordType: "CannabisStrain",
      recordName: `cannabis-strain:${id}`,
      fields: { name: { value: input.name }, sortIndex: { value: 0 } },
    },
  }]);
  const code = res.records[0]?.serverErrorCode;
  if (code) throw new Error(res.records[0]?.reason ?? code);
  return { id, name: input.name };
}

export async function deleteCannabisStrain(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `cannabis-strain:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}
