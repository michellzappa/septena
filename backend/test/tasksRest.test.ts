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
    const out = (list.tasks as never[]).map((t) => clientTask(t, "2026-11-22", names));
    assert.equal(out.length, 1);
    assert.equal(out[0].title, "Pay rent");
    assert.equal(out[0].area, "Home");
    assert.equal(out[0].overdue, true);
    assert.equal(out[0].repeats, true);
  });
});
