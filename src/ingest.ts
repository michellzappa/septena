import type { Context } from "hono";
import type { Env } from "./env.js";
import { putUserCkToken } from "./storage.js";
import { fetchUserRecordName } from "./cloudkit.js";
import { logEvent } from "./util.js";

// POST /internal/ck-token — a user's app pushes a freshly-minted
// ckWebAuthToken here (via CKFetchWebAuthTokenOperation). The app holds
// durable native CloudKit auth, so it re-mints on launch/foreground/
// background and keeps the gateway supplied — making expiry invisible.
//
// Multi-user identity: we do NOT trust the caller to say who they are. We
// validate the pushed token against CloudKit and DERIVE the owner's userId
// from the response, then store it in that user's slot. A push can only
// ever affect the account that minted the token.
//
// APP_INGEST_SECRET is a coarse, app-wide gate (embedded in every app
// build) to throttle abuse — it is NOT the per-user identity gate. The
// real binding is the CloudKit validation below.

export async function ingestCkToken(c: Context<{ Bindings: Env }>) {
  const auth = c.req.header("Authorization") ?? "";
  const m = auth.match(/^Bearer\s+(.+)$/);
  if (!m || m[1] !== c.env.APP_INGEST_SECRET) {
    logEvent("ingest_ck_token", { ok: false, reason: "bad app key" });
    return c.json({ error: "unauthorized" }, 401);
  }

  const body = (await c.req.json().catch(() => null)) as { ckWebAuthToken?: string } | null;
  const ckWebAuthToken = body?.ckWebAuthToken;
  if (!ckWebAuthToken || typeof ckWebAuthToken !== "string") {
    return c.json({ error: "missing ckWebAuthToken" }, 400);
  }

  // Validate + derive identity from CloudKit. Rejects expired/invalid tokens
  // so we never store a dead token or bind to an unknown user.
  const userId = await fetchUserRecordName(c.env, ckWebAuthToken);
  if (!userId) {
    logEvent("ingest_ck_token", { ok: false, reason: "token invalid / identity unresolved" });
    return c.json({ error: "invalid token" }, 400);
  }

  await putUserCkToken(c.env, userId, ckWebAuthToken);
  logEvent("ingest_ck_token", { ok: true, userId });
  return c.json({ ok: true });
}
