import type { CloudKitClient } from "../cloudkit.js";

export const listProjectsJsonSchema = {
  type: "object",
  properties: {
    status: { type: "string", enum: ["active", "done", "cancelled", "all"], default: "active" },
    limit: { type: "integer", minimum: 1, maximum: 500, default: 200 },
  },
} as const;

export interface ListProjectsInput {
  status?: "active" | "done" | "cancelled" | "all";
  limit?: number;
}

interface ProjectOut {
  id: string;
  title: string;
  status: string;
  area?: string;
  notes?: string;
  context?: string;
  githubRepo?: string;
  completedAt?: string;
}

export async function listProjects(
  client: CloudKitClient,
  input: ListProjectsInput,
): Promise<{ projects: ProjectOut[] }> {
  const status = input.status ?? "active";
  const limit = input.limit ?? 200;

  // CloudKit requires at least one filter or it rejects with "recordName
  // is not marked queryable". ___createTime isn't queryable on every
  // record type — match-all on `title BEGINS_WITH ""` is the proven
  // pattern (also used by listAreas/listSections).
  const filterBy =
    status === "all"
      ? [{ fieldName: "title", comparator: "BEGINS_WITH" as const, fieldValue: { value: "" } }]
      : [{ fieldName: "status", comparator: "EQUALS" as const, fieldValue: { value: status } }];

  const res = await client.queryRecords({
    recordType: "Project",
    filterBy,
    resultsLimit: limit,
  });

  const projects = res.records.map((r): ProjectOut => ({
    // Strip the "project:" recordName prefix so id matches what tasks
    // store in their `project` FK field. See listAreas.ts for rationale.
    id: r.recordName.startsWith("project:") ? r.recordName.slice(8) : r.recordName,
    title: (r.fields.title?.value as string) ?? "",
    status: (r.fields.status?.value as string) ?? "active",
    area: optionalString(r.fields.area?.value),
    notes: optionalString(r.fields.notesText?.value) ?? optionalString(r.fields.notes?.value),
    context: optionalString(r.fields.context?.value),
    githubRepo: optionalString(r.fields.githubRepo?.value),
    completedAt: optionalString(r.fields.completedAt?.value),
  }));
  return { projects };
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
