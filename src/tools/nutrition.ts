import type { CloudKitClient } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD, defaultLookbackStart, addDaysYMD, localToEpochMs } from "../tz.js";

function newUUID(): string {
  return crypto.randomUUID();
}

function startOfDayEpochMs(ymd: string, tz: string): number {
  // Start of the user-local day `ymd` (in `tz`) as a UTC epoch instant. The
  // Swift side uses user-local dates for NutritionDaySum.date; we match that.
  return localToEpochMs(ymd, "00:00", tz);
}

function endOfDayEpochMs(ymd: string, tz: string): number {
  // Inclusive end = 1ms before the start of the next local day.
  return localToEpochMs(addDaysYMD(ymd, 1), "00:00", tz) - 1;
}

function optStr(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}
function optNum(v: unknown): number | undefined {
  return typeof v === "number" ? v : undefined;
}

type ModifyOp =
  | { operationType: "create" | "forceUpdate" | "update"; record: { recordType: string; recordName: string; fields: Record<string, { value: unknown }> } }
  | { operationType: "delete"; record: { recordName: string } };

interface CKModifyResponse {
  records: Array<{ recordName: string; serverErrorCode?: string; reason?: string; fields?: Record<string, { value: unknown }> }>;
}

async function modify(client: CloudKitClient, ops: ModifyOp[]): Promise<CKModifyResponse> {
  return client.post<CKModifyResponse>("records/modify", {
    zoneID: { zoneName: client.zoneName },
    operations: ops,
  });
}

interface CKLookupResponse {
  records: Array<{ recordName: string; fields?: Record<string, { value: unknown }>; serverErrorCode?: string }>;
}

// ---- JSON Schemas ----

export const listNutritionEntriesJsonSchema = {
  type: "object",
  properties: {
    date:  { type: "string", description: "YYYY-MM-DD filter — returns all meals on this day. Omit to use from/to or default to last 30 days." },
    from:  { type: "string", description: "YYYY-MM-DD range start (inclusive). Ignored if date is set." },
    to:    { type: "string", description: "YYYY-MM-DD range end (inclusive). Defaults to today." },
    limit: { type: "integer", minimum: 1, maximum: 500, default: 200 },
  },
} as const;

export const logNutritionEntryJsonSchema = {
  type: "object",
  required: ["foods"],
  properties: {
    loggedAt:      { type: "string", description: "ISO8601 timestamp of the meal. Defaults to now." },
    foods:         { type: "string", description: "Newline-separated list of foods/items consumed." },
    emoji:         { type: "string", description: "Optional meal emoji." },
    note:          { type: "string" },
    mealType:      { type: "string", enum: ["breakfast", "lunch", "dinner", "snack"] },
    proteinG:      { type: "number", description: "Protein in grams." },
    fatG:          { type: "number", description: "Fat in grams." },
    carbsG:        { type: "number", description: "Carbohydrates in grams." },
    fiberG:        { type: "number" },
    sugarG:        { type: "number" },
    saturatedFatG: { type: "number" },
    alcoholG:      { type: "number" },
    kcal:          { type: "number", description: "Optional override; otherwise computed from 4P+9F+4C+7A." },
    sodiumMg:      { type: "number" },
    cholesterolMg: { type: "number" },
    potassiumMg:   { type: "number" },
    waterMl:       { type: "number" },
  },
} as const;

export const updateNutritionEntryJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id:            { type: "string" },
    loggedAt:      { type: "string", description: "ISO8601 timestamp." },
    foods:         { type: "string" },
    emoji:         { type: ["string", "null"] },
    note:          { type: ["string", "null"] },
    mealType:      { type: ["string", "null"], enum: ["breakfast", "lunch", "dinner", "snack", null] },
    proteinG:      { type: "number" },
    fatG:          { type: "number" },
    carbsG:        { type: "number" },
    fiberG:        { type: ["number", "null"] },
    sugarG:        { type: ["number", "null"] },
    saturatedFatG: { type: ["number", "null"] },
    alcoholG:      { type: ["number", "null"] },
    kcal:          { type: ["number", "null"] },
    sodiumMg:      { type: ["number", "null"] },
    cholesterolMg: { type: ["number", "null"] },
    potassiumMg:   { type: ["number", "null"] },
    waterMl:       { type: ["number", "null"] },
  },
} as const;

export const getNutritionDaySummaryJsonSchema = {
  type: "object",
  properties: {
    date: { type: "string", description: "YYYY-MM-DD. Defaults to today." },
  },
} as const;

// ---- Types ----

export interface ListNutritionEntriesInput { date?: string; from?: string; to?: string; limit?: number }
export interface LogNutritionEntryInput {
  loggedAt?: string;
  foods: string;
  emoji?: string;
  note?: string;
  mealType?: string;
  proteinG?: number; fatG?: number; carbsG?: number;
  fiberG?: number; sugarG?: number; saturatedFatG?: number; alcoholG?: number;
  kcal?: number; sodiumMg?: number; cholesterolMg?: number; potassiumMg?: number; waterMl?: number;
}
export interface UpdateNutritionEntryInput extends Partial<LogNutritionEntryInput> { id: string }
export interface GetNutritionDaySummaryInput { date?: string }

// ---- Implementations ----

export async function listNutritionEntries(client: CloudKitClient, input: ListNutritionEntriesInput) {
  const tz = await getEffectiveTimezone(client);
  const from = input.date ?? input.from ?? defaultLookbackStart(tz);
  const to   = input.date ?? input.to   ?? todayYMD(tz);

  // loggedAt is a Date/TIMESTAMP field — filter on epoch milliseconds.
  const res = await client.queryRecords({
    recordType: "NutritionEntry",
    filterBy: [
      { fieldName: "loggedAt", comparator: "GREATER_THAN_OR_EQUALS", fieldValue: { value: startOfDayEpochMs(from, tz) } },
      { fieldName: "loggedAt", comparator: "LESS_THAN_OR_EQUALS",    fieldValue: { value: endOfDayEpochMs(to, tz) } },
    ],
    sortBy: [{ fieldName: "loggedAt", ascending: false }],
    resultsLimit: input.limit ?? 200,
  });

  const entries = res.records.map((r) => {
    const loggedAtRaw = r.fields.loggedAt?.value;
    const loggedAtIso = typeof loggedAtRaw === "number" ? new Date(loggedAtRaw).toISOString() : undefined;
    return {
      id:            r.recordName.replace(/^nutrition-entry:/, ""),
      loggedAt:      loggedAtIso,
      foods:         optStr(r.fields.foods?.value) ?? "",
      emoji:         optStr(r.fields.emoji?.value),
      note:          optStr(r.fields.note?.value),
      mealType:      optStr(r.fields.mealType?.value),
      source:        optStr(r.fields.source?.value),
      proteinG:      optNum(r.fields.proteinG?.value) ?? 0,
      fatG:          optNum(r.fields.fatG?.value) ?? 0,
      carbsG:        optNum(r.fields.carbsG?.value) ?? 0,
      fiberG:        optNum(r.fields.fiberG?.value),
      sugarG:        optNum(r.fields.sugarG?.value),
      saturatedFatG: optNum(r.fields.saturatedFatG?.value),
      alcoholG:      optNum(r.fields.alcoholG?.value),
      kcal:          optNum(r.fields.kcal?.value),
      sodiumMg:      optNum(r.fields.sodiumMg?.value),
      cholesterolMg: optNum(r.fields.cholesterolMg?.value),
      potassiumMg:   optNum(r.fields.potassiumMg?.value),
      waterMl:       optNum(r.fields.waterMl?.value),
    };
  });

  return { from, to, entries };
}

export async function logNutritionEntry(client: CloudKitClient, input: LogNutritionEntryInput) {
  const id = newUUID();
  const loggedAt = input.loggedAt ? new Date(input.loggedAt).getTime() : Date.now();

  // Full intended field set. CloudKit may not yet know about some of
  // these for new accounts; createWithFieldFallback drops unrecognised
  // ones one-by-one and reports them back. Required fields go into
  // `protectedFields` so we hard-fail rather than silently dropping them.
  const fields: Record<string, { value: unknown }> = {
    loggedAt: { value: loggedAt },
    foods:    { value: input.foods },
    source:   { value: "mcp" },
    proteinG: { value: input.proteinG ?? 0 },
    fatG:     { value: input.fatG     ?? 0 },
    carbsG:   { value: input.carbsG   ?? 0 },
  };
  if (input.emoji)              fields.emoji         = { value: input.emoji };
  if (input.note)               fields.note          = { value: input.note };
  if (input.mealType)           fields.mealType      = { value: input.mealType };
  if (input.fiberG !== undefined)        fields.fiberG        = { value: input.fiberG };
  if (input.sugarG !== undefined)        fields.sugarG        = { value: input.sugarG };
  if (input.saturatedFatG !== undefined) fields.saturatedFatG = { value: input.saturatedFatG };
  if (input.alcoholG !== undefined)      fields.alcoholG      = { value: input.alcoholG };
  if (input.kcal !== undefined)          fields.kcal          = { value: input.kcal };
  if (input.sodiumMg !== undefined)      fields.sodiumMg      = { value: input.sodiumMg };
  if (input.cholesterolMg !== undefined) fields.cholesterolMg = { value: input.cholesterolMg };
  if (input.potassiumMg !== undefined)   fields.potassiumMg   = { value: input.potassiumMg };
  if (input.waterMl !== undefined)       fields.waterMl       = { value: input.waterMl };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "NutritionEntry",
    recordName: `nutrition-entry:${id}`,
    fields,
    protectedFields: ["loggedAt", "foods", "proteinG", "fatG", "carbsG"],
  });

  // Surface dropped fields when present so the model can mention to the
  // user "I logged your meal but couldn't save X yet — once you've used
  // X in the app once, future logs will save it."
  return droppedFields.length > 0
    ? { id, loggedAt: new Date(loggedAt).toISOString(), droppedFields }
    : { id, loggedAt: new Date(loggedAt).toISOString() };
}

export async function updateNutritionEntry(client: CloudKitClient, input: UpdateNutritionEntryInput) {
  const fields: Record<string, { value: unknown }> = {};
  const updated: string[] = [];

  const setNum = (key: keyof UpdateNutritionEntryInput, fieldName: string) => {
    if (input[key] !== undefined) { fields[fieldName] = { value: input[key] ?? 0 }; updated.push(fieldName); }
  };
  const setStr = (key: keyof UpdateNutritionEntryInput, fieldName: string) => {
    if (input[key] !== undefined) { fields[fieldName] = { value: input[key] ?? "" }; updated.push(fieldName); }
  };

  if (input.loggedAt !== undefined) {
    fields.loggedAt = { value: new Date(input.loggedAt).getTime() };
    updated.push("loggedAt");
  }
  setStr("foods", "foods");
  setStr("emoji", "emoji");
  setStr("note", "note");
  setStr("mealType", "mealType");
  setNum("proteinG", "proteinG"); setNum("fatG", "fatG"); setNum("carbsG", "carbsG");
  setNum("fiberG", "fiberG"); setNum("sugarG", "sugarG"); setNum("saturatedFatG", "saturatedFatG");
  setNum("alcoholG", "alcoholG"); setNum("kcal", "kcal");
  setNum("sodiumMg", "sodiumMg"); setNum("cholesterolMg", "cholesterolMg");
  setNum("potassiumMg", "potassiumMg"); setNum("waterMl", "waterMl");

  if (!updated.length) return { id: input.id, updated: [] };

  const res = await modify(client, [{
    operationType: "forceUpdate",
    record: { recordType: "NutritionEntry", recordName: `nutrition-entry:${input.id}`, fields },
  }]);
  const code = res.records[0]?.serverErrorCode;
  if (code) throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id, updated };
}

export async function getNutritionDaySummary(client: CloudKitClient, input: GetNutritionDaySummaryInput) {
  const tz = await getEffectiveTimezone(client);
  const date = input.date ?? todayYMD(tz);
  const res = await client.post<CKLookupResponse>("records/lookup", {
    zoneID: { zoneName: client.zoneName },
    records: [{ recordName: `nutrition-day:${date}` }],
  });
  const record = res.records[0];
  if (!record || record.serverErrorCode === "NOT_FOUND") {
    return { date, summary: null };
  }
  const f = record.fields ?? {};
  const firstLoggedAtRaw = f.firstLoggedAt?.value;
  const lastLoggedAtRaw  = f.lastLoggedAt?.value;
  return {
    date,
    summary: {
      date:          optStr(f.date?.value) ?? date,
      entryCount:    optNum(f.entryCount?.value) ?? 0,
      firstLoggedAt: typeof firstLoggedAtRaw === "number" ? new Date(firstLoggedAtRaw).toISOString() : undefined,
      lastLoggedAt:  typeof lastLoggedAtRaw  === "number" ? new Date(lastLoggedAtRaw).toISOString()  : undefined,
      kcal:          optNum(f.kcal?.value),
      proteinG:      optNum(f.proteinG?.value),
      fatG:          optNum(f.fatG?.value),
      carbsG:        optNum(f.carbsG?.value),
      fiberG:        optNum(f.fiberG?.value),
      sugarG:        optNum(f.sugarG?.value),
      saturatedFatG: optNum(f.saturatedFatG?.value),
      alcoholG:      optNum(f.alcoholG?.value),
      sodiumMg:      optNum(f.sodiumMg?.value),
      cholesterolMg: optNum(f.cholesterolMg?.value),
      potassiumMg:   optNum(f.potassiumMg?.value),
      waterMl:       optNum(f.waterMl?.value),
    },
  };
}
