import { queryByDateRange, type CloudKitClient } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD, defaultLookbackStart, nowHHMMSS, localToEpochMs, epochMsToHHMM } from "../tz.js";

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

export const listGutEventsJsonSchema = {
  type: "object",
  properties: {
    date:  { type: "string", description: "YYYY-MM-DD filter. Omit to return the last 30 days." },
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
    volume:           { type: "string",  enum: ["small", "medium", "large"] },
    note:             { type: "string" },
  },
} as const;

// ---- Types ----

export interface ListGutEventsInput { date?: string; from?: string; to?: string; limit?: number }
export interface LogGutEventInput {
  date?: string;
  time?: string;
  bristol: number;
  volume?: string;
  note?: string;
}

// ---- Implementations ----

export async function listGutEvents(client: CloudKitClient, input: ListGutEventsInput) {
  const tz = await getEffectiveTimezone(client);
  const from = input.date ?? input.from ?? defaultLookbackStart(tz);
  const to   = input.date ?? input.to   ?? todayYMD(tz);

  const records = await queryByDateRange(client, {
    recordType: "GutEvent",
    from,
    to,
    instantField: "occurredAt",
    resultsLimit: input.limit ?? 100,
  });

  const events = records.map((r) => ({
    id:              r.recordName.replace(/^gut-event:/, ""),
    date:            optStr(r.fields.date?.value)  ?? "",
    time:            optStr(r.fields.time?.value)  ?? (typeof r.fields.occurredAt?.value === "number" ? epochMsToHHMM(r.fields.occurredAt.value as number, tz) : ""),
    bristol:         (r.fields.bristol?.value  as number) ?? 0,
    volume:          optStr(r.fields.volume?.value),
    note:            optStr(r.fields.note?.value),
  }));

  return { events };
}

export async function logGutEvent(client: CloudKitClient, input: LogGutEventInput) {
  const tz = await getEffectiveTimezone(client);
  const id = newId(6);
  const date = input.date ?? todayYMD(tz);
  const time = input.time ?? nowHHMMSS(tz);
  const fields: Record<string, { value: unknown }> = {
    date:    { value: date },
    bristol: { value: input.bristol },
    // canonical instant; legacy `time` STRING retired (derive from occurredAt).
    occurredAt: { value: localToEpochMs(date, time, tz) },
  };
  if (input.volume)           fields.volume           = { value: input.volume };
  if (input.note)             fields.note             = { value: input.note };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "GutEvent",
    recordName: `gut-event:${id}`,
    fields,
    protectedFields: ["date", "bristol"],
  });

  return droppedFields.length > 0
    ? { id, date, time, bristol: input.bristol, droppedFields }
    : { id, date, time, bristol: input.bristol };
}
