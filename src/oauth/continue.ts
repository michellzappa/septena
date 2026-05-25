import type { Context } from "hono";
import type { Env } from "../env.js";
import { peekState } from "../storage.js";
import { readCookie } from "../util.js";

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

export async function continueAuth(c: Context<{ Bindings: Env }>) {
  const stateId = readCookie(c.req.raw, "septena_oauth");
  if (!stateId) {
    return c.text("missing session — restart sign-in from claude.ai", 400);
  }

  const state = await peekState(c.env, stateId);
  if (!state) {
    return c.text("session expired — restart sign-in from claude.ai", 400);
  }

  const appleUrl = new URL(
    `https://api.apple-cloudkit.com/database/1/${c.env.CK_CONTAINER}/${c.env.CK_ENVIRONMENT}/private/users/current`,
  );
  appleUrl.searchParams.set("ckAPIToken", c.env.CK_API_TOKEN);

  const probe = await fetch(appleUrl.toString(), {
    headers: { Accept: "application/json" },
  });
  const body = (await probe.json().catch(() => null)) as
    | { redirectURL?: string; serverErrorCode?: string; reason?: string }
    | null;
  if (!body?.redirectURL) {
    const detail = body?.serverErrorCode ?? body?.reason ?? `HTTP ${probe.status}`;
    return c.text(`apple sign-in unavailable: ${detail}`, 502);
  }

  return new Response(null, {
    status: 302,
    headers: {
      Location: body.redirectURL,
      "Cache-Control": "no-store",
    },
  });
}
