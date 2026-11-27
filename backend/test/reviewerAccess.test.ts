import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Hono } from "hono";
import { createTestAccountStore, createTestPairingStore, createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Directory reviewer access (ADR 0055, septena#85): the pairing page offers
// the demo account only in reviewer mode, and only for the right code.

const oauth = await import("../src/shadow/oauth.ts");
const { api } = await import("../src/api/routes.ts");
const { reviewerMode, REVIEWER_MAX_FAILURES } = await import("../src/shadow/reviewer.ts");

const EXEC_CTX = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
const DEMO = "u_reviewer_demo_account_0001";
const CODE = "reviewer-code-for-tests";

function makeMemoryKv() {
  const map = new Map<string, string>();
  return {
    map,
    async get(key: string) { return map.get(key) ?? null; },
    async put(key: string, value: string) { map.set(key, value); },
    async delete(key: string) { map.delete(key); },
  };
}

async function makeHarness(vars: Record<string, string | undefined> = { REVIEWER_CODE: CODE, REVIEWER_ACCOUNT_ID: DEMO }) {
  const taskStores = new Map<string, Awaited<ReturnType<typeof createTestTaskStore>>["store"]>();
  const ensureTaskStore = async (userId: string) => {
    let s = taskStores.get(userId);
    if (!s) { s = (await createTestTaskStore()).store; taskStores.set(userId, s); }
    return s;
  };
  const { store: accountStore } = await createTestAccountStore();
  const pairingStores = new Map<string, Awaited<ReturnType<typeof createTestPairingStore>>>();
  const ensurePairing = async (id: string) => {
    let p = pairingStores.get(id);
    if (!p) { p = await createTestPairingStore(); pairingStores.set(id, p); }
    return p.store;
  };
  const proxy = (target: () => Promise<unknown>) => new Proxy({}, {
    get(_t, prop: string) {
      return async (...args: unknown[]) =>
        ((await target()) as Record<string, (...a: unknown[]) => unknown>)[prop](...args);
    },
  });
  const state = makeMemoryKv();
  const clients = makeMemoryKv();
  const env = {
    API_PUBLIC_URL: "https://api.septena.app",
    WEB_ALLOWED_ORIGINS: "https://web.septena.app",
    SIGNED_SESSIONS: "true",
    SESSION_SIGNING_KEY: Buffer.alloc(32, 7).toString("base64"),
    ADMIN_TOKEN: "test-admin-token-0123456789abcdef",
    STATE: state,
    TOKENS: makeMemoryKv(),
    CLIENTS: clients,
    TASK_STORE: { idFromName: (n: string) => n, get: (id: string) => proxy(() => ensureTaskStore(id)) },
    ACCOUNT_STORE: { idFromName: (n: string) => n, get: () => proxy(async () => accountStore) },
    PAIRING: { idFromName: (n: string) => n, get: (id: string) => proxy(() => ensurePairing(id)) },
    ...vars,
  } as never;
  const app = new Hono();
  app.get("/oauth/authorize", oauth.authorize);
  app.get("/oauth/pair/continue", oauth.pairContinue);
  app.post("/oauth/pair/reviewer", oauth.pairReviewer);
  app.route("/v1", api);
  async function openConnector() {
    await clients.put("v2:client:c1", JSON.stringify({ id: "c1", name: "Claude", redirectUris: ["https://claude.ai/api/mcp/auth_callback"] }));
    const url = new URL("https://api.septena.app/oauth/authorize");
    for (const [k, v] of Object.entries({ response_type: "code", client_id: "c1", redirect_uri: "https://claude.ai/api/mcp/auth_callback", state: "st", code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", code_challenge_method: "S256" })) url.searchParams.set(k, v);
    const res = await app.fetch(new Request(url), env, EXEC_CTX);
    return { html: await res.text(), cookie: (res.headers.get("Set-Cookie") ?? "").split(";")[0] };
  }
  const submit = (cookie: string, code: string, ip = "203.0.113.9", origin = "https://api.septena.app") =>
    app.fetch(new Request("https://api.septena.app/oauth/pair/reviewer", {
      method: "POST",
      headers: { "Content-Type": "application/json", Cookie: cookie, Origin: origin, "CF-Connecting-IP": ip },
      body: JSON.stringify({ code }),
    }), env, EXEC_CTX);
  const page = (path: string, init: RequestInit = {}) => app.fetch(new Request(`https://api.septena.app${path}`, init), env, EXEC_CTX);
  const storedCodes = () => [...state.map.entries()].filter(([k]) => k.startsWith("v2:code:")).map(([, v]) => JSON.parse(v) as { userId: string });
  return { env, openConnector, submit, page, storedCodes };
}

describe("directory reviewer access", () => {
  it("hides the form and refuses the route when reviewer mode is off", async () => {
    for (const vars of [
      {},
      { REVIEWER_CODE: CODE },
      { REVIEWER_ACCOUNT_ID: DEMO },
      { REVIEWER_CODE: CODE, REVIEWER_ACCOUNT_ID: "not-a-user-id" },
      { REVIEWER_CODE: "short", REVIEWER_ACCOUNT_ID: DEMO },
    ]) {
      const h = await makeHarness(vars);
      const { html, cookie } = await h.openConnector();
      assert.doesNotMatch(html, /id="reviewer-form"/);
      assert.equal((await h.submit(cookie, CODE)).status, 404);
    }
  });

  it("shows the form when reviewer mode is on", async () => {
    const h = await makeHarness();
    const { html } = await h.openConnector();
    assert.match(html, /id="reviewer-form"/);
    assert.doesNotMatch(html, new RegExp(CODE));
  });

  it("refuses a wrong code and pairs nothing", async () => {
    const h = await makeHarness();
    const { cookie } = await h.openConnector();
    assert.equal((await h.submit(cookie, "wrong-code-123456")).status, 401);
    const still = await h.page("/oauth/pair/continue", { headers: { Cookie: cookie } });
    assert.equal(still.status, 200);
    assert.equal(h.storedCodes().length, 0);
  });

  it("refuses another origin", async () => {
    const h = await makeHarness();
    const { cookie } = await h.openConnector();
    assert.equal((await h.submit(cookie, CODE, "203.0.113.9", "https://evil.example")).status, 403);
  });

  it("limits wrong codes per IP", async () => {
    const h = await makeHarness();
    const { cookie } = await h.openConnector();
    for (let i = 0; i < REVIEWER_MAX_FAILURES; i++) assert.equal((await h.submit(cookie, `wrong-${i}-xxxxxxxx`)).status, 401);
    assert.equal((await h.submit(cookie, CODE)).status, 429);
    assert.equal((await h.submit(cookie, CODE, "198.51.100.4")).status, 200);
  });

  it("pairs the right code with the demo account and nothing else", async () => {
    const h = await makeHarness();
    const { cookie } = await h.openConnector();
    assert.equal((await h.submit(cookie, `  ${CODE} `)).status, 200);
    const done = await h.page("/oauth/pair/continue", { headers: { Cookie: cookie } });
    assert.equal(done.status, 302);
    assert.match(done.headers.get("Location") ?? "", /^https:\/\/claude\.ai\/api\/mcp\/auth_callback\?code=/);
    assert.deepEqual(h.storedCodes().map((c) => c.userId), [DEMO]);
  });

  it("ends at REVIEWER_MODE_UNTIL", async () => {
    const vars = { REVIEWER_CODE: CODE, REVIEWER_ACCOUNT_ID: DEMO };
    const day = Date.parse("2026-12-01T12:00:00Z");
    assert.ok(reviewerMode({ ...vars, REVIEWER_MODE_UNTIL: "2026-12-01" } as never, day));
    assert.equal(reviewerMode({ ...vars, REVIEWER_MODE_UNTIL: "2026-11-30" } as never, day), null);
    assert.equal(reviewerMode({ ...vars, REVIEWER_MODE_UNTIL: "not a date" } as never, day), null);
    const h = await makeHarness({ ...vars, REVIEWER_MODE_UNTIL: "2020-01-01" });
    const { html, cookie } = await h.openConnector();
    assert.doesNotMatch(html, /id="reviewer-form"/);
    assert.equal((await h.submit(cookie, CODE)).status, 404);
  });

  it("lets an admin approve a web device sign-in code for the demo account only", async () => {
    const h = await makeHarness();
    const startRes = await h.page("/v1/auth/device/start", {
      method: "POST",
      headers: { "Content-Type": "application/json", Origin: "https://web.septena.app" },
      body: JSON.stringify({ clientName: "Septena Web" }),
    });
    assert.equal(startRes.status, 200);
    const started = await startRes.json() as { code: string; pollSecret: string };

    // Wrong admin token is refused.
    const badAuth = await h.page("/v1/admin/reviewer/approve-device", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Admin-Token": "wrong" },
      body: JSON.stringify({ code: started.code }),
    });
    assert.equal(badAuth.status, 403);

    // Connector codes are never approved by the device endpoint.
    const { cookie } = await h.openConnector();
    const connectorCode = cookie.split("=")[1].split(".")[0];
    const wrongKind = await h.page("/v1/admin/reviewer/approve-device", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Admin-Token": "test-admin-token-0123456789abcdef" },
      body: JSON.stringify({ code: connectorCode }),
    });
    assert.equal(wrongKind.status, 404);

    // Approving the device code completes web sign-in into the demo account.
    const approveRes = await h.page("/v1/admin/reviewer/approve-device", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Admin-Token": "test-admin-token-0123456789abcdef" },
      body: JSON.stringify({ code: started.code }),
    });
    assert.equal(approveRes.status, 200);
    assert.deepEqual(await approveRes.json(), { ok: true, client: "Septena Web", kind: "device" });

    const pollRes = await h.page("/v1/auth/device/poll", {
      method: "POST",
      headers: { "Content-Type": "application/json", Origin: "https://web.septena.app" },
      body: JSON.stringify({ code: started.code, pollSecret: started.pollSecret, sessionMode: "cookie" }),
    });
    assert.equal(pollRes.status, 200);
    assert.match(pollRes.headers.get("Set-Cookie") ?? "", /HttpOnly/);
    const session = await pollRes.json() as { userId: string; accessToken: string };
    assert.equal(session.userId, DEMO);
    assert.ok(session.accessToken.startsWith("sa1."));

    // Returns 404 when reviewer mode is off.
    const off = await makeHarness({});
    const offRes = await off.page("/v1/admin/reviewer/approve-device", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Admin-Token": "test-admin-token-0123456789abcdef" },
      body: JSON.stringify({ code: started.code }),
    });
    assert.equal(offRes.status, 404);
  });
});
