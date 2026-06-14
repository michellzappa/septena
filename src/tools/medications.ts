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

const VALID_STATUSES = ["taken", "skipped", "missed"] as const;

// ---- Definitions ----

interface MedicationDefinition {
  id: string;
  title: string;
  genericName?: string;
  form?: string;
  route?: string;
  strengthValue?: number;
  strengthUnit?: string;
  defaultDoseValue?: number;
  defaultDoseUnit?: string;
  bucket?: string;
  scheduleKind: string;
  targetDosesPerDay: number;
  instructions?: string;
  archived: boolean;
  sortIndex: number;
}

function definitionFromRecord(r: { recordName: string; fields: Record<string, { value: unknown }> }): MedicationDefinition {
  return {
    id: r.recordName.replace(/^medication-definition:/, ""),
    title: optStr(r.fields.title?.value) ?? "",
    genericName: optStr(r.fields.genericName?.value),
    form: optStr(r.fields.form?.value),
    route: optStr(r.fields.route?.value),
    strengthValue: optNum(r.fields.strengthValue?.value),
    strengthUnit: optStr(r.fields.strengthUnit?.value),
    defaultDoseValue: optNum(r.fields.defaultDoseValue?.value),
    defaultDoseUnit: optStr(r.fields.defaultDoseUnit?.value),
    bucket: optStr(r.fields.bucket?.value),
    scheduleKind: optStr(r.fields.scheduleKind?.value) ?? "daily",
    targetDosesPerDay: optNum(r.fields.targetDosesPerDay?.value) ?? 1,
    instructions: optStr(r.fields.instructions?.value),
    archived: (optNum(r.fields.archived?.value) ?? 0) !== 0,
    sortIndex: optNum(r.fields.sortIndex?.value) ?? 0,
  };
}

async function fetchDefinitions(client: CloudKitClient): Promise<MedicationDefinition[]> {
  const res = await client.queryRecords({ recordType: "MedicationDefinition", resultsLimit: 500 });
  return res.records.map(definitionFromRecord).sort((a, b) => a.sortIndex - b.sortIndex);
}

// ---- JSON Schemas ----

export const listMedicationsJsonSchema = {
  type: "object",
  properties: {
    date:  { type: "string", description: "YYYY-MM-DD filter. Omit to return the last 7 days of doses." },
    from:  { type: "string", description: "YYYY-MM-DD range start (inclusive). Ignored if date is set." },
    to:    { type: "string", description: "YYYY-MM-DD range end (inclusive). Defaults to today." },
    limit: { type: "integer", minimum: 1, maximum: 500, default: 100 },
  },
} as const;

export const createMedicationJsonSchema = {
  type: "object",
  required: ["title"],
  properties: {
    title:             { type: "string",  description: "Medication name, e.g. 'Ibuprofen'." },
    genericName:       { type: "string" },
    form:              { type: "string",  description: "tablet/capsule/liquid/etc." },
    route:             { type: "string",  description: "oral/topical/etc." },
    strengthValue:     { type: "number" },
    strengthUnit:      { type: "string",  description: "e.g. mg, ml." },
    defaultDoseValue:  { type: "number" },
    defaultDoseUnit:   { type: "string" },
    bucket:            { type: "string",  description: "morning/afternoon/evening/anytime." },
    scheduleKind:      { type: "string",  enum: ["daily", "asNeeded"], description: "Defaults to daily." },
    targetDosesPerDay: { type: "integer", minimum: 0, description: "Defaults to 1 for daily meds." },
    instructions:      { type: "string" },
  },
} as const;

export const logMedicationJsonSchema = {
  type: "object",
  required: ["medicationID", "status"],
  properties: {
    medicationID:   { type: "string", description: "Definition id from medications_list. Must be an active (non-archived) medication." },
    status:         { type: "string", enum: ["taken", "skipped", "missed"] },
    date:           { type: "string", description: "YYYY-MM-DD. Defaults to today." },
    time:           { type: "string", description: "HH:MM or HH:MM:SS. Defaults to now." },
    doseValue:      { type: "number" },
    doseUnit:       { type: "string" },
    reason:         { type: "string" },
    effectNote:     { type: "string" },
    sideEffectNote: { type: "string" },
  },
} as const;

export const deleteMedicationDoseJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", description: "MedicationDoseEvent id." } },
} as const;

// ---- Types ----

export interface ListMedicationsInput { date?: string; from?: string; to?: string; limit?: number }
export interface CreateMedicationInput {
  title: string;
  genericName?: string;
  form?: string;
  route?: string;
  strengthValue?: number;
  strengthUnit?: string;
  defaultDoseValue?: number;
  defaultDoseUnit?: string;
  bucket?: string;
  scheduleKind?: string;
  targetDosesPerDay?: number;
  instructions?: string;
}
export interface LogMedicationInput {
  medicationID: string;
  status: string;
  date?: string;
  time?: string;
  doseValue?: number;
  doseUnit?: string;
  reason?: string;
  effectNote?: string;
  sideEffectNote?: string;
}

// ---- Implementations ----

export async function listMedications(client: CloudKitClient, input: ListMedicationsInput) {
  const tz = await getEffectiveTimezone(client);
  const from = input.date ?? input.from ?? ymdNDaysAgo(6, tz);
  const to   = input.date ?? input.to   ?? todayYMD(tz);

  const definitions = await fetchDefinitions(client);
  const titleByID = new Map(definitions.map((d) => [d.id, d.title]));

  const records = await queryByDateRange(client, {
    recordType: "MedicationDoseEvent",
    from,
    to,
    instantField: "occurredAt",
    resultsLimit: input.limit ?? 100,
  });

  const doses = records.map((r) => {
    const medicationID = optStr(r.fields.medicationID?.value) ?? "";
    return {
      id:             r.recordName.replace(/^medication-dose-event:/, ""),
      date:           optStr(r.fields.date?.value) ?? "",
      time:           typeof r.fields.occurredAt?.value === "number" ? epochMsToHHMM(r.fields.occurredAt.value as number, tz) : "",
      medicationID,
      medication:     titleByID.get(medicationID) ?? "",
      status:         optStr(r.fields.status?.value) ?? "",
      doseValue:      optNum(r.fields.doseValue?.value),
      doseUnit:       optStr(r.fields.doseUnit?.value),
      reason:         optStr(r.fields.reason?.value),
      effectNote:     optStr(r.fields.effectNote?.value),
      sideEffectNote: optStr(r.fields.sideEffectNote?.value),
    };
  });

  return { definitions, doses };
}

export async function createMedication(client: CloudKitClient, input: CreateMedicationInput) {
  const id = newId(8);
  const existing = await fetchDefinitions(client);
  const sortIndex = existing.reduce((m, d) => Math.max(m, d.sortIndex), -1) + 1;

  const fields: Record<string, { value: unknown }> = {
    title:             { value: input.title },
    scheduleKind:      { value: input.scheduleKind ?? "daily" },
    targetDosesPerDay: { value: input.targetDosesPerDay ?? 1 },
    sortIndex:         { value: sortIndex },
    archived:          { value: 0 },
    createdAt:         { value: Date.now() },
  };
  if (input.genericName)             fields.genericName      = { value: input.genericName };
  if (input.form)                    fields.form             = { value: input.form };
  if (input.route)                   fields.route            = { value: input.route };
  if (input.strengthValue !== undefined)    fields.strengthValue    = { value: input.strengthValue };
  if (input.strengthUnit)            fields.strengthUnit     = { value: input.strengthUnit };
  if (input.defaultDoseValue !== undefined) fields.defaultDoseValue = { value: input.defaultDoseValue };
  if (input.defaultDoseUnit)         fields.defaultDoseUnit  = { value: input.defaultDoseUnit };
  if (input.bucket)                  fields.bucket           = { value: input.bucket };
  if (input.instructions)            fields.instructions     = { value: input.instructions };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "MedicationDefinition",
    recordName: `medication-definition:${id}`,
    fields,
    protectedFields: ["title"],
  });

  return droppedFields.length > 0 ? { id, title: input.title, droppedFields } : { id, title: input.title };
}

export async function logMedication(client: CloudKitClient, input: LogMedicationInput) {
  const tz = await getEffectiveTimezone(client);
  if (!(VALID_STATUSES as readonly string[]).includes(input.status)) {
    throw new Error(`status must be ${VALID_STATUSES.join("|")}`);
  }
  const definitions = await fetchDefinitions(client);
  const def = definitions.find((d) => d.id === input.medicationID && !d.archived);
  if (!def) {
    const known = definitions.filter((d) => !d.archived).map((d) => `${d.id} (${d.title})`).join(", ");
    throw new Error(`unknown active medicationID '${input.medicationID}'. Use medications_list. Known: ${known}`);
  }

  const id = newId(6);
  const date = input.date ?? todayYMD(tz);
  const time = input.time ?? nowHHMMSS(tz);

  const fields: Record<string, { value: unknown }> = {
    date:         { value: date },
    medicationID: { value: input.medicationID },
    status:       { value: input.status },
    occurredAt:   { value: localToEpochMs(date, time, tz) },
    source:       { value: "mcp" },
  };
  if (input.doseValue !== undefined) fields.doseValue = { value: input.doseValue };
  if (input.doseUnit)                fields.doseUnit       = { value: input.doseUnit };
  if (input.reason)                  fields.reason         = { value: input.reason };
  if (input.effectNote)              fields.effectNote     = { value: input.effectNote };
  if (input.sideEffectNote)          fields.sideEffectNote = { value: input.sideEffectNote };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "MedicationDoseEvent",
    recordName: `medication-dose-event:${id}`,
    fields,
    protectedFields: ["date", "medicationID", "status"],
  });

  const base = { id, date, time, medicationID: input.medicationID, medication: def.title, status: input.status };
  return droppedFields.length > 0 ? { ...base, droppedFields } : base;
}

export async function deleteMedicationDose(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `medication-dose-event:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}
