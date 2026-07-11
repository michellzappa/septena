import type { Context } from "hono";
import type { Env } from "../env.js";
import { revokeToken } from "../storage.js";
import { logEvent } from "../util.js";

// RFC 7009 token revocation. Accepts access or refresh tokens (the
// token_type_hint is ignored — we just try both). Revoking a refresh token
// also kills the family's current access token. Per spec the endpoint
// returns 200 even for unknown tokens, so callers can't probe which
// tokens exist.

export async function revoke(c: Context<{ Bindings: Env }>) {
  const form = await c.req.formData().catch(() => null);
  const token = form ? String(form.get("token") ?? "") : "";
  if (!token) return c.json({ error: "invalid_request" }, 400);

  const revoked = await revokeToken(c.env, token);
  logEvent("oauth_revoke", { revoked });
  return new Response(null, { status: 200 });
}
