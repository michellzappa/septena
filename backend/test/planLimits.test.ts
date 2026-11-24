import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Plan table and free-account limits (docs/SYNC_SUBSCRIPTION_SPEC.md §3, §6,
// ADR 0010, ADR 0023).

const ent = await import("../src/entitlement/entitlement.ts");
const { PLAN_LIMITS } = await import("../src/generated/registries.ts");

const enforcing = { ENTITLEMENT_ENFORCE: "true" } as never;
const logOnly = { ENTITLEMENT_ENFORCE: "false" } as never;

function grant(over: Partial<Parameters<typeof ent.isRowActive>[0]> = {}) {
  return {
    id: "grant:mz", source: "grant" as const, productId: null, expiresAt: null, originalTransactionId: null,
    status: "active" as const, environment: null, note: null, signedAt: 0, updatedAt: 0, ...over,
  };
}

function session(store: Awaited<ReturnType<typeof createTestTaskStore>>["store"], name: string): string {
  const sid = `sid-${name}`;
  store.createSession(`hash-${name}`, Date.now() + 86_400_000, sid);
  return sid;
}

describe("plan table", () => {
  it("reads its values from registry/plans.json", () => {
    assert.deepEqual(ent.PLAN_TABLE.free, PLAN_LIMITS.account);
    assert.deepEqual(ent.PLAN_TABLE.plus, PLAN_LIMITS.plus);
    assert.equal(ent.PLAN_TABLE.free.devices, 1);
    assert.equal(ent.PLAN_TABLE.free.connectorWritesPerDay, 500);
    assert.equal(ent.PLAN_TABLE.free.connectedAgents, 1);
    assert.equal(ent.PLAN_TABLE.free.liveSync, true);
    assert.equal(ent.PLAN_TABLE.plus.connectedAgents, 3);
    assert.equal(ent.PLAN_TABLE.plus.devices, null);
  });

  it("resolves plus from any active row and free otherwise", () => {
    assert.equal(ent.resolvePlan([]), "free");
    assert.equal(ent.resolvePlan([grant()]), "plus");
    assert.equal(ent.resolvePlan([grant({ expiresAt: Date.now() - 1 })]), "free");
    assert.equal(ent.resolvePlan([grant({ status: "revoked" })]), "free");
  });

  it("blocks a breach only when enforcing", () => {
    const state = { plan: "free" as const, limits: ent.PLAN_TABLE.free, rows: [], usage: {} };
    const breach = { limit: "devices" as const, upsell: "second_device" as const };
    assert.equal(ent.decide(enforcing, "u_1", "t", state, breach), "block");
    assert.equal(ent.decide(logOnly, "u_1", "t", state, breach), "allow");
    assert.equal(ent.decide(enforcing, "u_1", "t", state, null), "allow");
    assert.equal(ent.planCheckFailed(logOnly, "u_1", "t", new Error("x")), "allow");
    assert.equal(ent.planCheckFailed(enforcing, "u_1", "t", new Error("x")), "block");
  });

  it("caps counts and windows from limits", () => {
    assert.equal(ent.atCap(24, 25), false);
    assert.equal(ent.atCap(25, 25), true);
    assert.equal(ent.atCap(10_000, null), false);
    assert.equal(ent.historyCutoff(logOnly, ent.PLAN_TABLE.free), null);
    const now = Date.parse("2026-11-22T00:00:00Z");
    assert.equal(ent.historyCutoff(enforcing, ent.PLAN_TABLE.free, now), "2026-10-23T00:00:00.000Z");
    assert.equal(ent.attachmentQuotaBytes(ent.PLAN_TABLE.free), 0);
    assert.equal(ent.attachmentQuotaBytes(ent.PLAN_TABLE.plus), 10 * 1024 ** 3);
    assert.equal(ent.usageKeys.connectorWrites(new Date("2026-11-22T23:59:00Z")), "cw:2026-11-22");
    assert.equal(ent.usageKeys.agentRuns(new Date("2026-11-22T23:59:00Z")), "ar:2026-11");
  });

  it("quotes the registry's upsell words", () => {
    assert.match(ent.upsellLine("connector_cap"), /500/);
  });
});

describe("device slot", () => {
  it("lets one device sync on a cap of 1, and moves the slot on claim", async () => {
    const { store } = await createTestTaskStore();
    const phone = session(store, "phone");
    const mac = session(store, "mac");
    assert.equal(store.deviceAccess(phone, "ios", 1).syncing, true, "first device takes the free slot");
    assert.equal(store.deviceAccess(mac, "mac", 1).syncing, false, "second device stays local");
    assert.equal(store.deviceAccess(phone, "ios", 1).syncing, true);
    store.claimDeviceSlot(mac, "mac");
    assert.equal(store.deviceAccess(mac, "mac", 1).syncing, true, "the claimed device syncs");
    assert.equal(store.deviceAccess(phone, "ios", 1).syncing, false, "the old device stops syncing");
    const summary = store.deviceSummary(1);
    assert.equal(summary.length, 2);
    assert.deepEqual(summary.filter((d) => d.syncing).map((d) => d.sid), [mac]);
  });

  it("frees the slot when the holder signs out", async () => {
    const { store } = await createTestTaskStore();
    const phone = session(store, "phone");
    const mac = session(store, "mac");
    store.deviceAccess(phone, null, 1);
    assert.equal(store.deviceAccess(mac, null, 1).syncing, false);
    store.revokeSession("hash-phone");
    assert.equal(store.deviceAccess(mac, null, 1).syncing, true);
  });

  it("syncs every device with no cap, then keeps the most recently used after a lapse", async () => {
    const { store } = await createTestTaskStore();
    const a = session(store, "a");
    const b = session(store, "b");
    const c = session(store, "c");
    for (const sid of [a, b, c, a, b]) assert.equal(store.deviceAccess(sid, null, null).syncing, true);
    assert.equal(store.deviceAccess(b, null, 1).syncing, true, "b synced last");
    assert.equal(store.deviceAccess(a, null, 1).syncing, false);
    assert.equal(store.deviceAccess(c, null, 1).syncing, false);
  });

  it("keeps the session id across refresh-token rotation", async () => {
    const { store, db } = await createTestTaskStore();
    const sid = session(store, "x");
    assert.equal(store.rotateSession("hash-x", "hash-x2", Date.now() + 86_400_000), sid);
    assert.equal(store.rotateSession("hash-x", "hash-x3", Date.now() + 86_400_000), null, "old token is single-use");
    db.prepare("INSERT INTO sessions (hash, createdAt, expiresAt) VALUES (?, ?, ?)").run("legacy", Date.now(), Date.now() + 86_400_000);
    const fresh = store.rotateSession("legacy", "legacy2", Date.now() + 86_400_000);
    assert.equal(typeof fresh, "string", "a session from before session ids gets one");
  });
});

describe("usage and history", () => {
  it("counts usage per key", async () => {
    const { store } = await createTestTaskStore();
    assert.equal(store.addUsage("cw:2026-11-22"), 1);
    assert.equal(store.addUsage("cw:2026-11-22"), 2);
    const snap = store.planSnapshot(["cw:2026-11-22", "ar:2026-11"]);
    assert.deepEqual(snap.usage, { "cw:2026-11-22": 2, "ar:2026-11": 0 });
    assert.deepEqual(snap.entitlements, []);
  });

  it("hides changes older than the window and counts them", async () => {
    const { store, db } = await createTestTaskStore();
    store.push([{ clientOpId: `w_1_${Date.now()}`, entity: "task", id: "window-task", op: "upsert", fields: { title: "one", status: "open" } }] as never, "app:test");
    store.push([{ clientOpId: `w_2_${Date.now()}`, entity: "task", id: "window-task", op: "upsert", fields: { title: "two" } }] as never, "app:test");
    db.prepare("UPDATE changes SET at = ? WHERE rev = (SELECT MIN(rev) FROM changes)").run("2020-01-01T00:00:00.000Z");
    const since = "2026-01-01T00:00:00.000Z";
    assert.equal(store.history("task", "window-task", null, 50).length, 2);
    assert.equal(store.history("task", "window-task", null, 50, since).length, 1);
    assert.equal(store.historyHidden("task", "window-task", since), 1);
  });

  it("offers the history_edge upsell only on the free plan with hidden changes", () => {
    const free = { plan: "free" as const, limits: ent.PLAN_TABLE.free, rows: [], usage: {} };
    const plus = { plan: "plus" as const, limits: ent.PLAN_TABLE.plus, rows: [], usage: {} };
    assert.equal(ent.historyEdgeUpsell(free, 3), "history_edge");
    assert.equal(ent.historyEdgeUpsell(free, 0), null, "nothing hidden");
    assert.equal(ent.historyEdgeUpsell(free, null), null, "more pages follow");
    assert.equal(ent.historyEdgeUpsell(plus, 3), null, "Plus has no upsell");
    assert.equal(ent.historyEdgeUpsell(null, 3), null, "no plan");
  });

  it("sums stored attachment bytes", async () => {
    const { store } = await createTestTaskStore();
    assert.equal(store.attachmentBytes(), 0);
  });
});

describe("reverse trial", () => {
  const DAY = 86_400_000;

  it("gives Plus for 14 days, then the free account", () => {
    const now = Date.UTC(2026, 10, 22);
    const row = { ...ent.trialRow(now), updatedAt: now };
    assert.equal(row.expiresAt, now + 14 * DAY);
    assert.equal(ent.resolvePlan([row], now + 13 * DAY), "plus");
    assert.equal(ent.trialEndsAt([row], now), now + 14 * DAY);
    // No renewal leeway: the trial ends on the hour it says.
    assert.equal(ent.resolvePlan([row], now + 14 * DAY), "free");
    assert.equal(ent.trialEndsAt([row], now + 14 * DAY), null);
  });

  it("reports no trial end once a paid row is active too", () => {
    const now = Date.UTC(2026, 10, 22);
    const row = { ...ent.trialRow(now), updatedAt: now };
    assert.equal(ent.trialEndsAt([row, grant()], now), null);
    assert.equal(ent.resolvePlan([row, grant()], now), "plus");
  });

  it("starts once per account", async () => {
    const { store } = await createTestTaskStore();
    const first = Date.UTC(2026, 10, 22);
    assert.equal(store.startTrialOnce(ent.trialRow(first)), true);
    assert.equal(store.startTrialOnce(ent.trialRow(first + 30 * DAY)), false);
    const rows = store.entitlements();
    assert.equal(rows.length, 1);
    assert.equal(rows[0].expiresAt, first + 14 * DAY);
  });
});
