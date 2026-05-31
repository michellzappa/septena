import type { Env } from "./env.js";
import { decrypt, encrypt } from "./crypto.js";
import { sha256Base64Url } from "./util.js";

// KV-backed records. All keys are random IDs (not deterministic from user
// data) so a KV listing leak doesn't reveal anything about who has signed up.

// ---- Mid-OAuth state ----
// Saved when we redirect the user to Apple sign-in. Recovered via a cookie
// when Apple redirects back. TTL short — a real user finishes in <2 min.

export interface OAuthState {
  oauthState: string;          // claude.ai's state, returned verbatim
  codeChallenge: string;       // PKCE
  codeChallengeMethod: "S256"; // we only accept S256
  clientId: string;
  redirectUri: string;
  createdAt: number;
}

const STATE_TTL_SECONDS = 600;

export async function putState(env: Env, id: string, s: OAuthState): Promise<void> {
  await env.STATE.put(`state:${id}`, JSON.stringify(s), { expirationTtl: STATE_TTL_SECONDS });
}

export async function takeState(env: Env, id: string): Promise<OAuthState | null> {
  const raw = await env.STATE.get(`state:${id}`);
  if (!raw) return null;
  await env.STATE.delete(`state:${id}`);
  return JSON.parse(raw) as OAuthState;
}

/// Non-destructive read — used by /oauth/continue, which only checks
/// the in-flight state exists before bouncing to Apple. The Apple
/// callback handler later does the destructive `takeState`.
export async function peekState(env: Env, id: string): Promise<OAuthState | null> {
  const raw = await env.STATE.get(`state:${id}`);
  return raw ? (JSON.parse(raw) as OAuthState) : null;
}

// ---- Auth codes ----
// Issued on Apple callback, exchanged at /oauth/token. Short TTL.

export interface AuthCode {
  ckWebAuthToken: string;      // plaintext here; encrypted on promotion to access token
  codeChallenge: string;
  clientId: string;
  redirectUri: string;
}

const CODE_TTL_SECONDS = 300;

export async function putCode(env: Env, code: string, c: AuthCode): Promise<void> {
  await env.STATE.put(`code:${code}`, JSON.stringify(c), { expirationTtl: CODE_TTL_SECONDS });
}

export async function takeCode(env: Env, code: string): Promise<AuthCode | null> {
  const raw = await env.STATE.get(`code:${code}`);
  if (!raw) return null;
  await env.STATE.delete(`code:${code}`);
  return JSON.parse(raw) as AuthCode;
}

// ---- Access tokens (bearer → user) ----
// A bearer binds Claude's permanent access token to a USER identity. It no
// longer carries the CloudKit token itself — that lives in a per-user slot
// (below), kept fresh by the user's app. `ckWebAuthTokenEnc` is retained
// only for backward compatibility: bearers minted before the multi-user
// refactor have no userId and fall back to their baked token until the
// user reconnects.

export interface AccessTokenRecord {
  userId?: string;             // multi-user identity this bearer belongs to
  ckWebAuthTokenEnc?: string;  // legacy bootstrap (pre-userId bearers)
  clientId: string;
  createdAt: number;
  lastUsedAt: number;
}

export async function putAccessTokenForUser(
  env: Env,
  accessToken: string,
  userId: string,
  clientId: string,
): Promise<void> {
  const rec: AccessTokenRecord = {
    userId,
    clientId,
    createdAt: Date.now(),
    lastUsedAt: Date.now(),
  };
  await env.TOKENS.put(`token:${accessToken}`, JSON.stringify(rec));
}

/// Legacy fallback: bake the token into the bearer when we couldn't resolve
/// a user identity at OAuth time. Ensures connect never hard-fails; such
/// bearers use the daily-expiry path until identity resolution succeeds on a
/// later reconnect.
export async function putLegacyAccessToken(
  env: Env,
  accessToken: string,
  ckWebAuthToken: string,
  clientId: string,
): Promise<void> {
  const enc = await encrypt(ckWebAuthToken, env.TOKEN_ENC_KEY);
  const rec: AccessTokenRecord = {
    ckWebAuthTokenEnc: enc,
    clientId,
    createdAt: Date.now(),
    lastUsedAt: Date.now(),
  };
  await env.TOKENS.put(`token:${accessToken}`, JSON.stringify(rec));
}

/// Resolve the live ckWebAuthToken for a bearer. New-shape bearers read the
/// per-user slot (kept fresh by the app); legacy bearers fall back to their
/// baked token. Returns null when neither is available (caller → 401, which
/// prompts the client to reconnect).
export async function resolveCkToken(
  env: Env,
  accessToken: string,
): Promise<{ ckWebAuthToken: string; userId?: string; createdAt: number; lastUsedAt: number } | null> {
  const raw = await env.TOKENS.get(`token:${accessToken}`);
  if (!raw) return null;
  const rec = JSON.parse(raw) as AccessTokenRecord;
  let ckWebAuthToken: string | null = null;
  if (rec.userId) {
    const slot = await getUserCkToken(env, rec.userId);
    if (slot) ckWebAuthToken = slot.ckWebAuthToken;
  }
  if (!ckWebAuthToken && rec.ckWebAuthTokenEnc) {
    ckWebAuthToken = await decrypt(rec.ckWebAuthTokenEnc, env.TOKEN_ENC_KEY);
  }
  if (!ckWebAuthToken) return null;
  return { ckWebAuthToken, userId: rec.userId, createdAt: rec.createdAt, lastUsedAt: rec.lastUsedAt };
}

/// Refresh lastUsedAt so the cleanup cron can tell live tokens from dead
/// ones. Preserves the encrypted CloudKit token; only bumps the timestamp.
/// Call behind a throttle (see TOUCH_INTERVAL_MS) and via waitUntil so it
/// never blocks the request.
export async function touchAccessToken(env: Env, accessToken: string): Promise<void> {
  const raw = await env.TOKENS.get(`token:${accessToken}`);
  if (!raw) return;
  const rec = JSON.parse(raw) as AccessTokenRecord;
  rec.lastUsedAt = Date.now();
  await env.TOKENS.put(`token:${accessToken}`, JSON.stringify(rec));
}

/// Delete access-token records idle longer than maxIdleMs. The underlying
/// ckWebAuthToken dies within hours, so anything unused for days is dead
/// weight (and a source of zombie health-check traffic). Returns count.
export async function cleanupAccessTokens(env: Env, maxIdleMs: number): Promise<number> {
  let deleted = 0;
  let cursor: string | undefined;
  do {
    const list = await env.TOKENS.list({ cursor });
    for (const k of list.keys) {
      if (!k.name.startsWith("token:")) continue; // skip ck:current etc.
      const raw = await env.TOKENS.get(k.name);
      if (!raw) continue;
      try {
        const rec = JSON.parse(raw) as AccessTokenRecord;
        const idle = Date.now() - (rec.lastUsedAt ?? rec.createdAt);
        if (idle > maxIdleMs) {
          await env.TOKENS.delete(k.name);
          deleted++;
        }
      } catch {
        // Unparseable record — remove it.
        await env.TOKENS.delete(k.name);
        deleted++;
      }
    }
    cursor = list.list_complete ? undefined : list.cursor;
  } while (cursor);
  return deleted;
}

// ---- Per-user CloudKit web-auth token (app-brokered) ----
// The user's app mints fresh ckWebAuthTokens (CKFetchWebAuthTokenOperation)
// and pushes them to /internal/ck-token. The gateway validates each token
// against CloudKit, derives the owner's userId, and stores it here. The MCP
// handler reads this per-user slot, so each user's Claude connector always
// has live CloudKit auth and never needs reconnecting. Keyed by a hash of
// the userId so a KV listing leak reveals no identities.

interface UserCkTokenRecord {
  ckWebAuthTokenEnc: string;
  updatedAt: number;
}

async function userSlotKey(userId: string): Promise<string> {
  return `ckuser:${await sha256Base64Url(userId)}`;
}

export async function putUserCkToken(env: Env, userId: string, ckWebAuthToken: string): Promise<void> {
  const enc = await encrypt(ckWebAuthToken, env.TOKEN_ENC_KEY);
  const rec: UserCkTokenRecord = { ckWebAuthTokenEnc: enc, updatedAt: Date.now() };
  await env.TOKENS.put(await userSlotKey(userId), JSON.stringify(rec));
}

export async function getUserCkToken(
  env: Env,
  userId: string,
): Promise<{ ckWebAuthToken: string; updatedAt: number } | null> {
  const raw = await env.TOKENS.get(await userSlotKey(userId));
  if (!raw) return null;
  const rec = JSON.parse(raw) as UserCkTokenRecord;
  const ckWebAuthToken = await decrypt(rec.ckWebAuthTokenEnc, env.TOKEN_ENC_KEY);
  return { ckWebAuthToken, updatedAt: rec.updatedAt };
}

// ---- Dynamic client registrations ----
// Per MCP spec, clients (e.g. claude.ai) self-register before OAuth.

export interface ClientRecord {
  clientId: string;
  redirectUris: string[];
  name?: string;
  createdAt: number;
}

export async function putClient(env: Env, c: ClientRecord): Promise<void> {
  await env.CLIENTS.put(`client:${c.clientId}`, JSON.stringify(c));
}

export async function getClient(env: Env, clientId: string): Promise<ClientRecord | null> {
  const raw = await env.CLIENTS.get(`client:${clientId}`);
  return raw ? (JSON.parse(raw) as ClientRecord) : null;
}
