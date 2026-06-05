import type { CloudKitClient } from "../cloudkit.js";

// Hydration is a UX layer over Nutrition — every water log is a
// NutritionEntry with foods=["Water"], waterMl > 0, and all macros at 0.
// This file mirrors the iOS HydrationPlugin's MCP contract:
//   hydration_log     → create water-only NutritionEntry
//   hydration_today   → today's total ml + water-only entry list
//   hydration_history → per-day totals over a range
//
// Today/history totals sum waterMl across ALL nutrition entries for the
// day, not just water-only logs, so a meal that recorded waterMl
// contributes correctly. The water-only entry list is filtered to the
// marker shape for the "what did I log under hydration?" view.

import { getEffectiveTimezone, todayYMD, ymdNDaysAgo, addDaysYMD, localToEpochMs } from "../tz.js";

function newUUID(): string {
  return crypto.randomUUID();
}

function startOfDayEpochMs(ymd: string, tz: string): number {
  return localToEpochMs(ymd, "00:00", tz);
}

function endOfDayEpochMs(ymd: string, tz: string): number {
  // Inclusive end = 1ms before the start of the next local day.
  return localToEpochMs(addDaysYMD(ymd, 1), "00:00", tz) - 1;
}

/** The local calendar date (in `tz`) of an instant, "YYYY-MM-DD". */
function ymdFromEpochMs(ms: number, tz: string): string {
  const dtf = new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
  });
  // en-CA renders as YYYY-MM-DD.
  return dtf.format(new Date(ms));
}

function optStr(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}
function optNum(v: unknown): number | undefined {
  return typeof v === "number" ? v : undefined;
}

// Marker that distinguishes a water-only log from a meal that recorded
// waterMl. Matches HydrationPlugin.waterFoodsMarker on the iOS side.
const WATER_FOODS_MARKER = "Water";

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

export const logHydrationJsonSchema = {
  type: "object",
  required: ["ml"],
  properties: {
    ml:       { type: "integer", minimum: 1, description: "Water amount in milliliters." },
    loggedAt: { type: "string", description: "ISO8601 timestamp. Defaults to now." },
    note:     { type: "string" },
  },
} as const;

export const hydrationTodayJsonSchema = {
  type: "object",
  properties: {},
} as const;

export const hydrationHistoryJsonSchema = {
  type: "object",
  properties: {
    from: { type: "string", description: "YYYY-MM-DD range start. Inclusive." },
    to:   { type: "string", description: "YYYY-MM-DD range end. Defaults to today." },
    days: { type: "integer", minimum: 1, maximum: 90, default: 7, description: "Used only if from/to omitted." },
  },
} as const;

// ---- Types ----

export interface LogHydrationInput { ml: number; loggedAt?: string; note?: string }
export interface HydrationHistoryInput { from?: string; to?: string; days?: number }

// ---- Helpers ----

interface NutritionEntryShape {
  loggedAt: number;
  foods: string;
  waterMl: number;
  proteinG: number;
  fatG: number;
  carbsG: number;
}

/// Mirrors HydrationPlugin.isHydrationOnly — a water-only entry has the
/// marker, positive waterMl, and zero macros. Meal entries that record
/// waterMl don't match and aren't shown in the hydration log list.
function isHydrationOnly(e: NutritionEntryShape): boolean {
  return e.foods === WATER_FOODS_MARKER
      && e.waterMl > 0
      && e.proteinG === 0
      && e.fatG === 0
      && e.carbsG === 0;
}

async function queryNutritionRange(client: CloudKitClient, from: string, to: string, tz: string, limit = 500) {
  return client.queryRecords({
    recordType: "NutritionEntry",
    filterBy: [
      { fieldName: "loggedAt", comparator: "GREATER_THAN_OR_EQUALS", fieldValue: { value: startOfDayEpochMs(from, tz) } },
      { fieldName: "loggedAt", comparator: "LESS_THAN_OR_EQUALS",    fieldValue: { value: endOfDayEpochMs(to, tz) } },
    ],
    sortBy: [{ fieldName: "loggedAt", ascending: false }],
    resultsLimit: limit,
  });
}

// ---- Implementations ----

export async function logHydration(client: CloudKitClient, input: LogHydrationInput) {
  const id = newUUID();
  const loggedAt = input.loggedAt ? new Date(input.loggedAt).getTime() : Date.now();

  // Write the same shape iOS does: water-only NutritionEntry with
  // emoji 💧, foods="Water", waterMl set, macros at 0. Source registers
  // the field via the gateway's fallback (mcp tag if available).
  const fields: Record<string, { value: unknown }> = {
    loggedAt: { value: loggedAt },
    foods:    { value: WATER_FOODS_MARKER },
    emoji:    { value: "💧" },
    waterMl:  { value: input.ml },
    proteinG: { value: 0 },
    fatG:     { value: 0 },
    carbsG:   { value: 0 },
    source:   { value: "mcp" },
  };
  if (input.note) fields.note = { value: input.note };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "NutritionEntry",
    recordName: `nutrition-entry:${id}`,
    fields,
    // waterMl is the load-bearing field for hydration — must not be dropped.
    // loggedAt/foods are also required by Nutrition schema.
    protectedFields: ["loggedAt", "foods", "waterMl", "proteinG", "fatG", "carbsG"],
  });

  return droppedFields.length > 0
    ? { id, ml: input.ml, loggedAt: new Date(loggedAt).toISOString(), droppedFields }
    : { id, ml: input.ml, loggedAt: new Date(loggedAt).toISOString() };
}

export async function hydrationToday(client: CloudKitClient) {
  const tz = await getEffectiveTimezone(client);
  const today = todayYMD(tz);
  const res = await queryNutritionRange(client, today, today, tz, 200);

  let totalMl = 0;
  const waterOnly: Array<{ id: string; ml: number; loggedAt: string; note?: string }> = [];

  for (const r of res.records) {
    const e: NutritionEntryShape = {
      loggedAt: typeof r.fields.loggedAt?.value === "number" ? (r.fields.loggedAt.value as number) : 0,
      foods:    optStr(r.fields.foods?.value) ?? "",
      waterMl:  optNum(r.fields.waterMl?.value) ?? 0,
      proteinG: optNum(r.fields.proteinG?.value) ?? 0,
      fatG:     optNum(r.fields.fatG?.value) ?? 0,
      carbsG:   optNum(r.fields.carbsG?.value) ?? 0,
    };
    totalMl += e.waterMl;
    if (isHydrationOnly(e)) {
      waterOnly.push({
        id:       r.recordName.replace(/^nutrition-entry:/, ""),
        ml:       e.waterMl,
        loggedAt: new Date(e.loggedAt).toISOString(),
        note:     optStr(r.fields.note?.value),
      });
    }
  }

  return { date: today, totalMl, entries: waterOnly };
}

export async function hydrationHistory(client: CloudKitClient, input: HydrationHistoryInput) {
  const tz = await getEffectiveTimezone(client);
  const to   = input.to ?? todayYMD(tz);
  const from = input.from ?? ymdNDaysAgo((input.days ?? 7) - 1, tz);

  const res = await queryNutritionRange(client, from, to, tz, 1000);

  // Bucket by day. Total includes water from ALL nutrition entries —
  // a meal that recorded waterMl contributes to its day's hydration total.
  const byDay = new Map<string, { totalMl: number; waterOnlyCount: number }>();

  for (const r of res.records) {
    const loggedAt = typeof r.fields.loggedAt?.value === "number" ? (r.fields.loggedAt.value as number) : 0;
    if (!loggedAt) continue;
    const day = ymdFromEpochMs(loggedAt, tz);
    const e: NutritionEntryShape = {
      loggedAt,
      foods:    optStr(r.fields.foods?.value) ?? "",
      waterMl:  optNum(r.fields.waterMl?.value) ?? 0,
      proteinG: optNum(r.fields.proteinG?.value) ?? 0,
      fatG:     optNum(r.fields.fatG?.value) ?? 0,
      carbsG:   optNum(r.fields.carbsG?.value) ?? 0,
    };
    if (e.waterMl <= 0) continue;
    const cur = byDay.get(day) ?? { totalMl: 0, waterOnlyCount: 0 };
    cur.totalMl += e.waterMl;
    if (isHydrationOnly(e)) cur.waterOnlyCount += 1;
    byDay.set(day, cur);
  }

  // Emit one row per day in the range, including zero days for visibility.
  // Step calendar dates directly (DST-safe) rather than fixed-ms epoch hops.
  const days: Array<{ date: string; totalMl: number; waterOnlyCount: number }> = [];
  for (let day = from; day <= to; day = addDaysYMD(day, 1)) {
    const cur = byDay.get(day) ?? { totalMl: 0, waterOnlyCount: 0 };
    days.push({ date: day, totalMl: cur.totalMl, waterOnlyCount: cur.waterOnlyCount });
  }

  return { from, to, days };
}
