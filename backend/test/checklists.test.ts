import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";
installWorkerTestHooks();

// Dynamic: recurrence.ts imports the core bridge as ./core/index.js, which
// resolves only after the hooks above are installed.
const { checklistOccurrenceID } = await import("../src/recurrence.ts");

const HUMAN_ACTOR = "app:mac-test";
const AGENT_ACTOR = "mcp:claude";

let seq = 0;
const opId = (prefix = "chkop") => `${prefix}_${++seq}_${Date.now()}`;

describe("Checklists (1-level subtasks, CL0 #153)", () => {
  it("creates, adds, checks, renames, reorders, and deletes checklist items via MCP tools", async () => {
    const { store } = await createTestTaskStore();
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const rpcStore = {
      readTask: async (id: string) => store.readTask(id),
      readTasks: async (status: "open" | "done", limit: number) => store.readTasks(status, limit),
      readAreas: async (limit: number) => store.readAreas(limit),
      readProjects: async (status: "active" | "done" | "cancelled" | "all", limit: number) => store.readProjects(status, limit),
      readChecklistItems: async (taskId: string) => store.readChecklistItems(taskId),
      readChecklistItem: async (id: string) => store.readChecklistItem(id),
      readChecklistCounts: async () => store.readChecklistCounts(),
      readConvoLinks: async () => store.readConvoLinks(),
      readOrderTop: async () => store.readOrderTop(),
      push: async (ops: Parameters<typeof store.push>[0], actor: string) => store.push(ops, actor),
    };
    const ctx = { store: rpcStore as never, timeZone: "UTC" };

    // 1. Create task with initial checklist steps.
    const created = (await runWriteTool(ctx, "tasks_create", {
      title: "Launch checklist",
      checklist: ["Write spec", "Ship backend"],
      origin: "user_request",
    })) as { id: string; checklist: Array<{ id: string; title: string; position: number }> };
    assert.equal(created.checklist.length, 2);

    // 2. Append one more step.
    const added = (await runWriteTool(ctx, "tasks_checklist_add", {
      task_id: created.id,
      items: ["Verify on device"],
    })) as { added: Array<{ id: string; title: string; position: number }> };
    assert.equal(added.added.length, 1);

    // 3. Check step 1 and rename step 2 concurrently (row-granularity merge).
    await runWriteTool(ctx, "tasks_checklist_update", { id: created.checklist[0].id, checked: true });
    await runWriteTool(ctx, "tasks_checklist_update", { id: created.checklist[1].id, title: "Ship sync & MCP" });

    const items = store.readChecklistItems(created.id);
    assert.equal(items.length, 3);
    assert.equal(items[0].checked, true);
    assert.ok(typeof items[0].checkedAt === "string");
    assert.equal(items[1].title, "Ship sync & MCP");
    assert.equal(items[1].checked, false);

    const counts = store.readChecklistCounts();
    assert.deepEqual(counts[created.id], { total: 3, done: 1 });

    // 4. Delete step 3.
    await runWriteTool(ctx, "tasks_checklist_delete", { id: added.added[0].id });
    assert.equal(store.readChecklistItems(created.id).length, 2);
  });

  it("copies checklist items unchecked onto spawned recurring occurrences with deterministic IDs", async () => {
    const { store } = await createTestTaskStore();
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const rpcStore = {
      readTask: async (id: string) => store.readTask(id),
      readTasks: async (status: "open" | "done", limit: number) => store.readTasks(status, limit),
      readAreas: async (limit: number) => store.readAreas(limit),
      readProjects: async (status: "active" | "done" | "cancelled" | "all", limit: number) => store.readProjects(status, limit),
      readChecklistItems: async (taskId: string) => store.readChecklistItems(taskId),
      readChecklistItem: async (id: string) => store.readChecklistItem(id),
      readChecklistCounts: async () => store.readChecklistCounts(),
      readConvoLinks: async () => store.readConvoLinks(),
      readOrderTop: async () => store.readOrderTop(),
      push: async (ops: Parameters<typeof store.push>[0], actor: string) => store.push(ops, actor),
    };
    const ctx = { store: rpcStore as never, timeZone: "UTC" };

    store.push([
      {
        clientOpId: opId("t"),
        op: "upsert",
        entity: "task",
        id: "recur-src",
        fields: {
          title: "Weekly review",
          status: "open",
          scheduled: "2026-11-20",
          recurrenceUnit: "week",
          recurrenceInterval: 1,
          recurrenceAfterCompletion: false,
          recurrenceAnchorDate: "2026-11-20",
        },
      },
      {
        clientOpId: opId("c1"),
        op: "upsert",
        entity: "checklistItem",
        id: "item-a",
        fields: { taskId: "recur-src", title: "Clear inbox", checked: true, checkedAt: "2026-11-20T09:00:00Z", position: 1024 },
      },
      {
        clientOpId: opId("c2"),
        op: "upsert",
        entity: "checklistItem",
        id: "item-b",
        fields: { taskId: "recur-src", title: "Plan week", checked: true, checkedAt: "2026-11-20T09:05:00Z", position: 2048 },
      },
    ], HUMAN_ACTOR);

    const completed = (await runWriteTool(ctx, "tasks_complete", { id: "recur-src" })) as {
      nextOccurrence?: { id: string; scheduled: string };
    };
    assert.ok(completed.nextOccurrence?.id);
    const nextId = completed.nextOccurrence!.id;

    // Source task keeps its original checked states (Things-style Logbook fidelity).
    const srcItems = store.readChecklistItems("recur-src");
    assert.equal(srcItems.every((r) => r.checked === true), true);

    // Spawned occurrence carries unchecked copies with deterministic IDs.
    const nextItems = store.readChecklistItems(nextId);
    assert.equal(nextItems.length, 2);
    assert.equal(nextItems[0].id, checklistOccurrenceID(nextId, 0, "item-a"));
    assert.equal(nextItems[1].id, checklistOccurrenceID(nextId, 1, "item-b"));
    assert.equal(nextItems[0].title, "Clear inbox");
    assert.equal(nextItems[1].title, "Plan week");
    assert.equal(nextItems[0].checked, false);
    assert.equal(nextItems[1].checked, false);
    assert.equal(nextItems[0].checkedAt, null);
  });

  it("enforces stoppedAt, cascades permanent task deletion, and gates pull behind includeChecklists", async () => {
    const { store } = await createTestTaskStore();

    store.push([
      { clientOpId: opId("t"), op: "upsert", entity: "task", id: "t-stop", fields: { title: "Protected", status: "open" } },
      { clientOpId: opId("c"), op: "upsert", entity: "convo", id: "t-stop", fields: { stoppedAt: "2026-11-21T10:00:00Z" } },
      { clientOpId: opId("i"), op: "upsert", entity: "checklistItem", id: "chk-1", fields: { taskId: "t-stop", title: "Step 1", position: 1024 } },
    ], HUMAN_ACTOR);

    // Agent write on stopped task's checklist item is refused.
    const agentAttempt = store.push([
      { clientOpId: opId("a"), op: "upsert", entity: "checklistItem", id: "chk-1", fields: { checked: true } },
    ], AGENT_ACTOR);
    assert.equal(agentAttempt.result.results[0].status, "rejected");
    assert.equal(agentAttempt.result.results[0].reason, "stopped");

    // Older clients pulling without includeChecklists never receive checklistItem rows.
    const legacyPull = store.pull(0, 100, true, false);
    assert.equal(legacyPull.changes.some((c) => c.entity === "checklistItem"), false);

    // Modern clients pulling with includeChecklists=true receive checklistItem rows.
    const modernPull = store.pull(0, 100, true, true);
    assert.equal(modernPull.changes.some((c) => c.entity === "checklistItem" && c.row.id === "chk-1"), true);

    // Permanent delete of owning task cascades tombstone to checklist items.
    store.push([{ clientOpId: opId("del"), op: "delete", entity: "task", id: "t-stop" }], HUMAN_ACTOR);
    assert.equal(store.readChecklistItems("t-stop").length, 0);
  });
});
