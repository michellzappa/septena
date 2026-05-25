import type { Context } from "hono";
import type { Env } from "../env.js";
import { getClient, putState } from "../storage.js";
import { randomId } from "../util.js";

// /oauth/authorize — claude.ai sends user's browser here.
// We stash the PKCE+state in KV under a random id, set that id as a
// cookie, and render a consent page. The user clicks "Continue" which
// POSTs to /oauth/continue; that handler probes CloudKit for the Apple
// sign-in URL and 302s the browser to idmsa.apple.com. Apple comes back
// to /auth/apple/callback where we resume using the cookie.
//
// The extra interstitial exists because (a) Apple's HIG recommends an
// explainer before handing the user off to an external IdP and (b) it
// gives us a place to surface scopes / errors / brand without depending
// on Apple's flow being available.

export async function authorize(c: Context<{ Bindings: Env }>) {
  const url = new URL(c.req.url);

  // Preview mode: render the consent page with placeholder copy so you
  // can eyeball styling without going through claude.ai's full flow.
  // Clicking Continue 400s ("missing session") since no state cookie is set.
  if (url.searchParams.get("preview") === "1") {
    return new Response(consentPage("claude.ai"), {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  }

  const clientId = url.searchParams.get("client_id");
  const redirectUri = url.searchParams.get("redirect_uri");
  const responseType = url.searchParams.get("response_type");
  const state = url.searchParams.get("state");
  const codeChallenge = url.searchParams.get("code_challenge");
  const codeChallengeMethod = url.searchParams.get("code_challenge_method");

  if (responseType !== "code") return c.text("unsupported_response_type", 400);
  if (!clientId || !redirectUri || !state || !codeChallenge) {
    return c.text("invalid_request", 400);
  }
  if (codeChallengeMethod !== "S256") {
    return c.text("PKCE S256 required", 400);
  }

  const client = await getClient(c.env, clientId);
  if (!client) return c.text("unknown client", 400);
  if (!client.redirectUris.includes(redirectUri)) {
    return c.text("redirect_uri not registered", 400);
  }

  const stateId = randomId(24);
  await putState(c.env, stateId, {
    oauthState: state,
    codeChallenge,
    codeChallengeMethod: "S256",
    clientId,
    redirectUri,
    createdAt: Date.now(),
  });

  const clientName = escapeHtml(client.name ?? clientId);
  const html = consentPage(clientName);

  return new Response(html, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Set-Cookie": cookie("septena_oauth", stateId),
      "Cache-Control": "no-store",
    },
  });
}

function consentPage(clientName: string): string {
  // Inline CSS — Workers don't serve static assets here. System font
  // stack matches Apple's sign-in look. Respects dark mode.
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sign in to Septena</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0;
    min-height: 100vh;
    display: grid;
    place-items: center;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    background: #fafafa;
    color: #1a1a1a;
  }
  @media (prefers-color-scheme: dark) {
    body { background: #0a0a0a; color: #f5f5f5; }
    .card { background: #161616; border-color: #2a2a2a; }
    .scope-list { background: #1f1f1f; border-color: #2a2a2a; }
    .footer { color: #888; }
  }
  .card {
    background: #fff;
    border: 1px solid #e5e5e5;
    border-radius: 14px;
    padding: 36px 32px 28px;
    max-width: 420px;
    width: calc(100% - 32px);
    box-shadow: 0 10px 30px rgba(0,0,0,0.05);
  }
  .logo {
    font-size: 28px;
    font-weight: 700;
    letter-spacing: -0.02em;
    margin: 0 0 6px;
  }
  h1 {
    font-size: 17px;
    font-weight: 600;
    margin: 18px 0 6px;
  }
  p {
    margin: 0 0 14px;
    line-height: 1.45;
    font-size: 15px;
    color: #4a4a4a;
  }
  @media (prefers-color-scheme: dark) { p { color: #b5b5b5; } }
  .scope-list {
    background: #f5f5f7;
    border: 1px solid #e5e5e5;
    border-radius: 8px;
    padding: 12px 14px;
    font-size: 13px;
    line-height: 1.6;
    margin: 8px 0 20px;
  }
  .scope-list strong { font-weight: 600; }
  button, .secondary {
    display: block;
    width: 100%;
    padding: 12px 18px;
    border-radius: 10px;
    border: 0;
    font-size: 16px;
    font-weight: 500;
    cursor: pointer;
    text-align: center;
    text-decoration: none;
    font-family: inherit;
  }
  button {
    background: #0a84ff;
    color: white;
    margin-bottom: 8px;
  }
  button:hover { background: #0066d6; }
  .secondary {
    background: transparent;
    color: #0a84ff;
    border: 0;
    padding: 8px;
    font-size: 14px;
  }
  .secondary:hover { text-decoration: underline; }
  .footer {
    font-size: 12px;
    color: #999;
    text-align: center;
    margin-top: 18px;
    line-height: 1.5;
  }
</style>
</head>
<body>
  <main class="card">
    <div class="logo">Septena</div>
    <h1>${clientName} wants to access your data</h1>
    <p>To continue, sign in with your iCloud account on the next screen. Your iCloud password never reaches Septena or ${clientName} — Apple authenticates you directly.</p>
    <div class="scope-list">
      <strong>${clientName} will be able to:</strong><br>
      • Read and write your tasks, areas, projects, and sections<br>
      • Read and write your habits, supplements, chores, and goals<br>
      • Read and write your app settings
    </div>
    <form method="POST" action="/oauth/continue">
      <button type="submit">Continue with iCloud</button>
    </form>
    <a class="secondary" href="javascript:history.back()">Cancel</a>
    <p class="footer">You can revoke this access any time in claude.ai's connector settings or by signing out of this device.</p>
  </main>
</body>
</html>`;
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (ch) =>
    ch === "&" ? "&amp;" :
    ch === "<" ? "&lt;" :
    ch === ">" ? "&gt;" :
    ch === '"' ? "&quot;" : "&#39;"
  );
}

function cookie(name: string, value: string): string {
  // 10-minute cookie — matches state TTL. HttpOnly so JS can't read it;
  // SameSite=Lax lets the Apple→us redirect carry it.
  return [
    `${name}=${encodeURIComponent(value)}`,
    "Path=/",
    "HttpOnly",
    "Secure",
    "SameSite=Lax",
    "Max-Age=600",
  ].join("; ");
}
