import type { Context } from "hono";
import type { Env } from "../env.js";
import { issueTokenPair, putUserCkToken, redeemRefreshToken, takeCode } from "../storage.js";
import { fetchUserRecordName } from "../cloudkit.js";
import { logEvent, sha256Base64Url } from "../util.js";

// /oauth/token — claude.ai posts here with the code we issued. Validate
// PKCE, promote the ckWebAuthToken from short-lived storage into the
// encrypted access-token store, hand back a finite-lived access token plus
// a rotating refresh token. The same endpoint services the refresh_token
// grant: each rotation spends the old refresh token and mints a new pair.

export async function token(c: Context<{ Bindings: Env }>) {
  const form = await c.req.formData().catch(() => null);
  if (!form) return c.json({ error: "invalid_request" }, 400);

  const grantType = String(form.get("grant_type") ?? "");
  const clientId = String(form.get("client_id") ?? "");

  if (grantType === "refresh_token") {
    const refreshToken = String(form.get("refresh_token") ?? "");
    if (!refreshToken || !clientId) {
      logEvent("oauth_token", { ok: false, grantType, clientId, error: "invalid_request" });
      return c.json({ error: "invalid_request" }, 400);
    }
    const res = await redeemRefreshToken(c.env, refreshToken, clientId);
    if (!res.ok) {
      logEvent("oauth_token", { ok: false, grantType, clientId, error: "invalid_grant", reason: res.reason });
      return c.json({ error: "invalid_grant" }, 400);
    }
    logEvent("oauth_token", { ok: true, grantType, clientId, refreshIssued: true, expiresIn: res.expiresIn });
    return c.json({
      access_token: res.accessToken,
      refresh_token: res.refreshToken,
      token_type: "Bearer",
      expires_in: res.expiresIn,
    });
  }

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

  // Bind this bearer to the CloudKit user so it tracks the app-refreshed
  // token, rather than freezing the one captured at sign-in. Also seed the
  // per-user store with this token so it works immediately, before the
  // app's first push. Best-effort: if whoami fails we still store the
  // captured token directly on the bearer (legacy path) so connect works.
  let userRecordName: string | null = null;
  try {
    userRecordName = await fetchUserRecordName(c.env, stored.ckWebAuthToken);
    if (userRecordName) {
      await putUserCkToken(c.env, userRecordName, stored.ckWebAuthToken);
    }
  } catch (e) {
    logEvent("oauth_token_whoami", { ok: false, error: e instanceof Error ? e.message : String(e) });
  }

  const grant = await issueTokenPair(c.env, {
    clientId,
    userRecordName: userRecordName ?? undefined,
    ckWebAuthToken: stored.ckWebAuthToken,
  });

  logEvent("oauth_token", { ok: true, grantType, clientId, bound: !!userRecordName, refreshIssued: true, expiresIn: grant.expiresIn });
  return c.json({
    access_token: grant.accessToken,
    refresh_token: grant.refreshToken,
    token_type: "Bearer",
    expires_in: grant.expiresIn,
  });
}
