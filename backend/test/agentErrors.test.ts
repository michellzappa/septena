import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, ensureSession, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// AS3 (ADR 0050 §3, §4): one error envelope with `retryable`, and
// idempotency keys on writes. Both MCP eras, and /v1.

const { REFUSALS, refusalInfo, errorEnvelope, envelopeFor, Refusal } = await import("../src/errors.ts");
const { previewMcpHandler } = await import("../src/shadow/mcp.ts");
const { api } = await import("../src/api/routes.ts");
const { signAccessToken } = await import("../src/api/session.ts");
const { sha256Base64Url } = await import("../src/util.ts");
const { MODERN_VERSION, META_PROTOCOL_VERSION } = await import("../src/protocol.ts");

const EXEC_CTX = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
const TEST_SIGNING_KEY = Buffer.alloc(32, 7).toString("base64");

function memoryKv() {
  const map = new Map<string, string>();
  return {
    async get(key: string) { return map.get(key) ?? null; },
    async put(key: string, value: string) { map.set(key, value); },
    async delete(key: string) { map.delete(key); },
  };
}

async function harness() {
  const { store } = await createTestTaskStore();
  const tokens = memoryKv();
  const env = {
    API_PUBLIC_URL: "https://api.septena.app",
    ENTITLEMENT_ENFORCE: "false",
    SESSION_SIGNING_KEY: TEST_SIGNING_KEY,
    TOKENS: tokens,
    STATE: memoryKv(),
    CLIENTS: memoryKv(),
    TASK_STORE: {
      idFromName(name: string) { return name; },
      get() {
        return new Proxy({}, {
          get(_t, prop: string) {
            return async (...args: unknown[]) => (store as unknown as Record<string, (...a: unknown[]) => unknown>)[prop](...args);
          },
        });
      },
    },
  } as never;
  const token = "sm1.agent_errors_test_token";
  await tokens.put(`v2:access:${await sha256Base64Url(token)}`, JSON.stringify({
    userId: "u1", clientId: "client-1", familyId: "fam-1", scope: "tasks:read tasks:write", expiresAt: Date.now() + 3600_000,
  }));

  async function rpc(method: string, params: Record<string, unknown> = {}, era: "legacy" | "modern" = "legacy") {
    const headers: Record<string, string> = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
    if (era === "modern") {
      params._meta = { [META_PROTOCOL_VERSION]: MODERN_VERSION };
      Object.assign(headers, { "MCP-Protocol-Version": MODERN_VERSION, "Mcp-Method": method });
      if (typeof params.name === "string") headers["Mcp-Name"] = params.name;
    }
    const req = new Request("https://api.septena.app/mcp", {
      method: "POST", headers, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    const fakeC = { req: { header: (k: string) => req.headers.get(k) ?? undefined, raw: req, json: () => req.json() }, env };
    const res = await previewMcpHandler(fakeC as never);
    assert.equal(res.status, 200);
    return (await res.json()) as {
      result?: { isError?: boolean; content: { text: string }[]; structuredContent?: { error: Record<string, unknown> }; resultType?: string };
      error?: { code: number; message: string; data?: unknown };
    };
  }

  const mcp = (name: string, args: Record<string, unknown>, era: "legacy" | "modern" = "legacy") =>
    rpc("tools/call", { name, arguments: args }, era);

  async function v1(path: string, init: { method?: string; body?: unknown; headers?: Record<string, string> } = {}) {
    ensureSession(store, "sid-1");
    const auth = `Bearer ${await signAccessToken(env, "u1", "sid-1")}`;
    return api.fetch(new Request(`https://api.septena.app${path}`, {
      method: init.method ?? "POST",
      headers: { Authorization: auth, "Content-Type": "application/json", ...init.headers },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    }), env, EXEC_CTX);
  }

  return { store, mcp, rpc, v1 };
}

const openTitles = (store: Awaited<ReturnType<typeof createTestTaskStore>>["store"], title: string) =>
  store.readTasks("open", 500).rows.filter((r) => r.title === title).length;

describe("AS3 error envelope", () => {
  it("maps each refusal code to one retryable value", () => {
    const expected: Record<string, boolean> = {
      paused: false, stopped: false, your_turn: false, held: true, budget: false, terminal: false, closed: false,
      not_found: false, human_accepts: false, in_review: false, human_ends: false, note_required: false,
      "human_only:assignee": false, stale: false, brief_is_users: false, rate_limited: true, doing: false,
      plan_check_failed: true, unavailable: true, idempotency_conflict: false, idempotency_in_progress: true,
      invalid_arguments: false, read_only: false, plan_limit: false,
    };
    for (const [code, retryable] of Object.entries(expected)) {
      assert.ok(code in REFUSALS, `${code} is in the table`);
      assert.equal(refusalInfo(code).retryable, retryable, code);
      assert.ok(refusalInfo(code).hint.length > 0, `${code} has a hint`);
    }
    for (const [code, info] of Object.entries(REFUSALS)) {
      assert.equal(typeof (info as { retryable: unknown }).retryable, "boolean", code);
    }
    // A reason with a detail suffix falls back to its prefix; old names alias.
    assert.equal(errorEnvelope("immutable:title").hint, REFUSALS.immutable.hint);
    assert.equal(errorEnvelope("unknown_task").code, "not_found");
    assert.equal(refusalInfo("never_heard_of_it").retryable, false);
    // A code keeps its exact name.
    assert.deepEqual(Object.keys(errorEnvelope("held")).sort(), ["code", "hint", "message", "retryable"]);
    assert.equal(envelopeFor(new Refusal("human_only:assignee", "x")).code, "human_only:assignee");
    assert.equal(envelopeFor(Object.assign(new Error("Network connection lost."), { retryable: true })).code, "unavailable");
  });

  for (const era of ["legacy", "modern"] as const) {
    it(`a refused tool call carries the envelope (${era} era)`, async () => {
      const h = await harness();
      const missing = await h.mcp("tasks_get", { id: "zzzz" }, era);
      assert.equal(missing.result?.isError, true);
      assert.match(missing.result!.content[0].text, /Task not found/, "the old text stays first");
      const env = JSON.parse(missing.result!.content[1].text) as { error: Record<string, unknown> };
      assert.deepEqual(env.error, missing.result!.structuredContent!.error);
      assert.equal(env.error.code, "not_found");
      assert.equal(env.error.retryable, false);
      assert.equal(typeof env.error.hint, "string");
      if (era === "modern") assert.equal(missing.result?.resultType, "complete");

      // A store rule: the user paused all agents.
      h.store.push([{ clientOpId: "p1", op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: true } }], "app:test");
      const paused = await h.mcp("tasks_create", { title: "Blocked" }, era);
      assert.equal(paused.result?.isError, true);
      assert.match(paused.result!.content[0].text, /paused/);
      assert.equal(paused.result!.structuredContent!.error.code, "paused");
      assert.equal(paused.result!.structuredContent!.error.retryable, false);

      // Bad arguments are a tool error with the envelope, not a protocol error.
      const bad = await h.mcp("tasks_get", {}, era);
      assert.equal(bad.result?.structuredContent?.error.code, "invalid_arguments");
    });
  }

  it("a refused claim keeps its old fields and adds the envelope", async () => {
    const h = await harness();
    const r = await h.mcp("tasks_claim", { id: "zzzz", agent: "runner" });
    const out = JSON.parse(r.result!.content[0].text) as Record<string, any>;
    assert.equal(out.claimed, false);
    assert.equal(out.reason, "not_found");
    assert.equal(typeof out.rule, "string");
    assert.equal(out.error.code, "not_found");
    assert.equal(out.error.retryable, false);
  });

  it("/v1 sends the envelope only when the caller asks for it", async () => {
    const h = await harness();
    const plain = await h.v1("/tasks/zzzz/complete");
    assert.equal(plain.status, 404);
    assert.deepEqual(await plain.json(), { error: "not_found" }, "app clients see the old body");
    const asked = await h.v1("/tasks/zzzz/complete", { headers: { "X-Septena-Errors": "envelope" } });
    assert.equal(asked.status, 404);
    const body = await asked.json() as { error: Record<string, unknown> };
    assert.equal(body.error.code, "not_found");
    assert.equal(body.error.retryable, false);
    assert.equal(typeof body.error.message, "string");
  });
});

describe("AS3 idempotency keys", () => {
  for (const era of ["legacy", "modern"] as const) {
    it(`a repeated create with one key makes one task (${era} era)`, async () => {
      const h = await harness();
      const first = await h.mcp("tasks_create", { title: "Once", idempotency_key: "key-1", origin: "user_request" }, era);
      const second = await h.mcp("tasks_create", { title: "Once", idempotency_key: "key-1", origin: "user_request" }, era);
      assert.equal(first.result?.isError, undefined);
      assert.equal(first.result!.content[0].text, second.result!.content[0].text, "the repeat returns the first result");
      assert.equal(openTitles(h.store, "Once"), 1);
      // Without a key, a second create is a second task.
      await h.mcp("tasks_create", { title: "Once", origin: "user_request" }, era);
      assert.equal(openTitles(h.store, "Once"), 2);
    });
  }

  it("refuses a key reused with a different body", async () => {
    const h = await harness();
    await h.mcp("tasks_create", { title: "First", idempotency_key: "key-2" });
    const reuse = await h.mcp("tasks_create", { title: "Second", idempotency_key: "key-2" });
    assert.equal(reuse.result?.isError, true);
    assert.equal(reuse.result!.structuredContent!.error.code, "idempotency_conflict");
    assert.equal(reuse.result!.structuredContent!.error.retryable, false);
    assert.equal(openTitles(h.store, "Second"), 0);
  });

  it("keeps nothing for a refused call, so its retry runs", async () => {
    const h = await harness();
    h.store.push([{ clientOpId: "p1", op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: true } }], "app:test");
    const refused = await h.mcp("tasks_create", { title: "Later", idempotency_key: "key-3" });
    assert.equal(refused.result!.structuredContent!.error.code, "paused");
    h.store.push([{ clientOpId: "p2", op: "upsert", entity: "setting", id: "agentsPaused", fields: { value: false } }], "app:test");
    const retry = await h.mcp("tasks_create", { title: "Later", idempotency_key: "key-3" });
    assert.equal(retry.result?.isError, undefined);
    assert.equal(openTitles(h.store, "Later"), 1);
  });

  it("lists the key on write tools only", async () => {
    const h = await harness();
    const r = await h.rpc("tools/list");
    const tools = (r.result as unknown as { tools: { name: string; inputSchema: { properties?: Record<string, unknown> }; annotations: { readOnlyHint: boolean } }[] }).tools;
    for (const t of tools) {
      const has = !!t.inputSchema.properties && "idempotency_key" in t.inputSchema.properties;
      assert.equal(has, !t.annotations.readOnlyHint, t.name);
    }
    assert.ok(tools.some((t) => t.name === "tasks_create" && "idempotency_key" in (t.inputSchema.properties ?? {})));
  });

  // scripts/lib/mcp-tools.mjs reads the tool names from the source for the
  // registry checks (capabilities.json `agent`, skills/*/SKILL.md). It must
  // see exactly the tools that tools/list serves.
  it("serves the tools that scripts/lib/mcp-tools.mjs reads from the source", async () => {
    const h = await harness();
    const r = await h.rpc("tools/list");
    const served = (r.result as unknown as { tools: { name: string }[] }).tools.map((t) => t.name).sort();
    const { mcpToolNames } = await import("../../scripts/lib/mcp-tools.mjs");
    assert.deepEqual(served, mcpToolNames(new URL("../..", import.meta.url).pathname));
  });

  it("expires a key after 24 hours and bounds the table", async () => {
    const { store } = await createTestTaskStore();
    const t0 = 1_000_000_000_000;
    assert.deepEqual(store.idempotencyBegin("k", "h1", t0), { state: "new" });
    assert.deepEqual(store.idempotencyBegin("k", "h1", t0 + 1000), { state: "in_progress" });
    store.idempotencyFinish("k", "h1", "{\"ok\":true}");
    assert.deepEqual(store.idempotencyBegin("k", "h1", t0 + 2000), { state: "replay", result: "{\"ok\":true}" });
    assert.deepEqual(store.idempotencyBegin("k", "h2", t0 + 3000), { state: "conflict" });
    assert.deepEqual(store.idempotencyBegin("k", "h2", t0 + 24 * 3600_000 + 1), { state: "new" }, "an expired key is free");
  });

  it("/v1 replays a write with the same Idempotency-Key", async () => {
    const h = await harness();
    const send = () => h.v1("/tasks", { body: { title: "Wrist" }, headers: { "Idempotency-Key": "v1-key" } });
    const a = await send();
    const b = await send();
    assert.equal(a.status, 201);
    assert.equal(b.status, 201);
    assert.equal(b.headers.get("Idempotent-Replayed"), "true");
    assert.deepEqual(await b.json(), await a.json());
    assert.equal(openTitles(h.store, "Wrist"), 1);
    // The key may also ride in the body.
    const c = await h.v1("/tasks", { body: { title: "Wrist", idempotency_key: "v1-key" } });
    assert.equal(c.headers.get("Idempotent-Replayed"), "true");
    const conflict = await h.v1("/tasks", { body: { title: "Other" }, headers: { "Idempotency-Key": "v1-key", "X-Septena-Errors": "envelope" } });
    assert.equal(conflict.status, 422);
    assert.equal(((await conflict.json()) as { error: { code: string } }).error.code, "idempotency_conflict");
  });
});
