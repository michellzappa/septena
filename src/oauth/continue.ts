import type { Context } from "hono";
import type { Env } from "../env.js";
import { peekState } from "../storage.js";
import { logEvent, readCookie } from "../util.js";

// POST /oauth/continue — the consent page's form posts here. We verify
// the in-flight state cookie, probe CloudKit for Apple's sign-in URL,
// and 302 the browser to idmsa.apple.com. The state record stays in KV
// (peek, not take) so /auth/apple/callback can consume it after Apple
// redirects back.
//
// CloudKit's /users/current endpoint is JSON-only: when unauthenticated
// it returns a body with `redirectURL` pointing at the real Apple
// sign-in page. Redirecting the browser straight at the JSON endpoint
// would just render raw JSON — we have to follow the redirect server-side.

// Probe CloudKit for Apple's sign-in redirect URL.
export async function probeAppleSignInURL(
  env: Env,
): Promise<{ ok: true; redirectURL: string } | { ok: false; status: 502; detail: string }> {
  const appleUrl = new URL(
    `https://api.apple-cloudkit.com/database/1/${env.CK_CONTAINER}/${env.CK_ENVIRONMENT}/private/users/current`,
  );
  appleUrl.searchParams.set("ckAPIToken", env.CK_API_TOKEN);

  const probe = await fetch(appleUrl.toString(), {
    headers: { Accept: "application/json" },
  });
  const body = (await probe.json().catch(() => null)) as
    | { redirectURL?: string; serverErrorCode?: string; reason?: string }
    | null;
  if (!body?.redirectURL) {
    const detail = body?.serverErrorCode ?? body?.reason ?? `HTTP ${probe.status}`;
    return { ok: false, status: 502, detail };
  }
  return { ok: true, redirectURL: body.redirectURL };
}

export async function continueAuth(c: Context<{ Bindings: Env }>) {
  const stateId = readCookie(c.req.raw, "septena_oauth");
  if (!stateId) {
    return c.text("missing session — restart sign-in from claude.ai", 400);
  }

  const state = await peekState(c.env, stateId);
  if (!state) {
    return c.text("session expired — restart sign-in from claude.ai", 400);
  }

  const apple = await probeAppleSignInURL(c.env);
  if (!apple.ok) {
    logEvent("oauth_continue", { ok: false, clientId: state.clientId, detail: apple.detail });
    return c.text(`apple sign-in unavailable: ${apple.detail}`, apple.status);
  }

  logEvent("oauth_continue", { ok: true, clientId: state.clientId });
  return new Response(null, {
    status: 302,
    headers: {
      Location: apple.redirectURL,
      "Cache-Control": "no-store",
    },
  });
}
