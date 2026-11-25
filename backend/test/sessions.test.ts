import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// ADR 0040: a lost reply never signs anyone out, and a stolen token never
// stays unnoticed.

const { api } = await import("../src/api/routes.ts");
const session = await import("../src/api/session.ts");
const mcp = await import("../src/shadow/tokens.ts");
const { SESSION_HEADER, SESSION_LEEWAY_MS } = await import("../src/store/sessions.ts");
const { sha256Base64Url } = await import("../src/util.ts");

const DAY = 86_400_000;
const USER = "u_sessions_test_1234567890";
const KEY = Buffer.alloc(32, 7).toString("base64");

type Store = Awaited<ReturnType<typeof createTestTaskStore>>["store"];

function memoryKv() {
  const map = new Map<string, string>();
  return {
    map,
    async get(key: string) { return map.get(key) ?? null; },
    async put(key: string, value: string) { map.set(key, value); },
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
    SESSION_SIGNING_KEY: KEY, SESSION_SIGNING_KEY_PREVIOUS: undefined as string | undefined,
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

/// Moves every stored time back, so the leeway is over.
function age(db: Awaited<ReturnType<typeof createTestTaskStore>>["db"], ms = SESSION_LEEWAY_MS + 1_000) {
  db.prepare("UPDATE sessions SET createdAt = createdAt - ?, usedAt = usedAt - ?, retiredAt = retiredAt - ?").run(ms, ms, ms);
}

describe("app session renewal", () => {
  it("survives a lost reply, hours later and many times over", async () => {
    const h = await harness();
    const s0 = await session.issueSession(h.e, USER);
    assert.ok(await h.uses(s0.accessToken));
    for (let i = 0; i < 20; i++) {
      assert.ok(await h.refresh(s0.refreshToken), `lost reply ${i}`);
      age(h.db, 60 * 60 * 1000);
    }
    const s1 = await h.refresh(s0.refreshToken);
    assert.ok(s1 && await h.uses(s1.accessToken));
    const s2 = await h.refresh(s1.refreshToken);
    assert.ok(s2 && await h.uses(s2.accessToken));
  });

  it("keeps the session when the store fails during a renewal", async () => {
    const h = await harness();
    const s0 = await session.issueSession(h.e, USER);
    h.setDown(true);
    await assert.rejects(h.refresh(s0.refreshToken));
    await assert.rejects(h.uses(s0.accessToken), "an outage is not a sign-out");
    h.setDown(false);
    assert.ok(await h.refresh(s0.refreshToken));
  });

  it("needs no KV", async () => {
    const h = await harness();
    const s0 = await session.issueSession(h.e, USER);
    await h.refresh(s0.refreshToken);
    assert.equal(h.tokens.map.size, 0);
  });

  it("ends the session when a spent token comes back", async () => {
    const h = await harness();
    const stolen = await session.issueSession(h.e, USER);
    const owner = await h.refresh(stolen.refreshToken);
    assert.ok(owner && await h.uses(owner.accessToken));
    age(h.db);
    assert.equal(await h.refresh(stolen.refreshToken), null);
    assert.equal(await h.uses(owner.accessToken), false, "both holders are out");
    assert.equal(await h.refresh(owner.refreshToken), null);
  });

  it("notices a thief who renews first, and one who hoards an unused reply", async () => {
    const first = await harness();
    const a0 = await session.issueSession(first.e, USER);
    const thief = await first.refresh(a0.refreshToken);
    assert.ok(thief && await first.uses(thief.accessToken));
    age(first.db);
    assert.equal(await first.refresh(a0.refreshToken), null, "the owner's next renewal exposes the theft");
    assert.equal(await first.uses(thief.accessToken), false);

    const second = await harness();
    const b0 = await session.issueSession(second.e, USER);
    const hoarded = await second.refresh(b0.refreshToken);
    const owner = await second.refresh(b0.refreshToken);
    assert.ok(hoarded && owner && await second.uses(owner.accessToken));
    age(second.db);
    assert.equal(await second.uses(hoarded.accessToken), false, "a losing reply buys nothing");
    assert.equal(await second.refresh(hoarded.refreshToken), null);
    assert.equal(await second.uses(owner.accessToken), false);
  });

  it("still knows a spent token after its row is purged", async () => {
    const h = await harness();
    const s0 = await session.issueSession(h.e, USER);
    const s1 = await h.refresh(s0.refreshToken);
    assert.ok(s1 && await h.uses(s1.accessToken));
    age(h.db, DAY);
    await h.store.alarm();
    assert.equal(await h.refresh(s0.refreshToken), null);
    assert.equal(await h.uses(s1.accessToken), false);
  });

  it("settles a race between two processes, then allows one branch only", async () => {
    const h = await harness();
    const s0 = await session.issueSession(h.e, USER);
    const [a, b] = await Promise.all([h.refresh(s0.refreshToken), h.refresh(s0.refreshToken)]);
    assert.ok(a && b && await h.uses(a.accessToken) && await h.uses(b.accessToken));
    age(h.db);
    assert.ok(await h.uses(a.accessToken) && await h.uses(b.accessToken));
    const a2 = await h.refresh(a.refreshToken);
    assert.ok(a2 && await h.uses(a2.accessToken));
    age(h.db);
    assert.equal(await h.refresh(b.refreshToken), null);
    assert.equal(await h.uses(a2.accessToken), false);
  });

  it("accepts a retired token inside the leeway", async () => {
    const h = await harness();
    const s0 = await session.issueSession(h.e, USER);
    const a = await h.refresh(s0.refreshToken);
    assert.ok(a && await h.uses(a.accessToken));
    const b = await h.refresh(s0.refreshToken);
    assert.ok(b && await h.uses(b.accessToken) && await h.uses(a.accessToken));
  });

  it("refuses forged tokens without touching a store", async () => {
    const h = await harness();
    const s0 = await session.issueSession(h.e, USER);
    h.touched.length = 0;
    const parts = s0.refreshToken.split(".");
    for (const forged of [
      [parts[0], "u_someone_else", ...parts.slice(2)].join("."),
      [...parts.slice(0, 4), "A".repeat(43)].join("."),
      ["smr2", ...parts.slice(1)].join("."),
      "sr2.a.b.c.d", "sr2....", "x".repeat(60), "sr1.unknown_token_value_unknown",
    ]) assert.equal(await h.refresh(forged), null, forged);
    assert.deepEqual(h.touched, []);
  });

  it("keeps sessions over a signing key change", async () => {
    const h = await harness();
    const s0 = await session.issueSession(h.e, USER);
    h.env.SESSION_SIGNING_KEY_PREVIOUS = KEY;
    h.env.SESSION_SIGNING_KEY = Buffer.alloc(32, 9).toString("base64");
    assert.ok(await h.uses(s0.accessToken));
    const s1 = await h.refresh(s0.refreshToken);
    h.env.SESSION_SIGNING_KEY_PREVIOUS = undefined;
    assert.ok(s1 && await h.uses(s1.accessToken));
    assert.equal(await h.uses(s0.accessToken), false);
  });

  it("carries over a token from before ADR 0040, lost replies included", async () => {
    const h = await harness();
    const old = "sr1.token_from_before_the_change";
    const hash = await sha256Base64Url(old);
    h.tokens.map.set(`api-refresh:${hash}`, USER);
    h.db.prepare("INSERT INTO sessions (hash, createdAt, expiresAt, sid) VALUES (?, ?, ?, ?)").run(hash, Date.now(), Date.now() + DAY, "sid-old");
    assert.ok(await h.uses(await session.signAccessToken(h.e, USER, "sid-old")), "its access token too");
    assert.ok(await h.refresh(old));
    age(h.db, DAY / 4);
    const s1 = await h.refresh(old);
    assert.ok(s1 && await h.uses(s1.accessToken));
    age(h.db);
    assert.equal(await h.refresh(old), null);
  });
});

describe("ending a session", () => {
  it("counts from the next request and closes its sockets only", async () => {
    const h = await harness();
    const s0 = await session.issueSession(h.e, USER);
    const other = await session.issueSession(h.e, USER);
    const claims = await session.verifyAccessToken(h.e, s0.accessToken);
    assert.ok(claims);
    const closed: string[] = [];
    h.sockets.push({ ws: { close: () => closed.push("mine") } as never, tags: [`sid:${claims.sid}`] });
    h.sockets.push({ ws: { close: () => closed.push("other") } as never, tags: ["sid:else"] });
    await session.revokeSession(h.e, s0.refreshToken);
    assert.deepEqual(closed, ["mine"]);
    assert.equal(await h.uses(s0.accessToken), false);
    assert.ok(await h.uses(other.accessToken));
    const res = await api.request("https://api.septena.app/access", { headers: { Authorization: `Bearer ${s0.accessToken}` } }, h.e);
    assert.equal(res.status, 401);
  });

  it("stamps the stream's session itself", () => {
    const req = session.withSession(new Request("https://api.septena.app/x", { headers: { [SESSION_HEADER]: "someone-else" } }), "mine", SESSION_HEADER);
    assert.equal(req.headers.get(SESSION_HEADER), "mine");
  });
});

describe("agent tokens", () => {
  const grant = { userId: USER, clientId: "client-a", scope: "tasks:read tasks:write", timeZone: "Europe/Lisbon" };

  it("survives a lost reply and keeps the grant", async () => {
    const h = await harness();
    const t0 = await mcp.issueMcpTokens(h.e, grant, "family-0001");
    const lost = await mcp.redeemMcpRefresh(h.e, t0.refresh_token, "client-a");
    assert.ok(lost.ok);
    age(h.db, 60 * 60 * 1000);
    const again = await mcp.redeemMcpRefresh(h.e, t0.refresh_token, "client-a");
    assert.ok(again.ok);
    assert.deepEqual(await mcp.verifyMcpAccess(h.e, again.tokens.access_token), { ...grant, familyId: "family-0001" });
  });

  it("ends the family on reuse, for the list too", async () => {
    const h = await harness();
    const t0 = await mcp.issueMcpTokens(h.e, grant, "family-0001");
    const t1 = await mcp.redeemMcpRefresh(h.e, t0.refresh_token, "client-a");
    assert.ok(t1.ok && await mcp.verifyMcpAccess(h.e, t1.tokens.access_token));
    age(h.db);
    assert.deepEqual(await mcp.redeemMcpRefresh(h.e, t0.refresh_token, "client-a"), { ok: false, reason: "replayed" });
    assert.equal(await mcp.verifyMcpAccess(h.e, t1.tokens.access_token), null);
    assert.equal(h.store.accessSummary(null, null).connections.length, 0);
  });

  it("keeps apps and agents apart, and one client's token from another", async () => {
    const h = await harness();
    const agent = await mcp.issueMcpTokens(h.e, grant, "family-0001");
    const app = await session.issueSession(h.e, USER);
    assert.equal(await h.uses(agent.access_token), false);
    assert.equal(await mcp.verifyMcpAccess(h.e, app.accessToken), null);
    assert.equal(await h.refresh(agent.refresh_token), null);
    assert.deepEqual(await mcp.redeemMcpRefresh(h.e, app.refreshToken, "client-a"), { ok: false, reason: "not_found" });
    assert.deepEqual(await mcp.redeemMcpRefresh(h.e, agent.refresh_token, "client-b"), { ok: false, reason: "client_mismatch" });
    assert.equal(await h.uses(await session.signAccessToken(h.e, USER, "family-0001")), false, "no agent session through the old claim shape");
    assert.ok((await mcp.redeemMcpRefresh(h.e, agent.refresh_token, "client-a")).ok);
  });

  it("revokes one access token, or the family, or on disconnect everything", async () => {
    const h = await harness();
    const t0 = await mcp.issueMcpTokens(h.e, grant, "family-0001");
    assert.equal(await mcp.revokeMcpToken(h.e, t0.access_token), "access");
    assert.equal(await mcp.verifyMcpAccess(h.e, t0.access_token), null);
    const t1 = await mcp.redeemMcpRefresh(h.e, t0.refresh_token, "client-a");
    assert.ok(t1.ok && await mcp.verifyMcpAccess(h.e, t1.tokens.access_token));
    assert.equal(await mcp.revokeMcpToken(h.e, t1.tokens.refresh_token), "refresh");
    assert.equal(await mcp.verifyMcpAccess(h.e, t1.tokens.access_token), null);

    const u0 = await mcp.issueMcpTokens(h.e, grant, "family-0002");
    assert.equal(await mcp.disconnectFamily(h.e, USER, "family-0002"), true);
    assert.equal(await mcp.verifyMcpAccess(h.e, u0.access_token), null);
    assert.equal((await mcp.redeemMcpRefresh(h.e, u0.refresh_token, "client-a")).ok, false);
  });

  it("carries over an agent from KV, and never one that was disconnected", async () => {
    const h = await harness();
    const old = "smr1.refresh_from_before_the_change";
    const hash = await sha256Base64Url(old);
    const rec = { ...grant, familyId: "family-old1", expiresAt: Date.now() + DAY };
    h.tokens.map.set(`v2:refresh:${hash}`, JSON.stringify(rec));
    assert.equal((await mcp.redeemMcpRefresh(h.e, old, "client-a")).ok, false, "not connected");
    h.store.recordConnection("family-old1", "client-a", "Claude", grant.scope);
    assert.ok((await mcp.redeemMcpRefresh(h.e, old, "client-a")).ok);
    const again = await mcp.redeemMcpRefresh(h.e, old, "client-a");
    assert.ok(again.ok, "lost reply");
    assert.equal((await mcp.verifyMcpAccess(h.e, again.tokens.access_token))?.timeZone, "Europe/Lisbon");
    assert.equal(await mcp.disconnectFamily(h.e, USER, "family-old1"), true);
    assert.equal((await mcp.redeemMcpRefresh(h.e, old, "client-a")).ok, false);
  });
});

describe("account deletion", () => {
  it("refuses every token of the account", async () => {
    const h = await harness();
    const app = await session.issueSession(h.e, USER);
    const agent = await mcp.issueMcpTokens(h.e, { userId: USER, clientId: "c", scope: "tasks:read" }, "family-0001");
    await (h.store as Store).deleteAccount();
    assert.equal(await h.uses(app.accessToken), false);
    assert.equal(await h.refresh(app.refreshToken), null);
    assert.equal(await mcp.verifyMcpAccess(h.e, agent.access_token), null);
    assert.equal((await mcp.redeemMcpRefresh(h.e, agent.refresh_token, "c")).ok, false);
  });
});
