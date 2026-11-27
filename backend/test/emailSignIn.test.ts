import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Hono } from "hono";
import { createTestAccountStore, createTestPairingStore, createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Sign-in S2: email one-time code (ADR 0016, ADR 0047, issue #169).

const { api } = await import("../src/api/routes.ts");
const { verifyAccessToken } = await import("../src/api/session.ts");
const { EMAIL_CODE_MAX_ATTEMPTS, EMAIL_CODE_MAX_SENDS, EMAIL_CODE_TTL_MS } = await import("../src/store/AccountStore.ts");
const { newEmailCode } = await import("../src/api/emailSignIn.ts");
const oauth = await import("../src/shadow/oauth.ts");
const { verifyMcpAccess } = await import("../src/shadow/tokens.ts");

const TEST_SIGNING_KEY = Buffer.alloc(32, 5).toString("base64");
const EXEC_CTX = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

function makeMemoryKv() {
  const map = new Map<string, string>();
  return {
    map,
    async get(key: string) { return map.get(key) ?? null; },
    async put(key: string, value: string) { map.set(key, value); },
    async delete(key: string) { map.delete(key); },
  };
}

async function makeHarness(opts: { enabled?: boolean; failSend?: boolean } = {}) {
  const taskStores = new Map<string, Awaited<ReturnType<typeof createTestTaskStore>>["store"]>();
  const ensureTaskStore = async (userId: string) => {
    let s = taskStores.get(userId);
    if (!s) {
      s = (await createTestTaskStore()).store;
      taskStores.set(userId, s);
    }
    return s;
  };
  const { store: accountStore } = await createTestAccountStore();
  const pairingStores = new Map<string, Awaited<ReturnType<typeof createTestPairingStore>>>();
  const ensurePairing = async (id: string) => {
    let p = pairingStores.get(id);
    if (!p) { p = await createTestPairingStore(); pairingStores.set(id, p); }
    return p.store;
  };
  const sent: { to: string; subject: string; text: string }[] = [];
  const proxy = (target: () => Promise<unknown>) => new Proxy({}, {
    get(_t, prop: string) {
      return async (...args: unknown[]) =>
        ((await target()) as Record<string, (...a: unknown[]) => unknown>)[prop](...args);
    },
  });
  const env = {
    API_PUBLIC_URL: "https://api.septena.app",
    APPLE_AUDIENCES: "com.septena.tasks",
    ENTITLEMENT_ENFORCE: "false",
    APPLE_IAP_BUNDLE_IDS: "com.septena.tasks",
    APPLE_IAP_ENVIRONMENTS: "Production,Sandbox",
    WEB_ALLOWED_ORIGINS: "https://web.septena.app",
    SESSION_SIGNING_KEY: TEST_SIGNING_KEY,
    SIGNED_SESSIONS: "true",
    EMAIL_SIGNIN: opts.enabled === false ? "false" : "true",
    EMAIL: {
      async send(m: { to: string; subject: string; text: string }) {
        if (opts.failSend) throw new Error("boom");
        sent.push(m);
        return { messageId: "m1" };
      },
    },
    TOKENS: makeMemoryKv(),
    STATE: makeMemoryKv(),
    CLIENTS: makeMemoryKv(),
    TASK_STORE: { idFromName: (n: string) => n, get: (id: string) => proxy(() => ensureTaskStore(id)) },
    ACCOUNT_STORE: { idFromName: (n: string) => n, get: () => proxy(async () => accountStore) },
    PAIRING: { idFromName: (n: string) => n, get: (id: string) => proxy(() => ensurePairing(id)) },
  } as never;

  const call = (path: string, body: unknown, headers: Record<string, string> = {}) =>
    api.fetch(new Request(`https://api.septena.app${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "203.0.113.9", ...headers },
      body: JSON.stringify(body),
    }), env, EXEC_CTX);
  const lastCode = () => /(\d{6})/.exec(sent.at(-1)!.text)![1];
  const app = new Hono();
  app.get("/oauth/authorize", oauth.authorize);
  app.get("/oauth/pair/continue", oauth.pairContinue);
  app.post("/oauth/pair/email", oauth.pairEmail);
  app.post("/oauth/token", oauth.token);
  app.route("/v1", api);
  const clients = (env as unknown as { CLIENTS: ReturnType<typeof makeMemoryKv> }).CLIENTS;
  // Standard RFC 7636 S256 verifier/challenge pair for token exchange tests.
  const pkceVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
  const pkceChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
  async function openConnector() {
    await clients.put("v2:client:c1", JSON.stringify({ id: "c1", name: "Claude", redirectUris: ["https://claude.ai/api/mcp/auth_callback"] }));
    const url = new URL("https://api.septena.app/oauth/authorize");
    for (const [k, v] of Object.entries({ response_type: "code", client_id: "c1", redirect_uri: "https://claude.ai/api/mcp/auth_callback", state: "st", code_challenge: pkceChallenge, code_challenge_method: "S256" })) url.searchParams.set(k, v);
    const res = await app.fetch(new Request(url), env, EXEC_CTX);
    return { html: await res.text(), cookie: (res.headers.get("Set-Cookie") ?? "").split(";")[0] };
  }
  const page = (path: string, init: RequestInit = {}) => app.fetch(new Request(`https://api.septena.app${path}`, init), env, EXEC_CTX);
  return { env, sent, call, lastCode, accountStore, ensureTaskStore, openConnector, page, pkceVerifier };
}

describe("email sign-in", () => {
  it("lists email only when the switch is on", async () => {
    for (const enabled of [true, false]) {
      const h = await makeHarness({ enabled });
      const res = await api.fetch(new Request("https://api.septena.app/auth/methods"), h.env, EXEC_CTX);
      const ids = ((await res.json()) as { methods: { id: string }[] }).methods.map((m) => m.id);
      assert.equal(ids.includes("email"), enabled);
      assert.ok(ids.includes("device"));
    }
  });

  it("refuses with 503 while switched off", async () => {
    const h = await makeHarness({ enabled: false });
    const res = await h.call("/auth/email/start", { email: "a@example.com" });
    assert.equal(res.status, 503);
    assert.equal(h.sent.length, 0);
  });

  it("creates an account on first use and signs in to the same one later", async () => {
    const h = await makeHarness();
    assert.equal((await h.call("/auth/email/start", { email: "New@Example.com " })).status, 202);
    assert.equal(h.sent[0].to, "new@example.com");
    const first = await h.call("/auth/email/verify", { email: "new@example.com", code: h.lastCode() });
    assert.equal(first.status, 200);
    const s1 = (await first.json()) as { accessToken: string; refreshToken: string };
    const c1 = await verifyAccessToken(h.env, s1.accessToken);
    assert.ok(c1?.userId);

    await h.call("/auth/email/start", { email: "new@example.com" });
    const second = await h.call("/auth/email/verify", { email: "NEW@example.com", code: h.lastCode() });
    const c2 = await verifyAccessToken(h.env, ((await second.json()) as { accessToken: string }).accessToken);
    assert.equal(c2?.userId, c1!.userId);
  });

  it("spends a code once", async () => {
    const h = await makeHarness();
    await h.call("/auth/email/start", { email: "a@example.com" });
    const code = h.lastCode();
    assert.equal((await h.call("/auth/email/verify", { email: "a@example.com", code })).status, 200);
    assert.equal((await h.call("/auth/email/verify", { email: "a@example.com", code })).status, 410);
  });

  it("locks the address after five wrong codes, and a new code does not unlock it", async () => {
    const h = await makeHarness();
    await h.call("/auth/email/start", { email: "a@example.com" });
    const right = h.lastCode();
    const wrong = right === "000000" ? "111111" : "000000";
    for (let i = 1; i < EMAIL_CODE_MAX_ATTEMPTS; i++) {
      const res = await h.call("/auth/email/verify", { email: "a@example.com", code: wrong });
      assert.equal(res.status, 401);
      assert.equal(((await res.json()) as { attemptsLeft: number }).attemptsLeft, EMAIL_CODE_MAX_ATTEMPTS - i);
    }
    assert.equal((await h.call("/auth/email/verify", { email: "a@example.com", code: wrong })).status, 429);
    assert.equal((await h.call("/auth/email/verify", { email: "a@example.com", code: right })).status, 429);
    assert.equal((await h.call("/auth/email/start", { email: "a@example.com" })).status, 429);
  });

  it("expires a code after ten minutes", async () => {
    const h = await makeHarness();
    const now = Date.now();
    h.accountStore.issueEmailCode("a@example.com", "hash", now - EMAIL_CODE_TTL_MS - 1);
    assert.deepEqual(h.accountStore.checkEmailCode("a@example.com", "hash", now), { status: "expired" });
  });

  it("limits codes per address", async () => {
    const h = await makeHarness();
    for (let i = 0; i < EMAIL_CODE_MAX_SENDS; i++) {
      assert.equal((await h.call("/auth/email/start", { email: "a@example.com" })).status, 202);
    }
    const res = await h.call("/auth/email/start", { email: "a@example.com" });
    assert.equal(res.status, 429);
    assert.ok(res.headers.get("Retry-After"));
  });

  it("answers start the same for a known and an unknown address", async () => {
    const h = await makeHarness();
    await h.call("/auth/email/start", { email: "known@example.com" });
    await h.call("/auth/email/verify", { email: "known@example.com", code: h.lastCode() });
    const known = await h.call("/auth/email/start", { email: "known@example.com" });
    const unknown = await h.call("/auth/email/start", { email: "unknown@example.com" });
    assert.equal(known.status, unknown.status);
    assert.deepEqual(Object.keys(await known.json()).sort(), Object.keys(await unknown.json()).sort());
  });

  it("sets the refresh cookie for the web app and refuses cookie mode from other origins", async () => {
    const h = await makeHarness();
    await h.call("/auth/email/start", { email: "w@example.com" });
    const code = h.lastCode();
    const bad = await h.call("/auth/email/verify", { email: "w@example.com", code, sessionMode: "cookie" }, { Origin: "https://evil.example" });
    assert.equal(bad.status, 403);
    const ok = await h.call("/auth/email/verify", { email: "w@example.com", code, sessionMode: "cookie" }, { Origin: "https://web.septena.app" });
    assert.equal(ok.status, 200);
    assert.match(ok.headers.get("Set-Cookie") ?? "", /septena_refresh=/);
    assert.equal(((await ok.json()) as { refreshToken?: string }).refreshToken, undefined);
  });

  it("rejects a malformed address or code", async () => {
    const h = await makeHarness();
    assert.equal((await h.call("/auth/email/start", { email: "not-an-email" })).status, 400);
    assert.equal((await h.call("/auth/email/verify", { email: "a@example.com", code: "12345" })).status, 400);
  });

  it("reports a failed send", async () => {
    const h = await makeHarness({ failSend: true });
    assert.equal((await h.call("/auth/email/start", { email: "a@example.com" })).status, 503);
  });

  it("connects a connector by email from the authorize page through token exchange without an app session", async () => {
    const h = await makeHarness();
    const { html, cookie } = await h.openConnector();
    assert.match(html, /id="email-start"/);
    await h.page("/v1/auth/email/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email: "agent@example.com" }) });
    const body = JSON.stringify({ email: "agent@example.com", code: h.lastCode(), timeZone: "Europe/Amsterdam" });
    const headers = { "Content-Type": "application/json", Cookie: cookie, Origin: "https://api.septena.app" };
    const foreign = await h.page("/oauth/pair/email", { method: "POST", headers: { ...headers, Origin: "https://evil.example" }, body });
    assert.equal(foreign.status, 403);
    const ok = await h.page("/oauth/pair/email", { method: "POST", headers, body });
    assert.equal(ok.status, 200);
    const done = await h.page("/oauth/pair/continue", { headers: { Cookie: cookie } });
    assert.equal(done.status, 302);
    const loc = new URL(done.headers.get("Location") ?? "");
    assert.equal(`${loc.origin}${loc.pathname}`, "https://claude.ai/api/mcp/auth_callback");
    const authCode = loc.searchParams.get("code");
    assert.ok(authCode);

    // Exchange auth code for MCP tokens on the brand-new agent-first account (no app session yet).
    const form = new URLSearchParams({
      grant_type: "authorization_code",
      code: authCode,
      code_verifier: h.pkceVerifier,
      redirect_uri: "https://claude.ai/api/mcp/auth_callback",
      client_id: "c1",
    });
    const tokRes = await h.page("/oauth/token", { method: "POST", body: form });
    assert.equal(tokRes.status, 200);
    const tokens = await tokRes.json() as { access_token: string; refresh_token: string; scope: string };
    assert.match(tokens.access_token, /^sm2\./);
    assert.match(tokens.refresh_token, /^smr2\./);
    const grant = await verifyMcpAccess(h.env, tokens.access_token);
    assert.ok(grant);
    assert.equal(grant.timeZone, "Europe/Amsterdam");
    const store = await h.ensureTaskStore(grant.userId);
    assert.equal(store.hasAppSession(), false);
    const summary = store.accountSummary();
    assert.ok(summary, "agent-first account appears in admin summary");
    assert.equal(summary.agents.length, 1);
  });

  it("refuses token exchange if an email-approved account was deleted before exchange", async () => {
    const h = await makeHarness();
    const { cookie } = await h.openConnector();
    await h.page("/v1/auth/email/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email: "gone@example.com" }) });
    await h.page("/oauth/pair/email", {
      method: "POST",
      headers: { "Content-Type": "application/json", Cookie: cookie, Origin: "https://api.septena.app" },
      body: JSON.stringify({ email: "gone@example.com", code: h.lastCode() }),
    });
    const done = await h.page("/oauth/pair/continue", { headers: { Cookie: cookie } });
    const authCode = new URL(done.headers.get("Location") ?? "").searchParams.get("code")!;
    const identity = await h.accountStore.resolveIdentity("email", "gone@example.com");
    assert.ok(identity);
    h.accountStore.deleteIdentitiesForUser(identity.userId);
    await (await h.ensureTaskStore(identity.userId)).deleteAccount();

    const form = new URLSearchParams({
      grant_type: "authorization_code",
      code: authCode,
      code_verifier: h.pkceVerifier,
      redirect_uri: "https://claude.ai/api/mcp/auth_callback",
      client_id: "c1",
    });
    const tokRes = await h.page("/oauth/token", { method: "POST", body: form });
    assert.equal(tokRes.status, 400);
    assert.deepEqual(await tokRes.json(), { error: "invalid_grant" });
  });

  it("hides the email form on the connector page while switched off", async () => {
    const h = await makeHarness({ enabled: false });
    const { html } = await h.openConnector();
    assert.doesNotMatch(html, /id="email-start"/);
  });

  it("makes six-digit codes", () => {
    for (let i = 0; i < 200; i++) assert.match(newEmailCode(), /^\d{6}$/);
  });
});
