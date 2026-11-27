import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Hono } from "hono";
import { createTestAccountStore, createTestPairingStore, createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// ADR 0056: headless agent account creation & connection with human email confirmation.

const { api } = await import("../src/api/routes.ts");
const agentSignup = await import("../src/shadow/agentSignup.ts");
const { previewMcpHandler } = await import("../src/shadow/mcp.ts");
const { verifyMcpAccess } = await import("../src/shadow/tokens.ts");
const { authenticate, verifyAccessToken } = await import("../src/api/session.ts");
const { EMAIL_CODE_MAX_ATTEMPTS, EMAIL_CODE_MAX_SENDS } = await import("../src/store/AccountStore.ts");

const TEST_SIGNING_KEY = Buffer.alloc(32, 9).toString("base64");
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
  const sent: { to: string; subject: string; text: string; html: string }[] = [];
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
      async send(m: { to: string; subject: string; text: string; html: string }) {
        if (opts.failSend) throw new Error("send boom");
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

  const app = new Hono();
  app.get("/agent/confirm/:token", agentSignup.confirmPage);
  app.post("/agent/confirm/:token", agentSignup.confirmSubmit);
  app.post("/mcp", previewMcpHandler);
  app.route("/v1", api);

  const req = (path: string, init: RequestInit = {}) =>
    app.fetch(new Request(`https://api.septena.app${path}`, init), env, EXEC_CTX);

  const jsonPost = (path: string, body: unknown, headers: Record<string, string> = {}) =>
    req(path, {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "198.51.100.4", ...headers },
      body: JSON.stringify(body),
    });

  const confirmUrlFromLastEmail = () => {
    const m = /https:\/\/api\.septena\.app(\/agent\/confirm\/[A-Za-z0-9_.-]+)/.exec(sent.at(-1)!.text);
    assert.ok(m, "confirmation link in email");
    return m[1];
  };

  const submitConfirm = (path: string, decision: "approve" | "decline", headers: Record<string, string> = {}) =>
    req(path, {
      method: "POST",
      headers: { Origin: "https://api.septena.app", "Sec-Fetch-Site": "same-origin", ...headers },
      body: new URLSearchParams({ decision }),
    });

  const mcpCall = (token: string, name: string, args: Record<string, unknown> = {}) =>
    req("/mcp", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }),
    });

  return { env, sent, accountStore, ensureTaskStore, req, jsonPost, confirmUrlFromLastEmail, submitConfirm, mcpCall };
}

describe("headless agent signup (ADR 0056)", () => {
  it("creates a new account after human confirmation, issues an sk1 key, works over MCP, and lets the user sign in later", async () => {
    const h = await makeHarness();
    const startRes = await h.jsonPost("/v1/agent/signup/start", {
      email: "Alex@Example.com ",
      agentName: "Claude Code",
      timeZone: "Europe/Berlin",
    });
    assert.equal(startRes.status, 202);
    assert.equal(startRes.headers.get("Cache-Control"), "no-store");
    const started = await startRes.json() as {
      status: string; requestId: string; pollSecret: string; expiresInSeconds: number; intervalSeconds: number;
    };
    assert.equal(started.status, "pending");
    assert.match(started.requestId, /^as_/);
    assert.equal(started.expiresInSeconds, 600);
    assert.equal(started.intervalSeconds, 3);
    assert.equal(h.sent.length, 1);
    assert.equal(h.sent[0].to, "alex@example.com");
    assert.match(h.sent[0].subject, /Confirm your Septena account for Claude Code/);

    // Polling before confirmation stays pending.
    const pendingRes = await h.jsonPost("/v1/agent/signup/poll", {
      requestId: started.requestId, pollSecret: started.pollSecret,
    });
    assert.equal(pendingRes.status, 202);
    assert.deepEqual(await pendingRes.json(), { status: "pending" });

    // GET confirmation page renders new-account copy and does NOT approve (safe for mail scanners).
    const confirmPath = h.confirmUrlFromLastEmail();
    const getRes = await h.req(confirmPath);
    assert.equal(getRes.status, 200);
    assert.equal(getRes.headers.get("Cache-Control"), "no-store");
    assert.equal(getRes.headers.get("Referrer-Policy"), "no-referrer");
    const html = await getRes.text();
    assert.match(html, /Create your Septena account/);
    assert.match(html, /Claude Code/);
    assert.match(html, /alex@example\.com/);
    assert.match(html, /Terms of Use/);
    assert.match(html, /Privacy Policy/);

    // Still pending after GET.
    assert.equal((await h.jsonPost("/v1/agent/signup/poll", {
      requestId: started.requestId, pollSecret: started.pollSecret,
    })).status, 202);

    // Human clicks Approve.
    const postRes = await h.submitConfirm(confirmPath, "approve");
    assert.equal(postRes.status, 200);
    assert.match(await postRes.text(), /Your Septena account is ready/);

    // Poll returns the scoped sk1 key in one shot.
    const okRes = await h.jsonPost("/v1/agent/signup/poll", {
      requestId: started.requestId, pollSecret: started.pollSecret,
    });
    assert.equal(okRes.status, 200);
    assert.equal(okRes.headers.get("Cache-Control"), "no-store");
    const claimed = await okRes.json() as {
      status: string; created: boolean; userId: string; agentId: string; agentName: string;
      access: string; scope: string; key: string; mcpUrl: string; onboardUrl: string; skillUrl: string;
    };
    assert.equal(claimed.status, "approved");
    assert.equal(claimed.created, true);
    assert.equal(claimed.agentName, "Claude Code");
    assert.equal(claimed.access, "write");
    assert.equal(claimed.scope, "tasks:read tasks:write");
    assert.match(claimed.key, /^sk1\./);
    assert.equal(claimed.mcpUrl, "https://api.septena.app/mcp");
    assert.equal(claimed.onboardUrl, "https://api.septena.app/onboard.md");
    assert.equal(claimed.skillUrl, "https://api.septena.app/skill.md");

    // Second poll is gone (one-shot).
    const replay = await h.jsonPost("/v1/agent/signup/poll", {
      requestId: started.requestId, pollSecret: started.pollSecret,
    });
    assert.equal(replay.status, 410);
    assert.deepEqual(await replay.json(), { error: "expired_or_unknown" });

    // Key is an agent key (never an app session) and preserves timeZone.
    assert.equal(await authenticate(h.env, claimed.key), null);
    const mintAttempt = await h.jsonPost("/v1/access/keys", { name: "escalate" }, {
      Authorization: `Bearer ${claimed.key}`,
    });
    assert.equal(mintAttempt.status, 401);
    const grant = await verifyMcpAccess(h.env, claimed.key);
    assert.equal(grant?.userId, claimed.userId);
    assert.equal(grant?.timeZone, "Europe/Berlin");

    // Trial started and admin summary sees the agent-first account.
    const store = await h.ensureTaskStore(claimed.userId);
    assert.equal(store.hasAppSession(), false);
    assert.equal(store.entitlements().some((e) => e.source === "trial"), true);
    const summary = store.accountSummary();
    assert.ok(summary);
    assert.equal(summary.agents.length, 1);

    // Agent immediately creates a task over MCP.
    const createRes = await h.mcpCall(claimed.key, "tasks_create", { title: "Draft Q4 roadmap", origin: "user_request" });
    assert.equal(createRes.status, 200);
    const createdRpc = await createRes.json() as { result: { isError?: boolean; content: { text: string }[] } };
    assert.notEqual(createdRpc.result.isError, true);

    // Later, the human signs in with the same email and lands on the exact same account & tasks.
    await h.jsonPost("/v1/auth/email/start", { email: "alex@example.com" });
    const loginCode = /(\d{6})/.exec(h.sent.at(-1)!.text)![1];
    const verifyRes = await h.jsonPost("/v1/auth/email/verify", { email: "alex@example.com", code: loginCode });
    assert.equal(verifyRes.status, 200);
    const session = await verifyRes.json() as { accessToken: string };
    const claims = await verifyAccessToken(h.env, session.accessToken);
    assert.equal(claims?.userId, claimed.userId);
    assert.equal(store.readTasks("open", 100).rows.some((r) => r.title === "Draft Q4 roadmap"), true);
  });

  it("connects to an existing account without leaking existence on start", async () => {
    const h = await makeHarness();
    // Create the account first via regular email sign-in.
    await h.jsonPost("/v1/auth/email/start", { email: "existing@example.com" });
    const code = /(\d{6})/.exec(h.sent.at(-1)!.text)![1];
    const v = await (await h.jsonPost("/v1/auth/email/verify", { email: "existing@example.com", code })).json() as { userId: string };

    const unknownStart = await h.jsonPost("/v1/agent/signup/start", { email: "brandnew@example.com", agentName: "OpenClaw" });
    const existingStart = await h.jsonPost("/v1/agent/signup/start", { email: "existing@example.com", agentName: "OpenClaw" });
    assert.equal(unknownStart.status, 202);
    assert.equal(existingStart.status, 202);
    const uBody = await unknownStart.json() as Record<string, unknown>;
    const eBody = await existingStart.json() as { requestId: string; pollSecret: string };
    assert.deepEqual(Object.keys(uBody).sort(), Object.keys(eBody).sort());

    // Email and confirmation page tell the mailbox owner this connects to their existing account.
    assert.match(h.sent.at(-1)!.subject, /Connect OpenClaw to your Septena account/);
    const confirmPath = h.confirmUrlFromLastEmail();
    const html = await (await h.req(confirmPath)).text();
    assert.match(html, /existing Septena account/);
    assert.match(html, /Approve connection/);

    await h.submitConfirm(confirmPath, "approve");
    const poll = await (await h.jsonPost("/v1/agent/signup/poll", {
      requestId: eBody.requestId, pollSecret: eBody.pollSecret,
    })).json() as { created: boolean; userId: string; key: string };
    assert.equal(poll.created, false);
    assert.equal(poll.userId, v.userId);
    assert.match(poll.key, /^sk1\./);
  });

  it("supports read-only keys", async () => {
    const h = await makeHarness();
    const started = await (await h.jsonPost("/v1/agent/signup/start", {
      email: "reader@example.com", agentName: "Briefing bot", access: "read",
    })).json() as { requestId: string; pollSecret: string };
    const confirmPath = h.confirmUrlFromLastEmail();
    const html = await (await h.req(confirmPath)).text();
    assert.match(html, /read your tasks/);
    assert.doesNotMatch(html, /read and change/);
    await h.submitConfirm(confirmPath, "approve");
    const claimed = await (await h.jsonPost("/v1/agent/signup/poll", {
      requestId: started.requestId, pollSecret: started.pollSecret,
    })).json() as { access: string; scope: string; key: string };
    assert.equal(claimed.access, "read");
    assert.equal(claimed.scope, "tasks:read");
    const writeRes = await (await h.mcpCall(claimed.key, "tasks_create", { title: "Should fail" })).json() as {
      result: { isError?: boolean; structuredContent?: { error: { code: string } } };
    };
    assert.equal(writeRes.result.isError, true);
    assert.equal(writeRes.result.structuredContent?.error.code, "read_only");
  });

  it("handles human decline without creating an account", async () => {
    const h = await makeHarness();
    const started = await (await h.jsonPost("/v1/agent/signup/start", {
      email: "nope@example.com", agentName: "Random Agent",
    })).json() as { requestId: string; pollSecret: string };
    const confirmPath = h.confirmUrlFromLastEmail();
    const postRes = await h.submitConfirm(confirmPath, "decline");
    assert.equal(postRes.status, 200);
    assert.match(await postRes.text(), /Request declined/);
    assert.equal(await h.accountStore.resolveIdentity("email", "nope@example.com"), null);

    const poll1 = await h.jsonPost("/v1/agent/signup/poll", {
      requestId: started.requestId, pollSecret: started.pollSecret,
    });
    assert.equal(poll1.status, 410);
    assert.deepEqual(await poll1.json(), { error: "denied" });

    // Second poll after denial was consumed is expired_or_unknown.
    const poll2 = await h.jsonPost("/v1/agent/signup/poll", {
      requestId: started.requestId, pollSecret: started.pollSecret,
    });
    assert.equal(poll2.status, 410);
    assert.deepEqual(await poll2.json(), { error: "expired_or_unknown" });
  });

  it("enforces switch, CSRF, input validation, escaping, and error envelope", async () => {
    const off = await makeHarness({ enabled: false });
    const resOff = await off.jsonPost("/v1/agent/signup/start", { email: "a@example.com", agentName: "Bot" }, {
      "X-Septena-Errors": "envelope",
    });
    assert.equal(resOff.status, 503);
    const envBody = await resOff.json() as { error: { code: string; retryable: boolean; hint: string } };
    assert.equal(envBody.error.code, "email_signin_off");
    assert.equal(envBody.error.retryable, false);
    assert.ok(envBody.error.hint.length > 0);
    assert.equal(off.sent.length, 0);

    const h = await makeHarness();
    assert.equal((await h.jsonPost("/v1/agent/signup/start", { email: "bad", agentName: "Bot" })).status, 400);
    assert.equal((await h.jsonPost("/v1/agent/signup/start", { email: "a@example.com", agentName: "" })).status, 400);
    assert.equal((await h.jsonPost("/v1/agent/signup/start", { email: "a@example.com", agentName: "Bot", timeZone: "Mars/Olympus" })).status, 400);
    assert.equal((await h.jsonPost("/v1/agent/signup/start", { email: "a@example.com", agentName: "Bot", extra: 1 })).status, 400);

    const started = await (await h.jsonPost("/v1/agent/signup/start", {
      email: "xss@example.com", agentName: "<script>alert(1)</script>",
    })).json() as { requestId: string; pollSecret: string };
    const confirmPath = h.confirmUrlFromLastEmail();
    const html = await (await h.req(confirmPath)).text();
    assert.doesNotMatch(html, /<script>/);
    assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);

    // Cross-origin or cross-site POST is refused.
    assert.equal((await h.submitConfirm(confirmPath, "approve", { Origin: "https://evil.example" })).status, 403);
    assert.equal((await h.submitConfirm(confirmPath, "approve", { "Sec-Fetch-Site": "cross-site" })).status, 403);

    // Tampered confirmation secret or wrong pollSecret is rejected.
    assert.equal((await h.req(`${confirmPath.slice(0, -2)}AA`)).status, 410);
    assert.equal((await h.jsonPost("/v1/agent/signup/poll", {
      requestId: started.requestId, pollSecret: "wrong_secret_12345678901234",
    })).status, 410);
  });

  it("rate limits per email, respects email lock, does not break active sign-in codes, and limits failed polls", async () => {
    const h = await makeHarness();
    // Active 6-digit sign-in code stays valid when an agent signup email is sent.
    await h.jsonPost("/v1/auth/email/start", { email: "dual@example.com" });
    const loginCode = /(\d{6})/.exec(h.sent.at(-1)!.text)![1];
    assert.equal((await h.jsonPost("/v1/agent/signup/start", { email: "dual@example.com", agentName: "Bot" })).status, 202);
    assert.equal((await h.jsonPost("/v1/auth/email/verify", { email: "dual@example.com", code: loginCode })).status, 200);

    // Per-email send limit (3 per 10 min).
    for (let i = 0; i < EMAIL_CODE_MAX_SENDS; i++) {
      assert.equal((await h.jsonPost("/v1/agent/signup/start", { email: "burst@example.com", agentName: "Bot" })).status, 202);
    }
    const limited = await h.jsonPost("/v1/agent/signup/start", { email: "burst@example.com", agentName: "Bot" });
    assert.equal(limited.status, 429);
    assert.ok(limited.headers.get("Retry-After"));

    // Locked address after 5 wrong email codes cannot receive agent signup mail either.
    await h.jsonPost("/v1/auth/email/start", { email: "locked@example.com" });
    const right = /(\d{6})/.exec(h.sent.at(-1)!.text)![1];
    const wrong = right === "000000" ? "111111" : "000000";
    for (let i = 0; i < EMAIL_CODE_MAX_ATTEMPTS; i++) {
      await h.jsonPost("/v1/auth/email/verify", { email: "locked@example.com", code: wrong });
    }
    assert.equal((await h.jsonPost("/v1/agent/signup/start", { email: "locked@example.com", agentName: "Bot" })).status, 429);

    // Per-IP failed poll limit.
    const pollIp = { "CF-Connecting-IP": "198.51.100.77" };
    for (let i = 0; i < agentSignup.AGENT_SIGNUP_POLL_MAX_FAILURES_PER_IP; i++) {
      const r = await h.jsonPost("/v1/agent/signup/poll", {
        requestId: "as_unknown_request_00000001", pollSecret: "wrong_secret_12345678901234",
      }, pollIp);
      assert.equal(r.status, 410);
    }
    const pollLimited = await h.jsonPost("/v1/agent/signup/poll", {
      requestId: "as_unknown_request_00000001", pollSecret: "wrong_secret_12345678901234",
    }, pollIp);
    assert.equal(pollLimited.status, 429);
  });

  it("refuses to mint a key if the account was deleted before poll, and reports email send failure", async () => {
    const h = await makeHarness();
    const started = await (await h.jsonPost("/v1/agent/signup/start", {
      email: "del@example.com", agentName: "Bot",
    })).json() as { requestId: string; pollSecret: string };
    await h.submitConfirm(h.confirmUrlFromLastEmail(), "approve");
    const identity = await h.accountStore.resolveIdentity("email", "del@example.com");
    assert.ok(identity);
    h.accountStore.deleteIdentitiesForUser(identity.userId);
    await (await h.ensureTaskStore(identity.userId)).deleteAccount();

    const poll = await h.jsonPost("/v1/agent/signup/poll", {
      requestId: started.requestId, pollSecret: started.pollSecret,
    });
    assert.equal(poll.status, 410);

    const fail = await makeHarness({ failSend: true });
    assert.equal((await fail.jsonPost("/v1/agent/signup/start", { email: "a@example.com", agentName: "Bot" })).status, 503);
  });
});
