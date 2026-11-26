import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestAccountStore, createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// ADR 0047 decisions 5 & 6 (#171, #643): account identity listing, linking,
// unlinking (refusing the last method), and no-silent-linking collision catch.

const { api } = await import("../src/api/routes.ts");
const { base64url } = await import("../src/util.ts");
const { issueSession, verifyAccessToken } = await import("../src/api/session.ts");
const { createAgentKey, MCP_READ_SCOPE, MCP_WRITE_SCOPE } = await import("../src/shadow/tokens.ts");
const { storedSubject } = await import("../src/store/AccountStore.ts");

const TEST_SIGNING_KEY = Buffer.alloc(32, 11).toString("base64");
const EXEC_CTX = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";

function makeMemoryKv() {
  const map = new Map<string, string>();
  return {
    map,
    async get(key: string) { return map.get(key) ?? null; },
    async put(key: string, value: string) { map.set(key, value); },
    async delete(key: string) { map.delete(key); },
  };
}

async function sha256Hex(input: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input)));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function makeAppleSigner(kid = "apple-link-test-key") {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const pubJwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid, use: "sig", alg: "RS256" };

  async function signToken(
    sub: string,
    rawNonce: string,
    extra: Record<string, unknown> = {},
    aud = "com.septena.tasks",
  ): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    const enc = new TextEncoder();
    const h = base64url(enc.encode(JSON.stringify({ alg: "RS256", kid })));
    const p = base64url(enc.encode(JSON.stringify({
      iss: "https://appleid.apple.com",
      aud,
      exp: now + 600,
      iat: now,
      sub,
      nonce: await sha256Hex(rawNonce),
      ...extra,
    })));
    const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, enc.encode(`${h}.${p}`)));
    return `${h}.${p}.${base64url(sig)}`;
  }

  async function withAppleJwks<T>(fn: () => Promise<T>): Promise<T> {
    const orig = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      if (url === APPLE_KEYS_URL) {
        return new Response(JSON.stringify({ keys: [pubJwk] }), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      return orig(input, init);
    }) as typeof fetch;
    try {
      return await fn();
    } finally {
      globalThis.fetch = orig;
    }
  }

  return { signToken, withAppleJwks };
}

async function makeHarness(opts: { emailEnabled?: boolean } = {}) {
  const taskStores = new Map<string, Awaited<ReturnType<typeof createTestTaskStore>>["store"]>();
  const ensureTaskStore = async (userId: string) => {
    let s = taskStores.get(userId);
    if (!s) { s = (await createTestTaskStore()).store; taskStores.set(userId, s); }
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
    EMAIL_SIGNIN: opts.emailEnabled === false ? "false" : "true",
    EMAIL: {
      async send(m: { to: string; subject: string; text: string }) {
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

  const call = (method: string, path: string, body?: unknown, headers: Record<string, string> = {}) =>
    api.fetch(new Request(`https://api.septena.app${path}`, {
      method,
      headers: {
        ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
        "CF-Connecting-IP": "198.51.100.12",
        ...headers,
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    }), env, EXEC_CTX);

  const lastCode = () => /(\d{6})/.exec(sent.at(-1)!.text)![1];
  return { env, sent, accountStore, ensureTaskStore, call, lastCode };
}

describe("account identity linking & management (ADR 0047, #171, #643)", () => {
  it("lets an email/agent account link Apple in Settings, sign in with Apple later, and refuses removing the last method", async () => {
    const h = await makeHarness();
    const signer = await makeAppleSigner("link-key-1");

    // 1. Account starts with email (as created by an agent or email sign-in).
    await h.call("POST", "/auth/email/start", { email: "alex@example.com" });
    const s1 = await (await h.call("POST", "/auth/email/verify", { email: "alex@example.com", code: h.lastCode() })).json() as {
      accessToken: string; userId: string;
    };
    const auth = { Authorization: `Bearer ${s1.accessToken}` };

    // 2. List identities: shows email only, canRemove = false.
    const list1 = await (await h.call("GET", "/auth/identities", undefined, auth)).json() as {
      identities: { id: string; provider: string; label: string }[]; canRemove: boolean;
    };
    assert.equal(list1.identities.length, 1);
    assert.equal(list1.identities[0].provider, "email");
    assert.equal(list1.identities[0].label, "alex@example.com");
    assert.equal(list1.canRemove, false);

    // Trying to remove the only method fails with 409 last_method.
    const cantDrop = await h.call("DELETE", `/auth/identities/${encodeURIComponent(list1.identities[0].id)}`, undefined, auth);
    assert.equal(cantDrop.status, 409);
    assert.deepEqual(await cantDrop.json(), { error: "last_method" });

    // 3. Link Apple ID to the signed-in email account.
    const appleSub = "009999.agent-user-apple-sub.0001";
    await signer.withAppleJwks(async () => {
      const nonce = "nonce-link-apple-123456";
      const token = await signer.signToken(appleSub, nonce);
      const linkRes = await h.call("POST", "/auth/link/apple", { identityToken: token, nonce }, auth);
      assert.equal(linkRes.status, 200);
      const linked = await linkRes.json() as {
        ok: boolean; created: boolean; identities: { id: string; provider: string; label: string }[]; canRemove: boolean;
      };
      assert.equal(linked.ok, true);
      assert.equal(linked.created, true);
      assert.equal(linked.identities.length, 2);
      assert.equal(linked.canRemove, true);
      const appleRow = linked.identities.find((i) => i.provider === "apple")!;
      assert.equal(appleRow.label, "Apple");
      assert.equal(appleRow.id, `apple:${await storedSubject("apple", appleSub)}`);

      // 4. Subsequent native Sign in with Apple lands on the SAME account (s1.userId), NOT a new derived id.
      const nonce2 = "nonce-signin-after-link-123";
      const signInRes = await h.call("POST", "/auth/apple", {
        identityToken: await signer.signToken(appleSub, nonce2),
        nonce: nonce2,
      });
      assert.equal(signInRes.status, 200);
      const s2 = await signInRes.json() as { accessToken: string; userId: string };
      assert.equal(s2.userId, s1.userId);
      assert.equal((await verifyAccessToken(h.env, s2.accessToken))?.userId, s1.userId);

      // 5. Removing email leaves Apple as the sole method (canRemove = false), and removing Apple is refused.
      const rmEmail = await h.call("DELETE", `/auth/identities/${encodeURIComponent("email:alex@example.com")}`, undefined, auth);
      assert.equal(rmEmail.status, 200);
      const afterRm = await rmEmail.json() as { identities: { id: string; provider: string }[]; canRemove: boolean };
      assert.equal(afterRm.identities.length, 1);
      assert.equal(afterRm.identities[0].provider, "apple");
      assert.equal(afterRm.canRemove, false);

      const rmLast = await h.call("DELETE", `/auth/identities/${encodeURIComponent(appleRow.id)}`, undefined, auth);
      assert.equal(rmLast.status, 409);
      assert.deepEqual(await rmLast.json(), { error: "last_method" });
    });
  });

  it("lets an Apple account link an email, refuses linking an email owned by another account, and blocks agent keys", async () => {
    const h = await makeHarness();
    const signer = await makeAppleSigner("link-key-2");

    await signer.withAppleJwks(async () => {
      const n1 = "nonce-apple-owner-123456";
      const sApple = await (await h.call("POST", "/auth/apple", {
        identityToken: await signer.signToken("sub-apple-1", n1), nonce: n1,
      })).json() as { accessToken: string; userId: string };

      // Another account owns taken@example.com.
      await h.call("POST", "/auth/email/start", { email: "taken@example.com" });
      await h.call("POST", "/auth/email/verify", { email: "taken@example.com", code: h.lastCode() });

      // Apple user adds recovery@example.com.
      const auth = { Authorization: `Bearer ${sApple.accessToken}` };
      assert.equal((await h.call("POST", "/auth/link/email/start", { email: "recovery@example.com" }, auth)).status, 202);
      const added = await h.call("POST", "/auth/link/email/verify", { email: "recovery@example.com", code: h.lastCode() }, auth);
      assert.equal(added.status, 200);
      assert.equal(((await added.json()) as { identities: unknown[] }).identities.length, 2);

      // Apple user tries to link taken@example.com -> 409 already_linked.
      await h.call("POST", "/auth/link/email/start", { email: "taken@example.com" }, auth);
      const clash = await h.call("POST", "/auth/link/email/verify", { email: "taken@example.com", code: h.lastCode() }, auth);
      assert.equal(clash.status, 409);
      assert.deepEqual(await clash.json(), { error: "already_linked" });

      // Agent keys cannot list, add, or remove sign-in methods.
      const agent = await createAgentKey(h.env, sApple.userId, "Bot", `${MCP_READ_SCOPE} ${MCP_WRITE_SCOPE}`);
      const agentAuth = { Authorization: `Bearer ${agent.key}` };
      assert.equal((await h.call("GET", "/auth/identities", undefined, agentAuth)).status, 401);
      assert.equal((await h.call("POST", "/auth/link/email/start", { email: "x@example.com" }, agentAuth)).status, 401);
      assert.equal((await h.call("DELETE", `/auth/identities/${encodeURIComponent("email:recovery@example.com")}`, undefined, agentAuth)).status, 401);
    });
  });

  it("enforces no silent linking on Sign in with Apple when verified email matches an existing account, and completes via email code", async () => {
    const h = await makeHarness();
    const signer = await makeAppleSigner("link-key-3");

    // Existing account created via email (e.g. agent signup).
    await h.call("POST", "/auth/email/start", { email: "alex@example.com" });
    const emailSession = await (await h.call("POST", "/auth/email/verify", { email: "alex@example.com", code: h.lastCode() })).json() as {
      userId: string;
    };

    await signer.withAppleJwks(async () => {
      const nonce = "nonce-apple-collision-1234";
      const appleSub = "008888.apple-collision-sub.0001";
      const token = await signer.signToken(appleSub, nonce, { email: "alex@example.com", email_verified: "true" });

      const collision = await h.call("POST", "/auth/apple", { identityToken: token, nonce });
      assert.equal(collision.status, 409);
      const body = await collision.json() as { error: string; email: string; provider: string; linkToken: string; codeSent: boolean };
      assert.equal(body.error, "account_exists");
      assert.equal(body.email, "alex@example.com");
      assert.equal(body.provider, "apple");
      assert.equal(body.codeSent, true);
      assert.match(body.linkToken, /^sl1\./);

      // No duplicate account was created!
      assert.equal(await h.accountStore.resolveIdentity("apple", appleSub), null);

      // Wrong code is rejected.
      const code = h.lastCode();
      const wrong = code === "000000" ? "111111" : "000000";
      assert.equal((await h.call("POST", "/auth/link/complete", { linkToken: body.linkToken, code: wrong })).status, 401);

      // Right code signs in to the EXISTING account and links Apple to it.
      const done = await h.call("POST", "/auth/link/complete", { linkToken: body.linkToken, code });
      assert.equal(done.status, 200);
      const completed = await done.json() as { accessToken: string; userId: string };
      assert.equal(completed.userId, emailSession.userId);
      const appleRow = await h.accountStore.resolveIdentity("apple", appleSub);
      assert.equal(appleRow?.userId, emailSession.userId);

      // Next Apple sign-in works directly with 200 (no collision anymore).
      const nonce2 = "nonce-apple-after-complete-12";
      const direct = await h.call("POST", "/auth/apple", {
        identityToken: await signer.signToken(appleSub, nonce2, { email: "alex@example.com", email_verified: true }),
        nonce: nonce2,
      });
      assert.equal(direct.status, 200);
      assert.equal(((await direct.json()) as { userId: string }).userId, emailSession.userId);
    });
  });

  it("supports cookie mode on /auth/link/complete and refuses foreign origins", async () => {
    const h = await makeHarness();
    const signer = await makeAppleSigner("link-key-4");

    await h.call("POST", "/auth/email/start", { email: "web@example.com" });
    await h.call("POST", "/auth/email/verify", { email: "web@example.com", code: h.lastCode() });

    await signer.withAppleJwks(async () => {
      const nonce = "nonce-web-collision-12345";
      const token = await signer.signToken("sub-web-1", nonce, { email: "web@example.com", email_verified: true });
      const { linkToken } = await (await h.call("POST", "/auth/apple", { identityToken: token, nonce })).json() as { linkToken: string };
      const code = h.lastCode();

      const badOrigin = await h.call("POST", "/auth/link/complete", { linkToken, code, sessionMode: "cookie" }, { Origin: "https://evil.example" });
      assert.equal(badOrigin.status, 403);

      const goodOrigin = await h.call("POST", "/auth/link/complete", { linkToken, code, sessionMode: "cookie" }, { Origin: "https://web.septena.app" });
      assert.equal(goodOrigin.status, 200);
      assert.match(goodOrigin.headers.get("Set-Cookie") ?? "", /septena_refresh=/);
    });
  });

  it("never collides on unverified email claims and still blocks duplicate creation when email sign-in is off", async () => {
    const h = await makeHarness({ emailEnabled: false });
    const signer = await makeAppleSigner("link-key-5");
    // Pre-existing email identity from earlier.
    const existing = await h.accountStore.resolveOrCreateIdentity("email", "pre@example.com");
    await issueSession(h.env, existing.userId);

    await signer.withAppleJwks(async () => {
      // Verified email collides -> 409 account_exists (without linkToken since email is off).
      const n1 = "nonce-email-off-collision1";
      const r1 = await h.call("POST", "/auth/apple", {
        identityToken: await signer.signToken("sub-off-1", n1, { email: "pre@example.com", email_verified: true }),
        nonce: n1,
      });
      assert.equal(r1.status, 409);
      const b1 = await r1.json() as { error: string; linkToken?: string };
      assert.equal(b1.error, "account_exists");
      assert.equal(b1.linkToken, undefined);

      // Unverified email does NOT collide.
      const n2 = "nonce-unverified-email-123";
      const r2 = await h.call("POST", "/auth/apple", {
        identityToken: await signer.signToken("sub-unverified-1", n2, { email: "pre@example.com", email_verified: false }),
        nonce: n2,
      });
      assert.equal(r2.status, 200);
    });
  });
});
