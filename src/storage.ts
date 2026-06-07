import type { Env } from "./env.js";
import { decrypt, encrypt } from "./crypto.js";

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

// ---- Per-user CloudKit token ----
// The app mints a fresh ckWebAuthToken (CKContainer.fetchWebAuthToken)
// and pushes it to /ingest/ck-token on a schedule. We store the latest
// one keyed by the CloudKit user it belongs to. Bearers bound to that
// user resolve through here, so the gateway always serves the freshest
// app-pushed token — the ~8h CloudKit token rotating no longer forces a
// reconnect. This holds only a short-lived *credential*, never user data.

const USER_TOKEN_PREFIX = "cktoken:";

interface UserCkTokenRecord {
  ckWebAuthTokenEnc: string;
  refreshedAt: number;
}

export async function putUserCkToken(
  env: Env,
  userRecordName: string,
  ckWebAuthToken: string,
): Promise<void> {
  const enc = await encrypt(ckWebAuthToken, env.TOKEN_ENC_KEY);
  const rec: UserCkTokenRecord = { ckWebAuthTokenEnc: enc, refreshedAt: Date.now() };
  await env.TOKENS.put(`${USER_TOKEN_PREFIX}${userRecordName}`, JSON.stringify(rec));
}

export async function getUserCkToken(
  env: Env,
  userRecordName: string,
): Promise<{ ckWebAuthToken: string; refreshedAt: number } | null> {
  const raw = await env.TOKENS.get(`${USER_TOKEN_PREFIX}${userRecordName}`);
  if (!raw) return null;
  const rec = JSON.parse(raw) as UserCkTokenRecord;
  const ckWebAuthToken = await decrypt(rec.ckWebAuthTokenEnc, env.TOKEN_ENC_KEY);
  return { ckWebAuthToken, refreshedAt: rec.refreshedAt };
}

// ---- Access tokens ----
// A bearer binds to a CloudKit user (`userRecordName`) and resolves to
// that user's latest app-pushed token. `ckWebAuthTokenEnc` is kept as a
// bootstrap/fallback: the token captured at connect time, used until the
// app's first push arrives (and for legacy bearers issued before the
// identity binding existed).

export interface AccessTokenRecord {
  userRecordName?: string;     // preferred: track the app-refreshed token
  ckWebAuthTokenEnc?: string;  // bootstrap/legacy fallback
  clientId: string;
  createdAt: number;
  lastUsedAt: number;
}

export async function putAccessToken(
  env: Env,
  accessToken: string,
  ckWebAuthToken: string,
  clientId: string,
  userRecordName?: string,
): Promise<void> {
  const enc = await encrypt(ckWebAuthToken, env.TOKEN_ENC_KEY);
  const rec: AccessTokenRecord = {
    userRecordName,
    ckWebAuthTokenEnc: enc,
    clientId,
    createdAt: Date.now(),
    lastUsedAt: Date.now(),
  };
  await env.TOKENS.put(`token:${accessToken}`, JSON.stringify(rec));
}

export async function getCkTokenForAccessToken(
  env: Env,
  accessToken: string,
): Promise<{
  ckWebAuthToken: string;
  createdAt: number;
  lastUsedAt: number;
  // Present when the bearer is bound to a CloudKit identity — i.e. the app can
  // re-mint this user's token, so an expiry is a *transient* lapse the handler
  // can degrade gracefully rather than hard-disconnecting. Absent only for
  // legacy bootstrap-only bearers, which truly need an OAuth re-run.
  userRecordName?: string;
} | null> {
  const raw = await env.TOKENS.get(`token:${accessToken}`);
  if (!raw) return null;
  const rec = JSON.parse(raw) as AccessTokenRecord;
  // Preferred: serve the freshest token the app has pushed for this user.
  if (rec.userRecordName) {
    const user = await getUserCkToken(env, rec.userRecordName);
    if (user) {
      return {
        ckWebAuthToken: user.ckWebAuthToken,
        createdAt: rec.createdAt,
        lastUsedAt: rec.lastUsedAt,
        userRecordName: rec.userRecordName,
      };
    }
    // App hasn't pushed yet — fall through to the bootstrap token below.
  }
  if (rec.ckWebAuthTokenEnc) {
    const ckWebAuthToken = await decrypt(rec.ckWebAuthTokenEnc, env.TOKEN_ENC_KEY);
    return {
      ckWebAuthToken,
      createdAt: rec.createdAt,
      lastUsedAt: rec.lastUsedAt,
      userRecordName: rec.userRecordName,
    };
  }
  return null; // stale bearer with no usable token → reconnect
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
      const isAccess = k.name.startsWith("token:");
      const isUserToken = k.name.startsWith(USER_TOKEN_PREFIX);
      if (!isAccess && !isUserToken) continue;
      const raw = await env.TOKENS.get(k.name);
      if (!raw) continue;
      try {
        const rec = JSON.parse(raw) as AccessTokenRecord & UserCkTokenRecord;
        // Access tokens age on lastUsedAt; per-user tokens on refreshedAt.
        const stamp = isUserToken ? rec.refreshedAt : (rec.lastUsedAt ?? rec.createdAt);
        const idle = Date.now() - stamp;
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
