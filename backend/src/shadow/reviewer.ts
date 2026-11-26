import type { Env } from "../env.js";
import { USER_ID_RE } from "../store/AccountStore.js";
import { storeFor, issueSession } from "../api/session.js";
import { grantRow } from "../entitlement/entitlement.js";
import { logEvent, randomId } from "../util.js";
import { MCP_GRANT_SCOPE, issueMcpTokens, type McpTokenResponse } from "./tokens.js";

// Directory reviewer access (ADR 0055, septena#85).
//
// Claude's and ChatGPT's directory reviewers must connect the connector with
// no Septena app and without mz. The pairing page offers a demo account, but
// only when reviewer mode is configured, and only after the reviewer types the
// reviewer code from the submission notes. An ordinary connection never lands
// in the demo account: without the code, the page pairs as before.
//
// Reviewer mode is on when REVIEWER_CODE and REVIEWER_ACCOUNT_ID are both set
// and REVIEWER_MODE_UNTIL (optional, ISO date or date-time) has not passed.
// Any missing or malformed value turns it off. Delete the REVIEWER_CODE secret
// to turn it off for good.

/// Wrong reviewer codes allowed per IP in one pairing window (same window as the pairing codes).
export const REVIEWER_MAX_FAILURES = 5;
/// The client id the seed script's own connection uses (backend/scripts/reviewer-seed.mjs).
export const REVIEWER_SEED_CLIENT_ID = "septena-reviewer-seed";

/// The demo account while reviewer mode is on, else null. Fails closed.
export function reviewerMode(env: Env, now = Date.now()): { userId: string } | null {
  const code = env.REVIEWER_CODE?.trim();
  const userId = env.REVIEWER_ACCOUNT_ID?.trim();
  if (!code || code.length < 12 || !userId || !USER_ID_RE.test(userId)) return null;
  const until = env.REVIEWER_MODE_UNTIL?.trim();
  if (until) {
    const end = Date.parse(/^\d{4}-\d{2}-\d{2}$/.test(until) ? `${until}T23:59:59Z` : until);
    if (!Number.isFinite(end) || now > end) return null;
  }
  return { userId };
}

/// Compares two strings without an early exit: equal-length digests, every byte read.
export async function sameSecret(given: string, expected: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(given)),
    crypto.subtle.digest("SHA-256", enc.encode(expected)),
  ]);
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

/// True when `given` is the reviewer code and reviewer mode is on.
export async function reviewerCodeMatches(env: Env, given: string): Promise<boolean> {
  if (!reviewerMode(env)) return false;
  return sameSecret(given.trim(), env.REVIEWER_CODE!.trim());
}

/// Ensures the demo account has an app session (device poll and connector
/// token exchange both require one) and a Pro grant while reviewer mode is on.
/// Returns the demo account id, or null when reviewer mode is off.
export async function ensureReviewerAccount(env: Env): Promise<{ userId: string } | null> {
  const mode = reviewerMode(env);
  if (!mode) return null;
  const store = storeFor(env, mode.userId);
  if (!(await store.hasAppSession())) await issueSession(env, mode.userId);
  await store.putEntitlement(
    grantRow("grant:reviewer", "pro", null, "Directory reviewer demo account (ADR 0055)"),
    "admin",
  );
  return mode;
}

/// Prepares the demo account for the seed script: an app session (the token
/// exchange refuses an account without one), a Pro grant (reviewers from two
/// directories connect two agents), and a short-lived connector token for the
/// script, which revokes it when it is done. Only ever the demo account.
export async function prepareReviewerAccount(env: Env): Promise<McpTokenResponse | null> {
  const mode = await ensureReviewerAccount(env);
  if (!mode) return null;
  const tokens = await issueMcpTokens(env, {
    userId: mode.userId,
    clientId: REVIEWER_SEED_CLIENT_ID,
    scope: MCP_GRANT_SCOPE,
    label: "Sample data",
  }, randomId(16));
  logEvent("reviewer_seed_session", { ok: true });
  return tokens;
}
