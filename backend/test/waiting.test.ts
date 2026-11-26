import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Waiting on a person (docs/REVIEW_SPEC.md §6, ADR 0053).

const HUMAN = "app:mac-test";
const AGENT = "mcp:claude";
let seq = 0;
const opId = (p = "w") => `${p}_${++seq}_${Date.now()}`;

type Store = Awaited<ReturnType<typeof createTestTaskStore>>["store"];

function task(store: Store, id: string, fields: Record<string, unknown> = {}, actor = HUMAN) {
  return store.push([{ clientOpId: opId("t"), op: "upsert", entity: "task", id, fields: { title: id, status: "open", ...fields } }], actor).result.results[0];
}
function write(store: Store, id: string, fields: Record<string, unknown>, actor = HUMAN) {
  return store.push([{ clientOpId: opId("u"), op: "upsert", entity: "task", id, fields }], actor).result.results[0];
}

describe("waiting on a person", () => {
  it("stamps the day a wait starts, keeps it when who changes, and clears it with the wait", async () => {
    const { store } = await createTestTaskStore();
    task(store, "t1");
    write(store, "t1", { waitingOn: "  Anna " });
    let row = store.readTask("t1")!.task;
    assert.equal(row.waitingOn, "Anna");
    assert.match(String(row.waitingSince), /^\d{4}-\d{2}-\d{2}$/);
    const since = row.waitingSince;
    write(store, "t1", { waitingOn: "Anna and Ben" });
    row = store.readTask("t1")!.task;
    assert.equal(row.waitingSince, since, "a change of who keeps the first day");
    write(store, "t1", { waitingOn: null });
    row = store.readTask("t1")!.task;
    assert.equal(row.waitingOn, null);
    assert.equal(row.waitingSince, null);
  });

  it("keeps the day the client sends", async () => {
    const { store } = await createTestTaskStore();
    task(store, "t1", { waitingOn: "Anna", waitingSince: "2026-11-20" });
    assert.equal(store.readTask("t1")!.task.waitingSince, "2026-11-20");
  });

  it("never fades: a fade pushed over a wait is dropped, and a wait ends a fade", async () => {
    const { store } = await createTestTaskStore();
    task(store, "t1", { waitingOn: "Anna" });
    write(store, "t1", { fadedAt: "2026-11-26T08:00:00Z", touchedAt: "2026-10-01T08:00:00Z" });
    assert.equal(store.readTask("t1")!.task.fadedAt, null);

    task(store, "t2", { touchedAt: "2026-10-01T08:00:00Z" });
    write(store, "t2", { fadedAt: "2026-11-26T08:00:00Z", touchedAt: "2026-10-01T08:00:00Z" });
    assert.ok(store.readTask("t2")!.task.fadedAt, "an ordinary task fades");
    write(store, "t2", { waitingOn: "Ben" });
    assert.equal(store.readTask("t2")!.task.fadedAt, null);
  });

  it("lets an agent set a wait, but never end one", async () => {
    const { store } = await createTestTaskStore();
    task(store, "t1");
    assert.equal(write(store, "t1", { waitingOn: "the lawyer" }, AGENT).status, "applied");
    assert.equal(write(store, "t1", { waitingOn: "the lawyer's office" }, AGENT).status, "applied");
    for (const fields of [{ waitingOn: null }, { waitingOn: "  " }, { status: "done" }, { status: "cancelled" }]) {
      const r = write(store, "t1", fields, AGENT);
      assert.equal(r.status, "rejected", JSON.stringify(fields));
      assert.equal(r.reason, "in_review");
    }
    const del = store.push([{ clientOpId: opId("d"), op: "delete", entity: "task", id: "t1" }], AGENT).result.results[0];
    assert.equal(del.reason, "in_review");
    assert.equal(store.readTask("t1")!.task.waitingOn, "the lawyer's office");

    assert.equal(write(store, "t1", { waitingOn: null }).status, "applied", "the user ends it");
    assert.equal(write(store, "t1", { status: "done" }, AGENT).status, "applied", "a plain task again");
  });
});

describe("tasks_set_waiting and view=waiting", () => {
  async function harness() {
    const { store } = await createTestTaskStore();
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const { listTasks } = await import("../src/shadow/mcp.ts");
    const rpc = new Proxy({}, {
      get: (_t, name) => async (...a: unknown[]) => (store as unknown as Record<string, (...x: unknown[]) => unknown>)[name as string](...a),
    }) as never;
    const ctx = { store: rpc, timeZone: "UTC", actor: AGENT };
    const run = (name: string, args: Record<string, unknown>) => runWriteTool(ctx, name as never, args) as Promise<Record<string, unknown>>;
    return { store, rpc, run, listTasks };
  }

  it("sets who and the day to chase, and lists oldest wait first", async () => {
    const h = await harness();
    task(h.store, "newer");
    task(h.store, "older", { waitingOn: "Ben", waitingSince: "2026-11-01" });
    task(h.store, "plain");
    const res = await h.run("tasks_set_waiting", { id: "newer", waiting_on: "Anna", scheduled: "2026-12-03" });
    assert.equal(res.waitingOn, "Anna");
    const row = h.store.readTask("newer")!.task;
    assert.equal(row.waitingOn, "Anna");
    assert.equal(row.scheduled, "2026-12-03");
    const list = await h.listTasks(h.rpc, "UTC", "waiting", 10);
    assert.deepEqual(list.tasks.map((t) => t.id), ["older", "newer"]);
    assert.equal(list.tasks[0].waitingOn, "Ben");
    assert.equal(list.tasks[0].waitingSince, "2026-11-01");
  });

  it("refuses an agent that ends a wait", async () => {
    const h = await harness();
    task(h.store, "t1", { waitingOn: "Anna" });
    await assert.rejects(h.run("tasks_set_waiting", { id: "t1", waiting_on: null }), /in_review|Review/);
    await assert.rejects(h.run("tasks_complete", { id: "t1" }), /in_review|Review/);
  });
});
