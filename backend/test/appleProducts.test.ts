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
    assert.equal(planForProduct("com.septena.tasks.sync.pro.annual"), "pro");
    assert.equal(planForProduct("com.septena.tasks.sync.pro.monthly"), "pro");
    assert.equal(planForProduct("com.septena.tasks.sync.lifetime"), null);
  });

  it("accepts the registry products and refuses others", () => {
    assert.equal(rejectReason(env, tx("com.septena.tasks.sync.pro.annual")), null);
    assert.equal(rejectReason(env, tx("com.septena.tasks.sync.annual")), null);
    assert.equal(rejectReason(env, tx("com.septena.tasks.sync.lifetime")), "product_not_sync");
    assert.equal(rejectReason(env, tx("com.septena.cloud.support.annual")), "product_not_sync");
  });

  it("puts a Pro purchase on Pro and a Plus purchase on Plus", () => {
    assert.equal(row("com.septena.tasks.sync.pro.monthly").plan, "pro");
    assert.equal(row("com.septena.tasks.sync.annual").plan, null);
    assert.equal(resolvePlan([row("com.septena.tasks.sync.pro.monthly")], now), "pro");
    assert.equal(resolvePlan([row("com.septena.tasks.sync.annual")], now), "plus");
  });
});
