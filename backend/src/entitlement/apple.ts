import type { Env } from "../env.js";
import type { JwsRenewalInfo, JwsTransaction, NotificationV2 } from "./appleJws.js";
import type { EntitlementRow, EntitlementStatus, PaidPlanId } from "./entitlement.js";
import { PLAN_PASS_PRODUCTS, PLAN_PRODUCT_PLANS } from "../generated/registries.js";

// App Store transaction / notification → entitlement row.

/// Only the sync products grant sync (spec §4). Plus sells as
/// com.septena.tasks.sync.monthly / .annual plus the 7-Year Pass
/// com.septena.tasks.sync.plus.7year (ADR 0061), and Pro as
/// com.septena.tasks.sync.pro.monthly / .annual (ADR 0059). Any later product
/// on the same record needs its own decision before it counts.
export const SYNC_PRODUCT_PREFIX = "com.septena.tasks.sync.";

/// The plan a store product gives, from registry/plans.json; null for a
/// product the registry does not list.
export function planForProduct(productId: string): PaidPlanId | null {
  return (PLAN_PRODUCT_PLANS as Record<string, PaidPlanId>)[productId] ?? null;
}

/// Fixed-duration non-renewing pass metadata for a product, or null for
/// auto-renewing subscriptions (ADR 0061).
export function passForProduct(productId: string): { plan: PaidPlanId; years: number } | null {
  return (PLAN_PASS_PRODUCTS as Record<string, { plan: PaidPlanId; years: number }>)[productId] ?? null;
}

/// Adds whole calendar years in UTC so a 7-year pass ends on the same date
/// seven years later.
function addCalendarYears(ms: number, years: number): number {
  const d = new Date(ms);
  d.setUTCFullYear(d.getUTCFullYear() + years);
  return d.getTime();
}

const list = (v: string | undefined) => (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);

/// Why a verified transaction does not count, or null when it does.
export function rejectReason(env: Env, tx: Pick<JwsTransaction, "bundleId" | "environment" | "productId">): string | null {
  if (!list(env.APPLE_IAP_BUNDLE_IDS).includes(tx.bundleId)) return "bundle_not_allowed";
  if (!list(env.APPLE_IAP_ENVIRONMENTS).includes(tx.environment)) return "environment_not_allowed";
  if (!tx.productId.startsWith(SYNC_PRODUCT_PREFIX) || planForProduct(tx.productId) === null) return "product_not_sync";
  return null;
}

/// Notification V2 `data.status`.
const STATUS_CODES: Record<number, EntitlementStatus> = {
  1: "active",
  2: "expired",
  3: "billing_retry",
  4: "grace",
  5: "revoked",
};

function statusFromNotification(n: NotificationV2): EntitlementStatus | null {
  const code = n.data?.status;
  if (code !== undefined && STATUS_CODES[code]) return STATUS_CODES[code];
  switch (n.notificationType) {
    case "REFUND":
    case "REVOKE":
      return "revoked";
    case "EXPIRED":
      return "expired";
    case "GRACE_PERIOD_EXPIRED":
      return "billing_retry";
    case "DID_FAIL_TO_RENEW":
      return n.subtype === "GRACE_PERIOD" ? "grace" : "billing_retry";
    default:
      return null;
  }
}

function resolvedExpiresDate(
  tx: JwsTransaction,
  opts: { existingExpiresAt?: number | null; stackFrom?: number },
): number | undefined {
  if (tx.expiresDate !== undefined) return tx.expiresDate;
  const pass = passForProduct(tx.productId);
  if (!pass) return undefined;
  if (opts.existingExpiresAt !== undefined && opts.existingExpiresAt !== null) return opts.existingExpiresAt;
  const base = Math.max(tx.purchaseDate ?? tx.signedDate, opts.stackFrom ?? 0);
  return addCalendarYears(base, pass.years);
}

function statusFromTransaction(expiresDate: number | undefined, now: number): EntitlementStatus {
  if (expiresDate === undefined) return "active";
  return expiresDate > now ? "active" : "expired";
}

export function appleRow(
  tx: JwsTransaction,
  opts: { renewal?: JwsRenewalInfo; notification?: NotificationV2; now?: number; existingExpiresAt?: number | null; stackFrom?: number },
): Omit<EntitlementRow, "updatedAt"> {
  const now = opts.now ?? Date.now();
  const computedExpiresDate = resolvedExpiresDate(tx, opts);
  let status: EntitlementStatus =
    tx.revocationDate !== undefined
      ? "revoked"
      : (opts.notification && statusFromNotification(opts.notification)) ?? statusFromTransaction(computedExpiresDate, now);
  // A purchase the app posts during grace still shows its old expiresDate;
  // the renewal info (when present) says it is in grace.
  if (status === "expired" && opts.renewal?.gracePeriodExpiresDate && opts.renewal.gracePeriodExpiresDate > now) status = "grace";
  if (status === "expired" && opts.renewal?.isInBillingRetryPeriod) status = "billing_retry";
  const expiresAt = status === "grace"
    ? opts.renewal?.gracePeriodExpiresDate ?? computedExpiresDate ?? null
    : computedExpiresDate ?? null;
  return {
    id: `apple:${tx.originalTransactionId}`,
    source: "apple",
    productId: tx.productId,
    // Pro products give Pro; Plus rows keep null, which reads as Plus.
    plan: planForProduct(tx.productId) === "pro" ? "pro" : null,
    expiresAt,
    originalTransactionId: tx.originalTransactionId,
    status,
    environment: tx.environment,
    note: opts.notification ? `${opts.notification.notificationType}${opts.notification.subtype ? `/${opts.notification.subtype}` : ""}` : "app",
    signedAt: opts.notification?.signedDate ?? tx.signedDate,
  };
}
