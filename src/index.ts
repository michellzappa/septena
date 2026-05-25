import { Hono } from "hono";
import type { Env } from "./env.js";
import { register } from "./oauth/register.js";
import { authorize } from "./oauth/authorize.js";
import { continueAuth } from "./oauth/continue.js";
import { token } from "./oauth/token.js";
import { appleCallback } from "./auth/appleCallback.js";
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

// OAuth 2.0 Authorization Server metadata (RFC 8414). MCP clients fetch
// this to discover the registration/authorize/token endpoints.
app.get("/.well-known/oauth-authorization-server", (c) => {
  const base = c.env.PUBLIC_URL;
  return c.json({
    issuer: base,
    authorization_endpoint: `${base}/oauth/authorize`,
    token_endpoint: `${base}/oauth/token`,
    registration_endpoint: `${base}/oauth/register`,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["none"],
  });
});

app.post("/oauth/register", register);
app.get("/oauth/authorize", authorize);
app.post("/oauth/continue", continueAuth);
app.post("/oauth/token", token);

app.get("/auth/apple/callback", appleCallback);

app.post("/mcp", mcpHandler);

export default app;
