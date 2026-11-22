import { Hono, type Context } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { zId } from "../store/columns.js";
import type { Row } from "../store/TaskStore.js";
import { addDaysYMD, isValidTz, todayYMD } from "../tz.js";
import type { TaskOut } from "../tools/taskShared.js";
import { listTasks } from "../shadow/mcp.js";
import { rpcStoreFor, runWriteTool, zWriteArgs, type StoreRpc, type WriteContext, type WriteToolName } from "../shadow/writes.js";

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
  daysOnToday?: number;
  checklistCount?: number;
  checklistDoneCount?: number;
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
  if (t.daysOnToday) out.daysOnToday = t.daysOnToday;
  if (t.checklistCount) {
    out.checklistCount = t.checklistCount;
    out.checklistDoneCount = t.checklistDoneCount ?? 0;
  }
  return out;
}

function containerNames(areas: Row[], projects: Row[]): Map<string, string> {
  const m = new Map<string, string>();
  for (const r of [...areas, ...projects]) {
    if (typeof r.title === "string" && r.title) m.set(r.id as string, r.title);
  }
  return m;
}

const zView = z.enum(["today", "inbox", "upcoming", "anytime"]);

tasksRest.get("/", async (c) => {
  const q = z.object({
    view: zView.default("today"),
    limit: z.coerce.number().int().min(1).max(500).default(300),
  }).safeParse(c.req.query());
  if (!q.success) return c.json({ error: "invalid_request" }, 400);
  const store = rpcStoreFor(c.env, c.get("userId"));
  const timeZone = await timeZoneFor(c, store);
  const [list, areas, projects] = await Promise.all([
    listTasks(store, timeZone, q.data.view, q.data.limit),
    store.readAreas(500),
    store.readProjects("active", 500),
  ]);
  const today = todayYMD(timeZone);
  const names = containerNames(areas, projects);
  return c.json({
    view: q.data.view,
    today,
    total: list.total,
    truncated: list.truncated,
    tasks: (list.tasks as TaskOut[]).map((t) => clientTask(t, names)),
  });
});

const zWhen = z.enum(["inbox", "today", "tomorrow"]);

tasksRest.post("/", async (c) => {
  const body = await json(c, z.object({
    title: z.string().trim().min(1).max(500),
    when: zWhen.default("inbox"),
  }).strict());
  if (body instanceof Response) return body;
  const ctx = await writeContext(c);
  const args: Record<string, unknown> = { title: body.title };
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
    case "untoday": {
      // The phone's "Remove from Today": drop the pin, and a scheduled date
      // that already arrived (it would keep the row on Today). A due date
      // stays; it is a commitment, not a placement.
      const current = await ctx.store.readTask(id.data);
      if (!current) return c.json({ error: "not_found" }, 404);
      const scheduled = current.task.scheduled;
      const args: Record<string, unknown> = { id: id.data, today: false };
      if (typeof scheduled === "string" && scheduled <= today) args.scheduled = "";
      return run(c, ctx, "tasks_update", args);
    }
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
