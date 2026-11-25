import type { Env } from "../env.js";
import { logEvent, randomId, sha256Base64Url } from "../util.js";
import { getClient } from "../storage.js";
import { issuesSignedTokens, logRenewal, mintRefresh, readRefresh, signAccessToken, storeFor, verifyAccessToken, type MintedRefresh } from "../api/session.js";
import type { SessionGrant } from "../store/sessions.js";
import { planFor } from "../entitlement/entitlement.js";

// OAuth tokens for the task connector on api.septena.app.
//
// The same sessions as the apps (src/api/session.ts, src/store/sessions.ts,
// ADR 0040): a 1-hour access token, a renewed refresh token, and the user's
// Durable Object as the only authority. The token family is the session id.
// Reuse of a spent refresh token ends the family.
//
// Distinct prefixes keep the token kinds apart, and the signature covers them:
//   sa1.  / sr2.   app session (session.ts)       — never accepted here
//   sm2.  / smr2.  MCP task connector (this file) — accepted by /mcp and /v1/agent/events/stream only
// Tokens from before ADR 0040 (`sm1.`, `smr1.`) lived in KV under `v2:`. They
// still work. Until SIGNED_SESSIONS they are also still issued; after it an
// `smr1.` moves into the store on its next renewal. Remove both paths 31 days
// after the switch, when the last one has expired.

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

const ACCESS_PREFIX = "sm2";
const REFRESH_PREFIX = "smr2";
const LEGACY_ACCESS_PREFIX = "sm1.";
const LEGACY_REFRESH_PREFIX = "smr1.";
const MAX_TOKEN_LENGTH = 1_000;
const ACCESS_TTL_S = 60 * 60;                // 1h
const REFRESH_TTL_S = 30 * 24 * 60 * 60;     // 30d, slides on rotation (as live)
/// The refresh lifetime: a connection unused this long has expired.
export const MCP_REFRESH_TTL_S = REFRESH_TTL_S;
/// Registrations for this connector live under this KV prefix (oauth.ts).
export const MCP_CLIENT_PREFIX = "v2:client:";

export interface McpGrant {
  userId: string;
  clientId: string;
  scope: string;
  /// IANA zone the app sent at pairing; decides what "today" means.
  timeZone?: string;
  /// The token family: one connected agent, and its session id. Set by `verifyMcpAccess`.
  familyId?: string;
  /// The name the user gave the agent at pairing. Only the first issue of a
  /// family carries it; the store keeps it through refresh rotation.
  label?: string;
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

export function isMcpAccessToken(token: string): boolean {
  return token.startsWith(`${ACCESS_PREFIX}.`) || token.startsWith(LEGACY_ACCESS_PREFIX);
}

async function tokenResponse(env: Env, userId: string, familyId: string, scope: string, refresh: MintedRefresh): Promise<McpTokenResponse> {
  return {
    access_token: await signAccessToken(env, userId, familyId, refresh.hash, ACCESS_PREFIX),
    refresh_token: refresh.token,
    token_type: "Bearer",
    expires_in: ACCESS_TTL_S,
    scope,
  };
}

const sessionGrant = (g: McpGrant): SessionGrant => ({ clientId: g.clientId, scope: g.scope, timeZone: g.timeZone });

/// The KV tokens, until SIGNED_SESSIONS.
async function issueLegacyTokens(env: Env, grant: McpGrant, familyId: string): Promise<McpTokenResponse> {
  const access = `${LEGACY_ACCESS_PREFIX}${randomId(32)}`;
  const refresh = `${LEGACY_REFRESH_PREFIX}${randomId(32)}`;
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
  await noteConnection(env, { ...base, label: grant.label }, familyId);
  return { access_token: access, refresh_token: refresh, token_type: "Bearer", expires_in: ACCESS_TTL_S, scope: grant.scope };
}

/// Renews a KV token with KV tokens, until SIGNED_SESSIONS.
async function rotateLegacy(env: Env, legacy: LegacyRefresh): Promise<McpTokenResponse> {
  const { rec, key } = legacy;
  const tokens = await issueLegacyTokens(env, rec, rec.familyId);
  const spent: RefreshRecord = { ...rec, rotatedAt: Date.now() };
  // KV refuses an expiration under 60s out; a token that close to expiry
  // needs no replay marker.
  if (rec.expiresAt - Date.now() > 61_000) {
    await env.TOKENS.put(key, JSON.stringify(spent), { expiration: Math.ceil(rec.expiresAt / 1000) });
  } else {
    await env.TOKENS.delete(key);
  }
  return tokens;
}

export async function issueMcpTokens(env: Env, grant: McpGrant, familyId = randomId(16)): Promise<McpTokenResponse> {
  if (!issuesSignedTokens(env)) return issueLegacyTokens(env, grant, familyId);
  const refresh = await mintRefresh(env, REFRESH_PREFIX, grant.userId, familyId, REFRESH_TTL_S);
  await storeFor(env, grant.userId).createSession(refresh.hash, refresh.expiresAt, familyId, sessionGrant(grant));
  await noteConnection(env, grant, familyId);
  return tokenResponse(env, grant.userId, familyId, grant.scope, refresh);
}

/// The grant behind an access token, or null. Fails closed on any wrong
/// prefix, signature, expiry or ended session.
export async function verifyMcpAccess(env: Env, raw: string): Promise<McpGrant | null> {
  if (raw.length > MAX_TOKEN_LENGTH) return null;
  if (raw.startsWith(LEGACY_ACCESS_PREFIX)) return verifyLegacyAccess(env, raw);
  const claims = await verifyAccessToken(env, raw, ACCESS_PREFIX);
  if (!claims?.rt) return null;
  const session = await storeFor(env, claims.userId).authorizeSession(claims.sid, claims.rt);
  return session?.grant ? { ...session.grant, userId: claims.userId, familyId: claims.sid } : null;
}

async function verifyLegacyAccess(env: Env, raw: string): Promise<McpGrant | null> {
  const rec = await env.TOKENS.get(await accessKey(raw));
  if (!rec) return null;
  let a: AccessRecord;
  try {
    a = JSON.parse(rec) as AccessRecord;
  } catch {
    return null;
  }
  if (typeof a.userId !== "string" || Date.now() > a.expiresAt) return null;
  if (!(await storeFor(env, a.userId).legacyAgentAllowed(a.familyId, a.expiresAt - ACCESS_TTL_S * 1000))) return null;
  return { userId: a.userId, clientId: a.clientId, scope: a.scope, timeZone: a.timeZone, familyId: a.familyId };
}

/// Lists the family in Settings > AI & Agents > Agents. The index never
/// blocks a token: a failure here only logs.
async function noteConnection(env: Env, grant: McpGrant, familyId: string): Promise<void> {
  try {
    const client = await getClient(env, grant.clientId, MCP_CLIENT_PREFIX);
    const name = client?.name?.trim().slice(0, 60) || "Claude";
    const label = grant.label?.trim().slice(0, AGENT_NAME_MAX) || null;
    const store = storeFor(env, grant.userId);
    if (issuesSignedTokens(env)) await store.noteAgent(familyId, grant.clientId, name, grant.scope, Date.now(), label);
    else await store.recordConnection(familyId, grant.clientId, name, grant.scope, Date.now(), label);
  } catch (e) {
    logEvent("mcp_connection_index_failed", { error: String(e) });
  }
}

/// Longest agent name the user can give (pairing and Settings rename).
export const AGENT_NAME_MAX = 40;

/// After a new agent pairs (an authorization-code exchange, not a refresh):
/// the client's older families and the agent the user said it replaces stop
/// working, so one agent is one row. Then the agent count is checked against
/// the plan's `connectedAgents` limit. That check only logs: it never blocks
/// a pairing. Never throws: the tokens are already issued.
export async function settleNewAgent(
  env: Env,
  grant: { userId: string; clientId: string; familyId: string; replaces?: string },
): Promise<void> {
  try {
    const store = storeFor(env, grant.userId);
    const old = await store.otherFamiliesOfClient(grant.clientId, grant.familyId);
    const targets = new Set(old);
    if (grant.replaces && grant.replaces !== grant.familyId) targets.add(grant.replaces);
    for (const familyId of targets) await disconnectFamily(env, grant.userId, familyId);
    if (targets.size) logEvent("mcp_agent_replaced", { replaced: targets.size });

    const count = await store.connectedAgentCount();
    const limit = (await planFor(env, grant.userId)).limits.connectedAgents;
    if (limit !== null && count > limit) {
      logEvent("agent_limit_over", { userId: grant.userId, count, limit, enforced: false });
    }
  } catch (e) {
    logEvent("mcp_agent_settle_failed", { error: String(e) });
  }
}

/// Disconnects one app from Settings: kills its tokens and its list row.
/// False when the family is not in this user's store.
export async function disconnectFamily(env: Env, userId: string, familyId: string): Promise<boolean> {
  const store = storeFor(env, userId);
  // Each step repeats safely, and the last one drops the row: a disconnect
  // that failed halfway can be retried.
  if (!(await store.ownsAgent(familyId))) return false;
  await revokeLegacyFamily(env, familyId);
  return store.endAgent(familyId);
}

/// Ends a family whether or not it has a list row.
async function endFamily(env: Env, userId: string, familyId: string): Promise<void> {
  await revokeLegacyFamily(env, familyId);
  await storeFor(env, userId).endSession(familyId);
}

async function revokeLegacyFamily(env: Env, familyId: string): Promise<void> {
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

interface LegacyRefresh {
  ref: { userId: string; sid: string; hash: string };
  rec: RefreshRecord;
  key: string;
}

async function readLegacyRefresh(env: Env, raw: string): Promise<LegacyRefresh | null> {
  const key = await refreshKey(raw);
  const stored = await env.TOKENS.get(key);
  if (!stored) return null;
  const rec = JSON.parse(stored) as RefreshRecord;
  return { ref: { userId: rec.userId, sid: rec.familyId, hash: await sha256Base64Url(raw) }, rec, key };
}

/// Trades the refresh token for a new pair in the same family.
export async function redeemMcpRefresh(env: Env, raw: string, clientId: string): Promise<McpRefreshResult> {
  if (raw.length > MAX_TOKEN_LENGTH) return { ok: false, reason: "not_found" };
  let ref = await readRefresh(env, REFRESH_PREFIX, raw);
  if (!ref && raw.startsWith(LEGACY_REFRESH_PREFIX)) {
    const legacy = await readLegacyRefresh(env, raw);
    if (!legacy) return { ok: false, reason: "not_found" };
    if (legacy.rec.rotatedAt) {
      await endFamily(env, legacy.rec.userId, legacy.rec.familyId);
      await env.TOKENS.delete(legacy.key);
      return { ok: false, reason: "replayed" };
    }
    if (legacy.rec.clientId !== clientId) return { ok: false, reason: "client_mismatch" };
    if (Date.now() > legacy.rec.expiresAt) return { ok: false, reason: "expired" };
    ref = legacy.ref;
    const store = storeFor(env, ref.userId);
    const issuedAt = legacy.rec.expiresAt - REFRESH_TTL_S * 1000;
    if (!(await store.legacyAgentAllowed(ref.sid, issuedAt))) return { ok: false, reason: "not_found" };
    // A family that already moved stays in the store, also after a rollback.
    if (!issuesSignedTokens(env) && !(await store.ownsMovedAgent(ref.sid))) {
      return { ok: true, tokens: await rotateLegacy(env, legacy) };
    }
    await store.adoptSession(ref.hash, issuedAt, legacy.rec.expiresAt, ref.sid, sessionGrant(legacy.rec));
  }
  if (!ref) return { ok: false, reason: "not_found" };

  const next = await mintRefresh(env, REFRESH_PREFIX, ref.userId, ref.sid, REFRESH_TTL_S);
  const res = await storeFor(env, ref.userId).renewSession(ref.hash, next.hash, next.expiresAt, ref.sid, clientId);
  logRenewal("agent", ref.userId, res);
  if (!res.ok) {
    if (res.reason === "reused") {
      await revokeLegacyFamily(env, ref.sid);
      return { ok: false, reason: "replayed" };
    }
    return { ok: false, reason: res.reason };
  }
  if (!res.grant) return { ok: false, reason: "not_found" };
  await noteConnection(env, { ...res.grant, userId: ref.userId }, ref.sid);
  return { ok: true, tokens: await tokenResponse(env, ref.userId, ref.sid, res.grant.scope, next) };
}

/// RFC 7009. Access token: that token. Refresh token: its family, at once.
/// Unknown tokens are not an error.
export async function revokeMcpToken(env: Env, raw: string): Promise<"access" | "refresh" | "none"> {
  if (raw.length > MAX_TOKEN_LENGTH) return "none";
  const claims = await verifyAccessToken(env, raw, ACCESS_PREFIX);
  if (claims?.rt) return (await storeFor(env, claims.userId).revokeSessionAccess(claims.sid, claims.rt)) ? "access" : "none";
  if (raw.startsWith(LEGACY_ACCESS_PREFIX)) {
    const key = await accessKey(raw);
    if (!(await env.TOKENS.get(key))) return "none";
    await env.TOKENS.delete(key);
    return "access";
  }
  const ref = await readRefresh(env, REFRESH_PREFIX, raw)
    ?? (raw.startsWith(LEGACY_REFRESH_PREFIX) ? (await readLegacyRefresh(env, raw))?.ref : null);
  if (!ref) return "none";
  await endFamily(env, ref.userId, ref.sid);
  return "refresh";
}
