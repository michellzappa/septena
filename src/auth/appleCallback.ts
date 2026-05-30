import type { Context } from "hono";
import type { Env } from "../env.js";
import { putCode, takeState } from "../storage.js";
import { logEvent, randomId, readCookie } from "../util.js";

// Apple redirects the user's browser here after sign-in, appending
// ?ckWebAuthToken=<...>. We recover the in-flight OAuth state via the
// cookie we set in /oauth/authorize, mint an auth code, and bounce the
// user back to claude.ai's redirect_uri with ?code=...&state=...

export async function appleCallback(c: Context<{ Bindings: Env }>) {
  const url = new URL(c.req.url);
  const ckWebAuthToken = url.searchParams.get("ckWebAuthToken");
  if (!ckWebAuthToken) {
    return c.text("Apple callback missing ckWebAuthToken", 400);
  }

  const stateId = readCookie(c.req.raw, "septena_oauth");
  if (!stateId) return c.text("missing state cookie — restart sign-in", 400);

  const state = await takeState(c.env, stateId);
  if (!state) return c.text("state expired — restart sign-in", 400);

  const code = randomId(32);
  await putCode(c.env, code, {
    ckWebAuthToken,
    codeChallenge: state.codeChallenge,
    clientId: state.clientId,
    redirectUri: state.redirectUri,
  });

  logEvent("apple_callback", { ok: true, clientId: state.clientId });

  const back = new URL(state.redirectUri);
  back.searchParams.set("code", code);
  back.searchParams.set("state", state.oauthState);

  return new Response(null, {
    status: 302,
    headers: {
      Location: back.toString(),
      // Clear the cookie now that we've consumed it.
      "Set-Cookie": "septena_oauth=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax",
    },
  });
}
