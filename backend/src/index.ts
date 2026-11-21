import { Hono } from "hono";
import type { Env } from "./env.js";
import { api } from "./api/routes.js";
import * as oauth from "./shadow/oauth.js";
import { previewMcpHandler } from "./shadow/mcp.js";
import { ONBOARD_MARKDOWN } from "./shadow/prompts.js";
import SKILL_MARKDOWN from "../skill.md";

export { TaskStore } from "./store/TaskStore.js";
export { PairingStore } from "./shadow/PairingStore.js";

const app = new Hono<{ Bindings: Env }>();

// The old CloudKit connector on mcp.septena.app was decommissioned on
// 2026-11-20. Its custom domain is gone from wrangler.toml; this answers any
// request that still reaches the Worker under that host, so a stale Claude
// connector gets a clear reason instead of the task connector's handlers.
const RETIRED_HOST = "mcp.septena.app";
app.use("*", async (c, next) => {
  if (new URL(c.req.url).host !== RETIRED_HOST) return next();
  return c.text(
    "mcp.septena.app was retired on 2026-11-20. Septena tasks are at https://api.septena.app/mcp (pair it from Septask).",
    410,
  );
});

// Copy window of the account move: nothing may write to the old stores while
// they are copied. Admin routes stay open for the copy itself.
app.use("*", async (c, next) => {
  if (c.env.MAINTENANCE !== "true") return next();
  const path = new URL(c.req.url).pathname;
  if (path === "/health" || path.startsWith("/v1/admin/")) return next();
  return c.json({ error: "maintenance" }, 503, { "Retry-After": "300" });
});

app.get("/health", (c) => c.json({ ok: true }));

// The agent brief for the task tools, as markdown.
app.get("/skill.md", (c) =>
  c.text(SKILL_MARKDOWN, 200, {
    "Content-Type": "text/markdown; charset=utf-8",
    "Cache-Control": "public, max-age=300",
  }),
);

// The onboarding script for bootstrapping areas, projects, notes and tasks (#124).
app.get("/onboard.md", (c) =>
  c.text(ONBOARD_MARKDOWN, 200, {
    "Content-Type": "text/markdown; charset=utf-8",
    "Cache-Control": "public, max-age=300",
  }),
);

// OAuth for the task connector: discovery (RFC 8414, RFC 9728), dynamic
// client registration, and the app-pairing authorize flow (src/shadow/oauth.ts).
app.get("/.well-known/oauth-authorization-server", oauth.authServerMetadata);
app.get("/.well-known/oauth-protected-resource", oauth.protectedResourceMetadata);
app.post("/oauth/register", oauth.register);
app.get("/oauth/authorize", oauth.authorize);
app.get("/oauth/pair/continue", oauth.pairContinue);
app.post("/oauth/token", oauth.token);
app.post("/oauth/revoke", oauth.revoke);

// The task connector (MCP over JSON-RPC, src/shadow/mcp.ts).
app.post("/mcp", previewMcpHandler);

// Revision 2026-07-28 removed the GET stream endpoint and protocol-level
// sessions (which were torn down with DELETE). A server on this revision
// answers both with 405, so an older client fails fast and falls back instead
// of reading a 404 as "there is no MCP endpoint here at all".
app.on(["GET", "DELETE"], "/mcp", (c) =>
  c.text("Method Not Allowed", 405, { Allow: "POST" }),
);

// Task backend API (docs/SEPTASK_BACKEND.md in the app repo).
app.route("/v1", api);

export default { fetch: app.fetch };
