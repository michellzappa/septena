import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

const { api } = await import("../src/api/routes.ts");
const { issueSession } = await import("../src/api/session.ts");

// Do (docs/DO_SPEC.md §2, §6, §7, ADR 0041).

const APP = "app:mac-test";
const AGENT = "mcp:claude";
let n = 0;
const op = (fields: object) => ({ clientOpId: `dosession_${++n}`, ...fields }) as never;
const ago = (minutes: number) => new Date(Date.now() - minutes * 60_000).toISOString();

async function setup() {
  const { store } = await createTestTaskStore();
  const task = (id: string, fields: object = {}) =>
    store.push([op({ op: "upsert", entity: "task", id, fields: { title: `Task ${id}`, status: "open", ...fields } })], APP);
  const start = (id: string, taskId: string, minutesAgo: number, fields: object = {}) => store.push([op({
    op: "upsert", entity: "doSession", id, fields: { taskId, startedAt: ago(minutesAgo), ...fields },
  })], APP).result.results[0];
  const edit = (id: string, fields: object, actor = APP) =>
    store.push([op({ op: "upsert", entity: "doSession", id, fields })], actor).result.results[0];
  const row = (id: string) => store.readDoSession(id) as Record<string, unknown>;
  task("a");
  task("b");
  return { store, task, start, edit, row };
}

describe("Do: rules in the store", () => {
  it("keeps one open and ends the older one where the newer one began", async () => {
    const { store, start, row } = await setup();
    start("s1", "a", 60);
    start("s2", "b", 30);
    assert.equal(store.readDoing()!.sessionId, "s2");
    assert.deepEqual([row("s1").exit, row("s1").endedAt, row("s1").lapsed], ["replaced", row("s2").startedAt, false]);
  });

  it("gives one result for two offline starts in either order of sync", async () => {
    const first = await setup();
    first.start("s1", "a", 60);
    first.start("s2", "b", 30);
    const second = await setup();
    second.start("s2", "b", 30);
    second.start("s1", "a", 60);
    for (const s of [first, second]) {
      assert.equal(s.store.readDoing()!.sessionId, "s2");
      assert.equal(s.row("s1").exit, "replaced");
      assert.equal(s.row("s1").endedAt, s.row("s2").startedAt);
    }
  });

  it("a Stop never touches a newer Do, and the earliest end wins", async () => {
    const { store, start, edit, row } = await setup();
    start("s1", "a", 60);
    start("s2", "b", 30);
    // Arrives late, happened later than the replacement: loses.
    edit("s1", { endedAt: ago(5), exit: "stopped" });
    assert.equal(row("s1").exit, "replaced");
    // Arrives late, happened earlier: wins.
    const earlier = ago(50);
    edit("s1", { endedAt: earlier, exit: "stopped", note: "Page 4" });
    assert.deepEqual([row("s1").exit, row("s1").endedAt, row("s1").note], ["stopped", earlier, "Page 4"]);
    assert.equal(store.readDoing()!.sessionId, "s2");
  });

  it("a losing push still moves the row, so its device pulls what the store kept", async () => {
    const { store, start, edit } = await setup();
    start("s1", "a", 60);
    edit("s1", { endedAt: ago(40), exit: "stopped" });
    const since = store.head();
    edit("s1", { endedAt: ago(5), exit: "done" });
    const [pulled] = store.pull(since, 100, true, true, true, true, true).changes;
    assert.equal(pulled.entity, "doSession");
    assert.equal(pulled.row.exit, "stopped");
  });

  it("a closed row never opens again and takes only a note", async () => {
    const { start, edit, row } = await setup();
    start("s1", "a", 60);
    edit("s1", { endedAt: ago(40), exit: "stopped" });
    edit("s1", { endedAt: null, plannedMinutes: 25, confirmedAt: ago(1), note: "Half" });
    assert.deepEqual(
      [typeof row("s1").endedAt, row("s1").plannedMinutes, row("s1").confirmedAt, row("s1").note],
      ["string", null, null, "Half"],
    );
  });

  it("the task ends its Do on every route", async () => {
    for (const [fields, exit] of [[{ status: "done" }, "done"], [{ status: "cancelled" }, "closed"], [{ fadedAt: ago(0) }, "closed"]] as const) {
      const { store, task, start, row } = await setup();
      start("s1", "a", 10);
      task("a", fields);
      assert.equal(store.readDoing(), null);
      assert.equal(row("s1").exit, exit);
      // Undo opens the task. The Do stays ended.
      task("a", { status: "open", fadedAt: null });
      assert.equal(store.readDoing(), null);
    }
    const { store, start } = await setup();
    start("s1", "a", 10);
    store.push([op({ op: "delete", entity: "task", id: "a" })], APP);
    assert.equal(store.readDoing(), null);
    assert.equal(store.readDoSession("s1"), null);
  });

  it("a Do that was started and finished offline lands closed", async () => {
    const { store, task, start, row } = await setup();
    task("a", { status: "done" });
    start("s1", "a", 10);
    assert.equal(row("s1").exit, "done");
    assert.equal(store.readDoing(), null);
  });

  it("refuses a Do of no task or a heading, and a start in the future is now", async () => {
    const { task, start, row } = await setup();
    assert.equal(start("s1", "nope", 1).status, "rejected");
    task("h", { kind: "heading" });
    assert.equal(start("s2", "h", 1).status, "rejected");
    start("s3", "a", -60);
    assert.ok(Date.parse(row("s3").startedAt as string) <= Date.now());
  });

  it("old clients do not pull the entity", async () => {
    const { store, start } = await setup();
    start("s1", "a", 1);
    const has = (flag: boolean) => store.pull(0, 1000, true, true, true, true, flag).changes.some((c) => c.entity === "doSession");
    assert.deepEqual([has(false), has(true)], [false, true]);
  });

  it("is stale after four hours, and housekeeping ends it a day later", async () => {
    const { store, start, edit, row } = await setup();
    start("s1", "a", 5 * 60);
    assert.equal(store.readDoing()!.isStale, true);
    edit("s1", { confirmedAt: ago(0) });
    assert.equal(store.readDoing()!.isStale, false);

    const old = await setup();
    old.start("s1", "a", 10);
    const sql = (old.store as unknown as { sql: { exec(q: string, ...a: unknown[]): unknown } }).sql;
    sql.exec("UPDATE do_sessions SET startedAt = ? WHERE id = ?", ago(30 * 60), "s1");
    await old.store.alarm();
    assert.deepEqual([old.row("s1").exit, old.row("s1").lapsed], ["stopped", true]);
    assert.ok(row("s1"));
  });
});

describe("Do: agents", () => {
  it("cannot write a Do", async () => {
    const { start, edit, row } = await setup();
    start("s1", "a", 1);
    const r = edit("s1", { endedAt: ago(0), exit: "done" }, AGENT);
    assert.deepEqual([r.status, (r as { reason?: string }).reason], ["rejected", "human_only_do"]);
    assert.equal(row("s1").endedAt, null);
  });

  it("cannot claim the task, and a start ends a live claim", async () => {
    const { store, start, edit } = await setup();
    assert.equal(store.claim("a", "runner", 60_000, AGENT, null).ok, true);
    start("s1", "a", 0);
    const convo = store.readTask("a")!.convo as Record<string, unknown>;
    assert.equal(convo.claimedBy, null);
    const refused = store.claim("a", "runner", 60_000, AGENT, null);
    assert.equal(refused.ok === false && refused.reason, "doing");
    assert.equal(store.claim("b", "runner", 60_000, AGENT, null).ok, true);
    edit("s1", { endedAt: new Date().toISOString(), exit: "stopped" });
    assert.equal(store.claim("a", "runner", 60_000, AGENT, null).ok, true);
  });

  it("hears when a Do starts and ends", async () => {
    const { store, start, edit } = await setup();
    const since = store.head();
    start("s1", "a", 1);
    edit("s1", { endedAt: ago(0), exit: "stopped" });
    assert.deepEqual(
      store.agentEvents(since, 100).events.map((e) => [e.kind, e.taskId]),
      [["do_started", "a"], ["do_ended", "a"]],
    );
  });

  it("a question's push waits during a Do and not during a stale one", async () => {
    const { store, start } = await setup();
    let sent = 0;
    Object.assign(store, { listPushTokens: () => [{}], dispatchAgentPushes: async () => { sent++; } });
    const ask = () => store.push([op({
      op: "appendTurn", taskId: "b",
      turn: { role: "provider", step: "scope", question: "Which?", options: ["Red", "Blue"], ts: "2026-11-24T11:00:00Z" },
    })], AGENT);
    start("s1", "a", 1);
    ask();
    assert.equal(sent, 0);
    assert.equal(store.readOpenQuestions(10).total, 1);
    start("s2", "a", 0);
    const sql = (store as unknown as { sql: { exec(q: string, ...a: unknown[]): unknown } }).sql;
    sql.exec("UPDATE do_sessions SET startedAt = ? WHERE id = 's2'", ago(5 * 60));
    sql.exec("UPDATE do_sessions SET startedAt = ? WHERE id = 's1'", ago(6 * 60));
    ask();
    assert.equal(sent, 1);
  });
});

async function device() {
  const { store } = await createTestTaskStore();
  const kv = () => ({ get: async () => null, put: async () => {}, delete: async () => {}, list: async () => ({ keys: [], list_complete: true }) });
  const env = {
    API_PUBLIC_URL: "https://api.septena.app",
    APPLE_AUDIENCES: "com.septena.tasks",
    ENTITLEMENT_ENFORCE: "false",
    APPLE_IAP_BUNDLE_IDS: "com.septena.tasks",
    APPLE_IAP_ENVIRONMENTS: "Production,Sandbox",
    SESSION_SIGNING_KEY: btoa(String.fromCharCode(...new Uint8Array(32).fill(7))),
    STATE: kv(), TOKENS: kv(), CLIENTS: kv(),
    TASK_STORE: { idFromName: (name: string) => name, get: () => store },
    ATTACHMENTS: {},
  } as never;
  const session = await issueSession(env, "u_do_test_1234567890abcdef");
  const headers = {
    Authorization: `Bearer ${session.accessToken}`, "Content-Type": "application/json",
    "X-Septena-Client": "Septena Orb", "X-Septena-TimeZone": "UTC",
  };
  const call = async (method: string, path: string, body?: object) => {
    const res = await api.request(`https://api.septena.app${path}`, { method, headers, body: body && JSON.stringify(body) }, env);
    return { status: res.status, body: (await res.json()) as Record<string, any> };
  };
  const task = (id: string, fields: object = {}) =>
    store.push([op({ op: "upsert", entity: "task", id, fields: { title: `Task ${id}`, status: "open", notes: "private", ...fields } })], APP);
  task("a");
  return { store, call, task };
}

describe("Do: thin clients", () => {
  it("starts once, shows in every view, and stops by its own id", async () => {
    const { store, call } = await device();
    const first = await call("POST", "/tasks/a/do", { sessionId: "sess-1", plannedMinutes: 25 });
    assert.equal(first.status, 201);
    const again = await call("POST", "/tasks/a/do", { sessionId: "sess-1", plannedMinutes: 25 });
    assert.deepEqual([again.status, again.body.alreadyStarted], [200, true]);
    for (const view of ["today", "review", "questions", "added", "upcoming"]) {
      const { body } = await call("GET", `/tasks?view=${view}`);
      assert.deepEqual([body.doing.sessionId, body.doing.title, body.doing.plannedMinutes, body.doing.notes], ["sess-1", "Task a", 25, undefined]);
      assert.ok(body.doing.now && body.doing.staleAt);
    }
    assert.ok(store.readTask("a")!.task.touchedAt);
    assert.equal((await call("POST", "/tasks/do/nope/stop")).status, 404);
    assert.equal((await call("POST", "/tasks/do/sess-1/stop", { note: "Page 4" })).status, 200);
    assert.equal((await call("POST", "/tasks/do/sess-1/stop")).body.alreadyEnded, true);
    assert.equal(store.readDoSession("sess-1")!.note, "Page 4");
    assert.equal((await call("GET", "/tasks?view=today")).body.doing, null);
  });

  it("Done and Later end it, and a closed task cannot be done", async () => {
    const { store, call, task } = await device();
    await call("POST", "/tasks/a/do", { sessionId: "s1" });
    assert.equal((await call("POST", "/tasks/a/defer", { until: "2030-01-01", session: "s1" })).status, 200);
    assert.equal(store.readDoSession("s1")!.exit, "later");
    task("b");
    await call("POST", "/tasks/b/do", { sessionId: "s2" });
    await call("POST", "/tasks/b/complete");
    assert.equal(store.readDoSession("s2")!.exit, "done");
    assert.equal((await call("POST", "/tasks/b/do", { sessionId: "s3" })).status, 422);
    assert.equal((await call("POST", "/tasks/zzz/do", { sessionId: "s4" })).status, 404);
  });

  it("starting a faded task keeps it", async () => {
    const { store, call, task } = await device();
    task("f", { fadedAt: ago(60) });
    await call("POST", "/tasks/f/do", { sessionId: "s1" });
    assert.equal(store.readTask("f")!.task.fadedAt, null);
    assert.equal(store.readDoing()!.sessionId, "s1");
  });
});
