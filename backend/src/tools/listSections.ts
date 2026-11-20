import type { CloudKitClient } from "../cloudkit.js";
import { getSettings } from "./getSettings.js";

export const listSectionsJsonSchema = {
  type: "object",
  properties: {
    limit: { type: "integer", minimum: 1, maximum: 500, default: 100 },
  },
} as const;

export interface ListSectionsInput {
  limit?: number;
}

interface SectionOut {
  key: string;
  label: string;
  color: string;
  /// Mirrors `SectionEntity.isEnabled` written by the iOS app. Records
  /// from older builds may not carry this field — treat missing as
  /// true so legacy users see all their tools.
  isEnabled: boolean;
  /// Mirrors `SectionEntity.showInToday`. Not currently used by the
  /// MCP gateway (it filters tool exposure, not Today-log surfaces)
  /// but surfaced here so future tools can read the user's intent.
  showInToday: boolean;
}

export async function listSections(
  client: CloudKitClient,
  input: ListSectionsInput,
): Promise<{ sections: SectionOut[] }> {
  const [settingsResult, res] = await Promise.all([
    getSettings(client),
    client.queryRecords({
      recordType: "Section",
      filterBy: [
        { fieldName: "title", comparator: "BEGINS_WITH", fieldValue: { value: "" } },
      ],
      resultsLimit: input.limit ?? 100,
    }),
  ]);

  const sections = res.records.map((r): SectionOut => {
    const enabledRaw = r.fields.isEnabled?.value;
    const showRaw = r.fields.showInToday?.value;
    return {
      key: r.recordName.startsWith("section:") ? r.recordName.slice(8) : r.recordName,
      label: (r.fields.title?.value as string) ?? "",
      color: (r.fields.color?.value as string) ?? "",
      isEnabled: typeof enabledRaw === "number" ? enabledRaw !== 0 : true,
      showInToday: typeof showRaw === "number" ? showRaw !== 0 : true,
    };
  });

  const order = Array.isArray(settingsResult.settings.section_order)
    ? settingsResult.settings.section_order.filter((v): v is string => typeof v === "string")
    : [];
  if (order.length === 0) return { sections };

  const rank = new Map(order.map((key, index) => [key, index]));
  sections.sort((a, b) => {
    const aRank = rank.get(a.key);
    const bRank = rank.get(b.key);
    if (aRank != null && bRank != null) return aRank - bRank;
    if (aRank != null) return -1;
    if (bRank != null) return 1;
    return a.label.localeCompare(b.label, undefined, { sensitivity: "base" });
  });
  return { sections };
}
