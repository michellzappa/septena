import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Plan table and free-account limits (docs/SYNC_SUBSCRIPTION_SPEC.md §3, §6,
// ADR 0010, ADR 0023).

const ent = await import("../src/entitlement/entitlement.ts");
const { DEVICE_SLOT_INACTIVE_MS, DEVICE_SLOT_MOVE_COOLDOWN_MS } = await import("../src/store/TaskStore.ts");
const { PLAN_LIMITS } = await import("../src/generated/registries.ts");
const { api } = await import("../src/api/routes.ts");
const { signAccessToken } = await import("../src/api/session.ts");
const { previewMcpHandler } = await import("../src/shadow/mcp.ts");
const { sha256Base64Url } = await import("../src/util.ts");

const enforcing = { ENTITLEMENT_ENFORCE: "true" } as never;
const logOnly = { ENTITLEMENT_ENFORCE: "false" } as never;
const TEST_SIGNING_KEY = Buffer.alloc(32, 7).toString("base64");
const EXEC_CTX = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;

function makeMemoryKv() {
  const map = new Map<string, string>();
  return {
    map,
    async get(key: string) { return map.get(key) ?? null; },
    async put(key: string, value: string) { map.set(key, value); },
    async delete(key: string) { map.delete(key); },
  };
}

function makeMemoryR2() {
  const map = new Map<string, Uint8Array>();
  return {
    map,
    async list({ prefix }: { prefix?: string; cursor?: string } = {}) {
      const objects = [...map.keys()]
        .filter((k) => !prefix || k.startsWith(prefix))
        .map((key) => ({ key }));
      return { objects, truncated: false, cursor: undefined };
    },
    async put(key: string, body: unknown) {
      map.set(key, body instanceof Uint8Array ? body : new Uint8Array());
    },
    async get(key: string) {
      const v = map.get(key);
      return v ? { body: v, size: v.byteLength } : null;
    },
    async delete(keys: string | string[]) {
      for (const k of Array.isArray(keys) ? keys : [keys]) map.delete(k);
    },
  };
}

async function makeRouteHarness(opts: { enforce?: boolean; failPlanRead?: boolean } = {}) {
  const tokens = makeMemoryKv();
  const attachments = makeMemoryR2();
  const stores = new Map<string, Awaited<ReturnType<typeof createTestTaskStore>>["store"]>();
  const ensureStore = async (userId: string) => {
    let s = stores.get(userId);
    if (!s) {
      s = (await createTestTaskStore()).store;
      stores.set(userId, s);
    }
    return s;
  };
  let failPlanRead = opts.failPlanRead ?? false;

  const env = {
    API_PUBLIC_URL: "https://api.septena.app",
    APPLE_AUDIENCES: "com.septena.tasks",
    ENTITLEMENT_ENFORCE: opts.enforce === false ? "false" : "true",
    APPLE_IAP_BUNDLE_IDS: "com.septena.tasks",
    APPLE_IAP_ENVIRONMENTS: "Production,Sandbox",
    SESSION_SIGNING_KEY: TEST_SIGNING_KEY,
    TOKENS: tokens,
    STATE: makeMemoryKv(),
    CLIENTS: makeMemoryKv(),
    ATTACHMENTS: attachments,
    TASK_STORE: {
      idFromName(name: string) { return name; },
      get(id: string) {
        return new Proxy({}, {
          get(_t, prop: string) {
            return async (...args: unknown[]) => {
              if (prop === "planSnapshot" && failPlanRead) {
                throw new Error("do_unavailable");
              }
              const s = await ensureStore(id);
              if (prop === "deleteAccount") {
                await s.deleteAccount();
                // Model Cloudflare's storage.deleteAll(): next access sees an empty DO.
                stores.delete(id);
                return;
              }
              return (s as unknown as Record<string, (...a: unknown[]) => unknown>)[prop](...args);
            };
          },
        });
      },
    },
  } as never;

  return {
    env,
    tokens,
    attachments,
    ensureStore,
    setFailPlanRead(v: boolean) { failPlanRead = v; },
    async authHeader(userId: string, sid: string) {
      return `Bearer ${await signAccessToken(env, userId, sid)}`;
    },
  };
}

async function captureLogs<T>(fn: () => Promise<T> | T): Promise<{ result: T; events: Record<string, unknown>[] }> {
  const events: Record<string, unknown>[] = [];
  const orig = console.log;
  console.log = (...args: unknown[]) => {
    for (const a of args) {
      if (typeof a === "string") {
        try { events.push(JSON.parse(a) as Record<string, unknown>); } catch { /* ignore */ }
      }
    }
  };
  try {
    return { result: await fn(), events };
  } finally {
    console.log = orig;
  }
}

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
    assert.equal(ent.PLAN_TABLE.free.connectorWritesPerDay, 25);
    assert.equal(ent.PLAN_TABLE.free.agentRunsPerMonth, 10);
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
    assert.match(ent.upsellLine("connector_cap"), /25/);
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

  it("preserves trial-used:<userId> across account deletion so re-signup gets no second trial", async () => {
    const h = await makeRouteHarness({ enforce: true });
    const userId = "u_trial_delete_re_signup_12345";
    const t0 = Date.UTC(2026, 10, 1);

    assert.equal(await ent.startTrialOnce(h.env, userId, t0), true);
    assert.equal(h.tokens.map.get(ent.trialUsedKey(userId)), "1");
    assert.equal(await ent.startTrialOnce(h.env, userId, t0 + DAY), false);

    // Delete the account through the real DELETE /v1/account route.
    const sid = "11111111-1111-4111-8111-111111111111";
    const res = await api.fetch(new Request("https://api.septena.app/account", {
      method: "DELETE",
      headers: { Authorization: await h.authHeader(userId, sid) },
    }), h.env, EXEC_CTX);
    assert.equal(res.status, 204);
    assert.equal(h.tokens.map.get(ent.trialUsedKey(userId)), "1", "KV marker survives account deletion");

    // Re-signing up with the same userId against a freshly emptied DO starts no second trial.
    assert.equal(await ent.startTrialOnce(h.env, userId, t0 + 30 * DAY), false);
    const freshStore = await h.ensureStore(userId);
    assert.deepEqual(freshStore.entitlements(), []);
    assert.equal((await ent.planFor(h.env, userId)).plan, "free");
  });

  it("backfills trial-used:<userId> on account deletion for pre-existing trial accounts", async () => {
    const h = await makeRouteHarness({ enforce: true });
    const userId = "u_legacy_trial_account_12345";
    const t0 = Date.UTC(2026, 10, 1);

    // Simulate an older account that wrote the DO trial row before the KV marker existed.
    const store = await h.ensureStore(userId);
    assert.equal(store.startTrialOnce(ent.trialRow(t0)), true);
    assert.equal(h.tokens.map.has(ent.trialUsedKey(userId)), false);

    const sid = "22222222-2222-4222-8222-222222222222";
    const res = await api.fetch(new Request("https://api.septena.app/account", {
      method: "DELETE",
      headers: { Authorization: await h.authHeader(userId, sid) },
    }), h.env, EXEC_CTX);
    assert.equal(res.status, 204);
    assert.equal(h.tokens.map.get(ent.trialUsedKey(userId)), "1");

    // Re-signup gets no second trial.
    assert.equal(await ent.startTrialOnce(h.env, userId, t0 + 20 * DAY), false);
    assert.deepEqual((await h.ensureStore(userId)).entitlements(), []);
  });
});

describe("free-limit hardening (spec §6.4)", () => {
  const HOUR = 60 * 60 * 1000;
  const DAY = 24 * HOUR;

  it("expires a slot holder after 14 days of inactivity so the next device takes it automatically", async () => {
    const { store } = await createTestTaskStore();
    const oldPhone = session(store, "old-phone");
    const newPhone = session(store, "new-phone");
    const mac = session(store, "mac");
    const t0 = Date.UTC(2026, 10, 1);

    assert.equal(store.deviceAccess(oldPhone, "ios", 1, t0).syncing, true);
    // Just before 14 days: old phone still holds the slot.
    assert.equal(store.deviceAccess(newPhone, "ios", 1, t0 + DEVICE_SLOT_INACTIVE_MS - 1).syncing, false);
    // At 14 days of inactivity: new phone automatically takes the slot with no prompt.
    assert.equal(store.deviceAccess(newPhone, "ios", 1, t0 + DEVICE_SLOT_INACTIVE_MS).syncing, true);
    assert.equal(store.deviceAccess(oldPhone, "ios", 1, t0 + DEVICE_SLOT_INACTIVE_MS + 1000).syncing, false);

    // Automatic take does NOT count against the 24-hour manual move cooldown.
    const move = store.claimDeviceSlot(mac, "mac", 1, true, t0 + DEVICE_SLOT_INACTIVE_MS + 2000);
    assert.deepEqual(move, { ok: true, moved: true });
    assert.equal(store.deviceAccess(mac, "mac", 1, t0 + DEVICE_SLOT_INACTIVE_MS + 3000).syncing, true);
    assert.equal(store.deviceAccess(newPhone, "ios", 1, t0 + DEVICE_SLOT_INACTIVE_MS + 3000).syncing, false);
  });

  it("reports a free slot in deviceSummary and GET /v1/entitlement after 14 days of inactivity", async () => {
    const h = await makeRouteHarness({ enforce: true });
    const userId = "u_stale_holder_summary_12345";
    const oldSid = "33333333-3333-4333-8333-333333333333";
    const newSid = "44444444-4444-4444-8444-444444444444";
    const store = await h.ensureStore(userId);
    const now = Date.now();
    store.createSession("h-old", now + 30 * DAY, oldSid);
    store.createSession("h-new", now + 30 * DAY, newSid);
    store.deviceAccess(oldSid, "ios", 1, now - DEVICE_SLOT_INACTIVE_MS - HOUR);

    const summary = store.deviceSummary(1, now);
    assert.equal(summary.find((d) => d.sid === oldSid)?.syncing, false);

    const res = await api.fetch(new Request("https://api.septena.app/entitlement", {
      headers: { Authorization: await h.authHeader(userId, newSid) },
    }), h.env, EXEC_CTX);
    assert.equal(res.status, 200);
    const body = await res.json() as { device: { syncing: boolean; syncingDevices: number } };
    assert.equal(body.device.syncing, true);
    assert.equal(body.device.syncingDevices, 0);
  });

  it("limits manual device slot moves to once per 24 hours on a capped plan", async () => {
    const { store } = await createTestTaskStore();
    const phone = session(store, "phone");
    const mac = session(store, "mac");
    const t0 = Date.UTC(2026, 10, 1);

    assert.equal(store.deviceAccess(phone, "ios", 1, t0).syncing, true);
    // First manual move succeeds.
    assert.deepEqual(store.claimDeviceSlot(mac, "mac", 1, true, t0 + HOUR), { ok: true, moved: true });
    // Re-claiming from the current holder is idempotent and does not fail.
    assert.deepEqual(store.claimDeviceSlot(mac, "mac", 1, true, t0 + 2 * HOUR), { ok: true, moved: false });
    // Second manual move within 24h is blocked.
    const blocked = store.claimDeviceSlot(phone, "ios", 1, true, t0 + 2 * HOUR);
    assert.equal(blocked.ok, false);
    if (!blocked.ok) assert.equal(blocked.retryAfterMs, DEVICE_SLOT_MOVE_COOLDOWN_MS - HOUR);
    assert.equal(store.deviceAccess(mac, "mac", 1, t0 + 2 * HOUR).syncing, true);
    assert.equal(store.deviceAccess(phone, "ios", 1, t0 + 2 * HOUR).syncing, false);
    // After 24h, moving back succeeds.
    assert.deepEqual(store.claimDeviceSlot(phone, "ios", 1, true, t0 + HOUR + DEVICE_SLOT_MOVE_COOLDOWN_MS), { ok: true, moved: true });
    assert.equal(store.deviceAccess(phone, "ios", 1, t0 + HOUR + DEVICE_SLOT_MOVE_COOLDOWN_MS + 1).syncing, true);
  });

  it("returns 402 with second_device upsell body on a second POST /v1/entitlement/device within 24h", async () => {
    const h = await makeRouteHarness({ enforce: true });
    const userId = "u_move_rate_limit_http_12345";
    const phoneSid = "55555555-5555-4555-8555-555555555555";
    const macSid = "66666666-6666-4666-8666-666666666666";
    const store = await h.ensureStore(userId);
    store.createSession("h-phone", Date.now() + DAY, phoneSid);
    store.createSession("h-mac", Date.now() + DAY, macSid);
    store.deviceAccess(phoneSid, "ios", 1);

    // Move 1: phone -> mac succeeds.
    const first = await api.fetch(new Request("https://api.septena.app/entitlement/device", {
      method: "POST",
      headers: { Authorization: await h.authHeader(userId, macSid), "X-Septena-Client": "macos" },
    }), h.env, EXEC_CTX);
    assert.equal(first.status, 200);
    assert.deepEqual(await first.json(), { syncing: true });

    // Move 2 within 24h: mac -> phone returns 402 with second_device upsell words.
    const second = await api.fetch(new Request("https://api.septena.app/entitlement/device", {
      method: "POST",
      headers: { Authorization: await h.authHeader(userId, phoneSid), "X-Septena-Client": "ios" },
    }), h.env, EXEC_CTX);
    assert.equal(second.status, 402);
    assert.deepEqual(await second.json(), {
      error: "device_move_rate_limited",
      limit: "devices",
      upsell: "second_device",
      message: ent.upsellLine("second_device"),
    });

    // In log-only mode, a second move within 24h logs entitlement_would_block and succeeds.
    const hLog = await makeRouteHarness({ enforce: false });
    const logStore = await hLog.ensureStore(userId);
    logStore.createSession("h-phone", Date.now() + DAY, phoneSid);
    logStore.createSession("h-mac", Date.now() + DAY, macSid);
    logStore.deviceAccess(phoneSid, "ios", 1);
    assert.equal((await api.fetch(new Request("https://api.septena.app/entitlement/device", {
      method: "POST",
      headers: { Authorization: await hLog.authHeader(userId, macSid), "X-Septena-Client": "macos" },
    }), hLog.env, EXEC_CTX)).status, 200);
    const { result: logSecond, events: logEvents } = await captureLogs(async () =>
      api.fetch(new Request("https://api.septena.app/entitlement/device", {
        method: "POST",
        headers: { Authorization: await hLog.authHeader(userId, phoneSid), "X-Septena-Client": "ios" },
      }), hLog.env, EXEC_CTX),
    );
    assert.equal(logSecond.status, 200);
    assert.ok(logEvents.some((e) => e.evt === "entitlement_would_block" && e.surface === "device_slot_move" && e.limit === "devices"));
  });

  it("allows sync on plan read failure (logged as plan_check_failed) while attachments and agent claims stay fail-closed", async () => {
    // Unit check on planCheckFailed modes and log event name.
    const { result: unitActions, events: unitEvents } = await captureLogs(() => ({
      openEnforcing: ent.planCheckFailed(enforcing, "u_1", "sync", new Error("boom"), "open"),
      closedEnforcing: ent.planCheckFailed(enforcing, "u_1", "attachments", new Error("boom"), "closed"),
      closedLogOnly: ent.planCheckFailed(logOnly, "u_1", "attachments", new Error("boom"), "closed"),
    }));
    assert.deepEqual(unitActions, { openEnforcing: "allow", closedEnforcing: "block", closedLogOnly: "allow" });
    assert.equal(unitEvents.length, 3);
    assert.equal(unitEvents[0].evt, "plan_check_failed");
    assert.equal(unitEvents[0].mode, "open");
    assert.equal(unitEvents[0].action, "allow");
    assert.equal(unitEvents[1].evt, "plan_check_failed");
    assert.equal(unitEvents[1].mode, "closed");
    assert.equal(unitEvents[1].action, "block");

    // HTTP routes in enforce mode when planSnapshot fails.
    const h = await makeRouteHarness({ enforce: true, failPlanRead: true });
    const userId = "u_fail_open_sync_1234567890";
    const sid = "77777777-7777-4777-8777-777777777777";
    const auth = await h.authHeader(userId, sid);

    const { result: syncRes, events: syncEvents } = await captureLogs(() =>
      api.fetch(new Request("https://api.septena.app/sync/pull?since=0", {
        headers: { Authorization: auth },
      }), h.env, EXEC_CTX),
    );
    assert.equal(syncRes.status, 200, "sync pull fails open on plan read failure");
    assert.ok(syncEvents.some((e) => e.evt === "plan_check_failed" && e.surface === "sync" && e.action === "allow"));

    const { result: pushRes, events: pushEvents } = await captureLogs(() =>
      api.fetch(new Request("https://api.septena.app/sync/push", {
        method: "POST",
        headers: { Authorization: auth, "Content-Type": "application/json" },
        body: JSON.stringify({
          ops: [{
            clientOpId: "op_fail_open_1",
            entity: "task",
            id: "task-fail-open",
            op: "upsert",
            fields: { title: "Still syncs", status: "open" },
          }],
        }),
      }), h.env, EXEC_CTX),
    );
    assert.equal(pushRes.status, 200, "sync push fails open on plan read failure");
    assert.ok(pushEvents.some((e) => e.evt === "plan_check_failed" && e.surface === "sync" && e.action === "allow"));

    const { result: attRes, events: attEvents } = await captureLogs(() =>
      api.fetch(new Request("https://api.septena.app/attachments/att-1", {
        method: "PUT",
        headers: { Authorization: auth, "Content-Length": "4" },
        body: "test",
      }), h.env, EXEC_CTX),
    );
    assert.equal(attRes.status, 503, "attachment upload stays fail-closed on plan read failure");
    assert.deepEqual(await attRes.json(), { error: "plan_check_failed" });
    assert.ok(attEvents.some((e) => e.evt === "plan_check_failed" && e.surface === "attachments" && e.action === "block"));

    // MCP tasks_claim stays fail-closed on plan read failure.
    const mcpToken = "sm1.test_access_token_value";
    const tokenHash = await sha256Base64Url(mcpToken);
    await h.tokens.put(`v2:access:${tokenHash}`, JSON.stringify({
      userId,
      clientId: "client-1",
      familyId: "fam-1",
      scope: "tasks:read tasks:write",
      expiresAt: Date.now() + 3600_000,
    }));
    const { result: claimRes, events: claimEvents } = await captureLogs(() => {
      const req = new Request("https://api.septena.app/mcp", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${mcpToken}`,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: { name: "tasks_claim", arguments: { id: "task-1", agent: "runner" } },
        }),
      });
      const fakeC = {
        req: {
          header: (k: string) => req.headers.get(k) ?? undefined,
          raw: req,
          text: () => req.text(),
          json: () => req.json(),
        },
        env: h.env,
      };
      return previewMcpHandler(fakeC as never);
    });
    assert.equal(claimRes.status, 200);
    const rpc = await claimRes.json() as { result?: { isError?: boolean; content?: { text: string }[] } };
    assert.equal(rpc.result?.isError, true, "agent claim stays fail-closed on plan read failure");
    assert.match(rpc.result?.content?.[0]?.text ?? "", /could not check this account's plan/i);
    assert.ok(claimEvents.some((e) => e.evt === "plan_check_failed" && e.surface === "tasks_claim" && e.action === "block"));
  });
});
