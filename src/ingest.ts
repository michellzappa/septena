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
// SECURITY: no embedded app secret. The endpoint is self-securing because we
// VALIDATE the pushed token against CloudKit and DERIVE the owner's userId
// from the response. A push can therefore only ever update the slot of the
// account that minted the token — writing someone else's slot would require
// their valid ckWebAuthToken (i.e. their iCloud auth). An embedded shared
// secret would add nothing to that guarantee.
//
// ABUSE: validation costs one CloudKit round-trip, so guard against spam
// with (a) a cheap length pre-check below and (b) a Cloudflare rate-limit
// rule on this path (configured in the dashboard, not in code).

export async function ingestCkToken(c: Context<{ Bindings: Env }>) {
  const body = (await c.req.json().catch(() => null)) as { ckWebAuthToken?: string } | null;
  const ckWebAuthToken = body?.ckWebAuthToken;
  // Cheap reject of obvious junk before paying for CloudKit validation.
  if (!ckWebAuthToken || typeof ckWebAuthToken !== "string" || ckWebAuthToken.length < 20) {
    return c.json({ error: "missing or malformed ckWebAuthToken" }, 400);
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
