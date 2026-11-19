import type { Context } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { getClient, putClient } from "../storage.js";
import { logEvent, randomId, readCookie, sha256Base64Url } from "../util.js";
import { isValidTz } from "../tz.js";
import { registerClient } from "../oauth/register.js";
import { validateRedirectUri } from "../oauth/redirects.js";
import { escapeHtml } from "../oauth/authorize.js";
import { storeFor } from "../api/session.js";
import { MCP_SCOPE, issueMcpTokens, redeemMcpRefresh, revokeMcpToken } from "./tokens.js";

// OAuth 2.1 for the read-only MCP preview on api.septena.app (phase 2,
// "shadow", of docs/SEPTASK_BACKEND.md in the app repo).
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
//   5. Claude trades the code (PKCE) at /oauth/token for an `sm1.` access token
//      and a rotating `smr1.` refresh token, scope tasks:read.
//
// Everything here runs only on the api host; mcp.septena.app keeps its own
// handlers (src/oauth/*) unchanged. KV keys are under `v2:`.

const CLIENT_PREFIX = "v2:client:";
const CODE_PREFIX = "v2:code:";
const CODE_TTL_S = 300;
const PAIR_TTL_MS = 10 * 60 * 1000;
const PAIR_COOKIE = "septena_pair";
/// Wrong codes a user may enter per window before approve answers 429.
export const PAIR_MAX_FAILURES = 5;

// No 0/O, 1/I/L: the code is read off one screen and typed into another.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 8;
const CODE_RE = new RegExp(`^[${CODE_ALPHABET}]{${CODE_LENGTH}}$`);

export function isApiHost(c: Context<{ Bindings: Env }>): boolean {
  return new URL(c.req.url).host === new URL(c.env.API_PUBLIC_URL).host;
}

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

function pairingFor(env: Env, code: string) {
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
    scopes_supported: [MCP_SCOPE],
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
    scopes_supported: [MCP_SCOPE],
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
  const s = await pairing.status(pendingId);
  if (s.status === "gone") {
    return messagePage(c, "This code expired. Go back to Claude and connect again.", 400, true);
  }
  if (s.status === "pending") {
    return pairPage(c, {
      code,
      clientName: s.clientName ?? "Claude",
      redirectHost: s.redirectUri ? new URL(s.redirectUri).host : "",
    });
  }

  const taken = await pairing.take(pendingId);
  if (!taken) return messagePage(c, "This code expired. Go back to Claude and connect again.", 400, true);
  const { pending, approval } = taken;

  const authCode = randomId(32);
  await c.env.STATE.put(
    `${CODE_PREFIX}${authCode}`,
    JSON.stringify({
      userId: approval.userId,
      timeZone: approval.timeZone,
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
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
}

// ---- POST /v1/pair/approve (called by the app, bearer-authenticated) ----

export const zPairApproveBody = z.object({
  code: z.string().min(1).max(32),
  timeZone: z.string().max(64).optional(),
}).strict();

export type PairApproveResult =
  | { ok: true; client: string }
  | { ok: false; status: 404 | 409 | 429; error: "invalid_code" | "code_used" | "too_many_attempts" };

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
  const res = code
    ? await pairingFor(env, code).approve({ userId, timeZone })
    : { outcome: "not_found" as const, clientName: undefined };
  if (res.outcome === "ok") {
    logEvent("preview_pair_approve", { ok: true });
    return { ok: true, client: res.clientName ?? "Claude" };
  }
  await store.notePairFailure();
  logEvent("preview_pair_approve", { ok: false, reason: res.outcome });
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

  const tokens = await issueMcpTokens(c.env, {
    userId: stored.userId,
    clientId,
    scope: MCP_SCOPE,
    timeZone: stored.timeZone,
  });
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

const PAGE_CSS = `
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
  @media (prefers-color-scheme: dark) {
    body { background: #0a0a0a; color: #f5f5f5; }
    .card { background: #161616; border-color: #2a2a2a; }
    p { color: #b5b5b5; }
    .code { background: #1f1f1f; }
    .small { color: #888; }
  }`;

function pairPage(
  c: Context<{ Bindings: Env }>,
  opts: { code: string; clientName: string; redirectHost: string; setCookie?: string },
) {
  const shown = `${opts.code.slice(0, 4)}-${opts.code.slice(4)}`;
  const back = opts.redirectHost
    ? `<p class="small">After you approve, this page sends you back to <b>${escapeHtml(opts.redirectHost)}</b>. If you did not start this from Claude, close this page.</p>`
    : `<p class="small">If you did not start this from Claude, close this page.</p>`;
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="3;url=/oauth/pair/continue">
<title>Connect Septena tasks</title>
<style>${PAGE_CSS}</style>
</head>
<body>
  <main class="card">
    <h1>Connect ${escapeHtml(opts.clientName)} to your Septena tasks</h1>
    <p>Open Septask &#9656; Settings &#9656; About &#9656; Advanced &#9656; Task backend, and enter this code:</p>
    <div class="code">${escapeHtml(shown)}</div>
    <p>This is a read-only preview. Claude can read your tasks here but cannot change them.</p>
    <p class="small">The code works for 10 minutes. This page checks for your approval every few seconds.</p>
    ${back}
  </main>
</body>
</html>`;
  const headers: Record<string, string> = {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  };
  if (opts.setCookie) headers["Set-Cookie"] = opts.setCookie;
  return new Response(html, { status: 200, headers });
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
