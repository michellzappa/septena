import type { Env } from "../env.js";
import { randomId, sha256Base64Url } from "../util.js";

// OAuth tokens for the task connector on api.septena.app.
//
// Same model as the app sessions (src/api/session.ts): a 1-hour access token, a rotating refresh token, and
// KV records keyed by sha256(token) so a KV leak yields no usable bearer. A
// spent refresh token presented again is a replay and kills the family.
//
// Distinct prefixes keep the three token kinds apart:
//   sa1.  / sr1.   app session (session.ts)       — never accepted here
//   sm1.  / smr1.  MCP task connector (this file)         — never accepted by /v1
// KV keys live under `v2:`, apart from the `token:`, `refresh:` and
// `rtfamily:` records the retired CloudKit connector left (they expire by TTL).

export const MCP_READ_SCOPE = "tasks:read";
export const MCP_WRITE_SCOPE = "tasks:write";
/// Every scope this server knows, for discovery.
export const MCP_SCOPES = [MCP_READ_SCOPE, MCP_WRITE_SCOPE];
/// What a new pairing grants. Grants issued before 2026-11-19 carry
/// `tasks:read` only and keep it through refresh rotation: those connections
/// must pair again to write.
export const MCP_GRANT_SCOPE = MCP_SCOPES.join(" ");

export function hasScope(grant: Pick<McpGrant, "scope">, scope: string): boolean {
  return grant.scope.split(" ").includes(scope);
}

const ACCESS_PREFIX = "sm1.";
const REFRESH_PREFIX = "smr1.";
const ACCESS_TTL_S = 60 * 60;                // 1h
const REFRESH_TTL_S = 30 * 24 * 60 * 60;     // 30d, slides on rotation (as live)

export interface McpGrant {
  userId: string;
  clientId: string;
  scope: string;
  /// IANA zone the app sent at pairing; decides what "today" means.
  timeZone?: string;
}

interface AccessRecord extends McpGrant {
  familyId: string;
  expiresAt: number;
}

interface RefreshRecord extends McpGrant {
  familyId: string;
  expiresAt: number;
  rotatedAt?: number;
}

interface FamilyRecord {
  refreshKey: string;
  accessKey: string;
}

const accessKey = async (raw: string) => `v2:access:${await sha256Base64Url(raw)}`;
const refreshKey = async (raw: string) => `v2:refresh:${await sha256Base64Url(raw)}`;
const familyKey = (id: string) => `v2:family:${id}`;

export interface McpTokenResponse {
  access_token: string;
  refresh_token: string;
  token_type: "Bearer";
  expires_in: number;
  scope: string;
}

export async function issueMcpTokens(env: Env, grant: McpGrant, familyId = randomId(16)): Promise<McpTokenResponse> {
  const access = `${ACCESS_PREFIX}${randomId(32)}`;
  const refresh = `${REFRESH_PREFIX}${randomId(32)}`;
  const now = Date.now();
  const base: McpGrant = { userId: grant.userId, clientId: grant.clientId, scope: grant.scope, timeZone: grant.timeZone };
  const aKey = await accessKey(access);
  const rKey = await refreshKey(refresh);
  const accessRec: AccessRecord = { ...base, familyId, expiresAt: now + ACCESS_TTL_S * 1000 };
  const refreshRec: RefreshRecord = { ...base, familyId, expiresAt: now + REFRESH_TTL_S * 1000 };
  const fam: FamilyRecord = { refreshKey: rKey, accessKey: aKey };
  await Promise.all([
    env.TOKENS.put(aKey, JSON.stringify(accessRec), { expirationTtl: ACCESS_TTL_S }),
    env.TOKENS.put(rKey, JSON.stringify(refreshRec), { expirationTtl: REFRESH_TTL_S }),
    env.TOKENS.put(familyKey(familyId), JSON.stringify(fam), { expirationTtl: REFRESH_TTL_S }),
  ]);
  return { access_token: access, refresh_token: refresh, token_type: "Bearer", expires_in: ACCESS_TTL_S, scope: grant.scope };
}

/// The grant behind a preview access token, or null. Fails closed on any
/// wrong prefix, unknown, expired or unparseable record.
export async function verifyMcpAccess(env: Env, raw: string): Promise<McpGrant | null> {
  if (!raw.startsWith(ACCESS_PREFIX) || raw.length > 200) return null;
  const rec = await env.TOKENS.get(await accessKey(raw));
  if (!rec) return null;
  try {
    const a = JSON.parse(rec) as AccessRecord;
    if (typeof a.userId !== "string" || Date.now() > a.expiresAt) return null;
    return { userId: a.userId, clientId: a.clientId, scope: a.scope, timeZone: a.timeZone };
  } catch {
    return null;
  }
}

async function revokeFamily(env: Env, familyId: string): Promise<void> {
  const raw = await env.TOKENS.get(familyKey(familyId));
  if (raw) {
    const fam = JSON.parse(raw) as FamilyRecord;
    await Promise.all([env.TOKENS.delete(fam.refreshKey), env.TOKENS.delete(fam.accessKey)]);
  }
  await env.TOKENS.delete(familyKey(familyId));
}

export type McpRefreshResult =
  | { ok: true; tokens: McpTokenResponse }
  | { ok: false; reason: "not_found" | "expired" | "replayed" | "client_mismatch" };

/// Rotate: spend the refresh token, mint a new pair in the same family. The
/// spent record stays until its original expiry so a replay is detected.
export async function redeemMcpRefresh(env: Env, raw: string, clientId: string): Promise<McpRefreshResult> {
  if (!raw.startsWith(REFRESH_PREFIX) || raw.length > 200) return { ok: false, reason: "not_found" };
  const key = await refreshKey(raw);
  const stored = await env.TOKENS.get(key);
  if (!stored) return { ok: false, reason: "not_found" };
  const rec = JSON.parse(stored) as RefreshRecord;
  if (rec.rotatedAt) {
    await revokeFamily(env, rec.familyId);
    await env.TOKENS.delete(key);
    return { ok: false, reason: "replayed" };
  }
  if (rec.clientId !== clientId) return { ok: false, reason: "client_mismatch" };
  if (Date.now() > rec.expiresAt) {
    await env.TOKENS.delete(key);
    return { ok: false, reason: "expired" };
  }
  const tokens = await issueMcpTokens(env, rec, rec.familyId);
  const spent: RefreshRecord = { ...rec, rotatedAt: Date.now() };
  // KV refuses an expiration under 60s out; a token that close to expiry
  // needs no replay marker.
  if (rec.expiresAt - Date.now() > 61_000) {
    await env.TOKENS.put(key, JSON.stringify(spent), { expiration: Math.ceil(rec.expiresAt / 1000) });
  } else {
    await env.TOKENS.delete(key);
  }
  return { ok: true, tokens };
}

/// RFC 7009. Access token: delete it. Refresh token: kill its family (and so
/// the current access token). Unknown tokens are not an error.
export async function revokeMcpToken(env: Env, raw: string): Promise<"access" | "refresh" | "none"> {
  if (raw.startsWith(ACCESS_PREFIX)) {
    const key = await accessKey(raw);
    if (!(await env.TOKENS.get(key))) return "none";
    await env.TOKENS.delete(key);
    return "access";
  }
  if (raw.startsWith(REFRESH_PREFIX)) {
    const key = await refreshKey(raw);
    const stored = await env.TOKENS.get(key);
    if (!stored) return "none";
    await revokeFamily(env, (JSON.parse(stored) as RefreshRecord).familyId);
    await env.TOKENS.delete(key);
    return "refresh";
  }
  return "none";
}
