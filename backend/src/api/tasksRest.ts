import { Hono, type Context } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { zId } from "../store/columns.js";
import type { Row } from "../store/TaskStore.js";
import { addDaysYMD, isValidTz, todayYMD } from "../tz.js";
import type { TaskOut } from "../tools/taskShared.js";
import { matchesView } from "../tools/taskShared.js";
import { listTasks, taskOut } from "../shadow/mcp.js";
import { MAX_REF_INPUT, findByRef, zRefs } from "../shadow/refs.js";
import { DESIGN_TOKENS } from "../generated/registries.js";
import { AGENT_FALLBACK_NAME, rpcStoreFor, runWriteTool, zWriteArgs, type StoreRpc, type WriteContext, type WriteToolName } from "../shadow/writes.js";

// A small REST surface over the MCP task tools for thin app clients, first of
// all the Apple Watch (docs/WATCH.md in the app repo). The watch has no task
// store of its own: it asks for a ready-made view and sends verbs. Reads and
// writes run the SAME functions the MCP connector uses (`listTasks`,
// `runWriteTool`), so Today on the wrist, in Claude and on the phone cannot
// disagree. Writes are credited to the app (`app:<client>`), never the agent,
// so agent-only rules (human_accepts, stopped) treat them as the human.
//
// Mounted at /v1/tasks behind requireUser + requireSyncEntitlement.

type Vars = { userId: string; actor: string };
type Ctx = Context<{ Bindings: Env; Variables: Vars }>;

export const tasksRest = new Hono<{ Bindings: Env; Variables: Vars }>();

/// The wrist's zone decides "today" (it's the device you're wearing), then the
/// synced `homeTimezone`, then UTC — same fallbacks as the MCP connector.
async function timeZoneFor(c: Ctx, store: StoreRpc): Promise<string> {
  const header = c.req.header("X-Septena-TimeZone");
  if (header && isValidTz(header)) return header;
  const synced = await store.readSetting("homeTimezone");
  if (typeof synced === "string" && isValidTz(synced)) return synced;
  return "UTC";
}

async function writeContext(c: Ctx): Promise<WriteContext> {
  const store = rpcStoreFor(c.env, c.get("userId"));
  const client = c.get("actor").replace(/^app:/, "");
  return {
    store,
    timeZone: await timeZoneFor(c, store),
    actor: c.get("actor"),
    source: { source: "app", sourceClient: client === "unknown" ? "app" : client },
  };
}

/// One task as the watch draws it. Area / project arrive as display names,
/// so the client never needs the container tables.
export interface ClientTask {
  id: string;
  title: string;
  notes?: string;
  scheduled?: string;
  deadline?: string;
  startTime?: string;
  area?: string;
  project?: string;
  inbox?: true;
  repeats?: true;
  starred?: true;
  /// When it was completed (the completed view). Local wall-clock time in the
  /// user's zone, so its first ten characters compare with `today`.
  completedAt?: string;
  daysOnToday?: number;
  checklistCount?: number;
  checklistDoneCount?: number;
  /// How many references the task has (docs/TASK_REFERENCES_SPEC.md).
  refCount?: number;
  /// What the agent said when it handed the task over, and when (the review
  /// view). A task sent back and handed over again has a new `reviewAt`.
  reviewNote?: string;
  reviewAt?: string;
  /// When it was created (ms), and who added it: "You" or the agent's name
  /// (the added view; the same names as the task page's "Added by").
  createdAt?: number;
  addedBy?: "you" | "agent";
  agentName?: string;
}

/// The user's synced accent with its hexes, so a thin client that has no
/// registry (the desk orb) draws in the same color as the apps. Colorful is
/// the default and the fallback for an unknown id.
export function accentFor(setting: unknown): { id: string; light: string; dark: string } {
  const all = DESIGN_TOKENS.fruitAccents;
  const a = all.find((x) => x.id === setting) ?? all.find((x) => x.id === "colorful") ?? all[0];
  return { id: a.id, light: a.light, dark: a.dark };
}

/// No derived "overdue": the client compares `deadline` with the `today` the
/// response carries, so "Due today" and "Overdue" stay distinguishable.
export function clientTask(t: TaskOut, names: Map<string, string>): ClientTask {
  const out: ClientTask = { id: t.id, title: t.title };
  if (t.notes) out.notes = t.notes;
  if (t.scheduled) out.scheduled = t.scheduled;
  if (t.deadline) out.deadline = t.deadline;
  if (t.startTime) out.startTime = t.startTime;
  const area = t.area ? names.get(t.area) : undefined;
  const project = t.project ? names.get(t.project) : undefined;
  if (area) out.area = area;
  if (project) out.project = project;
  if (t.inbox) out.inbox = true;
  if (t.recurrence) out.repeats = true;
  if (t.starred) out.starred = true;
  if (t.completedAt) out.completedAt = t.completedAt;
  if (t.refCount) out.refCount = t.refCount;
  if (t.reviewNote) out.reviewNote = t.reviewNote;
  if (t.reviewAt) out.reviewAt = t.reviewAt;
  if (t.daysOnToday) out.daysOnToday = t.daysOnToday;
  if (t.checklistCount) {
    out.checklistCount = t.checklistCount;
    out.checklistDoneCount = t.checklistDoneCount ?? 0;
  }
  return out;
}

const ADDED_WINDOW_MS = 24 * 60 * 60 * 1000;
const ADDED_MAX = 50;

/// The added view (docs/COMPANION_DEVICES_SPEC.md §6): open tasks that a
/// person or an agent created in the last 24 hours, newest first, wherever
/// they sit. Imports and spawned repeat occurrences are not in it: nobody
/// added those now.
export function addedTasks(rows: Row[], names: Map<string, string>, nowMs: number): { tasks: ClientTask[]; total: number } {
  const str = (v: unknown) => (typeof v === "string" ? v : "");
  const found: { row: Row; at: number }[] = [];
  for (const row of rows) {
    const at = Date.parse(str(row.createdAt));
    if (!Number.isFinite(at) || nowMs - at > ADDED_WINDOW_MS) continue;
    if (row.fadedAt) continue;
    const source = str(row.source);
    if (source === "things" || source.startsWith("import:")) continue;
    const series = str(row.recurrenceSeriesID);
    if (series && series !== row.id) continue;
    // A row with no title yet is being typed on another device.
    if (!str(row.title).trim()) continue;
    found.push({ row, at });
  }
  found.sort((a, b) => b.at - a.at);
  const tasks = found.slice(0, ADDED_MAX).map(({ row, at }) => {
    const out = clientTask(taskOut(row), names);
    delete out.notes;
    out.createdAt = at;
    out.addedBy = row.source === "mcp" ? "agent" : "you";
    if (out.addedBy === "agent") out.agentName = str(row.sourceClient).trim() || AGENT_FALLBACK_NAME;
    return out;
  });
  return { tasks, total: found.length };
}

function containerNames(areas: Row[], projects: Row[]): Map<string, string> {
  const m = new Map<string, string>();
  for (const r of [...areas, ...projects]) {
    if (typeof r.title === "string" && r.title) m.set(r.id as string, r.title);
  }
  return m;
}

const zView = z.enum(["today", "inbox", "upcoming", "repeating", "anytime", "completed", "starred", "review", "added"]);

/// Mirrors `TaskStructureOrder.positionOrdered` in SeptenaCore: positive
/// `position` ascending, unset (`0` / missing) sinks to the bottom, ties break
/// by title (case-insensitive).
function numPos(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) && v > 0 ? v : Number.POSITIVE_INFINITY;
}

function sortByPosition(rows: Row[]): Row[] {
  return rows
    .map((r, i) => ({ r, i, title: typeof r.title === "string" ? r.title : "" }))
    .sort((a, b) =>
      numPos(a.r.position) - numPos(b.r.position)
      || a.title.localeCompare(b.title, undefined, { sensitivity: "base" })
      || a.i - b.i,
    )
    .map((x) => x.r);
}

tasksRest.get("/lists", async (c) => {
  const store = rpcStoreFor(c.env, c.get("userId"));
  const timeZone = await timeZoneFor(c, store);
  const [areas, projects, open, review] = await Promise.all([
    store.readAreas(500),
    store.readProjects("active", 500),
    listTasks(store, timeZone, "all", 500),
    listTasks(store, timeZone, "review", 100),
  ]);
  const today = todayYMD(timeZone);
  const nowMs = Date.now();
  const projectArea = new Map<string, string>();
  for (const p of projects) {
    if (typeof p.id === "string" && typeof p.area === "string" && p.area) {
      projectArea.set(p.id, p.area);
    }
  }
  const projectCounts = new Map<string, number>();
  const areaCounts = new Map<string, number>();
  let todayCount = 0;
  let upcomingCount = 0;
  let repeatingCount = 0;
  let anytimeCount = 0;
  let starredCount = 0;
  for (const t of open.tasks as TaskOut[]) {
    if (matchesView(t, "today", today, nowMs)) todayCount++;
    if (matchesView(t, "upcoming", today, nowMs)) upcomingCount++;
    if (t.recurrence) repeatingCount++;
    if (matchesView(t, "anytime", today, nowMs)) anytimeCount++;
    if (t.starred) starredCount++;
    if (t.project) {
      projectCounts.set(t.project, (projectCounts.get(t.project) ?? 0) + 1);
    }
    const a = t.area ?? (t.project ? projectArea.get(t.project) : undefined);
    if (a) {
      areaCounts.set(a, (areaCounts.get(a) ?? 0) + 1);
    }
  }
  return c.json({
    counts: {
      today: todayCount,
      review: review.total,
      upcoming: upcomingCount,
      repeating: repeatingCount,
      anytime: anytimeCount,
      starred: starredCount,
    },
    areas: sortByPosition(areas).map((r) => {
      const id = r.id as string;
      const out: { id: string; title: string; emoji?: string; count: number } = {
        id,
        title: typeof r.title === "string" ? r.title : "",
        count: areaCounts.get(id) ?? 0,
      };
      if (typeof r.emoji === "string" && r.emoji) out.emoji = r.emoji;
      return out;
    }),
    projects: sortByPosition(projects).map((r) => {
      const id = r.id as string;
      const out: { id: string; title: string; area?: string; count: number } = {
        id,
        title: typeof r.title === "string" ? r.title : "",
        count: projectCounts.get(id) ?? 0,
      };
      if (typeof r.area === "string" && r.area) out.area = r.area;
      return out;
    }),
  });
});

tasksRest.get("/", async (c) => {
  const q = z.object({
    view: zView.default("today"),
    area: zId.optional(),
    project: zId.optional(),
    limit: z.coerce.number().int().min(1).max(500).default(300),
  }).safeParse(c.req.query());
  if (!q.success) return c.json({ error: "invalid_request" }, 400);
  const store = rpcStoreFor(c.env, c.get("userId"));
  const timeZone = await timeZoneFor(c, store);
  if (q.data.view === "added") {
    const [open, areas, projects, accentSetting] = await Promise.all([
      store.readTasks("open", 500),
      store.readAreas(500),
      store.readProjects("active", 500),
      store.readSetting("accentColor"),
    ]);
    const added = addedTasks(open.rows, containerNames(areas, projects), Date.now());
    return c.json({
      view: "added",
      today: todayYMD(timeZone),
      accent: accentFor(accentSetting),
      total: added.total,
      truncated: added.total > added.tasks.length,
      tasks: added.tasks,
    });
  }
  const needsAll = !!q.data.area || !!q.data.project || q.data.view === "repeating" || q.data.view === "starred";
  const [list, areas, projects, accentSetting] = await Promise.all([
    listTasks(store, timeZone, needsAll ? "all" : q.data.view, needsAll ? 500 : q.data.limit),
    store.readAreas(500),
    store.readProjects("active", 500),
    store.readSetting("accentColor"),
  ]);
  const today = todayYMD(timeZone);
  const names = containerNames(areas, projects);
  let tasks = list.tasks as TaskOut[];
  let total = list.total;
  let truncated = list.truncated;
  if (q.data.project) {
    tasks = tasks.filter((t) => t.project === q.data.project);
    total = tasks.length;
    truncated = total > q.data.limit;
    tasks = tasks.slice(0, q.data.limit);
  } else if (q.data.area) {
    const projectArea = new Map<string, string>();
    for (const p of projects) {
      if (typeof p.id === "string" && typeof p.area === "string" && p.area) {
        projectArea.set(p.id, p.area);
      }
    }
    tasks = tasks.filter((t) => t.area === q.data.area || (!!t.project && projectArea.get(t.project) === q.data.area));
    total = tasks.length;
    truncated = total > q.data.limit;
    tasks = tasks.slice(0, q.data.limit);
  } else if (q.data.view === "repeating") {
    tasks = tasks.filter((t) => !!t.recurrence);
    total = tasks.length;
    truncated = total > q.data.limit;
    tasks = tasks.slice(0, q.data.limit);
  } else if (q.data.view === "starred") {
    tasks = tasks.filter((t) => !!t.starred);
    total = tasks.length;
    truncated = total > q.data.limit;
    tasks = tasks.slice(0, q.data.limit);
  }
  return c.json({
    view: q.data.view,
    today,
    accent: accentFor(accentSetting),
    total,
    truncated,
    tasks: tasks.map((t) => clientTask(t, names)),
  });
});

/// The tasks that point at a key, a URL or a `message://` link. The key is in
/// the body, never in the URL: request logs hold URLs, and a key is content.
tasksRest.post("/by-ref", async (c) => {
  const body = await json(c, z.object({
    key: z.string().min(1).max(MAX_REF_INPUT),
    limit: z.number().int().min(1).max(200).default(50),
  }).strict());
  if (body instanceof Response) return body;
  try {
    return c.json(await findByRef(rpcStoreFor(c.env, c.get("userId")), body.key, body.limit));
  } catch (e) {
    return c.json({ error: "rejected", message: e instanceof Error ? e.message : String(e) }, 422);
  }
});

const zWhen = z.enum(["inbox", "today", "tomorrow"]);

tasksRest.post("/", async (c) => {
  const body = await json(c, z.object({
    title: z.string().trim().min(1).max(500),
    when: zWhen.default("inbox"),
    refs: zRefs.optional(),
  }).strict());
  if (body instanceof Response) return body;
  const ctx = await writeContext(c);
  const args: Record<string, unknown> = { title: body.title };
  if (body.refs) args.refs = body.refs;
  if (body.when === "today") args.today = true;
  if (body.when === "tomorrow") args.scheduled = addDaysYMD(todayYMD(ctx.timeZone), 1);
  return run(c, ctx, "tasks_create", args, 201);
});

const zVerb = z.enum(["complete", "today", "untoday", "tomorrow", "defer", "cancel"]);

tasksRest.post("/:id/:verb", async (c) => {
  const id = zId.safeParse(c.req.param("id"));
  const verb = zVerb.safeParse(c.req.param("verb"));
  if (!id.success || !verb.success) return c.json({ error: "invalid_request" }, 400);
  const ctx = await writeContext(c);
  const today = todayYMD(ctx.timeZone);
  switch (verb.data) {
    case "complete":
      return run(c, ctx, "tasks_complete", { id: id.data });
    case "today":
      return run(c, ctx, "tasks_move_to_today", { id: id.data });
    case "tomorrow":
      return run(c, ctx, "tasks_defer", { id: id.data, until: addDaysYMD(today, 1) });
    case "defer": {
      const body = await json(c, z.object({ until: z.string().regex(/^\d{4}-\d{2}-\d{2}$/) }).strict());
      if (body instanceof Response) return body;
      return run(c, ctx, "tasks_defer", { id: id.data, until: body.until });
    }
    case "untoday":
      // The phone's "Remove from Today" (spec §4 A3): the core drops the pin
      // and any When date or deadline that has arrived, so the row cannot
      // bounce straight back (decision Q2).
      return run(c, ctx, "tasks_update", { id: id.data, today: false });
    case "cancel":
      return run(c, ctx, "tasks_update", { id: id.data, status: "cancelled" });
  }
});

async function json<T extends z.ZodTypeAny>(c: Ctx, schema: T): Promise<z.infer<T> | Response> {
  let body: unknown = {};
  const text = await c.req.text();
  if (text.trim()) {
    try {
      body = JSON.parse(text);
    } catch {
      return c.json({ error: "invalid_json" }, 400);
    }
  }
  const parsed = schema.safeParse(body);
  if (!parsed.success) return c.json({ error: "invalid_request", issues: parsed.error.issues.slice(0, 10) }, 400);
  return parsed.data;
}

/// Validates against the MCP tool's own schema, then runs it. Tool errors are
/// plain Errors; "Task not found" maps to 404, anything else to 422.
async function run(
  c: Ctx, ctx: WriteContext, name: WriteToolName, args: Record<string, unknown>, okStatus: 200 | 201 = 200,
): Promise<Response> {
  const parsed = zWriteArgs[name].safeParse(args);
  if (!parsed.success) return c.json({ error: "invalid_request" }, 400);
  try {
    const result = await runWriteTool(ctx, name, parsed.data as Record<string, unknown>);
    logEvent("tasks_rest", { tool: name, ok: true });
    return c.json(result as object, okStatus);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    logEvent("tasks_rest", { tool: name, ok: false });
    if (/^Task not found/.test(message)) return c.json({ error: "not_found" }, 404);
    return c.json({ error: "rejected", message }, 422);
  }
}
