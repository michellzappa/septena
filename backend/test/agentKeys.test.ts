import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// #86: agent keys for agents that cannot sign in. A key is an agent session,
// so the Agents list, disconnect and account deletion cover it.

const { api } = await import("../src/api/routes.ts");
const session = await import("../src/api/session.ts");
const mcp = await import("../src/shadow/tokens.ts");

const DAY = 86_400_000;
const USER = "u_agent_keys_test_1234567890";
const KEY = Buffer.alloc(32, 7).toString("base64");

function memoryKv() {
  const map = new Map<string, string>();
  const meta = new Map<string, unknown>();
  return {
    map,
    meta,
    async get(key: string) { return map.get(key) ?? null; },
    async getWithMetadata(key: string) { return { value: map.get(key) ?? null, metadata: meta.get(key) ?? null }; },
    async put(key: string, value: string, opts?: { metadata?: unknown }) { map.set(key, value); meta.set(key, opts?.metadata); },
    async delete(key: string) { map.delete(key); },
  };
}

async function harness() {
  const made = await createTestTaskStore();
  const tokens = memoryKv();
  const touched: string[] = [];
  let down = false;
  const env = {
    API_PUBLIC_URL: "https://api.septena.app", APPLE_AUDIENCES: "com.septena.tasks", ENTITLEMENT_ENFORCE: "false",
    APPLE_IAP_BUNDLE_IDS: "com.septena.tasks", APPLE_IAP_ENVIRONMENTS: "Production,Sandbox",
    SIGNED_SESSIONS: "true", SESSION_SIGNING_KEY: KEY, SESSION_SIGNING_KEY_PREVIOUS: undefined as string | undefined,
    TOKENS: tokens, STATE: memoryKv(), CLIENTS: memoryKv(), ATTACHMENTS: {},
    TASK_STORE: {
      idFromName: (name: string) => name,
      get: (id: string) => {
        touched.push(id);
        return new Proxy({}, {
          get: (_t, prop: string) => async (...args: unknown[]) => {
            if (down) throw new Error("store unavailable");
            return (made.store as unknown as Record<string, (...a: unknown[]) => unknown>)[prop](...args);
          },
        });
      },
    },
  };
  const e = env as never;
  const refresh = (token: string) => session.refreshSession(e, token);
  const uses = async (token: string) => (await session.authenticate(e, token)) !== null;
  return { ...made, env, e, tokens, touched, refresh, uses, setDown(v: boolean) { down = v; } };
}


async function makeKey(h: Awaited<ReturnType<typeof harness>>, body: unknown) {
  const s = await session.issueSession(h.e, USER);
  const res = await api.request("https://api.septena.app/access/keys", {
    method: "POST",
    headers: { Authorization: `Bearer ${s.accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }, h.e);
  return { res, app: s };
}

describe("agent keys", () => {
  it("creates a key once, and the key acts as the named agent", async () => {
    const h = await harness();
    const { res } = await makeKey(h, { name: "nightly script" });
    assert.equal(res.status, 201);
    assert.equal(res.headers.get("Cache-Control"), "no-store");
    const k = await res.json() as { id: string; key: string; name: string; scope: string };
    assert.match(k.key, /^sk1\./);
    assert.equal(k.scope, "tasks:read tasks:write");
    assert.ok(mcp.isMcpAccessToken(k.key));
    const grant = await mcp.verifyMcpAccess(h.e, k.key);
    assert.equal(grant?.userId, USER);
    assert.equal(grant?.familyId, k.id);
    assert.ok(grant && mcp.hasScope(grant, mcp.MCP_WRITE_SCOPE));
    assert.equal(await h.store.connectionName(k.id), "nightly script");
    const raw = h.db.prepare("SELECT COUNT(*) AS n FROM sessions WHERE hash = ?").get(k.key) as { n: number };
    assert.equal(raw.n, 0, "the store never holds the key itself");
  });

  it("grants read only when asked", async () => {
    const h = await harness();
    const k = await (await makeKey(h, { name: "reader", access: "read" })).res.json() as { key: string };
    const grant = await mcp.verifyMcpAccess(h.e, k.key);
    assert.ok(grant && mcp.hasScope(grant, mcp.MCP_READ_SCOPE));
    assert.equal(grant && mcp.hasScope(grant, mcp.MCP_WRITE_SCOPE), false);
  });

  it("refuses a bad body, an agent token and no token", async () => {
    const h = await harness();
    assert.equal((await makeKey(h, { name: "" })).res.status, 400);
    assert.equal((await makeKey(h, { name: "x", access: "admin" })).res.status, 400);
    assert.equal((await makeKey(h, { name: "x", extra: 1 })).res.status, 400);
    const k = await (await makeKey(h, { name: "agent" })).res.json() as { key: string };
    const byAgent = await api.request("https://api.septena.app/access/keys", {
      method: "POST", headers: { Authorization: `Bearer ${k.key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ name: "minted by an agent" }),
    }, h.e);
    assert.equal(byAgent.status, 401, "an agent cannot mint keys");
  });

  it("refuses a forged, altered or foreign key", async () => {
    const h = await harness();
    const k = await (await makeKey(h, { name: "agent" })).res.json() as { key: string };
    const [prefix, user, id, secret] = k.key.split(".");
    assert.equal(await mcp.verifyMcpAccess(h.e, `${prefix}.${user}.${id}.${secret.slice(0, -2)}AA`), null);
    assert.equal(await mcp.verifyMcpAccess(h.e, `${prefix}.${user}.other_id_123456.${secret}`), null);
    assert.equal(await mcp.verifyMcpAccess(h.e, "sk1.garbage"), null);
    assert.equal(await mcp.verifyMcpAccess(h.e, "sk1.a.b.c.d"), null);
  });

  it("is listed, never expires, and dies on revoke", async () => {
    const h = await harness();
    const { res, app } = await makeKey(h, { name: "cron" });
    const k = await res.json() as { id: string; key: string };
    const list = async () => (await (await api.request("https://api.septena.app/access", { headers: { Authorization: `Bearer ${app.accessToken}` } }, h.e)).json()) as { connections: { id: string; name: string; clientName: string }[] };
    const row = (await list()).connections.find((c) => c.id === k.id);
    assert.equal(row?.name, "cron");
    assert.equal(row?.clientName, "Agent key");

    // A year unused: the row and the key stay.
    h.db.prepare("UPDATE connections SET lastUsed = lastUsed - ?").run(365 * DAY);
    await h.store.alarm();
    assert.ok((await list()).connections.some((c) => c.id === k.id));
    assert.ok(await mcp.verifyMcpAccess(h.e, k.key));
    const used = h.db.prepare("SELECT lastUsed FROM connections WHERE familyId = ?").get(k.id) as { lastUsed: number };
    assert.ok(Date.now() - used.lastUsed < 60_000, "a use moves last used");

    const del = await api.request(`https://api.septena.app/access/connections/${k.id}`, { method: "DELETE", headers: { Authorization: `Bearer ${app.accessToken}` } }, h.e);
    assert.equal(del.status, 204);
    assert.equal(await mcp.verifyMcpAccess(h.e, k.key), null);
  });

  it("does not replace another key, and RFC 7009 revoke ends it", async () => {
    const h = await harness();
    const a = await (await makeKey(h, { name: "a" })).res.json() as { key: string };
    const b = await (await makeKey(h, { name: "b" })).res.json() as { key: string };
    assert.ok(await mcp.verifyMcpAccess(h.e, a.key));
    assert.ok(await mcp.verifyMcpAccess(h.e, b.key));
    assert.equal(await mcp.revokeMcpToken(h.e, a.key), "refresh");
    assert.equal(await mcp.verifyMcpAccess(h.e, a.key), null);
    assert.ok(await mcp.verifyMcpAccess(h.e, b.key));
  });

  it("dies with the account", async () => {
    const h = await harness();
    const k = await (await makeKey(h, { name: "a" })).res.json() as { key: string };
    await h.store.deleteAccount();
    assert.equal(await mcp.verifyMcpAccess(h.e, k.key), null);
  });
});
