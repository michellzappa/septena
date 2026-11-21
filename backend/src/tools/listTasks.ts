import type { CloudKitClient } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD } from "../tz.js";
import { annotate, inboxFirst, matchesView, normalizeView, type TaskOut, type TaskView } from "./taskShared.js";

// Ported from /Users/mz/Dev/septena-mcp/src/tools/listTasks.ts.
// Single source of truth for tool definitions can come later once a 3rd
// shared package exists; for now, mirror.

export type { TaskView } from "./taskShared.js";

export const listTasksJsonSchema = {
  type: "object",
  properties: {
    view: {
      type: "string",
      enum: ["today", "inbox", "anytime", "upcoming", "completed"],
      default: "today",
      description:
        "Which task list to read. 'today' = the whole Today page as the app shows it: the Inbox section first, then every task due today. 'inbox' = only the Inbox section: tasks the user has not filed yet (no area or project) and your proposals they have not accepted. 'anytime' is the single home for open, dateless tasks. Rows carry `inbox: true` when they sit in the Inbox, and `daysOnToday: N` when they have carried over on Today undone for N days (the app darkens their checkbox; 7+ is long overdue for a decision).",
    },
    limit: {
      type: "integer",
      minimum: 1,
      maximum: 500,
      default: 100,
    },
  },
} as const;

export interface ListTasksInput {
  view?: TaskView;
  limit?: number;
}

/** Reads the three CloudKit recurrence columns back into the wire shape. */
function recurrenceOut(
  fields: Record<string, { value: unknown } | undefined>,
): { unit: string; interval: number; after_completion: boolean } | undefined {
  const unit = optionalString(fields.recurrenceUnit?.value);
  if (!unit) return undefined;
  return {
    unit,
    interval: Number(fields.recurrenceInterval?.value ?? 1) || 1,
    after_completion: Number(fields.recurrenceAfterCompletion?.value ?? 1) !== 0,
  };
}

export async function listTasks(
  client: CloudKitClient,
  input: ListTasksInput,
): Promise<{ tasks: TaskOut[]; total: number; truncated: boolean }> {
  // "someday" is the retired bucket — accepted as an alias for "anytime".
  const view = normalizeView(input.view);
  const limit = input.limit ?? 100;

  // CKQuery can express EQUALS but not OR-unions or IS-NULL. iOS's
  // Today view is (today=true OR scheduled<=today OR deadline<=today) and
  // Inbox is "no area, project, scheduled, deadline, today" — neither
  // expressible server-side. So for these views we fetch the full open-
  // task population and filter client-side using iOS's rules (see
  // Persistence.swift LocalCache.tasks(filter:)).
  const needsClientFilter =
    view === "today" || view === "inbox" || view === "upcoming";
  // These views are filtered client-side (today/inbox/upcoming aren't
  // expressible as one CK query), and the matching tasks often have NO
  // `scheduled` value (inbox items, today-flagged) so they sort unpredictably.
  // A capped fetch could leave them outside the page → missing tasks. Pull the
  // full open-task set, then filter and slice to `limit`.
  const res = await client.queryRecords({
    recordType: "Task",
    filterBy: filtersForView(view),
    sortBy:
      view === "completed"
        ? [{ fieldName: "completedAt", ascending: false }]
        : [{ fieldName: "scheduled", ascending: true }],
    ...(needsClientFilter ? { fetchAll: true } : { resultsLimit: limit }),
  });

  let tasks: TaskOut[] = res.records.map((r) => ({
    id: r.recordName,
    title: (r.fields.title?.value as string) ?? "",
    status: (r.fields.status?.value as string) ?? "open",
    today: ((r.fields.today?.value as number) ?? 0) !== 0,
    scheduled: optionalString(r.fields.scheduled?.value),
    deadline: optionalString(r.fields.deadline?.value),
    area: optionalString(r.fields.area?.value),
    project: optionalString(r.fields.project?.value),
    completedAt: optionalString(r.fields.completedAt?.value),
    notes: optionalString(r.fields.notesText?.value),
    created: optionalString(r.fields.created?.value),
    todaySetOn: optionalString(r.fields.todaySetOn?.value),
    source: optionalString(r.fields.source?.value),
    acknowledgedAt: optionalNumber(r.fields.acknowledgedAt?.value),
    createdAt: optionalNumber(r.fields.createdAt?.value),
    kind: optionalString(r.fields.kind?.value),
    recurrence: recurrenceOut(r.fields),
    touchedAt: optionalIsoTimestamp(r.fields.touchedAt?.value),
    deferCount: optionalPositiveInt(r.fields.deferCount?.value),
    fadedAt: optionalIsoTimestamp(r.fields.fadedAt?.value),
    dropReason: optionalString(r.fields.dropReason?.value),
    effort: optionalString(r.fields.effort?.value),
  }));

  // Project headings (section dividers) are not to-dos — drop them from every
  // view here, the single chokepoint (mirrors iOS LocalCache.convert). This
  // also covers the non-client-filtered views ("anytime"/"completed"), whose
  // capped fetch would otherwise leak an open, dateless heading row.
  tasks = tasks.filter((t) => t.kind !== "heading");

  // Truncation signal so a caller knows there's more beyond `limit` (the
  // classic "I scanned `completed` to 400, missed #481, concluded deleted"
  // misread). For client-filtered views we hold the whole filtered set, so
  // `total` is exact. For capped views CloudKit's continuationMarker tells us
  // definitively whether more rows exist past the page; `total` there is the
  // count returned (≥ when truncated, exact when not).
  let truncated: boolean;
  let total: number;
  const tz = await getEffectiveTimezone(client);
  const todayStr = todayYMD(tz);
  const nowMs = Date.now();
  if (needsClientFilter) {
    let matched = tasks.filter((t) => matchesView(t, view, todayStr, nowMs));
    if (view === "today") matched = inboxFirst(matched, todayStr, nowMs);
    total = matched.length;
    truncated = matched.length > limit;
    tasks = matched.slice(0, limit);
  } else {
    truncated = !!res.continuationMarker;
    total = tasks.length;
  }
  // `created` / `todaySetOn` only feed `daysOnToday`; not part of the result.
  tasks = tasks.map((t) => {
    const { created: _c, todaySetOn: _t, ...out } = annotate(t, todayStr, nowMs);
    return out;
  });
  return { tasks, total, truncated };
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function optionalNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function optionalPositiveInt(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined;
}

function optionalIsoTimestamp(value: unknown): string | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return new Date(value).toISOString();
  return optionalString(value);
}

function filtersForView(view: TaskView) {
  if (view === "completed") {
    return [{ fieldName: "status", comparator: "EQUALS" as const, fieldValue: { value: "done" } }];
  }
  return [{ fieldName: "status", comparator: "EQUALS" as const, fieldValue: { value: "open" } }];
}
