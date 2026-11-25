import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// What ends a fade (docs/TASK_FADE_SPEC.md §4.1).

const APP = "app:mac-test";
const AGENT = "mcp:claude";
const FADED = "2026-11-21T18:47:47Z";
let n = 0;

async function setup() {
  const { store } = await createTestTaskStore();
  const write = (fields: object, actor = APP) =>
    store.push([{ clientOpId: `taskfade_${++n}`, op: "upsert", entity: "task", id: "a", fields } as never], actor).result.results[0];
  write({ title: "Task a", status: "open", fadedAt: FADED });
  return { store, write, fadedAt: () => store.readTask("a")!.task.fadedAt };
}

describe("what ends a fade", () => {
  it("a deadline does, from the app or an agent", async () => {
    for (const actor of [APP, AGENT]) {
      const { write, fadedAt } = await setup();
      assert.equal(fadedAt(), FADED);
      assert.equal(write({ deadline: "2026-12-01" }, actor).status, "applied");
      assert.equal(fadedAt(), null);
    }
  });

  it("a task with a deadline cannot be faded", async () => {
    const { write, fadedAt } = await setup();
    write({ fadedAt: null, deadline: "2026-12-01" });
    write({ fadedAt: FADED });
    assert.equal(fadedAt(), null);
  });

  it("an old fade loses to a newer touch", async () => {
    const { write, fadedAt } = await setup();
    write({ fadedAt: null, touchedAt: "2026-11-24T09:05:22Z" });
    write({ fadedAt: FADED });
    assert.equal(fadedAt(), null);
  });

  it("a fade newer than the touch, and an agent's title edit, change nothing", async () => {
    const { write, fadedAt } = await setup();
    write({ touchedAt: "2026-11-01T09:00:00Z" });
    write({ title: "Renamed" }, AGENT);
    assert.equal(fadedAt(), FADED);
  });

  it("repairs rows written before the rule", async () => {
    const { store, fadedAt } = await setup();
    const sql = (store as unknown as { sql: { exec(q: string): unknown } }).sql;
    sql.exec("UPDATE tasks SET deadline = '2026-12-01' WHERE id = 'a'");
    assert.equal(store.endStaleFades(), 1);
    assert.equal(fadedAt(), null);
    assert.equal(store.endStaleFades(), 0);
  });

  it("a device that missed a touch, a date ahead or a hand-off cannot fade the task", async () => {
    const now = "2026-11-25T10:00:00Z";
    for (const known of [{ touchedAt: "2026-11-24T10:00:00Z" }, { scheduled: "2026-12-24" }]) {
      const { write, fadedAt } = await setup();
      write({ fadedAt: null, touchedAt: "2026-10-01T10:00:00Z" });
      write(known);
      write({ fadedAt: now });
      assert.equal(fadedAt(), null, JSON.stringify(known));
    }
    const { store, write, fadedAt } = await setup();
    write({ fadedAt: null });
    store.push([{ clientOpId: `taskfade_${++n}`, op: "upsert", entity: "convo", id: "a", fields: { endState: "needs_verify", endStateNote: "x" } } as never], AGENT);
    write({ fadedAt: now });
    assert.equal(fadedAt(), null);
  });

  it("a push with its own touch may fade, and undo restores a fade", async () => {
    const { write, fadedAt } = await setup();
    write({ fadedAt: null, touchedAt: "2026-11-25T10:00:00Z" });
    write({ fadedAt: FADED, touchedAt: "2026-11-01T09:00:00Z" });
    assert.equal(fadedAt(), FADED);
  });

  it("an unaccepted proposal fades with a deadline (ADR 0039)", async () => {
    const { write, fadedAt } = await setup();
    write({ fadedAt: null, source: "mcp", deadline: "2026-12-20" });
    write({ fadedAt: FADED });
    assert.equal(fadedAt(), FADED);
    write({ acknowledgedAt: "2026-11-25T10:00:00Z", touchedAt: "2026-11-25T10:00:00Z" });
    assert.equal(fadedAt(), null);
  });
});
