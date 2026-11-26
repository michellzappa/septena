import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createTestAccountStore, installWorkerTestHooks } from "./taskStoreHarness.ts";

installWorkerTestHooks();

// Growth on the admin page (ADR 0059).

const { change, cumulative, lastDays, perDay, snapshotSeries, weeklyCohorts, windowChange } = await import("../src/admin/metrics.ts");
const { renderAdmin } = await import("../src/admin/page.ts");
const { embedUrl } = await import("../src/admin/plausible.ts");

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
    const off = renderAdmin({ ...base, traffic: { state: "off" } });
    assert.match(off, /Plausible is not connected/);
    assert.match(off, /id="growth"/);
    const view = {
      site: "septena.app", days: [{ day: "2026-11-26", visitors: 5, pageviews: 9 }],
      totals: { visitors: 5, visits: 6, pageviews: 9, bounceRate: 40, visitDuration: 75 },
      sources: [{ name: "<script>", visitors: 3, n: 3, rate: null }], pages: [], countries: [],
      goals: [{ name: "Signup", visitors: 1, n: 1, rate: 20 }], missingGoals: ["Download click"], downloads: [], ctaPlacements: [], fetchedAt: NOW,
    };
    const on = renderAdmin({ ...base, traffic: { state: "ok", view } });
    assert.ok(on.includes("&lt;script&gt;") && !on.includes("<script>"));
    assert.match(on, /20\.00%/);
    assert.match(on, /No events in 30 days: Download click/);
  });

  it("embeds only a plausible.io share link", () => {
    assert.match(embedUrl("https://plausible.io/share/septena.app?auth=abc")!, /^https:\/\/plausible\.io\/share\/septena\.app\?auth=abc&embed=true/);
    assert.equal(embedUrl("https://evil.example/share/x"), null);
    assert.equal(embedUrl("http://plausible.io/share/x"), null);
    assert.equal(embedUrl("https://plausible.io/septena.app"), null);
    assert.equal(embedUrl(undefined), null);
  });
});
