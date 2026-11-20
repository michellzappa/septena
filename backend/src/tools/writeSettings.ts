import type { CloudKitClient } from "../cloudkit.js";

interface CKLookupResponse {
  records: Array<{
    recordName: string;
    fields?: Record<string, { value: unknown }>;
    serverErrorCode?: string;
  }>;
}

interface CKModifyResponse {
  records: Array<{
    recordName: string;
    serverErrorCode?: string;
    reason?: string;
  }>;
}

const SECTION_KEY_ALIASES: Record<string, string> = {
  exercise: "training",
};

export const updateSettingsJsonSchema = {
  type: "object",
  required: ["patch"],
  properties: {
    patch: {
      type: "object",
      description: "Partial settings object to merge into the CloudKit settings singleton.",
    },
  },
} as const;

export interface UpdateSettingsInput {
  patch: Record<string, unknown>;
}

export const updateSectionJsonSchema = {
  type: "object",
  required: ["key"],
  properties: {
    key: { type: "string", description: "Section key, e.g. tasks or training." },
    label: { type: "string" },
    color: { type: "string", description: "Hex or hsl/rgb string." },
    order: { type: "integer", minimum: 0, description: "Move this section to the given index in settings.section_order." },
  },
} as const;

export interface UpdateSectionInput {
  key: string;
  label?: string;
  color?: string;
  order?: number;
}

function canonicalSectionKey(value: unknown): string {
  const key = String(value ?? "").trim();
  return SECTION_KEY_ALIASES[key] ?? key;
}

function canonicalizeSectionOrder(value: unknown): unknown {
  if (!Array.isArray(value)) return value;
  const out: string[] = [];
  const seen = new Set<string>();
  for (const item of value) {
    const key = canonicalSectionKey(item);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(key);
  }
  return out;
}

function canonicalizeSettingsPatch(input: Record<string, unknown>): Record<string, unknown> {
  const patch = { ...input };
  if ("sections" in patch) {
    throw new Error("settings.sections is no longer written through settings_update; use sections_update instead.");
  }
  if (patch.theme === "eink") {
    patch.theme = "system";
    if (!("eink" in patch)) patch.eink = true;
  }
  if ("section_order" in patch) {
    patch.section_order = canonicalizeSectionOrder(patch.section_order);
  }
  return patch;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function deepMerge(base: Record<string, unknown>, patch: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...base };
  for (const [key, value] of Object.entries(patch)) {
    if (isPlainObject(value) && isPlainObject(out[key])) {
      out[key] = deepMerge(out[key] as Record<string, unknown>, value);
    } else {
      out[key] = value;
    }
  }
  return out;
}

async function lookupSettingsPayload(client: CloudKitClient): Promise<Record<string, unknown>> {
  const res = await client.post<CKLookupResponse>("records/lookup", {
    zoneID: { zoneName: client.zoneName },
    records: [{ recordName: "app" }],
  });
  const record = res.records[0];
  if (!record || record.serverErrorCode === "NOT_FOUND") return {};
  const payload = record.fields?.payloadJSON?.value;
  if (typeof payload !== "string" || payload.length === 0) return {};
  try {
    const parsed = JSON.parse(payload) as unknown;
    return isPlainObject(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

async function saveSettingsPayload(client: CloudKitClient, payload: Record<string, unknown>) {
  const res = await client.post<CKModifyResponse>("records/modify", {
    zoneID: { zoneName: client.zoneName },
    operations: [{
      operationType: "forceUpdate",
      record: {
        recordType: "Settings",
        recordName: "app",
        fields: {
          payloadJSON: { value: JSON.stringify(payload) },
          updatedAt: { value: new Date().toISOString() },
        },
      },
    }],
  });
  const record = res.records[0];
  if (!record || record.serverErrorCode) {
    throw new Error(record?.reason || record?.serverErrorCode || "Settings update failed");
  }
}

async function lookupSectionFields(
  client: CloudKitClient,
  key: string,
): Promise<Record<string, { value: unknown }> | null> {
  const recordName = `section:${key}`;
  const res = await client.post<CKLookupResponse>("records/lookup", {
    zoneID: { zoneName: client.zoneName },
    records: [{ recordName }],
  });
  const record = res.records[0];
  if (!record || record.serverErrorCode === "NOT_FOUND") return null;
  return record.fields ?? {};
}

function moveSectionInOrder(order: string[], key: string, index: number): string[] {
  const withoutKey = order.filter((item) => item !== key);
  const boundedIndex = Math.max(0, Math.min(index, withoutKey.length));
  withoutKey.splice(boundedIndex, 0, key);
  return withoutKey;
}

export async function updateSettings(
  client: CloudKitClient,
  input: UpdateSettingsInput,
): Promise<{ settings: Record<string, unknown> }> {
  if (!isPlainObject(input.patch)) {
    throw new Error("settings_update.patch must be a JSON object");
  }
  const existing = await lookupSettingsPayload(client);
  const merged = deepMerge(existing, canonicalizeSettingsPatch(input.patch));
  await saveSettingsPayload(client, merged);
  return { settings: merged };
}

export async function updateSection(
  client: CloudKitClient,
  input: UpdateSectionInput,
): Promise<{ section: { key: string; label: string; color: string }; order?: string[] }> {
  const key = canonicalSectionKey(input.key);
  if (!key) throw new Error("sections_update.key is required");

  const existing = await lookupSectionFields(client, key);
  const label = input.label ?? (existing?.title?.value as string | undefined) ?? key;
  const color = input.color ?? (existing?.color?.value as string | undefined) ?? "";

  const sectionWrite = client.post<CKModifyResponse>("records/modify", {
    zoneID: { zoneName: client.zoneName },
    operations: [{
      operationType: existing ? "forceUpdate" : "create",
      record: {
        recordType: "Section",
        recordName: `section:${key}`,
        fields: {
          title: { value: label },
          color: { value: color },
          updatedAt: { value: new Date().toISOString() },
        },
      },
    }],
  });

  let order: string[] | undefined;
  let settingsWrite: Promise<void> | undefined;
  if (input.order !== undefined) {
    const settings = await lookupSettingsPayload(client);
    const current = Array.isArray(settings.section_order)
      ? (canonicalizeSectionOrder(settings.section_order) as string[])
      : [];
    order = moveSectionInOrder(current, key, input.order);
    settings.section_order = order;
    settingsWrite = saveSettingsPayload(client, settings);
  }

  const sectionResult = await sectionWrite;
  const sectionRecord = sectionResult.records[0];
  if (!sectionRecord || sectionRecord.serverErrorCode) {
    throw new Error(sectionRecord?.reason || sectionRecord?.serverErrorCode || "Section update failed");
  }
  if (settingsWrite) await settingsWrite;

  return {
    section: { key, label, color },
    ...(order ? { order } : {}),
  };
}
