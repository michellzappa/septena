import type { Env } from "./env.js";
import { decrypt, encrypt } from "./crypto.js";
import { randomId, sha256Base64Url } from "./util.js";

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

// ---- Per-user section manifest cache ----
// The last-known list of enabled+ordered section keys, recomputed and stored
// on every successful tools/list. When a later tools/list hits an expired
// ckWebAuthToken, we serve this cache instead of re-throwing — a re-throw
// becomes a hard 401 that flips claude.ai to a *sticky* disconnected state
// (the daily-reconnect symptom). Serving the cache keeps the connector alive
// through the ~8h token lapse; the next call after the app re-mints refreshes
// it. Not a credential and not user life-data — just which sections are on —
// so it's stored plaintext with a self-cleaning TTL for abandoned users.

const SECTIONS_PREFIX = "sections:";
const SECTIONS_TTL_SECONDS = 30 * 24 * 60 * 60; // 30d; refreshed on every success

export async function putUserSections(
  env: Env,
  userRecordName: string,
  sectionKeys: string[],
): Promise<void> {
  await env.TOKENS.put(
    `${SECTIONS_PREFIX}${userRecordName}`,
    JSON.stringify(sectionKeys),
    { expirationTtl: SECTIONS_TTL_SECONDS },
  );
}

export async function getUserSections(
  env: Env,
  userRecordName: string,
): Promise<string[] | null> {
  const raw = await env.TOKENS.get(`${SECTIONS_PREFIX}${userRecordName}`);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed.filter(k => typeof k === "string") as string[]) : null;
  } catch {
    return null;
  }
}

// ---- Access + refresh tokens ----
// A bearer binds to a CloudKit user (`userRecordName`) and resolves to
// that user's latest app-pushed token. `ckWebAuthTokenEnc` is kept as a
// bootstrap/fallback: the token captured at connect time, used until the
// app's first push arrives (and for legacy bearers issued before the
// identity binding existed).
//
// Tokens are finite-lived: access tokens expire after ACCESS_TOKEN_TTL and
// clients stay connected by rotating a refresh token at /oauth/token. KV
// records are keyed by sha256(token), never the raw token, so a KV leak
// doesn't yield usable bearers. Every record carries a KV expirationTtl,
// so revocation aside, nothing outlives its logical lifetime.
//
// Refresh rotation keeps the spent record around (marked `rotatedAt`) for
// its original lifetime. Presenting a spent token is a replay — either the
// legitimate client or a thief holds a stale copy — so the whole family
// (current refresh + access token) is revoked and the user re-auths.

const ACCESS_TOKEN_TTL_SECONDS = 60 * 60;                // 1h
const REFRESH_TOKEN_TTL_SECONDS = 30 * 24 * 60 * 60;     // 30d, slides on rotation

export interface AccessTokenRecord {
  userRecordName?: string;     // preferred: track the app-refreshed token
  ckWebAuthTokenEnc?: string;  // bootstrap/legacy fallback
  clientId: string;
  createdAt: number;
  lastUsedAt: number;
  expiresAt: number;           // ms epoch; checked on read, enforced by KV TTL
}

interface RefreshTokenRecord {
  userRecordName?: string;
  ckWebAuthTokenEnc?: string;
  clientId: string;
  familyId: string;            // links successive rotations of one grant
  createdAt: number;
  expiresAt: number;           // ms epoch
  rotatedAt?: number;          // set once spent; any later use is a replay
}

// Points at the family's *current* tokens so a replay or a refresh-token
// revocation can kill them without listing KV.
interface RefreshFamilyRecord {
  refreshHash: string;
  accessHash: string;
  updatedAt: number;
}

const accessKey = async (raw: string) => `token:${await sha256Base64Url(raw)}`;
const refreshKey = async (raw: string) => `refresh:${await sha256Base64Url(raw)}`;
const familyKey = (id: string) => `rtfamily:${id}`;

export interface TokenGrant {
  accessToken: string;
  refreshToken: string;
  expiresIn: number; // access-token lifetime, seconds
}

/// Mint a fresh access + refresh token pair. Pass the plaintext CloudKit
/// token on the initial grant (encrypted here) or the already-encrypted
/// blob when rotating. `familyId` ties a rotation to its original grant.
export async function issueTokenPair(
  env: Env,
  opts: {
    clientId: string;
    userRecordName?: string;
    ckWebAuthToken?: string;
    ckWebAuthTokenEnc?: string;
    familyId?: string;
  },
): Promise<TokenGrant> {
  const ckWebAuthTokenEnc = opts.ckWebAuthTokenEnc
    ?? (opts.ckWebAuthToken ? await encrypt(opts.ckWebAuthToken, env.TOKEN_ENC_KEY) : undefined);

  const accessToken = randomId(32);
  const refreshToken = randomId(32);
  const familyId = opts.familyId ?? randomId(16);
  const now = Date.now();

  const accessRec: AccessTokenRecord = {
    userRecordName: opts.userRecordName,
    ckWebAuthTokenEnc,
    clientId: opts.clientId,
    createdAt: now,
    lastUsedAt: now,
    expiresAt: now + ACCESS_TOKEN_TTL_SECONDS * 1000,
  };
  const refreshRec: RefreshTokenRecord = {
    userRecordName: opts.userRecordName,
    ckWebAuthTokenEnc,
    clientId: opts.clientId,
    familyId,
    createdAt: now,
    expiresAt: now + REFRESH_TOKEN_TTL_SECONDS * 1000,
  };
  const refreshHash = await refreshKey(refreshToken);
  const accessHash = await accessKey(accessToken);
  const familyRec: RefreshFamilyRecord = { refreshHash, accessHash, updatedAt: now };

  await Promise.all([
    env.TOKENS.put(accessHash, JSON.stringify(accessRec), { expirationTtl: ACCESS_TOKEN_TTL_SECONDS }),
    env.TOKENS.put(refreshHash, JSON.stringify(refreshRec), { expirationTtl: REFRESH_TOKEN_TTL_SECONDS }),
    env.TOKENS.put(familyKey(familyId), JSON.stringify(familyRec), { expirationTtl: REFRESH_TOKEN_TTL_SECONDS }),
  ]);

  return { accessToken, refreshToken, expiresIn: ACCESS_TOKEN_TTL_SECONDS };
}

/// Delete a family's current tokens. Used on replay detection and on
/// refresh-token revocation (RFC 7009 §2.1: revoking a refresh token
/// SHOULD revoke the access tokens issued with it).
async function revokeFamily(env: Env, familyId: string): Promise<void> {
  const raw = await env.TOKENS.get(familyKey(familyId));
  if (raw) {
    const fam = JSON.parse(raw) as RefreshFamilyRecord;
    await Promise.all([
      env.TOKENS.delete(fam.refreshHash),
      env.TOKENS.delete(fam.accessHash),
    ]);
  }
  await env.TOKENS.delete(familyKey(familyId));
}

export type RefreshRedemption =
  | ({ ok: true; clientId: string } & TokenGrant)
  | { ok: false; reason: "not_found" | "expired" | "replayed" | "client_mismatch" };

/// Rotate a refresh token: validate, spend it, mint a new pair in the same
/// family. The old access token is left to its (short) natural expiry so
/// in-flight requests don't 401 mid-rotation.
export async function redeemRefreshToken(
  env: Env,
  rawRefreshToken: string,
  expectedClientId: string,
): Promise<RefreshRedemption> {
  const key = await refreshKey(rawRefreshToken);
  const raw = await env.TOKENS.get(key);
  if (!raw) return { ok: false, reason: "not_found" };
  const rec = JSON.parse(raw) as RefreshTokenRecord;

  if (rec.rotatedAt) {
    // Replay of a spent token — someone (client or thief) has a stale copy.
    // Kill the whole family; the legitimate user just re-auths.
    await revokeFamily(env, rec.familyId);
    await env.TOKENS.delete(key);
    return { ok: false, reason: "replayed" };
  }
  if (rec.clientId !== expectedClientId) return { ok: false, reason: "client_mismatch" };
  if (Date.now() > rec.expiresAt) {
    await env.TOKENS.delete(key);
    return { ok: false, reason: "expired" };
  }

  const grant = await issueTokenPair(env, {
    clientId: rec.clientId,
    userRecordName: rec.userRecordName,
    ckWebAuthTokenEnc: rec.ckWebAuthTokenEnc,
    familyId: rec.familyId,
  });

  // Keep the spent record (for replay detection) until its original expiry.
  const spent: RefreshTokenRecord = { ...rec, rotatedAt: Date.now() };
  await env.TOKENS.put(key, JSON.stringify(spent), {
    expiration: Math.ceil(rec.expiresAt / 1000),
  });

  return { ok: true, clientId: rec.clientId, ...grant };
}

/// RFC 7009 revocation. Tries the token as an access token, then as a
/// refresh token (which also revokes the family's current access token).
/// Returns what was revoked, for logging only — the endpoint always 200s.
export async function revokeToken(env: Env, rawToken: string): Promise<"access" | "refresh" | "none"> {
  const aKey = await accessKey(rawToken);
  if (await env.TOKENS.get(aKey)) {
    await env.TOKENS.delete(aKey);
    return "access";
  }
  const rKey = await refreshKey(rawToken);
  const raw = await env.TOKENS.get(rKey);
  if (raw) {
    const rec = JSON.parse(raw) as RefreshTokenRecord;
    await revokeFamily(env, rec.familyId);
    await env.TOKENS.delete(rKey); // in case the family pointer was stale
    return "refresh";
  }
  return "none";
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
  // Keyed by sha256(token) — legacy raw-keyed records simply never match
  // and age out via the cleanup cron. KV TTL enforces expiry; the explicit
  // expiresAt check covers KV's eventual-deletion window.
  const raw = await env.TOKENS.get(await accessKey(accessToken));
  if (!raw) return null;
  const rec = JSON.parse(raw) as AccessTokenRecord;
  if (Date.now() > rec.expiresAt) return null;
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

/// Bump lastUsedAt — observability only now that expiry is TTL-driven;
/// a busy token still dies at expiresAt and the client refresh-rotates.
/// Call behind a throttle (see TOUCH_INTERVAL_MS) and via waitUntil so it
/// never blocks the request.
export async function touchAccessToken(env: Env, accessToken: string): Promise<void> {
  const key = await accessKey(accessToken);
  const raw = await env.TOKENS.get(key);
  if (!raw) return;
  const rec = JSON.parse(raw) as AccessTokenRecord;
  // KV rejects expirations under 60s out; a nearly-dead token isn't worth
  // stamping anyway.
  if (rec.expiresAt - Date.now() < 60_000) return;
  rec.lastUsedAt = Date.now();
  // Absolute expiration so the rewrite can't extend the token's KV lifetime.
  await env.TOKENS.put(key, JSON.stringify(rec), {
    expiration: Math.ceil(rec.expiresAt / 1000),
  });
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

// `keyPrefix` keeps each authorization server's registrations apart: the live
// connector uses the default `client:`, the api.septena.app preview `v2:client:`
// (src/shadow/), so a client registered with one is unknown to the other.
export async function putClient(env: Env, c: ClientRecord, keyPrefix = "client:"): Promise<void> {
  await env.CLIENTS.put(`${keyPrefix}${c.clientId}`, JSON.stringify(c));
}

export async function getClient(env: Env, clientId: string, keyPrefix = "client:"): Promise<ClientRecord | null> {
  const raw = await env.CLIENTS.get(`${keyPrefix}${clientId}`);
  return raw ? (JSON.parse(raw) as ClientRecord) : null;
}
