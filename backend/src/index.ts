import { Hono } from "hono";
import type { Env } from "./env.js";
import { api } from "./api/routes.js";
import { plusContinue, plusLanding, plusStart } from "./api/plusLinks.js";
import { joinLanding } from "./api/shares.js";
import { admin } from "./admin/routes.js";
import { sweepAccounts } from "./admin/accounts.js";
import { recordMetrics } from "./admin/metrics.js";
import { sweepSupport } from "./support/routes.js";
import * as oauth from "./shadow/oauth.js";
import * as agentSignup from "./shadow/agentSignup.js";
import { previewMcpHandler } from "./shadow/mcp.js";
import { ONBOARD_MARKDOWN } from "./shadow/prompts.js";
import SKILL_MARKDOWN from "../skill.md";
import coreWasm from "./core/wasm/septena_core_wasm_bg.wasm";
import { initCore } from "./core/index.js";

// The shared core (ADR 0025), compiled at bundle time, instantiated once per
// isolate. The Durable Objects exported below share this isolate.
initCore(coreWasm);

export { TaskStore } from "./store/TaskStore.js";
export { ProjectStore } from "./store/ProjectStore.js";
export { AccountStore } from "./store/AccountStore.js";
export { PairingStore } from "./shadow/PairingStore.js";
export { SupportStore } from "./support/store.js";

const app = new Hono<{ Bindings: Env }>();

// The old CloudKit connector on mcp.septena.app was decommissioned on
// 2026-11-20. Its custom domain is gone from wrangler.toml; this answers any
// request that still reaches the Worker under that host, so a stale Claude
// connector gets a clear reason instead of the task connector's handlers.
const RETIRED_HOST = "mcp.septena.app";
app.use("*", async (c, next) => {
  if (new URL(c.req.url).host !== RETIRED_HOST) return next();
  return c.text(
    "mcp.septena.app was retired on 2026-11-20. Septena tasks are at https://api.septena.app/mcp (pair it from Septena).",
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
// OpenAI apps directory domain verification (docs/CONNECTOR_DIRECTORY_SUBMISSION.md).
app.get("/.well-known/openai-apps-challenge", (c) =>
  c.env.OPENAI_APPS_CHALLENGE
    ? c.text(c.env.OPENAI_APPS_CHALLENGE.trim(), 200, { "Cache-Control": "no-store" })
    : c.text("Not found", 404),
);
app.post("/oauth/register", oauth.register);
app.get("/oauth/authorize", oauth.authorize);
app.get("/oauth/pair/continue", oauth.pairContinue);
app.post("/oauth/pair/email", oauth.pairEmail);
app.get("/oauth/pair/oidc/:provider", oauth.pairOidc);
app.post("/oauth/pair/reviewer", oauth.pairReviewer);
// Where a sign-in QR lands when a system camera opens it (src/shadow/pairQr.ts).
app.get("/pair/:code", oauth.pairLanding);
// Where a human confirms a headless agent account creation/connection (ADR 0056).
app.get("/agent/confirm/:token", agentSignup.confirmPage);
app.post("/agent/confirm/:token", agentSignup.confirmSubmit);
// Where an invite to a shared project opens (src/api/shares.ts).
app.get("/join/:token", joinLanding);
// Where a Plus link opens (src/api/plusLinks.ts).
app.get("/plus/:token", plusLanding);
app.post("/plus/:token/start", plusStart);
app.get("/plus/:token/continue", plusContinue);
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

// The admin page (src/admin/), behind Cloudflare Access.
app.route("/admin", admin);

export default {
  fetch: app.fetch,
  async scheduled(_event, env) {
    if (env.MAINTENANCE !== "true") {
      await sweepAccounts(env);
      await recordMetrics(env);
      await sweepSupport(env);
    }
  },
} satisfies ExportedHandler<Env>;
