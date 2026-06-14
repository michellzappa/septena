import type { CloudKitClient } from "../cloudkit.js";
import { getEffectiveTimezone, todayYMD } from "../tz.js";

// Ported from /Users/mz/Dev/septena-mcp/src/tools/listTasks.ts.
// Single source of truth for tool definitions can come later once a 3rd
// shared package exists; for now, mirror.

export type TaskView =
  | "today" | "triage" | "inbox" | "anytime" | "someday" | "upcoming" | "completed";

export const listTasksJsonSchema = {
  type: "object",
  properties: {
    view: {
      type: "string",
      enum: ["today", "triage", "inbox", "anytime", "someday", "upcoming", "completed"],
      default: "today",
      description:
        "Which task list to read. 'today' = ratified + due. 'triage' = the to-sort pile shown above Today: unratified rows the user hasn't placed (your unacknowledged proposals + their loose captures); 'today' excludes these.",
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

interface TaskOut {
  id: string;
  title: string;
  status: string;
  today: boolean;
  scheduled?: string;
  deadline?: string;
  area?: string;
  project?: string;
  completedAt?: string;
  // Provenance + freshness cue — needed to compute the triage band (and to
  // keep "today" excluding unratified rows). See iOS SeptenaTask.isInTriageBand.
  source?: string;
  acknowledgedAt?: number; // ms epoch; present once the user has engaged the row
  createdAt?: number;      // ms epoch
}

// Agent-cue decay window — keep in lockstep with iOS AgentCue.decayWindow (7d).
const CUE_DECAY_MS = 7 * 24 * 60 * 60 * 1000;

export async function listTasks(
  client: CloudKitClient,
  input: ListTasksInput,
): Promise<{ tasks: TaskOut[]; total: number; truncated: boolean }> {
  const view = input.view ?? "today";
  const limit = input.limit ?? 100;

  // CKQuery can express EQUALS but not OR-unions or IS-NULL. iOS's
  // Today view is (today=true OR scheduled<=today OR due<=today) and
  // Inbox is "no area, project, scheduled, due, today" — neither
  // expressible server-side. So for these views we fetch the full open-
  // task population and filter client-side using iOS's rules (see
  // Persistence.swift LocalCache.tasks(filter:)).
  const needsClientFilter =
    view === "today" || view === "triage" || view === "inbox" || view === "upcoming";
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
    source: optionalString(r.fields.source?.value),
    acknowledgedAt: optionalNumber(r.fields.acknowledgedAt?.value),
    createdAt: optionalNumber(r.fields.createdAt?.value),
  }));

  // Truncation signal so a caller knows there's more beyond `limit` (the
  // classic "I scanned `completed` to 400, missed #481, concluded deleted"
  // misread). For client-filtered views we hold the whole filtered set, so
  // `total` is exact. For capped views CloudKit's continuationMarker tells us
  // definitively whether more rows exist past the page; `total` there is the
  // count returned (≥ when truncated, exact when not).
  let truncated: boolean;
  let total: number;
  if (needsClientFilter) {
    const tz = await getEffectiveTimezone(client);
    const todayStr = todayYMD(tz);
    const nowMs = Date.now();
    const matched = tasks.filter((t) => matchesView(t, view, todayStr, nowMs));
    total = matched.length;
    truncated = matched.length > limit;
    tasks = matched.slice(0, limit);
  } else {
    truncated = !!res.continuationMarker;
    total = tasks.length;
  }
  return { tasks, total, truncated };
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function optionalNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

/// Mirrors iOS TaskEntity.isInTriageBand — the unratified layer above Today.
/// Agent arm: an unacknowledged MCP-authored row still inside the freshness
/// window (reuses the agent-cue, so cue-decay = ratification-by-timeout).
/// Human arm: a loose capture with no disposition at all (the classic Inbox).
function inTriageBand(t: TaskOut, nowMs: number): boolean {
  if (t.status !== "open") return false;
  if (t.source === "mcp") {
    if (t.acknowledgedAt) return false;
    if (!t.createdAt) return false;
    return nowMs - t.createdAt < CUE_DECAY_MS;
  }
  return !t.today && !t.area && !t.project && !t.scheduled && !t.deadline;
}

/// Mirrors Persistence.swift LocalCache.tasks(filter:). Keep in lockstep
/// with iOS so the two surfaces never disagree on what "Today" means.
function matchesView(t: TaskOut, view: TaskView, today: string, nowMs: number): boolean {
  if (t.status !== "open") return false;
  switch (view) {
    case "today":
      // Ratified + due — the triage band (unratified) is excluded.
      if (inTriageBand(t, nowMs)) return false;
      return t.today || (!!t.scheduled && t.scheduled <= today) || (!!t.deadline && t.deadline <= today);
    case "triage":
      return inTriageBand(t, nowMs);
    case "inbox":
      return !t.today && !t.area && !t.project && !t.scheduled && !t.deadline;
    case "upcoming":
      if (t.today) return false;
      return (!!t.scheduled && t.scheduled > today) || (!!t.deadline && t.deadline > today);
    default:
      return true;
  }
}

function filtersForView(view: TaskView) {
  if (view === "completed") {
    return [{ fieldName: "status", comparator: "EQUALS" as const, fieldValue: { value: "done" } }];
  }
  return [{ fieldName: "status", comparator: "EQUALS" as const, fieldValue: { value: "open" } }];
}
