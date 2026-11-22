import type { Env } from "../env.js";
import { base64url, fromBase64Url, randomId, sha256Base64Url } from "../util.js";

// App sessions for the task backend (docs/SEPTASK_BACKEND.md §7).
//
// - Access token: stateless, HMAC-signed, 1 hour. `sa1.<payload>.<sig>`.
//   It carries `sid`, the session's stable id: one sign-in on one install.
//   The device slot (spec §3, ADR 0023) counts sessions.
// - Refresh token: random, single-use, rotated on every refresh, 180 days.
//   Stored hashed in the user's Durable Object (so account deletion kills
//   it); a KV entry maps the hash to the user so a refresh can find the DO.

export const ACCESS_TTL_S = 60 * 60;
const REFRESH_TTL_S = 180 * 24 * 60 * 60;
const PREFIX = "sa1";

async function hmacKey(env: Env): Promise<CryptoKey> {
  const raw = Uint8Array.from(atob(env.SESSION_SIGNING_KEY), (c) => c.charCodeAt(0));
  if (raw.length !== 32) throw new Error(`SESSION_SIGNING_KEY must decode to 32 bytes, got ${raw.length}`);
  return crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

function encodeJSON(v: unknown): string {
  return base64url(new TextEncoder().encode(JSON.stringify(v)));
}

export async function signAccessToken(env: Env, userId: string, sid: string): Promise<string> {
  const payload = encodeJSON({ sub: userId, sid, exp: Math.floor(Date.now() / 1000) + ACCESS_TTL_S });
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(env), new TextEncoder().encode(`${PREFIX}.${payload}`)));
  return `${PREFIX}.${payload}.${base64url(sig)}`;
}

export interface AccessClaims {
  userId: string;
  /// null for a token signed before session ids existed (at most one hour).
  sid: string | null;
}

/// Returns the user id and session id, or null for any invalid or expired
/// token.
export async function verifyAccessToken(env: Env, token: string): Promise<AccessClaims | null> {
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] !== PREFIX) return null;
  const [, payload, sig] = parts;
  try {
    const ok = await crypto.subtle.verify("HMAC", await hmacKey(env), fromBase64Url(sig), new TextEncoder().encode(`${PREFIX}.${payload}`));
    if (!ok) return null;
    const claims = JSON.parse(new TextDecoder().decode(fromBase64Url(payload))) as { sub: string; sid?: unknown; exp: number };
    if (typeof claims.sub !== "string" || claims.exp < Math.floor(Date.now() / 1000)) return null;
    return { userId: claims.sub, sid: typeof claims.sid === "string" ? claims.sid : null };
  } catch {
    return null;
  }
}

export function storeFor(env: Env, userId: string) {
  return env.TASK_STORE.get(env.TASK_STORE.idFromName(userId));
}

export interface IssuedSession {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  userId: string;
}

async function newRefresh(env: Env, userId: string): Promise<{ token: string; hash: string; expiresAt: number }> {
  const token = `sr1.${randomId(32)}`;
  const hash = await sha256Base64Url(token);
  await env.TOKENS.put(`api-refresh:${hash}`, userId, { expirationTtl: REFRESH_TTL_S });
  return { token, hash, expiresAt: Date.now() + REFRESH_TTL_S * 1000 };
}

export async function issueSession(env: Env, userId: string): Promise<IssuedSession> {
  const refresh = await newRefresh(env, userId);
  const sid = crypto.randomUUID();
  await storeFor(env, userId).createSession(refresh.hash, refresh.expiresAt, sid);
  return { accessToken: await signAccessToken(env, userId, sid), refreshToken: refresh.token, expiresIn: ACCESS_TTL_S, userId };
}

export async function refreshSession(env: Env, refreshToken: string): Promise<IssuedSession | null> {
  const oldHash = await sha256Base64Url(refreshToken);
  const userId = await env.TOKENS.get(`api-refresh:${oldHash}`);
  if (!userId) return null;
  await env.TOKENS.delete(`api-refresh:${oldHash}`);
  const next = await newRefresh(env, userId);
  const sid = await storeFor(env, userId).rotateSession(oldHash, next.hash, next.expiresAt);
  if (!sid) {
    await env.TOKENS.delete(`api-refresh:${next.hash}`);
    return null;
  }
  return { accessToken: await signAccessToken(env, userId, sid), refreshToken: next.token, expiresIn: ACCESS_TTL_S, userId };
}

export async function revokeSession(env: Env, refreshToken: string): Promise<void> {
  const hash = await sha256Base64Url(refreshToken);
  const userId = await env.TOKENS.get(`api-refresh:${hash}`);
  await env.TOKENS.delete(`api-refresh:${hash}`);
  if (userId) await storeFor(env, userId).revokeSession(hash);
}
