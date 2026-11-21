import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// The account move copies each user's TaskStore row for row
// (docs/CLOUDFLARE_ACCOUNT_MOVE.md). These tests copy one store into a fresh
// one and check that nothing changes on the way.

let seq = 0;
const opId = () => `copyop_${++seq}_${Date.now()}`;

async function seededStore() {
  const { store } = await createTestTaskStore();
  store.push([
    { clientOpId: opId(), op: "upsert", entity: "area", id: "area-1", fields: { title: "Home" } },
    { clientOpId: opId(), op: "upsert", entity: "project", id: "proj-1", fields: { title: "Move", areaId: "area-1" } },
    { clientOpId: opId(), op: "upsert", entity: "task", id: "task-1", fields: { title: "Pack books", status: "open", projectId: "proj-1" } },
    { clientOpId: opId(), op: "upsert", entity: "task", id: "task-2", fields: { title: "Call movers", status: "open" } },
    { clientOpId: opId(), op: "upsert", entity: "convo", id: "task-1", fields: { assignee: "claude" } },
  ], "app:test");
  store.push([{ clientOpId: opId(), op: "delete", entity: "task", id: "task-2" }], "app:test");
  return store;
}

type Store = Awaited<ReturnType<typeof seededStore>>;

function copyAll(from: Store, to: Store, pageSize = 2) {
  assert.deepEqual(to.copyImportBegin(), { ok: true });
  for (const table of Object.keys(from.copySnapshot())) {
    let after = 0;
    for (;;) {
      const page = from.copyExport(table, after, pageSize);
      if (page.rows.length) to.copyImport(table, page.rows);
      if (page.next === null) break;
      after = page.next;
    }
  }
  return to.copyImportEnd();
}

describe("TaskStore account copy", () => {
  it("copies every table with the same counts, revs and pull result", async () => {
    const from = await seededStore();
    const { store: to } = await createTestTaskStore();

    const after = copyAll(from, to);
    assert.deepEqual(after, from.copySnapshot());
    assert.deepEqual(to.pull(0, 1000, true), from.pull(0, 1000, true));

    // The rev counter came across: the next write continues the sequence.
    const next = to.push([{ clientOpId: opId(), op: "upsert", entity: "task", id: "task-3", fields: { title: "New", status: "open" } }], "app:test");
    const prev = from.pull(0, 1000, true).nextSince;
    assert.equal(next.result.results[0].status, "applied");
    assert.ok((next.result.results[0] as { rev: number }).rev > prev);
  });

  it("replays a client op id that was applied before the copy", async () => {
    const from = await seededStore();
    const { store: to } = await createTestTaskStore();
    const id = opId();
    from.push([{ clientOpId: id, op: "upsert", entity: "task", id: "task-9", fields: { title: "Once", status: "open" } }], "app:test");
    copyAll(from, to);
    const again = to.push([{ clientOpId: id, op: "upsert", entity: "task", id: "task-9", fields: { title: "Once", status: "open" } }], "app:test");
    const before = from.pull(0, 1000, true).nextSince;
    assert.equal(to.pull(0, 1000, true).nextSince, before, "the replayed op must not write again");
    assert.equal(again.result.results.length, 1);
  });

  it("refuses to import into a store that holds data", async () => {
    const live = await seededStore();
    assert.deepEqual(live.copyImportBegin(), { ok: false, reason: "not_empty" });
    assert.throws(() => live.copyImport("tasks", [{ id: "x" }]), /import not started/);
  });

  it("rejects unknown tables and columns", async () => {
    const from = await seededStore();
    const { store: to } = await createTestTaskStore();
    assert.throws(() => from.copyExport("no_such_table", 0, 10), /unknown table/);
    to.copyImportBegin();
    assert.throws(() => to.copyImport("no_such_table", [{ id: "x" }]), /unknown table/);
    assert.throws(() => to.copyImport("tasks", [{ id: "x", "title) VALUES (1); DROP TABLE tasks; --": "y" }]), /unknown column/);
  });
});
