import type { Context } from "hono";
import { z } from "zod";
import type { Env } from "../env.js";
import { base64url, escapeHtml, fromBase64Url, logEvent, randomId, readCookie, sha256Base64Url } from "../util.js";
import { verifyAppleIdentityToken } from "./appleIdentity.js";
import { isAllowedWebOrigin, cookieSessionResponse } from "./webAuth.js";
import { authenticate, issueSession } from "./session.js";
import { linkProviderToAccount, mintOidcLinkToken, resolveProviderLogin, verifyOidcLinkToken, type FederatedProvider } from "./authLink.js";
import { PAGE_CSS, normalizePairCode, pairingFor } from "../shadow/oauth.js";

// OIDC sign-in for Google, Microsoft and web Sign in with Apple
// (ADR 0047, docs/SIGN_IN_SURFACES_SPEC.md §4, issue #637).
//
// Zero npm dependencies: Web Crypto verifies RS256 JWKS signatures for Google,
// Microsoft and Apple, and mints ES256 client_secret JWTs for Apple's token
// endpoint. Each provider stays off (503 provider_off, hidden from
// GET /v1/auth/methods) until its Worker secrets are set (#638).

export type OidcProvider = FederatedProvider;
export const OIDC_PROVIDERS: readonly OidcProvider[] = ["apple", "google", "microsoft"];

const STATE_PREFIX = "oidc:state:";
const RESULT_PREFIX = "oidc:res:";
const STATE_TTL_S = 10 * 60;
const RESULT_TTL_S = 5 * 60;
const JWKS_TTL_MS = 60 * 60 * 1000;
const CLOCK_SKEW_S = 60;
const IP_WINDOW_MS = 10 * 60 * 1000;
export const OIDC_START_MAX_PER_IP = 20;
const PAIR_COOKIE = "septena_pair";

const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GOOGLE_ISSUERS = new Set(["https://accounts.google.com", "accounts.google.com"]);

const MICROSOFT_JWKS_URL = "https://login.microsoftonline.com/common/discovery/v2.0/keys";
const MICROSOFT_AUTH_URL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
const MICROSOFT_TOKEN_URL = "https://login.microsoftonline.com/common/oauth2/v2.0/token";

const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";
const APPLE_AUTH_URL = "https://appleid.apple.com/auth/authorize";
const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
const APPLE_AUDIENCE = "https://appleid.apple.com";

const ALLOWED_APP_CALLBACKS = new Set([
  "septena://auth/callback",
  "septask://auth/callback",
]);

interface JwkWithKid extends JsonWebKey {
  kid?: string;
}

const jwksCache = new Map<string, { at: number; keys: JwkWithKid[] }>();
let testFetchOverride: typeof fetch | null = null;

export function setOidcFetchForTests(fn: typeof fetch | null): void {
  testFetchOverride = fn;
}

export function clearOidcJwksCache(): void {
  jwksCache.clear();
}

const activeFetch = (): typeof fetch => testFetchOverride ?? fetch;

// ---- provider configuration helpers ----

export function parseOidcProvider(raw: string): OidcProvider | null {
  return raw === "apple" || raw === "google" || raw === "microsoft" ? raw : null;
}

export function acceptedAppleAudiences(env: Env): string[] {
  const list = env.APPLE_AUDIENCES.split(",").map((s) => s.trim()).filter(Boolean);
  const webId = env.APPLE_WEB_CLIENT_ID?.trim();
  if (webId && !list.includes(webId)) list.push(webId);
  return list;
}

export function googleNativeAudiences(env: Env): string[] {
  return [env.GOOGLE_ANDROID_CLIENT_ID, env.GOOGLE_CLIENT_ID, env.GOOGLE_IOS_CLIENT_ID]
    .map((s) => s?.trim())
    .filter((s): s is string => Boolean(s));
}

export function isOidcWebEnabled(env: Env, provider: OidcProvider): boolean {
  switch (provider) {
    case "google":
      return Boolean(env.GOOGLE_CLIENT_ID?.trim() && env.GOOGLE_CLIENT_SECRET?.trim());
    case "microsoft":
      return Boolean(env.MICROSOFT_CLIENT_ID?.trim() && env.MICROSOFT_CLIENT_SECRET?.trim());
    case "apple":
      return Boolean(
        env.APPLE_WEB_CLIENT_ID?.trim() &&
        env.APPLE_SIGNIN_KEY_ID?.trim() &&
        env.APPLE_SIGNIN_KEY?.trim() &&
        (env.APPLE_SIGNIN_TEAM_ID?.trim() || env.APNS_TEAM_ID?.trim()),
      );
  }
}

export function isGoogleNativeEnabled(env: Env): boolean {
  return googleNativeAudiences(env).length > 0;
}

export function enabledOidcWebProviders(env: Env): OidcProvider[] {
  return OIDC_PROVIDERS.filter((p) => isOidcWebEnabled(env, p));
}

// ---- return_to allowlist ----

export function isAllowedReturnTo(env: Env, returnTo: string): boolean {
  if (returnTo === "connector") return true;
  if (ALLOWED_APP_CALLBACKS.has(returnTo)) return true;
  let parsed: URL;
  try {
    parsed = new URL(returnTo);
  } catch {
    return false;
  }
  if (parsed.protocol !== "https:") return false;
  return isAllowedWebOrigin(env, parsed.origin);
}

// ---- IP rate limit ----

async function ipCount(env: Env, prefix: string, ip: string): Promise<{ key: string; count: number }> {
  const bucket = Math.floor(Date.now() / IP_WINDOW_MS);
  const key = `${prefix}:${await sha256Base64Url(ip.trim())}:${bucket}`;
  const raw = await env.STATE.get(key);
  const n = raw ? Number.parseInt(raw, 10) : 0;
  return { key, count: Number.isFinite(n) && n > 0 ? n : 0 };
}

async function ipNote(env: Env, key: string, count: number): Promise<void> {
  await env.STATE.put(key, String(count + 1), { expirationTtl: IP_WINDOW_MS / 1000 });
}

// ---- JWT & JWKS verification ----

export class OidcTokenError extends Error {}

function decodeJsonPart<T>(part: string): T {
  try {
    return JSON.parse(new TextDecoder().decode(fromBase64Url(part))) as T;
  } catch {
    throw new OidcTokenError("malformed token");
  }
}

async function fetchJwks(url: string, forceRefresh: boolean): Promise<JwkWithKid[]> {
  const cached = jwksCache.get(url);
  if (!forceRefresh && cached && Date.now() - cached.at < JWKS_TTL_MS) return cached.keys;
  const res = await activeFetch()(url);
  if (!res.ok) throw new OidcTokenError(`jwks fetch failed: ${res.status}`);
  const body = (await res.json()) as { keys?: JwkWithKid[] };
  const keys = Array.isArray(body.keys) ? body.keys : [];
  jwksCache.set(url, { at: Date.now(), keys });
  return keys;
}

async function verifyRs256Jwt<T extends Record<string, unknown>>(
  token: string,
  jwksUrl: string,
  keysOverride?: JwkWithKid[],
): Promise<T> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new OidcTokenError("malformed token");
  const [h, p, s] = parts;
  const header = decodeJsonPart<{ alg?: string; kid?: string }>(h);
  if (header.alg !== "RS256" || !header.kid) throw new OidcTokenError("unexpected alg or missing kid");

  let jwk: JwkWithKid | undefined;
  if (keysOverride) {
    jwk = keysOverride.find((k) => k.kid === header.kid);
  } else {
    jwk = (await fetchJwks(jwksUrl, false)).find((k) => k.kid === header.kid);
    if (!jwk) jwk = (await fetchJwks(jwksUrl, true)).find((k) => k.kid === header.kid);
  }
  if (!jwk) throw new OidcTokenError("unknown signing key");

  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  let sig: Uint8Array<ArrayBuffer>;
  try {
    sig = fromBase64Url(s);
  } catch {
    throw new OidcTokenError("malformed token");
  }
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    sig,
    new TextEncoder().encode(`${h}.${p}`),
  );
  if (!ok) throw new OidcTokenError("bad signature");
  return decodeJsonPart<T>(p);
}

function checkTimeClaims(claims: { exp?: unknown; iat?: unknown }, nowS = Math.floor(Date.now() / 1000)): void {
  if (typeof claims.exp !== "number" || claims.exp < nowS - CLOCK_SKEW_S) {
    throw new OidcTokenError("expired");
  }
  if (typeof claims.iat === "number" && claims.iat > nowS + CLOCK_SKEW_S) {
    throw new OidcTokenError("issued in the future");
  }
}

function constantTimeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  const len = Math.max(ab.length, bb.length);
  let diff = ab.length ^ bb.length;
  for (let i = 0; i < len; i++) diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  return diff === 0;
}

export interface VerifiedOidcIdentity {
  provider: OidcProvider;
  subject: string;
  email?: string;
  emailVerified: boolean;
}

export async function verifyGoogleIdToken(
  token: string,
  audiences: string[],
  opts: { expectedNonce?: string; keys?: JwkWithKid[] } = {},
): Promise<VerifiedOidcIdentity> {
  const claims = await verifyRs256Jwt<{
    iss?: string;
    aud?: string;
    sub?: string;
    exp?: number;
    iat?: number;
    nonce?: string;
    email?: string;
    email_verified?: boolean | string;
  }>(token, GOOGLE_JWKS_URL, opts.keys);
  if (!claims.iss || !GOOGLE_ISSUERS.has(claims.iss)) throw new OidcTokenError("bad issuer");
  if (!claims.aud || !audiences.includes(claims.aud)) throw new OidcTokenError("bad audience");
  checkTimeClaims(claims);
  if (!claims.sub) throw new OidcTokenError("no subject");
  if (opts.expectedNonce !== undefined) {
    if (!claims.nonce || !constantTimeEqual(claims.nonce, opts.expectedNonce)) {
      throw new OidcTokenError("nonce mismatch");
    }
  }
  const email = typeof claims.email === "string" && claims.email.trim().length > 0
    ? claims.email.trim().toLowerCase()
    : undefined;
  const emailVerified = claims.email_verified === true || claims.email_verified === "true";
  return { provider: "google", subject: claims.sub, ...(email ? { email } : {}), emailVerified };
}

export async function verifyMicrosoftIdToken(
  token: string,
  clientId: string,
  opts: { expectedNonce?: string; keys?: JwkWithKid[] } = {},
): Promise<VerifiedOidcIdentity> {
  const claims = await verifyRs256Jwt<{
    iss?: string;
    aud?: string;
    oid?: string;
    tid?: string;
    exp?: number;
    iat?: number;
    nonce?: string;
    email?: string;
    email_verified?: boolean | string;
    xms_edov?: boolean | number;
  }>(token, MICROSOFT_JWKS_URL, opts.keys);
  if (!claims.tid || !claims.oid) throw new OidcTokenError("missing tid or oid");
  // Common-tenant tokens must carry an issuer matching their own tenant id.
  const expectedIssuer = `https://login.microsoftonline.com/${claims.tid}/v2.0`;
  if (claims.iss !== expectedIssuer) throw new OidcTokenError("bad issuer");
  if (claims.aud !== clientId) throw new OidcTokenError("bad audience");
  checkTimeClaims(claims);
  if (opts.expectedNonce !== undefined) {
    if (!claims.nonce || !constantTimeEqual(claims.nonce, opts.expectedNonce)) {
      throw new OidcTokenError("nonce mismatch");
    }
  }
  const email = typeof claims.email === "string" && claims.email.trim().length > 0
    ? claims.email.trim().toLowerCase()
    : undefined;
  // Require explicit verification signal (`xms_edov` or `email_verified`) before
  // trusting Microsoft's email claim for collision matching.
  const emailVerified = claims.email_verified === true || claims.email_verified === "true" ||
    claims.xms_edov === true || claims.xms_edov === 1;
  return {
    provider: "microsoft",
    subject: `${claims.tid}:${claims.oid}`,
    ...(email ? { email } : {}),
    emailVerified,
  };
}

// ---- Apple web client_secret (ES256 JWT) ----

function parsePkcs8Pem(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN [A-Z ]+-----/g, "")
    .replace(/-----END [A-Z ]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

export async function mintAppleClientSecret(env: Env, nowMs = Date.now()): Promise<string> {
  const clientId = env.APPLE_WEB_CLIENT_ID?.trim();
  const keyId = env.APPLE_SIGNIN_KEY_ID?.trim();
  const keyPem = env.APPLE_SIGNIN_KEY?.trim();
  const teamId = env.APPLE_SIGNIN_TEAM_ID?.trim() || env.APNS_TEAM_ID?.trim();
  if (!clientId || !keyId || !keyPem || !teamId) throw new OidcTokenError("apple web secrets missing");

  const key = await crypto.subtle.importKey(
    "pkcs8",
    parsePkcs8Pem(keyPem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const iat = Math.floor(nowMs / 1000);
  const exp = iat + 300;
  const enc = new TextEncoder();
  const header = base64url(enc.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
  const payload = base64url(enc.encode(JSON.stringify({ iss: teamId, iat, exp, aud: APPLE_AUDIENCE, sub: clientId })));
  const input = `${header}.${payload}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(input));
  return `${input}.${base64url(new Uint8Array(sig))}`;
}

// ---- OIDC state & result storage ----

interface OidcStateRecord {
  provider: OidcProvider;
  returnTo: string;
  codeVerifier: string;
  nonce: string;
  linkUserId?: string;
  pairCode?: string;
  pairPendingId?: string;
  expiresAt: number;
}

type OidcResultRecord =
  | { mode: "signin"; provider: OidcProvider; subject: string; email?: string; emailVerified: boolean }
  | { mode: "link"; linkUserId: string; provider: OidcProvider; subject: string };

function callbackUrl(env: Env, provider: OidcProvider): string {
  return `${env.API_PUBLIC_URL}/v1/auth/oidc/${provider}/callback`;
}

function appendQuery(base: string, params: Record<string, string>): string {
  const u = new URL(base);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  return u.toString();
}

function errorHtml(title: string, body: string, status = 400): Response {
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>${escapeHtml(title)}</title><style>${PAGE_CSS}</style></head>
<body><main class="card"><h1>${escapeHtml(title)}</h1><p>${escapeHtml(body)}</p></main></body></html>`;
  return new Response(html, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  });
}

// ---- route handlers ----

/// POST /v1/auth/link/oidc/start (authenticated): returns the redirect URL for
/// linking an OIDC provider to the signed-in account without putting a bearer
/// token in query strings.
export const zOidcLinkStartBody = z.object({
  provider: z.enum(["apple", "google", "microsoft"]),
  returnTo: z.string().min(1).max(500),
}).strict();

export async function startOidcLinkUrl(
  env: Env,
  userId: string,
  body: z.infer<typeof zOidcLinkStartBody>,
): Promise<{ ok: true; url: string } | { ok: false; status: 400 | 503; error: string }> {
  if (!isOidcWebEnabled(env, body.provider)) return { ok: false, status: 503, error: "provider_off" };
  if (body.returnTo === "connector" || !isAllowedReturnTo(env, body.returnTo)) {
    return { ok: false, status: 400, error: "invalid_return_to" };
  }
  const linkToken = await mintOidcLinkToken(env, userId);
  const url = new URL(`${env.API_PUBLIC_URL}/v1/auth/oidc/${body.provider}/start`);
  url.searchParams.set("return_to", body.returnTo);
  url.searchParams.set("link_token", linkToken);
  return { ok: true, url: url.toString() };
}

/// GET /oauth/pair/oidc/:provider (under /oauth so the HttpOnly `septena_pair`
/// cookie is sent by the browser). Redirects to the OIDC provider with
/// `return_to=connector`.
export async function pairOidcStart(c: Context<{ Bindings: Env }>): Promise<Response> {
  const provider = parseOidcProvider(c.req.param("provider") ?? "");
  if (!provider) return errorHtml("Unknown provider", "Go back to your agent and connect again.", 404);
  if (!isOidcWebEnabled(c.env, provider)) {
    return errorHtml("Sign-in unavailable", "This sign-in provider is not enabled.", 503);
  }
  const url = new URL(c.req.url);
  url.searchParams.set("return_to", "connector");
  const req = new Request(url.toString(), { headers: c.req.raw.headers, method: "GET" });
  const fakeC = {
    env: c.env,
    req: {
      param: (name: string) => (name === "provider" ? provider : undefined),
      query: (name: string) => url.searchParams.get(name) ?? undefined,
      header: (name: string) => c.req.header(name),
      raw: req,
    },
    json: c.json.bind(c),
  } as unknown as Context<{ Bindings: Env }>;
  return oidcStart(fakeC);
}

/// GET /v1/auth/oidc/:provider/start
export async function oidcStart(c: Context<{ Bindings: Env }>): Promise<Response> {
  const noStore = { "Cache-Control": "no-store" };
  const provider = parseOidcProvider(c.req.param("provider") ?? "");
  if (!provider) return c.json({ error: "unknown_provider" }, 404, noStore);
  if (!isOidcWebEnabled(c.env, provider)) return c.json({ error: "provider_off" }, 503, noStore);

  const returnTo = c.req.query("return_to") ?? "";
  if (!returnTo || !isAllowedReturnTo(c.env, returnTo)) {
    return c.json({ error: "invalid_return_to" }, 400, noStore);
  }

  const clientIp = c.req.header("CF-Connecting-IP");
  if (clientIp) {
    const { key, count } = await ipCount(c.env, "rl:oidcstart", clientIp);
    if (count >= OIDC_START_MAX_PER_IP) {
      logEvent("oidc_start", { ok: false, provider, reason: "ip_limited" });
      return c.json({ error: "too_many_requests", retryAfterSeconds: IP_WINDOW_MS / 1000 }, 429, {
        ...noStore,
        "Retry-After": String(IP_WINDOW_MS / 1000),
      });
    }
    await ipNote(c.env, key, count);
  }

  let pairCode: string | undefined;
  let pairPendingId: string | undefined;
  if (returnTo === "connector") {
    const cookie = readCookie(c.req.raw, PAIR_COOKIE) ?? "";
    const [rawCode, pendingId] = cookie.split(".");
    const code = rawCode ? normalizePairCode(rawCode) : null;
    if (!code || !pendingId) {
      return errorHtml("Sign-in expired", "Go back to your agent and connect again.", 410);
    }
    const status = await pairingFor(c.env, code).status(pendingId, "connector");
    if (status.status !== "pending") {
      return errorHtml("Sign-in expired", "Go back to your agent and connect again.", 410);
    }
    pairCode = code;
    pairPendingId = pendingId;
  }

  let linkUserId: string | undefined;
  const rawLinkToken = c.req.query("link_token");
  if (rawLinkToken) {
    if (returnTo === "connector") return c.json({ error: "invalid_request" }, 400, noStore);
    const uid = await verifyOidcLinkToken(c.env, rawLinkToken);
    if (!uid) return c.json({ error: "expired_or_unknown" }, 410, noStore);
    linkUserId = uid;
  }

  const state = randomId(24);
  const codeVerifier = randomId(32);
  const codeChallenge = await sha256Base64Url(codeVerifier);
  const nonce = randomId(24);
  const record: OidcStateRecord = {
    provider,
    returnTo,
    codeVerifier,
    nonce,
    ...(linkUserId ? { linkUserId } : {}),
    ...(pairCode && pairPendingId ? { pairCode, pairPendingId } : {}),
    expiresAt: Date.now() + STATE_TTL_S * 1000,
  };
  await c.env.STATE.put(`${STATE_PREFIX}${state}`, JSON.stringify(record), { expirationTtl: STATE_TTL_S });

  const redirectUri = callbackUrl(c.env, provider);
  let target: URL;
  if (provider === "google") {
    target = new URL(GOOGLE_AUTH_URL);
    target.searchParams.set("client_id", c.env.GOOGLE_CLIENT_ID!.trim());
    target.searchParams.set("redirect_uri", redirectUri);
    target.searchParams.set("response_type", "code");
    target.searchParams.set("scope", "openid email");
    target.searchParams.set("state", state);
    target.searchParams.set("nonce", nonce);
    target.searchParams.set("code_challenge", codeChallenge);
    target.searchParams.set("code_challenge_method", "S256");
    target.searchParams.set("prompt", "select_account");
  } else if (provider === "microsoft") {
    target = new URL(MICROSOFT_AUTH_URL);
    target.searchParams.set("client_id", c.env.MICROSOFT_CLIENT_ID!.trim());
    target.searchParams.set("redirect_uri", redirectUri);
    target.searchParams.set("response_type", "code");
    target.searchParams.set("scope", "openid email");
    target.searchParams.set("state", state);
    target.searchParams.set("nonce", nonce);
    target.searchParams.set("code_challenge", codeChallenge);
    target.searchParams.set("code_challenge_method", "S256");
  } else {
    target = new URL(APPLE_AUTH_URL);
    target.searchParams.set("client_id", c.env.APPLE_WEB_CLIENT_ID!.trim());
    target.searchParams.set("redirect_uri", redirectUri);
    target.searchParams.set("response_type", "code");
    target.searchParams.set("response_mode", "form_post");
    target.searchParams.set("scope", "email");
    target.searchParams.set("state", state);
    target.searchParams.set("nonce", nonce);
  }

  logEvent("oidc_start", { ok: true, provider, connector: returnTo === "connector", link: Boolean(linkUserId) });
  return new Response(null, {
    status: 302,
    headers: { Location: target.toString(), "Cache-Control": "no-store" },
  });
}

async function exchangeOidcCode(
  env: Env,
  provider: OidcProvider,
  code: string,
  codeVerifier: string,
): Promise<string> {
  const redirectUri = callbackUrl(env, provider);
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: redirectUri,
  });
  let tokenUrl: string;
  if (provider === "google") {
    tokenUrl = GOOGLE_TOKEN_URL;
    body.set("client_id", env.GOOGLE_CLIENT_ID!.trim());
    body.set("client_secret", env.GOOGLE_CLIENT_SECRET!.trim());
    body.set("code_verifier", codeVerifier);
  } else if (provider === "microsoft") {
    tokenUrl = MICROSOFT_TOKEN_URL;
    body.set("client_id", env.MICROSOFT_CLIENT_ID!.trim());
    body.set("client_secret", env.MICROSOFT_CLIENT_SECRET!.trim());
    body.set("code_verifier", codeVerifier);
  } else {
    tokenUrl = APPLE_TOKEN_URL;
    body.set("client_id", env.APPLE_WEB_CLIENT_ID!.trim());
    body.set("client_secret", await mintAppleClientSecret(env));
  }

  const res = await activeFetch()(tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
  if (!res.ok) throw new OidcTokenError(`token exchange failed: ${res.status}`);
  const data = (await res.json()) as { id_token?: unknown };
  if (typeof data.id_token !== "string" || !data.id_token) {
    throw new OidcTokenError("missing id_token");
  }
  return data.id_token;
}

async function verifyProviderIdToken(
  env: Env,
  provider: OidcProvider,
  idToken: string,
  nonce: string,
): Promise<VerifiedOidcIdentity> {
  if (provider === "google") {
    return verifyGoogleIdToken(idToken, [env.GOOGLE_CLIENT_ID!.trim()], { expectedNonce: nonce });
  }
  if (provider === "microsoft") {
    return verifyMicrosoftIdToken(idToken, env.MICROSOFT_CLIENT_ID!.trim(), { expectedNonce: nonce });
  }
  let keys = await fetchJwks(APPLE_JWKS_URL, false);
  const headerKid = (() => {
    try { return decodeJsonPart<{ kid?: string }>(idToken.split(".")[0] ?? "").kid; } catch { return undefined; }
  })();
  if (headerKid && !keys.some((k) => k.kid === headerKid)) {
    keys = await fetchJwks(APPLE_JWKS_URL, true);
  }
  const apple = await verifyAppleIdentityToken(idToken, null, [env.APPLE_WEB_CLIENT_ID!.trim()], {
    expectedNonce: nonce,
    keys: keys.filter((k): k is JwkWithKid & { kid: string } => typeof k.kid === "string"),
  });
  return {
    provider: "apple",
    subject: apple.sub,
    ...(apple.email ? { email: apple.email } : {}),
    emailVerified: apple.emailVerified ?? false,
  };
}

/// GET & POST /v1/auth/oidc/:provider/callback
export async function oidcCallback(c: Context<{ Bindings: Env }>): Promise<Response> {
  const provider = parseOidcProvider(c.req.param("provider") ?? "");
  if (!provider || !isOidcWebEnabled(c.env, provider)) {
    return errorHtml("Sign-in unavailable", "This sign-in provider is not enabled.", 404);
  }

  let code = "";
  let state = "";
  let providerError = "";
  if (c.req.method === "POST") {
    const form = await c.req.formData().catch(() => null);
    code = String(form?.get("code") ?? "");
    state = String(form?.get("state") ?? "");
    providerError = String(form?.get("error") ?? "");
  } else {
    code = c.req.query("code") ?? "";
    state = c.req.query("state") ?? "";
    providerError = c.req.query("error") ?? "";
  }

  if (!state) return errorHtml("Sign-in expired", "Start sign-in again from Septena.", 400);
  const stateKey = `${STATE_PREFIX}${state}`;
  const rawState = await c.env.STATE.get(stateKey);
  if (!rawState) return errorHtml("Sign-in expired", "This sign-in expired or was already used. Try again.", 410);
  // Single-use: burn state before any external call.
  await c.env.STATE.delete(stateKey);

  let stored: OidcStateRecord;
  try {
    stored = JSON.parse(rawState) as OidcStateRecord;
  } catch {
    return errorHtml("Sign-in expired", "Start sign-in again from Septena.", 400);
  }
  if (stored.provider !== provider || Date.now() > stored.expiresAt) {
    return errorHtml("Sign-in expired", "This sign-in expired. Start again from Septena.", 410);
  }

  const failBack = (reason: string): Response => {
    if (stored.returnTo === "connector") {
      return new Response(null, { status: 302, headers: { Location: "/oauth/pair/continue", "Cache-Control": "no-store" } });
    }
    return new Response(null, {
      status: 302,
      headers: { Location: appendQuery(stored.returnTo, { oidc_error: reason }), "Cache-Control": "no-store" },
    });
  };

  if (providerError || !code) {
    logEvent("oidc_callback", { ok: false, provider, reason: providerError || "missing_code" });
    return failBack(providerError || "cancelled");
  }

  let identity: VerifiedOidcIdentity;
  try {
    const idToken = await exchangeOidcCode(c.env, provider, code, stored.codeVerifier);
    identity = await verifyProviderIdToken(c.env, provider, idToken, stored.nonce);
  } catch (e) {
    logEvent("oidc_callback", { ok: false, provider, reason: e instanceof Error ? e.message.slice(0, 120) : "verify_failed" });
    return failBack("invalid_token");
  }

  // Connector authorize page mode: approve the pending MCP pairing directly.
  if (stored.returnTo === "connector") {
    if (!stored.pairCode || !stored.pairPendingId) {
      return errorHtml("Sign-in expired", "Go back to your agent and connect again.", 410);
    }
    const pairing = pairingFor(c.env, stored.pairCode);
    if ((await pairing.status(stored.pairPendingId, "connector")).status !== "pending") {
      return errorHtml("Sign-in expired", "Go back to your agent and connect again.", 410);
    }
    const login = await resolveProviderLogin(c.env, {
      provider: identity.provider,
      subject: identity.subject,
      email: identity.email,
      emailVerified: identity.emailVerified,
      clientIp: c.req.header("CF-Connecting-IP"),
    });
    if (login.outcome !== "signed_in") {
      return errorHtml(
        "This email already has a Septena account",
        `Sign in with your email (${login.email}) on the previous page to connect your agent to that account.`,
        409,
      );
    }
    const approved = await pairing.approve(
      { userId: login.userId, approvedVia: "oidc", approvedAt: Date.now() },
      "connector",
    );
    if (approved.outcome !== "ok") {
      return errorHtml("Sign-in expired", "Go back to your agent and connect again.", 410);
    }
    logEvent("preview_pair_approve", { ok: true, kind: "connector", via: `oidc:${provider}`, created: login.created });
    return new Response(null, {
      status: 302,
      headers: { Location: "/oauth/pair/continue", "Cache-Control": "no-store" },
    });
  }

  // App/web mode: hand back a one-time result code for POST /v1/auth/oidc/redeem.
  const resultCode = randomId(32);
  const resRecord: OidcResultRecord = stored.linkUserId
    ? { mode: "link", linkUserId: stored.linkUserId, provider: identity.provider, subject: identity.subject }
    : {
      mode: "signin",
      provider: identity.provider,
      subject: identity.subject,
      ...(identity.email ? { email: identity.email } : {}),
      emailVerified: identity.emailVerified,
    };
  await c.env.STATE.put(`${RESULT_PREFIX}${resultCode}`, JSON.stringify(resRecord), { expirationTtl: RESULT_TTL_S });
  logEvent("oidc_callback", { ok: true, provider, mode: resRecord.mode });
  return new Response(null, {
    status: 302,
    headers: { Location: appendQuery(stored.returnTo, { oidc_code: resultCode }), "Cache-Control": "no-store" },
  });
}

// ---- POST /v1/auth/oidc/redeem ----

export const zOidcRedeemBody = z.object({
  code: z.string().min(20).max(128),
  sessionMode: z.enum(["body", "cookie"]).optional(),
}).strict();

export async function oidcRedeem(c: Context<{ Bindings: Env }>): Promise<Response> {
  const noStore = { "Cache-Control": "no-store" };
  let raw: unknown;
  try { raw = await c.req.json(); } catch { return c.json({ error: "invalid_json" }, 400, noStore); }
  const parsed = zOidcRedeemBody.safeParse(raw);
  if (!parsed.success) return c.json({ error: "invalid_request", issues: parsed.error.issues.slice(0, 20) }, 400, noStore);

  const cookieMode = parsed.data.sessionMode === "cookie";
  if (cookieMode && !isAllowedWebOrigin(c.env, c.req.header("Origin"))) {
    return c.json({ error: "origin_not_allowed" }, 403, noStore);
  }

  const key = `${RESULT_PREFIX}${parsed.data.code}`;
  const rawRec = await c.env.STATE.get(key);
  if (!rawRec) return c.json({ error: "expired_or_unknown" }, 410, noStore);
  await c.env.STATE.delete(key);

  const rec = JSON.parse(rawRec) as OidcResultRecord;
  if (rec.mode === "link") {
    const auth = c.req.header("Authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    const claims = token ? await authenticate(c.env, token) : null;
    if (!claims || claims.userId !== rec.linkUserId) {
      return c.json({ error: "unauthorized" }, 401, noStore);
    }
    const linked = await linkProviderToAccount(c.env, rec.linkUserId, rec.provider, rec.subject);
    if (!linked.ok) return c.json({ error: linked.error }, linked.status, noStore);
    return c.json({ ok: true, created: linked.created, identities: linked.identities, canRemove: linked.canRemove }, 200, noStore);
  }

  const login = await resolveProviderLogin(c.env, {
    provider: rec.provider,
    subject: rec.subject,
    email: rec.email,
    emailVerified: rec.emailVerified,
    clientIp: c.req.header("CF-Connecting-IP"),
  });
  if (login.outcome === "needs_link") {
    return c.json({
      error: "account_exists",
      email: login.email,
      provider: login.provider,
      linkToken: login.linkToken,
      codeSent: login.codeSent,
    }, 409, noStore);
  }
  if (login.outcome === "needs_link_email_off") {
    return c.json({ error: "account_exists", email: login.email, provider: login.provider }, 409, noStore);
  }
  const session = await issueSession(c.env, login.userId);
  logEvent("oidc_signin", { ok: true, provider: rec.provider, created: login.created });
  return cookieMode ? cookieSessionResponse(c.env, session) : c.json(session, 200, noStore);
}

// ---- POST /v1/auth/google/native ----

export const zGoogleNativeBody = z.object({
  idToken: z.string().min(20).max(8_000),
  nonce: z.string().min(16).max(256).optional(),
}).strict();

export async function verifyGoogleNativeToken(
  env: Env,
  body: z.infer<typeof zGoogleNativeBody>,
): Promise<VerifiedOidcIdentity> {
  const audiences = googleNativeAudiences(env);
  if (audiences.length === 0) throw new OidcTokenError("provider_off");
  return verifyGoogleIdToken(body.idToken, audiences, { expectedNonce: body.nonce });
}
