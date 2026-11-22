import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestTaskStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Settings > Account > Devices & Access: every place the account is signed
// in (GET /v1/access) and signing one out.

const DAY = 86_400_000;

async function freshStore() {
  return (await createTestTaskStore()).store;
}

describe("access summary", () => {
  it("lists devices with a live session and marks the caller", async () => {
    const store = await freshStore();
    store.createSession("h-phone", Date.now() + DAY, "sid-phone");
    store.createSession("h-mac", Date.now() + DAY, "sid-mac");
    store.deviceAccess("sid-phone", "ios", null);
    store.deviceAccess("sid-mac", "macos", null);
    const s = store.accessSummary("sid-mac", null);
    assert.equal(s.devices.length, 2);
    assert.deepEqual(s.devices.find((d) => d.sid === "sid-mac")?.current, true);
    assert.deepEqual(s.devices.find((d) => d.sid === "sid-phone")?.current, false);
    assert.equal(s.devices.find((d) => d.sid === "sid-phone")?.client, "ios");
  });

  it("lists connections newest first and drops expired ones", async () => {
    const store = await freshStore();
    const now = Date.now();
    store.recordConnection("fam-old", "c1", "Claude", "tasks:read", now - 31 * DAY);
    store.recordConnection("fam-claude", "c2", "Claude", "tasks:read tasks:write", now - DAY);
    store.recordConnection("fam-gpt", "c3", "ChatGPT", "tasks:read tasks:write", now);
    const s = store.accessSummary(null, null, now);
    assert.deepEqual(s.connections.map((c) => c.id), ["fam-gpt", "fam-claude"]);
    assert.equal(s.connections[0].clientName, "ChatGPT");
  });

  it("keeps createdAt and moves lastUsed on rotation", async () => {
    const store = await freshStore();
    store.recordConnection("fam", "c", "Claude", "tasks:read", 1_000);
    store.recordConnection("fam", "c", "Claude", "tasks:read tasks:write", 5_000);
    const [c] = store.accessSummary(null, null, 6_000).connections;
    assert.equal(c.createdAt, 1_000);
    assert.equal(c.lastUsed, 5_000);
    assert.equal(c.scope, "tasks:read tasks:write");
  });
});

describe("signing out", () => {
  it("revokes every refresh token of one device and hides it", async () => {
    const store = await freshStore();
    store.createSession("h-a", Date.now() + DAY, "sid-a");
    store.createSession("h-b", Date.now() + DAY, "sid-b");
    store.deviceAccess("sid-a", "ios", null);
    store.deviceAccess("sid-b", "android", null);
    assert.deepEqual(store.revokeDevice("sid-b"), ["h-b"]);
    assert.equal(store.rotateSession("h-b", "h-b2", Date.now() + DAY), null, "the refresh token is dead");
    assert.deepEqual(store.accessSummary("sid-a", null).devices.map((d) => d.sid), ["sid-a"]);
    assert.deepEqual(store.revokeDevice("sid-unknown"), []);
  });

  it("forgets a connection once", async () => {
    const store = await freshStore();
    store.recordConnection("fam", "c", "Claude", "tasks:read");
    assert.equal(store.forgetConnection("fam"), true);
    assert.equal(store.forgetConnection("fam"), false);
    assert.equal(store.accessSummary(null, null).connections.length, 0);
  });
});
