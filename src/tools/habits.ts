import { extractUnknownFieldName, type CloudKitClient } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD, nowHHMM, localToEpochMs, epochMsToHHMM } from "../tz.js";

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
  records: Array<{ recordName: string; fields?: Record<string, { value: unknown }>; serverErrorCode?: string; reason?: string }>;
}

async function modify(client: CloudKitClient, ops: ModifyOp[]): Promise<CKModifyResponse> {
  return client.post<CKModifyResponse>("records/modify", {
    zoneID: { zoneName: client.zoneName },
    operations: ops,
  });
}

// ---- JSON Schemas ----

export const listHabitsJsonSchema = {
  type: "object",
  properties: {
    date: { type: "string", description: "YYYY-MM-DD. Defaults to today." },
  },
} as const;

export const createHabitJsonSchema = {
  type: "object",
  required: ["title", "bucket"],
  properties: {
    title: { type: "string", minLength: 1 },
    bucket: { type: "string", enum: ["morning", "evening", "anytime"] },
    emoji: { type: "string" },
  },
} as const;

export const toggleHabitJsonSchema = {
  type: "object",
  required: ["id", "done"],
  properties: {
    id: { type: "string" },
    date: { type: "string", description: "YYYY-MM-DD. Defaults to today." },
    done: { type: "boolean" },
    skipped: { type: "boolean", default: false },
  },
} as const;

// ---- Types ----

export interface ListHabitsInput { date?: string }
export interface CreateHabitInput { title: string; bucket: string; emoji?: string }
export interface ToggleHabitInput { id: string; date?: string; done: boolean; skipped?: boolean }

// ---- Implementations ----

export async function listHabits(client: CloudKitClient, input: ListHabitsInput) {
  const tz = await getEffectiveTimezone(client);
  const date = input.date ?? todayYMD(tz);
  const [defsRes, eventsRes] = await Promise.all([
    client.queryRecords({
      recordType: "HabitDefinition",
      sortBy: [{ fieldName: "sortIndex", ascending: true }],
      resultsLimit: 200,
    }),
    client.queryRecords({
      recordType: "HabitEvent",
      filterBy: [{ fieldName: "date", comparator: "EQUALS", fieldValue: { value: date } }],
      resultsLimit: 200,
    }),
  ]);

  const byID = new Map<string, { done: boolean; skipped: boolean; note?: string; time?: string }>();
  for (const r of eventsRes.records) {
    const hid = optStr(r.fields.habitID?.value);
    if (hid) {
      byID.set(hid, {
        done: ((r.fields.done?.value as number) ?? 0) !== 0,
        skipped: ((r.fields.skipped?.value as number) ?? 0) !== 0,
        note: optStr(r.fields.note?.value),
        time: optStr(r.fields.time?.value) ?? (typeof r.fields.occurredAt?.value === "number" ? epochMsToHHMM(r.fields.occurredAt.value as number, tz) : undefined),
      });
    }
  }

  const habits = defsRes.records.map((r) => {
    const id = r.recordName.slice("habit-def:".length);
    const ev = byID.get(id);
    return {
      id,
      title: optStr(r.fields.title?.value) ?? "",
      bucket: optStr(r.fields.bucket?.value) ?? "morning",
      emoji: optStr(r.fields.emoji?.value),
      sortIndex: (r.fields.sortIndex?.value as number) ?? 0,
      done: ev?.done ?? false,
      skipped: ev?.skipped ?? false,
      note: ev?.note,
      time: ev?.time,
    };
  });

  return { date, habits };
}

export async function createHabit(client: CloudKitClient, input: CreateHabitInput) {
  const id = newId(4);
  const fields: Record<string, { value: unknown }> = {
    title: { value: input.title },
    bucket: { value: input.bucket },
    sortIndex: { value: 0 },
  };
  if (input.emoji) fields.emoji = { value: input.emoji };
  await modify(client, [{
    operationType: "create",
    record: { recordType: "HabitDefinition", recordName: `habit-def:${id}`, fields },
  }]);
  return { id, title: input.title, bucket: input.bucket };
}

export async function toggleHabit(client: CloudKitClient, input: ToggleHabitInput) {
  const tz = await getEffectiveTimezone(client);
  const date = input.date ?? todayYMD(tz);
  const stateID = `habit:${date}:${input.id}`;
  const recordName = `habit-event:${stateID}`;
  const needsRow = input.done || (input.skipped ?? false);

  if (!needsRow) {
    const res = await modify(client, [{ operationType: "delete", record: { recordName } }]);
    // NOT_FOUND is fine — the event just didn't exist
    if (res.records[0]?.serverErrorCode && res.records[0].serverErrorCode !== "NOT_FOUND") {
      throw new Error(`Failed to delete habit event: ${res.records[0].serverErrorCode}`);
    }
    return { id: input.id, date, done: false, skipped: false };
  }

  const time = nowHHMM(tz);
  const fields: Record<string, { value: unknown }> = {
    date: { value: date },
    habitID: { value: input.id },
    done: { value: input.done ? 1 : 0 },
    skipped: { value: (input.skipped ?? false) ? 1 : 0 },
    // canonical instant; legacy `time` STRING retired (derive from occurredAt).
    // occurredAt drops gracefully if the schema doesn't know it yet (see below).
    occurredAt: { value: localToEpochMs(date, time, tz) },
  };

  const createRes = await modify(client, [{
    operationType: "create",
    record: { recordType: "HabitEvent", recordName, fields },
  }]);
  const code = createRes.records[0]?.serverErrorCode;
  if (code === "CONFLICT" || code === "EXISTS" || code === "UNIQUE_FIELD_ERROR") {
    await modify(client, [{
      operationType: "forceUpdate",
      record: { recordType: "HabitEvent", recordName, fields },
    }]);
  } else if (code) {
    // If the only problem is an unregistered occurredAt field, drop it and retry
    // once — the schema may not know occurredAt yet on this account.
    const unknown = extractUnknownFieldName(createRes.records[0]?.reason ?? code);
    if (unknown && unknown in fields && unknown !== "date" && unknown !== "habitID" && unknown !== "done") {
      delete fields[unknown];
      const retry = await modify(client, [{
        operationType: "create",
        record: { recordType: "HabitEvent", recordName, fields },
      }]);
      const rcode = retry.records[0]?.serverErrorCode;
      if (rcode === "CONFLICT" || rcode === "EXISTS" || rcode === "UNIQUE_FIELD_ERROR") {
        await modify(client, [{
          operationType: "forceUpdate",
          record: { recordType: "HabitEvent", recordName, fields },
        }]);
      } else if (rcode) {
        throw new Error(`Failed to toggle habit: ${rcode}`);
      }
    } else {
      throw new Error(`Failed to toggle habit: ${code}`);
    }
  }

  return { id: input.id, date, done: input.done, skipped: input.skipped ?? false };
}
