import type { Env } from "../env.js";
import type { JwsRenewalInfo, JwsTransaction, NotificationV2 } from "./appleJws.js";
import type { EntitlementRow, EntitlementStatus, PaidPlanId } from "./entitlement.js";
import { PLAN_PRODUCT_PLANS } from "../generated/registries.js";

// App Store transaction / notification → entitlement row.

/// Only the sync subscriptions grant sync (spec §4). Plus sells as
/// com.septena.tasks.sync.monthly / .annual, Pro as
/// com.septena.tasks.sync.pro.monthly / .annual (ADR 0059), all in one
/// subscription group. Any later product on the same record needs its own
/// decision before it counts.
export const SYNC_PRODUCT_PREFIX = "com.septena.tasks.sync.";

/// The plan a store product gives, from registry/plans.json; null for a
/// product the registry does not list.
export function planForProduct(productId: string): PaidPlanId | null {
  return (PLAN_PRODUCT_PLANS as Record<string, PaidPlanId>)[productId] ?? null;
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

function statusFromTransaction(tx: JwsTransaction, now: number): EntitlementStatus {
  if (tx.expiresDate === undefined) return "active";
  return tx.expiresDate > now ? "active" : "expired";
}

export function appleRow(
  tx: JwsTransaction,
  opts: { renewal?: JwsRenewalInfo; notification?: NotificationV2; now?: number },
): Omit<EntitlementRow, "updatedAt"> {
  const now = opts.now ?? Date.now();
  let status: EntitlementStatus =
    tx.revocationDate !== undefined
      ? "revoked"
      : (opts.notification && statusFromNotification(opts.notification)) ?? statusFromTransaction(tx, now);
  // A purchase the app posts during grace still shows its old expiresDate;
  // the renewal info (when present) says it is in grace.
  if (status === "expired" && opts.renewal?.gracePeriodExpiresDate && opts.renewal.gracePeriodExpiresDate > now) status = "grace";
  if (status === "expired" && opts.renewal?.isInBillingRetryPeriod) status = "billing_retry";
  const expiresAt = status === "grace"
    ? opts.renewal?.gracePeriodExpiresDate ?? tx.expiresDate ?? null
    : tx.expiresDate ?? null;
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
