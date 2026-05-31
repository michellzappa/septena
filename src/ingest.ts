import type { Context } from "hono";
import type { Env } from "./env.js";
import { putCurrentCkToken } from "./storage.js";
import { logEvent } from "./util.js";

// POST /internal/ck-token — the iOS app pushes a freshly-minted
// ckWebAuthToken here. The app holds durable native CloudKit auth, so it
// can re-mint web tokens (CKFetchWebAuthTokenOperation) on launch /
// foreground / background-refresh and keep this current — making token
// expiry invisible to the user (Claude never has to reconnect).
//
// Auth: a shared bearer secret (APP_INGEST_SECRET). Single-user for now;
// embed in the app. Move to per-user auth when the product is multi-tenant.

export async function ingestCkToken(c: Context<{ Bindings: Env }>) {
  const auth = c.req.header("Authorization") ?? "";
  const m = auth.match(/^Bearer\s+(.+)$/);
  if (!m || m[1] !== c.env.APP_INGEST_SECRET) {
    logEvent("ingest_ck_token", { ok: false, reason: "bad secret" });
    return c.json({ error: "unauthorized" }, 401);
  }

  const body = (await c.req.json().catch(() => null)) as { ckWebAuthToken?: string } | null;
  const ckWebAuthToken = body?.ckWebAuthToken;
  if (!ckWebAuthToken || typeof ckWebAuthToken !== "string") {
    return c.json({ error: "missing ckWebAuthToken" }, 400);
  }

  await putCurrentCkToken(c.env, ckWebAuthToken);
  logEvent("ingest_ck_token", { ok: true, len: ckWebAuthToken.length });
  return c.json({ ok: true });
}
