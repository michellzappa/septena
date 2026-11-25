import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

const { api } = await import("../src/api/routes.ts");
const { issueSession } = await import("../src/api/session.ts");

// docs/COMPANION_DEVICES_SPEC.md §2 and §3, over the routes a device calls.

let n = 0;
const op = (fields: object) => ({ clientOpId: `cmp_${++n}`, ...fields }) as never;

const kv = () => ({ get: async () => null, put: async () => {}, delete: async () => {}, list: async () => ({ keys: [], list_complete: true }) });

async function device() {
  const { store } = await createTestTaskStore();
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
  const session = await issueSession(env, "u_companion_test_1234567890");
  const headers = {
    Authorization: `Bearer ${session.accessToken}`,
    "Content-Type": "application/json",
    "X-Septena-Client": "Septena Orb",
    "X-Septena-TimeZone": "UTC",
  };
  const call = async (method: string, path: string, body?: object) => {
    const res = await api.request(`https://api.septena.app${path}`, { method, headers, body: body && JSON.stringify(body) }, env);
    return { status: res.status, body: (await res.json()) as Record<string, any> };
  };
  const ask = (id: string, options = ["Red", "Blue"]) => store.push([op({
    op: "appendTurn", taskId: id,
    turn: { role: "provider", step: "scope", question: "Which?", options, ts: "2026-11-24T11:00:00Z" },
  })], "mcp:claude");
  const task = (id: string, extra: object = {}) => store.push([op({
    op: "upsert", entity: "task", id, fields: { title: `Task ${id}`, status: "open", notes: "private", ...extra },
  })], "app:test");
  const handOver = (id: string) => store.push([op({
    op: "upsert", entity: "convo", id, fields: { assignee: "claude", endState: "needs_verify", endStateNote: "Check it" },
  })], "app:test");
  return { store, call, ask, task, handOver };
}

describe("companion devices: questions", () => {
  it("lists open questions only, without task notes", async () => {
    const { store, call, ask, task } = await device();
    for (const id of ["q1", "answered", "stopped", "plain", "done"]) task(id);
    for (const id of ["q1", "answered", "stopped", "done"]) ask(id);
    store.push([op({ op: "appendTurn", taskId: "answered", turn: { role: "user", step: "scope", chosen: "Red", inReplyTo: 1, ts: "2026-11-24T11:01:00Z" } })], "app:test");
    store.push([op({ op: "upsert", entity: "convo", id: "stopped", fields: { stoppedAt: "2026-11-24T11:02:00Z" } })], "app:test");
    store.push([op({ op: "upsert", entity: "task", id: "done", fields: { status: "done" } })], "app:test");
    const { status, body } = await call("GET", "/tasks?view=questions");
    assert.equal(status, 200);
    assert.equal(body.total, 1);
    const [t] = body.tasks;
    assert.deepEqual([t.id, t.question, t.options, t.turnSeq, t.notes], ["q1", "Which?", ["Red", "Blue"], 1, undefined]);
  });

  it("answers by option, in the question's own step, once", async () => {
    const { store, call, ask, task } = await device();
    task("q1");
    ask("q1");
    const first = await call("POST", "/tasks/q1/answer", { option: 1, inReplyTo: 1 });
    assert.equal(first.status, 200);
    const again = await call("POST", "/tasks/q1/answer", { option: 1, inReplyTo: 1 });
    assert.equal(again.status, 200);
    assert.equal(again.body.alreadyAnswered, true);
    const turns = store.readTask("q1")!.turns;
    assert.equal(turns.length, 2);
    assert.deepEqual([turns[1].role, turns[1].chosen, turns[1].step, turns[1].inReplyTo], ["user", "Blue", "scope", 1]);
    assert.equal(store.history("turn", "q1:2", null, 5)[0].actor, "app:Septena Orb");
  });

  it("refuses an answer to a question that is not the open one", async () => {
    const { store, call, ask, task } = await device();
    task("q1");
    ask("q1");
    ask("q1", ["Green", "Grey"]);
    assert.equal((await call("POST", "/tasks/q1/answer", { option: 0, inReplyTo: 1 })).status, 422);
    assert.equal((await call("POST", "/tasks/q1/answer", { option: 9, inReplyTo: 2 })).status, 400);
    assert.equal((await call("POST", "/tasks/q1/answer", { option: 0 })).status, 400);
    assert.equal((await call("POST", "/tasks/q1/answer", { option: 0, chosen: "Red", inReplyTo: 2 })).status, 400);
    assert.equal((await call("POST", "/tasks/nope/answer", { option: 0, inReplyTo: 1 })).status, 404);
    assert.equal(store.readTask("q1")!.turns.length, 2);
  });
});

describe("companion devices: review", () => {
  it("accepts the hand-off it saw, acknowledges an agent's task, and repeats safely", async () => {
    const { store, call, task, handOver } = await device();
    task("r1", { source: "mcp" });
    handOver("r1");
    const seen = (await call("GET", "/tasks?view=review")).body.tasks[0].reviewAt as string;
    assert.equal((await call("POST", "/tasks/r1/accept", { reviewAt: "2020-01-01T00:00:00.000Z" })).status, 422);
    assert.equal(store.readTask("r1")!.task.status, "open");
    assert.equal((await call("POST", "/tasks/r1/accept", { reviewAt: seen })).status, 200);
    const row = store.readTask("r1")!.task;
    assert.equal(row.status, "done");
    assert.ok(row.acknowledgedAt);
    assert.equal((await call("POST", "/tasks/r1/accept", { reviewAt: seen })).body.alreadyComplete, true);
  });

  it("sends back with a turn, opens the task for the agent, and refuses a second one", async () => {
    const { store, call, task, handOver } = await device();
    task("r1");
    handOver("r1");
    assert.equal((await call("POST", "/tasks/r1/send_back", {})).status, 200);
    const read = store.readTask("r1")!;
    assert.deepEqual(
      [read.convo?.endState, read.convo?.endStateNote, read.convo?.assignee, read.task.status],
      ["open", null, "claude", "open"],
    );
    assert.deepEqual([read.turns[0].role, read.turns[0].note], ["user", "Sent back without a note."]);
    assert.equal((await call("POST", "/tasks/r1/send_back", {})).status, 422);
    assert.equal(store.readTask("r1")!.turns.length, 1);
  });
});
