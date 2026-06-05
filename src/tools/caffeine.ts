import { queryByDateRange, type CloudKitClient } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD, ymdNDaysAgo, nowHHMMSS, localToEpochMs } from "../tz.js";

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";
function newId(len = 4): string {
  const buf = new Uint8Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => SHORTID_ALPHABET[b & 31]).join("");
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

export const listCaffeineEventsJsonSchema = {
  type: "object",
  properties: {
    date: { type: "string", description: "YYYY-MM-DD filter. Omit to return the last 7 days." },
    from: { type: "string", description: "YYYY-MM-DD range start (inclusive). Ignored if date is set." },
    to:   { type: "string", description: "YYYY-MM-DD range end (inclusive). Defaults to today." },
    limit: { type: "integer", minimum: 1, maximum: 500, default: 100 },
  },
} as const;

export const logCaffeineEventJsonSchema = {
  type: "object",
  required: ["method"],
  properties: {
    date:   { type: "string", description: "YYYY-MM-DD. Defaults to today." },
    time:   { type: "string", description: "HH:MM or HH:MM:SS. Defaults to now." },
    method: { type: "string", enum: ["v60", "matcha", "other"], description: "Brew / intake method." },
    beans:  { type: "string", description: "CaffeineBean id (from caffeine_beans_list)." },
    grams:  { type: "number", description: "Dose in grams." },
    note:   { type: "string" },
  },
} as const;

export const deleteCaffeineEventJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", description: "CaffeineEvent id." } },
} as const;

export const listCaffeineBeansJsonSchema = {
  type: "object",
  properties: {},
} as const;

export const createCaffeineBeanJsonSchema = {
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string", minLength: 1 },
  },
} as const;

export const deleteCaffeineBeanJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", description: "CaffeineBean id." } },
} as const;

// ---- Types ----

export interface ListCaffeineEventsInput { date?: string; from?: string; to?: string; limit?: number }
export interface LogCaffeineEventInput { date?: string; time?: string; method: string; beans?: string; grams?: number; note?: string }
export interface CreateCaffeineBeanInput { name: string }

// ---- Implementations ----

export async function listCaffeineEvents(client: CloudKitClient, input: ListCaffeineEventsInput) {
  const tz = await getEffectiveTimezone(client);
  const from = input.date ?? input.from ?? ymdNDaysAgo(6, tz);
  const to   = input.date ?? input.to   ?? todayYMD(tz);

  const records = await queryByDateRange(client, {
    recordType: "CaffeineEvent",
    from,
    to,
    timeField: "time",
    resultsLimit: input.limit ?? 100,
  });

  const events = records.map((r) => ({
    id: r.recordName.replace(/^caffeine-event:/, ""),
    date:   optStr(r.fields.date?.value)   ?? "",
    time:   optStr(r.fields.time?.value)   ?? "",
    method: optStr(r.fields.method?.value) ?? "",
    beans:  optStr(r.fields.beans?.value),
    grams:  typeof r.fields.grams?.value === "number" ? r.fields.grams.value : undefined,
    note:   optStr(r.fields.note?.value),
  }));

  return { events };
}

export async function logCaffeineEvent(client: CloudKitClient, input: LogCaffeineEventInput) {
  const tz = await getEffectiveTimezone(client);
  const id = newId(6);
  const date = input.date ?? todayYMD(tz);
  const time = input.time ?? nowHHMMSS(tz);
  const fields: Record<string, { value: unknown }> = {
    date:   { value: date },
    time:   { value: time },
    method: { value: input.method },
    occurredAt: { value: localToEpochMs(date, time, tz) },
  };
  if (input.beans)              fields.beans = { value: input.beans };
  if (input.grams !== undefined) fields.grams = { value: input.grams };
  if (input.note)               fields.note  = { value: input.note };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "CaffeineEvent",
    recordName: `caffeine-event:${id}`,
    fields,
    protectedFields: ["date", "time", "method"],
  });

  return droppedFields.length > 0
    ? { id, date, time, method: input.method, droppedFields }
    : { id, date, time, method: input.method };
}

export async function deleteCaffeineEvent(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `caffeine-event:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}

export async function listCaffeineBeans(client: CloudKitClient) {
  const res = await client.queryRecords({
    recordType: "CaffeineBean",
    sortBy: [{ fieldName: "sortIndex", ascending: true }],
    resultsLimit: 100,
  });
  const beans = res.records.map((r) => ({
    id:   r.recordName.replace(/^caffeine-bean:/, ""),
    name: optStr(r.fields.name?.value) ?? "",
    sortIndex: (r.fields.sortIndex?.value as number) ?? 0,
  }));
  return { beans };
}

export async function createCaffeineBean(client: CloudKitClient, input: CreateCaffeineBeanInput) {
  const id = newId(4);
  const res = await modify(client, [{
    operationType: "create",
    record: {
      recordType: "CaffeineBean",
      recordName: `caffeine-bean:${id}`,
      fields: { name: { value: input.name }, sortIndex: { value: 0 } },
    },
  }]);
  const code = res.records[0]?.serverErrorCode;
  if (code) throw new Error(res.records[0]?.reason ?? code);
  return { id, name: input.name };
}

export async function deleteCaffeineBean(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `caffeine-bean:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}
