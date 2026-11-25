import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, ensureSession, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

const { api } = await import("../src/api/routes.ts");
const { signAccessToken } = await import("../src/api/session.ts");
const { issueMcpTokens, MCP_GRANT_SCOPE } = await import("../src/shadow/tokens.ts");
const {
  MAX_AGENT_WEBHOOKS,
  signWebhookPayload,
  validateWebhookUrl,
  verifyWebhookSignature,
} = await import("../src/api/agentWake.ts");
const {
  backoffDelayMs,
  createSseParser,
  isWakeEvent,
} = await import("../../scripts/task-runner-wake.mjs");

const TEST_SIGNING_KEY = Buffer.alloc(32, 7).toString("base64");
const EXEC_CTX = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

function makeKv() {
  const map = new Map<string, string>();
  return {
    map,
    async get(key: string) { return map.get(key) ?? null; },
    async put(key: string, value: string) { map.set(key, value); },
    async delete(key: string) { map.delete(key); },
  };
}

class MockWebSocket {
  sent: string[] = [];
  closed = false;
  send(msg: string) {
    this.sent.push(msg);
  }
  close() {
    this.closed = true;
  }
}

function installMockWebSocketPair() {
  const created: Array<[MockWebSocket, MockWebSocket]> = [];
  const prevPair = (globalThis as Record<string, unknown>).WebSocketPair;
  const RealResponse = globalThis.Response;
  (globalThis as Record<string, unknown>).WebSocketPair = class {
    0: MockWebSocket;
    1: MockWebSocket;
    constructor() {
      this[0] = new MockWebSocket();
      this[1] = new MockWebSocket();
      created.push([this[0], this[1]]);
    }
  };
  // Node/Undici Response rejects status 101; Cloudflare Workers accepts 101 + webSocket.
  (globalThis as Record<string, unknown>).Response = new Proxy(RealResponse, {
    construct(Target, args: [BodyInit | null | undefined, (ResponseInit & { webSocket?: unknown }) | undefined], newTarget) {
      const init = args[1];
      if (init?.status === 101 && init.webSocket) {
        return { status: 101, webSocket: init.webSocket, headers: new Headers(init.headers) };
      }
      return Reflect.construct(Target, args, newTarget);
    },
  });
  return {
    created,
    restore() {
      if (prevPair === undefined) delete (globalThis as Record<string, unknown>).WebSocketPair;
      else (globalThis as Record<string, unknown>).WebSocketPair = prevPair;
      (globalThis as Record<string, unknown>).Response = RealResponse;
    },
  };
}

async function makeRouteHarness() {
  const tokens = makeKv();
  const clients = makeKv();
  const stores = new Map<string, Awaited<ReturnType<typeof createTestTaskStore>>>();

  async function ensureStore(userId: string) {
    let entry = stores.get(userId);
    if (!entry) {
      entry = await createTestTaskStore();
      stores.set(userId, entry);
    }
    return entry;
  }

  const env = {
    API_PUBLIC_URL: "https://api.septena.app",
    APPLE_AUDIENCES: "com.septena.tasks",
    ENTITLEMENT_ENFORCE: "false",
    APPLE_IAP_BUNDLE_IDS: "com.septena.tasks",
    APPLE_IAP_ENVIRONMENTS: "Production,Sandbox",
    SESSION_SIGNING_KEY: TEST_SIGNING_KEY,
    STATE: makeKv(),
    TOKENS: tokens,
    CLIENTS: clients,
    ATTACHMENTS: { list: async () => ({ objects: [], truncated: false }), delete: async () => {} },
    TASK_STORE: {
      idFromName: (name: string) => name,
      get: (id: string) => new Proxy({}, {
        get(_t, prop: string) {
          return async (...args: unknown[]) => {
            const { store } = await ensureStore(id);
            const fn = (store as unknown as Record<string, (...a: unknown[]) => unknown>)[prop];
            return fn.apply(store, args);
          };
        },
      }),
    },
  } as never;

  async function userAuth(userId: string, sid = "11111111-1111-4111-8111-111111111111") {
    ensureSession((await ensureStore(userId)).store, sid);
    return `Bearer ${await signAccessToken(env, userId, sid)}`;
  }

  async function mcpAuth(userId: string, scope = MCP_GRANT_SCOPE) {
    const issued = await issueMcpTokens(env, { userId, clientId: "client-runner", scope });
    return `Bearer ${issued.access_token}`;
  }

  return { env, tokens, ensureStore, userAuth, mcpAuth };
}

let seq = 0;
const opId = () => `wakeop_${++seq}_${Date.now()}`;

async function readChunksUntil(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  predicate: (acc: string) => boolean,
  timeoutMs = 2000,
): Promise<string> {
  const decoder = new TextDecoder();
  let acc = "";
  const deadline = Date.now() + timeoutMs;
  while (!predicate(acc)) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error(`timed out waiting for SSE chunk; received:\n${acc}`);
    const res = await Promise.race([
      reader.read(),
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("read timeout")), remaining)),
    ]);
    if (res.done) break;
    acc += decoder.decode(res.value, { stream: true });
  }
  return acc;
}

describe("webhook URL & SSRF validation", () => {
  it("accepts public HTTPS URLs and custom high ports", () => {
    assert.equal(validateWebhookUrl("https://hooks.example.com/septena").ok, true);
    assert.equal(validateWebhookUrl("https://hooks.example.com:8443/wake?source=septena").ok, true);
    assert.equal(validateWebhookUrl("https://1.1.1.1/hook").ok, true);
  });

  it("rejects non-HTTPS, credentials, privileged ports, loopback, private IPv4/IPv6, and cloud metadata", () => {
    const bad = [
      "http://hooks.example.com/septena",
      "file:///etc/passwd",
      "https://user:pass@hooks.example.com/hook",
      "https://localhost/hook",
      "https://sub.localhost/hook",
      "https://mz-mini.local/hook",
      "https://service.internal/hook",
      "https://intranet/hook",
      "https://127.0.0.1/hook",
      "https://127.0.0.2/hook",
      "https://10.0.0.1/hook",
      "https://172.16.0.5/hook",
      "https://192.168.1.20/hook",
      "https://169.254.169.254/latest/meta-data/",
      "https://100.64.0.1/hook",
      "https://0.0.0.0/hook",
      "https://224.0.0.1/hook",
      "https://2130706433/hook",
      "https://[::1]/hook",
      "https://[::]/hook",
      "https://[fe80::1]/hook",
      "https://[fc00::1]/hook",
      "https://[fd12:3456::1]/hook",
      "https://[::ffff:127.0.0.1]/hook",
      "https://[::ffff:169.254.169.254]/hook",
      "https://hooks.example.com:22/hook",
      "https://hooks.example.com:80/hook",
      "not-a-url",
    ];
    for (const url of bad) {
      const r = validateWebhookUrl(url);
      assert.equal(r.ok, false, `expected ${url} to be rejected`);
    }
  });
});

describe("webhook HMAC-SHA256 signing & verification", () => {
  it("signs with sha256=<hex> and verifies in constant time", async () => {
    const secret = "whsec_test_secret_1234567890";
    const ts = "1732480000000";
    const body = JSON.stringify({ event: "assigned", rev: 5, taskId: "t-1", at: "2026-11-24T22:00:00Z" });
    const sig = await signWebhookPayload(secret, ts, body);
    assert.match(sig, /^sha256=[0-9a-f]{64}$/);
    assert.equal(await verifyWebhookSignature(secret, ts, body, sig), true);
    assert.equal(await verifyWebhookSignature("wrong_secret", ts, body, sig), false);
    assert.equal(await verifyWebhookSignature(secret, "1732480000001", body, sig), false);
    assert.equal(await verifyWebhookSignature(secret, ts, body + " ", sig), false);
    assert.equal(await verifyWebhookSignature(secret, ts, body, "md5=deadbeef"), false);
  });
});

describe("GET /v1/agent/events/stream (SSE + WebSocket)", () => {
  it("authenticates user bearer tokens and MCP OAuth tokens, rejecting unauthorized or underscoped callers", async () => {
    const h = await makeRouteHarness();
    const userId = "u_wake_auth_test_1234567890";

    const unauth = await api.fetch(new Request("https://api.septena.app/agent/events/stream"), h.env, EXEC_CTX);
    assert.equal(unauth.status, 401);

    const noScope = await api.fetch(new Request("https://api.septena.app/agent/events/stream", {
      headers: { Authorization: await h.mcpAuth(userId, "other:scope") },
    }), h.env, EXEC_CTX);
    assert.equal(noScope.status, 403);

    const badCursor = await api.fetch(new Request("https://api.septena.app/agent/events/stream?since=-1", {
      headers: { Authorization: await h.userAuth(userId) },
    }), h.env, EXEC_CTX);
    assert.equal(badCursor.status, 400);

    // Valid MCP OAuth token with tasks:read opens SSE stream
    const ac = new AbortController();
    const res = await api.fetch(new Request("https://api.septena.app/agent/events/stream", {
      headers: { Authorization: await h.mcpAuth(userId) },
      signal: ac.signal,
    }), h.env, EXEC_CTX);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Content-Type"), "text/event-stream; charset=utf-8");
    const reader = res.body!.getReader();
    const first = await readChunksUntil(reader, (s) => s.includes("event: ready"));
    assert.match(first, /retry: 3000/);
    assert.match(first, /event: ready/);
    ac.abort();
    await reader.cancel();
  });

  it("replays missed events from since / Last-Event-ID and streams live assigned, user_turn, resumed, stopped, paused, unpaused events", async () => {
    const h = await makeRouteHarness();
    const userId = "u_wake_sse_stream_123456789";
    const { store } = await h.ensureStore(userId);

    // Seed a task + assign to claude (historical event before stream opens)
    store.push([
      { clientOpId: opId(), op: "upsert", entity: "task", id: "task-1", fields: { title: "Research flights", status: "open" } },
      { clientOpId: opId(), op: "upsert", entity: "convo", id: "task-1", fields: { assignee: "claude" } },
    ], "app:ios");

    // Open SSE stream with Last-Event-ID: 0 so we get cursor replay + live fan-out
    const ac = new AbortController();
    const res = await api.fetch(new Request("https://api.septena.app/agent/events/stream", {
      headers: {
        Authorization: await h.userAuth(userId),
        "Last-Event-ID": "0",
      },
      signal: ac.signal,
    }), h.env, EXEC_CTX);
    assert.equal(res.status, 200);

    const reader = res.body!.getReader();
    const replayText = await readChunksUntil(reader, (s) => s.includes("event: assigned"));
    const parser = createSseParser();
    const replayFrames = parser.feed(replayText);
    assert.equal(replayFrames[0].event, "ready");
    const assignedFrame = replayFrames.find((f) => f.event === "assigned");
    assert.ok(assignedFrame, "replayed assigned event");
    const assignedData = JSON.parse(assignedFrame.data) as { rev: number; kind: string; taskId: string };
    assert.equal(assignedData.taskId, "task-1");
    assert.equal(assignedFrame.id, String(assignedData.rev));

    // Agent write must NOT emit an agent event
    store.push([
      {
        clientOpId: opId(), op: "appendTurn", taskId: "task-1",
        turn: { seq: 1, role: "provider", step: "confirm", question: "Direct or 1-stop?", options: ["Direct", "1-stop"], ts: "2026-11-24T22:01:00Z" },
      },
    ], "mcp:runner:mz-mini@abc12345");

    // Live human commits: user_turn, stopped, resumed, paused, unpaused
    store.push([
      {
        clientOpId: opId(), op: "appendTurn", taskId: "task-1",
        turn: { seq: 2, role: "user", step: "confirm", chosen: "Direct", inReplyTo: 1, ts: "2026-11-24T22:02:00Z" },
      },
    ], "app:ios");
    store.push([
      { clientOpId: opId(), op: "upsert", entity: "convo", id: "task-1", fields: { stoppedAt: "2026-11-24T22:03:00Z" } },
    ], "app:ios");
    store.push([
      { clientOpId: opId(), op: "upsert", entity: "convo", id: "task-1", fields: { stoppedAt: null } },
    ], "app:ios");
    store.push([
      { clientOpId: opId(), op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: true } },
    ], "app:ios");
    store.push([
      { clientOpId: opId(), op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: false } },
    ], "app:ios");

    const liveText = await readChunksUntil(reader, (s) => s.includes("event: unpaused"));
    const liveFrames = parser.feed(liveText);
    assert.deepEqual(
      liveFrames.map((f) => f.event),
      ["user_turn", "stopped", "resumed", "paused", "unpaused"],
    );
    assert.equal(JSON.parse(liveFrames[0].data).taskId, "task-1");
    assert.equal(JSON.parse(liveFrames[3].data).taskId, null);

    ac.abort();
    await reader.cancel();
  });

  it("emits periodic SSE keepalive comments", async () => {
    const { store } = await createTestTaskStore();
    (store as unknown as { sseHeartbeatMs: number }).sseHeartbeatMs = 20;
    const ac = new AbortController();
    const res = await store.fetch(new Request("https://api.septena.app/v1/agent/events/stream", {
      signal: ac.signal,
    }));
    const reader = res.body!.getReader();
    const text = await readChunksUntil(reader, (s) => s.includes(": keepalive "));
    assert.match(text, /: keepalive \d+\n\n/);
    ac.abort();
    await reader.cancel();
  });

  it("supports WebSocket upgrade on /v1/agent/events/stream and isolates from sync WebSockets", async () => {
    const mockWs = installMockWebSocketPair();
    try {
      const { store } = await createTestTaskStore();

      // Open one sync WebSocket and one agent-events WebSocket
      const syncRes = await store.fetch(new Request("https://api.septena.app/v1/sync/ws", {
        headers: { Upgrade: "websocket" },
      }));
      assert.equal(syncRes.status, 101);
      const syncServer = mockWs.created[0][1];

      // Seed an assigned task before agent WS connects so it replays
      store.push([
        { clientOpId: opId(), op: "upsert", entity: "task", id: "t-ws", fields: { title: "WS task", status: "open" } },
        { clientOpId: opId(), op: "upsert", entity: "convo", id: "t-ws", fields: { assignee: "claude" } },
      ], "app:mac");

      const agentRes = await store.fetch(new Request("https://api.septena.app/v1/agent/events/stream?since=0", {
        headers: { Upgrade: "websocket" },
      }));
      assert.equal(agentRes.status, 101);
      const agentServer = mockWs.created[1][1];

      // Agent WS got ready + replayed assigned event
      assert.equal(agentServer.sent.length, 2);
      assert.equal(JSON.parse(agentServer.sent[0]).type, "ready");
      assert.equal(JSON.parse(agentServer.sent[1]).event.kind, "assigned");

      // Push a normal task edit (no agent event): sync WS gets {rev}, agent WS gets nothing
      const syncBefore = syncServer.sent.length;
      const agentBefore = agentServer.sent.length;
      store.push([
        { clientOpId: opId(), op: "upsert", entity: "task", id: "t-ws", fields: { title: "WS task updated" } },
      ], "app:mac");
      assert.equal(syncServer.sent.length, syncBefore + 1);
      assert.equal(agentServer.sent.length, agentBefore);

      // Push a user_turn: both get their own wire format, no cross-contamination
      store.push([
        {
          clientOpId: opId(), op: "appendTurn", taskId: "t-ws",
          turn: { seq: 1, role: "user", step: "confirm", note: "Go ahead", ts: "2026-11-24T22:10:00Z" },
        },
      ], "app:mac");
      assert.equal(agentServer.sent.length, agentBefore + 1);
      const msg = JSON.parse(agentServer.sent[agentServer.sent.length - 1]);
      assert.equal(msg.type, "event");
      assert.equal(msg.event.kind, "user_turn");
      assert.equal(msg.event.taskId, "t-ws");
      // Sync socket never saw an agent event frame
      assert.ok(syncServer.sent.every((s) => !s.includes('"type":"event"')));
    } finally {
      mockWs.restore();
    }
  });
});

describe("outbound agent webhooks (/v1/agent/webhooks + signed dispatch)", () => {
  it("registers, lists without secrets, rejects SSRF URLs, enforces cap, and deletes", async () => {
    const h = await makeRouteHarness();
    const userId = "u_webhook_crud_test_1234567";
    const auth = await h.userAuth(userId);

    // MCP token cannot manage account webhooks
    const mcpAttempt = await api.fetch(new Request("https://api.septena.app/agent/webhooks", {
      headers: { Authorization: await h.mcpAuth(userId) },
    }), h.env, EXEC_CTX);
    assert.equal(mcpAttempt.status, 401);

    // Reject SSRF target
    const ssrf = await api.fetch(new Request("https://api.septena.app/agent/webhooks", {
      method: "POST",
      headers: { Authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ url: "https://169.254.169.254/latest/meta-data" }),
    }), h.env, EXEC_CTX);
    assert.equal(ssrf.status, 400);
    const ssrfBody = await ssrf.json() as { error: string; reason: string };
    assert.equal(ssrfBody.error, "invalid_webhook_url");
    assert.equal(ssrfBody.reason, "private_address");

    // Create with auto-generated secret
    const createdRes = await api.fetch(new Request("https://api.septena.app/agent/webhooks", {
      method: "POST",
      headers: { Authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ url: "https://hooks.example.com/septena" }),
    }), h.env, EXEC_CTX);
    assert.equal(createdRes.status, 201);
    const created = await createdRes.json() as { id: string; url: string; secret: string; enabled: boolean };
    assert.match(created.id, /^wh_/);
    assert.match(created.secret, /^whsec_/);
    assert.equal(created.enabled, true);

    // List omits `secret`
    const listRes = await api.fetch(new Request("https://api.septena.app/agent/webhooks", {
      headers: { Authorization: auth },
    }), h.env, EXEC_CTX);
    assert.equal(listRes.status, 200);
    const listed = await listRes.json() as { webhooks: Array<Record<string, unknown>> };
    assert.equal(listed.webhooks.length, 1);
    assert.equal(listed.webhooks[0].id, created.id);
    assert.equal("secret" in listed.webhooks[0], false, "GET must never leak signing secret");

    // Delete returns 204, second delete returns 404
    const del1 = await api.fetch(new Request(`https://api.septena.app/agent/webhooks/${created.id}`, {
      method: "DELETE",
      headers: { Authorization: auth },
    }), h.env, EXEC_CTX);
    assert.equal(del1.status, 204);
    const del2 = await api.fetch(new Request(`https://api.septena.app/agent/webhooks/${created.id}`, {
      method: "DELETE",
      headers: { Authorization: auth },
    }), h.env, EXEC_CTX);
    assert.equal(del2.status, 404);

    // Enforces per-user cap
    for (let i = 0; i < MAX_AGENT_WEBHOOKS; i++) {
      const r = await api.fetch(new Request("https://api.septena.app/agent/webhooks", {
        method: "POST",
        headers: { Authorization: auth, "Content-Type": "application/json" },
        body: JSON.stringify({ url: `https://hooks.example.com/slot-${i}` }),
      }), h.env, EXEC_CTX);
      assert.equal(r.status, 201);
    }
    const overCap = await api.fetch(new Request("https://api.septena.app/agent/webhooks", {
      method: "POST",
      headers: { Authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ url: "https://hooks.example.com/overflow" }),
    }), h.env, EXEC_CTX);
    assert.equal(overCap.status, 409);
  });

  it("dispatches HMAC-SHA256 signed POST on assigned/user_turn/resumed, skips non-wake events, and tracks failures without breaking writes", async () => {
    const prevFetch = globalThis.fetch;
    const calls: Array<{ url: string; headers: Record<string, string>; body: string; redirect?: RequestRedirect }> = [];
    let nextResponse: () => Promise<Response> | Response = () => new Response("ok", { status: 200 });

    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      const headers: Record<string, string> = {};
      if (init?.headers) {
        for (const [k, v] of Object.entries(init.headers as Record<string, string>)) {
          headers[k.toLowerCase()] = v;
        }
      }
      calls.push({ url, headers, body: String(init?.body ?? ""), redirect: init?.redirect });
      return nextResponse();
    }) as typeof fetch;

    try {
      const { store, flushWaitUntil } = await createTestTaskStore();
      const secret = "whsec_verify_me_1234567890abcdef";
      const active = store.createAgentWebhook("https://hooks.example.com/wake", secret, true);
      assert.equal(active.ok, true);
      const disabled = store.createAgentWebhook("https://hooks.example.com/disabled", "whsec_disabled_1234567890", false);
      assert.equal(disabled.ok, true);

      // 1. `assigned` triggers signed POST with pointer-only payload
      store.push([
        { clientOpId: opId(), op: "upsert", entity: "task", id: "task-secret-title", fields: { title: "TOP SECRET CONTENT", status: "open" } },
        { clientOpId: opId(), op: "upsert", entity: "convo", id: "task-secret-title", fields: { assignee: "claude" } },
      ], "app:ios");
      await flushWaitUntil();

      assert.equal(calls.length, 1, "only enabled webhook called");
      const c1 = calls[0];
      assert.equal(c1.url, "https://hooks.example.com/wake");
      assert.equal(c1.redirect, "manual");
      assert.equal(c1.headers["x-septena-event"], "assigned");
      assert.ok(c1.headers["x-septena-delivery"]);
      assert.match(c1.headers["x-septena-timestamp"], /^\d+$/);
      assert.equal(
        await verifyWebhookSignature(secret, c1.headers["x-septena-timestamp"], c1.body, c1.headers["x-septena-signature"]),
        true,
      );
      assert.equal(c1.body.includes("TOP SECRET CONTENT"), false, "payload must be pointer-only");
      const parsed1 = JSON.parse(c1.body) as { event: string; taskId: string; rev: number; at: string };
      assert.equal(parsed1.event, "assigned");
      assert.equal(parsed1.taskId, "task-secret-title");

      let wh = store.listAgentWebhooks().find((w) => w.id === (active.ok ? active.webhook.id : ""))!;
      assert.equal(wh.lastStatus, 200);
      assert.equal(wh.failureCount, 0);
      assert.ok(wh.lastDeliveredAt);

      // 2. Non-wake events (`stopped`, `paused`) and agent writes do NOT dispatch webhooks
      store.push([
        { clientOpId: opId(), op: "upsert", entity: "convo", id: "task-secret-title", fields: { stoppedAt: "2026-11-24T22:05:00Z" } },
        { clientOpId: opId(), op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: true } },
      ], "app:ios");
      await flushWaitUntil();
      assert.equal(calls.length, 1);

      // 3. `resumed` fails with HTTP 500 -> increments failureCount, main push still succeeds
      nextResponse = () => new Response("boom", { status: 500 });
      const resumedPush = store.push([
        { clientOpId: opId(), op: "upsert", entity: "convo", id: "task-secret-title", fields: { stoppedAt: null } },
      ], "app:ios");
      assert.equal(resumedPush.result.results[0].status, "applied");
      await flushWaitUntil();
      assert.equal(calls.length, 2);
      assert.equal(calls[1].headers["x-septena-event"], "resumed");
      wh = store.listAgentWebhooks().find((w) => w.id === (active.ok ? active.webhook.id : ""))!;
      assert.equal(wh.lastStatus, 500);
      assert.equal(wh.failureCount, 1);

      // 4. `user_turn` throws network error -> failureCount increments to 2, lastStatus = 0, write still succeeds
      nextResponse = () => Promise.reject(new TypeError("network down"));
      const turnPush = store.push([
        {
          clientOpId: opId(), op: "appendTurn", taskId: "task-secret-title",
          turn: { seq: 1, role: "user", step: "confirm", note: "Proceed", ts: "2026-11-24T22:06:00Z" },
        },
      ], "app:ios");
      assert.equal(turnPush.result.results[0].status, "applied");
      await flushWaitUntil();
      assert.equal(calls.length, 3);
      assert.equal(calls[2].headers["x-septena-event"], "user_turn");
      wh = store.listAgentWebhooks().find((w) => w.id === (active.ok ? active.webhook.id : ""))!;
      assert.equal(wh.lastStatus, 0);
      assert.equal(wh.failureCount, 2);

      // 5. Subsequent 204 resets failureCount to 0
      nextResponse = () => new Response(null, { status: 204 });
      store.push([
        {
          clientOpId: opId(), op: "appendTurn", taskId: "task-secret-title",
          turn: { seq: 2, role: "user", step: "confirm", note: "Retry", ts: "2026-11-24T22:07:00Z" },
        },
      ], "app:ios");
      await flushWaitUntil();
      wh = store.listAgentWebhooks().find((w) => w.id === (active.ok ? active.webhook.id : ""))!;
      assert.equal(wh.lastStatus, 204);
      assert.equal(wh.failureCount, 0);
    } finally {
      globalThis.fetch = prevFetch;
    }
  });
});

describe("task-runner-wake.mjs SSE parser & backoff", () => {
  it("parses chunked SSE frames, ignores keepalive comments, and identifies wake events", () => {
    const parser = createSseParser();
    assert.deepEqual(parser.feed(": keepalive 12345\n\nretry: 3000\nevent: ready\nda"), []);
    const batch1 = parser.feed('ta: {"head":7,"paused":false}\r\n\r\nid: 8\nevent: user_turn\ndata: {"rev":8}\n\n');
    assert.equal(batch1.length, 2);
    assert.equal(batch1[0].event, "ready");
    assert.equal(batch1[0].retry, 3000);
    assert.equal(batch1[1].id, "8");
    assert.equal(batch1[1].event, "user_turn");
    assert.equal(isWakeEvent("assigned"), true);
    assert.equal(isWakeEvent("user_turn"), true);
    assert.equal(isWakeEvent("resumed"), true);
    assert.equal(isWakeEvent("paused"), false);
    assert.equal(isWakeEvent("stopped"), false);
    assert.ok(backoffDelayMs(0, 1000, 60_000, () => 0.5) === 1000);
    assert.ok(backoffDelayMs(10, 1000, 60_000, () => 0.5) === 60_000);
  });
});
