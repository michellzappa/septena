import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// /v1/tasks (src/api/tasksRest.ts) runs the MCP write tools with an app actor
// and app provenance. These pin the two differences from the MCP path.

async function harness() {
  const { store } = await createTestTaskStore();
  const rpc = {
    readTask: async (id: string) => store.readTask(id),
    readTasks: async (status: "open" | "done", limit: number) => store.readTasks(status, limit),
    readAreas: async (limit: number) => store.readAreas(limit),
    readProjects: async (status: "active" | "done" | "cancelled" | "all", limit: number) => store.readProjects(status, limit),
    readChecklistCounts: async () => store.readChecklistCounts(),
    readTaskLinks: async () => store.readTaskLinks(),
    readTaskRefs: async (id: string) => store.readTaskRefs(id),
    readTags: async () => store.readTags(),
    readSetting: async (key: string) => store.readSetting(key),
    readOrderTop: async () => store.readOrderTop(),
    push: async (ops: Parameters<typeof store.push>[0], actor: string) => store.push(ops, actor),
  };
  return { store, rpc };
}

describe("tasks REST surface (watch)", () => {
  it("creates as the human app client, not the agent", async () => {
    const { store, rpc } = await harness();
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const ctx = {
      store: rpc as never,
      timeZone: "UTC",
      actor: "app:septask-watch",
      source: { source: "app", sourceClient: "septask-watch" },
    };
    const created = (await runWriteTool(ctx, "tasks_create", { title: "Buy milk", today: true })) as { id: string };
    const row = store.readTask(created.id)!.task;
    assert.equal(row.source, "app");
    assert.equal(row.sourceClient, "septask-watch");
    assert.ok(row.acknowledgedAt, "a human capture is acknowledged");
    const [change] = store.history("task", created.id, null, 5);
    assert.equal(change.actor, "app:septask-watch");
  });

  it("MCP path keeps its provenance when no source is given", async () => {
    const { store, rpc } = await harness();
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const created = (await runWriteTool({ store: rpc as never, timeZone: "UTC" }, "tasks_create", { title: "Draft" })) as { id: string };
    const row = store.readTask(created.id)!.task;
    assert.equal(row.source, "mcp");
    assert.equal(store.history("task", created.id, null, 5)[0].actor, "mcp:claude");
  });

  it("maps a Today row to the client shape with container names", async () => {
    const { store, rpc } = await harness();
    store.push([
      { clientOpId: "a1", op: "upsert", entity: "area", id: "area-home", fields: { title: "Home" } },
      {
        clientOpId: "t1", op: "upsert", entity: "task", id: "task-1",
        fields: { title: "Pay rent", status: "open", area: "area-home", deadline: "2000-01-01", recurrenceUnit: "month", recurrenceInterval: 1 },
      },
    ], "app:test");
    const { listTasks } = await import("../src/shadow/mcp.ts");
    const { clientTask } = await import("../src/api/tasksRest.ts");
    const list = await listTasks(rpc as never, "UTC", "today", 100);
    const names = new Map([["area-home", "Home"]]);
    const out = (list.tasks as never[]).map((t) => clientTask(t, names));
    assert.equal(out.length, 1);
    assert.equal(out[0].title, "Pay rent");
    assert.equal(out[0].area, "Home");
    assert.equal(out[0].deadline, "2000-01-01");
    assert.equal(out[0].repeats, true);
  });
});

describe("tasks REST surface (desk orb)", () => {
  it("sends the synced accent with its hexes, Colorful as fallback", async () => {
    const { accentFor } = await import("../src/api/tasksRest.ts");
    assert.deepEqual(accentFor("persimmon"), { id: "persimmon", light: "#E05212", dark: "#FF7738" });
    assert.equal(accentFor(undefined).id, "colorful");
    assert.equal(accentFor("not-a-fruit").id, "colorful");
  });

  it("carries completedAt for the completed view", async () => {
    const { clientTask } = await import("../src/api/tasksRest.ts");
    const out = clientTask({ id: "t1", title: "Done thing", completedAt: "2026-11-24T09:15:00" } as never, new Map());
    assert.equal(out.completedAt, "2026-11-24T09:15:00");
  });

  it("carries the agent's review note for the review view", async () => {
    const { clientTask } = await import("../src/api/tasksRest.ts");
    const out = clientTask({ id: "t1", title: "Draft", reviewNote: "Drafted the reply; check the tone." } as never, new Map());
    assert.equal(out.reviewNote, "Drafted the reply; check the tone.");
  });

  it("carries when the agent handed the task over", async () => {
    const { store, rpc } = await harness();
    const withReview = { ...rpc, readReviewTasks: async (n: number) => store.readReviewTasks(n) };
    store.push([
      { clientOpId: "r1", op: "upsert", entity: "task", id: "task-r", fields: { title: "Draft", status: "open" } },
      { clientOpId: "r2", op: "upsert", entity: "convo", id: "task-r", fields: { assignee: "claude", endState: "needs_verify", endStateNote: "Check it" } },
    ], "app:test");
    const { listTasks } = await import("../src/shadow/mcp.ts");
    const { clientTask } = await import("../src/api/tasksRest.ts");
    const list = await listTasks(withReview as never, "UTC", "review", 10);
    const out = clientTask(list.tasks[0] as never, new Map());
    assert.equal(out.reviewNote, "Check it");
    assert.ok(Number.isFinite(Date.parse(out.reviewAt ?? "")));
  });

  it("added view: newest first, names the agent, skips imports, repeats, old and untitled rows", async () => {
    const { addedTasks } = await import("../src/api/tasksRest.ts");
    const now = Date.parse("2026-11-24T12:00:00Z");
    const ago = (min: number) => new Date(now - min * 60_000).toISOString();
    const row = (id: string, min: number, extra: object = {}) => ({ id, title: `Task ${id}`, status: "open", createdAt: ago(min), source: "app", notes: "private", ...extra });
    const { tasks, total } = addedTasks([
      row("mine", 10),
      row("agent", 2, { source: "mcp", sourceClient: "Codex" }),
      row("agent2", 3, { source: "mcp", sourceClient: null }),
      row("things", 1, { source: "things" }),
      row("import", 1, { source: "import:todoist" }),
      row("repeat", 1, { recurrenceSeriesID: "mine" }),
      row("seriesHead", 20, { recurrenceSeriesID: "seriesHead" }),
      row("old", 25 * 60),
      row("draft", 1, { title: " " }),
      row("faded", 1, { fadedAt: ago(0) }),
      row("undated", 1, { createdAt: null }),
    ] as never[], new Map(), now);
    assert.deepEqual(tasks.map((t) => t.id), ["agent", "agent2", "mine", "seriesHead"]);
    assert.equal(total, 4);
    assert.deepEqual([tasks[0].addedBy, tasks[0].agentName], ["agent", "Codex"]);
    assert.equal(tasks[1].agentName, "Claude");
    assert.deepEqual([tasks[2].addedBy, tasks[2].agentName], ["you", undefined]);
    assert.ok(tasks.every((t) => t.notes === undefined));
  });

  it("a person completing a Claude-assigned repeating task starts the next occurrence (#423)", async () => {
    const { store, rpc } = await harness();
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const readChecklistItems = async (id: string) => store.readChecklistItems(id);
    const ctxStore = { ...rpc, readChecklistItems } as never;
    store.push([
      {
        clientOpId: "c1", op: "upsert", entity: "task", id: "weekly-1",
        fields: { title: "Weekly report", status: "open", scheduled: "2026-11-23", recurrenceUnit: "week", recurrenceInterval: 1 },
      },
      { clientOpId: "c2", op: "upsert", entity: "convo", id: "weekly-1", fields: { assignee: "claude", endState: "needs_verify" } },
    ], "app:test");
    const agent = (await runWriteTool({ store: ctxStore, timeZone: "UTC" }, "tasks_complete", { id: "weekly-1" })) as { reason?: string };
    assert.equal(agent.reason, "human_accepts");
    assert.equal(store.readTasks("open", 10).rows.length, 1, "a refused agent leaves no orphan occurrence");
    const done = (await runWriteTool(
      { store: ctxStore, timeZone: "UTC", actor: "app:septask-watch" }, "tasks_complete", { id: "weekly-1" },
    )) as { status?: string; nextOccurrence?: { id: string } };
    assert.equal(done.status, "done");
    assert.ok(done.nextOccurrence, "the series goes on");
    const open = store.readTasks("open", 10).rows;
    assert.equal(open.length, 1);
    assert.equal(open[0].id, done.nextOccurrence!.id);
  });
});
