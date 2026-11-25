import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Task references R0 (docs/TASK_REFERENCES_SPEC.md, ADR 0031, ADR 0033, #386).

const HUMAN = "app:mac-test";
const AGENT = "mcp:Claude Code";
type Store = Awaited<ReturnType<typeof createTestTaskStore>>["store"];

let seq = 0;
const opId = () => `refop_${++seq}_${Date.now()}`;

/// Every store method as a plain async call, as the Worker sees it.
function rpcFor(store: Store) {
  return new Proxy({}, {
    get: (_t, name) => async (...a: unknown[]) => (store as unknown as Record<string, (...x: unknown[]) => unknown>)[name as string](...a),
  }) as never;
}

async function harness() {
  const { store, db } = await createTestTaskStore();
  const { runWriteTool } = await import("../src/shadow/writes.ts");
  const { findByRef, refsOut } = await import("../src/shadow/refs.ts");
  const { listTasks, searchTasks } = await import("../src/shadow/mcp.ts");
  const rpc = rpcFor(store);
  const ctx = { store: rpc, timeZone: "UTC", actor: AGENT };
  const run = (name: string, args: Record<string, unknown>) => runWriteTool(ctx, name as never, args) as Promise<Record<string, never>>;
  const push = (actor: string, op: Record<string, unknown>) =>
    store.push([{ clientOpId: opId(), ...op } as never], actor).result.results[0] as { status: string; reason?: string; rev?: number };
  const ref = (id: string, fields: Record<string, unknown>) => ({ op: "upsert", entity: "taskRef", id, fields });
  const task = (id: string, fields: Record<string, unknown> = {}) => {
    assert.equal(push(HUMAN, { op: "upsert", entity: "task", id, fields: { title: id, status: "open", ...fields } }).status, "applied");
  };
  const keys = (id: string) => store.readTaskRefs(id).map((r) => r.key);
  const pulled = (includeRefs: boolean) => store.pull(0, 1000, true, true, true, includeRefs).changes.filter((c) => c.entity === "taskRef");
  const { taskRefId } = await import("../src/core/index.ts");
  return { store, db, rpc, run, push, ref, task, keys, pulled, taskRefId, findByRef, refsOut, listTasks, searchTasks };
}

const url = (n: number, kind = "issues") => `https://github.com/Acme/App/${kind}/${n}`;

describe("MCP references", () => {
  it("a task made with an email reference is found by the raw message link (R0 exit check)", async () => {
    const h = await harness();
    const created = await h.run("tasks_create", {
      title: "Answer the offer",
      refs: [{ key: "email:<CAF+abc@Mail.Example.COM>", role: "from", snapshot: { title: "Offer", subtitle: "ada@example.com" } }],
    }) as unknown as { id: string; refs: unknown };
    assert.deepEqual(created.refs, [{ key: "email:CAF+abc@mail.example.com", kind: "email", role: "from" }]);
    const found = await h.findByRef(h.rpc, "message://%3CCAF%2Babc@MAIL.example.com%3E");
    assert.equal(found.key, "email:CAF+abc@mail.example.com");
    assert.deepEqual(found.tasks, [{ id: created.id, title: "Answer the offer", status: "open", role: "from" }]);
    assert.deepEqual(h.refsOut(h.store.readTaskRefs(created.id)), [{
      key: "email:CAF+abc@mail.example.com", kind: "email", role: "from",
      snapshot: { title: "Offer", subtitle: "ada@example.com", rawId: "CAF+abc@Mail.Example.COM" },
    }]);
    assert.equal(h.store.readTaskRefs(created.id)[0].createdBy, AGENT);
  });

  it("an invalid key creates nothing, and the error does not hold the key", async () => {
    const h = await harness();
    await assert.rejects(
      h.run("tasks_create", { title: "X", refs: [{ key: "https://user:secret@example.com/a" }] }),
      (e: Error) => /refs\[0\]\.key is not a valid reference/.test(e.message) && !e.message.includes("secret"),
    );
    assert.equal(h.store.readTasks("open", 10).total, 0);
    await assert.rejects(h.findByRef(h.rpc, "not a key"), /not a valid reference/);
  });

  it("updates by key, adds, removes and replaces at the limit", async () => {
    const h = await harness();
    const refs = Array.from({ length: 20 }, (_, i) => ({ key: `issue:a/b#${i + 1}` }));
    const { id } = await h.run("tasks_create", { title: "Full", refs }) as unknown as { id: string };
    assert.equal(h.keys(id).length, 20);
    await assert.rejects(h.run("tasks_update", { id, refs: [{ key: "issue:a/b#21" }] }), /at most 20 references/);
    assert.equal(h.keys(id).length, 20);
    const r = await h.run("tasks_update", {
      id, title: "Fuller", refs: [{ key: "issue:a/b#21" }, { key: "ISSUE:A/B#2", role: "blocked_by", snapshot: { title: "Two" } }],
      refs_remove: ["https://github.com/a/b/issues/1", "issue:none/none#1"],
    }) as unknown as { updated: string[] };
    assert.deepEqual(r.updated, ["title", "refs_remove", "refs"]);
    assert.equal(h.keys(id).length, 20);
    assert.ok(!h.keys(id).includes("issue:a/b#1"));
    const two = h.store.readTaskRefs(id).find((x) => x.key === "issue:a/b#2")!;
    assert.equal(two.role, "blocked_by");
    assert.equal((two.snapshot as { title: string }).title, "Two");
    assert.equal(h.keys(id).at(-1), "issue:a/b#21");
    // The same key again changes nothing.
    assert.deepEqual(await h.run("tasks_update", { id, refs: [{ key: "issue:a/b#21" }] }), { id, updated: [] });
    await assert.rejects(h.run("tasks_update", { id, refs: [{ key: "issue:a/b#3" }], refs_remove: ["issue:a/b#3"] }), /same key/);
  });

  it("shortens title and subtitle to fit, and the store rejects a snapshot over the cap", async () => {
    const h = await harness();
    const { id } = await h.run("tasks_create", {
      title: "Long", refs: [{ key: "email:a@B.c", snapshot: { title: "é".repeat(2000), subtitle: "s".repeat(2000) } }],
    }) as unknown as { id: string };
    const s = h.store.readTaskRefs(id)[0].snapshot as Record<string, string>;
    assert.ok(new TextEncoder().encode(JSON.stringify(s)).length <= 2048);
    assert.equal(s.rawId, "a@B.c");
    assert.ok(s.title.length > 0);
    const { zPushBody } = await import("../src/store/ops.ts");
    const body = (fields: Record<string, unknown>) => zPushBody.safeParse({
      ops: [{ clientOpId: "op-12345678", op: "upsert", entity: "taskRef", id: "ref-1", fields: { taskId: "t", key: "email:a@b.c", ...fields } }],
    }).success;
    assert.equal(body({ snapshot: { title: "ok" } }), true);
    assert.equal(body({ snapshot: { title: "é".repeat(1100) } }), false);
    assert.equal(body({ snapshot: { url: "javascript:alert(1)" } }), false);
    assert.equal(body({ snapshot: { body: "no" } }), false);
    assert.equal(body({ kind: "email" }), false);
    assert.equal(body({ createdBy: "app:x" }), false);
    assert.equal(body({ lastSeenAt: "2026-11-24T10:00:00Z" }), false);
    assert.equal(body({ role: "other" }), false);
  });

  it("finds active tasks first and leaves deleted tasks out", async () => {
    const h = await harness();
    for (const [id, fields] of [["open1", {}], ["done1", { status: "done" }], ["gone1", {}]] as const) {
      h.task(id, fields);
      h.push(HUMAN, h.ref(h.taskRefId(id, "url:https://example.com/a", 0), { taskId: id, key: "url:https://example.com/a" }));
    }
    h.push(HUMAN, { op: "upsert", entity: "task", id: "done1", fields: { title: "touched last" } });
    h.push(HUMAN, { op: "delete", entity: "task", id: "gone1" });
    const found = await h.findByRef(h.rpc, "https://EXAMPLE.com/a?utm_source=x#top");
    assert.deepEqual(found.tasks.map((t) => t.id), ["open1", "done1"]);
    assert.equal(found.total, 2);
    assert.deepEqual((await h.findByRef(h.rpc, "task:open1")).tasks, []);
  });

  it("a repeating task's next occurrence copies the about references only", async () => {
    const h = await harness();
    const { id } = await h.run("tasks_create", {
      title: "Weekly", scheduled: "2026-11-24", recurrence: { unit: "week" },
      refs: [{ key: "issue:a/b#1", snapshot: { title: "One" } }, { key: "email:a@b.c", role: "from" }, { key: "task:zzz", role: "blocked_by" }],
    }) as unknown as { id: string };
    const done = await h.run("tasks_complete", { id }) as unknown as { nextOccurrence: { id: string } };
    assert.deepEqual(h.keys(done.nextOccurrence.id), ["issue:a/b#1"]);
    const [copy] = h.store.readTaskRefs(done.nextOccurrence.id);
    assert.equal(copy.id, h.taskRefId(done.nextOccurrence.id, "issue:a/b#1", 0));
    assert.deepEqual(copy.snapshot, { title: "One" });
  });
});

describe("capture without duplicates (§6.2, #496)", () => {
  type Created = { id: string; placement: string; matched_keys?: string[]; follow_up?: { id: string }; refs?: { key: string }[] };
  const MAIL = { key: "email:<a@Example.com>", role: "from" };
  const setup = async () => {
    const h = await harness();
    const create = async (args: Record<string, unknown> = {}) =>
      await h.run("tasks_create", { title: "Answer", refs: [MAIL], ...args }) as unknown as Created;
    const open = () => h.store.readTasks("open", 10).total;
    const seen = (id: string) => h.store.readTaskRefs(id)[0].lastSeenAt as string | null;
    const set = (id: string, fields: Record<string, unknown>) => h.push(HUMAN, { op: "upsert", entity: "task", id, fields });
    return { ...h, create, open, seen, set };
  };

  it("a second create from the same item returns the task, also in parallel", async () => {
    const h = await setup();
    const [a, b] = await Promise.all([h.create(), h.create({ title: "Other words" })]);
    assert.equal(h.open(), 1);
    assert.deepEqual([a.placement, b.placement].sort(), ["existing", "inbox_proposal"]);
    assert.equal(a.id, b.id);
    const again = await h.create({ refs: [{ key: "message://%3Ca@EXAMPLE.com%3E", role: "from" }] });
    assert.equal(again.placement, "existing");
    assert.deepEqual(again.matched_keys, ["email:a@example.com"]);
  });

  it("stamps the reference and the task's history says captured again", async () => {
    const h = await setup();
    const { id } = await h.create();
    assert.equal(h.seen(id), null);
    const rev = h.store.head();
    await h.create();
    assert.ok(h.seen(id));
    assert.equal(h.store.head(), rev + 1);
    const entry = h.store.history(null, id, null, 1)[0];
    assert.deepEqual([entry.op, entry.actor, entry.diff?.lastSeenAt?.[0]], ["capture", AGENT, null]);
    const { runAgentTool } = await import("../src/shadow/agent.ts");
    const { activity } = await runAgentTool(h.rpc, "c", "tasks_activity", { id }) as { activity: { what: string }[] };
    assert.equal(activity[0].what, "captured again");
    assert.equal(h.pulled(true).length, 1);
  });

  it("allow_duplicate creates the task", async () => {
    const h = await setup();
    const a = await h.create();
    const b = await h.create({ allow_duplicate: true });
    assert.notEqual(a.id, b.id);
    assert.equal(b.placement, "inbox_proposal");
    assert.equal(b.follow_up, undefined);
    assert.ok(h.seen(a.id));
  });

  it("only from references match: about never blocks, on either side", async () => {
    const h = await setup();
    const about = await h.create({ refs: [{ ...MAIL, role: "about" }] });
    const from = await h.create();
    assert.notEqual(from.id, about.id);
    assert.equal(from.follow_up, undefined);
    assert.notEqual((await h.create({ refs: [{ ...MAIL, role: "about" }] })).placement, "existing");
    assert.equal(h.open(), 3);
  });

  it("only closed tasks have the key: a new task with a follow_up reference", async () => {
    for (const closed of [{ status: "done" }, { status: "cancelled" }, { fadedAt: "2026-11-20T10:00:00Z" }]) {
      const h = await setup();
      const old = await h.create({ origin: "user_request" });
      h.set(old.id, closed);
      const next = await h.create();
      assert.equal(next.placement, "inbox_proposal");
      assert.equal(next.follow_up?.id, old.id);
      assert.deepEqual(h.keys(next.id), ["email:a@example.com", `task:${old.id}`]);
      assert.equal(h.store.readTaskRefs(next.id)[1].role, "follow_up");
      assert.ok(h.seen(old.id));
      assert.equal(h.seen(next.id), null);
      // The new task is the active one now.
      assert.equal((await h.create()).id, next.id);
    }
  });

  it("a deleted task gets no stamp and no follow_up", async () => {
    const h = await setup();
    const old = await h.create({ origin: "user_request" });
    h.push(HUMAN, { op: "delete", entity: "task", id: old.id });
    const next = await h.create();
    assert.equal(next.follow_up, undefined);
    assert.deepEqual(h.keys(next.id), ["email:a@example.com"]);
  });

  it("several active tasks: the most recently touched one", async () => {
    const h = await setup();
    const a = await h.create();
    const b = await h.create({ allow_duplicate: true });
    h.set(b.id, { touchedAt: "2026-11-25T10:00:00.000Z" });
    h.set(a.id, { touchedAt: "2026-11-25T11:00:00.000Z" });
    h.set(b.id, { title: "a later write that is not a touch" });
    assert.equal((await h.create()).id, a.id);
  });

  it("an agent does not stamp a stopped task, or while agents are paused", async () => {
    const h = await setup();
    const { id } = await h.create();
    h.push(HUMAN, { op: "upsert", entity: "convo", id, fields: { stoppedAt: "2026-11-25T10:00:00Z" } });
    assert.equal((await h.create()).placement, "existing");
    assert.equal(h.seen(id), null);
    h.push(HUMAN, { op: "upsert", entity: "convo", id, fields: { stoppedAt: null } });
    h.push(HUMAN, { op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: true } });
    assert.equal((await h.create()).placement, "existing");
    assert.equal(h.seen(id), null);
  });
});

describe("turned-down proposals (#497)", () => {
  type Created = { id: string; placement: string; matched_keys?: string[] };
  const MAIL = { key: "email:<a@Example.com>", role: "from" };
  const setup = async () => {
    const h = await harness();
    const create = async (args: Record<string, unknown> = {}) =>
      await h.run("tasks_create", { title: "Answer", refs: [MAIL], ...args }) as unknown as Created;
    const set = (id: string, fields: Record<string, unknown>) => h.push(HUMAN, { op: "upsert", entity: "task", id, fields });
    const del = (id: string, actor = HUMAN) => h.push(actor, { op: "delete", entity: "task", id });
    const dismissed = async () => (await h.findByRef(h.rpc, MAIL.key) as { dismissed?: boolean }).dismissed === true;
    return { ...h, create, set, del, dismissed };
  };

  it("a deleted or dropped proposal is not proposed again", async () => {
    for (const turnDown of ["delete", "drop"] as const) {
      const h = await setup();
      const { id } = await h.create();
      assert.equal(await h.dismissed(), false);
      if (turnDown === "delete") h.del(id); else h.set(id, { status: "cancelled" });
      assert.equal(await h.dismissed(), true);
      const again = await h.create({ title: "Other words" });
      assert.equal(again.placement, "dismissed");
      assert.equal(again.id, undefined);
      assert.deepEqual(again.matched_keys, ["email:a@example.com"]);
      assert.equal(h.store.readTasks("open", 10).total, 0);
    }
  });

  it("a user request and allow_duplicate are never blocked; a person's capture neither", async () => {
    const h = await setup();
    h.del((await h.create()).id);
    const asked = await h.create({ origin: "user_request" });
    assert.equal(asked.placement, "committed");
    h.set(asked.id, { status: "done" });
    assert.equal((await h.create()).placement, "dismissed");
    assert.equal((await h.create({ allow_duplicate: true })).placement, "inbox_proposal");
    // The active task wins over the memory.
    assert.equal((await h.create()).placement, "existing");
    const { runWriteTool } = await import("../src/shadow/writes.ts");
    const h2 = await setup();
    h2.del((await h2.create()).id);
    const own = await runWriteTool(
      { store: h2.rpc, timeZone: "UTC", actor: HUMAN, source: { source: "app", sourceClient: "orb" } },
      "tasks_create", { title: "Mine", refs: [MAIL] },
    ) as Created;
    assert.ok(own.id);
    // A person added the key to a task: the memory is gone.
    assert.equal(await h2.dismissed(), false);
  });

  it("only a person's refusal of an unaccepted proposal counts", async () => {
    const accepted = await setup();
    const a = await accepted.create();
    accepted.set(a.id, { acknowledgedAt: "2026-11-25T10:00:00Z" });
    accepted.set(a.id, { status: "cancelled" });
    assert.equal(await accepted.dismissed(), false);
    const done = await setup();
    const d = await done.create();
    done.set(d.id, { status: "done" });
    done.del(d.id);
    assert.equal(await done.dismissed(), false);
    const agent = await setup();
    const c = await agent.create();
    await agent.run("tasks_update", { id: c.id, status: "cancelled" });
    assert.equal(await agent.dismissed(), false);
  });

  it("reopening the task clears the memory", async () => {
    const h = await setup();
    const { id } = await h.create();
    h.set(id, { status: "cancelled" });
    h.set(id, { status: "open" });
    assert.equal(await h.dismissed(), false);
    assert.equal((await h.create()).placement, "existing");
  });

  it("holds through the purge of the deleted task, for a year, with the key and the time only", async () => {
    const h = await setup();
    h.del((await h.create()).id);
    h.db.exec("UPDATE tasks SET deletedAt = '2020-01-01T00:00:00Z'; UPDATE task_refs SET deletedAt = '2020-01-01T00:00:00Z'");
    await h.store.alarm();
    assert.equal(h.db.prepare("SELECT COUNT(*) AS n FROM tasks").get()!.n, 0);
    assert.equal((await h.create()).placement, "dismissed");
    const cols = h.db.prepare("PRAGMA table_info(dismissed_refs)").all().map((r) => r.name);
    assert.deepEqual(cols, ["key", "at"]);
    h.db.exec("UPDATE dismissed_refs SET at = '2025-01-01T00:00:00Z'");
    await h.store.alarm();
    assert.equal((await h.create()).placement, "inbox_proposal");
  });

  it("a new message in a turned-down thread is a new item", async () => {
    const h = await setup();
    const thread = { key: "thread:root@example.com", role: "from" };
    h.del((await h.create({ refs: [MAIL, thread] })).id);
    const next = await h.create({ refs: [{ key: "email:b@example.com", role: "from" }, thread] });
    assert.equal(next.placement, "inbox_proposal");
    h.set(next.id, { status: "done" });
    assert.equal((await h.create({ refs: [thread] })).placement, "dismissed");
  });
});

describe("TaskStore references", () => {
  it("normalises the key, derives the kind and keeps one live row per task and key", async () => {
    const h = await harness();
    h.task("t1");
    assert.equal(h.push(HUMAN, h.ref("ref-a", { taskId: "t1", key: "Issue:Acme/App#7" })).status, "applied");
    const [row] = h.store.readTaskRefs("t1");
    assert.equal(row.key, "issue:acme/app#7");
    assert.equal(row.kind, "issue");
    assert.equal(row.role, "about");
    assert.equal(row.createdBy, HUMAN);
    assert.ok(row.createdAt);
    assert.equal(h.push(HUMAN, h.ref("ref-b", { taskId: "t1", key: "url:https://github.com/acme/app/pull/7" })).reason, "duplicate_ref");
    assert.equal(h.push(HUMAN, h.ref("ref-c", { taskId: "t1", key: "nonsense" })).reason, "invalid_key");
    assert.equal(h.push(HUMAN, h.ref("ref-d", { taskId: "t1" })).reason, "missing_required:key");
    assert.equal(h.push(HUMAN, h.ref("ref-e", { taskId: "nope", key: "issue:a/b#1" })).reason, "unknown_task");
    assert.equal(h.push(HUMAN, h.ref("ref-a", { key: "issue:a/b#1" })).reason, "immutable:key");
    assert.equal(h.push(HUMAN, h.ref("ref-a", { taskId: "t2", key: "issue:acme/app#7" })).reason, "immutable:taskId,key");
  });

  it("keeps an unknown kind", async () => {
    const h = await harness();
    h.task("t1");
    assert.equal(h.push(HUMAN, h.ref("ref-a", { taskId: "t1", key: "zulip:Stream/Topic" })).status, "applied");
    assert.equal(h.store.readTaskRefs("t1")[0].kind, "zulip");
  });

  it("two offline devices that add one reference converge on one row", async () => {
    const h = await harness();
    h.task("t1");
    const id = h.taskRefId("t1", "issue:a/b#1", 0);
    const fields = { taskId: "t1", key: "issue:a/b#1", role: "about", position: 1, createdAt: "2026-11-24T10:00:00Z" };
    assert.equal(h.push(HUMAN, h.ref(id, fields)).status, "applied");
    assert.equal(h.push("app:ios-test", h.ref(id, { ...fields, role: "from", createdAt: "2026-11-24T11:00:00Z" })).status, "applied");
    assert.equal(h.push("app:ios-test", h.ref(id, { taskId: "t1", key: "issue:a/b#1" })).status, "noop");
    const rows = h.store.readTaskRefs("t1");
    assert.equal(rows.length, 1);
    assert.equal(rows[0].role, "from");
    assert.equal(rows[0].createdAt, "2026-11-24T10:00:00Z");
    assert.equal(rows[0].createdBy, HUMAN);
  });

  it("a reference added again gets a new id, and a deleted row stays deleted", async () => {
    const h = await harness();
    h.task("t1");
    const key = "issue:a/b#1";
    const first = h.store.newRefId("t1", key);
    assert.equal(first, h.taskRefId("t1", key, 0));
    h.push(HUMAN, h.ref(first, { taskId: "t1", key }));
    h.push(HUMAN, { op: "delete", entity: "taskRef", id: first });
    assert.equal(h.push(HUMAN, h.ref(first, { taskId: "t1", key })).status, "dropped");
    const second = h.store.newRefId("t1", key);
    assert.equal(second, h.taskRefId("t1", key, 1));
    assert.equal(h.push(HUMAN, h.ref(second, { taskId: "t1", key })).status, "applied");
    h.push(HUMAN, { op: "delete", entity: "taskRef", id: second });
    // A purged tombstone lowers the count; the id in use is never minted.
    h.db.exec(`DELETE FROM task_refs WHERE id = '${first}'`);
    assert.equal(h.store.newRefId("t1", key), h.taskRefId("t1", key, 2));
  });

  it("limits a task to 20 references", async () => {
    const h = await harness();
    h.task("t1");
    for (let i = 1; i <= 20; i++) assert.equal(h.push(HUMAN, h.ref(`ref-${i}`, { taskId: "t1", key: `issue:a/b#${i}` })).status, "applied");
    assert.equal(h.push(HUMAN, h.ref("ref-21", { taskId: "t1", key: "issue:a/b#21" })).reason, "ref_limit_exceeded");
    h.push(HUMAN, { op: "delete", entity: "taskRef", id: "ref-1" });
    assert.equal(h.push(HUMAN, h.ref("ref-21", { taskId: "t1", key: "issue:a/b#21" })).status, "applied");
  });

  it("pulls references only for a client that asks, and a purged task takes them along", async () => {
    const h = await harness();
    h.task("t1");
    h.push(HUMAN, h.ref("ref-a", { taskId: "t1", key: "issue:a/b#1" }));
    assert.equal(h.pulled(false).length, 0);
    assert.equal(h.pulled(true).length, 1);
    h.push(HUMAN, { op: "delete", entity: "task", id: "t1" });
    assert.ok(h.pulled(true)[0].row.deletedAt);
    assert.equal(h.store.readTaskRefs("t1").length, 0);
  });

  it("a stopped task and a paused account refuse agent reference writes", async () => {
    const h = await harness();
    h.task("t1");
    h.task("t2");
    h.push(HUMAN, h.ref("ref-a", { taskId: "t1", key: "issue:a/b#1" }));
    h.push(HUMAN, { op: "upsert", entity: "convo", id: "t1", fields: { stoppedAt: "2026-11-24T10:00:00Z" } });
    assert.equal(h.push(AGENT, h.ref("ref-b", { taskId: "t1", key: "issue:a/b#2" })).reason, "stopped");
    assert.equal(h.push(AGENT, h.ref("ref-a", { taskId: "t2", role: "from" })).reason, "stopped");
    assert.equal(h.push(AGENT, { op: "delete", entity: "taskRef", id: "ref-a" }).reason, "stopped");
    assert.equal(h.push(HUMAN, h.ref("ref-b", { taskId: "t1", key: "issue:a/b#2" })).status, "applied");
    await assert.rejects(h.run("tasks_update", { id: "t1", refs_remove: ["issue:a/b#1"] }), /stopped/);

    h.push(HUMAN, { op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: true } });
    assert.equal(h.push(AGENT, h.ref("ref-c", { taskId: "t2", key: "issue:a/b#3" })).reason, "paused");
    await assert.rejects(h.run("tasks_update", { id: "t2", refs: [{ key: "issue:a/b#3" }] }), /paused/);
    const updated = await h.run("tasks_update", { id: "t2", title: "Renamed", refs: [{ key: "issue:a/b#3" }] }) as unknown as Record<string, unknown>;
    assert.deepEqual(updated.updated, ["title"]);
    assert.equal((updated.refs_refused as { reason: string }[])[0].reason, "paused");
    // A create still works; the refused reference is named, not dropped.
    const created = await h.run("tasks_create", { title: "New", refs: [{ key: "issue:a/b#4" }] }) as unknown as Record<string, unknown>;
    assert.equal(created.refs, undefined);
    assert.equal((created.refs_refused as { key: string; reason: string }[])[0].reason, "paused");
  });
});

describe("Issue links become references (§6.6)", () => {
  it("adds references from an agent's artifact, handoff, end-state note and turn", async () => {
    const h = await harness();
    h.task("t1");
    await h.run("tasks_set_artifact", { id: "t1", artifact: { title: "Plan", body: `See ${url(2)}.`, refs: [url(1)] } });
    await h.run("tasks_set_handoff", { id: "t1", handoff: { instruction: "Merge", actionType: "open_url", payload: url(3, "pull") } });
    await h.run("tasks_set_endstate", { id: "t1", endState: "decomposed", note: `Tracked in ${url(4)}` });
    await h.run("tasks_thread_append", { id: "t1", turn: { role: "provider", step: "work", note: `and ${url(5)}` } });
    assert.deepEqual([...h.keys("t1")].sort(), [1, 2, 3, 4, 5].map((n) => `issue:acme/app#${n}`));
    const list = await h.listTasks(h.rpc, "UTC", "all", 10);
    assert.deepEqual(list.tasks[0].issue, { url: url(5), repo: "Acme/App", number: 5, kind: "issue" });
    assert.equal(list.tasks[0].refCount, 5);
    const three = h.store.readTaskRefs("t1").find((r) => r.key === "issue:acme/app#3")!;
    assert.deepEqual(three.snapshot, { url: url(3, "pull"), rawId: "Acme/App#3" });
    assert.equal(three.role, "about");
    assert.equal(three.createdBy, AGENT);
  });

  it("the first link of one write is the newest issue", async () => {
    const h = await harness();
    h.task("t1");
    await h.run("tasks_set_artifact", { id: "t1", artifact: { title: "x", refs: [url(1), url(2)] } });
    assert.equal((await h.listTasks(h.rpc, "UTC", "all", 10)).tasks[0].issue?.number, 1);
    // An edit to an older reference does not make it the newest.
    await h.run("tasks_update", { id: "t1", refs: [{ key: "issue:acme/app#2", snapshot: { title: "Two" } }] });
    const found = await h.searchTasks(h.rpc, "UTC", { query: "t1" });
    assert.equal(found.tasks[0].issue?.number, 1);
  });

  it("a user's own removal wins, an agent's does not, and a user can add it again", async () => {
    const h = await harness();
    h.task("t1");
    const write = () => h.run("tasks_set_endstate", { id: "t1", endState: "open", note: url(1) });
    const rowId = () => h.store.readTaskRefs("t1")[0].id as string;
    await write();
    assert.equal(h.push(AGENT, { op: "delete", entity: "taskRef", id: rowId() }).status, "applied");
    await write();
    assert.equal(h.keys("t1").length, 1);
    assert.equal(h.push(HUMAN, { op: "delete", entity: "taskRef", id: rowId() }).status, "applied");
    await write();
    assert.equal(h.keys("t1").length, 0);
    assert.equal(h.store.backfillIssueRefs(), 0);
    assert.equal(h.push(HUMAN, h.ref(h.store.newRefId("t1", "issue:acme/app#1"), { taskId: "t1", key: "issue:acme/app#1" })).status, "applied");
    assert.equal(h.push(AGENT, { op: "delete", entity: "taskRef", id: rowId() }).status, "applied");
    await write();
    assert.equal(h.keys("t1").length, 1);
  });

  it("adds nothing from the app, over the limit, while paused, or to a stopped task", async () => {
    const h = await harness();
    h.task("t1");
    h.push(HUMAN, { op: "upsert", entity: "convo", id: "t1", fields: { endStateNote: url(1) } });
    assert.equal(h.keys("t1").length, 0);
    for (let i = 1; i <= 19; i++) h.push(HUMAN, h.ref(`ref-${i}`, { taskId: "t1", key: `task:x${i}` }));
    await h.run("tasks_set_artifact", { id: "t1", artifact: { title: "x", refs: [url(1), url(2)] } });
    assert.equal(h.keys("t1").length, 20);
    assert.ok(h.keys("t1").includes("issue:acme/app#1"));
    h.task("t2");
    h.push(HUMAN, { op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: true } });
    await h.run("tasks_thread_append", { id: "t2", turn: { role: "provider", step: "work", note: url(1) } });
    assert.equal(h.keys("t2").length, 0);
  });

  it("backfills one reference per task once, in the app's search order", async () => {
    const h = await harness();
    const convo = (id: string, fields: Record<string, unknown>) => h.push(HUMAN, { op: "upsert", entity: "convo", id, fields });
    const turn = (id: string, t: Record<string, unknown>) =>
      h.push(HUMAN, { op: "appendTurn", taskId: id, turn: { step: "work", ts: "2026-11-24T10:00:00Z", ...t } });
    for (const id of ["refs", "body", "title", "payload", "note", "turn", "has", "user", "none", "gone", "done"]) h.task(id);
    const artifact = { kind: "x", title: url(3), body: url(2), refs: ["no link", url(1, "pull")] };
    const rest = { handoff: { instruction: "go", actionType: "open_url", payload: url(4) }, endStateNote: url(5) };
    convo("refs", { artifact, ...rest });
    convo("body", { artifact: { ...artifact, refs: [] }, ...rest });
    convo("title", { artifact: { ...artifact, refs: [], body: "" }, ...rest });
    convo("payload", rest);
    convo("note", { endStateNote: url(5) });
    turn("note", { role: "provider", note: url(9) });
    turn("turn", { role: "provider", note: url(6) });
    turn("turn", { role: "provider", question: url(7), note: "no link, github.com/ only" });
    turn("turn", { role: "user", note: url(8) });
    turn("turn", { role: "provider", note: "https://github.com/Acme/App" });
    convo("has", { endStateNote: url(5) });
    h.push(HUMAN, h.ref("ref-has", { taskId: "has", key: "issue:acme/app#5" }));
    turn("user", { role: "user", note: url(8) });
    convo("gone", { endStateNote: url(5) });
    h.push(HUMAN, { op: "delete", entity: "task", id: "gone" });
    convo("done", { endStateNote: url(5) });
    h.push(HUMAN, { op: "upsert", entity: "task", id: "done", fields: { status: "done" } });

    // The store restarts on data from before R0.
    h.db.exec("DELETE FROM meta WHERE key = 'issueRefsV1'");
    const { store } = await createTestTaskStore(h.db);
    const got = (id: string) => store.readTaskRefs(id).map((r) => r.key);
    const want: Record<string, number | null> = {
      refs: 1, body: 2, title: 3, payload: 4, note: 5, turn: 7, has: 5, user: null, none: null, gone: null, done: 5,
    };
    for (const [id, n] of Object.entries(want)) assert.deepEqual(got(id), n === null ? [] : [`issue:acme/app#${n}`], id);
    const [row] = store.readTaskRefs("refs");
    assert.equal(row.createdBy, "system:migration");
    assert.equal(row.role, "about");
    assert.deepEqual(row.snapshot, { url: url(1, "pull"), rawId: "Acme/App#1" });
    const links = new Map(store.readTaskLinks().map((l) => [l.id, l]));
    const { issueLink } = await import("../src/tools/taskShared.ts");
    const link = links.get("refs")!.issue!;
    assert.equal(issueLink(link.key, link.snapshot).kind, "pr");
    const head = store.head();
    assert.equal(store.backfillIssueRefs(), 0);
    assert.equal(store.head(), head, "a second run writes nothing");
  });
});
