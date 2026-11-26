import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestAccountStore, createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Sign-in S2: email one-time code (ADR 0016, ADR 0047, issue #169).

const { api } = await import("../src/api/routes.ts");
const { verifyAccessToken } = await import("../src/api/session.ts");
const { EMAIL_CODE_MAX_ATTEMPTS, EMAIL_CODE_MAX_SENDS, EMAIL_CODE_TTL_MS } = await import("../src/store/AccountStore.ts");
const { newEmailCode } = await import("../src/api/emailSignIn.ts");

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
  } as never;

  const call = (path: string, body: unknown, headers: Record<string, string> = {}) =>
    api.fetch(new Request(`https://api.septena.app${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "203.0.113.9", ...headers },
      body: JSON.stringify(body),
    }), env, EXEC_CTX);
  const lastCode = () => /(\d{6})/.exec(sent.at(-1)!.text)![1];
  return { env, sent, call, lastCode, accountStore };
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

  it("makes six-digit codes", () => {
    for (let i = 0; i < 200; i++) assert.match(newEmailCode(), /^\d{6}$/);
  });
});
