import type { Context } from "hono";
import type { Env } from "../env.js";
import { putClient } from "../storage.js";
import { randomId } from "../util.js";

// RFC 7591 Dynamic Client Registration. MCP clients (e.g. claude.ai) POST
// here before starting OAuth. We accept any client — there's no human
// approval gate — because the security boundary is the per-user Apple
// sign-in, not the client identity.

export async function register(c: Context<{ Bindings: Env }>) {
  const body = await c.req
    .json<{ redirect_uris?: string[]; client_name?: string }>()
    .catch(() => ({}) as { redirect_uris?: string[]; client_name?: string });

  const redirectUris = body.redirect_uris ?? [];
  if (redirectUris.length === 0) {
    return c.json({ error: "invalid_redirect_uri" }, 400);
  }

  const clientId = randomId(24);
  await putClient(c.env, {
    clientId,
    redirectUris,
    name: body.client_name,
    createdAt: Date.now(),
  });

  return c.json({
    client_id: clientId,
    client_id_issued_at: Math.floor(Date.now() / 1000),
    redirect_uris: redirectUris,
    grant_types: ["authorization_code"],
    response_types: ["code"],
    token_endpoint_auth_method: "none", // public client (PKCE)
  });
}
