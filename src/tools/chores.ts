import { queryByDateRange, type CloudKitClient } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD, nowHHMM, addDaysYMD, localToEpochMs } from "../tz.js";

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

function newId(len = 4): string {
  const buf = new Uint8Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => SHORTID_ALPHABET[b & 31]).join("");
}

function sortKey(tz: string): string {
  return `${todayYMD(tz)}::${Date.now().toFixed(0).padStart(20, "0")}`;
}

function nextSaturday(from: string): string {
  const d = new Date(`${from}T12:00:00Z`);
  const day = d.getUTCDay(); // 0=Sun, 6=Sat
  const delta = day === 6 ? 7 : (6 - day);
  d.setUTCDate(d.getUTCDate() + delta);
  return d.toISOString().slice(0, 10);
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

// Compute due date by replaying events chronologically (mirrors ChecklistMirror.swift).
function computeDueDate(
  events: Array<{ action: string; date: string; newDueDate?: string; sortKey: string }>,
  cadenceDays: number,
): { lastCompleted: string | undefined; dueDate: string | undefined } {
  // Sort by sortKey ascending = chronological order
  const sorted = [...events].sort((a, b) => a.sortKey.localeCompare(b.sortKey));
  let lastCompleted: string | undefined;
  let dueDate: string | undefined;
  for (const ev of sorted) {
    if (ev.action === "complete") {
      lastCompleted = ev.date;
      dueDate = addDaysYMD(ev.date, cadenceDays);
    } else if (ev.action === "defer" && ev.newDueDate) {
      // Defer overrides the due date for that moment; subsequent completes
      // will recalculate from the completion date + cadence.
      dueDate = ev.newDueDate;
    }
  }
  return { lastCompleted, dueDate };
}

// ---- JSON Schemas ----

export const listChoresJsonSchema = {
  type: "object",
  properties: {},
} as const;

export const createChoreJsonSchema = {
  type: "object",
  required: ["title", "cadenceDays"],
  properties: {
    title: { type: "string", minLength: 1 },
    cadenceDays: { type: "integer", minimum: 1, description: "How often this chore recurs (days)" },
    emoji: { type: "string" },
  },
} as const;

export const updateChoreJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id: { type: "string" },
    title: { type: "string" },
    cadenceDays: { type: "integer", minimum: 1 },
    emoji: { type: ["string", "null"] },
  },
} as const;

export const deleteChoreJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string" } },
} as const;

export const completeChoreJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id: { type: "string" },
    date: { type: "string", description: "YYYY-MM-DD. Defaults to today." },
  },
} as const;

export const deferChoreJsonSchema = {
  type: "object",
  required: ["id", "mode"],
  properties: {
    id: { type: "string" },
    mode: { type: "string", enum: ["day", "weekend"], description: "'day' = tomorrow, 'weekend' = next Saturday" },
    date: { type: "string", description: "YYYY-MM-DD reference date. Defaults to today." },
  },
} as const;

export const uncompleteChoreJsonSchema = {
  type: "object",
  required: ["id"],
  properties: {
    id: { type: "string" },
    date: { type: "string", description: "YYYY-MM-DD. Defaults to today." },
  },
} as const;

// ---- Types ----

export interface CreateChoreInput { title: string; cadenceDays: number; emoji?: string }
export interface UpdateChoreInput { id: string; title?: string; cadenceDays?: number; emoji?: string | null }
export interface CompleteChoreInput { id: string; date?: string }
export interface DeferChoreInput { id: string; mode: "day" | "weekend"; date?: string }
export interface UncompleteChoreInput { id: string; date?: string }

// ---- Implementations ----

export async function listChores(client: CloudKitClient) {
  const tz = await getEffectiveTimezone(client);
  const today = todayYMD(tz);
  const since = addDaysYMD(today, -180);

  const [defsRes, eventRecords] = await Promise.all([
    client.queryRecords({
      recordType: "ChoreDefinition",
      // CK requires at least one filter; `title BEGINS_WITH ""` matches
      // every record without needing ___createTime to be queryable.
      filterBy: [{ fieldName: "title", comparator: "BEGINS_WITH", fieldValue: { value: "" } }],
      sortBy: [{ fieldName: "sortIndex", ascending: true }],
      resultsLimit: 200,
    }),
    // ChoreEvent.date is a STRING — CloudKit rejects range comparators on it
    // (GREATER_THAN_OR_EQUALS → 400), which broke listChores entirely. Use the
    // shared match-all + client-side window path; computeDueDate re-sorts by
    // sortKey itself, so server order doesn't matter.
    queryByDateRange(client, {
      recordType: "ChoreEvent",
      from: since,
      to: today,
      resultsLimit: 5000,
    }),
  ]);
  const eventsRes = { records: eventRecords };

  // Group events by choreID
  const eventsByChore = new Map<
    string,
    Array<{ action: string; date: string; newDueDate?: string; sortKey: string }>
  >();
  for (const r of eventsRes.records) {
    const cid = optStr(r.fields.choreID?.value);
    if (!cid) continue;
    const list = eventsByChore.get(cid) ?? [];
    list.push({
      action: optStr(r.fields.action?.value) ?? "complete",
      date: optStr(r.fields.date?.value) ?? today,
      newDueDate: optStr(r.fields.newDueDate?.value),
      sortKey: optStr(r.fields.sortKey?.value) ?? "",
    });
    eventsByChore.set(cid, list);
  }

  const chores = defsRes.records.map((r) => {
    const id = r.recordName.slice("chore-def:".length);
    const cadenceDays = (r.fields.cadenceDays?.value as number) ?? 1;
    const events = eventsByChore.get(id) ?? [];
    const { lastCompleted, dueDate } = computeDueDate(events, cadenceDays);
    const daysOverdue = dueDate
      ? Math.max(0, (new Date(today).getTime() - new Date(dueDate).getTime()) / 86400000)
      : 0;
    return {
      id,
      title: optStr(r.fields.title?.value) ?? "",
      emoji: optStr(r.fields.emoji?.value),
      cadenceDays,
      sortIndex: (r.fields.sortIndex?.value as number) ?? 0,
      lastCompleted,
      dueDate: dueDate ?? today,
      daysOverdue: Math.round(daysOverdue),
    };
  });

  return { chores };
}

export async function createChore(client: CloudKitClient, input: CreateChoreInput) {
  const id = newId(4);
  const fields: Record<string, { value: unknown }> = {
    title: { value: input.title },
    cadenceDays: { value: input.cadenceDays },
    sortIndex: { value: 0 },
  };
  if (input.emoji) fields.emoji = { value: input.emoji };
  await modify(client, [{
    operationType: "create",
    record: { recordType: "ChoreDefinition", recordName: `chore-def:${id}`, fields },
  }]);
  return { id, title: input.title, cadenceDays: input.cadenceDays };
}

export async function updateChore(client: CloudKitClient, input: UpdateChoreInput) {
  const fields: Record<string, { value: unknown }> = {};
  const updated: string[] = [];
  if (input.title !== undefined) { fields.title = { value: input.title }; updated.push("title"); }
  if (input.cadenceDays !== undefined) { fields.cadenceDays = { value: input.cadenceDays }; updated.push("cadenceDays"); }
  if (input.emoji !== undefined) { fields.emoji = { value: input.emoji ?? "" }; updated.push("emoji"); }
  if (!updated.length) return { id: input.id, updated: [] };
  await modify(client, [{
    operationType: "forceUpdate",
    record: { recordType: "ChoreDefinition", recordName: `chore-def:${input.id}`, fields },
  }]);
  return { id: input.id, updated };
}

export async function deleteChore(client: CloudKitClient, input: { id: string }) {
  const eventsRes = await client.queryRecords({
    recordType: "ChoreEvent",
    filterBy: [{ fieldName: "choreID", comparator: "EQUALS", fieldValue: { value: input.id } }],
    resultsLimit: 500,
  });
  const ops: ModifyOp[] = [
    ...eventsRes.records.map((r) => ({ operationType: "delete" as const, record: { recordName: r.recordName } })),
    { operationType: "delete", record: { recordName: `chore-def:${input.id}` } },
  ];
  await modify(client, ops);
  return { id: input.id, deletedEvents: eventsRes.records.length };
}

export async function completeChore(client: CloudKitClient, input: CompleteChoreInput) {
  const tz = await getEffectiveTimezone(client);
  const date = input.date ?? todayYMD(tz);
  const time = nowHHMM(tz);
  const eventID = `chore:${date}:${input.id}:${newId(6)}`;
  const fields: Record<string, { value: unknown }> = {
    choreID: { value: input.id },
    action: { value: "complete" },
    date: { value: date },
    // canonical instant; legacy `time` STRING retired (derive from occurredAt).
    sortKey: { value: sortKey(tz) },
    occurredAt: { value: localToEpochMs(date, time, tz) },
  };
  // createWithFieldFallback so occurredAt drops gracefully if the schema
  // doesn't know it yet (eventID is unique, so no CONFLICT path needed).
  await client.createWithFieldFallback({
    recordType: "ChoreEvent",
    recordName: `chore-event:${eventID}`,
    fields,
    protectedFields: ["choreID", "action", "date", "sortKey"],
  });
  return { id: input.id, date, action: "complete" };
}

export async function deferChore(client: CloudKitClient, input: DeferChoreInput) {
  const tz = await getEffectiveTimezone(client);
  const date = input.date ?? todayYMD(tz);
  const newDueDate = input.mode === "weekend" ? nextSaturday(date) : addDaysYMD(date, 1);
  const eventID = `chore:${date}:${input.id}:${newId(6)}`;
  const fields: Record<string, { value: unknown }> = {
    choreID: { value: input.id },
    action: { value: "defer" },
    date: { value: date },
    newDueDate: { value: newDueDate },
    reason: { value: input.mode },
    sortKey: { value: sortKey(tz) },
    occurredAt: { value: localToEpochMs(date, undefined, tz) },
  };
  await client.createWithFieldFallback({
    recordType: "ChoreEvent",
    recordName: `chore-event:${eventID}`,
    fields,
    protectedFields: ["choreID", "action", "date", "newDueDate", "sortKey"],
  });
  return { id: input.id, date, newDueDate, action: "defer" };
}

export async function uncompleteChore(client: CloudKitClient, input: UncompleteChoreInput) {
  const tz = await getEffectiveTimezone(client);
  const date = input.date ?? todayYMD(tz);
  // Find the most recent complete event for this chore on this date
  const eventsRes = await client.queryRecords({
    recordType: "ChoreEvent",
    filterBy: [
      { fieldName: "choreID", comparator: "EQUALS", fieldValue: { value: input.id } },
      { fieldName: "date", comparator: "EQUALS", fieldValue: { value: date } },
    ],
    sortBy: [{ fieldName: "sortKey", ascending: false }],
    resultsLimit: 10,
  });
  const completeEvent = eventsRes.records.find(
    (r) => optStr(r.fields.action?.value) === "complete",
  );
  if (!completeEvent) {
    return { id: input.id, date, deleted: false, reason: "no complete event found for this date" };
  }
  await modify(client, [{ operationType: "delete", record: { recordName: completeEvent.recordName } }]);
  return { id: input.id, date, deleted: true, deletedRecordName: completeEvent.recordName };
}
