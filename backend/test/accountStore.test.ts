import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestAccountStore, createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Sign-in S1: AccountStore global identity table (ADR 0016, issue #168).

const {
  GLOBAL_ACCOUNT_STORE_NAME,
  USER_ID_RE,
  identityKey,
  newUserId,
} = await import("../src/store/AccountStore.ts");
const { userIdForAppleSub } = await import("../src/api/appleIdentity.ts");
const { api } = await import("../src/api/routes.ts");
const { signAccessToken } = await import("../src/api/session.ts");
const ent = await import("../src/entitlement/entitlement.ts");
const { base64url } = await import("../src/util.ts");

const TEST_SIGNING_KEY = Buffer.alloc(32, 9).toString("base64");
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

function makeMemoryR2() {
  const map = new Map<string, Uint8Array>();
  return {
    map,
    async list({ prefix }: { prefix?: string; cursor?: string } = {}) {
      const objects = [...map.keys()]
        .filter((k) => !prefix || k.startsWith(prefix))
        .map((key) => ({ key }));
      return { objects, truncated: false, cursor: undefined };
    },
    async put(key: string, body: unknown) {
      map.set(key, body instanceof Uint8Array ? body : new Uint8Array());
    },
    async get(key: string) {
      const v = map.get(key);
      return v ? { body: v, size: v.byteLength } : null;
    },
    async delete(keys: string | string[]) {
      for (const k of Array.isArray(keys) ? keys : [keys]) map.delete(k);
    },
  };
}

async function sha256Hex(input: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input)));
  return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function makeAppleSigner(kid = "test-apple-key-1") {
  const pair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const publicJwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid };

  async function signToken(sub: string, rawNonce: string, aud = "com.septena.tasks"): Promise<string> {
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
    })));
    const sig = new Uint8Array(
      await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, enc.encode(`${h}.${p}`)),
    );
    return `${h}.${p}.${base64url(sig)}`;
  }

  async function withAppleJwks<T>(fn: () => Promise<T>): Promise<T> {
    const origFetch = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      if (url === APPLE_KEYS_URL) {
        return new Response(JSON.stringify({ keys: [publicJwk] }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      return origFetch(input, init);
    }) as typeof fetch;
    try {
      return await fn();
    } finally {
      globalThis.fetch = origFetch;
    }
  }

  return { signToken, withAppleJwks };
}

async function makeRouteHarness(opts: { bindAccountStore?: boolean } = {}) {
  const tokens = makeMemoryKv();
  const attachments = makeMemoryR2();
  const taskStores = new Map<string, Awaited<ReturnType<typeof createTestTaskStore>>["store"]>();
  const ensureTaskStore = async (userId: string) => {
    let s = taskStores.get(userId);
    if (!s) {
      s = (await createTestTaskStore()).store;
      taskStores.set(userId, s);
    }
    return s;
  };
  const { store: accountStore, db: accountDb } = await createTestAccountStore();
  const accountStoreIdsSeen: string[] = [];

  const env = {
    API_PUBLIC_URL: "https://api.septena.app",
    APPLE_AUDIENCES: "com.septena.tasks,com.septena.tasks.mac",
    ENTITLEMENT_ENFORCE: "true",
    APPLE_IAP_BUNDLE_IDS: "com.septena.tasks",
    APPLE_IAP_ENVIRONMENTS: "Production,Sandbox",
    SESSION_SIGNING_KEY: TEST_SIGNING_KEY,
    TOKENS: tokens,
    STATE: makeMemoryKv(),
    CLIENTS: makeMemoryKv(),
    ATTACHMENTS: attachments,
    TASK_STORE: {
      idFromName(name: string) { return name; },
      get(id: string) {
        return new Proxy({}, {
          get(_t, prop: string) {
            return async (...args: unknown[]) => {
              const s = await ensureTaskStore(id);
              if (prop === "deleteAccount") {
                await s.deleteAccount();
                taskStores.delete(id);
                return;
              }
              return (s as unknown as Record<string, (...a: unknown[]) => unknown>)[prop](...args);
            };
          },
        });
      },
    },
    ...(opts.bindAccountStore === false
      ? {}
      : {
          ACCOUNT_STORE: {
            idFromName(name: string) {
              accountStoreIdsSeen.push(name);
              return name;
            },
            get(_id: string) {
              return new Proxy({}, {
                get(_t, prop: string) {
                  return async (...args: unknown[]) =>
                    (accountStore as unknown as Record<string, (...a: unknown[]) => unknown>)[prop](...args);
                },
              });
            },
          },
        }),
  } as never;

  return {
    env,
    tokens,
    attachments,
    accountStore,
    accountDb,
    accountStoreIdsSeen,
    ensureTaskStore,
    async authHeader(userId: string, sid: string) {
      return `Bearer ${await signAccessToken(env, userId, sid)}`;
    },
  };
}

describe("AccountStore identity table", () => {
  it("mints random u_ userIds matching the admin regex for non-Apple providers", async () => {
    const generated = new Set<string>();
    for (let i = 0; i < 20; i++) {
      const id = newUserId();
      assert.match(id, USER_ID_RE);
      generated.add(id);
    }
    assert.equal(generated.size, 20, "each call mints a distinct random u_ id");
  });

  it("creates non-Apple identities with random u_ ids and resolves idempotently", async () => {
    const { store } = await createTestAccountStore();
    const t1 = 1_700_000_000_000;
    const t2 = t1 + 60_000;

    const first = store.resolveOrCreateIdentity("email", "Alice@Example.COM", undefined, t1);
    assert.equal(first.created, true);
    assert.match(first.userId, USER_ID_RE);
    assert.equal(first.row.key, "email:alice@example.com");
    assert.equal(first.row.provider, "email");
    assert.equal(first.row.subject, "alice@example.com");
    assert.equal(first.row.createdAt, t1);
    assert.equal(first.row.updatedAt, t1);

    // Subsequent lookup with different whitespace/casing resolves to the exact same userId.
    const second = store.resolveOrCreateIdentity("email", "  alice@example.com ", undefined, t2);
    assert.equal(second.created, false);
    assert.equal(second.userId, first.userId);
    assert.equal(second.row.createdAt, t1);
    assert.equal(second.row.updatedAt, t2);

    const readBack = store.resolveIdentity("email", "ALICE@example.com");
    assert.deepEqual(readBack, second.row);

    // Another email address gets its own distinct random u_ id.
    const bob = store.resolveOrCreateIdentity("email", "bob@example.com", undefined, t2);
    assert.equal(bob.created, true);
    assert.match(bob.userId, USER_ID_RE);
    assert.notEqual(bob.userId, first.userId);
  });

  it("links additional identities to an account without allowing hijacking", async () => {
    const { store } = await createTestAccountStore();
    const appleUserId = await userIdForAppleSub("000123.abcdef.4567");
    const otherUserId = newUserId();

    store.resolveOrCreateIdentity("apple", "000123.abcdef.4567", appleUserId, 1_000);
    const linked = store.linkIdentity("email", "Recovery@Example.com", appleUserId, 2_000);
    assert.equal(linked.ok, true);
    if (linked.ok) {
      assert.equal(linked.created, true);
      assert.equal(linked.row.key, "email:recovery@example.com");
      assert.equal(linked.row.userId, appleUserId);
    }

    // Re-linking the same identity to the same user is idempotent.
    const relinked = store.linkIdentity("email", "recovery@example.com", appleUserId, 3_000);
    assert.equal(relinked.ok, true);
    if (relinked.ok) {
      assert.equal(relinked.created, false);
      assert.equal(relinked.row.updatedAt, 3_000);
    }

    // Another account cannot claim an identity already belonging to appleUserId.
    const conflict = store.linkIdentity("email", "recovery@example.com", otherUserId, 4_000);
    assert.deepEqual(conflict, { ok: false, reason: "already_linked" });
    assert.equal(store.resolveIdentity("email", "recovery@example.com")?.userId, appleUserId);

    assert.deepEqual(
      store.listIdentitiesForUser(appleUserId).map((r) => r.key),
      ["apple:000123.abcdef.4567", "email:recovery@example.com"],
    );
  });

  it("persists identity rows across DO restarts and validates inputs", async () => {
    const { store, db } = await createTestAccountStore();
    const created = store.resolveOrCreateIdentity("email", "persist@example.com", undefined, 5_000);

    // Re-open AccountStore on the same SQLite database (simulates DO eviction + restart).
    const { store: reopened } = await createTestAccountStore(db);
    assert.equal(reopened.resolveIdentity("email", "persist@example.com")?.userId, created.userId);

    assert.equal(identityKey("Apple", "  sub-123  "), "apple:sub-123");
    assert.throws(() => identityKey("bad provider!", "x"));
    assert.throws(() => identityKey("email", "   "));
    assert.throws(() => reopened.resolveOrCreateIdentity("apple", "sub-1", "not_a_valid_user_id"));
    assert.throws(() => reopened.linkIdentity("email", "x@y.com", "short"));
  });
});

describe("auth and account deletion routes with AccountStore", () => {
  it("POST /v1/auth/apple keeps the derived userId, writes apple:<sub>, and resolves re-sign-in cleanly", async () => {
    const h = await makeRouteHarness();
    const signer = await makeAppleSigner("apple-s1-key-1");
    const sub = "001999.apple-sub-existing-user.0001";
    const expectedUserId = await userIdForAppleSub(sub);
    assert.match(expectedUserId, USER_ID_RE);

    await signer.withAppleJwks(async () => {
      const nonce1 = "nonce-first-signin-123456";
      const token1 = await signer.signToken(sub, nonce1);
      const res1 = await api.fetch(new Request("https://api.septena.app/auth/apple", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ identityToken: token1, nonce: nonce1 }),
      }), h.env, EXEC_CTX);
      assert.equal(res1.status, 200);
      const body1 = await res1.json() as { userId: string; accessToken: string; refreshToken: string };
      assert.equal(body1.userId, expectedUserId, "keeps the exact derived u_ userId for Apple accounts");

      // Identity row is written in the global AccountStore DO.
      assert.deepEqual(h.accountStoreIdsSeen, [GLOBAL_ACCOUNT_STORE_NAME]);
      const row1 = h.accountStore.resolveIdentity("apple", sub);
      assert.ok(row1, "apple:<sub> row exists in AccountStore");
      assert.equal(row1.key, `apple:${sub}`);
      assert.equal(row1.userId, expectedUserId);

      // Re-signing in with the same apple:<sub> resolves to the exact same userId with one row.
      const nonce2 = "nonce-second-signin-654321";
      const token2 = await signer.signToken(sub, nonce2);
      const res2 = await api.fetch(new Request("https://api.septena.app/auth/apple", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ identityToken: token2, nonce: nonce2 }),
      }), h.env, EXEC_CTX);
      assert.equal(res2.status, 200);
      const body2 = await res2.json() as { userId: string };
      assert.equal(body2.userId, expectedUserId);

      const rows = h.accountStore.listIdentitiesForUser(expectedUserId);
      assert.equal(rows.length, 1);
      assert.equal(rows[0].key, `apple:${sub}`);
      assert.equal(rows[0].createdAt, row1.createdAt);
      assert.ok(rows[0].updatedAt >= row1.updatedAt);
    });
  });

  it("POST /v1/auth/apple still works gracefully when ACCOUNT_STORE is unbound", async () => {
    const h = await makeRouteHarness({ bindAccountStore: false });
    const signer = await makeAppleSigner("apple-s1-key-unbound");
    const sub = "002222.apple-sub-unbound.0002";
    const expectedUserId = await userIdForAppleSub(sub);

    await signer.withAppleJwks(async () => {
      const nonce = "nonce-unbound-test-123456";
      const token = await signer.signToken(sub, nonce);
      const res = await api.fetch(new Request("https://api.septena.app/auth/apple", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ identityToken: token, nonce }),
      }), h.env, EXEC_CTX);
      assert.equal(res.status, 200);
      const body = await res.json() as { userId: string };
      assert.equal(body.userId, expectedUserId);
    });
  });

  it("DELETE /v1/account deletes all identity rows for that user without touching other users or trial-used", async () => {
    const h = await makeRouteHarness();
    const signer = await makeAppleSigner("apple-s1-key-delete");
    const subA = "003333.apple-user-a.0003";
    const subB = "004444.apple-user-b.0004";
    const userA = await userIdForAppleSub(subA);
    const userB = await userIdForAppleSub(subB);

    await signer.withAppleJwks(async () => {
      // Sign in both User A and User B via Apple (starts User A's reverse trial + writes trial-used:<userA>).
      const resA = await api.fetch(new Request("https://api.septena.app/auth/apple", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          identityToken: await signer.signToken(subA, "nonce-user-a-123456"),
          nonce: "nonce-user-a-123456",
        }),
      }), h.env, EXEC_CTX);
      assert.equal(resA.status, 200);

      const resB = await api.fetch(new Request("https://api.septena.app/auth/apple", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          identityToken: await signer.signToken(subB, "nonce-user-b-123456"),
          nonce: "nonce-user-b-123456",
        }),
      }), h.env, EXEC_CTX);
      assert.equal(resB.status, 200);

      // Attach secondary email identities to both users so we prove ALL rows for userA are wiped.
      assert.equal(h.accountStore.linkIdentity("email", "a@example.com", userA).ok, true);
      assert.equal(h.accountStore.linkIdentity("email", "b@example.com", userB).ok, true);
      assert.equal(h.accountStore.listIdentitiesForUser(userA).length, 2);
      assert.equal(h.accountStore.listIdentitiesForUser(userB).length, 2);
      assert.equal(h.tokens.map.get(ent.trialUsedKey(userA)), "1");

      // Delete User A's account.
      const delRes = await api.fetch(new Request("https://api.septena.app/account", {
        method: "DELETE",
        headers: { Authorization: await h.authHeader(userA, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa") },
      }), h.env, EXEC_CTX);
      assert.equal(delRes.status, 204);

      // All of User A's identity rows are gone.
      assert.deepEqual(h.accountStore.listIdentitiesForUser(userA), []);
      assert.equal(h.accountStore.resolveIdentity("apple", subA), null);
      assert.equal(h.accountStore.resolveIdentity("email", "a@example.com"), null);

      // User B's identity rows are completely untouched.
      assert.deepEqual(
        h.accountStore.listIdentitiesForUser(userB).map((r) => r.key),
        [`apple:${subB}`, "email:b@example.com"],
      );

      // #262's trial-used:<userId> KV marker survives account deletion.
      assert.equal(h.tokens.map.get(ent.trialUsedKey(userA)), "1");

      // Re-signing in as User A re-creates the apple:<sub> row with the same derived userId
      // and does NOT grant a second trial.
      const reSignRes = await api.fetch(new Request("https://api.septena.app/auth/apple", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          identityToken: await signer.signToken(subA, "nonce-user-a-resign-789"),
          nonce: "nonce-user-a-resign-789",
        }),
      }), h.env, EXEC_CTX);
      assert.equal(reSignRes.status, 200);
      const reSignBody = await reSignRes.json() as { userId: string };
      assert.equal(reSignBody.userId, userA);
      assert.equal(h.accountStore.resolveIdentity("apple", subA)?.userId, userA);
      assert.deepEqual((await h.ensureTaskStore(userA)).entitlements(), []);
    });
  });
});
