import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { installWorkerTestHooks } from "./taskStoreHarness.ts";
import type { EntitlementRow } from "../src/entitlement/entitlement.ts";
import type { Env } from "../src/env.ts";
import type { JwsTransaction } from "../src/entitlement/appleJws.ts";

installWorkerTestHooks();

// ADR 0059: the Plus and Pro store products, one subscription group.

const { appleRow, planForProduct, rejectReason } = await import("../src/entitlement/apple.ts");
const { resolvePlan } = await import("../src/entitlement/entitlement.ts");

const env = { APPLE_IAP_BUNDLE_IDS: "app.septena.tasks", APPLE_IAP_ENVIRONMENTS: "Production,Sandbox" } as unknown as Env;
const now = Date.UTC(2026, 10, 26);

function tx(productId: string): JwsTransaction {
  return {
    productId, bundleId: "app.septena.tasks", environment: "Sandbox",
    originalTransactionId: "1000", transactionId: "1000",
    expiresDate: now + 30 * 86_400_000, signedDate: now,
  } as unknown as JwsTransaction;
}

const row = (productId: string): EntitlementRow => ({ ...appleRow(tx(productId), { now }), updatedAt: now });

describe("App Store products and plans", () => {
  it("maps each registry product to its plan", () => {
    assert.equal(planForProduct("com.septena.tasks.sync.annual"), "plus");
    assert.equal(planForProduct("com.septena.tasks.sync.monthly"), "plus");
    assert.equal(planForProduct("com.septena.tasks.sync.plus.7year"), "plus");
    assert.equal(planForProduct("com.septena.tasks.sync.pro.annual"), "pro");
    assert.equal(planForProduct("com.septena.tasks.sync.pro.monthly"), "pro");
    assert.equal(planForProduct("com.septena.tasks.sync.lifetime"), null);
  });

  it("accepts the registry products and refuses others", () => {
    assert.equal(rejectReason(env, tx("com.septena.tasks.sync.pro.annual")), null);
    assert.equal(rejectReason(env, tx("com.septena.tasks.sync.annual")), null);
    assert.equal(rejectReason(env, tx("com.septena.tasks.sync.plus.7year")), null);
    assert.equal(rejectReason(env, tx("com.septena.tasks.sync.lifetime")), "product_not_sync");
    assert.equal(rejectReason(env, tx("com.septena.cloud.support.annual")), "product_not_sync");
  });

  it("puts a Pro purchase on Pro and a Plus purchase on Plus", () => {
    assert.equal(row("com.septena.tasks.sync.pro.monthly").plan, "pro");
    assert.equal(row("com.septena.tasks.sync.annual").plan, null);
    assert.equal(resolvePlan([row("com.septena.tasks.sync.pro.monthly")], now), "pro");
    assert.equal(resolvePlan([row("com.septena.tasks.sync.annual")], now), "plus");
  });

  it("computes a 7-year expiry for the non-renewing Plus pass when Apple omits expiresDate (ADR 0061)", () => {
    const passTx = {
      productId: "com.septena.tasks.sync.plus.7year",
      bundleId: "app.septena.tasks",
      environment: "Sandbox",
      originalTransactionId: "2000",
      transactionId: "2000",
      purchaseDate: now,
      signedDate: now,
    } as unknown as JwsTransaction;
    const expectedEnd = Date.UTC(2033, 10, 26);
    const passRow: EntitlementRow = { ...appleRow(passTx, { now }), updatedAt: now };
    assert.equal(passRow.plan, null);
    assert.equal(passRow.status, "active");
    assert.equal(passRow.expiresAt, expectedEnd);
    assert.equal(resolvePlan([passRow], now), "plus");
    // Expired past 7 years + 24h renewal leeway.
    assert.equal(resolvePlan([passRow], expectedEnd + 25 * 3_600_000), "free");

    // Stacking an early renewal extends from the current pass expiry.
    const stacked: EntitlementRow = {
      ...appleRow({ ...passTx, originalTransactionId: "2001", transactionId: "2001" } as unknown as JwsTransaction, { now, stackFrom: expectedEnd }),
      updatedAt: now,
    };
    assert.equal(stacked.expiresAt, Date.UTC(2040, 10, 26));

    // A Pro subscription on top wins while active, then falls back to the 7-Year Plus Pass.
    const proRow = row("com.septena.tasks.sync.pro.monthly");
    assert.equal(resolvePlan([passRow, proRow], now), "pro");
    assert.equal(resolvePlan([passRow, proRow], now + 60 * 86_400_000), "plus");
  });
});
