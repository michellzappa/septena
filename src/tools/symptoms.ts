import { queryByDateRange, type CloudKitClient } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD, ymdNDaysAgo, nowHHMMSS, localToEpochMs, epochMsToHHMM } from "../tz.js";

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
  records: Array<{ recordName: string; serverErrorCode?: string; reason?: string }>;
}

async function modify(client: CloudKitClient, ops: ModifyOp[]): Promise<CKModifyResponse> {
  return client.post<CKModifyResponse>("records/modify", {
    zoneID: { zoneName: client.zoneName },
    operations: ops,
  });
}

// ---- Definitions ----

interface SymptomDefinition {
  id: string;
  title: string;
  emoji?: string;
  bodySystem?: string;
  defaultBodyRegion?: string;
  archived: boolean;
  sortIndex: number;
}

function definitionFromRecord(r: { recordName: string; fields: Record<string, { value: unknown }> }): SymptomDefinition {
  return {
    id: r.recordName.replace(/^symptom-definition:/, ""),
    title: optStr(r.fields.title?.value) ?? "",
    emoji: optStr(r.fields.emoji?.value),
    bodySystem: optStr(r.fields.bodySystem?.value),
    defaultBodyRegion: optStr(r.fields.defaultBodyRegion?.value),
    archived: (optNum(r.fields.archived?.value) ?? 0) !== 0,
    sortIndex: optNum(r.fields.sortIndex?.value) ?? 0,
  };
}

async function fetchDefinitions(client: CloudKitClient): Promise<SymptomDefinition[]> {
  const res = await client.queryRecords({ recordType: "SymptomDefinition", resultsLimit: 500 });
  return res.records.map(definitionFromRecord).sort((a, b) => a.sortIndex - b.sortIndex);
}

// ---- JSON Schemas ----

export const listSymptomsJsonSchema = {
  type: "object",
  properties: {
    date:  { type: "string", description: "YYYY-MM-DD filter. Omit to return the last 7 days of events." },
    from:  { type: "string", description: "YYYY-MM-DD range start (inclusive). Ignored if date is set." },
    to:    { type: "string", description: "YYYY-MM-DD range end (inclusive). Defaults to today." },
    limit: { type: "integer", minimum: 1, maximum: 500, default: 100 },
  },
} as const;

export const createSymptomJsonSchema = {
  type: "object",
  required: ["title"],
  properties: {
    title:             { type: "string", description: "Symptom name, e.g. 'Headache'." },
    emoji:             { type: "string", description: "Optional glyph." },
    bodySystem:        { type: "string", description: "Optional grouping, e.g. 'digestive', 'neuro'." },
    defaultBodyRegion: { type: "string", description: "Optional default region pre-filled when logging." },
  },
} as const;

export const logSymptomJsonSchema = {
  type: "object",
  required: ["symptomID", "severity"],
  properties: {
    symptomID:       { type: "string",  description: "Definition id from symptoms_list. Must be an active (non-archived) symptom." },
    severity:        { type: "integer", minimum: 0, maximum: 10, description: "Severity 0–10." },
    date:            { type: "string",  description: "YYYY-MM-DD. Defaults to today." },
    time:            { type: "string",  description: "HH:MM or HH:MM:SS. Defaults to now." },
    durationMinutes: { type: "integer", minimum: 0 },
    bodyRegion:      { type: "string" },
    side:            { type: "string",  description: "left/right/both by convention." },
    quality:         { type: "string",  description: "e.g. throbbing, sharp, dull." },
    triggerNote:     { type: "string" },
    reliefNote:      { type: "string" },
    note:            { type: "string" },
  },
} as const;

export const deleteSymptomEventJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", description: "SymptomEvent id." } },
} as const;

// ---- Types ----

export interface ListSymptomsInput { date?: string; from?: string; to?: string; limit?: number }
export interface CreateSymptomInput { title: string; emoji?: string; bodySystem?: string; defaultBodyRegion?: string }
export interface LogSymptomInput {
  symptomID: string;
  severity: number;
  date?: string;
  time?: string;
  durationMinutes?: number;
  bodyRegion?: string;
  side?: string;
  quality?: string;
  triggerNote?: string;
  reliefNote?: string;
  note?: string;
}

// ---- Implementations ----

export async function listSymptoms(client: CloudKitClient, input: ListSymptomsInput) {
  const tz = await getEffectiveTimezone(client);
  const from = input.date ?? input.from ?? ymdNDaysAgo(6, tz);
  const to   = input.date ?? input.to   ?? todayYMD(tz);

  const definitions = await fetchDefinitions(client);
  const titleByID = new Map(definitions.map((d) => [d.id, d.title]));

  const records = await queryByDateRange(client, {
    recordType: "SymptomEvent",
    from,
    to,
    instantField: "occurredAt",
    resultsLimit: input.limit ?? 100,
  });

  const events = records.map((r) => {
    const symptomID = optStr(r.fields.symptomID?.value) ?? "";
    return {
      id:              r.recordName.replace(/^symptom-event:/, ""),
      date:            optStr(r.fields.date?.value) ?? "",
      time:            typeof r.fields.occurredAt?.value === "number" ? epochMsToHHMM(r.fields.occurredAt.value as number, tz) : "",
      symptomID,
      symptom:         titleByID.get(symptomID) ?? "",
      severity:        optNum(r.fields.severity?.value) ?? 0,
      durationMinutes: optNum(r.fields.durationMinutes?.value),
      bodyRegion:      optStr(r.fields.bodyRegion?.value),
      side:            optStr(r.fields.side?.value),
      quality:         optStr(r.fields.quality?.value),
      triggerNote:     optStr(r.fields.triggerNote?.value),
      reliefNote:      optStr(r.fields.reliefNote?.value),
      note:            optStr(r.fields.note?.value),
    };
  });

  return { definitions, events };
}

export async function createSymptom(client: CloudKitClient, input: CreateSymptomInput) {
  const id = newId(8);
  const existing = await fetchDefinitions(client);
  const sortIndex = existing.reduce((m, d) => Math.max(m, d.sortIndex), -1) + 1;

  const fields: Record<string, { value: unknown }> = {
    title:     { value: input.title },
    sortIndex: { value: sortIndex },
    archived:  { value: 0 },
    createdAt: { value: Date.now() },
  };
  if (input.emoji)             fields.emoji             = { value: input.emoji };
  if (input.bodySystem)        fields.bodySystem        = { value: input.bodySystem };
  if (input.defaultBodyRegion) fields.defaultBodyRegion = { value: input.defaultBodyRegion };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "SymptomDefinition",
    recordName: `symptom-definition:${id}`,
    fields,
    protectedFields: ["title"],
  });

  return droppedFields.length > 0 ? { id, title: input.title, droppedFields } : { id, title: input.title };
}

export async function logSymptom(client: CloudKitClient, input: LogSymptomInput) {
  const tz = await getEffectiveTimezone(client);
  const definitions = await fetchDefinitions(client);
  const def = definitions.find((d) => d.id === input.symptomID && !d.archived);
  if (!def) {
    const known = definitions.filter((d) => !d.archived).map((d) => `${d.id} (${d.title})`).join(", ");
    throw new Error(`unknown active symptomID '${input.symptomID}'. Use symptoms_list. Known: ${known}`);
  }

  const id = newId(6);
  const date = input.date ?? todayYMD(tz);
  const time = input.time ?? nowHHMMSS(tz);
  const severity = Math.max(0, Math.min(10, Math.round(input.severity)));

  const fields: Record<string, { value: unknown }> = {
    date:       { value: date },
    symptomID:  { value: input.symptomID },
    severity:   { value: severity },
    occurredAt: { value: localToEpochMs(date, time, tz) },
    source:     { value: "mcp" },
  };
  if (input.durationMinutes !== undefined) fields.durationMinutes = { value: input.durationMinutes };
  if (input.bodyRegion)  fields.bodyRegion  = { value: input.bodyRegion };
  if (input.side)        fields.side        = { value: input.side };
  if (input.quality)     fields.quality     = { value: input.quality };
  if (input.triggerNote) fields.triggerNote = { value: input.triggerNote };
  if (input.reliefNote)  fields.reliefNote  = { value: input.reliefNote };
  if (input.note)        fields.note        = { value: input.note };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "SymptomEvent",
    recordName: `symptom-event:${id}`,
    fields,
    protectedFields: ["date", "symptomID", "severity"],
  });

  const base = { id, date, time, symptomID: input.symptomID, symptom: def.title, severity };
  return droppedFields.length > 0 ? { ...base, droppedFields } : base;
}

export async function deleteSymptomEvent(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `symptom-event:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}
