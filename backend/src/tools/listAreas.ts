import type { CloudKitClient } from "../cloudkit.js";

export const listAreasJsonSchema = {
  type: "object",
  properties: {
    limit: { type: "integer", minimum: 1, maximum: 500, default: 100 },
  },
} as const;

export interface ListAreasInput {
  limit?: number;
}

interface AreaOut {
  id: string;
  title: string;
  context?: string;
}

export async function listAreas(
  client: CloudKitClient,
  input: ListAreasInput,
): Promise<{ areas: AreaOut[] }> {
  // dev-env schema doesn't mark ___createTime queryable on Area, so use
  // `title BEGINS_WITH ""` which matches every record with a title.
  const res = await client.queryRecords({
    recordType: "Area",
    filterBy: [
      { fieldName: "title", comparator: "BEGINS_WITH", fieldValue: { value: "" } },
    ],
    resultsLimit: input.limit ?? 100,
  });

  const areas = res.records.map((r): AreaOut => ({
    // Strip the "area:" recordName prefix so the id matches what tasks
    // store in their `area` FK field. The iOS app uses the unprefixed
    // form everywhere; returning the prefixed recordName here would cause
    // round-trips through writeTasks to write a dangling reference.
    id: r.recordName.startsWith("area:") ? r.recordName.slice(5) : r.recordName,
    title: (r.fields.title?.value as string) ?? "",
    context: optionalString(r.fields.context?.value),
  }));
  return { areas };
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
