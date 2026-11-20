import type { CloudKitClient } from "../cloudkit.js";

export const getSettingsJsonSchema = {
  type: "object",
  properties: {},
} as const;

export interface GetSettingsResult {
  settings: Record<string, unknown>;
}

interface CKLookupResponse {
  records: Array<{
    recordName: string;
    fields?: Record<string, { value: unknown }>;
    serverErrorCode?: string;
  }>;
}

export async function getSettings(client: CloudKitClient): Promise<GetSettingsResult> {
  const res = await client.post<CKLookupResponse>("records/lookup", {
    zoneID: { zoneName: client.zoneName },
    records: [{ recordName: "app" }],
  });
  const record = res.records[0];
  if (!record || record.serverErrorCode === "NOT_FOUND") {
    return { settings: {} };
  }
  const payload = record.fields?.payloadJSON?.value;
  if (typeof payload !== "string" || payload.length === 0) {
    return { settings: {} };
  }
  try {
    return { settings: JSON.parse(payload) as Record<string, unknown> };
  } catch {
    return { settings: {} };
  }
}
