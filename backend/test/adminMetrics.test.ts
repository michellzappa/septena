import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestAccountStore, createTestTaskStore, ensureSession, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Growth on the admin page (ADR 0059).

const { change, cumulative, lastDays, perDay, snapshotSeries, weeklyCohorts, windowChange } = await import("../src/admin/metrics.ts");
const { ADMIN_PAGES, renderAdmin } = await import("../src/admin/page.ts");
const { embedUrl } = await import("../src/admin/plausible.ts");
const { clientMix, releaseAdoption } = await import("../src/admin/metrics.ts");
const { deviceLabel } = await import("../src/admin/accounts.ts");
const { clientVersion } = await import("../src/api/routes.ts");

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 10, 26, 12);
const userId = (n: number) => `u_${String(n).repeat(43)}`;

const row = (n: number, createdAt: number, summary: Record<string, unknown> | null = null) => ({
  userId: userId(n), createdAt, refreshedAt: NOW, providers: ["apple"], plusLinks: [],
  summary: summary as never,
});
const summary = (over: Record<string, unknown> = {}) => ({
  firstSeen: null, lastChangeAt: null, signedIn: true, openTasks: 1, closedTasks: 0, projects: 0, areas: 0, sharedProjects: 0,
  files: 0, fileBytes: 0, devices: [], agents: [], agentChangesWeek: 0, webhooks: 0, failingWebhooks: 0, entitlements: [], ...over,
});

describe("admin growth", () => {
  it("builds day series from start times", () => {
    const days = lastDays(3, NOW);
    assert.deepEqual(days, ["2026-11-24", "2026-11-25", "2026-11-26"]);
    const times = [NOW - 10 * DAY, NOW - DAY, NOW - DAY, NOW];
    assert.deepEqual(perDay(times, days), [0, 2, 1]);
    assert.deepEqual(cumulative(times, days), [1, 3, 4]);
  });

  it("compares with a week before, and says nothing without history", () => {
    assert.deepEqual(change([10, null, null, null, null, null, null, 15]), { abs: 5, pct: 0.5 });
    assert.equal(change([null, 1, 2, 3, 4, 5, 6, 7]), null);
    assert.deepEqual(windowChange([1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2]), { now: 14, before: 7, pct: 1 });
    assert.equal(windowChange([0, 0, 1]).pct, null);
  });

  it("reads snapshot fields per day and leaves gaps empty", () => {
    const days = lastDays(3, NOW);
    assert.deepEqual(snapshotSeries([{ day: "2026-11-25", data: { paid: 2 } }], "paid", days), [null, 2, null]);
  });

  it("groups accounts by the Monday of their first week", () => {
    const seen = [{ client: "septask-mac", version: "0.9.0", firstSeen: NOW, lastSeen: NOW }];
    const cohorts = weeklyCohorts([
      row(1, NOW, summary({ closedTasks: 3, devices: seen })),
      row(2, NOW - DAY, summary()),
      row(3, NOW - 9 * DAY, summary({ closedTasks: 1 })),
    ] as never, 2, NOW);
    assert.deepEqual(cohorts.map((c) => [c.week, c.size, c.activated, c.activeWeek]), [["2026-11-23", 2, 1, 1], ["2026-11-16", 1, 1, 0]]);
  });

  it("keeps one snapshot per day", async () => {
    const { store } = await createTestAccountStore();
    store.saveMetricDay("2026-11-25", { accounts: 1 });
    store.saveMetricDay("2026-11-26", { accounts: 2 });
    store.saveMetricDay("2026-11-26", { accounts: 3 });
    assert.deepEqual(store.listMetricDays("2026-11-26"), [{ day: "2026-11-26", data: { accounts: 3 } }]);
  });

  it("renders without Plausible and escapes traffic names", () => {
    const base = {
      admin: "mz@example.com", accounts: [row(1, NOW, summary({ closedTasks: 1 }))] as never, links: [], uses: [], signups: null, query: "",
      emailSignups: [], emailUserId: null, history: [], releases: [], now: NOW,
    };
    const off = renderAdmin("website", { ...base, traffic: { state: "off" } });
    assert.match(off, /Plausible is not connected/);
    assert.match(off, /<a href="\/admin\/website" aria-current="page">Website<\/a>/);
    const view = {
      site: "septena.app", days: [{ day: "2026-11-26", visitors: 5, pageviews: 9 }],
      totals: { visitors: 5, visits: 6, pageviews: 9, bounceRate: 40, visitDuration: 75 },
      sources: [{ name: "<script>", visitors: 3, n: 3, rate: null }], pages: [], countries: [],
      goals: [{ name: "Signup", visitors: 1, n: 1, rate: 20 }], missingGoals: ["Download click"], downloads: [], ctaPlacements: [], fetchedAt: NOW,
    };
    const on = renderAdmin("website", { ...base, traffic: { state: "ok", view } });
    assert.ok(on.includes("&lt;script&gt;") && !on.includes("<script>"));
    assert.match(on, /20\.00%/);
    assert.match(on, /No events in 30 days: Download click/);
  });

  it("renders every page with its own tab marked and the brand accent", () => {
    const base = {
      admin: "mz@example.com", accounts: [row(1, NOW, summary({ closedTasks: 1 }))] as never, links: [], uses: [], signups: null, query: "",
      emailSignups: [], emailUserId: null, history: [], releases: [], now: NOW, traffic: { state: "off" as const },
    };
    for (const p of ADMIN_PAGES) {
      const html = renderAdmin(p.id, base);
      assert.equal((html.match(/aria-current="page"/g) ?? []).length, 1, p.id);
      assert.ok(html.includes(`href="/admin${p.path}" aria-current="page"`), p.id);
      assert.match(html, /--accent: #E05212/i, p.id);
    }
    assert.match(renderAdmin("accounts", base), /1 of 1/);
    assert.doesNotMatch(renderAdmin("overview", base), /<table><thead><tr><th>Account<\/th>/, "the account table is its own page");
  });

  it("embeds only a plausible.io share link", () => {
    assert.match(embedUrl("https://plausible.io/share/septena.app?auth=abc")!, /^https:\/\/plausible\.io\/share\/septena\.app\?auth=abc&embed=true/);
    assert.equal(embedUrl("https://evil.example/share/x"), null);
    assert.equal(embedUrl("http://plausible.io/share/x"), null);
    assert.equal(embedUrl("https://plausible.io/septena.app"), null);
    assert.equal(embedUrl(undefined), null);
  });

  it("reads the version header, and the version older Android and web builds put in the client name", () => {
    assert.equal(clientVersion("0.9.0 (2935)", "septask-mac"), "0.9.0 (2935)");
    assert.equal(clientVersion(undefined, "android 0.9.0"), "0.9.0");
    assert.equal(clientVersion(undefined, "web 0.2.0"), "0.2.0");
    assert.equal(clientVersion(undefined, "septask-mac"), null);
    assert.equal(clientVersion("x".repeat(80), "septask-mac"), null, "a value the client-name rule refuses is dropped");
    assert.equal(deviceLabel({ client: "septask-mac", version: null }), "Mac, older build");
    assert.equal(deviceLabel({ client: "android 0.9.0", version: null }), "Android 0.9.0");
    assert.equal(deviceLabel({ client: "septena-android", version: "0.9.1 (40)" }), "Android 0.9.1 (40)");
  });

  it("groups versions by marketing version and counts releases per device", () => {
    const dev = (client: string, version: string | null) => ({ client, version, firstSeen: NOW - DAY, lastSeen: NOW });
    const rows = [
      row(1, NOW, summary({ devices: [dev("septask-mac", "0.9.0 (2844)"), dev("septask-mac", "0.9.0 (2935)"), dev("septask-mac", null)],
        versions: [{ client: "septask-mac", version: "0.9.0 (2844)", firstSeen: NOW - 5 * DAY, lastSeen: NOW }, { client: "septask-mac", version: "0.9.0 (2935)", firstSeen: NOW - DAY, lastSeen: NOW }] })),
      row(2, NOW, summary({ devices: [dev("android 0.9.0", null)], versions: [{ client: "septena-android", version: "0.9.1 (40)", firstSeen: NOW, lastSeen: NOW }] })),
    ] as never;
    const mix = clientMix(rows, NOW);
    assert.deepEqual(mix.platforms.map((t) => [t.name, t.n]), [["Mac", 3], ["Android", 1]]);
    assert.deepEqual(mix.versions.map((t) => [t.name, t.n]), [["Mac 0.9.0", 2], ["Android 0.9.0", 1], ["Mac, older build", 1]]);
    assert.equal(mix.builds.length, 3);
    assert.deepEqual(releaseAdoption(rows).map((r) => [r.name, r.devices]), [["Android 0.9.1", 1], ["Mac 0.9.0", 2]]);
  });

  it("keeps every version a device ran", async () => {
    const { store } = await createTestTaskStore();
    ensureSession(store, "sid-1");
    store.deviceAccess("sid-1", "septask-mac", null, NOW - DAY, "0.9.0 (1)");
    store.deviceAccess("sid-1", "septask-mac", null, NOW, "0.9.0 (2)");
    store.deviceAccess("sid-1", "septask-mac", null, NOW, null);
    const versions = store.accountSummary(NOW)!.versions!.map((v) => v.version);
    assert.deepEqual(versions, ["0.9.0 (1)", "0.9.0 (2)"]);
  });

  it("counts the appearance of active signed-in accounts only (#859)", async () => {
    const { appearanceMix, appearanceSnapshot } = await import("../src/admin/metrics.ts");
    const seen = (at: number) => [{ client: "septask-mac", version: "0.9.0", firstSeen: at, lastSeen: at }];
    const look = (over: Record<string, unknown> = {}) => ({ accentColor: "colorful", canvasTexture: "none", textureIntensity: 55, textureMotion: "still", ...over });
    const mix = appearanceMix([
      row(1, NOW, summary({ devices: seen(NOW), appearance: look() })),
      row(2, NOW, summary({ devices: seen(NOW - DAY), appearance: look({ accentColor: "persimmon", canvasTexture: "ridges", textureIntensity: 80, textureMotion: "slowDrift" }) })),
      row(3, NOW, summary({ devices: seen(NOW), appearance: look({ accentColor: "other", canvasTexture: "ridges", textureIntensity: "other" }) })),
      row(4, NOW, summary({ devices: seen(NOW - 31 * DAY), appearance: look({ accentColor: "yuzu" }) })),
      row(5, NOW, summary({ devices: seen(NOW) })),
    ] as never, NOW);
    assert.equal(mix.accounts, 3, "inactive and summaries without appearance are not counted");
    assert.deepEqual(mix.accentColor, [{ name: "colorful", n: 1 }, { name: "other", n: 1 }, { name: "persimmon", n: 1 }]);
    assert.deepEqual(mix.canvasTexture, [{ name: "ridges", n: 2 }, { name: "none", n: 1 }]);
    assert.deepEqual(mix.textureIntensity, [{ name: "higher", n: 1 }, { name: "other", n: 1 }], "only accounts with a texture");
    assert.deepEqual(mix.textureMotion, [{ name: "slowDrift", n: 1 }, { name: "still", n: 1 }]);
    const snap = appearanceSnapshot(mix);
    assert.equal(snap["appearance.accounts"], 3);
    assert.equal(snap["appearance.canvasTexture.ridges"], 2);
    assert.equal(snap["appearance.accentColor.yuzu"], undefined);
  });

  it("reads appearance from synced settings: defaults, and other for unknown values (#859)", async () => {
    const { appearanceFromSettings } = await import("../src/store/TaskStore.ts");
    assert.deepEqual(appearanceFromSettings(() => null), { accentColor: "colorful", canvasTexture: "none", textureIntensity: 55, textureMotion: "still" });
    const set: Record<string, unknown> = { accentColor: "haskap", canvasTexture: "<b>typed</b>", textureIntensity: 7, textureMotion: "slowDrift" };
    assert.deepEqual(appearanceFromSettings((k) => set[k] ?? null), { accentColor: "haskap", canvasTexture: "other", textureIntensity: "other", textureMotion: "slowDrift" });

    const { store } = await createTestTaskStore();
    assert.equal(store.accountSummary(NOW)?.appearance, undefined, "no sign-in, no appearance");
    ensureSession(store, "sid-1");
    store.push([{ clientOpId: "op-1", op: "upsert", entity: "setting", id: "accentColor", fields: { value: "yuzu" } }] as never, "app");
    assert.deepEqual(store.accountSummary(NOW)!.appearance, { accentColor: "yuzu", canvasTexture: "none", textureIntensity: 55, textureMotion: "still" });
  });

  it("shows the appearance block on the product page (#859)", () => {
    const seen = [{ client: "septask-mac", version: "0.9.0", firstSeen: NOW, lastSeen: NOW }];
    const html = renderAdmin("product", {
      admin: "mz@example.com", accounts: [row(1, NOW, summary({ devices: seen, appearance: { accentColor: "persimmon", canvasTexture: "washiPaper", textureIntensity: 55, textureMotion: "still" } }))] as never,
      links: [], uses: [], signups: null, query: "", emailSignups: [], emailUserId: null, history: [], releases: [], traffic: { state: "off" }, now: NOW,
    });
    assert.match(html, /<h2>Appearance<\/h2>/);
    assert.match(html, /Persimmon/);
    assert.match(html, /Washi Paper/);
    assert.match(html, /without sign-in/);
  });
});
