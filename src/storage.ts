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

// ---- Access tokens ----
// Long-lived. The ckWebAuthToken is encrypted with TOKEN_ENC_KEY. Each
// bearer carries its own user's token, so the gateway is multi-user by
// construction: one bearer per user connection, no shared state.

export interface AccessTokenRecord {
  ckWebAuthTokenEnc: string;
  clientId: string;
  createdAt: number;
  lastUsedAt: number;
}

export async function putAccessToken(
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

export async function getCkTokenForAccessToken(
  env: Env,
  accessToken: string,
): Promise<{ ckWebAuthToken: string; createdAt: number; lastUsedAt: number } | null> {
  const raw = await env.TOKENS.get(`token:${accessToken}`);
  if (!raw) return null;
  const rec = JSON.parse(raw) as AccessTokenRecord;
  if (!rec.ckWebAuthTokenEnc) return null; // stale multi-user bearer → reconnect
  const ckWebAuthToken = await decrypt(rec.ckWebAuthTokenEnc, env.TOKEN_ENC_KEY);
  return { ckWebAuthToken, createdAt: rec.createdAt, lastUsedAt: rec.lastUsedAt };
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
      if (!k.name.startsWith("token:")) continue; // only access-token records
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
