import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { storeFor } from "../api/session.js";
import { PLAN_LIMITS, PLAN_UPSELLS } from "../generated/registries.js";

// Plan and entitlement (docs/SYNC_SUBSCRIPTION_SPEC.md §5–§6, ADR 0010,
// ADR 0023).
//
// Rows live in the user's TaskStore Durable Object (`entitlements` table).
// One row per source of access: `apple:<originalTransactionId>` for an App
// Store subscription, `grant:<name>` for a hand-made grant (mz, testers,
// press). The user is on Plus when ANY row is active, else on the free
// account.
//
// `resolvePlan` turns the rows into a plan id, and `PLAN_TABLE` maps the plan
// to its limits (registry/plans.json `limits`, generated to PLAN_LIMITS).
// Gates read limits, never the plan name: a later tier is a new row in the
// table, not a code change at the gates. Every limited call goes through
// `decide`. `ENTITLEMENT_ENFORCE` decides what a "no" does: "true" blocks
// (402 / tool error); anything else only logs `entitlement_would_block` and
// lets the call through.

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

// ---- plans and limits ----

/// The plans the server knows. `trial` (the 14-day reverse trial, spec §3)
/// is not built yet; it will resolve to the Plus limits.
export type PlanId = "free" | "plus";

export interface PlanLimits {
  /// Devices that sync to the server; null = no cap.
  devices: number | null;
  /// The live socket (`/v1/sync/ws`). Without it the app polls.
  liveSync: boolean;
  /// Change history the reads show (`/v1/changes`, tasks_history,
  /// tasks_activity). null = everything the store keeps.
  changeLogDays: number | null;
  /// Logbook window. Read by the apps; the server has no Logbook read.
  logbookDays: number | null;
  /// Recently Deleted window. Read by the apps; the server has no Recently
  /// Deleted read.
  recentlyDeletedDays: number | null;
  /// Server attachment storage (R2). 0 = attachments stay on the device.
  attachmentsGB: number | null;
  /// Connector write calls per UTC day; null = no cap.
  connectorWritesPerDay: number | null;
  /// New agent claims per UTC month; null = no cap (the per-task run budget
  /// of ADR 0008 still applies).
  agentRunsPerMonth: number | null;
  createShares: boolean;
  linkedProjects: number | null;
}

/// The plan table. Values come only from registry/plans.json.
export const PLAN_TABLE: Record<PlanId, PlanLimits> = {
  free: PLAN_LIMITS.account,
  plus: PLAN_LIMITS.plus,
};

export function resolvePlan(rows: EntitlementRow[], now = Date.now()): PlanId {
  return rows.some((r) => isRowActive(r, now)) ? "plus" : "free";
}

export interface PlanState {
  plan: PlanId;
  limits: PlanLimits;
  rows: EntitlementRow[];
  /// Usage counters asked for in `planFor` (key → count).
  usage: Record<string, number>;
}

/// The caller's plan, with the usage counters a gate needs, in one call to
/// the user's Durable Object.
export async function planFor(env: Env, userId: string, usageKeys: string[] = []): Promise<PlanState> {
  const snap = await storeFor(env, userId).planSnapshot(usageKeys);
  const plan = resolvePlan(snap.entitlements);
  return { plan, limits: PLAN_TABLE[plan], rows: snap.entitlements, usage: snap.usage };
}

export type UpsellId = keyof typeof PLAN_UPSELLS;

/// A call that breaks one limit, and the upsell moment it maps to (spec
/// §3.2). null: no upsell (the app falls back quietly, e.g. live sync → poll).
export interface LimitBreach {
  limit: keyof PlanLimits;
  upsell: UpsellId | null;
}

/// The upsell as one line, for a refusal the user or the model reads.
export function upsellLine(id: UpsellId): string {
  const u = PLAN_UPSELLS[id];
  return `${u.title}. ${u.detail}`;
}

/// "allow" or "block" for one limited call. Logs every breach. In log-only
/// mode (ENTITLEMENT_ENFORCE != "true") the answer is always "allow".
export function decide(env: Env, userId: string, surface: string, state: PlanState, breach: LimitBreach | null): "allow" | "block" {
  if (!breach) return "allow";
  const enforce = isEnforcing(env);
  logEvent(enforce ? "entitlement_blocked" : "entitlement_would_block", {
    surface, userId, plan: state.plan, limit: breach.limit,
  });
  return enforce ? "block" : "allow";
}

/// A failed plan check. Log-only mode lets the call through with no limits;
/// enforce mode blocks (fail closed).
export function planCheckFailed(env: Env, userId: string, surface: string, e: unknown): "allow" | "block" {
  const enforce = isEnforcing(env);
  logEvent("entitlement_check_failed", { surface, userId, enforce, error: e instanceof Error ? e.message : String(e) });
  return enforce ? "block" : "allow";
}

/// Counter keys. Days and months are UTC.
export const usageKeys = {
  connectorWrites: (now = new Date()) => `cw:${now.toISOString().slice(0, 10)}`,
  agentRuns: (now = new Date()) => `ar:${now.toISOString().slice(0, 7)}`,
};

/// A count against a cap: over when the next call would pass the cap.
export function atCap(used: number, cap: number | null): boolean {
  return cap !== null && used >= cap;
}

const DAY_MS = 24 * HOUR_MS;

/// The oldest change a read may show, or null for no window. Applied only
/// when enforcing, so log-only mode reads exactly as before.
export function historyCutoff(env: Env, limits: PlanLimits | null, now = Date.now()): string | null {
  if (!limits || limits.changeLogDays === null || !isEnforcing(env)) return null;
  return new Date(now - limits.changeLogDays * DAY_MS).toISOString();
}

export function attachmentQuotaBytes(limits: PlanLimits): number | null {
  return limits.attachmentsGB === null ? null : limits.attachmentsGB * 1024 ** 3;
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
