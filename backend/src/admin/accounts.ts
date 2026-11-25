import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { isRowActive, type PaidPlanId } from "../entitlement/entitlement.js";
import { storeFor } from "../api/session.js";
import { accountStoreFor, type AccountIndexRow } from "../store/AccountStore.js";
import type { AccountSummary } from "../store/TaskStore.js";

// The account index behind the admin page (ADR 0043). Each account is its own
// Durable Object, so the page never opens them all: an hourly cron refreshes
// the summaries that are older than REFRESH_AFTER_MS.

export const REFRESH_AFTER_MS = 20 * 60 * 60 * 1000;
export const SWEEP_LIMIT = 400;
const PARALLEL = 20;

/// Accounts that last signed in before the identity table existed (#168): the
/// trial marker and the purchase-token index both name them.
async function knownUserIds(env: Env): Promise<string[]> {
  const ids = new Set<string>();
  for (const prefix of ["trial-used:", "ent-aat:"]) {
    let cursor: string | undefined;
    do {
      const page = await env.TOKENS.list({ prefix, cursor });
      for (const { name } of page.keys) {
        const id = prefix === "trial-used:" ? name.slice(prefix.length) : await env.TOKENS.get(name);
        if (id) ids.add(id);
      }
      cursor = page.list_complete ? undefined : page.cursor;
    } while (cursor);
  }
  return [...ids];
}

export async function refreshAccounts(env: Env, userIds: string[]): Promise<void> {
  const accounts = accountStoreFor(env);
  if (!accounts) return;
  for (let i = 0; i < userIds.length; i += PARALLEL) {
    const batch = userIds.slice(i, i + PARALLEL);
    const results = await Promise.allSettled(batch.map((id) => storeFor(env, id).accountSummary()));
    const rows: { userId: string; summary: AccountSummary | null }[] = [];
    results.forEach((r, n) => {
      if (r.status === "fulfilled") rows.push({ userId: batch[n], summary: r.value as AccountSummary | null });
      else logEvent("account_summary_failed", { userId: batch[n], error: String(r.reason) });
    });
    await accounts.saveSummaries(rows);
  }
}

/// Refreshes the stalest summaries. Returns how many accounts it read.
export async function sweepAccounts(env: Env, olderThanMs = REFRESH_AFTER_MS, now = Date.now()): Promise<number> {
  const accounts = accountStoreFor(env);
  if (!accounts) return 0;
  if (await accounts.needsSeed()) await accounts.seedAccounts(await knownUserIds(env));
  const ids = await accounts.accountsToRefresh(now - olderThanMs, SWEEP_LIMIT);
  await refreshAccounts(env, ids);
  logEvent("account_sweep", { accounts: ids.length });
  return ids.length;
}

// ---- what the page says about an account ----

/// The grant row the admin page writes: one per account.
export const ADMIN_GRANT_ID = "grant:admin";

export type PlanWord = "paid" | "granted" | "trial" | "lapsed" | "trial over" | "free";

const PAID = new Set(["apple", "stripe", "google"]);

/// A purchase that counts as a customer: sandbox purchases are tests.
const isCustomerRow = (e: AccountSummary["entitlements"][number]) =>
  PAID.has(e.source) && (e.environment === null || e.environment === "Production");

export interface PlanView {
  word: PlanWord;
  /// The plan the account is on now; null on the free account.
  plan: PaidPlanId | null;
  /// mz gave this account a plan on the admin page.
  adminGrant: boolean;
  /// When the active row ends; null = no end or nothing active.
  until: number | null;
  period: "year" | "month" | null;
  hadTrial: boolean;
  customer: boolean;
}

export function planView(summary: AccountSummary | null, now = Date.now()): PlanView {
  const rows = summary?.entitlements ?? [];
  const active = rows.filter((r) => isRowActive({ ...r, originalTransactionId: null, note: null, updatedAt: r.signedAt }, now));
  const pick = (test: (r: (typeof rows)[number]) => boolean) => active.filter(test);
  const paid = pick((r) => PAID.has(r.source));
  const granted = pick((r) => r.source === "grant");
  const trial = pick((r) => r.source === "trial");
  const pro = pick((r) => r.plan === "pro");
  const best = pro.length ? pro : paid.length ? paid : granted.length ? granted : trial;
  const customer = rows.some(isCustomerRow);
  const hadTrial = rows.some((r) => r.source === "trial");
  const word: PlanWord = paid.length ? "paid" : granted.length ? "granted" : trial.length ? "trial"
    : customer ? "lapsed" : hadTrial ? "trial over" : "free";
  const product = paid[0]?.productId ?? "";
  return {
    word,
    plan: pro.length ? "pro" : active.length ? "plus" : null,
    adminGrant: rows.some((r) => r.id === ADMIN_GRANT_ID),
    until: best.length && best.every((r) => r.expiresAt !== null) ? Math.max(...best.map((r) => r.expiresAt!)) : null,
    period: /annual|year/.test(product) ? "year" : /month/.test(product) ? "month" : null,
    hadTrial,
    customer,
  };
}

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;

/// The funnel counts of docs/SYNC_SUBSCRIPTION_SPEC.md §3.3, from server data.
export function overview(rows: AccountIndexRow[], now = Date.now()) {
  const plans = rows.map((r) => planView(r.summary, now));
  const count = (test: (r: AccountIndexRow) => boolean) => rows.filter(test).length;
  const plan = (word: PlanWord) => plans.filter((p) => p.word === word).length;
  const seen = (r: AccountIndexRow) => lastSeen(r.summary);
  return {
    accounts: rows.length,
    newThisWeek: count((r) => now - r.createdAt < WEEK_MS),
    activeThisWeek: count((r) => now - (seen(r) ?? 0) < WEEK_MS),
    twoDevices: count((r) => (r.summary?.devices.length ?? 0) >= 2),
    withAgent: count((r) => (r.summary?.agents.length ?? 0) > 0),
    agentChangesWeek: rows.reduce((n, r) => n + (r.summary?.agentChangesWeek ?? 0), 0),
    trialsStarted: plans.filter((p) => p.hadTrial).length,
    trialsConverted: plans.filter((p) => p.hadTrial && p.customer).length,
    onTrial: plan("trial"),
    paid: plan("paid"),
    paidYear: plans.filter((p) => p.word === "paid" && p.period === "year").length,
    paidMonth: plans.filter((p) => p.word === "paid" && p.period === "month").length,
    granted: plan("granted"),
    pro: plans.filter((p) => p.plan === "pro").length,
    lapsed: plan("lapsed"),
    openTasks: rows.reduce((n, r) => n + (r.summary?.openTasks ?? 0), 0),
    closedTasks: rows.reduce((n, r) => n + (r.summary?.closedTasks ?? 0), 0),
    files: rows.reduce((n, r) => n + (r.summary?.files ?? 0), 0),
    fileBytes: rows.reduce((n, r) => n + (r.summary?.fileBytes ?? 0), 0),
  };
}

/// The last time a device or an agent of the account reached the server.
export function lastSeen(summary: AccountSummary | null): number | null {
  const times = [...(summary?.devices ?? []).map((d) => d.lastSeen), ...(summary?.agents ?? []).map((a) => a.lastUsed)];
  return times.length ? Math.max(...times) : null;
}

/// "septask-ios" with its version header; Android puts the version in the name.
export function deviceLabel(d: { client: string | null; version: string | null }): string {
  const client = d.client ?? "unknown";
  const name = client === "septask-ios" ? "iPhone or iPad" : client === "septask-mac" ? "Mac" : client === "septask-watch" ? "Watch"
    : client.replace(/^android\b/, "Android");
  return d.version ? `${name} ${d.version}` : name;
}
