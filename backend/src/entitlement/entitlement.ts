import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { storeFor } from "../api/session.js";

// Sync subscription entitlement (docs/SYNC_SUBSCRIPTION_SPEC.md §5–§6).
//
// Rows live in the user's TaskStore Durable Object (`entitlements` table).
// One row per source of access: `apple:<originalTransactionId>` for an App
// Store subscription, `grant:<name>` for a hand-made grant (mz, testers,
// press). The user has sync when ANY row is active.
//
// `hasSyncEntitlement` is the one check. Every paid path calls it through
// `entitlementGate`: the /v1 sync middleware and the api.septena.app
// connector's write tools. `ENTITLEMENT_ENFORCE` decides what a "no" does:
// "true" blocks (402 / tool error); anything else only logs
// `entitlement_would_block` and lets the call through.

export type EntitlementSource = "apple" | "grant" | "stripe";
export type EntitlementStatus = "active" | "grace" | "billing_retry" | "expired" | "revoked";

export interface EntitlementRow {
  id: string;
  source: EntitlementSource;
  productId: string | null;
  /// ms epoch; null = no expiry (grants only). For `grace`, the end of the
  /// grace period; otherwise the subscription's expiresDate.
  expiresAt: number | null;
  originalTransactionId: string | null;
  status: EntitlementStatus;
  /// Apple environment (Production / Sandbox); null for grants.
  environment: string | null;
  note: string | null;
  /// Apple's signedDate of the payload this row came from (ms). An older
  /// payload never overwrites a newer one: notifications arrive out of order.
  signedAt: number;
  updatedAt: number;
}

const HOUR_MS = 60 * 60 * 1000;
/// An `active` subscription stays active this long past expiresAt, so a
/// renewal notification that arrives late does not cut sync off.
export const RENEWAL_LEEWAY_MS = 24 * HOUR_MS;
/// Apple retries billing for up to 60 days. A `billing_retry` row counts as
/// active (spec §6) until Apple's EXPIRED notification, capped here in case
/// that notification never arrives.
export const BILLING_RETRY_MAX_MS = 60 * 24 * HOUR_MS;

export function isRowActive(row: EntitlementRow, now = Date.now()): boolean {
  switch (row.status) {
    case "active":
      if (row.expiresAt === null) return true;
      return now < row.expiresAt + (row.source === "grant" ? 0 : RENEWAL_LEEWAY_MS);
    case "grace":
      return row.expiresAt === null || now < row.expiresAt + RENEWAL_LEEWAY_MS;
    case "billing_retry":
      return row.expiresAt === null || now < row.expiresAt + BILLING_RETRY_MAX_MS;
    default:
      return false;
  }
}

export function isEnforcing(env: Env): boolean {
  return env.ENTITLEMENT_ENFORCE === "true";
}

export async function hasSyncEntitlement(env: Env, userId: string): Promise<boolean> {
  const rows = await storeFor(env, userId).entitlements();
  const now = Date.now();
  return rows.some((r) => isRowActive(r, now));
}

/// "allow" or "block" for one paid call. Logs every "no". In log-only mode
/// (ENTITLEMENT_ENFORCE != "true") the answer is always "allow", and a failed
/// check never breaks sync. In enforce mode a failed check blocks (fail
/// closed).
export async function entitlementGate(env: Env, userId: string, surface: string): Promise<"allow" | "block"> {
  const enforce = isEnforcing(env);
  let ok: boolean;
  try {
    ok = await hasSyncEntitlement(env, userId);
  } catch (e) {
    logEvent("entitlement_check_failed", { surface, userId, enforce, error: e instanceof Error ? e.message : String(e) });
    return enforce ? "block" : "allow";
  }
  if (ok) return "allow";
  logEvent(enforce ? "entitlement_blocked" : "entitlement_would_block", { surface, userId });
  return enforce ? "block" : "allow";
}

// ---- appAccountToken ----

/// Fixed UUIDv5 namespace for Septena backend user ids. Never change it: every
/// purchase made so far carries a token derived from it.
const APP_ACCOUNT_NAMESPACE = "b85c7060-77c8-4ea3-b8b4-fdee891cc9ef";

/// The `appAccountToken` the app passes to `Product.purchase`: UUIDv5 of the
/// backend user id (`u_…`) in APP_ACCOUNT_NAMESPACE, lowercase. StoreKit needs
/// a UUID and our user id is not one; v5 is deterministic, so the app can ask
/// the server (`GET /v1/entitlement`) or compute it, and both agree.
export async function appAccountTokenFor(userId: string): Promise<string> {
  const ns = Uint8Array.from(APP_ACCOUNT_NAMESPACE.replace(/-/g, "").match(/../g)!.map((h) => parseInt(h, 16)));
  const name = new TextEncoder().encode(userId);
  const input = new Uint8Array(ns.length + name.length);
  input.set(ns);
  input.set(name, ns.length);
  const b = new Uint8Array(await crypto.subtle.digest("SHA-1", input)).slice(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// ---- KV indexes (TOKENS namespace) ----
// A webhook names a transaction, not a user. These map it back.

const otxKey = (originalTransactionId: string) => `ent-otx:${originalTransactionId}`;
const aatKey = (appAccountToken: string) => `ent-aat:${appAccountToken.toLowerCase()}`;

export async function rememberAppAccountToken(env: Env, userId: string, token: string): Promise<void> {
  if ((await env.TOKENS.get(aatKey(token))) !== userId) await env.TOKENS.put(aatKey(token), userId);
}

export async function rememberOriginalTransaction(env: Env, userId: string, originalTransactionId: string): Promise<void> {
  if ((await env.TOKENS.get(otxKey(originalTransactionId))) !== userId) {
    await env.TOKENS.put(otxKey(originalTransactionId), userId);
  }
}

/// The user a notification is about: by originalTransactionId (recorded when
/// the app posted the purchase), else by appAccountToken (recorded whenever
/// the app read its token).
export async function userForTransaction(
  env: Env,
  originalTransactionId: string,
  appAccountToken: string | undefined,
): Promise<string | null> {
  const byOtx = await env.TOKENS.get(otxKey(originalTransactionId));
  if (byOtx) return byOtx;
  if (appAccountToken) return env.TOKENS.get(aatKey(appAccountToken));
  return null;
}
