import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

// The agent comment loop end to end (issue #619, docs/AGENT_LOOP_AUDIT.md):
// the agent asks on a task, the user replies, the agent hears of the reply
// by webhook or by poll, reads it, and goes on. Each test names the hop of
// the audit it covers.

installWorkerTestHooks();

const { runAgentTool } = await import("../src/shadow/agent.ts");
const { deliverWebhookWithRetry, isRetryableWebhookStatus, verifyWebhookSignature } = await import("../src/api/agentWake.ts");

const HUMAN = "app:ios";
const CLIENT = "client-loop-1234";
const HOLDER = "runner:mini@client-l";
const AGENT = `mcp:${HOLDER}`;
const OTHER_HOLDER = "claude-chat@client-o";
const OTHER = `mcp:${OTHER_HOLDER}`;
const SECRET = "whsec_loop_test_1234567890abcdef";

let seq = 0;
const opId = () => `loopop_${++seq}`;

type Store = Awaited<ReturnType<typeof createTestTaskStore>>["store"];

interface Call { url: string; event: string; body: string; timestamp: string; signature: string }

/// Swaps globalThis.fetch for a recorder. `answer` decides each response.
function mockFetch(answer: (n: number) => Promise<Response> | Response) {
  const prev = globalThis.fetch;
  const calls: Call[] = [];
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const headers = init?.headers as Record<string, string>;
    calls.push({
      url: String(input),
      event: headers["X-Septena-Event"],
      body: String(init?.body ?? ""),
      timestamp: headers["X-Septena-Timestamp"],
      signature: headers["X-Septena-Signature"],
    });
    return answer(calls.length);
  }) as typeof fetch;
  return { calls, restore: () => { globalThis.fetch = prev; } };
}

function noRetryWaits(store: Store) {
  (store as unknown as { webhookRetryDelaysMs: number[] }).webhookRetryDelaysMs = [0, 0];
}

/// A task the user gave to the agent.
function assignTask(store: Store, id: string) {
  const r = store.push([
    { clientOpId: opId(), op: "upsert", entity: "task", id, fields: { title: "Plan the offsite", status: "open" } },
    { clientOpId: opId(), op: "upsert", entity: "convo", id, fields: { assignee: "claude" } },
  ], HUMAN);
  assert.ok(r.result.results.every((x) => x.status === "applied"));
}

function nextSeq(store: Store, id: string): number {
  return (store.readTask(id)?.turns.length ?? 0) + 1;
}

/// The agent's question: a provider turn with options.
function ask(store: Store, id: string, actor = AGENT) {
  return store.push([{
    clientOpId: opId(), op: "appendTurn", taskId: id,
    turn: { seq: nextSeq(store, id), role: "provider", step: "decide", question: "Which week?", options: ["Week 1", "Week 2"], ts: new Date().toISOString() },
  }], actor).result.results[0];
}

/// The user's reply, as the app sends it.
function reply(store: Store, id: string, chosen = "Week 2") {
  return store.push([{
    clientOpId: opId(), op: "appendTurn", taskId: id,
    turn: { seq: nextSeq(store, id), role: "user", step: "decide", chosen, inReplyTo: nextSeq(store, id) - 1, ts: new Date().toISOString() },
  }], HUMAN).result.results[0];
}

/// A plain agent note (no question).
function note(store: Store, id: string, text: string, actor = AGENT) {
  return store.push([{
    clientOpId: opId(), op: "appendTurn", taskId: id,
    turn: { seq: nextSeq(store, id), role: "provider", step: "work", note: text, ts: new Date().toISOString() },
  }], actor).result.results[0];
}

async function poll(store: Store, since?: number, limit?: number) {
  const args: Record<string, unknown> = {};
  if (since !== undefined) args.since = since;
  if (limit !== undefined) args.limit = limit;
  return await runAgentTool(store as never, CLIENT, "tasks_agent_events", args) as {
    paused: boolean; events: Array<{ rev: number; kind: string; taskId: string | null }>; nextSince: number;
  };
}

function claim(store: Store, id: string, holder = HOLDER, actor = AGENT, ttlMs = 30 * 60_000) {
  return store.claim(id, holder, ttlMs, actor, "work the task");
}

describe("agent comment loop: webhook path", () => {
  it("hop 1-6: question, reply, signed user_turn webhook, agent reads the reply and claims again", async () => {
    const hook = mockFetch(() => new Response(null, { status: 204 }));
    try {
      const { store, flushWaitUntil } = await createTestTaskStore();
      const created = store.createAgentWebhook("https://hooks.example.com/agent", SECRET, true);
      assert.equal(created.ok, true);
      assignTask(store, "t1");
      await flushWaitUntil();
      assert.deepEqual(hook.calls.map((c) => c.event), ["assigned"]);

      // Hop 1: the agent claims and asks. Asking ends the claim.
      assert.equal(claim(store, "t1").ok, true);
      assert.equal(ask(store, "t1").status, "applied");
      await flushWaitUntil();
      assert.equal(hook.calls.length, 1, "an agent's own turn wakes no agent");
      let convo = store.readTask("t1")?.convo;
      assert.equal(convo?.claimedBy, null);
      // Hop 2: the task waits for the user; the agent may not claim it.
      assert.equal(claim(store, "t1").ok, false);
      assert.equal((claim(store, "t1") as { reason: string }).reason, "your_turn");

      // Hop 3: the user replies.
      assert.equal(reply(store, "t1").status, "applied");
      await flushWaitUntil();

      // Hop 4: one signed, pointer-only user_turn webhook.
      assert.equal(hook.calls.length, 2);
      const call = hook.calls[1];
      assert.equal(call.event, "user_turn");
      assert.equal(await verifyWebhookSignature(SECRET, call.timestamp, call.body, call.signature), true);
      const body = JSON.parse(call.body) as { event: string; taskId: string; rev: number };
      assert.equal(body.taskId, "t1");
      assert.equal(call.body.includes("Week 2"), false, "the webhook carries no reply text");
      const wh = store.listAgentWebhooks()[0];
      assert.equal(wh.failureCount, 0);
      assert.equal(wh.lastStatus, 204);

      // Hop 5: the agent reads the reply from the thread.
      const read = store.readTask(body.taskId)!;
      const last = read.turns[read.turns.length - 1];
      assert.equal(last.role, "user");
      assert.equal(last.chosen, "Week 2");

      // Hop 6: the reply refilled the run budget, and the agent claims again.
      const again = claim(store, "t1");
      assert.equal(again.ok, true);
      assert.equal((again as { runsSinceUser: number }).runsSinceUser, 1);
      assert.equal(note(store, "t1", "Booked week 2.").status, "applied");
      convo = store.readTask("t1")?.convo;
      assert.equal(convo?.claimedBy, HOLDER);
    } finally {
      hook.restore();
    }
  });

  it("hop 4: a webhook that fails is sent again, and failureCount counts only the delivery that gave up", async () => {
    // 503, then a network error, then 200: three attempts, one success.
    const hook = mockFetch((n) => n === 1 ? new Response("busy", { status: 503 }) : n === 2 ? Promise.reject(new TypeError("reset")) : new Response("ok", { status: 200 }));
    try {
      const { store, flushWaitUntil } = await createTestTaskStore();
      noRetryWaits(store);
      store.createAgentWebhook("https://hooks.example.com/agent", SECRET, true);
      assignTask(store, "t2");
      await flushWaitUntil();
      assert.deepEqual(hook.calls.map((c) => c.event), ["assigned", "assigned", "assigned"]);
      const revs = new Set(hook.calls.map((c) => (JSON.parse(c.body) as { rev: number }).rev));
      assert.equal(revs.size, 1, "every attempt carries the same rev, so a receiver can dedupe");
      let wh = store.listAgentWebhooks()[0];
      assert.equal(wh.lastStatus, 200);
      assert.equal(wh.failureCount, 0);

      // Every attempt fails: one failed delivery, and the poll still has the event.
      hook.calls.length = 0;
      const down = mockFetch(() => new Response("down", { status: 500 }));
      try {
        const before = await poll(store);
        assert.equal(claim(store, "t2").ok, true);
        assert.equal(ask(store, "t2").status, "applied");
        assert.equal(reply(store, "t2").status, "applied");
        await flushWaitUntil();
        assert.equal(down.calls.length, 3, "three attempts in all");
        wh = store.listAgentWebhooks()[0];
        assert.equal(wh.lastStatus, 500);
        assert.equal(wh.failureCount, 1);
        const after = await poll(store, before.nextSince);
        assert.deepEqual(after.events.map((e) => [e.kind, e.taskId]), [["user_turn", "t2"]]);
      } finally {
        down.restore();
      }
    } finally {
      hook.restore();
    }
  });

  it("hop 4: a 4xx answer other than 408/425/429 is not sent again", async () => {
    assert.equal(isRetryableWebhookStatus(0), true);
    assert.equal(isRetryableWebhookStatus(429), true);
    assert.equal(isRetryableWebhookStatus(502), true);
    assert.equal(isRetryableWebhookStatus(401), false);
    assert.equal(isRetryableWebhookStatus(404), false);
    let calls = 0;
    const fetchImpl = (async () => { calls++; return new Response(null, { status: 410 }); }) as unknown as typeof fetch;
    const target = { id: "wh_x", url: "https://hooks.example.com/gone", secret: SECRET };
    const ev = { rev: 1, kind: "user_turn" as const, taskId: "t", at: new Date().toISOString() };
    const res = await deliverWebhookWithRetry(target, ev, [0, 0], fetchImpl, async () => {});
    assert.equal(res.ok, false);
    assert.equal(res.attempts, 1);
    assert.equal(calls, 1);
    // A blocked URL sends nothing and is not retried.
    const blocked = await deliverWebhookWithRetry({ ...target, url: "https://127.0.0.1/x" }, ev, [0, 0], fetchImpl, async () => {});
    assert.equal(blocked.blocked, true);
    assert.equal(blocked.attempts, 1);
    assert.equal(calls, 1);
  });
});

describe("agent comment loop: poll path", () => {
  it("hop 4b: the cursor never skips or repeats an event, page by page", async () => {
    const { store } = await createTestTaskStore();
    const start = await poll(store);
    assert.deepEqual(start.events, [], "no cursor: start at the head, no replay");
    for (const id of ["p1", "p2", "p3"]) {
      assignTask(store, id);
      assert.equal(claim(store, id).ok, true);
      // Agent notes are not events: the feed skips them.
      assert.equal(note(store, id, "Looking into it.").status, "applied");
      assert.equal(note(store, id, "Still on it.").status, "applied");
      assert.equal(ask(store, id).status, "applied");
      assert.equal(reply(store, id).status, "applied");
    }
    // The full feed in one call.
    const all = await poll(store, start.nextSince, 500);
    assert.deepEqual(all.events.map((e) => `${e.kind}:${e.taskId}`), [
      "assigned:p1", "user_turn:p1", "assigned:p2", "user_turn:p2", "assigned:p3", "user_turn:p3",
    ]);
    // Page by one: the same events, in order, once each.
    const seen: string[] = [];
    let cursor = start.nextSince;
    for (let i = 0; i < 20; i++) {
      const page = await poll(store, cursor, 1);
      assert.ok(page.nextSince >= cursor, "the cursor never moves back");
      seen.push(...page.events.map((e) => `${e.kind}:${e.taskId}`));
      if (page.events.length === 0) break;
      cursor = page.nextSince;
    }
    assert.deepEqual(seen, all.events.map((e) => `${e.kind}:${e.taskId}`));
    // A repeat call with the last cursor returns nothing new.
    const idle = await poll(store, all.nextSince);
    assert.deepEqual(idle.events, []);
    assert.equal(idle.nextSince, all.nextSince);
  });

  it("hop 4b: a reply behind more than 5000 agent writes is not skipped", async () => {
    const { store } = await createTestTaskStore();
    assignTask(store, "busy");
    const start = await poll(store);
    // 5200 agent writes: more than one call's scan (10 pages of 500).
    const ops = Array.from({ length: 5200 }, (_, i) => ({
      clientOpId: opId(), op: "upsert" as const, entity: "task" as const, id: "busy", fields: { notes: `pass ${i}` },
    }));
    const pushed = store.push(ops, AGENT);
    assert.equal(pushed.result.results.filter((r) => r.status !== "applied").length, 0);
    assert.equal(reply(store, "busy", "Go on").status, "applied");

    const events: string[] = [];
    let cursor = start.nextSince;
    for (let i = 0; i < 5 && events.length === 0; i++) {
      const page = await poll(store, cursor);
      events.push(...page.events.map((e) => `${e.kind}:${e.taskId}`));
      assert.ok(page.nextSince > cursor, "each call moves the cursor");
      cursor = page.nextSince;
    }
    assert.deepEqual(events, ["user_turn:busy"]);
  });
});

describe("agent comment loop: claims, stop and pause", () => {
  it("a claim that runs out while the user replies: the reply lands, and the next claim wins", async () => {
    const { store } = await createTestTaskStore();
    assignTask(store, "c1");
    const realNow = Date.now;
    try {
      assert.equal(claim(store, "c1", HOLDER, AGENT, 60_000).ok, true);
      assert.equal(note(store, "c1", "Drafting.").status, "applied");
      // The lease runs out before the agent writes again.
      const later = realNow() + 5 * 60_000;
      Date.now = () => later;
      // The user writes meanwhile.
      const r = store.push([{
        clientOpId: opId(), op: "appendTurn", taskId: "c1",
        turn: { seq: nextSeq(store, "c1"), role: "user", step: "work", note: "Use the cheaper venue.", ts: new Date(later).toISOString() },
      }], HUMAN).result.results[0];
      assert.equal(r.status, "applied");
      // Another agent may take the free task; the first one is then held off.
      const other = claim(store, "c1", OTHER_HOLDER, OTHER);
      assert.equal(other.ok, true);
      const held = claim(store, "c1");
      assert.equal(held.ok, false);
      assert.equal((held as { reason: string }).reason, "held");
      assert.equal((held as { holder: string }).holder, OTHER_HOLDER);
      // The new holder starts its count from the user's turn.
      assert.equal((other as { runsSinceUser: number }).runsSinceUser, 1);
    } finally {
      Date.now = realNow;
    }
  });

  it("a claim that runs out and is taken again by the same agent is a fresh run", async () => {
    const { store } = await createTestTaskStore();
    assignTask(store, "c2");
    const realNow = Date.now;
    try {
      assert.equal(claim(store, "c2", HOLDER, AGENT, 60_000).ok, true);
      const later = realNow() + 5 * 60_000;
      Date.now = () => later;
      const again = claim(store, "c2");
      assert.equal(again.ok, true);
      assert.equal((again as { renewed: boolean }).renewed, false);
      assert.equal((again as { runsSinceUser: number }).runsSinceUser, 2);
    } finally {
      Date.now = realNow;
    }
  });

  it("a stop in the middle of a conversation refuses the agent, and the resume wakes it", async () => {
    const hook = mockFetch(() => new Response(null, { status: 204 }));
    try {
      const { store, flushWaitUntil } = await createTestTaskStore();
      store.createAgentWebhook("https://hooks.example.com/agent", SECRET, true);
      assignTask(store, "s1");
      assert.equal(claim(store, "s1").ok, true);
      assert.equal(ask(store, "s1").status, "applied");
      await flushWaitUntil();
      hook.calls.length = 0;

      store.push([{ clientOpId: opId(), op: "upsert", entity: "convo", id: "s1", fields: { stoppedAt: new Date().toISOString() } }], HUMAN);
      assert.equal(reply(store, "s1").status, "applied", "the user may still write on a stopped task");
      await flushWaitUntil();
      assert.deepEqual(hook.calls.map((c) => c.event), ["user_turn"]);
      // The woken agent is refused: no claim, no write.
      assert.equal((claim(store, "s1") as { reason: string }).reason, "stopped");
      const refused = note(store, "s1", "Continuing anyway");
      assert.equal(refused.status, "rejected");
      // The agent may not lift the stop itself.
      const lift = store.push([{ clientOpId: opId(), op: "upsert", entity: "convo", id: "s1", fields: { stoppedAt: null } }], AGENT).result.results[0];
      assert.equal(lift.status, "rejected");

      // The user resumes: a `resumed` wake, and the agent goes on.
      store.push([{ clientOpId: opId(), op: "upsert", entity: "convo", id: "s1", fields: { stoppedAt: null } }], HUMAN);
      await flushWaitUntil();
      assert.deepEqual(hook.calls.map((c) => c.event), ["user_turn", "resumed"]);
      assert.equal(claim(store, "s1").ok, true);
    } finally {
      hook.restore();
    }
  });

  it("a pause in the middle of a conversation: the reply waits, and the unpause wakes the agent", async () => {
    const hook = mockFetch(() => new Response(null, { status: 204 }));
    try {
      const { store, flushWaitUntil } = await createTestTaskStore();
      store.createAgentWebhook("https://hooks.example.com/agent", SECRET, true);
      assignTask(store, "z1");
      assert.equal(claim(store, "z1").ok, true);
      assert.equal(ask(store, "z1").status, "applied");
      const cursor = (await poll(store)).nextSince;
      await flushWaitUntil();
      hook.calls.length = 0;

      store.push([{ clientOpId: opId(), op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: true } }], HUMAN);
      assert.equal(reply(store, "z1").status, "applied");
      await flushWaitUntil();
      const during = await poll(store, cursor);
      assert.equal(during.paused, true);
      assert.deepEqual(during.events.map((e) => e.kind), ["paused", "user_turn"]);
      assert.equal((claim(store, "z1") as { reason: string }).reason, "paused");
      assert.equal(note(store, "z1", "Working").status, "rejected");

      store.push([{ clientOpId: opId(), op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: false } }], HUMAN);
      await flushWaitUntil();
      // user_turn during the pause, then unpaused: the agent that was refused is woken again.
      assert.deepEqual(hook.calls.map((c) => c.event), ["user_turn", "unpaused"]);
      const unpaused = JSON.parse(hook.calls[1].body) as { taskId: string | null };
      assert.equal(unpaused.taskId, null);
      const after = await poll(store, during.nextSince);
      assert.equal(after.paused, false);
      assert.deepEqual(after.events.map((e) => e.kind), ["unpaused"]);
      assert.equal(claim(store, "z1").ok, true);
    } finally {
      hook.restore();
    }
  });
});

describe("agent wake webhooks: durable outbox on DO alarm (#748)", () => {
  it("survives DO eviction/restart and delivers with exponential backoff on alarm()", async () => {
    const realNow = Date.now;
    let clock = 1_770_000_000_000;
    Date.now = () => clock;
    // Fail twice (503, network error), then succeed on attempt 3 after a simulated DO restart.
    let attempt = 0;
    const hook = mockFetch(() => {
      attempt++;
      if (attempt === 1) return new Response("busy", { status: 503 });
      if (attempt === 2) return Promise.reject(new TypeError("network reset"));
      return new Response(null, { status: 204 });
    });
    try {
      const first = await createTestTaskStore();
      first.store.createAgentWebhook("https://hooks.example.com/durable", SECRET, true);
      assignTask(first.store, "d1");
      await first.flushWaitUntil();

      assert.equal(hook.calls.length, 1, "initial attempt fired immediately");
      assert.equal(first.store.listAgentWebhooks()[0].failureCount, 0, "still retrying; has not given up");
      const firstRetryAt = first.alarmAt();
      assert.ok(firstRetryAt !== null && firstRetryAt === clock + 5_000, `expected 5s backoff alarm, got ${firstRetryAt}`);

      // Simulate DO eviction & cold restart on the same SQLite database before alarm fires.
      const restarted = await createTestTaskStore(first.db);
      clock += 5_000;
      await restarted.store.alarm();

      assert.equal(hook.calls.length, 2, "alarm delivered retry #1 after DO restart");
      assert.equal(restarted.store.listAgentWebhooks()[0].failureCount, 0);
      const secondRetryAt = restarted.alarmAt();
      assert.ok(secondRetryAt !== null && secondRetryAt === clock + 30_000, `expected 30s backoff alarm, got ${secondRetryAt}`);

      // Advance past second backoff: attempt 3 succeeds and clears outbox.
      clock += 30_000;
      await restarted.store.alarm();
      assert.equal(hook.calls.length, 3);
      const revs = new Set(hook.calls.map((c) => (JSON.parse(c.body) as { rev: number }).rev));
      assert.equal(revs.size, 1, "all retries carry the same rev for receiver dedupe");
      const wh = restarted.store.listAgentWebhooks()[0];
      assert.equal(wh.enabled, true);
      assert.equal(wh.lastStatus, 204);
      assert.equal(wh.failureCount, 0);
      const queued = restarted.db.prepare("SELECT COUNT(*) AS n FROM agent_webhook_outbox").get() as { n: number };
      assert.equal(queued.n, 0, "outbox row deleted on success");
    } finally {
      Date.now = realNow;
      hook.restore();
    }
  });

  it("drops queued outbox rows when a webhook is deleted", async () => {
    const realNow = Date.now;
    let clock = 1_770_100_000_000;
    Date.now = () => clock;
    const hook = mockFetch(() => new Response("down", { status: 503 }));
    try {
      const { store, db, flushWaitUntil } = await createTestTaskStore();
      const created = store.createAgentWebhook("https://hooks.example.com/del", SECRET, true);
      assert.equal(created.ok, true);
      assignTask(store, "d2");
      await flushWaitUntil();
      assert.equal(hook.calls.length, 1);
      assert.equal((db.prepare("SELECT COUNT(*) AS n FROM agent_webhook_outbox").get() as { n: number }).n, 1);

      assert.equal(store.deleteAgentWebhook(created.webhook.id), true);
      assert.equal((db.prepare("SELECT COUNT(*) AS n FROM agent_webhook_outbox").get() as { n: number }).n, 0);

      clock += 60_000;
      await store.alarm();
      assert.equal(hook.calls.length, 1, "deleted webhook receives no further attempts");
    } finally {
      Date.now = realNow;
      hook.restore();
    }
  });

  it("disables a webhook (enabled = 0) after N consecutive failed deliveries and clears its outbox", async () => {
    const hook = mockFetch(() => new Response("gone", { status: 410 }));
    try {
      const { store, db, flushWaitUntil } = await createTestTaskStore();
      (store as unknown as { webhookDisableAfterFailures: number }).webhookDisableAfterFailures = 3;
      const created = store.createAgentWebhook("https://hooks.example.com/dead", SECRET, true);
      assert.equal(created.ok, true);

      // Three consecutive non-retryable 410 deliveries -> auto-disabled.
      assignTask(store, "f1");
      await flushWaitUntil();
      assert.equal(store.listAgentWebhooks()[0].enabled, true);
      assert.equal(store.listAgentWebhooks()[0].failureCount, 1);

      assignTask(store, "f2");
      await flushWaitUntil();
      assert.equal(store.listAgentWebhooks()[0].enabled, true);
      assert.equal(store.listAgentWebhooks()[0].failureCount, 2);

      assignTask(store, "f3");
      await flushWaitUntil();
      const disabled = store.listAgentWebhooks()[0];
      assert.equal(disabled.enabled, false, "webhook auto-disabled after 3 consecutive failures");
      assert.equal(disabled.failureCount, 3);
      assert.equal((db.prepare("SELECT COUNT(*) AS n FROM agent_webhook_outbox").get() as { n: number }).n, 0);

      // Subsequent wake events are not enqueued or sent to the disabled webhook.
      const beforeCalls = hook.calls.length;
      assignTask(store, "f4");
      await flushWaitUntil();
      assert.equal(hook.calls.length, beforeCalls);
    } finally {
      hook.restore();
    }
  });
});
