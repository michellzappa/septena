import type { Context } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { TOOLS_LIST_TTL_MS, type Era } from "../protocol.js";
import {
  type JsonRpcRequest,
  type Tool,
  answerProtocolMethod,
  methodNotFound,
  readRpcRequest,
  rpcError,
  rpcResult,
  unauthorized,
} from "../rpc.js";
import { storeFor } from "../api/session.js";
import { zId } from "../store/columns.js";
import type { Row, TaskStore } from "../store/TaskStore.js";
import { todayYMD } from "../tz.js";
import { listTasksJsonSchema } from "../tools/listTasks.js";
import { listAreasJsonSchema } from "../tools/listAreas.js";
import { listProjectsJsonSchema } from "../tools/listProjects.js";
import { getTaskJsonSchema, pendingReasoningJsonSchema, threadGetJsonSchema } from "../tools/writeTasks.js";
import {
  type ConvoTurn,
  type TaskConvo,
  type TaskOut,
  awaitsReasoning,
  convoSummary,
  matchesView,
  normalizeView,
} from "../tools/taskShared.js";
import { MCP_SCOPE, verifyMcpAccess, type McpGrant } from "./tokens.js";

// Read-only MCP preview at https://api.septena.app/mcp (phase 2, "shadow", of
// docs/SEPTASK_BACKEND.md in the app repo). Same protocol layer as the live
// connector (src/rpc.ts + src/protocol.ts, dual-era); the data source is the
// user's TaskStore Durable Object instead of CloudKit.
//
// Tool names, arguments and output shapes match the live tools. The view rules
// and the conversation summary are the same functions (tools/taskShared.ts).
// No write tool is listed or callable here: the apps still write iCloud and
// this store is a snapshot refreshed by re-running the import.

const INSTRUCTIONS =
  "Septena tasks, read-only preview. These tools read the signed-in user's tasks, " +
  "areas, projects and task conversations from the Septena task backend. The data " +
  "is a copy the user refreshes from the Septask Mac app, so it can lag behind the " +
  "app. Nothing here can create or change a task: use the main Septena connector " +
  "for that.";

const RESOURCE_METADATA = (env: Env) => `${env.API_PUBLIC_URL}/.well-known/oauth-protected-resource`;

const TOOLS: Tool[] = [
  {
    name: "tasks_list",
    description:
      "List Septena tasks for a given view (today, triage, inbox, upcoming, anytime, completed). Read-only preview from the task backend. 'anytime' is the single home for open, dateless tasks (it absorbed the former 'someday' bucket). 'triage' is the to-sort pile shown above Today; 'today' excludes those and is in the user's Today order. Returns {tasks, total, truncated}; truncated=true means more rows exist beyond limit.",
    inputSchema: listTasksJsonSchema,
  },
  {
    name: "tasks_get",
    description:
      "Inspect a single task by id: title, status, area, project, scheduled, deadline, today, completedAt, source, and a compact conversation summary. Read-only preview from the task backend.",
    inputSchema: getTaskJsonSchema,
  },
  {
    name: "tasks_list_projects",
    description: "List Septena projects, optionally filtered by status. Read-only preview from the task backend.",
    inputSchema: listProjectsJsonSchema,
  },
  {
    name: "tasks_list_areas",
    description: "List Septena areas (top-level containers like 'home', 'envisioning'). Read-only preview from the task backend.",
    inputSchema: listAreasJsonSchema,
  },
  {
    name: "tasks_thread_get",
    description: "Read a task's conversation (TaskConvo: confirmedIntent, acceptance, thread of turns, artifact, handoff, endState, assignee). Read-only preview from the task backend.",
    inputSchema: threadGetJsonSchema,
  },
  {
    name: "tasks_pending_reasoning",
    description: "List tasks awaiting reasoning: marked for Claude, or whose last provider turn was low-confidence, and not yet terminal. Read-only preview from the task backend.",
    inputSchema: pendingReasoningJsonSchema,
  },
];

// Arguments are validated before anything reaches the Durable Object. Unknown
// keys are ignored, as on the live connector.
const zLimit = (max: number) => z.number().int().min(1).max(max);
const zArgs = {
  tasks_list: z.object({
    view: z.enum(["today", "triage", "inbox", "anytime", "upcoming", "completed", "someday"]).optional(),
    limit: zLimit(500).optional(),
  }),
  tasks_get: z.object({ id: zId }),
  tasks_thread_get: z.object({ id: zId }),
  tasks_list_areas: z.object({ limit: zLimit(500).optional() }),
  tasks_list_projects: z.object({
    status: z.enum(["active", "done", "cancelled", "all"]).optional(),
    limit: zLimit(500).optional(),
  }),
  tasks_pending_reasoning: z.object({ limit: zLimit(500).optional() }),
};
type ToolName = keyof typeof zArgs;

export async function previewMcpHandler(c: Context<{ Bindings: Env }>) {
  const auth = c.req.header("Authorization") ?? "";
  const m = auth.match(/^Bearer\s+(.+)$/);
  if (!m) return unauthorized("preview: missing Bearer header", RESOURCE_METADATA(c.env));
  const grant = await verifyMcpAccess(c.env, m[1]);
  if (!grant) return unauthorized("preview: access_token not found", RESOURCE_METADATA(c.env));
  if (!grant.scope.split(" ").includes(MCP_SCOPE)) {
    return unauthorized("preview: scope", RESOURCE_METADATA(c.env));
  }

  const parsed = await readRpcRequest(c);
  if (parsed instanceof Response) return parsed;
  const { req, era } = parsed;

  const protocolReply = answerProtocolMethod(req, era, {
    instructions: INSTRUCTIONS,
    initializeInstructions: INSTRUCTIONS,
  });
  if (protocolReply) return protocolReply;

  try {
    switch (req.method) {
      case "tools/list":
        return rpcResult(req.id, { tools: TOOLS, ttlMs: TOOLS_LIST_TTL_MS, cacheScope: "private" }, era);
      case "tools/call": {
        const params = (req.params ?? {}) as { name?: string; arguments?: Record<string, unknown> };
        const startedAt = Date.now();
        try {
          const res = await callTool(c.env, grant, req.id, params, era);
          logEvent("preview_tool_call", { name: params.name ?? "?", ok: true, ms: Date.now() - startedAt });
          return res;
        } catch (err) {
          logEvent("preview_tool_call", {
            name: params.name ?? "?",
            ok: false,
            ms: Date.now() - startedAt,
            error: err instanceof Error ? err.message.slice(0, 200) : String(err),
          });
          throw err;
        }
      }
      default:
        return methodNotFound(req, era);
    }
  } catch (err) {
    return rpcError(req.id, -32603, err instanceof Error ? err.message : String(err), era);
  }
}

async function callTool(
  env: Env,
  grant: McpGrant,
  id: JsonRpcRequest["id"],
  params: { name?: string; arguments?: Record<string, unknown> },
  era: Era,
): Promise<Response> {
  const name = params.name ?? "";
  if (!(name in zArgs)) {
    // Write tools are not part of this endpoint; same reply as any unknown tool.
    return rpcError(id, -32602, `Unknown tool: ${params.name} (this connector is a read-only preview)`);
  }
  const args = zArgs[name as ToolName].safeParse(params.arguments ?? {});
  if (!args.success) {
    return rpcError(id, -32602, `Invalid arguments: ${args.error.issues.map((i) => `${i.path.join(".")} ${i.message}`).join("; ")}`);
  }
  const store = readerFor(env, grant.userId);
  const a = args.data as Record<string, unknown>;
  let result: unknown;
  switch (name as ToolName) {
    case "tasks_list":
      result = await listTasks(store, grant, a.view, a.limit as number | undefined);
      break;
    case "tasks_get": {
      const r = await store.readTask(a.id as string);
      if (!r || r.task.kind === "heading") throw new Error(`Task not found: ${a.id}`);
      const t = taskOut(r.task);
      result = {
        id: t.id, title: t.title, status: t.status, today: t.today,
        scheduled: t.scheduled, deadline: t.deadline, area: t.area, project: t.project,
        completedAt: t.completedAt, source: t.source, notes: t.notes,
        convo: convoSummary(convoOut(r.convo, r.turns)),
      };
      break;
    }
    case "tasks_thread_get": {
      const r = await store.readTask(a.id as string);
      if (!r) throw new Error(`Task not found: ${a.id}`);
      result = { id: a.id, conversation: convoOut(r.convo, r.turns) };
      break;
    }
    case "tasks_list_areas": {
      const rows = await store.readAreas((a.limit as number | undefined) ?? 100);
      result = {
        areas: rows.map((r) => ({ id: r.id as string, title: str(r.title) ?? "", context: str(r.context) })),
      };
      break;
    }
    case "tasks_list_projects": {
      const rows = await store.readProjects(
        (a.status as "active" | "done" | "cancelled" | "all" | undefined) ?? "active",
        (a.limit as number | undefined) ?? 200,
      );
      result = {
        projects: rows.map((r) => ({
          id: r.id as string,
          title: str(r.title) ?? "",
          status: str(r.status) ?? "active",
          area: str(r.area),
          notes: str(r.notes),
          context: str(r.context),
          githubRepo: str(r.githubRepo),
          completedAt: str(r.completedAt),
        })),
      };
      break;
    }
    case "tasks_pending_reasoning": {
      const limit = (a.limit as number | undefined) ?? 50;
      const tasks: Array<{ id: string; title: string; confirmedIntent?: string; assignee?: string }> = [];
      for (const row of await store.readConvoCandidates()) {
        // Only the last provider turn matters to the rule, so it is the thread.
        const convo: TaskConvo = {
          thread: row.lastProviderConfidence === null ? [] : [
            { seq: 0, role: "provider", step: "work", confidence: row.lastProviderConfidence, ts: "" },
          ],
          subtasks: [],
          confirmedIntent: row.confirmedIntent ?? undefined,
          assignee: (row.assignee ?? undefined) as TaskConvo["assignee"],
          endState: row.endState ?? undefined,
        };
        if (!awaitsReasoning(convo)) continue;
        tasks.push({ id: row.id, title: row.title ?? "", confirmedIntent: convo.confirmedIntent, assignee: convo.assignee });
        if (tasks.length >= limit) break;
      }
      result = { tasks };
      break;
    }
  }
  return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] }, era);
}

/// The DO's read methods as plain async calls. Typed from TaskStore's own
/// declarations: the generated RPC stub type recurses too deep on JSON rows.
type ReadMethod = "readTasks" | "readTask" | "readAreas" | "readProjects" | "readConvoCandidates";
type Store = { [K in ReadMethod]: (...a: Parameters<TaskStore[K]>) => Promise<ReturnType<TaskStore[K]>> };
const readerFor = (env: Env, userId: string) => storeFor(env, userId) as unknown as Store;

async function listTasks(store: Store, grant: McpGrant, rawView: unknown, rawLimit: number | undefined) {
  const view = normalizeView(rawView);
  const limit = rawLimit ?? 100;
  if (view === "completed") {
    const { rows, total } = await store.readTasks("done", limit);
    return { tasks: rows.map(taskOut), total, truncated: total > rows.length };
  }
  // Open rows arrive ordered by scheduled, then position. Today re-sorts by
  // its own manual order: todayPosition, falling back to position.
  const { rows } = await store.readTasks("open", limit);
  const today = todayYMD(grant.timeZone ?? "UTC");
  const nowMs = Date.now();
  let matched = rows
    .map((row) => ({ row, out: taskOut(row) }))
    .filter(({ out }) => matchesView(out, view, today, nowMs));
  if (view === "today") {
    const key = (r: Row) =>
      num(r.todayPosition) ?? num(r.position) ?? Number.POSITIVE_INFINITY;
    matched = matched
      .map((m, i) => ({ ...m, i }))
      .sort((x, y) => key(x.row) - key(y.row) || x.i - y.i);
  }
  return {
    tasks: matched.slice(0, limit).map((m) => m.out),
    total: matched.length,
    truncated: matched.length > limit,
  };
}

/// A TaskStore task row in the live `tasks_list` shape (tools/taskShared.ts
/// TaskOut), key order included.
function taskOut(r: Row): TaskOut {
  const unit = str(r.recurrenceUnit);
  return {
    id: r.id as string,
    title: str(r.title) ?? "",
    status: str(r.status) ?? "open",
    today: r.today === true,
    scheduled: str(r.scheduled),
    deadline: str(r.deadline),
    area: str(r.area),
    project: str(r.project),
    completedAt: str(r.completedAt),
    notes: str(r.notes),
    source: str(r.source),
    acknowledgedAt: ms(r.acknowledgedAt),
    createdAt: ms(r.createdAt),
    kind: str(r.kind),
    recurrence: unit
      ? {
          unit,
          interval: Number(r.recurrenceInterval ?? 1) || 1,
          after_completion: r.recurrenceAfterCompletion === true,
        }
      : undefined,
  };
}

/// A convo row plus its turns, in the live TaskConvo shape (absent fields
/// omitted, as in the CloudKit JSON blob).
function convoOut(row: Row | null, turns: Row[]): TaskConvo {
  const c: TaskConvo = { thread: turns.map(turnOut), subtasks: [] };
  if (!row) return c;
  if (str(row.confirmedIntent)) c.confirmedIntent = row.confirmedIntent as string;
  if (str(row.acceptance)) c.acceptance = row.acceptance as string;
  if (Array.isArray(row.subtasks)) c.subtasks = row.subtasks as string[];
  if (row.artifact) c.artifact = row.artifact as TaskConvo["artifact"];
  if (row.handoff) c.handoff = row.handoff as TaskConvo["handoff"];
  if (str(row.endState)) c.endState = row.endState as string;
  if (str(row.endStateNote)) c.endStateNote = row.endStateNote as string;
  if (str(row.assignee)) c.assignee = row.assignee as TaskConvo["assignee"];
  return c;
}

function turnOut(r: Row): ConvoTurn {
  const t: Record<string, unknown> = {};
  for (const k of ["seq", "role", "step", "provider", "confidence", "question", "options",
    "chosen", "otherText", "inReplyTo", "note", "ts"]) {
    if (r[k] !== undefined && r[k] !== null) t[k] = r[k];
  }
  return t as unknown as ConvoTurn;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

/// ISO stamp → ms epoch, the unit the live tool emits for these fields.
function ms(v: unknown): number | undefined {
  if (typeof v !== "string") return undefined;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : undefined;
}
