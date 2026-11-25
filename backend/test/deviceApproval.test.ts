import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Hono } from "hono";
import { createTestPairingStore, createTestTaskStore, ensureSession, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Sign-in S3: approve a new device from a signed-in app (ADR 0016, issue #170).

const { api } = await import("../src/api/routes.ts");
const { signAccessToken, verifyAccessToken } = await import("../src/api/session.ts");
const oauth = await import("../src/shadow/oauth.ts");
const { pairApproveUrl } = await import("../src/shadow/pairQr.ts");

const TEST_SIGNING_KEY = Buffer.alloc(32, 7).toString("base64");
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

async function makeHarness() {
  const tokens = makeMemoryKv();
  const state = makeMemoryKv();
  const clients = makeMemoryKv();
  const taskStores = new Map<string, Awaited<ReturnType<typeof createTestTaskStore>>["store"]>();
  const pairingStores = new Map<string, Awaited<ReturnType<typeof createTestPairingStore>>>();

  const ensureTaskStore = async (userId: string) => {
    let s = taskStores.get(userId);
    if (!s) {
      s = (await createTestTaskStore()).store;
      taskStores.set(userId, s);
    }
    return s;
  };

  const ensurePairingStore = async (id: string) => {
    let p = pairingStores.get(id);
    if (!p) {
      p = await createTestPairingStore();
      pairingStores.set(id, p);
    }
    return p;
  };

  const env = {
    API_PUBLIC_URL: "https://api.septena.app",
    APPLE_AUDIENCES: "com.septena.tasks",
    ENTITLEMENT_ENFORCE: "false",
    APPLE_IAP_BUNDLE_IDS: "com.septena.tasks",
    APPLE_IAP_ENVIRONMENTS: "Production,Sandbox",
    SESSION_SIGNING_KEY: TEST_SIGNING_KEY,
    TOKENS: tokens,
    STATE: state,
    CLIENTS: clients,
    TASK_STORE: {
      idFromName(name: string) { return name; },
      get(id: string) {
        return new Proxy({}, {
          get(_t, prop: string) {
            return async (...args: unknown[]) => {
              const s = await ensureTaskStore(id);
              return (s as unknown as Record<string, (...a: unknown[]) => unknown>)[prop](...args);
            };
          },
        });
      },
    },
    PAIRING: {
      idFromName(name: string) { return name; },
      get(id: string) {
        return new Proxy({}, {
          get(_t, prop: string) {
            return async (...args: unknown[]) => {
              const p = await ensurePairingStore(id);
              return (p.store as unknown as Record<string, (...a: unknown[]) => unknown>)[prop](...args);
            };
          },
        });
      },
    },
  } as never;

  const app = new Hono<{ Bindings: typeof env }>();
  app.get("/oauth/authorize", oauth.authorize);
  app.get("/oauth/pair/continue", oauth.pairContinue);
  app.get("/pair/:code", oauth.pairLanding);
  app.post("/oauth/token", oauth.token);
  app.route("/v1", api);

  async function authHeader(userId: string, sid = "11111111-1111-4111-8111-111111111111") {
    ensureSession(await ensureTaskStore(userId), sid);
    return `Bearer ${await signAccessToken(env, userId, sid)}`;
  }

  async function postJson(
    path: string,
    body: unknown,
    opts: { auth?: string; ip?: string; client?: string } = {},
  ) {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (opts.auth) headers.Authorization = opts.auth;
    if (opts.ip) headers["CF-Connecting-IP"] = opts.ip;
    if (opts.client) headers["X-Septena-Client"] = opts.client;
    return app.fetch(new Request(`https://api.septena.app${path}`, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    }), env, EXEC_CTX);
  }

  async function seedConnectorClient(clientId = "claude-test-client") {
    await clients.put(`v2:client:${clientId}`, JSON.stringify({
      id: clientId,
      name: "Claude",
      redirectUris: ["https://claude.ai/api/mcp/auth_callback"],
    }));
    return clientId;
  }

  async function startConnectorFlow(clientId = "claude-test-client") {
    await seedConnectorClient(clientId);
    const challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
    const url = new URL("https://api.septena.app/oauth/authorize");
    url.searchParams.set("response_type", "code");
    url.searchParams.set("client_id", clientId);
    url.searchParams.set("redirect_uri", "https://claude.ai/api/mcp/auth_callback");
    url.searchParams.set("state", "oauth-state-123");
    url.searchParams.set("code_challenge", challenge);
    url.searchParams.set("code_challenge_method", "S256");

    const res = await app.fetch(new Request(url.toString(), { method: "GET" }), env, EXEC_CTX);
    assert.equal(res.status, 200);
    const setCookie = res.headers.get("Set-Cookie") ?? "";
    const m = /septena_pair=([A-Z2-9]{8})\.([A-Za-z0-9_-]+)/.exec(setCookie);
    assert.ok(m, `expected septena_pair cookie in ${setCookie}`);
    return { code: m[1], pendingId: m[2], cookie: `septena_pair=${m[1]}.${m[2]}` };
  }

  return {
    env,
    app,
    tokens,
    state,
    clients,
    pairingStores,
    ensureTaskStore,
    ensurePairingStore,
    authHeader,
    postJson,
    startConnectorFlow,
  };
}

describe("Sign-in S3: device approval flow (ADR 0016, #170)", () => {
  it("end-to-end: signed-in user approves a device code and polling client receives a valid session for the same userId", async () => {
    const h = await makeHarness();
    const userId = "u_device_approval_happy_user_0001";
    const approverSid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const approverAuth = await h.authHeader(userId, approverSid);

    // 1. New device starts pairing.
    const startRes = await h.postJson("/v1/auth/device/start", { clientName: "Android Pixel 9" });
    assert.equal(startRes.status, 200);
    assert.equal(startRes.headers.get("Cache-Control"), "no-store");
    const started = await startRes.json() as {
      code: string;
      pollSecret: string;
      expiresIn: number;
      interval: number;
      qr: { size: number; modules: string };
    };
    assert.match(started.code, /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/);
    assert.match(started.pollSecret, /^[A-Za-z0-9_-]{20,64}$/);
    assert.equal(started.expiresIn, 600);
    assert.equal(started.interval, 3);
    // QR matrix payload is present; when qrcode-generator is installed (CI), validate version dimensions too.
    assert.equal(typeof started.qr.size, "number");
    assert.equal(typeof started.qr.modules, "string");
    assert.equal(started.qr.modules.length, started.qr.size * started.qr.size);
    assert.match(started.qr.modules, /^[01]*$/);
    if (started.qr.size > 0) {
      assert.ok(started.qr.size >= 21 && started.qr.size <= 177);
      assert.equal((started.qr.size - 17) % 4, 0);
    }
    assert.equal(pairApproveUrl("https://api.septena.app", started.code), `https://api.septena.app/pair/${started.code}`);

    // 2. Landing page for system-camera QR scans approves nothing and does not mutate state.
    const landingRes = await h.app.fetch(
      new Request(`https://api.septena.app/pair/${started.code}`, { method: "GET" }),
      h.env,
      EXEC_CTX,
    );
    assert.equal(landingRes.status, 200);
    assert.equal(landingRes.headers.get("Cache-Control"), "no-store");
    assert.equal(landingRes.headers.get("Referrer-Policy"), "no-referrer");

    // 3. Polling before approval returns 202 pending (accepts formatted lowercase/dashed code).
    const dashed = `${started.code.slice(0, 4).toLowerCase()}-${started.code.slice(4).toLowerCase()}`;
    const pendingRes = await h.postJson("/v1/auth/device/poll", {
      code: dashed,
      pollSecret: started.pollSecret,
    });
    assert.equal(pendingRes.status, 202);
    assert.equal(pendingRes.headers.get("Cache-Control"), "no-store");
    assert.deepEqual(await pendingRes.json(), { status: "pending" });

    // 4. Signed-in app inspects the code to show "Sign in on Android Pixel 9?".
    const inspectRes = await h.postJson("/v1/pair/inspect", { code: dashed }, { auth: approverAuth });
    assert.equal(inspectRes.status, 200);
    assert.equal(inspectRes.headers.get("Cache-Control"), "no-store");
    const inspected = await inspectRes.json() as { kind: string; client: string; expiresIn: number };
    assert.equal(inspected.kind, "device");
    assert.equal(inspected.client, "Android Pixel 9");
    assert.ok(inspected.expiresIn > 0 && inspected.expiresIn <= 600);

    // 5. Signed-in app approves the device code with explicit kind: "device".
    const approveRes = await h.postJson(
      "/v1/pair/approve",
      { code: started.code, kind: "device", timeZone: "Europe/Berlin" },
      { auth: approverAuth },
    );
    assert.equal(approveRes.status, 200);
    assert.equal(approveRes.headers.get("Cache-Control"), "no-store");
    assert.deepEqual(await approveRes.json(), { ok: true, client: "Android Pixel 9", kind: "device" });

    // 6. Polling client now receives an ordinary app session for the same userId.
    const pollRes = await h.postJson("/v1/auth/device/poll", {
      code: started.code,
      pollSecret: started.pollSecret,
    });
    assert.equal(pollRes.status, 200);
    assert.equal(pollRes.headers.get("Cache-Control"), "no-store");
    const session = await pollRes.json() as {
      accessToken: string;
      refreshToken: string;
      expiresIn: number;
      userId: string;
    };
    assert.equal(session.userId, userId);
    assert.equal(session.expiresIn, 3600);
    assert.ok(session.accessToken.startsWith("sa1."));
    assert.ok(session.refreshToken.startsWith("sr1."));

    const claims = await verifyAccessToken(h.env, session.accessToken);
    assert.ok(claims);
    assert.equal(claims.userId, userId);
    assert.ok(claims.sid && claims.sid !== approverSid, "new device receives its own distinct session id");

    // The issued access token works immediately on authenticated endpoints, and refresh rotates cleanly.
    const accessRes = await h.app.fetch(new Request("https://api.septena.app/v1/access", {
      method: "GET",
      headers: {
        Authorization: `Bearer ${session.accessToken}`,
        "X-Septena-Client": "septask-android",
      },
    }), h.env, EXEC_CTX);
    assert.equal(accessRes.status, 200);

    const refreshRes = await h.postJson("/v1/auth/refresh", { refreshToken: session.refreshToken });
    assert.equal(refreshRes.status, 200);
    const refreshed = await refreshRes.json() as { userId: string; accessToken: string; refreshToken: string };
    assert.equal(refreshed.userId, userId);
    assert.notEqual(refreshed.refreshToken, session.refreshToken);

    // 7. Single-use: a second poll with the same code + secret cannot redeem a second session.
    const replayRes = await h.postJson("/v1/auth/device/poll", {
      code: started.code,
      pollSecret: started.pollSecret,
    });
    assert.equal(replayRes.status, 410);
    assert.deepEqual(await replayRes.json(), { error: "expired_or_unknown" });
  });

  it("refuses double approval and prevents re-pointing an approved code to another user", async () => {
    const h = await makeHarness();
    const userA = "u_pair_single_approve_user_a_001";
    const userB = "u_pair_single_approve_user_b_002";
    const authA = await h.authHeader(userA);
    const authB = await h.authHeader(userB);

    const started = await (await h.postJson("/v1/auth/device/start", { clientName: "Windows Desktop" })).json() as {
      code: string;
      pollSecret: string;
    };

    const first = await h.postJson("/v1/pair/approve", { code: started.code, kind: "device" }, { auth: authA });
    assert.equal(first.status, 200);

    // Inspecting an already-approved code reports code_used.
    const inspectAgain = await h.postJson("/v1/pair/inspect", { code: started.code }, { auth: authB });
    assert.equal(inspectAgain.status, 409);
    assert.deepEqual(await inspectAgain.json(), { error: "code_used" });

    // A second approval by another user fails with 409 and does NOT overwrite userA.
    const second = await h.postJson("/v1/pair/approve", { code: started.code, kind: "device" }, { auth: authB });
    assert.equal(second.status, 409);
    assert.deepEqual(await second.json(), { error: "code_used" });

    // Polling still yields userA's session.
    const poll = await h.postJson("/v1/auth/device/poll", { code: started.code, pollSecret: started.pollSecret });
    assert.equal(poll.status, 200);
    const session = await poll.json() as { userId: string };
    assert.equal(session.userId, userA);
  });

  it("enforces strict purpose separation: cross-purpose approvals, polls, and OAuth redemptions all fail", async () => {
    const h = await makeHarness();
    const userId = "u_cross_purpose_isolation_user_01";
    const auth = await h.authHeader(userId);

    // --- Attack A: approve a device code through connector approval (explicit kind: "connector" OR omitted legacy kind) ---
    const devStart = await (await h.postJson("/v1/auth/device/start", { clientName: "Android Tablet" })).json() as {
      code: string;
      pollSecret: string;
    };

    const badExplicitConnector = await h.postJson(
      "/v1/pair/approve",
      { code: devStart.code, kind: "connector" },
      { auth },
    );
    assert.equal(badExplicitConnector.status, 404);
    assert.deepEqual(await badExplicitConnector.json(), { error: "invalid_code" });

    // Legacy pre-2026-11-22 clients omit `kind` because they only knew connector pairing.
    // Omitting `kind` MUST NEVER silently approve a device sign-in code.
    const badOmittedKind = await h.postJson(
      "/v1/pair/approve",
      { code: devStart.code },
      { auth },
    );
    assert.equal(badOmittedKind.status, 404);
    assert.deepEqual(await badOmittedKind.json(), { error: "invalid_code" });

    // Device code must still be pending (neither approved nor corrupted).
    const stillPending = await h.postJson("/v1/auth/device/poll", {
      code: devStart.code,
      pollSecret: devStart.pollSecret,
    });
    assert.equal(stillPending.status, 202);

    // --- Attack B: connector OAuth (/oauth/pair/continue) tries to redeem a device code (both pending and approved) ---
    const fakeCookie = `septena_pair=${devStart.code}.${devStart.pollSecret}`;
    const continuePending = await h.app.fetch(new Request("https://api.septena.app/oauth/pair/continue", {
      method: "GET",
      headers: { Cookie: fakeCookie },
    }), h.env, EXEC_CTX);
    assert.equal(continuePending.status, 400);
    assert.equal(continuePending.headers.get("Location"), null);

    // Now legitimately approve the device code, then try to hijack it via /oauth/pair/continue.
    const goodDevApprove = await h.postJson(
      "/v1/pair/approve",
      { code: devStart.code, kind: "device" },
      { auth },
    );
    assert.equal(goodDevApprove.status, 200);

    const continueApproved = await h.app.fetch(new Request("https://api.septena.app/oauth/pair/continue", {
      method: "GET",
      headers: { Cookie: fakeCookie },
    }), h.env, EXEC_CTX);
    assert.equal(continueApproved.status, 400);
    assert.equal(continueApproved.headers.get("Location"), null);
    assert.equal(
      [...h.state.map.keys()].filter((k) => k.startsWith("v2:code:")).length,
      0,
      "connector OAuth must never mint an auth code from a device pairing",
    );

    // The legitimate device still redeems its own approved session.
    const legitDevPoll = await h.postJson("/v1/auth/device/poll", {
      code: devStart.code,
      pollSecret: devStart.pollSecret,
    });
    assert.equal(legitDevPoll.status, 200);
    assert.equal(((await legitDevPoll.json()) as { userId: string }).userId, userId);

    // --- Attack C: poll a connector code through /v1/auth/device/poll, or approve connector code as device ---
    const conn = await h.startConnectorFlow();

    const badApproveAsDevice = await h.postJson(
      "/v1/pair/approve",
      { code: conn.code, kind: "device" },
      { auth },
    );
    assert.equal(badApproveAsDevice.status, 404);
    assert.deepEqual(await badApproveAsDevice.json(), { error: "invalid_code" });

    // Polling a pending connector code on /v1/auth/device/poll fails (even with its real pendingId).
    const pollConnPending = await h.postJson("/v1/auth/device/poll", {
      code: conn.code,
      pollSecret: conn.pendingId,
    });
    assert.equal(pollConnPending.status, 410);
    assert.deepEqual(await pollConnPending.json(), { error: "expired_or_unknown" });

    // Legacy omitted `kind` still works for connector codes (backward compatibility).
    const legacyConnApprove = await h.postJson(
      "/v1/pair/approve",
      { code: conn.code },
      { auth },
    );
    assert.equal(legacyConnApprove.status, 200);
    assert.deepEqual(await legacyConnApprove.json(), { ok: true, client: "Claude", kind: "connector" });

    // Even AFTER approval, polling a connector code on /v1/auth/device/poll fails and never mints an app session!
    const pollConnApproved = await h.postJson("/v1/auth/device/poll", {
      code: conn.code,
      pollSecret: conn.pendingId,
    });
    assert.equal(pollConnApproved.status, 410);
    assert.deepEqual(await pollConnApproved.json(), { error: "expired_or_unknown" });

    // And the connector flow itself can still finish its OAuth redirect normally.
    const finishConn = await h.app.fetch(new Request("https://api.septena.app/oauth/pair/continue", {
      method: "GET",
      headers: { Cookie: conn.cookie },
    }), h.env, EXEC_CTX);
    assert.equal(finishConn.status, 302);
    const loc = new URL(finishConn.headers.get("Location")!);
    assert.equal(loc.origin + loc.pathname, "https://claude.ai/api/mcp/auth_callback");
    assert.ok(loc.searchParams.get("code"));
    assert.equal(loc.searchParams.get("state"), "oauth-state-123");
  });

  it("rejects wrong client pollSecret without revealing status or consuming the code", async () => {
    const h = await makeHarness();
    const userId = "u_wrong_secret_device_user_00001";
    const auth = await h.authHeader(userId);

    const started = await (await h.postJson("/v1/auth/device/start", { clientName: "Web Chrome" })).json() as {
      code: string;
      pollSecret: string;
    };
    const wrongSecret = "wrong_secret_value_0123456789abcdef";

    // Wrong secret while pending -> 410, does not consume.
    const badPending = await h.postJson("/v1/auth/device/poll", { code: started.code, pollSecret: wrongSecret });
    assert.equal(badPending.status, 410);
    assert.deepEqual(await badPending.json(), { error: "expired_or_unknown" });

    // Approve the code, then try wrong secret again -> still 410, does not consume!
    assert.equal(
      (await h.postJson("/v1/pair/approve", { code: started.code, kind: "device" }, { auth })).status,
      200,
    );
    const badApproved = await h.postJson("/v1/auth/device/poll", { code: started.code, pollSecret: wrongSecret });
    assert.equal(badApproved.status, 410);
    assert.deepEqual(await badApproved.json(), { error: "expired_or_unknown" });

    // Legitimate device with the real secret still receives its session.
    const good = await h.postJson("/v1/auth/device/poll", { code: started.code, pollSecret: started.pollSecret });
    assert.equal(good.status, 200);
    assert.equal(((await good.json()) as { userId: string }).userId, userId);
  });

  it("handles explicit denial and expiry cleanly", async () => {
    const h = await makeHarness();
    const userId = "u_deny_and_expire_device_user_01";
    const auth = await h.authHeader(userId);

    // 1. Explicit denial via POST /v1/pair/deny.
    const started = await (await h.postJson("/v1/auth/device/start", { clientName: "Unknown Browser" })).json() as {
      code: string;
      pollSecret: string;
    };
    const denyRes = await h.postJson(
      "/v1/pair/deny",
      { code: started.code, kind: "device" },
      { auth },
    );
    assert.equal(denyRes.status, 200);
    assert.deepEqual(await denyRes.json(), { ok: true, client: "Unknown Browser", kind: "device" });

    // Cannot approve a denied code.
    const approveDenied = await h.postJson(
      "/v1/pair/approve",
      { code: started.code, kind: "device" },
      { auth },
    );
    assert.equal(approveDenied.status, 409);
    assert.deepEqual(await approveDenied.json(), { error: "code_used" });

    // Wrong pollSecret on a denied code does NOT leak "denied".
    const wrongOnDenied = await h.postJson("/v1/auth/device/poll", {
      code: started.code,
      pollSecret: "wrong_secret_value_0123456789abcdef",
    });
    assert.equal(wrongOnDenied.status, 410);
    assert.deepEqual(await wrongOnDenied.json(), { error: "expired_or_unknown" });

    // Real pollSecret receives 410 { error: "denied" } once, then storage is wiped.
    const pollDenied = await h.postJson("/v1/auth/device/poll", {
      code: started.code,
      pollSecret: started.pollSecret,
    });
    assert.equal(pollDenied.status, 410);
    assert.deepEqual(await pollDenied.json(), { error: "denied" });

    const pollAfterDenied = await h.postJson("/v1/auth/device/poll", {
      code: started.code,
      pollSecret: started.pollSecret,
    });
    assert.equal(pollAfterDenied.status, 410);
    assert.deepEqual(await pollAfterDenied.json(), { error: "expired_or_unknown" });

    // 2. Expired code returns invalid_code / expired_or_unknown and cleans up.
    const expired = await (await h.postJson("/v1/auth/device/start", { clientName: "Old Device" })).json() as {
      code: string;
      pollSecret: string;
    };
    const pairingObj = await h.ensurePairingStore(`pair:${expired.code}`);
    const storedPending = pairingObj.data.get("pending") as { expiresAt: number };
    storedPending.expiresAt = Date.now() - 1;

    const pollExpired = await h.postJson("/v1/auth/device/poll", {
      code: expired.code,
      pollSecret: expired.pollSecret,
    });
    assert.equal(pollExpired.status, 410);
    assert.deepEqual(await pollExpired.json(), { error: "expired_or_unknown" });
    assert.equal(pairingObj.data.size, 0, "expired pairing wipes its DO storage");

    // 3. Alarm cleanup wipes PairingStore storage.
    const alarmTarget = await (await h.postJson("/v1/auth/device/start", { clientName: "Alarm Device" })).json() as {
      code: string;
    };
    const alarmObj = await h.ensurePairingStore(`pair:${alarmTarget.code}`);
    assert.ok(alarmObj.getAlarm() !== null);
    await alarmObj.store.alarm();
    assert.equal(alarmObj.data.size, 0);
  });

  it("enforces brute-force rate limits on inspect/approve, device/start, and failed device/poll", async () => {
    const h = await makeHarness();
    const attackerUser = "u_bruteforce_attacker_user_00001";
    const innocentUser = "u_bruteforce_innocent_user_00002";
    const attackerAuth = await h.authHeader(attackerUser);
    const innocentAuth = await h.authHeader(innocentUser);

    const live = await (await h.postJson("/v1/auth/device/start", { clientName: "Legit Phone" })).json() as {
      code: string;
      pollSecret: string;
    };

    // 1. Per-user approve/inspect lockout after PAIR_MAX_FAILURES (5) wrong codes.
    for (let i = 0; i < oauth.PAIR_MAX_FAILURES; i++) {
      const endpoint = i % 2 === 0 ? "/v1/pair/inspect" : "/v1/pair/approve";
      const body = endpoint === "/v1/pair/inspect"
        ? { code: `ZZZZ222${i + 2}` }
        : { code: `ZZZZ222${i + 2}`, kind: "device" };
      const r = await h.postJson(endpoint, body, { auth: attackerAuth });
      assert.equal(r.status, 404);
    }

    // Even a real live code is now locked out (429) for attackerUser on inspect, approve, and deny.
    const lockedInspect = await h.postJson("/v1/pair/inspect", { code: live.code }, { auth: attackerAuth });
    assert.equal(lockedInspect.status, 429);
    assert.deepEqual(await lockedInspect.json(), { error: "too_many_attempts" });

    const lockedApprove = await h.postJson(
      "/v1/pair/approve",
      { code: live.code, kind: "device" },
      { auth: attackerAuth },
    );
    assert.equal(lockedApprove.status, 429);
    assert.deepEqual(await lockedApprove.json(), { error: "too_many_attempts" });

    const lockedDeny = await h.postJson("/v1/pair/deny", { code: live.code, kind: "device" }, { auth: attackerAuth });
    assert.equal(lockedDeny.status, 429);
    assert.deepEqual(await lockedDeny.json(), { error: "too_many_attempts" });

    // Innocent user is unaffected and can inspect + approve the live code.
    const okInspect = await h.postJson("/v1/pair/inspect", { code: live.code }, { auth: innocentAuth });
    assert.equal(okInspect.status, 200);

    // 2. Per-IP rate limit on POST /v1/auth/device/start.
    const spamIp = "203.0.113.10";
    for (let i = 0; i < oauth.DEVICE_START_MAX_PER_IP; i++) {
      const r = await h.postJson("/v1/auth/device/start", { clientName: "Flood Device" }, { ip: spamIp });
      assert.equal(r.status, 200);
    }
    const startBlocked = await h.postJson("/v1/auth/device/start", { clientName: "Flood Device" }, { ip: spamIp });
    assert.equal(startBlocked.status, 429);
    assert.deepEqual(await startBlocked.json(), { error: "too_many_attempts" });

    // Another IP can still start device pairing.
    const otherIpStart = await h.postJson("/v1/auth/device/start", { clientName: "Other Device" }, { ip: "203.0.113.11" });
    assert.equal(otherIpStart.status, 200);

    // 3. Per-IP failed-poll lockout on POST /v1/auth/device/poll.
    // Valid pending polls do NOT count as failures.
    const legitIp = "198.51.100.20";
    for (let i = 0; i < oauth.DEVICE_POLL_MAX_FAILURES_PER_IP + 3; i++) {
      const pending = await h.postJson(
        "/v1/auth/device/poll",
        { code: live.code, pollSecret: live.pollSecret },
        { ip: legitIp },
      );
      assert.equal(pending.status, 202);
    }

    // Wrong pollSecret guesses from an attacker IP lock out after DEVICE_POLL_MAX_FAILURES_PER_IP.
    const pollSpamIp = "198.51.100.99";
    for (let i = 0; i < oauth.DEVICE_POLL_MAX_FAILURES_PER_IP; i++) {
      const bad = await h.postJson(
        "/v1/auth/device/poll",
        { code: live.code, pollSecret: `wrong_guess_secret_000000000000_${i}` },
        { ip: pollSpamIp },
      );
      assert.equal(bad.status, 410);
    }
    const pollLocked = await h.postJson(
      "/v1/auth/device/poll",
      { code: live.code, pollSecret: live.pollSecret },
      { ip: pollSpamIp },
    );
    assert.equal(pollLocked.status, 429);
    assert.deepEqual(await pollLocked.json(), { error: "too_many_attempts" });
  });

  it("enforces authentication on approval endpoints and validates request payloads", async () => {
    const h = await makeHarness();

    assert.equal((await h.postJson("/v1/pair/inspect", { code: "ABCD2345" })).status, 401);
    assert.equal((await h.postJson("/v1/pair/approve", { code: "ABCD2345", kind: "device" })).status, 401);
    assert.equal((await h.postJson("/v1/pair/deny", { code: "ABCD2345", kind: "device" })).status, 401);

    // Invalid clientName / extra fields on start.
    assert.equal((await h.postJson("/v1/auth/device/start", { clientName: "" })).status, 400);
    assert.equal((await h.postJson("/v1/auth/device/start", { clientName: "<script>" })).status, 400);
    assert.equal((await h.postJson("/v1/auth/device/start", { clientName: "Android", extra: true })).status, 400);

    // Malformed pollSecret / extra fields on poll.
    assert.equal((await h.postJson("/v1/auth/device/poll", { code: "ABCD2345", pollSecret: "short" })).status, 400);
    assert.equal(
      (await h.postJson("/v1/auth/device/poll", { code: "ABCD2345", pollSecret: "a".repeat(32), extra: 1 })).status,
      400,
    );
  });
});
