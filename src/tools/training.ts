import { queryByDateRange, type CloudKitClient } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD, ymdNDaysAgo, nowHHMM, localToEpochMs, epochMsToHHMM } from "../tz.js";

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";
function newId(len = 6): string {
  const buf = new Uint8Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => SHORTID_ALPHABET[b & 31]).join("");
}

function slugify(s: string): string {
  return s.toLowerCase().trim()
    .replace(/[^\w\s-]/g, "")
    .replace(/[\s_]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "")
    || newId(6);
}

function optStr(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}
function optNum(v: unknown): number | undefined {
  return typeof v === "number" ? v : undefined;
}
function optStrArray(v: unknown): string[] {
  if (Array.isArray(v)) return v.filter((x): x is string => typeof x === "string");
  return [];
}

// The 16 canonical muscle groups — must stay in lockstep with the iOS
// `Muscle` enum (SeptenaCore/Models.swift). camelCase exactly; 'quads', not
// 'quadriceps'. See docs/MUSCLE_TAXONOMY_16.md in the app repo.
export const VALID_MUSCLES = [
  "chest", "frontDelts", "sideDelts", "rearDelts", "triceps",
  "lats", "upperBack", "biceps", "forearms",
  "quads", "hamstrings", "glutes", "calves", "adductors",
  "abs", "lowerBack",
] as const;
const MUSCLE_SET = new Set<string>(VALID_MUSCLES);

/** Throw on any muscle value that isn't one of the 10 canonical groups. */
function assertMuscle(value: string): string {
  if (!MUSCLE_SET.has(value)) {
    throw new Error(`invalid muscle '${value}'. Valid: ${VALID_MUSCLES.join(", ")}`);
  }
  return value;
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

async function lookupExerciseEntry(
  client: CloudKitClient,
  id: string,
): Promise<Record<string, { value: unknown }> | null> {
  const res = await client.post<{ records: Array<{ recordName: string; fields?: Record<string, { value: unknown }>; serverErrorCode?: string }> }>(
    "records/lookup",
    { zoneID: { zoneName: client.zoneName }, records: [{ recordName: `exercise-entry:${id}` }] },
  );
  const r = res.records[0];
  if (!r || r.serverErrorCode === "NOT_FOUND") return null;
  return r.fields ?? {};
}

// ============================================================================
// Schemas
// ============================================================================

// ---- ExerciseEntry (event log) ----

export const listTrainingEntriesJsonSchema = {
  type: "object",
  properties: {
    date:  { type: "string", description: "YYYY-MM-DD single-day filter." },
    from:  { type: "string", description: "YYYY-MM-DD range start (inclusive). Ignored if date is set." },
    to:    { type: "string", description: "YYYY-MM-DD range end (inclusive). Defaults to today." },
    exercise: { type: "string", description: "Filter to a specific canonical exercise name." },
    limit: { type: "integer", minimum: 1, maximum: 500, default: 200 },
  },
} as const;

export const logTrainingEntryJsonSchema = {
  type: "object",
  required: ["sessionType", "exercise"],
  properties: {
    date:        { type: "string", description: "YYYY-MM-DD. Defaults to today." },
    time:        { type: "string", description: "HH:MM session start. Defaults to now." },
    sessionType: { type: "string", description: "SessionType id (e.g. 'upper', 'lower', 'cardio')." },
    exercise:    { type: "string", description: "Canonical exercise NAME (not id) — e.g. 'Chest press'. List via training_exercises_list." },
    weight:      { type: "number", description: "Weight in kg (for strength)." },
    sets:        { type: "string", description: "Integer or 'AMRAP'." },
    reps:        { type: "string", description: "Integer or free-form (e.g. '8,8,6' for varying)." },
    difficulty:  { type: "string", description: "Subjective difficulty (e.g. 'easy', 'hard', 'failure')." },
    durationMin: { type: "number", description: "Duration in minutes (for cardio/mobility)." },
    distanceM:   { type: "number", description: "Distance in meters (for cardio)." },
    level:       { type: "number", description: "Machine resistance / incline level." },
    note:        { type: "string" },
    concludedAt: { type: "string", description: "ISO8601 timestamp when the set/session finished." },
  },
} as const;

export const updateTrainingEntryJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id:          { type: "string" },
    date:        { type: "string" },
    time:        { type: "string" },
    sessionType: { type: "string" },
    exercise:    { type: "string" },
    weight:      { type: ["number", "null"] },
    sets:        { type: ["string", "null"] },
    reps:        { type: ["string", "null"] },
    difficulty:  { type: ["string", "null"] },
    durationMin: { type: ["number", "null"] },
    distanceM:   { type: ["number", "null"] },
    level:       { type: ["number", "null"] },
    note:        { type: ["string", "null"] },
    concludedAt: { type: ["string", "null"] },
  },
} as const;

// ---- ExerciseDefinition (catalog) ----

export const listExercisesJsonSchema = {
  type: "object",
  properties: {
    type:     { type: "string", enum: ["strength", "cardio", "mobility", "core"], description: "Filter by exercise type." },
    archived: { type: "boolean", description: "Include archived. Defaults to false." },
    limit:    { type: "integer", default: 200 },
  },
} as const;

export const createExerciseJsonSchema = {
  type: "object",
  required: ["name", "type"],
  properties: {
    name:             { type: "string", description: "Canonical display name (e.g. 'Chest press')." },
    type:             { type: "string", enum: ["strength", "cardio", "mobility", "core"] },
    id:               { type: "string", description: "Optional slug id. Defaults to slugified name." },
    subgroup:         { type: "string", description: "Free-form grouping (e.g. 'push', 'pull')." },
    aliases:          { type: "array", items: { type: "string" } },
    primaryMuscle:    { type: "string", enum: VALID_MUSCLES, description: "Primary muscle group (one of the 16 canonical values)." },
    secondaryMuscles: { type: "array", items: { type: "string", enum: VALID_MUSCLES } },
  },
} as const;

export const updateExerciseJsonSchema = {
  type: "object", required: ["id"],
  properties: {
    id:               { type: "string" },
    name:             { type: "string" },
    type:             { type: "string", enum: ["strength", "cardio", "mobility", "core"] },
    subgroup:         { type: ["string", "null"] },
    aliases:          { type: "array", items: { type: "string" } },
    primaryMuscle:    { type: ["string", "null"], description: "Primary muscle group (one of the 16 canonical values). Pass \"\" or null to clear." },
    secondaryMuscles: { type: "array", items: { type: "string", enum: VALID_MUSCLES } },
    archived:         { type: "boolean" },
  },
} as const;

// ============================================================================
// Types
// ============================================================================

export interface ListTrainingEntriesInput { date?: string; from?: string; to?: string; exercise?: string; limit?: number }
export interface LogTrainingEntryInput {
  date?: string; time?: string;
  sessionType: string; exercise: string;
  weight?: number; sets?: string; reps?: string; difficulty?: string;
  durationMin?: number; distanceM?: number; level?: number;
  note?: string; concludedAt?: string;
}
export interface UpdateTrainingEntryInput extends Partial<LogTrainingEntryInput> { id: string }
export interface ListExercisesInput { type?: string; archived?: boolean; limit?: number }
export interface CreateExerciseInput {
  name: string; type: string; id?: string; subgroup?: string;
  aliases?: string[]; primaryMuscle?: string; secondaryMuscles?: string[];
}
export interface UpdateExerciseInput {
  id: string; name?: string; type?: string; subgroup?: string | null;
  aliases?: string[]; primaryMuscle?: string | null; secondaryMuscles?: string[]; archived?: boolean;
}

// ============================================================================
// ExerciseEntry implementations
// ============================================================================

export async function listTrainingEntries(client: CloudKitClient, input: ListTrainingEntriesInput) {
  const tz = await getEffectiveTimezone(client);
  const from = input.date ?? input.from ?? ymdNDaysAgo(13, tz);
  const to   = input.date ?? input.to   ?? todayYMD(tz);

  // `exercise` is an unindexed STRING — pushing EQUALS server-side risks a
  // CloudKit 400 (same failure mode as the date range). Fetch the date window,
  // then filter by exercise client-side and slice to `limit`.
  const limit = input.limit ?? 200;
  const windowRecords = await queryByDateRange(client, {
    recordType: "ExerciseEntry",
    from,
    to,
    instantField: "occurredAt",
    resultsLimit: input.exercise ? 5000 : limit,
  });
  const wanted = input.exercise?.toLowerCase();
  const records = (wanted
    ? windowRecords.filter((r) => optStr(r.fields.exercise?.value)?.toLowerCase() === wanted)
    : windowRecords
  ).slice(0, limit);

  const entries = records.map((r) => ({
    id:          r.recordName.replace(/^exercise-entry:/, ""),
    date:        optStr(r.fields.date?.value) ?? "",
    time:        optStr(r.fields.time?.value) ?? (typeof r.fields.occurredAt?.value === "number" ? epochMsToHHMM(r.fields.occurredAt.value as number, tz) : ""),
    sessionType: optStr(r.fields.sessionType?.value) ?? "",
    exercise:    optStr(r.fields.exercise?.value) ?? "",
    weight:      optNum(r.fields.weight?.value),
    sets:        optStr(r.fields.sets?.value),
    reps:        optStr(r.fields.reps?.value),
    difficulty:  optStr(r.fields.difficulty?.value),
    durationMin: optNum(r.fields.durationMin?.value),
    distanceM:   optNum(r.fields.distanceM?.value),
    level:       optNum(r.fields.level?.value),
    note:        optStr(r.fields.note?.value),
    concludedAt: optStr(r.fields.concludedAt?.value),
    loggedAt:    optStr(r.fields.loggedAt?.value),
  }));

  return { from, to, entries };
}

export async function logTrainingEntry(client: CloudKitClient, input: LogTrainingEntryInput) {
  const tz = await getEffectiveTimezone(client);
  const id = newId(6);
  const date = input.date ?? todayYMD(tz);
  const time = input.time ?? nowHHMM(tz);
  const fields: Record<string, { value: unknown }> = {
    date:        { value: date },
    sessionType: { value: input.sessionType },
    exercise:    { value: input.exercise },
    loggedAt:    { value: new Date().toISOString() },
    // canonical instant; legacy `time` STRING retired (derive from occurredAt).
    occurredAt:  { value: localToEpochMs(date, time, tz) },
  };
  if (input.weight      !== undefined) fields.weight      = { value: input.weight };
  if (input.sets        !== undefined) fields.sets        = { value: input.sets };
  if (input.reps        !== undefined) fields.reps        = { value: input.reps };
  if (input.difficulty)               fields.difficulty   = { value: input.difficulty };
  if (input.durationMin !== undefined) fields.durationMin = { value: input.durationMin };
  if (input.distanceM   !== undefined) fields.distanceM   = { value: input.distanceM };
  if (input.level       !== undefined) fields.level       = { value: input.level };
  if (input.note)                     fields.note         = { value: input.note };
  if (input.concludedAt)              fields.concludedAt  = { value: input.concludedAt };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "ExerciseEntry",
    recordName: `exercise-entry:${id}`,
    fields,
    protectedFields: ["date", "sessionType", "exercise"],
  });

  return droppedFields.length > 0
    ? { id, date, time, sessionType: input.sessionType, exercise: input.exercise, droppedFields }
    : { id, date, time, sessionType: input.sessionType, exercise: input.exercise };
}

export async function updateTrainingEntry(client: CloudKitClient, input: UpdateTrainingEntryInput) {
  const fields: Record<string, { value: unknown }> = {};
  const updated: string[] = [];

  const setOpt = <K extends keyof UpdateTrainingEntryInput>(key: K, field: string) => {
    const v = input[key];
    if (v !== undefined) {
      // null clears (CloudKit treats "" / 0 the same on optional fields)
      fields[field] = { value: v ?? "" };
      updated.push(field);
    }
  };

  // `date` (calendar-day key) is still stored; `time` STRING is retired —
  // a time/date change recomputes the canonical `occurredAt` instead, filling
  // the missing half from the existing record.
  if (input.date || input.time) {
    const tz = await getEffectiveTimezone(client);
    let d = input.date;
    let t = input.time;
    if (!d || !t) {
      const existing = await lookupExerciseEntry(client, input.id);
      if (!d) d = optStr(existing?.date?.value) ?? todayYMD(tz);
      if (!t) {
        t = optStr(existing?.time?.value)
          ?? (typeof existing?.occurredAt?.value === "number" ? epochMsToHHMM(existing.occurredAt.value as number, tz) : undefined);
      }
    }
    if (input.date) { fields.date = { value: input.date }; updated.push("date"); }
    fields.occurredAt = { value: localToEpochMs(d!, t, tz) };
    updated.push("occurredAt");
  }
  // sessionType: treat empty string as an explicit clear, not "field not provided".
  if (input.sessionType !== undefined) { fields.sessionType = { value: input.sessionType }; updated.push("sessionType"); }
  if (input.exercise)    { fields.exercise    = { value: input.exercise };    updated.push("exercise"); }
  setOpt("weight", "weight");
  setOpt("sets", "sets");
  setOpt("reps", "reps");
  setOpt("difficulty", "difficulty");
  setOpt("durationMin", "durationMin");
  setOpt("distanceM", "distanceM");
  setOpt("level", "level");
  setOpt("note", "note");
  setOpt("concludedAt", "concludedAt");

  if (!updated.length) return { id: input.id, updated: [] };

  const res = await modify(client, [{
    operationType: "forceUpdate",
    record: { recordType: "ExerciseEntry", recordName: `exercise-entry:${input.id}`, fields },
  }]);
  const code = res.records[0]?.serverErrorCode;
  if (code) throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id, updated };
}

// ============================================================================
// ExerciseDefinition implementations
// ============================================================================

export async function listExercises(client: CloudKitClient, input: ListExercisesInput) {
  const filters: Array<{ fieldName: string; comparator: string; fieldValue: { value: unknown } }> = [];
  if (input.type) {
    filters.push({ fieldName: "type", comparator: "EQUALS", fieldValue: { value: input.type } });
  }
  if (input.archived === undefined || input.archived === false) {
    filters.push({ fieldName: "archived", comparator: "EQUALS", fieldValue: { value: 0 } });
  }

  const res = await client.queryRecords({
    recordType: "ExerciseDefinition",
    filterBy: filters.length ? (filters as never) : undefined,
    sortBy: [{ fieldName: "sortIndex", ascending: true }],
    resultsLimit: input.limit ?? 200,
  });

  const exercises = res.records.map((r) => ({
    id:               r.recordName.replace(/^exercise-def:/, ""),
    name:             optStr(r.fields.name?.value) ?? "",
    type:             optStr(r.fields.type?.value) ?? "",
    subgroup:         optStr(r.fields.subgroup?.value),
    aliases:          optStrArray(r.fields.aliases?.value),
    primaryMuscle:    optStr(r.fields.primaryMuscle?.value),
    secondaryMuscles: optStrArray(r.fields.secondaryMuscles?.value),
    archived:         ((r.fields.archived?.value as number) ?? 0) !== 0,
    sortIndex:        (r.fields.sortIndex?.value as number) ?? 0,
  }));

  return { exercises };
}

export async function createExercise(client: CloudKitClient, input: CreateExerciseInput) {
  if (input.primaryMuscle) assertMuscle(input.primaryMuscle);
  (input.secondaryMuscles ?? []).forEach(assertMuscle);
  const id = input.id ?? slugify(input.name);
  const fields: Record<string, { value: unknown }> = {
    name:      { value: input.name },
    type:      { value: input.type },
    archived:  { value: 0 },
    sortIndex: { value: 0 },
    aliases:   { value: input.aliases ?? [] },
    secondaryMuscles: { value: input.secondaryMuscles ?? [] },
  };
  if (input.subgroup)      fields.subgroup      = { value: input.subgroup };
  if (input.primaryMuscle) fields.primaryMuscle = { value: input.primaryMuscle };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "ExerciseDefinition",
    recordName: `exercise-def:${id}`,
    fields,
    protectedFields: ["name", "type"],
  });

  return droppedFields.length > 0
    ? { id, name: input.name, type: input.type, droppedFields }
    : { id, name: input.name, type: input.type };
}

export async function updateExercise(client: CloudKitClient, input: UpdateExerciseInput) {
  // Validate muscles up front so a typo can't dirty the catalog. "" / null is
  // allowed for primaryMuscle (clears it).
  if (input.primaryMuscle) assertMuscle(input.primaryMuscle);
  (input.secondaryMuscles ?? []).forEach(assertMuscle);
  const fields: Record<string, { value: unknown }> = {};
  const updated: string[] = [];
  if (input.name !== undefined)             { fields.name = { value: input.name }; updated.push("name"); }
  if (input.type !== undefined)             { fields.type = { value: input.type }; updated.push("type"); }
  if (input.subgroup !== undefined)         { fields.subgroup = { value: input.subgroup ?? "" }; updated.push("subgroup"); }
  if (input.aliases !== undefined)          { fields.aliases = { value: input.aliases }; updated.push("aliases"); }
  if (input.primaryMuscle !== undefined)    { fields.primaryMuscle = { value: input.primaryMuscle ?? "" }; updated.push("primaryMuscle"); }
  if (input.secondaryMuscles !== undefined) { fields.secondaryMuscles = { value: input.secondaryMuscles }; updated.push("secondaryMuscles"); }
  if (input.archived !== undefined)         { fields.archived = { value: input.archived ? 1 : 0 }; updated.push("archived"); }

  if (!updated.length) return { id: input.id, updated: [] };

  const res = await modify(client, [{
    operationType: "forceUpdate",
    record: { recordType: "ExerciseDefinition", recordName: `exercise-def:${input.id}`, fields },
  }]);
  const code = res.records[0]?.serverErrorCode;
  if (code) throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id, updated };
}
