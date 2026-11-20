import type { Context } from "hono";
import type { Env } from "../env.js";
import { fetchUserRecordName } from "../cloudkit.js";
import { putUserCkToken } from "../storage.js";
import { logEvent } from "../util.js";

// POST /ingest/ck-token
//
// The iOS/macOS app mints a fresh ckWebAuthToken via
// CKContainer.fetchWebAuthToken(withAPIToken:) — using its durable native
// iCloud session, so no browser/idmsa round-trip — and pushes it here on
// a schedule (foreground, background refresh, near-expiry nudge).
//
// Self-securing: the only auth is the token itself. We resolve the
// CloudKit user it belongs to via `users/current`; an invalid or expired
// token yields no user and is rejected. A valid token both proves
// identity AND is the thing we store, keyed by that user. No separate
// shared secret to leak.
//
// IMPORTANT: the app must mint with the SAME CloudKit API token the
// gateway uses for its REST calls (env.CK_API_TOKEN) — a ckWebAuthToken
// is scoped to the API token it was minted with.
export async function ingestCkToken(c: Context<{ Bindings: Env }>) {
  const body = (await c.req.json().catch(() => null)) as
    | { ckWebAuthToken?: string }
    | null;
  const token = body?.ckWebAuthToken?.trim();
  if (!token) return c.json({ error: "missing ckWebAuthToken" }, 400);

  const userRecordName = await fetchUserRecordName(c.env, token);
  if (!userRecordName) {
    // Don't echo the token or any user identifier — terse by design.
    logEvent("ingest_ck_token", { ok: false, reason: "invalid_token" });
    return c.json({ error: "invalid_token" }, 401);
  }

  await putUserCkToken(c.env, userRecordName, token);
  logEvent("ingest_ck_token", { ok: true });
  return c.json({ ok: true });
}
