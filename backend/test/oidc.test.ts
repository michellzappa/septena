import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Hono } from "hono";
import { createTestAccountStore, createTestPairingStore, createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Sign-in SI3 (ADR 0047, #637): Google, Microsoft and web Sign in with Apple
// OIDC backend, native Google token verification, PKCE, state, nonce, JWKS,
// return_to allowlist, collision catch, linking and connector OIDC approval.

const { api } = await import("../src/api/routes.ts");
const oauth = await import("../src/shadow/oauth.ts");
const oidc = await import("../src/api/oidc.ts");
const { base64url, sha256Base64Url } = await import("../src/util.ts");
const { verifyMcpAccess } = await import("../src/shadow/tokens.ts");
const { storedSubject } = await import("../src/store/AccountStore.ts");

const TEST_SIGNING_KEY = Buffer.alloc(32, 13).toString("base64");
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

async function makeRsaSigner(kid: string) {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const pubJwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid, use: "sig", alg: "RS256" };
  async function sign(claims: Record<string, unknown>, alg = "RS256", keyId = kid): Promise<string> {
    const enc = new TextEncoder();
    const h = base64url(enc.encode(JSON.stringify({ alg, kid: keyId })));
    const p = base64url(enc.encode(JSON.stringify(claims)));
    const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, enc.encode(`${h}.${p}`)));
    return `${h}.${p}.${base64url(sig)}`;
  }
  return { pubJwk, sign };
}

async function makeEcPkcs8Pem(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let bin = "";
  for (const b of pkcs8) bin += String.fromCharCode(b);
  const b64 = btoa(bin).match(/.{1,64}/g)!.join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----`, publicKey: pair.publicKey };
}

async function makeHarness(overrides: Record<string, unknown> = {}) {
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
  const sent: { to: string; subject: string; text: string }[] = [];
  const proxy = (target: () => Promise<unknown>) => new Proxy({}, {
    get(_t, prop: string) {
      return async (...args: unknown[]) =>
        ((await target()) as Record<string, (...a: unknown[]) => unknown>)[prop](...args);
    },
  });
  const clients = makeMemoryKv();
  const env = {
    API_PUBLIC_URL: "https://api.septena.app",
    APPLE_AUDIENCES: "com.septena.tasks",
    ENTITLEMENT_ENFORCE: "false",
    APPLE_IAP_BUNDLE_IDS: "com.septena.tasks",
    APPLE_IAP_ENVIRONMENTS: "Production,Sandbox",
    WEB_ALLOWED_ORIGINS: "https://web.septena.app",
    SESSION_SIGNING_KEY: TEST_SIGNING_KEY,
    SIGNED_SESSIONS: "true",
    EMAIL_SIGNIN: "true",
    EMAIL: {
      async send(m: { to: string; subject: string; text: string }) { sent.push(m); return { messageId: "m1" }; },
    },
    TOKENS: makeMemoryKv(),
    STATE: makeMemoryKv(),
    CLIENTS: clients,
    TASK_STORE: { idFromName: (n: string) => n, get: (id: string) => proxy(() => ensureTaskStore(id)) },
    ACCOUNT_STORE: { idFromName: (n: string) => n, get: () => proxy(async () => accountStore) },
    PAIRING: { idFromName: (n: string) => n, get: (id: string) => proxy(() => ensurePairing(id)) },
    ...overrides,
  } as never;

  const app = new Hono();
  app.get("/oauth/authorize", oauth.authorize);
  app.get("/oauth/pair/continue", oauth.pairContinue);
  app.get("/oauth/pair/oidc/:provider", oauth.pairOidc);
  app.post("/oauth/token", oauth.token);
  app.route("/v1", api);

  const req = (path: string, init: RequestInit = {}) =>
    app.fetch(new Request(`https://api.septena.app${path}`, init), env, EXEC_CTX);
  const lastCode = () => /(\d{6})/.exec(sent.at(-1)!.text)![1];
  return { env, sent, clients, accountStore, ensureTaskStore, req, lastCode };
}

describe("OIDC providers (ADR 0047, #637)", () => {
  it("reports only configured providers in GET /v1/auth/methods and refuses unconfigured ones", async () => {
    const bare = await makeHarness({ EMAIL_SIGNIN: "false" });
    const bareBody = await (await bare.req("/v1/auth/methods")).json() as { methods: { id: string; web?: boolean }[] };
    assert.deepEqual(bareBody.methods, [{ id: "apple" }, { id: "device" }]);
    assert.equal((await bare.req("/v1/auth/oidc/google/start?return_to=https://web.septena.app/auth/callback")).status, 503);
    assert.equal((await bare.req("/v1/auth/oidc/microsoft/start?return_to=https://web.septena.app/auth/callback")).status, 503);
    assert.equal((await bare.req("/v1/auth/oidc/apple/start?return_to=https://web.septena.app/auth/callback")).status, 503);
    assert.equal((await bare.req("/v1/auth/oidc/unknown/start?return_to=https://web.septena.app/auth/callback")).status, 404);

    const ec = await makeEcPkcs8Pem();
    const full = await makeHarness({
      GOOGLE_CLIENT_ID: "g-web", GOOGLE_CLIENT_SECRET: "g-sec",
      MICROSOFT_CLIENT_ID: "m-web", MICROSOFT_CLIENT_SECRET: "m-sec",
      APPLE_WEB_CLIENT_ID: "app.septena.signin", APPLE_SIGNIN_KEY_ID: "KEY1234567",
      APPLE_SIGNIN_TEAM_ID: "TEAM123456", APPLE_SIGNIN_KEY: ec.pem,
    });
    const fullBody = await (await full.req("/v1/auth/methods")).json() as { methods: { id: string; web?: boolean; native?: boolean }[] };
    assert.deepEqual(fullBody.methods, [
      { id: "apple", web: true },
      { id: "google", web: true, native: true },
      { id: "microsoft", web: true },
      { id: "email" },
      { id: "device" },
    ]);
  });

  it("enforces return_to allowlist and IP rate limits on /v1/auth/oidc/:provider/start", async () => {
    const h = await makeHarness({ GOOGLE_CLIENT_ID: "g-web", GOOGLE_CLIENT_SECRET: "g-sec" });
    for (const bad of ["", "https://evil.example/cb", "http://web.septena.app/cb", "javascript:alert(1)", "evil://auth/callback"]) {
      const r = await h.req(`/v1/auth/oidc/google/start?return_to=${encodeURIComponent(bad)}`);
      assert.equal(r.status, 400, `should reject ${bad}`);
    }
    for (const good of ["https://web.septena.app/auth/callback", "septena://auth/callback", "septask://auth/callback"]) {
      const r = await h.req(`/v1/auth/oidc/google/start?return_to=${encodeURIComponent(good)}`, {
        headers: { "CF-Connecting-IP": "198.51.100.31" },
      });
      assert.equal(r.status, 302, `should accept ${good}`);
    }
    // IP rate limit.
    const ip = { "CF-Connecting-IP": "198.51.100.32" };
    for (let i = 0; i < oidc.OIDC_START_MAX_PER_IP; i++) {
      assert.equal((await h.req("/v1/auth/oidc/google/start?return_to=https://web.septena.app/cb", { headers: ip })).status, 302);
    }
    assert.equal((await h.req("/v1/auth/oidc/google/start?return_to=https://web.septena.app/cb", { headers: ip })).status, 429);
  });

  it("completes Google OIDC with PKCE, nonce, JWKS, single-use state, cookie redeem, and collision catch", async () => {
    const rsa = await makeRsaSigner("google-kid-1");
    const h = await makeHarness({ GOOGLE_CLIENT_ID: "g-web-client", GOOGLE_CLIENT_SECRET: "g-web-secret" });
    oidc.clearOidcJwksCache();

    const startRes = await h.req("/v1/auth/oidc/google/start?return_to=https://web.septena.app/auth/callback");
    assert.equal(startRes.status, 302);
    const authUrl = new URL(startRes.headers.get("Location")!);
    assert.equal(authUrl.origin, "https://accounts.google.com");
    const state = authUrl.searchParams.get("state")!;
    const nonce = authUrl.searchParams.get("nonce")!;
    const challenge = authUrl.searchParams.get("code_challenge")!;
    assert.equal(authUrl.searchParams.get("code_challenge_method"), "S256");

    const now = Math.floor(Date.now() / 1000);
    const idToken = await rsa.sign({
      iss: "https://accounts.google.com",
      aud: "g-web-client",
      sub: "google-user-123",
      exp: now + 600,
      iat: now,
      nonce,
      email: "user@gmail.com",
      email_verified: true,
    });

    let seenVerifier = "";
    oidc.setOidcFetchForTests((async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url === "https://oauth2.googleapis.com/token") {
        const body = new URLSearchParams(String(init?.body ?? ""));
        seenVerifier = body.get("code_verifier") ?? "";
        assert.equal(body.get("client_secret"), "g-web-secret");
        return new Response(JSON.stringify({ id_token: idToken }), { status: 200 });
      }
      if (url === "https://www.googleapis.com/oauth2/v3/certs") {
        return new Response(JSON.stringify({ keys: [rsa.pubJwk] }), { status: 200 });
      }
      throw new Error(`unexpected fetch: ${url}`);
    }) as typeof fetch);

    try {
      const cb = await h.req(`/v1/auth/oidc/google/callback?code=g-code-1&state=${encodeURIComponent(state)}`);
      assert.equal(cb.status, 302);
      assert.equal(await sha256Base64Url(seenVerifier), challenge, "PKCE verifier matches S256 challenge");
      const ret = new URL(cb.headers.get("Location")!);
      assert.equal(`${ret.origin}${ret.pathname}`, "https://web.septena.app/auth/callback");
      const oidcCode = ret.searchParams.get("oidc_code")!;
      assert.ok(oidcCode);

      // Replaying the callback state is refused (single-use).
      assert.equal((await h.req(`/v1/auth/oidc/google/callback?code=g-code-1&state=${encodeURIComponent(state)}`)).status, 410);

      // Redeem in cookie mode from allowed web origin.
      const redeemed = await h.req("/v1/auth/oidc/redeem", {
        method: "POST",
        headers: { "Content-Type": "application/json", Origin: "https://web.septena.app" },
        body: JSON.stringify({ code: oidcCode, sessionMode: "cookie" }),
      });
      assert.equal(redeemed.status, 200);
      assert.match(redeemed.headers.get("Set-Cookie") ?? "", /septena_refresh=/);
      const s = await redeemed.json() as { userId: string };
      assert.equal((await h.accountStore.resolveIdentity("google", "google-user-123"))?.userId, s.userId);
      assert.equal((await h.ensureTaskStore(s.userId)).entitlements().some((e) => e.source === "trial"), true);

      // Replaying oidc_code is refused (one-shot).
      const replay = await h.req("/v1/auth/oidc/redeem", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: oidcCode }),
      });
      assert.equal(replay.status, 410);

      // Collision catch: another Google sub with verified email of an existing email account -> 409 + linkToken.
      const existingEmail = await h.accountStore.resolveOrCreateIdentity("email", "clash@example.com");
      const start2 = await h.req("/v1/auth/oidc/google/start?return_to=septena://auth/callback");
      const u2 = new URL(start2.headers.get("Location")!);
      const tok2 = await rsa.sign({
        iss: "https://accounts.google.com",
        aud: "g-web-client",
        sub: "google-clash-sub",
        exp: now + 600,
        iat: now,
        nonce: u2.searchParams.get("nonce")!,
        email: "clash@example.com",
        email_verified: true,
      });
      oidc.setOidcFetchForTests((async (input: RequestInfo | URL) => {
        const url = typeof input === "string" ? input : input.toString();
        if (url === "https://oauth2.googleapis.com/token") return new Response(JSON.stringify({ id_token: tok2 }), { status: 200 });
        return new Response(JSON.stringify({ keys: [rsa.pubJwk] }), { status: 200 });
      }) as typeof fetch);
      const cb2 = await h.req(`/v1/auth/oidc/google/callback?code=c2&state=${encodeURIComponent(u2.searchParams.get("state")!)}`);
      const code2 = new URL(cb2.headers.get("Location")!).searchParams.get("oidc_code")!;
      const clashRes = await h.req("/v1/auth/oidc/redeem", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: code2 }),
      });
      assert.equal(clashRes.status, 409);
      const clash = await clashRes.json() as { error: string; linkToken: string; provider: string };
      assert.equal(clash.error, "account_exists");
      assert.equal(clash.provider, "google");
      const finished = await h.req("/v1/auth/link/complete", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ linkToken: clash.linkToken, code: h.lastCode() }),
      });
      assert.equal(finished.status, 200);
      assert.equal(((await finished.json()) as { userId: string }).userId, existingEmail.userId);
    } finally {
      oidc.setOidcFetchForTests(null);
    }
  });

  it("verifies Microsoft common-tenant oid+tid subject and rejects mismatched tenant issuer", async () => {
    const rsa = await makeRsaSigner("ms-kid-1");
    const h = await makeHarness({ MICROSOFT_CLIENT_ID: "ms-client-id", MICROSOFT_CLIENT_SECRET: "ms-secret" });
    oidc.clearOidcJwksCache();
    const now = Math.floor(Date.now() / 1000);

    // Rejects issuer whose tenant doesn't match `tid`.
    const badIssToken = await rsa.sign({
      iss: "https://login.microsoftonline.com/other-tenant/v2.0",
      aud: "ms-client-id",
      tid: "tenant-a",
      oid: "oid-1",
      exp: now + 600,
      iat: now,
      nonce: "n1",
    });
    await assert.rejects(() => oidc.verifyMicrosoftIdToken(badIssToken, "ms-client-id", { expectedNonce: "n1", keys: [rsa.pubJwk] }), /bad issuer/);

    // Full callback stores `microsoft:h_<hash(tid:oid)>` and does not trust unverified email.
    await h.accountStore.resolveOrCreateIdentity("email", "spoof@example.com");
    const start = await h.req("/v1/auth/oidc/microsoft/start?return_to=https://web.septena.app/cb");
    const authUrl = new URL(start.headers.get("Location")!);
    const msToken = await rsa.sign({
      iss: "https://login.microsoftonline.com/tenant-123/v2.0",
      aud: "ms-client-id",
      tid: "tenant-123",
      oid: "oid-999",
      exp: now + 600,
      iat: now,
      nonce: authUrl.searchParams.get("nonce")!,
      email: "spoof@example.com", // no email_verified / xms_edov -> not trusted for collision
    });
    oidc.setOidcFetchForTests((async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url.includes("/token")) return new Response(JSON.stringify({ id_token: msToken }), { status: 200 });
      return new Response(JSON.stringify({ keys: [rsa.pubJwk] }), { status: 200 });
    }) as typeof fetch);

    try {
      const cb = await h.req(`/v1/auth/oidc/microsoft/callback?code=ms-c&state=${encodeURIComponent(authUrl.searchParams.get("state")!)}`);
      const resCode = new URL(cb.headers.get("Location")!).searchParams.get("oidc_code")!;
      const redeemed = await h.req("/v1/auth/oidc/redeem", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: resCode }),
      });
      assert.equal(redeemed.status, 200);
      const { userId } = await redeemed.json() as { userId: string };
      const row = await h.accountStore.resolveIdentity("microsoft", "tenant-123:oid-999");
      assert.equal(row?.userId, userId);
      assert.equal(row?.subject, await storedSubject("microsoft", "tenant-123:oid-999"));
    } finally {
      oidc.setOidcFetchForTests(null);
    }
  });

  it("handles Web Sign in with Apple (ES256 client_secret + POST form_post callback)", async () => {
    const rsa = await makeRsaSigner("apple-web-kid");
    const ec = await makeEcPkcs8Pem();
    const h = await makeHarness({
      APPLE_WEB_CLIENT_ID: "app.septena.signin",
      APPLE_SIGNIN_KEY_ID: "KEY9876543",
      APPLE_SIGNIN_TEAM_ID: "TEAM123456",
      APPLE_SIGNIN_KEY: ec.pem,
    });
    oidc.clearOidcJwksCache();
    const now = Math.floor(Date.now() / 1000);

    const start = await h.req("/v1/auth/oidc/apple/start?return_to=https://web.septena.app/cb");
    assert.equal(start.status, 302);
    const authUrl = new URL(start.headers.get("Location")!);
    assert.equal(authUrl.searchParams.get("response_mode"), "form_post");
    const state = authUrl.searchParams.get("state")!;
    const nonce = authUrl.searchParams.get("nonce")!;

    const appleIdToken = await rsa.sign({
      iss: "https://appleid.apple.com",
      aud: "app.septena.signin",
      sub: "apple-web-sub-1",
      exp: now + 600,
      iat: now,
      nonce,
    });

    let clientSecretJwt = "";
    oidc.setOidcFetchForTests((async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url === "https://appleid.apple.com/auth/token") {
        const body = new URLSearchParams(String(init?.body ?? ""));
        clientSecretJwt = body.get("client_secret") ?? "";
        return new Response(JSON.stringify({ id_token: appleIdToken }), { status: 200 });
      }
      if (url === "https://appleid.apple.com/auth/keys") {
        return new Response(JSON.stringify({ keys: [rsa.pubJwk] }), { status: 200 });
      }
      throw new Error(`unexpected fetch: ${url}`);
    }) as typeof fetch);

    try {
      const cb = await h.req("/v1/auth/oidc/apple/callback", {
        method: "POST",
        body: new URLSearchParams({ code: "apple-code-1", state }),
      });
      assert.equal(cb.status, 302);
      assert.equal(clientSecretJwt.split(".").length, 3);
      const secretPayload = JSON.parse(Buffer.from(clientSecretJwt.split(".")[1], "base64url").toString()) as { iss: string; sub: string; aud: string };
      assert.equal(secretPayload.iss, "TEAM123456");
      assert.equal(secretPayload.sub, "app.septena.signin");
      assert.equal(secretPayload.aud, "https://appleid.apple.com");

      const code = new URL(cb.headers.get("Location")!).searchParams.get("oidc_code")!;
      const redeemed = await h.req("/v1/auth/oidc/redeem", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code }),
      });
      assert.equal(redeemed.status, 200);
      const { userId } = await redeemed.json() as { userId: string };
      assert.equal((await h.accountStore.resolveIdentity("apple", "apple-web-sub-1"))?.userId, userId);
    } finally {
      oidc.setOidcFetchForTests(null);
    }
  });

  it("supports native Android Google sign-in, Settings OIDC linking, and OIDC approval on the MCP connector page", async () => {
    const rsa = await makeRsaSigner("google-kid-2");
    const h = await makeHarness({
      GOOGLE_CLIENT_ID: "g-web-2",
      GOOGLE_CLIENT_SECRET: "g-sec-2",
      GOOGLE_ANDROID_CLIENT_ID: "g-android-2",
    });
    oidc.clearOidcJwksCache();
    const now = Math.floor(Date.now() / 1000);

    // 1. Native Android Google sign-in.
    const nativeTok = await rsa.sign({
      iss: "https://accounts.google.com",
      aud: "g-android-2",
      sub: "g-native-sub-1",
      exp: now + 600,
      iat: now,
      nonce: "android-nonce-123456",
      email: "android@gmail.com",
      email_verified: true,
    });
    oidc.setOidcFetchForTests((async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input.toString();
      if (url === "https://www.googleapis.com/oauth2/v3/certs") {
        return new Response(JSON.stringify({ keys: [rsa.pubJwk] }), { status: 200 });
      }
      throw new Error(`unexpected fetch: ${url}`);
    }) as typeof fetch);

    try {
      const nativeRes = await h.req("/v1/auth/google/native", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ idToken: nativeTok, nonce: "android-nonce-123456" }),
      });
      assert.equal(nativeRes.status, 200);
      const nativeSession = await nativeRes.json() as { accessToken: string; userId: string };
      assert.equal((await h.accountStore.resolveIdentity("google", "g-native-sub-1"))?.userId, nativeSession.userId);

      // Wrong nonce is rejected with 401.
      const badNonce = await h.req("/v1/auth/google/native", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ idToken: nativeTok, nonce: "wrong-nonce-12345678" }),
      });
      assert.equal(badNonce.status, 401);

      // 2. Link a second Google account via OIDC Settings link flow (verified by matching Bearer token).
      const linkStart = await h.req("/v1/auth/link/oidc/start", {
        method: "POST",
        headers: { Authorization: `Bearer ${nativeSession.accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ provider: "google", returnTo: "https://web.septena.app/settings" }),
      });
      assert.equal(linkStart.status, 200);
      const { url: startUrl } = await linkStart.json() as { url: string };
      const redir = await h.req(new URL(startUrl).pathname + new URL(startUrl).search);
      const gUrl = new URL(redir.headers.get("Location")!);
      const linkIdTok = await rsa.sign({
        iss: "https://accounts.google.com",
        aud: "g-web-2",
        sub: "g-linked-sub-2",
        exp: now + 600,
        iat: now,
        nonce: gUrl.searchParams.get("nonce")!,
      });
      oidc.setOidcFetchForTests((async (input: RequestInfo | URL) => {
        const u = typeof input === "string" ? input : input.toString();
        if (u === "https://oauth2.googleapis.com/token") return new Response(JSON.stringify({ id_token: linkIdTok }), { status: 200 });
        return new Response(JSON.stringify({ keys: [rsa.pubJwk] }), { status: 200 });
      }) as typeof fetch);
      const linkCb = await h.req(`/v1/auth/oidc/google/callback?code=lc&state=${encodeURIComponent(gUrl.searchParams.get("state")!)}`);
      const linkResCode = new URL(linkCb.headers.get("Location")!).searchParams.get("oidc_code")!;

      // Redeem without Bearer fails 401, with right Bearer succeeds 200.
      assert.equal((await h.req("/v1/auth/oidc/redeem", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ code: linkResCode }),
      })).status, 401);

      // Re-run link flow and redeem with Bearer.
      const redir2 = await h.req(new URL(startUrl).pathname + new URL(startUrl).search);
      const gUrl2 = new URL(redir2.headers.get("Location")!);
      const linkIdTok2 = await rsa.sign({
        iss: "https://accounts.google.com", aud: "g-web-2", sub: "g-linked-sub-2", exp: now + 600, iat: now, nonce: gUrl2.searchParams.get("nonce")!,
      });
      oidc.setOidcFetchForTests((async (input: RequestInfo | URL) => {
        const u = typeof input === "string" ? input : input.toString();
        if (u === "https://oauth2.googleapis.com/token") return new Response(JSON.stringify({ id_token: linkIdTok2 }), { status: 200 });
        return new Response(JSON.stringify({ keys: [rsa.pubJwk] }), { status: 200 });
      }) as typeof fetch);
      const linkCb2 = await h.req(`/v1/auth/oidc/google/callback?code=lc2&state=${encodeURIComponent(gUrl2.searchParams.get("state")!)}`);
      const linkResCode2 = new URL(linkCb2.headers.get("Location")!).searchParams.get("oidc_code")!;
      const linked = await h.req("/v1/auth/oidc/redeem", {
        method: "POST",
        headers: { Authorization: `Bearer ${nativeSession.accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ code: linkResCode2 }),
      });
      assert.equal(linked.status, 200);
      assert.equal(((await linked.json()) as { identities: unknown[] }).identities.length, 2);

      // 3. Connector authorize page OIDC creates an agent-first account and mints MCP tokens without an app session.
      await h.clients.put("v2:client:c1", JSON.stringify({ id: "c1", name: "Claude", redirectUris: ["https://claude.ai/api/mcp/auth_callback"] }));
      const pkceVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
      const pkceChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
      const authPage = await h.req(`/oauth/authorize?response_type=code&client_id=c1&redirect_uri=${encodeURIComponent("https://claude.ai/api/mcp/auth_callback")}&state=st1&code_challenge=${pkceChallenge}&code_challenge_method=S256`);
      const html = await authPage.text();
      assert.match(html, /\/oauth\/pair\/oidc\/google/);
      const cookie = (authPage.headers.get("Set-Cookie") ?? "").split(";")[0];

      const pairStart = await h.req("/oauth/pair/oidc/google", { headers: { Cookie: cookie } });
      assert.equal(pairStart.status, 302);
      const pUrl = new URL(pairStart.headers.get("Location")!);
      const connIdTok = await rsa.sign({
        iss: "https://accounts.google.com", aud: "g-web-2", sub: "g-connector-sub-1", exp: now + 600, iat: now, nonce: pUrl.searchParams.get("nonce")!,
      });
      oidc.setOidcFetchForTests((async (input: RequestInfo | URL) => {
        const u = typeof input === "string" ? input : input.toString();
        if (u === "https://oauth2.googleapis.com/token") return new Response(JSON.stringify({ id_token: connIdTok }), { status: 200 });
        return new Response(JSON.stringify({ keys: [rsa.pubJwk] }), { status: 200 });
      }) as typeof fetch);

      const pairCb = await h.req(`/v1/auth/oidc/google/callback?code=cc&state=${encodeURIComponent(pUrl.searchParams.get("state")!)}`);
      assert.equal(pairCb.status, 302);
      assert.equal(pairCb.headers.get("Location"), "/oauth/pair/continue");

      const cont = await h.req("/oauth/pair/continue", { headers: { Cookie: cookie } });
      assert.equal(cont.status, 302);
      const authCode = new URL(cont.headers.get("Location")!).searchParams.get("code")!;

      const tokRes = await h.req("/oauth/token", {
        method: "POST",
        body: new URLSearchParams({
          grant_type: "authorization_code",
          code: authCode,
          code_verifier: pkceVerifier,
          redirect_uri: "https://claude.ai/api/mcp/auth_callback",
          client_id: "c1",
        }),
      });
      assert.equal(tokRes.status, 200);
      const tokens = await tokRes.json() as { access_token: string };
      assert.match(tokens.access_token, /^sm2\./);
      const grant = await verifyMcpAccess(h.env, tokens.access_token);
      assert.ok(grant);
      assert.equal((await h.ensureTaskStore(grant.userId)).hasAppSession(), false);
    } finally {
      oidc.setOidcFetchForTests(null);
    }
  });
});
