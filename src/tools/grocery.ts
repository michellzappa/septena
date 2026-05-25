import type { CloudKitClient } from "../cloudkit.js";

const SHORTID_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";
function newId(len = 4): string {
  const buf = new Uint8Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => SHORTID_ALPHABET[b & 31]).join("");
}

function todayYMD(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function optStr(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
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

// ---- GroceryItem ----

export const listGroceryItemsJsonSchema = {
  type: "object",
  properties: {
    low:      { type: "boolean", description: "Filter to items marked low. Omit for all." },
    category: { type: "string", description: "Filter by GroceryCategory id." },
    limit:    { type: "integer", default: 300 },
  },
} as const;

export const createGroceryItemJsonSchema = {
  type: "object",
  required: ["name", "category"],
  properties: {
    name:     { type: "string" },
    category: { type: "string", description: "GroceryCategory id (resolve via grocery_categories_list)." },
    emoji:    { type: "string" },
  },
} as const;

export const updateGroceryItemJsonSchema = {
  type: "object", required: ["id"],
  properties: {
    id:         { type: "string" },
    name:       { type: "string" },
    category:   { type: "string" },
    emoji:      { type: "string" },
    low:        { type: "boolean", description: "Marked-low flag. Use grocery_item_set_low for the day-to-day workflow." },
    lastBought: { type: ["string", "null"], description: "YYYY-MM-DD or null to clear." },
  },
} as const;

export const setGroceryLowJsonSchema = {
  type: "object", required: ["id", "low"],
  properties: {
    id:  { type: "string", description: "GroceryItem id." },
    low: { type: "boolean", description: "true = mark out/low; false = restock (auto-stamps lastBought=today)." },
  },
} as const;

export const deleteGroceryItemJsonSchema = {
  type: "object", required: ["id"],
  properties: { id: { type: "string" } },
} as const;

// ---- GroceryCategory ----

export const listGroceryCategoriesJsonSchema = {
  type: "object",
  properties: { limit: { type: "integer", default: 100 } },
} as const;

export const createGroceryCategoryJsonSchema = {
  type: "object", required: ["name"],
  properties: { name: { type: "string" } },
} as const;

export const deleteGroceryCategoryJsonSchema = {
  type: "object", required: ["id"],
  properties: { id: { type: "string" } },
} as const;

// ============================================================================
// Types
// ============================================================================

export interface ListGroceryItemsInput { low?: boolean; category?: string; limit?: number }
export interface CreateGroceryItemInput { name: string; category: string; emoji?: string }
export interface UpdateGroceryItemInput { id: string; name?: string; category?: string; emoji?: string; low?: boolean; lastBought?: string | null }
export interface SetGroceryLowInput { id: string; low: boolean }
export interface ListGroceryCategoriesInput { limit?: number }
export interface CreateGroceryCategoryInput { name: string }

// ============================================================================
// GroceryItem implementations
// ============================================================================

export async function listGroceryItems(client: CloudKitClient, input: ListGroceryItemsInput) {
  const filters: Array<{ fieldName: string; comparator: string; fieldValue: { value: unknown } }> = [];
  if (input.low !== undefined) {
    filters.push({ fieldName: "low", comparator: "EQUALS", fieldValue: { value: input.low ? 1 : 0 } });
  }
  if (input.category) {
    filters.push({ fieldName: "category", comparator: "EQUALS", fieldValue: { value: input.category } });
  }

  const res = await client.queryRecords({
    recordType: "GroceryItem",
    filterBy: filters.length ? (filters as never) : undefined,
    sortBy: [{ fieldName: "sortIndex", ascending: true }],
    resultsLimit: input.limit ?? 300,
  });

  const items = res.records.map((r) => ({
    id:         r.recordName.replace(/^grocery-item:/, ""),
    name:       optStr(r.fields.name?.value) ?? "",
    category:   optStr(r.fields.category?.value) ?? "",
    emoji:      optStr(r.fields.emoji?.value) ?? "",
    low:        ((r.fields.low?.value as number) ?? 0) !== 0,
    lastBought: optStr(r.fields.lastBought?.value),
    sortIndex:  (r.fields.sortIndex?.value as number) ?? 0,
  }));

  return { items };
}

export async function createGroceryItem(client: CloudKitClient, input: CreateGroceryItemInput) {
  const id = newId(4);
  const fields: Record<string, { value: unknown }> = {
    name:      { value: input.name },
    category:  { value: input.category },
    emoji:     { value: input.emoji ?? "" },
    low:       { value: 0 },
    sortIndex: { value: 0 },
  };

  const { droppedFields } = await client.createWithFieldFallback({
    recordType: "GroceryItem",
    recordName: `grocery-item:${id}`,
    fields,
    protectedFields: ["name", "category"],
  });

  return droppedFields.length > 0
    ? { id, name: input.name, category: input.category, droppedFields }
    : { id, name: input.name, category: input.category };
}

export async function updateGroceryItem(client: CloudKitClient, input: UpdateGroceryItemInput) {
  const fields: Record<string, { value: unknown }> = {};
  const updated: string[] = [];
  if (input.name !== undefined)       { fields.name       = { value: input.name }; updated.push("name"); }
  if (input.category !== undefined)   { fields.category   = { value: input.category }; updated.push("category"); }
  if (input.emoji !== undefined)      { fields.emoji      = { value: input.emoji }; updated.push("emoji"); }
  if (input.low !== undefined)        { fields.low        = { value: input.low ? 1 : 0 }; updated.push("low"); }
  if (input.lastBought !== undefined) { fields.lastBought = { value: input.lastBought ?? "" }; updated.push("lastBought"); }

  if (!updated.length) return { id: input.id, updated: [] };

  const res = await modify(client, [{
    operationType: "forceUpdate",
    record: { recordType: "GroceryItem", recordName: `grocery-item:${input.id}`, fields },
  }]);
  const code = res.records[0]?.serverErrorCode;
  if (code) throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id, updated };
}

/// Convenience: the most common grocery workflow. `low=true` marks the
/// item as out / running low. `low=false` clears the flag and stamps
/// lastBought to today (restock signal).
export async function setGroceryLow(client: CloudKitClient, input: SetGroceryLowInput) {
  const fields: Record<string, { value: unknown }> = {
    low: { value: input.low ? 1 : 0 },
  };
  if (!input.low) {
    // Restocked. lastBought=today is the conventional signal.
    fields.lastBought = { value: todayYMD() };
  }
  const res = await modify(client, [{
    operationType: "forceUpdate",
    record: { recordType: "GroceryItem", recordName: `grocery-item:${input.id}`, fields },
  }]);
  const code = res.records[0]?.serverErrorCode;
  if (code) throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id, low: input.low, ...(input.low ? {} : { lastBought: todayYMD() }) };
}

export async function deleteGroceryItem(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `grocery-item:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}

// ============================================================================
// GroceryCategory implementations
// ============================================================================

export async function listGroceryCategories(client: CloudKitClient, input: ListGroceryCategoriesInput) {
  const res = await client.queryRecords({
    recordType: "GroceryCategory",
    sortBy: [{ fieldName: "sortIndex", ascending: true }],
    resultsLimit: input.limit ?? 100,
  });
  const categories = res.records.map((r) => ({
    id:        r.recordName.replace(/^grocery-cat:/, ""),
    name:      optStr(r.fields.name?.value) ?? "",
    sortIndex: (r.fields.sortIndex?.value as number) ?? 0,
  }));
  return { categories };
}

export async function createGroceryCategory(client: CloudKitClient, input: CreateGroceryCategoryInput) {
  const id = newId(4);
  const res = await modify(client, [{
    operationType: "create",
    record: {
      recordType: "GroceryCategory",
      recordName: `grocery-cat:${id}`,
      fields: { name: { value: input.name }, sortIndex: { value: 0 } },
    },
  }]);
  const code = res.records[0]?.serverErrorCode;
  if (code) throw new Error(res.records[0]?.reason ?? code);
  return { id, name: input.name };
}

export async function deleteGroceryCategory(client: CloudKitClient, input: { id: string }) {
  const res = await modify(client, [{ operationType: "delete", record: { recordName: `grocery-cat:${input.id}` } }]);
  const code = res.records[0]?.serverErrorCode;
  if (code && code !== "NOT_FOUND") throw new Error(res.records[0]?.reason ?? code);
  return { id: input.id };
}
