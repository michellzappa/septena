import { queryByDateRange, type CloudKitClient, type CKRecord } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD, ymdNDaysAgo, nowHHMMSS, localToEpochMs, epochMsToHHMM } from "../tz.js";

// Generic consumable ("intake") tools. The tracker — a "kind" — is an
// ARGUMENT resolved by id or unique case-insensitive name, never part of a
// tool name: nine tools cover unlimited user-defined trackers and substance
// nouns live only in the user's own kind names. Mirrors the in-app server's
// MCPDispatch intake block (lockstep rule); record shapes follow
// docs/CloudKitSchema.md (IntakeKind / IntakeItem / IntakeEvent).

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";
function newId(len = 8): string {
  const buf = new Uint8Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => SHORTID_ALPHABET[b & 31]).join("");
}

function optStr(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

function num(v: unknown): number | undefined {
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

// ---- Method rows (stored as a JSON string column on the kind) ----

export interface IntakeMethodRow {
  token: string;
  label: string;
  symbol?: string;
  defaultAmount?: number;
  usesContainer: boolean;
}

function slug(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function parseMethodsJSON(v: unknown): IntakeMethodRow[] {
  if (typeof v !== "string" || v.length === 0) return [];
  try {
    const arr = JSON.parse(v);
    return Array.isArray(arr) ? (arr as IntakeMethodRow[]) : [];
  } catch {
    return [];
  }
}

function normalizeMethods(input: unknown): IntakeMethodRow[] | undefined {
  if (!Array.isArray(input) || input.length === 0) return undefined;
  const rows = input
    .map((m): IntakeMethodRow | null => {
      const obj = m as Record<string, unknown>;
      const label = optStr(obj.label) ?? optStr(obj.token);
      if (!label) return null;
      return {
        token: optStr(obj.token)?.toLowerCase() ?? slug(label),
        label,
        symbol: optStr(obj.symbol),
        defaultAmount: num(obj.defaultAmount),
        usesContainer: obj.usesContainer === true,
      };
    })
    .filter((r): r is IntakeMethodRow => r !== null);
  return rows.length > 0 ? rows : undefined;
}

// ---- Kind resolution ----

interface IntakeKind {
  id: string;
  name: string;
  symbol: string;
  color: string;
  unit?: string;
  doseStyle: string;
  countNoun?: string;
  containerNoun?: string;
  containerCap?: number;
  catalogNoun?: string;
  objective: string;
  archived: boolean;
  methods: IntakeMethodRow[];
}

function kindFromRecord(r: CKRecord): IntakeKind {
  return {
    id: r.recordName.replace(/^intake-kind:/, ""),
    name: optStr(r.fields.name?.value) ?? "",
    symbol: optStr(r.fields.symbol?.value) ?? "circle",
    color: optStr(r.fields.color?.value) ?? "",
    unit: optStr(r.fields.unit?.value),
    doseStyle: optStr(r.fields.doseStyle?.value) ?? "none",
    countNoun: optStr(r.fields.countNoun?.value),
    containerNoun: optStr(r.fields.containerNoun?.value),
    containerCap: num(r.fields.containerCap?.value),
    catalogNoun: optStr(r.fields.catalogNoun?.value),
    objective: optStr(r.fields.objective?.value) ?? "log",
    archived: r.fields.archivedAt?.value !== undefined && r.fields.archivedAt?.value !== null,
    methods: parseMethodsJSON(r.fields.methods?.value),
  };
}

async function fetchKinds(client: CloudKitClient): Promise<IntakeKind[]> {
  const res = await client.queryRecords({
    recordType: "IntakeKind",
    resultsLimit: 200,
  });
  return res.records.map(kindFromRecord);
}

async function resolveKind(client: CloudKitClient, key: string | undefined): Promise<IntakeKind> {
  if (!key) throw new Error("missing 'kind'");
  const kinds = await fetchKinds(client);
  const exact = kinds.find((k) => k.id === key);
  if (exact) return exact;
  const lower = key.toLowerCase();
  const named = kinds.filter((k) => k.name.toLowerCase() === lower);
  if (named.length === 1) return named[0];
  const candidates = kinds
    .filter((k) => !k.archived)
    .map((k) => `${k.name} (${k.id})`)
    .join(", ");
  throw new Error(
    named.length === 0
      ? `unknown kind '${key}' — kinds: ${candidates}`
      : `ambiguous kind '${key}' — use an id. kinds: ${candidates}`,
  );
}

// ---- JSON Schemas ----

const methodsSchema = {
  type: "array",
  description: "Method rows.",
  items: {
    type: "object",
    properties: {
      token: { type: "string" },
      label: { type: "string" },
      symbol: { type: "string" },
      defaultAmount: { type: "number" },
      usesContainer: { type: "boolean" },
    },
  },
} as const;

const kindConfigProperties = {
  symbol: { type: "string", description: "SF Symbol name." },
  color: { type: "string", description: "Hex accent, e.g. #0d9488." },
  unit: { type: "string", description: "Amount unit: g | mg | ml." },
  doseStyle: { type: "string", enum: ["none", "amount", "count", "both"] },
  countNoun: { type: "string", description: "Count unit name: hit | cup | puff." },
  containerNoun: { type: "string", description: "capsule | pack — enables the container quick-add." },
  containerCap: { type: "integer", description: "Uses per container." },
  catalogNoun: { type: "string", description: "Variety catalog name: Beans | Strains." },
  objective: { type: "string", enum: ["log", "limit", "reduce", "quit"] },
  methods: methodsSchema,
} as const;

export const listIntakeKindsJsonSchema = {
  type: "object",
  properties: {
    includeArchived: { type: "boolean", description: "Include archived trackers. Default false." },
  },
} as const;

export const createIntakeKindJsonSchema = {
  type: "object",
  required: ["name"],
  properties: { name: { type: "string", minLength: 1 }, ...kindConfigProperties },
} as const;

export const updateIntakeKindJsonSchema = {
  type: "object",
  required: ["kind"],
  properties: {
    kind: { type: "string", description: "Tracker id or unique name (case-insensitive)." },
    name: { type: "string" },
    archived: { type: "boolean" },
    ...kindConfigProperties,
  },
} as const;

export const listIntakeItemsJsonSchema = {
  type: "object",
  required: ["kind"],
  properties: { kind: { type: "string", description: "Tracker id or unique name." } },
} as const;

export const createIntakeItemJsonSchema = {
  type: "object",
  required: ["kind", "name"],
  properties: { kind: { type: "string" }, name: { type: "string", minLength: 1 } },
} as const;

export const deleteIntakeItemJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", description: "IntakeItem id." } },
} as const;

export const listIntakeEventsJsonSchema = {
  type: "object",
  required: ["kind"],
  properties: {
    kind: { type: "string", description: "Tracker id or unique name." },
    date: { type: "string", description: "YYYY-MM-DD filter. Omit for last 7 days." },
    from: { type: "string", description: "YYYY-MM-DD range start (inclusive)." },
    to: { type: "string", description: "YYYY-MM-DD range end (inclusive). Defaults to today." },
    limit: { type: "integer", minimum: 1, maximum: 500, default: 100 },
  },
} as const;

export const logIntakeEventJsonSchema = {
  type: "object",
  required: ["kind", "method"],
  properties: {
    kind: { type: "string", description: "Tracker id or unique name." },
    method: { type: "string", description: "Method token or label (see intake_kinds_list)." },
    date: { type: "string", description: "YYYY-MM-DD. Defaults to today." },
    time: { type: "string", description: "HH:MM or HH:MM:SS. Defaults to now." },
    amount: { type: "number", description: "Dose in the kind's unit." },
    count: { type: "integer", description: "Hits/uses — container math reads this." },
    item: { type: "string", description: "Catalog variety id or name." },
    note: { type: "string" },
  },
} as const;

export const deleteIntakeEventJsonSchema = {
  type: "object",
  required: ["id"],
  properties: { id: { type: "string", description: "IntakeEvent id." } },
} as const;

// ---- Types ----

export interface ListIntakeKindsInput { includeArchived?: boolean }
export interface CreateIntakeKindInput {
  name: string; symbol?: string; color?: string; unit?: string; doseStyle?: string;
  countNoun?: string; containerNoun?: string; containerCap?: number; catalogNoun?: string;
  objective?: string; methods?: unknown;
}
export interface UpdateIntakeKindInput extends Partial<CreateIntakeKindInput> { kind: string; archived?: boolean }
export interface ListIntakeItemsInput { kind: string }
export interface CreateIntakeItemInput { kind: string; name: string }
export interface ListIntakeEventsInput { kind: string; date?: string; from?: string; to?: string; limit?: number }
export interface LogIntakeEventInput {
  kind: string; method: string; date?: string; time?: string;
  amount?: number; count?: number; item?: string; note?: string;
}

// ---- Implementations ----

export async function listIntakeKinds(client: CloudKitClient, input: ListIntakeKindsInput) {
  const kinds = (await fetchKinds(client)).filter((k) => input.includeArchived || !k.archived);
  // Per-kind today counts + container state, so resolution is one call ever.
  const tz = await getEffectiveTimezone(client);
  const today = todayYMD(tz);
  const todays = await queryByDateRange(client, {
    recordType: "IntakeEvent",
    from: today,
    to: today,
    instantField: "occurredAt",
    resultsLimit: 500,
  });
  return {
    kinds: kinds.map((k) => {
      const mine = todays.filter((r) => optStr(r.fields.kindID?.value) === k.id);
      const containerToken = k.methods.find((m) => m.usesContainer)?.token;
      let lastContainerCountToday = 0;
      if (containerToken) {
        const latest = mine
          .filter((r) => optStr(r.fields.method?.value) === containerToken)
          .sort((a, b) => (num(b.fields.occurredAt?.value) ?? 0) - (num(a.fields.occurredAt?.value) ?? 0))[0];
        lastContainerCountToday = num(latest?.fields.count?.value) ?? 0;
      }
      return { ...k, todayCount: mine.length, lastContainerCountToday };
    }),
  };
}

function kindFields(input: Partial<CreateIntakeKindInput>): Record<string, { value: unknown }> {
  const fields: Record<string, { value: unknown }> = {};
  if (input.name !== undefined) fields.name = { value: input.name };
  if (input.symbol !== undefined) fields.symbol = { value: input.symbol };
  if (input.color !== undefined) fields.color = { value: input.color };
  if (input.unit !== undefined) fields.unit = { value: input.unit };
  if (input.doseStyle !== undefined) fields.doseStyle = { value: input.doseStyle };
  if (input.countNoun !== undefined) fields.countNoun = { value: input.countNoun };
  if (input.containerNoun !== undefined) fields.containerNoun = { value: input.containerNoun };
  if (input.containerCap !== undefined) fields.containerCap = { value: input.containerCap };
  if (input.catalogNoun !== undefined) fields.catalogNoun = { value: input.catalogNoun };
  if (input.objective !== undefined) fields.objective = { value: input.objective };
  const methods = normalizeMethods(input.methods);
  if (methods) fields.methods = { value: JSON.stringify(methods) };
  return fields;
}

export async function createIntakeKind(client: CloudKitClient, input: CreateIntakeKindInput) {
  const id = `ik-${newId(8)}`;
  const fields = kindFields({ doseStyle: "none", objective: "log", symbol: "circle", ...input });
  fields.sortIndex = { value: 0 };
  fields.flourish = { value: "bloom" };
  fields.metricMode = { value: "countEvents" };
  if (!fields.methods) fields.methods = { value: "[]" };
  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "IntakeKind",
    recordName: `intake-kind:${id}`,
    fields,
    protectedFields: ["name"],
  });
  // NOTE: the objective's matching Goal is created by the app (Manage sheet /
  // in-app server) — the gateway only sets the objective field.
  return droppedFields.length > 0 ? { id, name: input.name, droppedFields } : { id, name: input.name };
}

export async function updateIntakeKind(client: CloudKitClient, input: UpdateIntakeKindInput) {
  const kind = await resolveKind(client, input.kind);
  const fields = kindFields(input);
  if (input.archived !== undefined) {
    fields.archivedAt = { value: input.archived ? Date.now() : null };
  }
  if (Object.keys(fields).length === 0) return { id: kind.id, name: kind.name };
  const res = await modify(client, [{
    operationType: "forceUpdate",
    record: { recordType: "IntakeKind", recordName: `intake-kind:${kind.id}`, fields },
  }]);
  const code = res.records[0]?.serverErrorCode;
  if (code) throw new Error(res.records[0]?.reason ?? code);
  return { id: kind.id, name: input.name ?? kind.name };
}

export async function listIntakeItems(client: CloudKitClient, input: ListIntakeItemsInput) {
  const kind = await resolveKind(client, input.kind);
  const res = await client.queryRecords({
    recordType: "IntakeItem",
    resultsLimit: 200,
  });
  const items = res.records
    .filter((r) => optStr(r.fields.kindID?.value) === kind.id && r.fields.archivedAt?.value == null)
    .map((r) => ({
      id: r.recordName.replace(/^intake-item:/, ""),
      name: optStr(r.fields.name?.value) ?? "",
    }));
  return { kind: kind.name, items };
}

export async function createIntakeItem(client: CloudKitClient, input: CreateIntakeItemInput) {
  const kind = await resolveKind(client, input.kind);
  const id = `ii-${newId(8)}`;
  const res = await modify(client, [{
    operationType: "create",
    record: {
      recordType: "IntakeItem",
      recordName: `intake-item:${id}`,
      fields: { kindID: { value: kind.id }, name: { value: input.name }, sortIndex: { value: 0 } },
    },
  }]);
  const code = res.records[0]?.serverErrorCode;
  if (code) throw new Error(res.records[0]?.reason ?? code);
  return { id, name: input.name, kind: kind.name };
}

export async function deleteIntakeItem(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `intake-item:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}

export async function listIntakeEvents(client: CloudKitClient, input: ListIntakeEventsInput) {
  const kind = await resolveKind(client, input.kind);
  const tz = await getEffectiveTimezone(client);
  const from = input.date ?? input.from ?? ymdNDaysAgo(6, tz);
  const to = input.date ?? input.to ?? todayYMD(tz);

  const records = await queryByDateRange(client, {
    recordType: "IntakeEvent",
    from,
    to,
    instantField: "occurredAt",
    resultsLimit: 500,
  });

  const events = records
    .filter((r) => optStr(r.fields.kindID?.value) === kind.id)
    .slice(0, input.limit ?? 100)
    .map((r) => ({
      id: r.recordName.replace(/^intake-event:/, ""),
      date: optStr(r.fields.date?.value) ?? "",
      time: typeof r.fields.occurredAt?.value === "number" ? epochMsToHHMM(r.fields.occurredAt.value as number, tz) : "",
      method: optStr(r.fields.method?.value) ?? "",
      item: optStr(r.fields.itemID?.value),
      amount: num(r.fields.amount?.value),
      count: num(r.fields.count?.value),
      note: optStr(r.fields.note?.value),
    }));

  return { kind: kind.name, kindID: kind.id, events };
}

export async function logIntakeEvent(client: CloudKitClient, input: LogIntakeEventInput) {
  const kind = await resolveKind(client, input.kind);
  const lower = (input.method ?? "").toLowerCase();
  const match = kind.methods.find((m) => m.token === lower || m.label.toLowerCase() === lower);
  const token = match?.token ?? (kind.methods.length === 0 ? slug(input.method) : undefined);
  if (!token) {
    throw new Error(
      `unknown method '${input.method}' for ${kind.name} — methods: ${kind.methods.map((m) => m.token).join(", ")}`,
    );
  }

  let itemID: string | undefined;
  if (input.item) {
    const { items } = await listIntakeItems(client, { kind: kind.id });
    const found = items.find((i) => i.id === input.item) ??
      items.find((i) => i.name.toLowerCase() === input.item!.toLowerCase());
    if (!found) {
      throw new Error(`unknown item '${input.item}' — items: ${items.map((i) => i.name).join(", ")}`);
    }
    itemID = found.id;
  }

  const tz = await getEffectiveTimezone(client);
  const id = newId(8);
  const date = input.date ?? todayYMD(tz);
  const time = input.time ?? nowHHMMSS(tz);
  const fields: Record<string, { value: unknown }> = {
    kindID: { value: kind.id },
    date: { value: date },
    method: { value: token },
    occurredAt: { value: localToEpochMs(date, time, tz) },
  };
  if (itemID) fields.itemID = { value: itemID };
  if (input.amount !== undefined) fields.amount = { value: input.amount };
  if (input.count !== undefined) fields.count = { value: input.count };
  if (input.note) fields.note = { value: input.note };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "IntakeEvent",
    recordName: `intake-event:${id}`,
    fields,
    protectedFields: ["kindID", "date", "method"],
  });

  return droppedFields.length > 0
    ? { id, date, time, method: token, kind: kind.name, droppedFields }
    : { id, date, time, method: token, kind: kind.name };
}

export async function deleteIntakeEvent(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `intake-event:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}
