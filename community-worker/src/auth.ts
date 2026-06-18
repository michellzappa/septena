import { rateLimited, verifyAssertion } from "./attest";
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
  const keyId = req.headers.get("X-Attest-Key-Id") ?? "";
  const assertion = req.headers.get("X-Attest-Assertion") ?? "";
  const challenge = req.headers.get("X-Attest-Challenge") ?? "";
  let attested = false;
  if (mode !== "off") {
    if (!keyId || !assertion || !challenge) {
      if (mode === "enforce") return { error: problem("missing_attestation", 403), attestStatus: "missing" };
    } else {
      const res = await verifyAssertion(env, { keyId, assertionB64: assertion, challenge, body: bodyBytes });
      if (!res.ok && mode === "enforce") {
        return { error: problem(`attestation_${res.reason ?? "failed"}`, 403), attestStatus: res.reason ?? "failed" };
      }
      if (!res.ok) console.log(`attest.audit failed reason=${res.reason ?? ""}`);
      else attested = true;
    }
  }

  const cloudKitUserID = req.headers.get("X-Septena-CloudKit-User")?.trim() ?? "";
  if (!cloudKitUserID) return { error: problem("missing_cloudkit_user", 400), attestStatus: "ok" };
  const userHash = await hmacUserHash(env, cloudKitUserID);

  // Identity binding (trust-on-first-use). The CloudKit user id is a header the
  // client asserts; App Attest only proves the app is genuine, not *which*
  // iCloud user it is. Pin each genuine attest key to the first identity it
  // presents so one device's key can't later hop between user identities (e.g.
  // claim a maintainer's hash). A normal single-account user never trips this;
  // it self-heals on reinstall (a fresh key gets a fresh binding). NOT a full
  // fix for a first-contact spoof by someone who already knows a target's
  // opaque CloudKit record id — closing that needs proven CloudKit identity.
  if (attested && keyId) {
    const bindKey = `bind:${keyId}`;
    const bound = await env.ATTEST.get(bindKey);
    if (!bound) {
      await env.ATTEST.put(bindKey, userHash);
    } else if (bound !== userHash) {
      console.log(`attest.bind mismatch key=${keyId.slice(0, 8)}`);
      return { error: problem("identity_mismatch", 403), attestStatus: "identity_mismatch" };
    }
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

async function hmacUserHash(env: Env, cloudKitUserID: string): Promise<string> {
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
