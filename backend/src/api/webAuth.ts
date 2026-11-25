import type { Context, Next } from "hono";
import type { Env } from "../env.js";
import { randomId, readCookie, sha256Base64Url } from "../util.js";
import { REFRESH_TTL_S, type IssuedSession } from "./session.js";

// Web client auth, CORS and WebSocket ticket helpers (docs/WEB_CLIENT_SPEC.md §4–§5).

export const REFRESH_COOKIE_NAME = "septena_refresh";
export const WS_TICKET_TTL_S = 30;
// Cloudflare KV requires expirationTtl >= 60s; exact 30s lifetime is enforced via expiresAt.
const WS_TICKET_KV_TTL_S = 60;
const WS_TICKET_PREFIX = "wst_";

const ALLOW_METHODS = "GET, POST, PUT, PATCH, DELETE, OPTIONS";
const ALLOW_HEADERS = "Authorization, Content-Type, X-Septena-Client";
const EXPOSE_HEADERS = "ETag";

export function allowedWebOrigins(env: Env): string[] {
  const raw = env.WEB_ALLOWED_ORIGINS;
  if (!raw) return [];
  return raw
    .split(",")
    .map((o) => o.trim().replace(/\/$/, ""))
    .filter((o) => o.length > 0);
}

export function isAllowedWebOrigin(env: Env, origin: string | undefined | null): origin is string {
  if (!origin) return false;
  return allowedWebOrigins(env).includes(origin);
}

function isSecureCookie(env: Env): boolean {
  return !(env.API_PUBLIC_URL?.startsWith("http://"));
}

export function buildRefreshCookie(env: Env, refreshToken: string): string {
  const parts = [
    `${REFRESH_COOKIE_NAME}=${encodeURIComponent(refreshToken)}`,
    "Path=/v1/auth",
    `Max-Age=${REFRESH_TTL_S}`,
    "HttpOnly",
  ];
  if (isSecureCookie(env)) parts.push("Secure");
  parts.push("SameSite=Lax");
  return parts.join("; ");
}

export function clearRefreshCookie(env: Env): string {
  const parts = [
    `${REFRESH_COOKIE_NAME}=`,
    "Path=/v1/auth",
    "Max-Age=0",
    "HttpOnly",
  ];
  if (isSecureCookie(env)) parts.push("Secure");
  parts.push("SameSite=Lax");
  return parts.join("; ");
}

export function readRefreshCookie(req: Request): string | null {
  const token = readCookie(req, REFRESH_COOKIE_NAME);
  if (!token || token.length < 20 || token.length > 400) return null;
  return token;
}

export function cookieSessionResponse(env: Env, session: IssuedSession): Response {
  return new Response(
    JSON.stringify({
      accessToken: session.accessToken,
      expiresIn: session.expiresIn,
      userId: session.userId,
    }),
    {
      status: 200,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
        "Set-Cookie": buildRefreshCookie(env, session.refreshToken),
      },
    },
  );
}

function appendVary(headers: Headers, value: string): void {
  const existing = headers.get("Vary");
  if (!existing) {
    headers.set("Vary", value);
    return;
  }
  const parts = existing.split(",").map((p) => p.trim().toLowerCase());
  if (!parts.includes(value.toLowerCase())) {
    headers.set("Vary", `${existing}, ${value}`);
  }
}

export async function webCorsMiddleware<E extends { Bindings: Env }>(
  c: Context<E>,
  next: Next,
): Promise<Response | void> {
  const origin = c.req.header("Origin");
  const allowed = isAllowedWebOrigin(c.env, origin);

  if (c.req.method === "OPTIONS") {
    if (!allowed) {
      return c.json({ error: "origin_not_allowed" }, 403, { Vary: "Origin" });
    }
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Credentials": "true",
        "Access-Control-Allow-Methods": ALLOW_METHODS,
        "Access-Control-Allow-Headers": ALLOW_HEADERS,
        "Access-Control-Max-Age": "86400",
        Vary: "Origin",
      },
    });
  }

  await next();

  if (!allowed || !c.res || c.res.status === 101) return;

  // Clone headers when the handler returned an immutable Response.
  try {
    c.res.headers.set("Access-Control-Allow-Origin", origin);
    c.res.headers.set("Access-Control-Allow-Credentials", "true");
    c.res.headers.set("Access-Control-Expose-Headers", EXPOSE_HEADERS);
    appendVary(c.res.headers, "Origin");
  } catch {
    const headers = new Headers(c.res.headers);
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Access-Control-Allow-Credentials", "true");
    headers.set("Access-Control-Expose-Headers", EXPOSE_HEADERS);
    appendVary(headers, "Origin");
    c.res = new Response(c.res.body, {
      status: c.res.status,
      statusText: c.res.statusText,
      headers,
    });
  }
}

// ---- single-use WebSocket tickets (WEB_CLIENT_SPEC.md §5) ----

export interface WsTicketClaims {
  userId: string;
  sid: string | null;
  client: string | null;
}

interface StoredWsTicket extends WsTicketClaims {
  expiresAt: number;
}

export async function issueWsTicket(
  env: Env,
  claims: WsTicketClaims,
  now = Date.now(),
): Promise<{ ticket: string; expiresIn: number }> {
  const ticket = `${WS_TICKET_PREFIX}${randomId(24)}`;
  const hash = await sha256Base64Url(ticket);
  const stored: StoredWsTicket = {
    userId: claims.userId,
    sid: claims.sid,
    client: claims.client,
    expiresAt: now + WS_TICKET_TTL_S * 1000,
  };
  await env.STATE.put(`ws-ticket:${hash}`, JSON.stringify(stored), {
    expirationTtl: WS_TICKET_KV_TTL_S,
  });
  return { ticket, expiresIn: WS_TICKET_TTL_S };
}

export async function redeemWsTicket(
  env: Env,
  ticket: string,
  now = Date.now(),
): Promise<WsTicketClaims | null> {
  if (!ticket.startsWith(WS_TICKET_PREFIX) || ticket.length < 24 || ticket.length > 128) {
    return null;
  }
  const hash = await sha256Base64Url(ticket);
  const key = `ws-ticket:${hash}`;
  const raw = await env.STATE.get(key);
  if (!raw) return null;
  // Single-use: consume before validating expiry so replay is never possible.
  await env.STATE.delete(key);
  try {
    const stored = JSON.parse(raw) as StoredWsTicket;
    if (typeof stored.userId !== "string" || typeof stored.expiresAt !== "number") return null;
    if (now > stored.expiresAt) return null;
    return {
      userId: stored.userId,
      sid: typeof stored.sid === "string" ? stored.sid : null,
      client: typeof stored.client === "string" ? stored.client : null,
    };
  } catch {
    return null;
  }
}
