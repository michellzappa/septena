import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Hono } from "hono";
import { createTestPairingStore, createTestTaskStore, ensureSession, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// WB0 backend readiness: CORS, cookie session mode, and WebSocket tickets
// (docs/WEB_CLIENT_SPEC.md §4–§5, issue #21).

const { api } = await import("../src/api/routes.ts");
const { signAccessToken } = await import("../src/api/session.ts");
const { REFRESH_COOKIE_NAME, issueWsTicket, redeemWsTicket } = await import("../src/api/webAuth.ts");

const TEST_SIGNING_KEY = Buffer.alloc(32, 9).toString("base64");
const EXEC_CTX = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
const WEB_ORIGIN = "https://web.septena.app";

function makeMemoryKv() {
  const map = new Map<string, string>();
  return {
    map,
    async get(key: string) { return map.get(key) ?? null; },
    async getWithMetadata(key: string) { return { value: map.get(key) ?? null, metadata: null }; },
    async put(key: string, value: string) { map.set(key, value); },
    async delete(key: string) { map.delete(key); },
  };
}

function extractRefreshCookie(setCookie: string | null): string {
  assert.ok(setCookie, "expected Set-Cookie header");
  const m = new RegExp(`${REFRESH_COOKIE_NAME}=([^;]+)`).exec(setCookie);
  assert.ok(m, `expected ${REFRESH_COOKIE_NAME} in Set-Cookie: ${setCookie}`);
  return decodeURIComponent(m[1]);
}

async function makeHarness(overrides: Record<string, unknown> = {}) {
  const tokens = makeMemoryKv();
  const state = makeMemoryKv();
  const clients = makeMemoryKv();
  const taskStores = new Map<string, Awaited<ReturnType<typeof createTestTaskStore>>["store"]>();
  const pairingStores = new Map<string, Awaited<ReturnType<typeof createTestPairingStore>>>();
  let wsFetchCalls = 0;

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
    WEB_ALLOWED_ORIGINS: WEB_ORIGIN,
    SESSION_SIGNING_KEY: TEST_SIGNING_KEY,
    TOKENS: tokens,
    STATE: state,
    CLIENTS: clients,
    TASK_STORE: {
      idFromName(name: string) { return name; },
      get(id: string) {
        return new Proxy({}, {
          get(_t, prop: string) {
            if (prop === "fetch") {
              return async () => {
                wsFetchCalls++;
                return new Response(JSON.stringify({ upgraded: true }), { status: 200 });
              };
            }
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
    ...overrides,
  } as never;

  const app = new Hono<{ Bindings: typeof env }>();
  app.route("/v1", api);

  async function req(
    method: string,
    path: string,
    opts: { body?: unknown; headers?: Record<string, string>; rawBody?: string } = {},
  ) {
    const headers: Record<string, string> = { ...(opts.headers ?? {}) };
    let body: string | undefined = opts.rawBody;
    if (opts.body !== undefined) {
      headers["Content-Type"] = "application/json";
      body = JSON.stringify(opts.body);
    }
    return app.fetch(new Request(`https://api.septena.app${path}`, { method, headers, body }), env, EXEC_CTX);
  }

  async function authHeader(userId: string, sid = "22222222-2222-4222-8222-222222222222") {
    ensureSession(await ensureTaskStore(userId), sid);
    return `Bearer ${await signAccessToken(env, userId, sid)}`;
  }

  return { env, app, req, authHeader, getWsFetchCalls: () => wsFetchCalls };
}

describe("WB0 CORS", () => {
  it("answers preflight for allowed web origins and rejects disallowed origins", async () => {
    const h = await makeHarness();

    const ok = await h.req("OPTIONS", "/v1/sync/pull", {
      headers: {
        Origin: WEB_ORIGIN,
        "Access-Control-Request-Method": "GET",
        "Access-Control-Request-Headers": "Authorization, X-Septena-Client",
      },
    });
    assert.equal(ok.status, 204);
    assert.equal(ok.headers.get("Access-Control-Allow-Origin"), WEB_ORIGIN);
    assert.equal(ok.headers.get("Access-Control-Allow-Credentials"), "true");
    assert.match(ok.headers.get("Access-Control-Allow-Headers") ?? "", /Authorization/);
    assert.match(ok.headers.get("Access-Control-Allow-Headers") ?? "", /X-Septena-Client/);
    assert.equal(ok.headers.get("Access-Control-Max-Age"), "86400");
    assert.equal(ok.headers.get("Vary"), "Origin");

    const bad = await h.req("OPTIONS", "/v1/sync/pull", {
      headers: { Origin: "https://evil.example" },
    });
    assert.equal(bad.status, 403);
    assert.equal(bad.headers.get("Access-Control-Allow-Origin"), null);
  });

  it("attaches credentialed CORS headers on normal API responses for allowed origins only", async () => {
    const h = await makeHarness();
    const auth = await h.authHeader("u_cors_1");

    const ok = await h.req("GET", "/v1/sync/pull?since=0", {
      headers: { Origin: WEB_ORIGIN, Authorization: auth },
    });
    assert.equal(ok.status, 200);
    assert.equal(ok.headers.get("Access-Control-Allow-Origin"), WEB_ORIGIN);
    assert.equal(ok.headers.get("Access-Control-Allow-Credentials"), "true");
    assert.match(ok.headers.get("Vary") ?? "", /Origin/);

    const other = await h.req("GET", "/v1/sync/pull?since=0", {
      headers: { Origin: "https://other.example", Authorization: auth },
    });
    assert.equal(other.status, 200);
    assert.equal(other.headers.get("Access-Control-Allow-Origin"), null);
  });
});

describe("WB0 cookie session mode", () => {
  it("completes device approval into an HttpOnly refresh cookie, rotates on refresh, and clears on signout", async () => {
    const h = await makeHarness();
    const userId = "u_web_cookie_1";
    const approverAuth = await h.authHeader(userId);

    const startRes = await h.req("POST", "/v1/auth/device/start", {
      headers: { Origin: WEB_ORIGIN },
      body: { clientName: "Web Chrome" },
    });
    assert.equal(startRes.status, 200);
    const start = (await startRes.json()) as { code: string; pollSecret: string };

    const approveRes = await h.req("POST", "/v1/pair/approve", {
      headers: { Authorization: approverAuth },
      body: { code: start.code, kind: "device" },
    });
    assert.equal(approveRes.status, 200);

    // Cookie mode refuses requests without an allowed Origin BEFORE consuming the approval.
    const badPoll = await h.req("POST", "/v1/auth/device/poll", {
      headers: { Origin: "https://evil.example" },
      body: { code: start.code, pollSecret: start.pollSecret, sessionMode: "cookie" },
    });
    assert.equal(badPoll.status, 403);

    // Allowed Origin gets the session cookie and no refreshToken in JSON.
    const pollRes = await h.req("POST", "/v1/auth/device/poll", {
      headers: { Origin: WEB_ORIGIN },
      body: { code: start.code, pollSecret: start.pollSecret, sessionMode: "cookie" },
    });
    assert.equal(pollRes.status, 200);
    const pollBody = (await pollRes.json()) as Record<string, unknown>;
    assert.equal(typeof pollBody.accessToken, "string");
    assert.equal(pollBody.userId, userId);
    assert.equal("refreshToken" in pollBody, false);

    const setCookie1 = pollRes.headers.get("Set-Cookie");
    assert.ok(setCookie1);
    assert.match(setCookie1, /HttpOnly/);
    assert.match(setCookie1, /Secure/);
    assert.match(setCookie1, /SameSite=Lax/);
    assert.match(setCookie1, /Path=\/v1\/auth/);
    const token1 = extractRefreshCookie(setCookie1);

    // Cookie refresh refuses missing or disallowed Origin.
    const noOriginRefresh = await h.req("POST", "/v1/auth/refresh", {
      headers: { Cookie: `${REFRESH_COOKIE_NAME}=${token1}` },
    });
    assert.equal(noOriginRefresh.status, 403);

    const badOriginRefresh = await h.req("POST", "/v1/auth/refresh", {
      headers: { Origin: "https://evil.example", Cookie: `${REFRESH_COOKIE_NAME}=${token1}` },
    });
    assert.equal(badOriginRefresh.status, 403);

    // Allowed Origin rotates the cookie and returns a new access token.
    const refreshRes = await h.req("POST", "/v1/auth/refresh", {
      headers: { Origin: WEB_ORIGIN, Cookie: `${REFRESH_COOKIE_NAME}=${token1}` },
      body: {},
    });
    assert.equal(refreshRes.status, 200);
    const refreshBody = (await refreshRes.json()) as Record<string, unknown>;
    assert.equal(typeof refreshBody.accessToken, "string");
    assert.equal("refreshToken" in refreshBody, false);
    const token2 = extractRefreshCookie(refreshRes.headers.get("Set-Cookie"));
    assert.notEqual(token2, token1);

    // An unknown/bogus cookie fails with 401 and clears the cookie.
    const invalidRes = await h.req("POST", "/v1/auth/refresh", {
      headers: { Origin: WEB_ORIGIN, Cookie: `${REFRESH_COOKIE_NAME}=sr1.not-a-real-refresh-token-value` },
    });
    assert.equal(invalidRes.status, 401);
    assert.match(invalidRes.headers.get("Set-Cookie") ?? "", /Max-Age=0/);

    // Sign-out revokes the session and clears the cookie.
    const signoutRes = await h.req("POST", "/v1/auth/signout", {
      headers: { Origin: WEB_ORIGIN, Cookie: `${REFRESH_COOKIE_NAME}=${token2}` },
    });
    assert.equal(signoutRes.status, 204);
    assert.match(signoutRes.headers.get("Set-Cookie") ?? "", /Max-Age=0/);

    const afterSignout = await h.req("POST", "/v1/auth/refresh", {
      headers: { Origin: WEB_ORIGIN, Cookie: `${REFRESH_COOKIE_NAME}=${token2}` },
    });
    assert.equal(afterSignout.status, 401);
    assert.match(afterSignout.headers.get("Set-Cookie") ?? "", /Max-Age=0/);
  });

  it("supports ADR 0040 signed sr2 refresh cookies (>200 chars)", async () => {
    const h = await makeHarness({ SIGNED_SESSIONS: "true" });
    const userId = "u_web_sr2_1";
    const approverAuth = await h.authHeader(userId);

    const startRes = await h.req("POST", "/v1/auth/device/start", {
      headers: { Origin: WEB_ORIGIN },
      body: { clientName: "Web Safari" },
    });
    const start = (await startRes.json()) as { code: string; pollSecret: string };
    await h.req("POST", "/v1/pair/approve", {
      headers: { Authorization: approverAuth },
      body: { code: start.code, kind: "device" },
    });

    const pollRes = await h.req("POST", "/v1/auth/device/poll", {
      headers: { Origin: WEB_ORIGIN },
      body: { code: start.code, pollSecret: start.pollSecret, sessionMode: "cookie" },
    });
    assert.equal(pollRes.status, 200);
    const sr2 = extractRefreshCookie(pollRes.headers.get("Set-Cookie"));
    assert.ok(sr2.startsWith("sr2."));

    const refreshRes = await h.req("POST", "/v1/auth/refresh", {
      headers: { Origin: WEB_ORIGIN, Cookie: `${REFRESH_COOKIE_NAME}=${sr2}` },
    });
    assert.equal(refreshRes.status, 200);
    const sr2Next = extractRefreshCookie(refreshRes.headers.get("Set-Cookie"));
    assert.ok(sr2Next.startsWith("sr2."));
    assert.notEqual(sr2Next, sr2);
  });
});

describe("WB0 WebSocket tickets", () => {
  it("issues a single-use 30s ticket accepted by /v1/sync/ws and rejected on replay or expiry", async () => {
    const h = await makeHarness();
    const userId = "u_ws_ticket_1";
    const auth = await h.authHeader(userId);

    const ticketRes = await h.req("POST", "/v1/sync/ws-ticket", {
      headers: { Origin: WEB_ORIGIN, Authorization: auth, "X-Septena-Client": "web 0.1.0" },
    });
    assert.equal(ticketRes.status, 200);
    const { ticket, expiresIn } = (await ticketRes.json()) as { ticket: string; expiresIn: number };
    assert.equal(expiresIn, 30);
    assert.ok(ticket.startsWith("wst_"));

    // Ticket is refused for disallowed Origin.
    const badOriginWs = await h.req("GET", `/v1/sync/ws?ticket=${encodeURIComponent(ticket)}`, {
      headers: { Origin: "https://evil.example", Upgrade: "websocket" },
    });
    assert.equal(badOriginWs.status, 403);

    // First valid redemption succeeds and forwards to the user's TaskStore.
    const wsOk = await h.req("GET", `/v1/sync/ws?ticket=${encodeURIComponent(ticket)}`, {
      headers: { Origin: WEB_ORIGIN, Upgrade: "websocket" },
    });
    assert.equal(wsOk.status, 200);
    assert.equal(h.getWsFetchCalls(), 1);

    // Replay is rejected with 401.
    const wsReplay = await h.req("GET", `/v1/sync/ws?ticket=${encodeURIComponent(ticket)}`, {
      headers: { Origin: WEB_ORIGIN, Upgrade: "websocket" },
    });
    assert.equal(wsReplay.status, 401);

    // Tickets are not accepted on non-ws sync endpoints.
    const t2Res = await h.req("POST", "/v1/sync/ws-ticket", {
      headers: { Authorization: auth },
    });
    const { ticket: ticket2 } = (await t2Res.json()) as { ticket: string };
    const pullWithTicket = await h.req("GET", `/v1/sync/pull?since=0&ticket=${encodeURIComponent(ticket2)}`);
    assert.equal(pullWithTicket.status, 401);

    // Expired ticket is rejected.
    const issued = await issueWsTicket(h.env, { userId, sid: null, client: "web 0.1.0" }, 1_000_000);
    const expired = await redeemWsTicket(h.env, issued.ticket, 1_031_000);
    assert.equal(expired, null);
  });
});
