import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Project notes as agent context: ADR 0012, docs/PROJECT_NOTES_SPEC.md §3–§4 (#120).

const HUMAN = "app:mac-test";
const AGENT = "mcp:claude";

let seq = 0;
const opId = (p = "op") => `${p}_${++seq}_${Date.now()}`;

type Store = Awaited<ReturnType<typeof createTestTaskStore>>["store"];

function upsert(store: Store, actor: string, entity: "project" | "area", id: string, fields: Record<string, unknown>, baseNoteRev?: number) {
  const op = { clientOpId: opId(entity), op: "upsert" as const, entity, id, fields, ...(baseNoteRev !== undefined ? { baseNoteRev } : {}) };
  return store.push([op], actor).result.results[0];
}

describe("splitNotes / agentMayWriteNotes", async () => {
  const { splitNotes, agentMayWriteNotes } = await import("../src/store/TaskStore.ts");

  it("splits at the first exact `## Log` line", () => {
    assert.deepEqual(splitNotes("Goal\n\n## Log\n### a"), { brief: "Goal\n\n", log: "\n### a" });
    assert.deepEqual(splitNotes("Goal only"), { brief: "Goal only", log: null });
    assert.deepEqual(splitNotes("## Logbook\nx"), { brief: "## Logbook\nx", log: null });
    assert.deepEqual(splitNotes(null), { brief: "", log: null });
  });

  it("allows appends to the log and writing an empty brief", () => {
    assert.ok(agentMayWriteNotes("Goal", "Goal\n\n## Log\n### 2026-11-21 · claude\nDid it"));
    assert.ok(agentMayWriteNotes("Goal\n## Log\n### a\n", "Goal\n## Log\n### a\n\n### b\n"));
    assert.ok(agentMayWriteNotes(null, "Fresh brief"));
    assert.ok(agentMayWriteNotes("## Log\n### a", "New brief\n## Log\n### a\n### b"));
  });

  it("refuses brief edits and log rewrites", () => {
    assert.ok(!agentMayWriteNotes("Goal", "Other goal"));
    assert.ok(!agentMayWriteNotes("Goal", "Goal plus more"));
    assert.ok(!agentMayWriteNotes("Goal", null));
    assert.ok(!agentMayWriteNotes("Goal\n## Log\n### a", "Goal\n## Log\n### edited"));
    assert.ok(!agentMayWriteNotes("Goal\n## Log\n### a", "Goal"));
  });
});

describe("TaskStore notes rules for agents", () => {
  it("records a revision for every notes change, with full text", async () => {
    const { store } = await createTestTaskStore();
    const long = "x".repeat(10_000);
    assert.equal(upsert(store, HUMAN, "project", "p1", { title: "P", status: "active", notes: "v1" }).status, "applied");
    assert.equal(upsert(store, HUMAN, "project", "p1", { notes: long }).status, "applied");
    assert.equal(upsert(store, HUMAN, "project", "p1", { title: "Renamed" }).status, "applied");
    assert.deepEqual(store.readNote("project", "p1"), { notes: long, noteRev: 2 });
    const revs = store.noteRevisions("project", "p1", null, 10, true);
    assert.deepEqual(revs.map((r) => r.rev), [2, 1]);
    assert.equal(revs[0].body, long, "history keeps the full text, unlike the change log");
    assert.equal(revs[1].actor, HUMAN);
    assert.equal(store.noteRevisions("project", "p1", null, 10, false)[0].body, undefined);
  });

  it("tracks area notes in the `context` column", async () => {
    const { store } = await createTestTaskStore();
    upsert(store, HUMAN, "area", "a1", { title: "Work", context: "Area brief" });
    assert.deepEqual(store.readNote("area", "a1"), { notes: "Area brief", noteRev: 1 });
  });

  it("refuses an agent notes write without the current baseNoteRev and returns the notes", async () => {
    const { store } = await createTestTaskStore();
    upsert(store, HUMAN, "project", "p2", { title: "P", status: "active", notes: "Goal" });
    for (const base of [undefined, 0, 5]) {
      const r = upsert(store, AGENT, "project", "p2", { notes: "Goal\n## Log\n### x" }, base);
      assert.equal(r.status, "rejected");
      assert.equal(r.status === "rejected" && r.reason, "stale");
      assert.deepEqual(r.status === "rejected" && r.current, { notes: "Goal", noteRev: 1 });
    }
    assert.equal(upsert(store, AGENT, "project", "p2", { notes: "Goal\n## Log\n### x" }, 1).status, "applied");
    assert.equal(store.readNote("project", "p2")?.noteRev, 2);
  });

  it("refuses an agent change to the user's brief", async () => {
    const { store } = await createTestTaskStore();
    upsert(store, HUMAN, "project", "p3", { title: "P", status: "active", notes: "Goal" });
    const r = upsert(store, AGENT, "project", "p3", { notes: "My better goal" }, 1);
    assert.equal(r.status === "rejected" && r.reason, "brief_is_users");
    assert.ok(r.status === "rejected" && r.rule?.includes("## Log"));
    assert.equal(store.readNote("project", "p3")?.notes, "Goal");
  });

  it("lets an agent write an empty brief and create a container with notes", async () => {
    const { store } = await createTestTaskStore();
    assert.equal(upsert(store, AGENT, "project", "p4", { title: "New", status: "active", notes: "Brief by setup" }).status, "applied");
    upsert(store, HUMAN, "area", "a2", { title: "Home" });
    assert.equal(upsert(store, AGENT, "area", "a2", { context: "Home brief" }, 0).status, "applied");
    assert.equal(store.readNote("area", "a2")?.notes, "Home brief");
  });

  it("lets the human change anything, with no baseNoteRev", async () => {
    const { store } = await createTestTaskStore();
    upsert(store, HUMAN, "project", "p5", { title: "P", status: "active", notes: "Goal\n## Log\n### a" });
    assert.equal(upsert(store, HUMAN, "project", "p5", { notes: "Rewritten" }).status, "applied");
  });

  it("refuses agent notes writes while agents are paused", async () => {
    const { store } = await createTestTaskStore();
    upsert(store, HUMAN, "project", "p6", { title: "P", status: "active" });
    store.push([{ clientOpId: opId("pause"), op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: true } }], HUMAN);
    const r = upsert(store, AGENT, "project", "p6", { notes: "Brief" }, 0);
    assert.equal(r.status === "rejected" && r.reason, "paused");
  });

  it("refuses agent writes to the retired project context", async () => {
    const { store } = await createTestTaskStore();
    upsert(store, HUMAN, "project", "p7", { title: "P", status: "active" });
    const r = upsert(store, AGENT, "project", "p7", { context: "x" });
    assert.equal(r.status === "rejected" && r.reason, "retired:context");
  });

  it("lets an agent change other project fields without a baseNoteRev", async () => {
    const { store } = await createTestTaskStore();
    upsert(store, HUMAN, "project", "p8", { title: "P", status: "active", notes: "Goal" });
    assert.equal(upsert(store, AGENT, "project", "p8", { title: "Renamed" }).status, "applied");
  });
});

describe("TaskStore notes migration (notesV1)", () => {
  it("merges project context into notes above the log and starts history", async () => {
    const { store, db } = await createTestTaskStore();
    upsert(store, HUMAN, "project", "m1", { title: "A", status: "active", notes: "Goal\n## Log\n### old", context: "Ctx text" });
    upsert(store, HUMAN, "project", "m2", { title: "B", status: "active", context: "Only context" });
    upsert(store, HUMAN, "area", "ma", { title: "Work", context: "Area notes" });
    // Pretend the data predates the migration.
    db.exec("UPDATE projects SET noteRev = NULL; UPDATE areas SET noteRev = NULL; DELETE FROM note_revisions; DELETE FROM meta WHERE key = 'notesV1';");

    const { store: restarted } = await createTestTaskStore(db);
    const m1 = restarted.readNote("project", "m1")!;
    assert.match(m1.notes!, /^Goal\n\n## Context \(merged \d{4}-\d{2}-\d{2}\)\n\nCtx text\n\n## Log\n### old$/);
    assert.equal(m1.noteRev, 2);
    assert.deepEqual(restarted.noteRevisions("project", "m1", null, 5, false).map((r) => r.reason), ["merge project context into notes", "first revision"]);
    const m2 = restarted.readNote("project", "m2")!;
    assert.match(m2.notes!, /^## Context \(merged [\d-]+\)\n\nOnly context\n$/);
    assert.equal(m2.noteRev, 1);
    assert.deepEqual(restarted.readNote("area", "ma"), { notes: "Area notes", noteRev: 1 });
    const ctx = db.prepare("SELECT context FROM projects WHERE id = 'm1'").get() as { context: string | null };
    assert.equal(ctx.context, null);

    // Runs once: a second restart changes nothing.
    const { store: again } = await createTestTaskStore(db);
    assert.equal(again.readNote("project", "m1")?.noteRev, 2);
  });
});
