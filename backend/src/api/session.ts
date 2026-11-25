import type { Env } from "../env.js";
import { base64url, fromBase64Url, logEvent, randomId, sha256Base64Url } from "../util.js";
import type { RenewResult, SessionGrant } from "../store/sessions.js";

// Sessions of the task backend (docs/SEPTASK_BACKEND.md §10, ADR 0040), for
// app sign-ins here and for connected agents (src/shadow/tokens.ts).
//
// - Access token: HMAC-signed, 1 hour. `<prefix>.<payload>.<sig>`. It carries
//   `sid`, the session's stable id (one sign-in on one install), and `rt`, the
//   hash of the refresh token it came with. The signature alone is not
//   enough: every request asks the user's Durable Object whether the session
//   is alive, so a sign-out counts from the next request.
// - Refresh token: random and signed, 180 days. `<prefix>.<userId>.<sid>.
//   <secret>.<sig>`. The signature routes it: no lookup table can be stale,
//   and a made-up token never reaches a Durable Object. The secret is stored
//   hashed in the Durable Object, the only authority over it.
// - Renewal: src/store/sessions.ts.

export const ACCESS_TTL_S = 60 * 60;
const REFRESH_TTL_S = 180 * 24 * 60 * 60;
const ACCESS_PREFIX = "sa1";
const REFRESH_PREFIX = "sr2";
const LEGACY_REFRESH_PREFIX = "sr1";

/// Two-step rollout: a version that accepts the ADR 0040 tokens ships first,
/// and issues them only after the switch, so no Worker in flight, and no
/// rollback, ever meets a token it cannot read. Remove with the KV tokens.
export const issuesSignedTokens = (env: Env) => env.SIGNED_SESSIONS === "true";

async function hmacKey(secret: string): Promise<CryptoKey> {
  const raw = Uint8Array.from(atob(secret), (c) => c.charCodeAt(0));
  if (raw.length !== 32) throw new Error(`SESSION_SIGNING_KEY must decode to 32 bytes, got ${raw.length}`);
  return crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

async function sign(env: Env, message: string): Promise<string> {
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(env.SESSION_SIGNING_KEY), new TextEncoder().encode(message));
  return `${message}.${base64url(new Uint8Array(sig))}`;
}

/// The signed message, or null. The previous key still verifies, so the key
/// can change without signing everyone out.
async function verified(env: Env, token: string): Promise<string | null> {
  const cut = token.lastIndexOf(".");
  if (cut < 0) return null;
  const message = token.slice(0, cut);
  for (const secret of [env.SESSION_SIGNING_KEY, env.SESSION_SIGNING_KEY_PREVIOUS]) {
    if (!secret) continue;
    const key = await hmacKey(secret);
    try {
      if (await crypto.subtle.verify("HMAC", key, fromBase64Url(token.slice(cut + 1)), new TextEncoder().encode(message))) return message;
    } catch {
      return null; // not base64url
    }
  }
  return null;
}

/// `rt` is null only in an access token from before ADR 0040.
export async function signAccessToken(env: Env, userId: string, sid: string, rt: string | null = null, prefix = ACCESS_PREFIX): Promise<string> {
  const claims = { sub: userId, sid, exp: Math.floor(Date.now() / 1000) + ACCESS_TTL_S, ...(rt ? { rt } : {}) };
  return sign(env, `${prefix}.${base64url(new TextEncoder().encode(JSON.stringify(claims)))}`);
}

export interface AccessClaims {
  userId: string;
  sid: string;
  /// Hash of the refresh token this access token came with.
  rt: string | null;
}

/// The claims of a correctly signed, unexpired access token, or null. The
/// session may be over: callers use `authenticate`.
export async function verifyAccessToken(env: Env, token: string, prefix = ACCESS_PREFIX): Promise<AccessClaims | null> {
  if (!token.startsWith(`${prefix}.`) || token.length > 1_000) return null;
  const message = await verified(env, token);
  if (!message) return null;
  try {
    const claims = JSON.parse(new TextDecoder().decode(fromBase64Url(message.slice(prefix.length + 1)))) as { sub?: unknown; sid?: unknown; rt?: unknown; exp?: unknown };
    if (typeof claims.sub !== "string" || typeof claims.sid !== "string") return null;
    if (typeof claims.exp !== "number" || claims.exp < Math.floor(Date.now() / 1000)) return null;
    return { userId: claims.sub, sid: claims.sid, rt: typeof claims.rt === "string" ? claims.rt : null };
  } catch {
    return null;
  }
}

/// The app session behind an access token, or null. A store error throws: the
/// caller answers 5xx, and the client keeps its session and retries.
export async function authenticate(env: Env, token: string): Promise<AccessClaims | null> {
  const claims = await verifyAccessToken(env, token);
  if (!claims) return null;
  const session = await storeFor(env, claims.userId).authorizeSession(claims.sid, claims.rt);
  return session && session.grant === null ? claims : null;
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

export interface MintedRefresh {
  token: string;
  hash: string;
  expiresAt: number;
}

export async function mintRefresh(env: Env, prefix: string, userId: string, sid: string, ttlSeconds: number): Promise<MintedRefresh> {
  const token = await sign(env, `${prefix}.${userId}.${sid}.${randomId(32)}`);
  return { token, hash: await sha256Base64Url(token), expiresAt: Date.now() + ttlSeconds * 1000 };
}

async function mintAppRefresh(env: Env, userId: string, sid: string): Promise<MintedRefresh> {
  if (issuesSignedTokens(env)) return mintRefresh(env, REFRESH_PREFIX, userId, sid, REFRESH_TTL_S);
  const token = `${LEGACY_REFRESH_PREFIX}.${randomId(32)}`;
  const hash = await sha256Base64Url(token);
  await env.TOKENS.put(`api-refresh:${hash}`, userId, { expirationTtl: REFRESH_TTL_S });
  return { token, hash, expiresAt: Date.now() + REFRESH_TTL_S * 1000 };
}

export interface RefreshRef {
  userId: string;
  sid: string;
  hash: string;
}

/// Where a signed refresh token belongs, or null. Says nothing about whether
/// it is still good: the store decides.
export async function readRefresh(env: Env, prefix: string, token: string): Promise<RefreshRef | null> {
  const parts = token.split(".");
  if (parts.length !== 5 || parts[0] !== prefix || !(await verified(env, token))) return null;
  return { userId: parts[1], sid: parts[2], hash: await sha256Base64Url(token) };
}

export function logRenewal(kind: "app" | "agent", userId: string, res: RenewResult): void {
  if (res.ok) return;
  logEvent("session_renewal_refused", { kind, userId, reason: res.reason });
}

async function issued(env: Env, userId: string, sid: string, refresh: MintedRefresh): Promise<IssuedSession> {
  return { accessToken: await signAccessToken(env, userId, sid, refresh.hash), refreshToken: refresh.token, expiresIn: ACCESS_TTL_S, userId };
}

export async function issueSession(env: Env, userId: string): Promise<IssuedSession> {
  const sid = crypto.randomUUID();
  const refresh = await mintAppRefresh(env, userId, sid);
  await storeFor(env, userId).createSession(refresh.hash, refresh.expiresAt, sid);
  return issued(env, userId, sid, refresh);
}

/// A refresh token from before ADR 0040 (`sr1.`): a KV entry names the user.
/// The entry stays until it expires; the store alone says if the token is good.
async function readLegacyRefresh(env: Env, token: string): Promise<RefreshRef | null> {
  if (!token.startsWith(`${LEGACY_REFRESH_PREFIX}.`)) return null;
  const hash = await sha256Base64Url(token);
  const userId = await env.TOKENS.get(`api-refresh:${hash}`);
  const sid = userId ? await storeFor(env, userId).sessionIdFor(hash) : null;
  return userId && sid ? { userId, sid, hash } : null;
}

const resolveRefresh = async (env: Env, token: string) =>
  (await readRefresh(env, REFRESH_PREFIX, token)) ?? readLegacyRefresh(env, token);

export async function refreshSession(env: Env, refreshToken: string): Promise<IssuedSession | null> {
  const ref = await resolveRefresh(env, refreshToken);
  if (!ref) return null;
  const next = await mintAppRefresh(env, ref.userId, ref.sid);
  const res = await storeFor(env, ref.userId).renewSession(ref.hash, next.hash, next.expiresAt, ref.sid);
  logRenewal("app", ref.userId, res);
  return res.ok ? issued(env, ref.userId, ref.sid, next) : null;
}

export async function revokeSession(env: Env, refreshToken: string): Promise<void> {
  const ref = await resolveRefresh(env, refreshToken);
  if (ref) await storeFor(env, ref.userId).revokeSession(ref.hash, ref.sid);
}

/// An access token whose account is already deleted: a repeated `DELETE
/// /v1/account` (the first reply was lost) has nothing left to do.
export async function accountAlreadyDeleted(env: Env, token: string): Promise<boolean> {
  const claims = await verifyAccessToken(env, token);
  if (!claims) return false;
  const store = storeFor(env, claims.userId);
  return (await store.wasDeleted()) && !(await store.hasAppSession());
}

/// The request with the session that opened it, for a stream the store holds
/// open. Overwrites whatever the client sent.
export function withSession(request: Request, sid: string, header: string): Request {
  const headers = new Headers(request.headers);
  headers.set(header, sid);
  return new Request(request, { headers });
}
