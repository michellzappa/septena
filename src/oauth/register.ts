import type { Context } from "hono";
import type { Env } from "../env.js";
import { putClient, type ClientRecord } from "../storage.js";
import { logEvent, randomId } from "../util.js";
import { validateRedirectUri } from "./redirects.js";

// RFC 7591 Dynamic Client Registration. MCP clients (e.g. claude.ai) POST
// here before starting OAuth. There's no human approval gate, so the
// redirect_uris are the security boundary against consent phishing: they
// must be https (or loopback) and on a pinned known-client host — see
// redirects.ts. client_name is sanitized because the consent page renders
// it to the user.

const MAX_REDIRECT_URIS = 5;
const MAX_CLIENT_NAME_LENGTH = 100;

export async function register(c: Context<{ Bindings: Env }>) {
  return registerClient(c, (env, rec) => putClient(env, rec), "oauth_register");
}

/// The registration logic, shared with the api.septena.app preview
/// (src/shadow/oauth.ts), which stores its clients under its own KV prefix.
export async function registerClient(
  c: Context<{ Bindings: Env }>,
  save: (env: Env, rec: ClientRecord) => Promise<void>,
  logName: string,
) {
  const body = await c.req
    .json<{ redirect_uris?: unknown; client_name?: unknown }>()
    .catch(() => ({}) as { redirect_uris?: unknown; client_name?: unknown });

  const redirectUris = Array.isArray(body.redirect_uris)
    ? body.redirect_uris.filter((u): u is string => typeof u === "string")
    : [];
  if (redirectUris.length === 0 || redirectUris.length > MAX_REDIRECT_URIS) {
    logEvent(logName, { ok: false, error: "invalid_redirect_uri", count: redirectUris.length });
    return c.json({ error: "invalid_redirect_uri" }, 400);
  }
  for (const uri of redirectUris) {
    const reason = validateRedirectUri(uri);
    if (reason) {
      logEvent(logName, { ok: false, error: "invalid_redirect_uri", reason });
      return c.json({ error: "invalid_redirect_uri", error_description: reason }, 400);
    }
  }

  // Strip control characters and cap length — this string is shown to the
  // user on the consent page (HTML-escaped there, but keep it sane here too).
  const name = typeof body.client_name === "string"
    ? body.client_name.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, MAX_CLIENT_NAME_LENGTH)
    : "";

  const clientId = randomId(24);
  await save(c.env, {
    clientId,
    redirectUris,
    name: name || undefined,
    createdAt: Date.now(),
  });

  logEvent(logName, { ok: true, clientId, redirectUris, name });
  return c.json({
    client_id: clientId,
    client_id_issued_at: Math.floor(Date.now() / 1000),
    redirect_uris: redirectUris,
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    token_endpoint_auth_method: "none", // public client (PKCE)
  });
}
