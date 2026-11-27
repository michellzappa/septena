import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestAccountStore, createTestPairingStore, createTestTaskStore, ensureSession, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Plus links and the admin page (ADR 0043, #198).

const { addMonths } = await import("../src/store/plusLinks.ts");
const { claimPlusLink, createPlusLink, plusContinue, plusLanding, plusStart, revokePlusLink } = await import("../src/api/plusLinks.ts");
const { admin } = await import("../src/admin/routes.ts");
const { overview, planView, sweepAccounts } = await import("../src/admin/accounts.ts");
const { approvePairing, inspectPairing, pollDevicePairing } = await import("../src/shadow/oauth.ts");
const { grantRow, planFor, resolvePlan, trialRow } = await import("../src/entitlement/entitlement.ts");
const { base64url } = await import("../src/util.ts");
const { Hono } = await import("hono");

const ORIGIN = "https://api.septena.app";
const TEAM = "test.cloudflareaccess.com";
const DAY = 86_400_000;
const userId = (n: number) => `u_${String(n).repeat(43)}`;

async function harness() {
  const { store: accounts } = await createTestAccountStore();
  const tasks = new Map<string, Awaited<ReturnType<typeof createTestTaskStore>>["store"]>();
  const pairings = new Map<string, Awaited<ReturnType<typeof createTestPairingStore>>["store"]>();
  const kv = () => {
    const map = new Map<string, string>();
    return {
      async get(k: string) { return map.get(k) ?? null; },
      async put(k: string, v: string) { map.set(k, v); },
      async delete(k: string) { map.delete(k); },
      async list({ prefix }: { prefix: string }) {
        return { keys: [...map.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true };
      },
    };
  };
  const ns = (make: (id: string) => Promise<object>) => ({
    idFromName: (name: string) => name,
    get: (id: string) => new Proxy({}, {
      get: (_t, prop: string) => async (...args: unknown[]) =>
        ((await make(id)) as Record<string, (...a: unknown[]) => unknown>)[prop](...args),
    }),
  });
  const taskStore = async (id: string) => {
    if (!tasks.has(id)) tasks.set(id, (await createTestTaskStore()).store);
    return tasks.get(id)!;
  };
  const env = {
    API_PUBLIC_URL: ORIGIN, ENTITLEMENT_ENFORCE: "true", ADMIN_EMAILS: "mz@example.com",
    ACCESS_TEAM_DOMAIN: TEAM, ACCESS_AUD: "aud-1",
    TOKENS: kv(), STATE: kv(), CLIENTS: kv(),
    TASK_STORE: ns(taskStore),
    ACCOUNT_STORE: ns(async () => accounts),
    PAIRING: ns(async (id) => {
      if (!pairings.has(id)) pairings.set(id, (await createTestPairingStore()).store);
      return pairings.get(id)!;
    }),
  } as never;
  const signIn = async (id: string) => { ensureSession(await taskStore(id), `sid-${id}`); };
  const app = new Hono();
  app.get("/plus/:token", plusLanding as never);
  app.post("/plus/:token/start", plusStart as never);
  app.get("/plus/:token/continue", plusContinue as never);
  app.route("/admin", admin as never);
  const ctx = { waitUntil() {}, passThroughOnException() {} } as never;
  const call = (path: string, init?: RequestInit) => app.fetch(new Request(`${ORIGIN}${path}`, init), env, ctx);
  return { env, accounts, taskStore, signIn, call };
}

const hashOf = async (url: string) =>
  base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(url.split("/plus/")[1]))));

describe("Plus links", () => {
  it("adds calendar months and stays inside the target month", () => {
    assert.equal(new Date(addMonths(Date.UTC(2026, 0, 31), 1)).toISOString().slice(0, 10), "2026-02-28");
    assert.equal(new Date(addMonths(Date.UTC(2026, 10, 25), 12)).toISOString().slice(0, 10), "2027-11-25");
  });

  it("gives Plus once per account, keeps the count, and stops at the limit", async () => {
    const h = await harness();
    const made = (await createPlusLink(h.env, { label: "Friends", months: 12, maxUses: 2, plan: "plus" }))!;
    const hash = await hashOf(made.url);
    for (const n of [1, 2, 3]) await h.signIn(userId(n));
    const first = await claimPlusLink(h.env, hash, userId(1));
    assert.ok(first?.expiresAt && first.expiresAt > Date.now() + 360 * DAY);
    assert.equal((await claimPlusLink(h.env, hash, userId(1)))?.expiresAt, first!.expiresAt, "the same account claims the same grant");
    assert.ok(await claimPlusLink(h.env, hash, userId(2)));
    assert.equal(await claimPlusLink(h.env, hash, userId(3)), null, "used up");
    assert.deepEqual((await h.taskStore(userId(3))).entitlements(), []);
    assert.equal((await h.taskStore(userId(1))).entitlements()[0].source, "grant");
    h.accounts.deleteIdentitiesForUser(userId(2));
    assert.equal(h.accounts.openPlusLink(hash), null, "a deleted account does not free a use");
  });

  it("close keeps Plus, take back ends it for one or for all", async () => {
    const h = await harness();
    const made = (await createPlusLink(h.env, { label: "Press", months: null, maxUses: 9, plan: "plus" }))!;
    const hash = await hashOf(made.url);
    for (const n of [1, 2, 3]) await h.signIn(userId(n));
    assert.equal((await claimPlusLink(h.env, hash, userId(1)))?.expiresAt, null);
    await claimPlusLink(h.env, hash, userId(2));
    h.accounts.closePlusLink(made.link.id);
    assert.equal(await claimPlusLink(h.env, hash, userId(3)), null);
    assert.ok(await claimPlusLink(h.env, hash, userId(1)), "an account that has it keeps it");
    await revokePlusLink(h.env, made.link.id, userId(1));
    assert.deepEqual((await h.taskStore(userId(1))).entitlements(), []);
    assert.equal(await claimPlusLink(h.env, hash, userId(1)), null, "a taken-back grant does not return");
    assert.equal((await h.taskStore(userId(2))).entitlements().length, 1);
    await revokePlusLink(h.env, made.link.id, null);
    assert.deepEqual((await h.taskStore(userId(2))).entitlements(), []);
  });

  it("refuses an account with no session", async () => {
    const h = await harness();
    const made = (await createPlusLink(h.env, { label: "x", months: 1, maxUses: 1, plan: "plus" }))!;
    assert.equal(await claimPlusLink(h.env, await hashOf(made.url), userId(1)), null);
    assert.ok(h.accounts.openPlusLink(await hashOf(made.url)), "no use is spent");
  });

  it("runs the whole page: open, start, approve in the app, Plus is on; the code never signs anything in", async () => {
    const h = await harness();
    await h.signIn(userId(1));
    const made = (await createPlusLink(h.env, { label: "Anna", months: 12, maxUses: 1, plan: "plus" }))!;
    const path = new URL(made.url).pathname;
    const landing = await h.call(path);
    assert.equal(landing.status, 200);
    assert.ok(!(await landing.text()).includes("Anna"), "the label is for mz only");
    const start = await h.call(`${path}/start`, { method: "POST" });
    assert.equal(start.status, 303);
    const cookie = start.headers.get("Set-Cookie")!.split(";")[0];
    const [code, secret] = cookie.split("=")[1].split(".");
    const go = () => h.call(`${path}/continue`, { headers: { Cookie: cookie } });
    assert.match(await (await go()).text(), /Approve this code/);
    const seen = await inspectPairing(h.env, userId(1), { code });
    assert.ok(seen.ok && seen.kind === "device" && seen.client === "Septena plan link");
    const approved = await approvePairing(h.env, userId(1), { code, kind: "device" });
    assert.ok(approved.ok);
    assert.equal((await pollDevicePairing(h.env, { code, pollSecret: secret })).status, "gone", "a plus code mints no session");
    assert.match(await (await go()).text(), /Plus is on/);
    assert.equal((await h.taskStore(userId(1))).entitlements().length, 1);
    assert.equal((await go()).status, 410, "one shot");
    assert.equal((await h.call(path)).status, 404, "used up");
    assert.equal((await h.call("/plus/nonsense")).status, 404);
  });
});

describe("Pro", () => {
  it("is the highest active grant, gives the Pro limits, and ends with its row", async () => {
    const h = await harness();
    await h.signIn(userId(1));
    const store = await h.taskStore(userId(1));
    const plan = () => planFor(h.env, userId(1));
    store.startTrialOnce(trialRow());
    assert.equal((await plan()).plan, "plus");
    const made = (await createPlusLink(h.env, { label: "Pro", plan: "pro", months: null, maxUses: 1 }))!;
    assert.equal((await claimPlusLink(h.env, await hashOf(made.url), userId(1)))?.plan, "pro");
    const pro = await plan();
    assert.deepEqual([pro.plan, pro.limits.connectedAgents, pro.limits.attachmentsGB, pro.limits.devices], ["pro", null, 50, null]);
    await revokePlusLink(h.env, made.link.id, null);
    assert.equal((await plan()).plan, "plus", "back to the trial");
    store.putEntitlement({ ...grantRow("grant:x", "pro", Date.now() - 1, null) }, "admin");
    assert.equal((await plan()).plan, "plus", "an ended Pro row gives nothing");
  });

  it("keeps rows and links from before plans as Plus", async () => {
    const { store, db } = await createTestTaskStore();
    store.putEntitlement({ ...grantRow("grant:old", "plus", null, null), plan: undefined }, "admin");
    db.exec("ALTER TABLE entitlements DROP COLUMN plan");
    const reopened = (await createTestTaskStore(db)).store;
    assert.equal(resolvePlan(reopened.entitlements()), "plus");
    const first = await createTestAccountStore();
    first.store.createPlusLink("hash", { label: "old", plan: "pro", months: null, maxUses: 1 });
    first.db.exec("ALTER TABLE plus_links DROP COLUMN plan");
    const again = (await createTestAccountStore(first.db)).store;
    assert.equal(again.listPlusLinks().links[0].plan, "plus");
  });
});

describe("account index", () => {
  it("seeds old accounts, counts content without carrying it, and forgets empty stores", async () => {
    const h = await harness();
    const old = userId(1), gone = userId(2), fresh = userId(3);
    const tokens = (h.env as { TOKENS: { put(k: string, v: string): Promise<void> } }).TOKENS;
    await tokens.put(`trial-used:${old}`, "1");
    await tokens.put(`trial-used:${gone}`, "1");
    await tokens.put("ent-aat:some-token", old);
    const s = await h.taskStore(old);
    ensureSession(s, "sid-old");
    s.deviceAccess("sid-old", "septask-ios", null, Date.now(), "0.9.3 (1234)");
    s.startTrialOnce(trialRow());
    s.recordConnection("fam", "c1", "Claude", "tasks:read", Date.now(), "My secret agent");
    s.push([{ clientOpId: "op-1", op: "upsert", entity: "task", id: "11111111-1111-4111-8111-111111111111", fields: { title: "Secret title", status: "open" } }] as never, "app:test");
    const { userId: emailUser } = await h.accounts.resolveOrCreateIdentity("email", "a@example.com");
    await h.accounts.resolveOrCreateIdentity("apple", "sub-1", fresh);
    assert.equal(await sweepAccounts(h.env), 4);
    const rows = h.accounts.listAccounts();
    assert.deepEqual(new Set(rows.map((r) => r.userId)), new Set([old, emailUser, fresh]));
    const row = rows.find((r) => r.userId === old)!;
    assert.equal(row.summary?.openTasks, 1);
    assert.equal(row.summary?.devices[0].version, "0.9.3 (1234)");
    assert.ok(!/secret/i.test(JSON.stringify(rows)), "no title and no user-typed name");
    assert.deepEqual(rows.find((r) => r.userId === emailUser)?.providers, ["email"]);
    assert.equal(planView(row.summary).word, "trial");
    assert.equal(overview(rows).accounts, 3);
    assert.equal(await sweepAccounts(h.env), 0, "fresh summaries are not read again");
    h.accounts.deleteIdentitiesForUser(old);
    h.accounts.saveSummaries([{ userId: old, summary: row.summary }]);
    assert.ok(!h.accounts.listAccounts().some((r) => r.userId === old), "a deleted account does not come back");
  });

  it("never counts a sandbox purchase as a customer", () => {
    const base = { id: "apple:1", source: "apple" as const, productId: "com.septena.tasks.sync.annual", status: "expired" as const, expiresAt: 1, signedAt: 1 };
    const view = (environment: string) => planView({ entitlements: [{ ...base, environment }] } as never).word;
    assert.equal(view("Sandbox"), "free");
    assert.equal(view("Production"), "lapsed");
  });
});

describe("admin page", () => {
  async function accessJwt(email: string, over: Record<string, unknown> = {}) {
    const pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
    const kid = crypto.randomUUID();
    const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid };
    const enc = (v: unknown) => base64url(new TextEncoder().encode(JSON.stringify(v)));
    const now = Math.floor(Date.now() / 1000);
    const head = `${enc({ alg: "RS256", kid })}.${enc({ iss: `https://${TEAM}`, aud: ["aud-1"], exp: now + 600, email, ...over })}`;
    const sig = base64url(new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(head))));
    globalThis.fetch = (async () => new Response(JSON.stringify({ keys: [jwk] }))) as typeof fetch;
    return `${head}.${sig}`;
  }

  it("is 404 without a valid Access token for a listed email", async () => {
    const h = await harness();
    const get = (jwt?: string) => h.call("/admin", jwt ? { headers: { "CF-Access-Jwt-Assertion": jwt } } : undefined);
    assert.equal((await get()).status, 404);
    assert.equal((await h.call("/admin", { headers: { "CF-Access-Authenticated-User-Email": "mz@example.com" } })).status, 404);
    assert.equal((await get(await accessJwt("eve@example.com"))).status, 404);
    assert.equal((await get(await accessJwt("mz@example.com", { aud: ["other"] }))).status, 404);
    const jwt = await accessJwt("mz@example.com");
    assert.equal((await get(jwt)).status, 200);
    (h.env as Record<string, unknown>).ACCESS_AUD = "";
    assert.equal((await get(jwt)).status, 404);
  });

  it("makes a link, refuses a write from another origin, and escapes what it shows", async () => {
    const h = await harness();
    const jwt = await accessJwt("mz@example.com");
    const post = (path: string, body: Record<string, string>, origin = ORIGIN) => h.call(path, {
      method: "POST", body: new URLSearchParams(body), headers: { "CF-Access-Jwt-Assertion": jwt, Origin: origin },
    });
    const form = { label: "<b>Anna</b>", plan: "plus", months: "forever", maxUses: "3" };
    assert.equal((await post("/admin/links", form, "https://evil.example")).status, 403);
    assert.equal((await post("/admin/links", { ...form, maxUses: "0" })).status, 400);
    const html = await (await post("/admin/links", form)).text();
    assert.match(html, /https:\/\/api\.septena\.app\/plus\/pl_[A-Za-z0-9_-]{32}/);
    assert.ok(html.includes("&lt;b&gt;Anna") && !html.includes("<b>Anna"));
    const id = h.accounts.listPlusLinks().links[0].id;
    assert.equal((await post(`/admin/links/${id}/revoke`, {})).status, 404, "a revoke must say who");
    const closed = await post(`/admin/links/${id}/close`, {});
    assert.equal(closed.status, 303);
    assert.equal(closed.headers.get("Location"), "/admin/plans");
    assert.ok(h.accounts.listPlusLinks().links[0].closedAt);
  });

  it("gives a listed account a plan, changes it, takes it back, and touches no other account", async () => {
    const h = await harness();
    const jwt = await accessJwt("mz@example.com");
    const post = (path: string, body: Record<string, string> = {}) => h.call(path, {
      method: "POST", body: new URLSearchParams(body), headers: { "CF-Access-Jwt-Assertion": jwt, Origin: ORIGIN },
    });
    const { userId: id } = await h.accounts.resolveOrCreateIdentity("email", "a@example.com");
    await h.signIn(id);
    await sweepAccounts(h.env);
    const rows = async () => (await h.taskStore(id)).entitlements();
    assert.equal((await post(`/admin/accounts/${id}/plan`, { plan: "pro", months: "forever" })).status, 303);
    assert.deepEqual((await rows()).map((r) => [r.id, r.plan, r.expiresAt]), [["grant:admin", "pro", null]]);
    const view = planView(h.accounts.listAccounts()[0].summary);
    assert.deepEqual([view.word, view.plan, view.until, view.adminGrant], ["granted", "pro", null, true]);
    await post(`/admin/accounts/${id}/plan`, { plan: "plus", months: "12" });
    assert.deepEqual((await rows()).map((r) => r.plan), ["plus"], "one grant per account");
    assert.equal((await post(`/admin/accounts/${id}/plan`, { plan: "free", months: "12" })).status, 404);
    assert.equal((await post(`/admin/accounts/${userId(9)}/plan`, { plan: "pro", months: "forever" })).status, 404, "an unlisted id gets no store");
    assert.equal((await post(`/admin/accounts/${id}/plan/end`)).status, 303);
    assert.deepEqual(await rows(), []);
  });
});
