import { Hono } from "hono";
import type { Env } from "./env.js";
import { cleanupAccessTokens } from "./storage.js";
import { register } from "./oauth/register.js";
import { authorize } from "./oauth/authorize.js";
import { continueAuth } from "./oauth/continue.js";
import { token } from "./oauth/token.js";
import { revoke } from "./oauth/revoke.js";
import { appleCallback } from "./auth/appleCallback.js";
import { ingestCkToken } from "./ingest/ckToken.js";
import { mcpHandler } from "./mcp.js";
import { landingHTML, SKILL_MARKDOWN } from "./landing.js";

const app = new Hono<{ Bindings: Env }>();

// Public landing page — introduces the gateway and embeds the skill brief.
// Both humans (browsing) and models (fetching the URL) land here.
app.get("/", (c) =>
  c.html(landingHTML(), 200, {
    // Short cache: the skill text changes when we ship new tools.
    "Cache-Control": "public, max-age=300",
  }),
);

// Raw markdown — for copy-paste into MCP client system prompts, Claude Code
// skill files, or any other context where rendered HTML is unhelpful.
app.get("/skill.md", (c) =>
  c.text(SKILL_MARKDOWN, 200, {
    "Content-Type": "text/markdown; charset=utf-8",
    "Cache-Control": "public, max-age=300",
  }),
);

app.get("/health", (c) => c.json({ ok: true }));

// Apple App Site Association — lets Septena AND Septask claim mcp.septena.app
// via the Associated Domains `webcredentials` service, which is what
// ASWebAuthenticationSession's HTTPS callback (.https) requires before it
// will hand the /auth/apple/callback redirect (carrying ckWebAuthToken)
// back to the app. Both iOS apps ship the same webcredentials:mcp.septena.app
// entitlement — every App ID needs to be listed here or iOS silently refuses
// the association (webAuth.start() returns false, no sheet ever shows).
// webcredentials only — we deliberately do NOT add applinks (no
// universal-link hijacking of the landing page).
app.get("/.well-known/apple-app-site-association", (c) =>
  c.json(
    {
      webcredentials: {
        apps: ["992N457T8D.com.septena.cloud", "992N457T8D.com.septena.tasks"],
      },
    },
    200,
    { "Cache-Control": "public, max-age=3600" },
  ),
);

// OAuth 2.0 Authorization Server metadata (RFC 8414). MCP clients fetch
// this to discover the registration/authorize/token endpoints.
app.get("/.well-known/oauth-authorization-server", (c) => {
  const base = c.env.PUBLIC_URL;
  return c.json({
    issuer: base,
    authorization_endpoint: `${base}/oauth/authorize`,
    token_endpoint: `${base}/oauth/token`,
    registration_endpoint: `${base}/oauth/register`,
    revocation_endpoint: `${base}/oauth/revoke`,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["none"],
    revocation_endpoint_auth_methods_supported: ["none"],
    // RFC 9207: we return `iss` on the authorization response, so advertise it
    // and let conforming clients validate it (MCP 2026-07-28 requires them to
    // when present).
    authorization_response_iss_parameter_supported: true,
  });
});

// OAuth 2.0 Protected Resource Metadata (RFC 9728). Required by the MCP
// 2025-06 auth spec: the resource server advertises which authorization
// server(s) can issue tokens for it. Claude's MCP client follows the
// `resource_metadata` parameter we emit in `WWW-Authenticate` here, then
// uses `authorization_servers[0]` to find the AS metadata above and
// re-runs OAuth without bothering the user (assuming Apple's browser
// session cookie is still alive).
app.get("/.well-known/oauth-protected-resource", (c) => {
  const base = c.env.PUBLIC_URL;
  return c.json({
    resource: base,
    authorization_servers: [base],
    bearer_methods_supported: ["header"],
  });
});

app.post("/oauth/register", register);
app.get("/oauth/authorize", authorize);
app.post("/oauth/continue", continueAuth);
app.post("/oauth/token", token);
app.post("/oauth/revoke", revoke);

app.get("/auth/apple/callback", appleCallback);

app.post("/mcp", mcpHandler);

// Revision 2026-07-28 removed the GET stream endpoint and protocol-level
// sessions (which were torn down with DELETE). A server on this revision
// answers both with 405, so an older client fails fast and falls back instead
// of reading a 404 as "there is no MCP endpoint here at all".
app.on(["GET", "DELETE"], "/mcp", (c) =>
  c.text("Method Not Allowed", 405, { Allow: "POST" }),
);

// The app pushes freshly-minted ckWebAuthTokens here so bearers serve a
// live token without the user re-authing every ~8h. Self-securing: the
// pushed token is validated against CloudKit's users/current.
app.post("/ingest/ck-token", ingestCkToken);

// Access/refresh tokens now carry KV TTLs and self-expire; this cron is
// belt-and-braces for what doesn't: legacy raw-keyed token records from
// before the hashed-key cutover, and per-user cktoken: records (no TTL).
// CloudKit tokens die within hours, so a week of idleness means dead.
const TOKEN_MAX_IDLE_MS = 7 * 24 * 60 * 60 * 1000;

export default {
  fetch: app.fetch,
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(
      cleanupAccessTokens(env, TOKEN_MAX_IDLE_MS).then((n) =>
        console.log(JSON.stringify({ evt: "token_cleanup", deleted: n })),
      ),
    );
  },
};
