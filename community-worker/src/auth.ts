import { rateLimited, verifyAssertion } from "./attest";
import { verifySession } from "./apple";
import type { CurrentUser, Env } from "./env";

export async function requireUser(
  env: Env,
  req: Request,
  bodyBytes: Uint8Array,
): Promise<{ user?: CurrentUser; error?: Response; attestStatus: string }> {
  const ip = req.headers.get("CF-Connecting-IP") ?? "unknown";
  if (await rateLimited(env, `ip:${ip}`, 120, 60)) {
    return { error: problem("rate_limited", 429), attestStatus: "rate_limited" };
  }

  const mode = env.ATTEST_MODE ?? "enforce";

  const cloudKitUserID = req.headers.get("X-Septena-CloudKit-User")?.trim() ?? "";
  if (!cloudKitUserID) return { error: problem("missing_cloudkit_user", 400), attestStatus: "ok" };
  const userHash = await hmacUserHash(env, cloudKitUserID);

  // A request proves it's genuine one of two ways, either of which satisfies
  // enforce mode: an App Attest assertion (a real, unmodified app on a real
  // Apple device) OR a Sign in with Apple session token (a proven Apple ID —
  // the substitute for devices without App Attest, notably native macOS).
  let attested = false;
  let attestStatus = "missing";

  // (1) Sign in with Apple session — worker-signed, bound to this identity.
  const sessionTok = req.headers.get("X-Septena-Session")?.trim() ?? "";
  if (sessionTok) {
    const s = await verifySession(env, sessionTok);
    if (s.ok) {
      // The session is signed by us and pinned to an identity; reject replaying
      // someone else's session under a different CloudKit user header.
      if (s.userHash !== userHash) {
        return { error: problem("identity_mismatch", 403), attestStatus: "identity_mismatch" };
      }
      attested = true;
      attestStatus = "ok";
    } else {
      console.log(`session.verify failed reason=${s.reason ?? ""}`);
      attestStatus = `session_${s.reason ?? "failed"}`;
    }
  }

  // (2) App Attest assertion. The CloudKit user id is a header the client
  // asserts; App Attest only proves the app is genuine, not *which* iCloud user
  // it is. Pin each genuine attest key to the first identity it presents so one
  // device's key can't later hop between user identities (e.g. claim a
  // maintainer's hash). A normal single-account user never trips this; it
  // self-heals on reinstall (a fresh key gets a fresh binding).
  const keyId = req.headers.get("X-Attest-Key-Id") ?? "";
  const assertion = req.headers.get("X-Attest-Assertion") ?? "";
  const challenge = req.headers.get("X-Attest-Challenge") ?? "";
  if (!attested && mode !== "off" && keyId && assertion && challenge) {
    const res = await verifyAssertion(env, { keyId, assertionB64: assertion, challenge, body: bodyBytes });
    if (res.ok) {
      const bindKey = `bind:${keyId}`;
      const bound = await env.ATTEST.get(bindKey);
      if (!bound) {
        await env.ATTEST.put(bindKey, userHash);
      } else if (bound !== userHash) {
        console.log(`attest.bind mismatch key=${keyId.slice(0, 8)}`);
        return { error: problem("identity_mismatch", 403), attestStatus: "identity_mismatch" };
      }
      attested = true;
      attestStatus = "ok";
    } else {
      console.log(`attest.audit failed reason=${res.reason ?? ""}`);
      attestStatus = `attestation_${res.reason ?? "failed"}`;
    }
  }

  if (!attested && mode === "enforce") {
    const reason = attestStatus === "missing" ? "missing_attestation" : "attestation_failed";
    return { error: problem(reason, 403), attestStatus };
  }

  const row = await upsertIdentity(env, userHash);
  if (row.is_banned === 1) return { error: problem("user_banned", 403), attestStatus: "ok" };
  return {
    user: {
      userHash,
      role: row.role as CurrentUser["role"],
      isBanned: row.is_banned === 1,
    },
    attestStatus: "ok",
  };
}

async function upsertIdentity(env: Env, userHash: string): Promise<{ role: string; is_banned: number }> {
  await env.DB.prepare(`
    insert into user_identity (user_hash) values (?)
    on conflict(user_hash) do update set last_seen_at = datetime('now')
  `).bind(userHash).run();

  const row = await env.DB.prepare(`
    select role, is_banned from user_identity where user_hash = ?
  `).bind(userHash).first<{ role: string; is_banned: number }>();
  return row ?? { role: "user", is_banned: 0 };
}

export async function hmacUserHash(env: Env, cloudKitUserID: string): Promise<string> {
  const salt = env.USER_HASH_SALT;
  if (!salt || salt.startsWith("REPLACE_")) throw new Error("USER_HASH_SALT is not configured");
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(salt),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(cloudKitUserID)));
  return b64url(sig);
}

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function problem(error: string, status: number): Response {
  return new Response(JSON.stringify({ error }), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}
