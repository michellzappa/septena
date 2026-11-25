import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

const {
  AGENT_QUESTION_CATEGORY,
  APNS_DEFAULT_BUNDLE_ID,
  APNS_PROD_HOST,
  APNS_SANDBOX_HOST,
  buildAgentQuestionPayload,
  clearApnsJwtCache,
  mintApnsJwt,
  parsePkcs8Pem,
  readApnsConfig,
  sendAgentQuestionPushes,
  setApnsFetchForTests,
} = await import("../src/api/apns.ts");

const { fromBase64Url } = await import("../src/util.ts");
const { api } = await import("../src/api/routes.ts");
const { issueSession } = await import("../src/api/session.ts");

const TOKEN_A = "a".repeat(64);
const TOKEN_B = "b".repeat(64);
const TOKEN_C = "c".repeat(64);

let opCounter = 0;
const opId = (prefix = "apns") => `${prefix}_${++opCounter}`;

async function generateTestP256KeyPair(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const b64 = btoa(String.fromCharCode(...pkcs8));
  const lines = b64.match(/.{1,64}/g)?.join("\n") ?? b64;
  const pem = `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----`;
  return { pem, publicKey: pair.publicKey };
}

function makeFakeKV() {
  const map = new Map<string, string>();
  return {
    async get(k: string) { return map.get(k) ?? null; },
    async put(k: string, v: string) { map.set(k, v); },
    async delete(k: string) { map.delete(k); },
  };
}

function makeRouteEnv(store: unknown) {
  const signingKey = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));
  return {
    API_PUBLIC_URL: "https://api.septena.app",
    APPLE_AUDIENCES: "com.septena.tasks",
    ENTITLEMENT_ENFORCE: "false",
    APPLE_IAP_BUNDLE_IDS: "com.septena.tasks",
    APPLE_IAP_ENVIRONMENTS: "Production,Sandbox",
    SESSION_SIGNING_KEY: signingKey,
    STATE: makeFakeKV(),
    TOKENS: makeFakeKV(),
    CLIENTS: makeFakeKV(),
    TASK_STORE: {
      idFromName: (name: string) => name,
      get: () => store,
    },
    ATTACHMENTS: {
      delete: async () => {},
      put: async () => {},
      get: async () => null,
      list: async () => ({ objects: [], truncated: false }),
    },
  };
}

describe("APNs ES256 JWT signing and caching", () => {
  it("signs a verifiable ES256 JWT with Web Crypto and caches it for <50 min", async () => {
    clearApnsJwtCache();
    const { pem, publicKey } = await generateTestP256KeyPair();
    const cfg = {
      keyPem: pem,
      keyId: "KEY1234567",
      teamId: "TEAM123456",
      bundleId: APNS_DEFAULT_BUNDLE_ID,
      sandboxOverride: null,
    };

    const t0 = 1_800_000_000_000;
    const jwt1 = await mintApnsJwt(cfg, t0);
    const parts = jwt1.split(".");
    assert.equal(parts.length, 3);

    const header = JSON.parse(new TextDecoder().decode(fromBase64Url(parts[0])));
    const payload = JSON.parse(new TextDecoder().decode(fromBase64Url(parts[1])));
    assert.deepEqual(header, { alg: "ES256", kid: "KEY1234567" });
    assert.deepEqual(payload, { iss: "TEAM123456", iat: Math.floor(t0 / 1000) });

    // Cryptographically verify the P-256 signature with the generated public key.
    const signingInput = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    const sigBytes = fromBase64Url(parts[2]);
    assert.equal(sigBytes.byteLength, 64, "ES256 raw signature must be 64 bytes (r || s)");
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      sigBytes,
      signingInput,
    );
    assert.equal(valid, true);

    // Within 45 minutes: returns exact cached JWT.
    const jwtCached = await mintApnsJwt(cfg, t0 + 40 * 60 * 1000);
    assert.equal(jwtCached, jwt1);

    // At 46 minutes (<50 min refresh boundary): mints a fresh JWT with new iat.
    const jwtFresh = await mintApnsJwt(cfg, t0 + 46 * 60 * 1000);
    assert.notEqual(jwtFresh, jwt1);
    const freshPayload = JSON.parse(new TextDecoder().decode(fromBase64Url(jwtFresh.split(".")[1])));
    assert.equal(freshPayload.iat, Math.floor((t0 + 46 * 60 * 1000) / 1000));
  });

  it("parses PKCS#8 PEM keys stored with literal \\n escapes", async () => {
    const { pem } = await generateTestP256KeyPair();
    const escaped = pem.replace(/\n/g, "\\n");
    assert.deepEqual(parsePkcs8Pem(escaped), parsePkcs8Pem(pem));
  });
});

describe("APNs payload builder", () => {
  it("caps options at 3 and includes category, mutable-content, and userInfo", () => {
    const payload = buildAgentQuestionPayload({
      taskId: "task-123",
      taskTitle: "Ship F1b push notifications",
      turnSeq: 4,
      step: "decide",
      question: "Which APNs mode should we use?",
      note: "Some background note",
      options: ["Prod", "Sandbox", "Auto", "Fourth", "Fifth"],
    });

    assert.equal(payload.aps.alert.title, "Ship F1b push notifications");
    assert.ok(payload.aps.alert.body.includes("Which APNs mode should we use?"));
    assert.ok(payload.aps.alert.body.includes("1. Prod · 2. Sandbox · 3. Auto"));
    assert.equal(payload.aps.alert.body.includes("Fourth"), false);
    assert.equal(payload.aps.category, AGENT_QUESTION_CATEGORY);
    assert.equal(payload.aps["mutable-content"], 1);
    assert.equal(payload.aps.sound, "default");
    assert.equal(payload.aps["thread-id"], "agent-question:task-123");
    assert.equal(payload.taskId, "task-123");
    assert.equal(payload.turnSeq, 4);
    assert.equal(payload.step, "decide");
    assert.deepEqual(payload.options, ["Prod", "Sandbox", "Auto"]);
  });

  it("falls back cleanly when title or question is blank", () => {
    const payload = buildAgentQuestionPayload({
      taskId: "t-blank",
      taskTitle: "   ",
      turnSeq: 1,
      step: "confirm",
      question: null,
      note: "Confirm the scope before starting",
      options: ["Proceed", "Stop"],
    });
    assert.equal(payload.aps.alert.title, "Septena");
    assert.ok(payload.aps.alert.body.startsWith("Confirm the scope before starting\n1. Proceed · 2. Stop"));
  });
});

describe("APNs push delivery, missing secrets no-op, and 410/BadDeviceToken pruning", () => {
  it("no-ops cleanly when APNS_KEY / APNS_KEY_ID / APNS_TEAM_ID are missing", async () => {
    assert.equal(readApnsConfig({}), null);
    assert.equal(readApnsConfig({ APNS_KEY: "abc", APNS_KEY_ID: "kid" }), null);

    let fetchCalled = false;
    const res = await sendAgentQuestionPushes(
      {},
      {
        taskId: "t-1",
        taskTitle: "Test",
        turnSeq: 1,
        step: "decide",
        question: "Proceed?",
        note: null,
        options: ["Yes", "No"],
      },
      [{ token: TOKEN_A, deviceId: "d1", platform: "ios", sandbox: false, updatedAt: new Date().toISOString() }],
      {
        fetchFn: async () => {
          fetchCalled = true;
          return new Response(null, { status: 200 });
        },
      },
    );

    assert.equal(fetchCalled, false);
    assert.equal(res.skipped, "missing_secrets");
    assert.equal(res.attempted, 0);
    assert.deepEqual(res.pruned, []);
  });

  it("routes prod vs sandbox hosts, sets ios vs watchos topics, and prunes 410 & BadDeviceToken", async () => {
    clearApnsJwtCache();
    const { pem } = await generateTestP256KeyPair();
    const calls: { url: string; headers: Record<string, string>; body: string }[] = [];

    const mockFetch: typeof fetch = async (input, init) => {
      const url = String(input);
      const headers = Object.fromEntries(new Headers(init?.headers).entries());
      calls.push({ url, headers, body: String(init?.body ?? "") });
      if (url.endsWith(TOKEN_A)) return new Response(null, { status: 200 });
      if (url.endsWith(TOKEN_B)) return new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 });
      if (url.endsWith(TOKEN_C)) return new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 });
      return new Response(null, { status: 500 });
    };

    const res = await sendAgentQuestionPushes(
      { APNS_KEY: pem, APNS_KEY_ID: "KID9999999", APNS_TEAM_ID: "TEAM999999" },
      {
        taskId: "t-prune",
        taskTitle: "Deploy release",
        turnSeq: 2,
        step: "decide",
        question: "Ship now?",
        note: null,
        options: ["Ship", "Hold"],
      },
      [
        { token: TOKEN_A, deviceId: "d1", platform: "ios", sandbox: false, updatedAt: "2026-11-24T00:00:00Z" },
        { token: TOKEN_B, deviceId: "d2", platform: "ios", sandbox: true, updatedAt: "2026-11-24T00:00:00Z" },
        { token: TOKEN_C, deviceId: "d3", platform: "watchos", sandbox: false, updatedAt: "2026-11-24T00:00:00Z" },
      ],
      { fetchFn: mockFetch },
    );

    assert.equal(res.attempted, 3);
    assert.equal(res.delivered, 1);
    assert.deepEqual(res.pruned.sort(), [TOKEN_B, TOKEN_C].sort());

    const byUrl = new Map(calls.map((c) => [c.url, c]));
    const callA = byUrl.get(`${APNS_PROD_HOST}/3/device/${TOKEN_A}`);
    const callB = byUrl.get(`${APNS_SANDBOX_HOST}/3/device/${TOKEN_B}`);
    const callC = byUrl.get(`${APNS_PROD_HOST}/3/device/${TOKEN_C}`);
    assert.ok(callA, "prod iOS token should hit production APNs host");
    assert.ok(callB, "sandbox iOS token should hit sandbox APNs host");
    assert.ok(callC, "prod watchOS token should hit production APNs host");

    assert.equal(callA.headers["apns-topic"], "com.septena.tasks");
    assert.equal(callA.headers["apns-push-type"], "alert");
    assert.ok(callA.headers.authorization.startsWith("bearer "));
    assert.equal(callC.headers["apns-topic"], "com.septena.tasks.watchkitapp");
  });
});

describe("TaskStore push tokens & agent turn trigger", () => {
  it("registers, rotates per-device, deletes, and cleans up push tokens on device revoke", async () => {
    const { store } = await createTestTaskStore();

    store.upsertPushToken({ token: TOKEN_A.toUpperCase(), deviceId: "sid-iphone", platform: "ios", sandbox: false });
    assert.equal(store.listPushTokens().length, 1);
    assert.equal(store.listPushTokens()[0].token, TOKEN_A);
    assert.equal(store.listPushTokens()[0].sandbox, false);

    // Token rotation on the same deviceId + platform supersedes the old token.
    store.upsertPushToken({ token: TOKEN_B, deviceId: "sid-iphone", platform: "ios", sandbox: true });
    const afterRotate = store.listPushTokens();
    assert.equal(afterRotate.length, 1);
    assert.equal(afterRotate[0].token, TOKEN_B);
    assert.equal(afterRotate[0].sandbox, true);

    // Second device / watch keeps its own token.
    store.upsertPushToken({ token: TOKEN_C, deviceId: "sid-watch", platform: "watchos", sandbox: false });
    assert.equal(store.listPushTokens().length, 2);

    // Explicit delete removes only the named token.
    assert.equal(store.deletePushToken(TOKEN_C), true);
    assert.equal(store.deletePushToken(TOKEN_C), false);
    assert.deepEqual(store.listPushTokens().map((t) => t.token), [TOKEN_B]);

    // Revoking a device session removes its push tokens.
    store.createSession("h-iphone", Date.now() + 86_400_000, "sid-iphone");
    store.revokeDevice("sid-iphone");
    assert.equal(store.listPushTokens().length, 0);
  });

  it("triggers APNs push on agent provider turn with options, prunes dead tokens, and skips plain notes / user turns", async () => {
    clearApnsJwtCache();
    const { pem } = await generateTestP256KeyPair();
    const sentPayloads: { url: string; body: Record<string, unknown> }[] = [];

    setApnsFetchForTests(async (input, init) => {
      const url = String(input);
      sentPayloads.push({ url, body: JSON.parse(String(init?.body ?? "{}")) });
      if (url.endsWith(TOKEN_B)) {
        return new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 });
      }
      return new Response(null, { status: 200 });
    });

    try {
      const { store, flushWaitUntil } = await createTestTaskStore(undefined, {
        APNS_KEY: pem,
        APNS_KEY_ID: "KID1111111",
        APNS_TEAM_ID: "TEAM111111",
      });

      store.upsertPushToken({ token: TOKEN_A, deviceId: "d1", platform: "ios", sandbox: false });
      store.upsertPushToken({ token: TOKEN_B, deviceId: "d2", platform: "ios", sandbox: false });

      // Create task first.
      store.push(
        [{ clientOpId: opId("create"), op: "upsert", entity: "task", id: "t-q", fields: { title: "Review PR #213", status: "open" } }],
        "app:septask-ios",
      );

      // 1. Agent plain note (provider turn WITHOUT options) -> no push.
      store.push(
        [{
          clientOpId: opId("note"),
          op: "appendTurn",
          taskId: "t-q",
          turn: { role: "provider", step: "ground", note: "Read the repo", ts: "2026-11-24T10:00:00Z" },
        }],
        "mcp:claude",
      );
      await flushWaitUntil();
      assert.equal(sentPayloads.length, 0);

      // 2. User turn -> no push.
      store.push(
        [{
          clientOpId: opId("user"),
          op: "appendTurn",
          taskId: "t-q",
          turn: { role: "user", step: "work", note: "Looks good", ts: "2026-11-24T10:01:00Z" },
        }],
        "app:septask-ios",
      );
      await flushWaitUntil();
      assert.equal(sentPayloads.length, 0);

      // 3. App-authored on-device provider turn -> no push.
      store.push(
        [{
          clientOpId: opId("ondev"),
          op: "appendTurn",
          taskId: "t-q",
          turn: {
            role: "provider",
            step: "confirm",
            question: "Confirm?",
            options: ["Yes", "No"],
            ts: "2026-11-24T10:02:00Z",
          },
        }],
        "app:septask-ios",
      );
      await flushWaitUntil();
      assert.equal(sentPayloads.length, 0);

      // 4. Agent provider turn WITH options -> sends APNs push to both tokens, prunes TOKEN_B (410).
      const questionOpId = opId("ask");
      const out = store.push(
        [{
          clientOpId: questionOpId,
          op: "appendTurn",
          taskId: "t-q",
          turn: {
            role: "provider",
            step: "decide",
            question: "Ready to merge?",
            options: ["Merge now", "Wait for review", "Draft PR", "Extra"],
            ts: "2026-11-24T10:03:00Z",
          },
        }],
        "mcp:claude",
      );
      assert.equal(out.result.results[0].status, "applied");
      await flushWaitUntil();

      assert.equal(sentPayloads.length, 2);
      assert.equal(sentPayloads[0].body.taskId, "t-q");
      assert.equal(sentPayloads[0].body.turnSeq, 4);
      assert.deepEqual(sentPayloads[0].body.options, ["Merge now", "Wait for review", "Draft PR"]);
      assert.deepEqual(store.listPushTokens().map((t) => t.token), [TOKEN_A], "410 token must be pruned");

      // 5. Replaying the same clientOpId must NOT send duplicate notifications.
      store.push(
        [{
          clientOpId: questionOpId,
          op: "appendTurn",
          taskId: "t-q",
          turn: {
            role: "provider",
            step: "decide",
            question: "Ready to merge?",
            options: ["Merge now", "Wait for review"],
            ts: "2026-11-24T10:03:00Z",
          },
        }],
        "mcp:claude",
      );
      await flushWaitUntil();
      assert.equal(sentPayloads.length, 2, "idempotent replay must not resend push");
    } finally {
      setApnsFetchForTests(null);
    }
  });

  it("commits agent question turn cleanly without throwing when APNs secrets are missing", async () => {
    const { store, flushWaitUntil } = await createTestTaskStore(undefined, {});
    store.upsertPushToken({ token: TOKEN_A, deviceId: "d1", platform: "ios", sandbox: false });
    store.push(
      [{ clientOpId: opId("t"), op: "upsert", entity: "task", id: "t-nosecret", fields: { title: "Safe write", status: "open" } }],
      "app:septask-ios",
    );
    const out = store.push(
      [{
        clientOpId: opId("q"),
        op: "appendTurn",
        taskId: "t-nosecret",
        turn: {
          role: "provider",
          step: "decide",
          question: "Continue?",
          options: ["Yes", "No"],
          ts: "2026-11-24T10:10:00Z",
        },
      }],
      "mcp:claude",
    );
    await flushWaitUntil();
    assert.equal(out.result.results[0].status, "applied");
    const read = store.readTask("t-nosecret");
    assert.equal(read?.turns.length, 1);
  });
});

describe("HTTP routes /v1/devices/push-token and /v1/tasks/:id/answer", () => {
  it("authenticates, validates, registers, and deletes push tokens over HTTP", async () => {
    const { store } = await createTestTaskStore();
    const env = makeRouteEnv(store);
    const session = await issueSession(env as never, "u_apns_route_test_1234567890");
    const auth = { Authorization: `Bearer ${session.accessToken}`, "Content-Type": "application/json" };

    // Unauthenticated -> 401.
    const unauth = await api.request(
      "https://api.septena.app/devices/push-token",
      { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ token: TOKEN_A }) },
      env as never,
    );
    assert.equal(unauth.status, 401);

    // Invalid token -> 400.
    const invalid = await api.request(
      "https://api.septena.app/devices/push-token",
      { method: "POST", headers: auth, body: JSON.stringify({ token: "not-hex!" }) },
      env as never,
    );
    assert.equal(invalid.status, 400);

    // Valid register -> 200 and stored in DO.
    const reg = await api.request(
      "https://api.septena.app/devices/push-token",
      { method: "POST", headers: auth, body: JSON.stringify({ token: TOKEN_A.toUpperCase(), platform: "ios", sandbox: true }) },
      env as never,
    );
    assert.equal(reg.status, 200);
    assert.deepEqual(await reg.json(), { ok: true, platform: "ios", sandbox: true });
    assert.equal(store.listPushTokens().length, 1);
    assert.equal(store.listPushTokens()[0].token, TOKEN_A);
    assert.equal(store.listPushTokens()[0].sandbox, true);

    // Delete -> 204 and removed from DO.
    const del = await api.request(
      "https://api.septena.app/devices/push-token",
      { method: "DELETE", headers: auth, body: JSON.stringify({ token: TOKEN_A }) },
      env as never,
    );
    assert.equal(del.status, 204);
    assert.equal(store.listPushTokens().length, 0);
  });

  it("answers an agent question turn via POST /v1/tasks/:id/answer (watch action)", async () => {
    const { store } = await createTestTaskStore();
    const env = makeRouteEnv(store);
    const session = await issueSession(env as never, "u_watch_answer_test_12345678");
    const auth = { Authorization: `Bearer ${session.accessToken}`, "Content-Type": "application/json", "X-Septena-Client": "septask-watch" };

    store.push(
      [{ clientOpId: opId("t"), op: "upsert", entity: "task", id: "t-watch", fields: { title: "Pick color", status: "open" } }],
      "app:septask-ios",
    );
    store.push(
      [{
        clientOpId: opId("q"),
        op: "appendTurn",
        taskId: "t-watch",
        turn: { role: "provider", step: "decide", question: "Which?", options: ["Red", "Blue"], ts: "2026-11-24T11:00:00Z" },
      }],
      "mcp:claude",
    );

    const res = await api.request(
      "https://api.septena.app/tasks/t-watch/answer",
      { method: "POST", headers: auth, body: JSON.stringify({ chosen: "Blue", inReplyTo: 1, step: "decide" }) },
      env as never,
    );
    assert.equal(res.status, 200);
    const body = (await res.json()) as { id: string; seq: number };
    assert.equal(body.id, "t-watch");
    assert.equal(body.seq, 2);

    const read = store.readTask("t-watch");
    assert.equal(read?.turns.length, 2);
    assert.equal(read?.turns[1].role, "user");
    assert.equal(read?.turns[1].chosen, "Blue");
    assert.equal(read?.turns[1].inReplyTo, 1);
  });
});
