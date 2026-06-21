/**
 * Sign in with Apple — identity-token verifier + session minting.
 *
 * The App-Attest substitute for devices where App Attest doesn't exist —
 * notably **native macOS** (DCAppAttestService is unavailable outside Mac
 * Catalyst). The Mac proves a genuine Apple ID once via Sign in with Apple; we
 * verify the identity token against Apple's public keys, then mint our own
 * long-lived, HMAC-signed session token the app replays on every community
 * request (header `X-Septena-Session`). `requireUser` accepts a valid session
 * exactly where it accepts an App Attest assertion.
 *
 * Why mint our own token instead of replaying Apple's: Apple identity tokens are
 * short-lived and can only be re-minted by re-running the interactive Sign in
 * with Apple flow. A worker-signed session avoids re-prompting on every call
 * without needing Apple's server-to-server refresh flow (no client secret, no
 * Services ID).
 *
 * Identity is still keyed on the CloudKit user (same as App Attest), so the SAME
 * person is the SAME community identity whether they act from an iPhone (App
 * Attest) or a Mac (Sign in with Apple). The Apple `sub` is bound to that
 * identity trust-on-first-use, mirroring the attest-key binding in auth.ts.
 */

import type { Env } from "./env";

const APPLE_ISS = "https://appleid.apple.com";
const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";
const SESSION_TTL_SEC = 90 * 24 * 60 * 60; // 90 days
const SESSION_DOMAIN = "sess:"; // domain-separation prefix for the HMAC

export interface AppleVerifyResult {
  ok: boolean;
  sub?: string;
  reason?: string;
}

// MARK: - Identity token verification

/**
 * Verify an Apple Sign in with Apple identity token (a JWT). Checks the RS256
 * signature against Apple's published JWKS, plus `iss`, `aud` (our bundle ids),
 * and `exp`. Returns the stable user id (`sub`) on success.
 */
export async function verifyAppleIdentityToken(env: Env, token: string): Promise<AppleVerifyResult> {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return { ok: false, reason: "format" };
    const [headerB64, payloadB64, sigB64] = parts;

    const header = JSON.parse(utf8(b64urlToBytes(headerB64))) as { alg?: string; kid?: string };
    if (header.alg !== "RS256") return { ok: false, reason: "alg" };
    if (!header.kid) return { ok: false, reason: "kid" };

    const jwk = await appleJWK(header.kid);
    if (!jwk) return { ok: false, reason: "unknown_key" };

    const key = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    const signed = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
    const sig = b64urlToBytes(sigB64);
    const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, sig, signed);
    if (!valid) return { ok: false, reason: "sig" };

    const claims = JSON.parse(utf8(b64urlToBytes(payloadB64))) as {
      iss?: string; aud?: string; sub?: string; exp?: number;
    };
    if (claims.iss !== APPLE_ISS) return { ok: false, reason: "iss" };
    const auds = allowedAuds(env);
    if (!claims.aud || !auds.includes(claims.aud)) return { ok: false, reason: "aud" };
    const now = Math.floor(Date.now() / 1000);
    if (!claims.exp || claims.exp < now - 60) return { ok: false, reason: "expired" };
    if (!claims.sub) return { ok: false, reason: "no_sub" };

    return { ok: true, sub: claims.sub };
  } catch (e) {
    return { ok: false, reason: `err:${(e as Error).message}` };
  }
}

/** Bundle ids accepted as the token `aud`. Defaults to the App Attest app ids
 *  with the team prefix stripped (`TEAMID.com.x` → `com.x`); override with
 *  SIWA_BUNDLE_IDS. */
function allowedAuds(env: Env): string[] {
  if (env.SIWA_BUNDLE_IDS) {
    return env.SIWA_BUNDLE_IDS.split(",").map((s) => s.trim()).filter(Boolean);
  }
  return (env.APP_ATTEST_APP_ID ?? "")
    .split(",")
    .map((s) => s.trim().replace(/^[^.]+\./, ""))
    .filter(Boolean);
}

/** Apple rotates a small set of signing keys; fetch the JWKS and pick by kid.
 *  Sign-in is rare (once per device per session lifetime) so a live fetch is
 *  fine — no caching layer needed. */
async function appleJWK(kid: string): Promise<JsonWebKey | null> {
  const resp = await fetch(APPLE_JWKS_URL, { headers: { accept: "application/json" } });
  if (!resp.ok) throw new Error(`jwks ${resp.status}`);
  const body = (await resp.json()) as { keys?: Array<JsonWebKey & { kid?: string }> };
  const match = body.keys?.find((k) => k.kid === kid);
  return match ?? null;
}

// MARK: - Apple sub ↔ identity binding (trust-on-first-use)

/** Pin each Apple `sub` to the first CloudKit identity it presents, mirroring
 *  the attest-key binding. Prevents one Apple ID from later hopping to a
 *  different community identity. Self-heals if the user signs out everywhere
 *  and the binding is never re-presented (it just persists harmlessly). */
export async function bindAppleSub(env: Env, sub: string, userHash: string): Promise<{ ok: boolean }> {
  const key = `apple:${sub}`;
  const bound = await env.ATTEST.get(key);
  if (!bound) {
    await env.ATTEST.put(key, userHash);
    return { ok: true };
  }
  return { ok: bound === userHash };
}

// MARK: - Session tokens (worker-signed, self-contained)

export interface MintedSession {
  token: string;
  expiresAt: number; // epoch seconds
}

/** Mint a self-contained `payload.signature` session token bound to this
 *  identity. No storage — verification recomputes the HMAC. */
export async function mintSession(env: Env, userHash: string, sub: string): Promise<MintedSession> {
  const exp = Math.floor(Date.now() / 1000) + SESSION_TTL_SEC;
  const payload = b64url(new TextEncoder().encode(JSON.stringify({ u: userHash, s: sub, e: exp })));
  const sig = await sessionSig(env, payload);
  return { token: `${payload}.${sig}`, expiresAt: exp };
}

export interface SessionVerifyResult {
  ok: boolean;
  userHash?: string;
  reason?: string;
}

/** Verify a session token: HMAC matches and not expired. Returns the bound
 *  identity hash. */
export async function verifySession(env: Env, token: string): Promise<SessionVerifyResult> {
  try {
    const dot = token.indexOf(".");
    if (dot <= 0) return { ok: false, reason: "format" };
    const payload = token.slice(0, dot);
    const sig = token.slice(dot + 1);
    const expected = await sessionSig(env, payload);
    if (!timingSafeEqual(sig, expected)) return { ok: false, reason: "sig" };
    const obj = JSON.parse(utf8(b64urlToBytes(payload))) as { u?: string; e?: number };
    if (!obj.u || !obj.e) return { ok: false, reason: "claims" };
    if (obj.e < Math.floor(Date.now() / 1000)) return { ok: false, reason: "expired" };
    return { ok: true, userHash: obj.u };
  } catch (e) {
    return { ok: false, reason: `err:${(e as Error).message}` };
  }
}

async function sessionSig(env: Env, payload: string): Promise<string> {
  const secret = env.SESSION_SIGNING_KEY ?? env.USER_HASH_SALT;
  if (!secret || secret.startsWith("REPLACE_")) {
    throw new Error("SESSION_SIGNING_KEY / USER_HASH_SALT is not configured");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(SESSION_DOMAIN + payload)));
  return b64url(sig);
}

// MARK: - helpers

function utf8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}
function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlToBytes(s: string): Uint8Array {
  const norm = s.replace(/-/g, "+").replace(/_/g, "/");
  const pad = norm.length % 4 === 0 ? norm : norm + "=".repeat(4 - (norm.length % 4));
  const bin = atob(pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
