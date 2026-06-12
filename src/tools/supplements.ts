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

export const listSupplementsJsonSchema = {
  type: "object",
  properties: {
    date: { type: "string", description: "YYYY-MM-DD. Defaults to today." },
  },
} as const;

export const createSupplementJsonSchema = {
  type: "object",
  required: ["title"],
  properties: {
    title: { type: "string", minLength: 1 },
    emoji: { type: "string" },
  },
} as const;

export const toggleSupplementJsonSchema = {
  type: "object",
  required: ["id", "done"],
  properties: {
    id: { type: "string" },
    date: { type: "string", description: "YYYY-MM-DD. Defaults to today." },
    done: { type: "boolean" },
  },
} as const;

// ---- Types ----

export interface ListSupplementsInput { date?: string }
export interface CreateSupplementInput { title: string; emoji?: string }
export interface ToggleSupplementInput { id: string; date?: string; done: boolean }

// ---- Implementations ----

export async function listSupplements(client: CloudKitClient, input: ListSupplementsInput) {
  const tz = await getEffectiveTimezone(client);
  const date = input.date ?? todayYMD(tz);
  const [defsRes, eventsRes] = await Promise.all([
    client.queryRecords({
      recordType: "SupplementDefinition",
      sortBy: [{ fieldName: "sortIndex", ascending: true }],
      resultsLimit: 200,
    }),
    client.queryRecords({
      recordType: "SupplementEvent",
      filterBy: [{ fieldName: "date", comparator: "EQUALS", fieldValue: { value: date } }],
      resultsLimit: 200,
    }),
  ]);

  const byID = new Map<string, { done: boolean; note?: string; time?: string }>();
  for (const r of eventsRes.records) {
    const sid = optStr(r.fields.supplementID?.value);
    if (sid) {
      byID.set(sid, {
        done: ((r.fields.done?.value as number) ?? 0) !== 0,
        note: optStr(r.fields.note?.value),
        time: optStr(r.fields.time?.value) ?? (typeof r.fields.occurredAt?.value === "number" ? epochMsToHHMM(r.fields.occurredAt.value as number, tz) : undefined),
      });
    }
  }

  const supplements = defsRes.records.map((r) => {
    const id = r.recordName.slice("supplement-def:".length);
    const ev = byID.get(id);
    return {
      id,
      title: optStr(r.fields.title?.value) ?? "",
      emoji: optStr(r.fields.emoji?.value),
      sortIndex: (r.fields.sortIndex?.value as number) ?? 0,
      done: ev?.done ?? false,
      note: ev?.note,
      time: ev?.time,
    };
  });

  return { date, supplements };
}

export async function createSupplement(client: CloudKitClient, input: CreateSupplementInput) {
  const id = newId(4);
  const fields: Record<string, { value: unknown }> = {
    title: { value: input.title },
    sortIndex: { value: 0 },
  };
  if (input.emoji) fields.emoji = { value: input.emoji };
  await modify(client, [{
    operationType: "create",
    record: { recordType: "SupplementDefinition", recordName: `supplement-def:${id}`, fields },
  }]);
  return { id, title: input.title };
}

export async function toggleSupplement(client: CloudKitClient, input: ToggleSupplementInput) {
  const tz = await getEffectiveTimezone(client);
  const date = input.date ?? todayYMD(tz);
  const stateID = `supplement:${date}:${input.id}`;
  const recordName = `supplement-event:${stateID}`;

  if (!input.done) {
    const res = await modify(client, [{ operationType: "delete", record: { recordName } }]);
    if (res.records[0]?.serverErrorCode && res.records[0].serverErrorCode !== "NOT_FOUND") {
      throw new Error(`Failed to delete supplement event: ${res.records[0].serverErrorCode}`);
    }
    return { id: input.id, date, done: false };
  }

  const time = nowHHMM(tz);
  const fields: Record<string, { value: unknown }> = {
    date: { value: date },
    supplementID: { value: input.id },
    done: { value: 1 },
    // canonical instant; legacy `time` STRING retired (derive from occurredAt).
    // occurredAt drops gracefully if the schema doesn't know it yet.
    occurredAt: { value: localToEpochMs(date, time, tz) },
  };

  const createRes = await modify(client, [{
    operationType: "create",
    record: { recordType: "SupplementEvent", recordName, fields },
  }]);
  const code = createRes.records[0]?.serverErrorCode;
  if (code === "CONFLICT" || code === "EXISTS" || code === "UNIQUE_FIELD_ERROR") {
    await modify(client, [{
      operationType: "forceUpdate",
      record: { recordType: "SupplementEvent", recordName, fields },
    }]);
  } else if (code) {
    // If the only problem is an unregistered occurredAt field, drop it and retry.
    const unknown = extractUnknownFieldName(createRes.records[0]?.reason ?? code);
    if (unknown && unknown in fields && unknown !== "date" && unknown !== "supplementID" && unknown !== "done") {
      delete fields[unknown];
      const retry = await modify(client, [{
        operationType: "create",
        record: { recordType: "SupplementEvent", recordName, fields },
      }]);
      const rcode = retry.records[0]?.serverErrorCode;
      if (rcode === "CONFLICT" || rcode === "EXISTS" || rcode === "UNIQUE_FIELD_ERROR") {
        await modify(client, [{
          operationType: "forceUpdate",
          record: { recordType: "SupplementEvent", recordName, fields },
        }]);
      } else if (rcode) {
        throw new Error(`Failed to toggle supplement: ${rcode}`);
      }
    } else {
      throw new Error(`Failed to toggle supplement: ${code}`);
    }
  }

  return { id: input.id, date, done: true };
}
