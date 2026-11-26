import type { Context } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { getClient, putClient } from "../storage.js";
import { escapeHtml, logEvent, randomId, readCookie, sha256Base64Url } from "../util.js";
import { isValidTz } from "../tz.js";
import { registerClient } from "../oauth/register.js";
import { validateRedirectUri } from "../oauth/redirects.js";
import { storeFor } from "../api/session.js";
import { emailSignInEnabled, verifyEmailAccount, zEmailAddress } from "../api/emailSignIn.js";
import { SIGN_IN } from "../generated/registries.js";
import { pairApproveUrl, pairQrMatrix, pairQrSvg } from "./pairQr.js";
import { REVIEWER_MAX_FAILURES, reviewerCodeMatches, reviewerMode } from "./reviewer.js";
import { AGENT_NAME_MAX, MCP_CLIENT_PREFIX, MCP_GRANT_SCOPE, MCP_SCOPES, issueMcpTokens, redeemMcpRefresh, revokeMcpToken, settleNewAgent } from "./tokens.js";

// OAuth 2.1 for the MCP task connector on api.septena.app (phase 2,
// "shadow", of docs/SEPTASK_BACKEND.md in the app repo; read-write since
// 2026-11-19).
//
// Web Sign in with Apple is not configured, so identity comes from APP
// PAIRING instead of a web login:
//   1. Claude registers (DCR) and opens /oauth/authorize here.
//   2. The page shows a short code and refreshes itself.
//   3. The user enters the code in Septask; the app calls
//      POST /v1/pair/approve with its own bearer token, which binds its user id
//      to the pending authorization (PairingStore).
//   4. The page's next refresh sees the approval and redirects back to Claude
//      with an auth code (+ RFC 9207 `iss`).
//   5. Claude trades the code (PKCE) at /oauth/token for an `sm2.` access token
//      and a rotating `smr2.` refresh token, scope `tasks:read tasks:write`.
//
// KV keys are under `v2:`.

const CLIENT_PREFIX = MCP_CLIENT_PREFIX;
const CODE_PREFIX = "v2:code:";
const CODE_TTL_S = 300;
export const PAIR_TTL_MS = 10 * 60 * 1000;
const PAIR_COOKIE = "septena_pair";
/// Wrong codes a user may enter per window before approve/inspect/deny answers 429.
export const PAIR_MAX_FAILURES = 5;
/// Device sign-in starts allowed per IP in one pairing window.
export const DEVICE_START_MAX_PER_IP = 20;
/// Failed device polls (unknown/wrong secret/wrong purpose) allowed per IP per window.
export const DEVICE_POLL_MAX_FAILURES_PER_IP = PAIR_MAX_FAILURES;

async function ipRateKey(prefix: string, ip: string): Promise<string> {
  const bucket = Math.floor(Date.now() / PAIR_TTL_MS);
  const ipHash = await sha256Base64Url(ip.trim());
  return `${prefix}:${ipHash}:${bucket}`;
}

async function ipRateCount(env: Env, prefix: string, ip: string): Promise<number> {
  const raw = await env.STATE.get(await ipRateKey(prefix, ip));
  const n = raw ? Number.parseInt(raw, 10) : 0;
  return Number.isFinite(n) && n > 0 ? n : 0;
}

async function noteIpRateEvent(env: Env, prefix: string, ip: string): Promise<number> {
  const key = await ipRateKey(prefix, ip);
  const prev = await env.STATE.get(key);
  const next = (prev ? Number.parseInt(prev, 10) || 0 : 0) + 1;
  await env.STATE.put(key, String(next), { expirationTtl: PAIR_TTL_MS / 1000 });
  return next;
}

// No 0/O, 1/I/L: the code is read off one screen and typed into another.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 8;
const CODE_RE = new RegExp(`^[${CODE_ALPHABET}]{${CODE_LENGTH}}$`);

function newPairCode(): string {
  // Rejection sampling keeps every symbol equally likely.
  const limit = 256 - (256 % CODE_ALPHABET.length);
  let out = "";
  while (out.length < CODE_LENGTH) {
    for (const b of crypto.getRandomValues(new Uint8Array(16))) {
      if (b < limit && out.length < CODE_LENGTH) out += CODE_ALPHABET[b % CODE_ALPHABET.length];
    }
  }
  return out;
}

/// Uppercases and drops spaces and dashes; null unless it is a well-formed code.
export function normalizePairCode(input: string): string | null {
  const code = input.toUpperCase().replace(/[\s-]/g, "");
  return CODE_RE.test(code) ? code : null;
}

export function pairingFor(env: Env, code: string) {
  return env.PAIRING.get(env.PAIRING.idFromName(`pair:${code}`));
}

// ---- discovery ----

export function authServerMetadata(c: Context<{ Bindings: Env }>) {
  const base = c.env.API_PUBLIC_URL;
  return c.json({
    issuer: base,
    authorization_endpoint: `${base}/oauth/authorize`,
    token_endpoint: `${base}/oauth/token`,
    registration_endpoint: `${base}/oauth/register`,
    revocation_endpoint: `${base}/oauth/revoke`,
    scopes_supported: MCP_SCOPES,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["none"],
    revocation_endpoint_auth_methods_supported: ["none"],
    authorization_response_iss_parameter_supported: true,
  });
}

export function protectedResourceMetadata(c: Context<{ Bindings: Env }>) {
  const base = c.env.API_PUBLIC_URL;
  return c.json({
    resource: base,
    authorization_servers: [base],
    scopes_supported: MCP_SCOPES,
    bearer_methods_supported: ["header"],
  });
}

// ---- registration ----

export function register(c: Context<{ Bindings: Env }>) {
  return registerClient(c, (env, rec) => putClient(env, rec, CLIENT_PREFIX), "preview_oauth_register");
}

// ---- authorize: show the pairing code ----

export async function authorize(c: Context<{ Bindings: Env }>) {
  const q = new URL(c.req.url).searchParams;
  const clientId = q.get("client_id");
  const redirectUri = q.get("redirect_uri");
  const state = q.get("state");
  const codeChallenge = q.get("code_challenge");

  if (q.get("response_type") !== "code") return c.text("unsupported_response_type", 400);
  if (!clientId || !redirectUri || !state || !codeChallenge) return c.text("invalid_request", 400);
  if (q.get("code_challenge_method") !== "S256") return c.text("PKCE S256 required", 400);
  if (clientId.length > 100 || state.length > 1_000 || !/^[A-Za-z0-9_-]{43,128}$/.test(codeChallenge)) {
    return c.text("invalid_request", 400);
  }
  // RFC 8707: when the client names a resource, it must be this server.
  const resource = q.get("resource");
  if (resource && resource.replace(/\/mcp\/?$/, "").replace(/\/$/, "") !== c.env.API_PUBLIC_URL) {
    return c.text("invalid_target", 400);
  }

  const client = await getClient(c.env, clientId, CLIENT_PREFIX);
  if (!client) return c.text("unknown client", 400);
  if (!client.redirectUris.includes(redirectUri)) return c.text("redirect_uri not registered", 400);
  const rejection = validateRedirectUri(redirectUri);
  if (rejection) {
    logEvent("preview_oauth_authorize", { clientId, ok: false, error: "redirect_rejected", reason: rejection });
    return c.text(`redirect_uri rejected: ${rejection}`, 400);
  }

  const pendingId = randomId(24);
  const expiresAt = Date.now() + PAIR_TTL_MS;
  let code: string | null = null;
  for (let i = 0; i < 4 && !code; i++) {
    const candidate = newPairCode();
    const created = await pairingFor(c.env, candidate).create({
      pendingId,
      clientId,
      purpose: "connector",
      clientName: client.name,
      redirectUri,
      oauthState: state,
      codeChallenge,
      expiresAt,
    });
    if (created) code = candidate;
  }
  if (!code) return c.text("pairing unavailable, try again", 503);

  logEvent("preview_oauth_authorize", { clientId, ok: true });
  return pairPage(c, {
    code,
    clientName: client.name ?? "Claude",
    redirectHost: new URL(redirectUri).host,
    setCookie: [
      `${PAIR_COOKIE}=${code}.${pendingId}`,
      "Path=/oauth",
      "HttpOnly",
      "Secure",
      "SameSite=Lax",
      `Max-Age=${PAIR_TTL_MS / 1000}`,
    ].join("; "),
  });
}

// ---- the page polls here until the app approves ----

export async function pairContinue(c: Context<{ Bindings: Env }>) {
  const cookie = readCookie(c.req.raw, PAIR_COOKIE) ?? "";
  const [rawCode, pendingId] = cookie.split(".");
  const code = rawCode ? normalizePairCode(rawCode) : null;
  if (!code || !pendingId || !/^[A-Za-z0-9_-]{20,64}$/.test(pendingId)) {
    return messagePage(c, "This sign-in has no pairing code. Go back to Claude and connect again.", 400);
  }
  const pairing = pairingFor(c.env, code);
  const s = await pairing.status(pendingId, "connector");
  if (s.status === "gone") {
    return messagePage(c, "This code expired. Go back to Claude and connect again.", 400, true);
  }
  if (s.status === "denied") {
    await pairing.consumeDenied(pendingId, "connector");
    return messagePage(c, "This sign-in was declined. Go back to Claude and connect again.", 400, true);
  }
  if (s.status === "pending") {
    return pairPage(c, {
      code,
      clientName: s.clientName ?? "Claude",
      redirectHost: s.redirectUri ? new URL(s.redirectUri).host : "",
    });
  }

  const taken = await pairing.take(pendingId, "connector");
  if (!taken) return messagePage(c, "This code expired. Go back to Claude and connect again.", 400, true);
  const { pending, approval } = taken;

  const authCode = randomId(32);
  await c.env.STATE.put(
    `${CODE_PREFIX}${authCode}`,
    JSON.stringify({
      userId: approval.userId,
      timeZone: approval.timeZone,
      label: approval.label,
      replaces: approval.replaces,
      clientId: pending.clientId,
      redirectUri: pending.redirectUri,
      codeChallenge: pending.codeChallenge,
    } satisfies StoredCode),
    { expirationTtl: CODE_TTL_S },
  );
  logEvent("preview_pair_finished", { clientId: pending.clientId });

  const back = new URL(pending.redirectUri);
  back.searchParams.set("code", authCode);
  back.searchParams.set("state", pending.oauthState);
  back.searchParams.set("iss", c.env.API_PUBLIC_URL);
  return new Response(null, {
    status: 302,
    headers: {
      Location: back.toString(),
      "Set-Cookie": `${PAIR_COOKIE}=; Path=/oauth; Max-Age=0; HttpOnly; Secure; SameSite=Lax`,
      "Cache-Control": "no-store",
    },
  });
}

interface StoredCode {
  userId: string;
  timeZone?: string;
  /// The agent's name and the agent it replaces, from the approval.
  label?: string;
  replaces?: string;
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
}

// ---- the page's email path (ADR 0047, issue #636) ----

const zPairEmailBody = z.object({
  email: zEmailAddress,
  code: z.string().trim().regex(/^\d{6}$/),
  timeZone: z.string().max(64).optional(),
}).strict();

/// POST /oauth/pair/email: the authorize page's own email form. The pairing
/// cookie proves this browser opened the code; the email code proves the
/// account. A right code approves the pairing for that account, and the page
/// then finishes through /oauth/pair/continue as after an app approval.
export async function pairEmail(c: Context<{ Bindings: Env }>) {
  const noStore = { "Cache-Control": "no-store" };
  if (c.req.header("Origin") !== c.env.API_PUBLIC_URL) return c.json({ error: "origin_not_allowed" }, 403, noStore);
  const cookie = readCookie(c.req.raw, PAIR_COOKIE) ?? "";
  const [rawCode, pendingId] = cookie.split(".");
  const code = rawCode ? normalizePairCode(rawCode) : null;
  if (!code || !pendingId) return c.json({ error: "expired_or_unknown" }, 410, noStore);
  let raw: unknown;
  try { raw = await c.req.json(); } catch { return c.json({ error: "invalid_request" }, 400, noStore); }
  const body = zPairEmailBody.safeParse(raw);
  if (!body.success) return c.json({ error: "invalid_request" }, 400, noStore);

  const pairing = pairingFor(c.env, code);
  if ((await pairing.status(pendingId, "connector")).status !== "pending") {
    return c.json({ error: "expired_or_unknown" }, 410, noStore);
  }
  const account = await verifyEmailAccount(c.env, body.data, c.req.header("CF-Connecting-IP"));
  if (!account.ok) {
    return c.json({ error: account.error, ...(account.attemptsLeft !== undefined ? { attemptsLeft: account.attemptsLeft } : {}) }, account.status, noStore);
  }
  const timeZone = body.data.timeZone && isValidTz(body.data.timeZone) ? body.data.timeZone : undefined;
  const res = await pairing.approve({ userId: account.userId, timeZone }, "connector");
  if (res.outcome !== "ok") return c.json({ error: "expired_or_unknown" }, 410, noStore);
  logEvent("preview_pair_approve", { ok: true, kind: "connector", via: "email", created: account.created });
  return c.json({ ok: true }, 200, noStore);
}

// ---- the page's reviewer path (ADR 0055, septena#85) ----

const zPairReviewerBody = z.object({ code: z.string().trim().min(1).max(200) }).strict();

/// POST /oauth/pair/reviewer: a directory reviewer types the reviewer code on
/// the authorize page. The pairing cookie proves this browser opened the
/// pairing; a right code approves it for the demo account and nothing else.
/// Off (404) unless reviewer mode is on. The code is never logged.
export async function pairReviewer(c: Context<{ Bindings: Env }>) {
  const noStore = { "Cache-Control": "no-store" };
  const mode = reviewerMode(c.env);
  if (!mode) return c.json({ error: "not_found" }, 404, noStore);
  if (c.req.header("Origin") !== c.env.API_PUBLIC_URL) return c.json({ error: "origin_not_allowed" }, 403, noStore);
  const cookie = readCookie(c.req.raw, PAIR_COOKIE) ?? "";
  const [rawCode, pendingId] = cookie.split(".");
  const code = rawCode ? normalizePairCode(rawCode) : null;
  if (!code || !pendingId) return c.json({ error: "expired_or_unknown" }, 410, noStore);
  let raw: unknown;
  try { raw = await c.req.json(); } catch { return c.json({ error: "invalid_request" }, 400, noStore); }
  const body = zPairReviewerBody.safeParse(raw);
  if (!body.success) return c.json({ error: "invalid_request" }, 400, noStore);

  const ip = c.req.header("CF-Connecting-IP") ?? "unknown";
  if ((await ipRateCount(c.env, "rl:reviewer", ip)) >= REVIEWER_MAX_FAILURES) {
    logEvent("reviewer_pair", { ok: false, reason: "ip_limited" });
    return c.json({ error: "too_many_attempts" }, 429, noStore);
  }
  const pairing = pairingFor(c.env, code);
  if ((await pairing.status(pendingId, "connector")).status !== "pending") {
    return c.json({ error: "expired_or_unknown" }, 410, noStore);
  }
  if (!(await reviewerCodeMatches(c.env, body.data.code))) {
    await noteIpRateEvent(c.env, "rl:reviewer", ip);
    logEvent("reviewer_pair", { ok: false, reason: "wrong_code" });
    return c.json({ error: "invalid_code" }, 401, noStore);
  }
  const res = await pairing.approve({ userId: mode.userId }, "connector");
  if (res.outcome !== "ok") return c.json({ error: "expired_or_unknown" }, 410, noStore);
  logEvent("reviewer_pair", { ok: true });
  return c.json({ ok: true }, 200, noStore);
}

// ---- device sign-in by approval (ADR 0016, issue #170) ----
//
// A new device (the Android client first) has no Apple identity. It calls
// POST /v1/auth/device/start, shows the 8-character code, and the user enters
// it where Septask already takes connector codes (POST /v1/pair/approve, which
// handles both purposes). The device polls POST /v1/auth/device/poll with the
// secret only it holds; after approval the poll returns an app session for the
// approving user. The purpose check in PairingStore keeps the two flows apart.

export const zDeviceStartBody = z.object({
  clientName: z.string().regex(/^[\w .()-]{1,40}$/),
}).strict();

export const zDevicePollBody = z.object({
  code: z.string().min(1).max(32),
  pollSecret: z.string().regex(/^[A-Za-z0-9_-]{20,64}$/),
  /// Web clients request `"cookie"` so the refresh token stays in an HttpOnly
  /// cookie on api.septena.app instead of the JSON response body (WEB_CLIENT_SPEC.md §4).
  sessionMode: z.enum(["body", "cookie"]).optional(),
}).strict();

/// `qr` is the sign-in QR (src/shadow/pairQr.ts) for clients that draw it;
/// older clients ignore the field and show the code only.
export type DeviceStartResult = {
  code: string;
  pollSecret: string;
  expiresIn: number;
  interval: number;
  qr: { size: number; modules: string };
};

export type DeviceStartOutcome =
  | { ok: true; data: DeviceStartResult }
  | { ok: false; status: 429; error: "too_many_attempts" }
  | { ok: false; status: 503; error: "pairing_unavailable" };

/// Opens a code that a signed-in app approves. `secret` stays with whoever
/// started it and is needed to finish.
export async function openApprovalCode(
  env: Env,
  purpose: "device" | "plus",
  clientName: string,
  clientIp?: string | null,
): Promise<{ ok: true; code: string; secret: string } | { ok: false; reason: "rate_limited" | "unavailable" }> {
  if (clientIp && (await ipRateCount(env, "rl:devstart", clientIp)) >= DEVICE_START_MAX_PER_IP) {
    return { ok: false, reason: "rate_limited" };
  }
  if (clientIp) await noteIpRateEvent(env, "rl:devstart", clientIp);

  const secret = randomId(24);
  const expiresAt = Date.now() + PAIR_TTL_MS;
  for (let i = 0; i < 4; i++) {
    const code = newPairCode();
    const created = await pairingFor(env, code).create({
      purpose,
      pendingId: secret,
      clientId: purpose,
      clientName,
      redirectUri: "",
      oauthState: "",
      codeChallenge: "",
      expiresAt,
    });
    if (created) return { ok: true, code, secret };
  }
  return { ok: false, reason: "unavailable" };
}

export async function startDevicePairing(
  env: Env,
  body: z.infer<typeof zDeviceStartBody>,
  clientIp?: string | null,
): Promise<DeviceStartOutcome> {
  const opened = await openApprovalCode(env, "device", body.clientName, clientIp);
  if (!opened.ok) {
    logEvent("device_pair_start", { ok: false, reason: opened.reason });
    return opened.reason === "rate_limited"
      ? { ok: false, status: 429, error: "too_many_attempts" }
      : { ok: false, status: 503, error: "pairing_unavailable" };
  }
  logEvent("device_pair_start", { ok: true, client: body.clientName });
  return {
    ok: true,
    data: {
      code: opened.code,
      pollSecret: opened.secret,
      expiresIn: PAIR_TTL_MS / 1000,
      interval: 3,
      qr: pairQrMatrix(pairApproveUrl(env.API_PUBLIC_URL, opened.code)),
    },
  };
}

export type DevicePollResult =
  | { status: "pending" }
  | { status: "denied" }
  | { status: "gone" }
  | { status: "rate_limited" }
  | { status: "approved"; userId: string };

/// One-shot on approval (or denial): the caller issues the session; a second
/// poll is gone. Failed polls (unknown code, wrong secret, wrong purpose)
/// count toward the per-IP failure limit.
export async function pollDevicePairing(
  env: Env,
  body: z.infer<typeof zDevicePollBody>,
  clientIp?: string | null,
): Promise<DevicePollResult> {
  if (clientIp && (await ipRateCount(env, "rl:devpoll", clientIp)) >= DEVICE_POLL_MAX_FAILURES_PER_IP) {
    logEvent("device_pair_poll", { ok: false, reason: "rate_limited" });
    return { status: "rate_limited" };
  }
  const code = normalizePairCode(body.code);
  if (!code) {
    if (clientIp) await noteIpRateEvent(env, "rl:devpoll", clientIp);
    return { status: "gone" };
  }
  const pairing = pairingFor(env, code);
  const s = await pairing.status(body.pollSecret, "device");
  if (s.status === "pending") return { status: "pending" };
  if (s.status === "denied") {
    const consumed = await pairing.consumeDenied(body.pollSecret, "device");
    if (!consumed) return { status: "gone" };
    logEvent("device_pair_denied", { client: s.clientName });
    return { status: "denied" };
  }
  if (s.status !== "approved") {
    if (clientIp) await noteIpRateEvent(env, "rl:devpoll", clientIp);
    return { status: "gone" };
  }
  const taken = await pairing.take(body.pollSecret, "device");
  if (!taken) {
    if (clientIp) await noteIpRateEvent(env, "rl:devpoll", clientIp);
    return { status: "gone" };
  }
  logEvent("device_pair_finished", { client: taken.pending.clientName });
  return { status: "approved", userId: taken.approval.userId };
}

// ---- POST /v1/pair/approve & /v1/pair/deny (called by the app, bearer-authenticated) ----

export const zPairKind = z.enum(["connector", "device"]);

/// An agent's name, as the user types it at pairing or in Settings.
export const zAgentName = z.string().trim().min(1).max(AGENT_NAME_MAX).regex(/^[^\u0000-\u001f\u007f]+$/);

export const zPairApproveBody = z.object({
  code: z.string().min(1).max(32),
  timeZone: z.string().max(64).optional(),
  /// The kind the user confirmed after /v1/pair/inspect. Optional only for
  /// legacy connector-only app builds from before 2026-11-22 (defaults to
  /// "connector"; a "device" code always requires explicit kind: "device").
  kind: zPairKind.optional(),
  /// Connector codes: the name the user gives the agent. Absent = the
  /// client's registered name.
  name: zAgentName.optional(),
  /// Connector codes: the agent (connection id) this one replaces. Its
  /// tokens stop working when the new agent finishes pairing.
  replaces: z.string().regex(/^[A-Za-z0-9_-]{8,64}$/).optional(),
}).strict();

export const zPairInspectBody = z.object({
  code: z.string().min(1).max(32),
}).strict();

export const zPairDenyBody = z.object({
  code: z.string().min(1).max(32),
  kind: zPairKind.optional(),
}).strict();

type PairFailure = { ok: false; status: 404 | 409 | 429; error: "invalid_code" | "code_used" | "too_many_attempts" };

export type PairApproveResult =
  | { ok: true; client: string; kind: "connector" | "device" }
  | PairFailure;

export type PairInspectResult =
  | { ok: true; kind: "connector" | "device"; client: string; expiresIn: number }
  | PairFailure;

/// Shows what a code asks for before the user approves it. A wrong code counts
/// toward the same failure limit as approve, so inspect cannot be used to
/// guess codes faster.
export async function inspectPairing(
  env: Env,
  userId: string,
  body: z.infer<typeof zPairInspectBody>,
): Promise<PairInspectResult> {
  const store = storeFor(env, userId);
  if ((await store.pairFailures()) >= PAIR_MAX_FAILURES) {
    logEvent("pair_inspect", { ok: false, reason: "rate_limited" });
    return { ok: false, status: 429, error: "too_many_attempts" };
  }
  const code = normalizePairCode(body.code);
  const res = code ? await pairingFor(env, code).peek() : { outcome: "not_found" as const };
  if (res.outcome === "ok") {
    logEvent("pair_inspect", { ok: true, kind: res.purpose });
    return {
      ok: true,
      kind: res.purpose,
      client: res.clientName ?? (res.purpose === "device" ? "A new device" : "Claude"),
      expiresIn: Math.max(0, Math.round((res.expiresAt - Date.now()) / 1000)),
    };
  }
  await store.notePairFailure();
  logEvent("pair_inspect", { ok: false, reason: res.outcome });
  return res.outcome === "already_used"
    ? { ok: false, status: 409, error: "code_used" }
    : { ok: false, status: 404, error: "invalid_code" };
}

export async function approvePairing(
  env: Env,
  userId: string,
  body: z.infer<typeof zPairApproveBody>,
): Promise<PairApproveResult> {
  const store = storeFor(env, userId);
  if ((await store.pairFailures()) >= PAIR_MAX_FAILURES) {
    logEvent("preview_pair_approve", { ok: false, reason: "rate_limited" });
    return { ok: false, status: 429, error: "too_many_attempts" };
  }
  const code = normalizePairCode(body.code);
  const timeZone = body.timeZone && isValidTz(body.timeZone) ? body.timeZone : undefined;
  // Omitting `kind` is accepted only for legacy connector-only app builds: a
  // device sign-in code must always be confirmed with `kind: "device"`.
  const expectedKind = body.kind ?? "connector";
  // The name and replacement only mean something for an agent; a device
  // code ignores them (it never reaches the token exchange).
  const agent = expectedKind === "device" ? {} : { label: body.name, replaces: body.replaces };
  const res = code
    ? await pairingFor(env, code).approve({ userId, timeZone, ...agent }, expectedKind)
    : { outcome: "not_found" as const, clientName: undefined, purpose: undefined };
  if (res.outcome === "ok") {
    const kind = res.purpose ?? "connector";
    logEvent("preview_pair_approve", { ok: true, kind });
    return { ok: true, client: res.clientName ?? (kind === "device" ? "A new device" : "Claude"), kind };
  }
  await store.notePairFailure();
  logEvent("preview_pair_approve", { ok: false, reason: res.outcome });
  return res.outcome === "already_used"
    ? { ok: false, status: 409, error: "code_used" }
    : { ok: false, status: 404, error: "invalid_code" };
}

export async function denyPairing(
  env: Env,
  userId: string,
  body: z.infer<typeof zPairDenyBody>,
): Promise<PairApproveResult> {
  const store = storeFor(env, userId);
  if ((await store.pairFailures()) >= PAIR_MAX_FAILURES) {
    logEvent("pair_deny", { ok: false, reason: "rate_limited" });
    return { ok: false, status: 429, error: "too_many_attempts" };
  }
  const code = normalizePairCode(body.code);
  const res = code
    ? await pairingFor(env, code).deny(body.kind)
    : { outcome: "not_found" as const, clientName: undefined, purpose: undefined };
  if (res.outcome === "ok") {
    const kind = res.purpose ?? "connector";
    logEvent("pair_deny", { ok: true, kind });
    return { ok: true, client: res.clientName ?? (kind === "device" ? "A new device" : "Claude"), kind };
  }
  await store.notePairFailure();
  logEvent("pair_deny", { ok: false, reason: res.outcome });
  return res.outcome === "already_used"
    ? { ok: false, status: 409, error: "code_used" }
    : { ok: false, status: 404, error: "invalid_code" };
}

// ---- token ----

export async function token(c: Context<{ Bindings: Env }>) {
  const form = await c.req.formData().catch(() => null);
  if (!form) return c.json({ error: "invalid_request" }, 400);
  const grantType = String(form.get("grant_type") ?? "");
  const clientId = String(form.get("client_id") ?? "");

  if (grantType === "refresh_token") {
    const refreshToken = String(form.get("refresh_token") ?? "");
    if (!refreshToken || !clientId) return c.json({ error: "invalid_request" }, 400);
    const res = await redeemMcpRefresh(c.env, refreshToken, clientId);
    if (!res.ok) {
      logEvent("preview_oauth_token", { ok: false, grantType, clientId, reason: res.reason });
      return c.json({ error: "invalid_grant" }, 400);
    }
    logEvent("preview_oauth_token", { ok: true, grantType, clientId });
    return c.json(res.tokens, 200, { "Cache-Control": "no-store" });
  }

  if (grantType !== "authorization_code") return c.json({ error: "unsupported_grant_type" }, 400);

  const code = String(form.get("code") ?? "");
  const codeVerifier = String(form.get("code_verifier") ?? "");
  const redirectUri = String(form.get("redirect_uri") ?? "");
  if (!code || !codeVerifier || !redirectUri || !clientId || code.length > 100) {
    return c.json({ error: "invalid_request" }, 400);
  }

  const key = `${CODE_PREFIX}${code}`;
  const raw = await c.env.STATE.get(key);
  if (!raw) return c.json({ error: "invalid_grant" }, 400);
  await c.env.STATE.delete(key);
  const stored = JSON.parse(raw) as StoredCode;
  if (stored.clientId !== clientId || stored.redirectUri !== redirectUri) {
    logEvent("preview_oauth_token", { ok: false, grantType, clientId, reason: "client_or_redirect_mismatch" });
    return c.json({ error: "invalid_grant" }, 400);
  }
  if ((await sha256Base64Url(codeVerifier)) !== stored.codeChallenge) {
    logEvent("preview_oauth_token", { ok: false, grantType, clientId, reason: "pkce" });
    return c.json({ error: "invalid_grant" }, 400);
  }

  if (!(await storeFor(c.env, stored.userId).hasAppSession())) {
    logEvent("preview_oauth_token", { ok: false, grantType, clientId, reason: "no_app_session" });
    return c.json({ error: "invalid_grant" }, 400);
  }

  const familyId = randomId(16);
  const tokens = await issueMcpTokens(c.env, {
    userId: stored.userId,
    clientId,
    scope: MCP_GRANT_SCOPE,
    timeZone: stored.timeZone,
    label: stored.label,
  }, familyId);
  await settleNewAgent(c.env, { userId: stored.userId, clientId, familyId, replaces: stored.replaces });
  logEvent("preview_oauth_token", { ok: true, grantType, clientId });
  return c.json(tokens, 200, { "Cache-Control": "no-store" });
}

// ---- revoke ----

export async function revoke(c: Context<{ Bindings: Env }>) {
  const form = await c.req.formData().catch(() => null);
  const t = form ? String(form.get("token") ?? "") : "";
  if (!t) return c.json({ error: "invalid_request" }, 400);
  const revoked = await revokeMcpToken(c.env, t);
  logEvent("preview_oauth_revoke", { revoked });
  return new Response(null, { status: 200 });
}

// ---- pages ----

export const PAGE_CSS = `
  :root { color-scheme: light dark; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    background: #fafafa; color: #1a1a1a; }
  .card { background: #fff; border: 1px solid #e5e5e5; border-radius: 14px; padding: 32px 28px;
    max-width: 420px; width: calc(100% - 32px); box-sizing: border-box; }
  h1 { font-size: 18px; margin: 0 0 12px; }
  p { margin: 0 0 14px; line-height: 1.45; font-size: 15px; color: #4a4a4a; }
  .code { font: 600 34px/1.2 ui-monospace, "SF Mono", Menlo, monospace; letter-spacing: 0.12em;
    text-align: center; padding: 16px 0; margin: 8px 0 18px; border-radius: 10px; background: #f5f5f7; }
  .small { font-size: 13px; color: #777; }
  .qr { width: 200px; margin: 4px auto 18px; border-radius: 10px; overflow: hidden; }
  .qr svg { display: block; width: 100%; height: auto; }
  @media (prefers-color-scheme: dark) {
    body { background: #0a0a0a; color: #f5f5f5; }
    .card { background: #161616; border-color: #2a2a2a; }
    p { color: #b5b5b5; }
    .code { background: #1f1f1f; }
    .small { color: #888; }
  }`;

const EMAIL_FORM_CSS = `
  .alt { border-top: 1px solid #e5e5e5; margin-top: 18px; padding-top: 18px; }
  .alt form { display: flex; gap: 8px; margin: 0 0 10px; }
  .alt input { flex: 1; min-width: 0; font: inherit; font-size: 15px; padding: 9px 11px; border-radius: 9px;
    border: 1px solid #d0d0d0; background: transparent; color: inherit; }
  .alt button { font: inherit; font-size: 15px; font-weight: 600; padding: 9px 14px; border-radius: 9px; border: 0;
    background: #1a1a1a; color: #fff; cursor: pointer; }
  .alt button:disabled { opacity: 0.5; cursor: default; }
  .alt .err { color: #c0392b; }
  @media (prefers-color-scheme: dark) {
    .alt { border-color: #2a2a2a; }
    .alt input { border-color: #3a3a3a; }
    .alt button { background: #f5f5f5; color: #111; }
  }`;

// Email sign-in on the connector page (ADR 0047, issue #636). A person with
// no signed-in app nearby connects with an email code; a new address starts a
// new account. Copy comes from registry/sign-in.json.
const EMAIL_METHOD = SIGN_IN.methods.find((m) => m.id === "email")!;
const EMAIL_FORM_HTML = `<section class="alt" id="email">
      <p><b>${escapeHtml(EMAIL_METHOD.title)}</b>. ${escapeHtml(SIGN_IN.copy.subheading)}</p>
      <form id="email-start"><input id="email-address" type="email" autocomplete="email" placeholder="${escapeHtml(SIGN_IN.email.emailPlaceholder)}" required aria-label="${escapeHtml(SIGN_IN.email.emailLabel)}"><button type="submit">${escapeHtml(SIGN_IN.email.sendCode)}</button></form>
      <form id="email-verify" hidden><input id="email-code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" required aria-label="${escapeHtml(SIGN_IN.email.codeLabel)}"><button type="submit">${escapeHtml(SIGN_IN.email.signIn)}</button></form>
      <p class="small" id="email-note" role="status"></p>
    </section>`;

// The reviewer form (ADR 0055): only while reviewer mode is on. Directory
// reviewers find the code in the submission notes; nobody else has it.
const REVIEWER_FORM_HTML = `<section class="alt" id="reviewer">
      <p><b>Directory reviewer?</b> Use the demo account. Type the reviewer code from the submission notes.</p>
      <form id="reviewer-form"><input id="reviewer-code" type="password" autocomplete="off" required aria-label="Reviewer code"><button type="submit">Use the demo account</button></form>
      <p class="small" id="reviewer-note" role="status"></p>
    </section>`;

const REVIEWER_PAGE_JS = `(() => {
  const form = document.getElementById("reviewer-form");
  if (!form) return;
  const note = document.getElementById("reviewer-note");
  const say = (t) => { note.textContent = t; note.className = "small err"; };
  const errors = { invalid_code: "That code is not right.", too_many_attempts: "Too many tries. Wait ten minutes and connect again.", expired_or_unknown: "This sign-in expired. Connect again." };
  form.addEventListener("submit", async (e) => {
    e.preventDefault(); const b = form.querySelector("button"); b.disabled = true;
    try {
      const r = await fetch("/oauth/pair/reviewer", { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ code: document.getElementById("reviewer-code").value }) });
      if (r.ok) { location.href = "/oauth/pair/continue"; return; }
      const j = await r.json().catch(() => null);
      say((j && errors[j.error]) || "Something went wrong. Try again.");
    } catch { say("Something went wrong. Try again."); }
    b.disabled = false;
  });
})();`;

// The page script. Strings arrive as JSON, so registry text never meets the
// script as code.
const PAIR_PAGE_TEXT = JSON.stringify({ email: SIGN_IN.email, errors: SIGN_IN.errors }).replace(/</g, "\\u003c");
const PAIR_PAGE_JS = `(() => {
  const T = ${PAIR_PAGE_TEXT};
  const go = () => { location.href = "/oauth/pair/continue"; };
  let busy = false;
  setInterval(async () => {
    if (busy) return;
    try {
      const r = await fetch("/oauth/pair/continue", { redirect: "manual", credentials: "same-origin" });
      if (r.type === "opaqueredirect" || r.status !== 200) go();
    } catch {}
  }, 3000);
  const start = document.getElementById("email-start");
  if (!start) return;
  const verify = document.getElementById("email-verify");
  const note = document.getElementById("email-note");
  const addr = document.getElementById("email-address");
  const codeIn = document.getElementById("email-code");
  const say = (t, err) => { note.textContent = t; note.className = err ? "small err" : "small"; };
  const errors = {
    invalid_request: T.errors.invalidEmail,
    too_many_requests: T.errors.rateLimited,
    too_many_attempts: T.errors.tooManyTries,
    expired_or_unknown: T.errors.codeExpired,
  };
  const fail = (j) => {
    if (j && j.error === "invalid_code") {
      const n = j.attemptsLeft;
      return say((n === 1 ? T.errors.wrongCode.one : T.errors.wrongCode.other).replace("{count}", String(n)), true);
    }
    say((j && errors[j.error]) || T.errors.network, true);
  };
  start.addEventListener("submit", async (e) => {
    e.preventDefault(); busy = true; start.querySelector("button").disabled = true;
    try {
      const r = await fetch("/v1/auth/email/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email: addr.value }) });
      if (r.status === 202) { verify.hidden = false; codeIn.focus(); say(T.email.codeSent.replace("{email}", addr.value.trim())); start.querySelector("button").textContent = T.email.resend; }
      else fail(await r.json().catch(() => null));
    } catch { fail(null); }
    start.querySelector("button").disabled = false; busy = false;
  });
  verify.addEventListener("submit", async (e) => {
    e.preventDefault(); busy = true; verify.querySelector("button").disabled = true;
    try {
      const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
      const r = await fetch("/oauth/pair/email", { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email: addr.value, code: codeIn.value.trim(), timeZone: tz }) });
      if (r.ok) { go(); return; }
      fail(await r.json().catch(() => null));
    } catch { fail(null); }
    verify.querySelector("button").disabled = false; busy = false;
  });
})();`;

function pairPage(
  c: Context<{ Bindings: Env }>,
  opts: { code: string; clientName: string; redirectHost: string; setCookie?: string },
) {
  const shown = `${opts.code.slice(0, 4)}-${opts.code.slice(4)}`;
  const client = escapeHtml(opts.clientName);
  const back = opts.redirectHost
    ? `<p class="small">After you approve, this page sends you back to <b>${escapeHtml(opts.redirectHost)}</b>. If you did not start this from ${client}, close this page.</p>`
    : `<p class="small">If you did not start this from ${client}, close this page.</p>`;
  // The app's row is labelled "Connect Claude" (registry/settings.json
  // claude_pairing), but it pairs every MCP client. Say so to other clients.
  const appPath = "Septena &#9656; Settings &#9656; AI &amp; Agents &#9656; Connect Claude";
  const appPathNote = /^claude\b/i.test(opts.clientName) ? "" : " (it connects every agent)";
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<noscript><meta http-equiv="refresh" content="3;url=/oauth/pair/continue"></noscript>
<title>Connect Septena tasks</title>
<style>${PAGE_CSS}${EMAIL_FORM_CSS}</style>
</head>
<body>
  <main class="card">
    <h1>Connect ${client} to your Septena tasks</h1>
    <p>On your iPhone or iPad, open ${appPath}${appPathNote}, tap Scan Code and point the camera at this QR code:</p>
    <div class="qr">${pairQrSvg(pairApproveUrl(c.env.API_PUBLIC_URL, opts.code), `Sign-in code ${shown}`)}</div>
    <p>Or enter the code by hand (on Mac: Settings &#9656; AI &amp; Agents):</p>
    <div class="code">${escapeHtml(shown)}</div>
    <p>${client} will be able to read and change your tasks.</p>
    <p class="small">The code works for 10 minutes. This page checks for your approval every few seconds.</p>
    ${emailSignInEnabled(c.env) ? EMAIL_FORM_HTML : ""}
    ${reviewerMode(c.env) ? REVIEWER_FORM_HTML : ""}
    ${back}
  </main>
  <script>${PAIR_PAGE_JS}</script>
  ${reviewerMode(c.env) ? `<script>${REVIEWER_PAGE_JS}</script>` : ""}
</body>
</html>`;
  const headers: Record<string, string> = {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  };
  if (opts.setCookie) headers["Set-Cookie"] = opts.setCookie;
  return new Response(html, { status: 200, headers });
}

/// GET /pair/:code — where a sign-in QR lands when a phone's system camera
/// opens it (src/shadow/pairQr.ts). It approves nothing and looks nothing up:
/// it only says where to scan, so a forwarded link cannot approve a sign-in.
export function pairLanding(c: Context<{ Bindings: Env }>) {
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>Septena sign-in code</title>
<style>${PAGE_CSS}</style>
</head>
<body><main class="card">
  <h1>Scan this code in Septena</h1>
  <p>This QR code signs in a device or connects Claude. Septena only accepts it from inside the app, where you see who asks before you approve.</p>
  <p>Open Septena on a device that is already signed in. Go to Settings &#9656; Account &#9656; Approve a sign-in, tap Scan Code, and scan the code again.</p>
  <p class="small">If you did not start a sign-in, close this page.</p>
</main></body>
</html>`;
  return new Response(html, {
    status: 200,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" },
  });
}

function messagePage(c: Context<{ Bindings: Env }>, message: string, status: number, clearCookie = false) {
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Connect Septena tasks</title>
<style>${PAGE_CSS}</style>
</head>
<body><main class="card"><h1>Connect Septena tasks</h1><p>${escapeHtml(message)}</p></main></body>
</html>`;
  const headers: Record<string, string> = {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  };
  if (clearCookie) headers["Set-Cookie"] = `${PAIR_COOKIE}=; Path=/oauth; Max-Age=0; HttpOnly; Secure; SameSite=Lax`;
  return new Response(html, { status, headers });
}
