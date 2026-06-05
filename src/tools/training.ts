import { queryByDateRange, type CloudKitClient } from "../cloudkit.js";

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

function todayYMD(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function ymdNDaysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function currentHHMM(): string {
  const d = new Date();
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
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
    sessionType: { type: "string", description: "SessionType id (e.g. 'upper', 'lower', 'cardio'). List via training_sessions_list." },
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

export const deleteTrainingEntryJsonSchema = {
  type: "object", required: ["id"],
  properties: { id: { type: "string", description: "ExerciseEntry id." } },
} as const;

export const retagTrainingSessionJsonSchema = {
  type: "object",
  required: ["date", "sessionType"],
  properties: {
    date:        { type: "string", description: "YYYY-MM-DD — every ExerciseEntry on this date will be retagged." },
    sessionType: { type: "string", description: "New sessionType for all entries that day ('upper' | 'lower' | 'cardio' | 'yoga' | …). Pass '' to clear." },
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
    primaryMuscle:    { type: "string", description: "Muscle enum value, e.g. 'chest', 'quadriceps'." },
    secondaryMuscles: { type: "array", items: { type: "string" } },
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
    primaryMuscle:    { type: ["string", "null"] },
    secondaryMuscles: { type: "array", items: { type: "string" } },
    archived:         { type: "boolean" },
  },
} as const;

export const deleteExerciseJsonSchema = {
  type: "object", required: ["id"],
  properties: { id: { type: "string", description: "ExerciseDefinition id (slug)." } },
} as const;

// ---- SessionType (routine template) ----

export const listSessionTypesJsonSchema = {
  type: "object",
  properties: {
    archived: { type: "boolean", description: "Include archived. Defaults to false." },
    limit:    { type: "integer", default: 100 },
  },
} as const;

export const createSessionTypeJsonSchema = {
  type: "object",
  required: ["id", "label"],
  properties: {
    id:        { type: "string", description: "Canonical key (e.g. 'upper', 'lower', 'cardio'). Lower-snake-case." },
    label:    { type: "string", description: "Display label (e.g. 'Upper Body')." },
    emoji:    { type: "string" },
    exercises: { type: "array", items: { type: "string" }, description: "Canonical exercise names that belong to this session." },
    kind:     { type: "string", description: "SessionKind enum value (free-form for now)." },
  },
} as const;

export const updateSessionTypeJsonSchema = {
  type: "object", required: ["id"],
  properties: {
    id:        { type: "string" },
    label:    { type: "string" },
    emoji:    { type: ["string", "null"] },
    exercises: { type: "array", items: { type: "string" } },
    kind:     { type: ["string", "null"] },
    archived: { type: "boolean" },
  },
} as const;

export const deleteSessionTypeJsonSchema = {
  type: "object", required: ["id"],
  properties: { id: { type: "string", description: "SessionType id." } },
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
export interface RetagTrainingSessionInput { date: string; sessionType: string }
export interface ListExercisesInput { type?: string; archived?: boolean; limit?: number }
export interface CreateExerciseInput {
  name: string; type: string; id?: string; subgroup?: string;
  aliases?: string[]; primaryMuscle?: string; secondaryMuscles?: string[];
}
export interface UpdateExerciseInput {
  id: string; name?: string; type?: string; subgroup?: string | null;
  aliases?: string[]; primaryMuscle?: string | null; secondaryMuscles?: string[]; archived?: boolean;
}
export interface ListSessionTypesInput { archived?: boolean; limit?: number }
export interface CreateSessionTypeInput {
  id: string; label: string; emoji?: string; exercises?: string[]; kind?: string;
}
export interface UpdateSessionTypeInput {
  id: string; label?: string; emoji?: string | null;
  exercises?: string[]; kind?: string | null; archived?: boolean;
}

// ============================================================================
// ExerciseEntry implementations
// ============================================================================

export async function listTrainingEntries(client: CloudKitClient, input: ListTrainingEntriesInput) {
  const from = input.date ?? input.from ?? ymdNDaysAgo(13);
  const to   = input.date ?? input.to   ?? todayYMD();

  // `exercise` is an unindexed STRING — pushing EQUALS server-side risks a
  // CloudKit 400 (same failure mode as the date range). Fetch the date window,
  // then filter by exercise client-side and slice to `limit`.
  const limit = input.limit ?? 200;
  const windowRecords = await queryByDateRange(client, {
    recordType: "ExerciseEntry",
    from,
    to,
    timeField: "time",
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
    time:        optStr(r.fields.time?.value) ?? "",
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
  const id = newId(6);
  const date = input.date ?? todayYMD();
  const time = input.time ?? currentHHMM();
  const fields: Record<string, { value: unknown }> = {
    date:        { value: date },
    time:        { value: time },
    sessionType: { value: input.sessionType },
    exercise:    { value: input.exercise },
    loggedAt:    { value: new Date().toISOString() },
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
    protectedFields: ["date", "time", "sessionType", "exercise"],
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

  if (input.date)        { fields.date        = { value: input.date }; updated.push("date"); }
  if (input.time)        { fields.time        = { value: input.time }; updated.push("time"); }
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

/// Bulk-retag every ExerciseEntry on a given date. The data model has no
/// dedicated TrainingSession record — a "session" is the logical bucket of
/// entries sharing (date, sessionType). This tool lets callers operate at
/// the session level without fanning out per-entry updates themselves.
export async function retagTrainingSession(client: CloudKitClient, input: RetagTrainingSessionInput) {
  // Query by `date EQUALS` directly. listTrainingEntries() uses a
  // ___createTime match-all filter which isn't indexed on ExerciseEntry,
  // and date GTE/LTE isn't allowed either — but EQUALS on the STRING
  // date field works even with minimal indexing.
  const res = await client.queryRecords({
    recordType: "ExerciseEntry",
    filterBy: [
      { fieldName: "date", comparator: "EQUALS" as const, fieldValue: { value: input.date } },
    ] as never,
    resultsLimit: 200,
  });
  const ids = res.records.map((r) => r.recordName.replace(/^exercise-entry:/, ""));
  if (!ids.length) return { date: input.date, sessionType: input.sessionType, updated: 0, ids: [] };

  const ops = ids.map((rawId) => ({
    operationType: "forceUpdate" as const,
    record: {
      recordType: "ExerciseEntry",
      recordName: `exercise-entry:${rawId}`,
      fields: { sessionType: { value: input.sessionType } },
    },
  }));
  const modRes = await modify(client, ops);
  const failed = modRes.records.filter((r) => r.serverErrorCode).map((r) => r.reason ?? r.serverErrorCode);
  if (failed.length) throw new Error(`retag failed: ${failed.join("; ")}`);
  return {
    date: input.date,
    sessionType: input.sessionType,
    updated: ids.length,
    ids,
  };
}

export async function deleteTrainingEntry(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `exercise-entry:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
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

export async function deleteExercise(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `exercise-def:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}

// ============================================================================
// SessionType implementations
// ============================================================================

export async function listSessionTypes(client: CloudKitClient, input: ListSessionTypesInput) {
  const filters: Array<{ fieldName: string; comparator: string; fieldValue: { value: unknown } }> = [];
  if (input.archived === undefined || input.archived === false) {
    filters.push({ fieldName: "archived", comparator: "EQUALS", fieldValue: { value: 0 } });
  }

  const res = await client.queryRecords({
    recordType: "SessionType",
    filterBy: filters.length ? (filters as never) : undefined,
    sortBy: [{ fieldName: "sortIndex", ascending: true }],
    resultsLimit: input.limit ?? 100,
  });

  const sessions = res.records.map((r) => ({
    id:        r.recordName.replace(/^session-type:/, ""),
    label:     optStr(r.fields.label?.value) ?? "",
    emoji:     optStr(r.fields.emoji?.value),
    exercises: optStrArray(r.fields.exercises?.value),
    kind:      optStr(r.fields.kind?.value),
    archived:  ((r.fields.archived?.value as number) ?? 0) !== 0,
    sortIndex: (r.fields.sortIndex?.value as number) ?? 0,
  }));

  return { sessions };
}

export async function createSessionType(client: CloudKitClient, input: CreateSessionTypeInput) {
  const fields: Record<string, { value: unknown }> = {
    label:     { value: input.label },
    exercises: { value: input.exercises ?? [] },
    archived:  { value: 0 },
    sortIndex: { value: 0 },
  };
  if (input.emoji) fields.emoji = { value: input.emoji };
  if (input.kind)  fields.kind  = { value: input.kind };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "SessionType",
    recordName: `session-type:${input.id}`,
    fields,
    protectedFields: ["label"],
  });

  return droppedFields.length > 0
    ? { id: input.id, label: input.label, droppedFields }
    : { id: input.id, label: input.label };
}

export async function updateSessionType(client: CloudKitClient, input: UpdateSessionTypeInput) {
  const fields: Record<string, { value: unknown }> = {};
  const updated: string[] = [];
  if (input.label !== undefined)     { fields.label = { value: input.label }; updated.push("label"); }
  if (input.emoji !== undefined)     { fields.emoji = { value: input.emoji ?? "" }; updated.push("emoji"); }
  if (input.exercises !== undefined) { fields.exercises = { value: input.exercises }; updated.push("exercises"); }
  if (input.kind !== undefined)      { fields.kind = { value: input.kind ?? "" }; updated.push("kind"); }
  if (input.archived !== undefined)  { fields.archived = { value: input.archived ? 1 : 0 }; updated.push("archived"); }

  if (!updated.length) return { id: input.id, updated: [] };

  const res = await modify(client, [{
    operationType: "forceUpdate",
    record: { recordType: "SessionType", recordName: `session-type:${input.id}`, fields },
  }]);
  const code = res.records[0]?.serverErrorCode;
  if (code) throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id, updated };
}

export async function deleteSessionType(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `session-type:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}
