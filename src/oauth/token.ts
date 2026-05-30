import type { Context } from "hono";
import type { Env } from "../env.js";
import { putAccessToken, takeCode } from "../storage.js";
import { logEvent, randomId, sha256Base64Url } from "../util.js";

// /oauth/token — claude.ai posts here with the code we issued. Validate
// PKCE, promote the ckWebAuthToken from short-lived storage into the
// long-lived encrypted access-token store, hand back an access_token.

export async function token(c: Context<{ Bindings: Env }>) {
  const form = await c.req.formData().catch(() => null);
  if (!form) return c.json({ error: "invalid_request" }, 400);

  const grantType = String(form.get("grant_type") ?? "");
  const clientId = String(form.get("client_id") ?? "");
  if (grantType !== "authorization_code") {
    logEvent("oauth_token", { ok: false, grantType, clientId, error: "unsupported_grant_type" });
    return c.json({ error: "unsupported_grant_type" }, 400);
  }

  const code = String(form.get("code") ?? "");
  const codeVerifier = String(form.get("code_verifier") ?? "");
  const redirectUri = String(form.get("redirect_uri") ?? "");
  if (!code || !codeVerifier || !redirectUri || !clientId) {
    logEvent("oauth_token", { ok: false, grantType, clientId, error: "invalid_request" });
    return c.json({ error: "invalid_request" }, 400);
  }

  const stored = await takeCode(c.env, code);
  if (!stored) {
    logEvent("oauth_token", { ok: false, grantType, clientId, error: "invalid_grant", reason: "code_not_found" });
    return c.json({ error: "invalid_grant" }, 400);
  }
  if (stored.clientId !== clientId || stored.redirectUri !== redirectUri) {
    logEvent("oauth_token", { ok: false, grantType, clientId, error: "invalid_grant", reason: "client_or_redirect_mismatch" });
    return c.json({ error: "invalid_grant" }, 400);
  }

  // PKCE: code_challenge == base64url(sha256(code_verifier))
  const expected = await sha256Base64Url(codeVerifier);
  if (expected !== stored.codeChallenge) {
    logEvent("oauth_token", { ok: false, grantType, clientId, error: "invalid_grant", reason: "pkce" });
    return c.json({ error: "invalid_grant", reason: "pkce" }, 400);
  }

  const accessToken = randomId(40);
  await putAccessToken(c.env, accessToken, stored.ckWebAuthToken, clientId);

  // refreshIssued/expiresIn logged explicitly so the lapse investigation can
  // confirm the gateway issues a non-expiring access token and no refresh.
  logEvent("oauth_token", { ok: true, grantType, clientId, refreshIssued: false, expiresIn: null });
  return c.json({
    access_token: accessToken,
    token_type: "Bearer",
    // No expires_in: we treat tokens as long-lived; CloudKit will return
    // an auth error if its ckWebAuthToken has expired, and we'll surface
    // that as an MCP unauthorized response so claude.ai can re-auth.
  });
}
