import { z } from "zod";
import type { Env } from "../env.js";
import { logEvent } from "../util.js";

// The website's traffic for the admin page, from the Plausible Stats API v2
// (https://plausible.io/docs/stats-api). Plausible is anonymous and aggregate
// (septena-site docs/marketing.md), so nothing here names a person.
// The key is a read-only Stats API key: `wrangler secret put PLAUSIBLE_API_KEY`.
// The answer is cached in KV for CACHE_SECONDS so a page load does not wait on
// eight API calls.

const ENDPOINT = "https://plausible.io/api/v2/query";
const CACHE_KEY = "admin:plausible:v1";
const CACHE_SECONDS = 600;
const TIMEOUT_MS = 6000;

/// The site's custom events (septena-site components/*.tsx). Plausible counts
/// an event as a goal only after the goal is added in its site settings.
export const CTA_GOALS = ["Signup", "Signup answers", "Download click", "List-keeper CTA", "List-keeper start", "List-keeper finish", "List-keeper share", "Help answered"];

const zResult = z.object({
  results: z.array(z.object({ metrics: z.array(z.number().nullable()), dimensions: z.array(z.string()) })),
});

export interface Row { name: string; visitors: number; n: number; rate: number | null }

export interface TrafficView {
  site: string;
  days: { day: string; visitors: number; pageviews: number }[];
  totals: { visitors: number; visits: number; pageviews: number; bounceRate: number; visitDuration: number };
  sources: Row[];
  pages: Row[];
  countries: Row[];
  goals: Row[];
  /// Site events that Plausible has no goal for yet: they are not counted.
  missingGoals: string[];
  downloads: Row[];
  ctaPlacements: Row[];
  fetchedAt: number;
}

export type TrafficResult = { state: "off" } | { state: "error"; reason: string } | { state: "ok"; view: TrafficView };

async function query(env: Env, site: string, body: Record<string, unknown>) {
  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.PLAUSIBLE_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ site_id: site, ...body }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`plausible ${res.status}`);
  return zResult.parse(await res.json()).results;
}

const num = (v: number | null | undefined) => (typeof v === "number" ? v : 0);

/// A breakdown: visitors and a second metric by one dimension, top `limit`.
async function breakdown(env: Env, site: string, dimension: string, metric: "pageviews" | "events" | "visits", limit: number, filters?: unknown[]) {
  const results = await query(env, site, {
    metrics: ["visitors", metric], date_range: "30d", dimensions: [dimension],
    ...(filters ? { filters } : {}), order_by: [["visitors", "desc"]], pagination: { limit },
  });
  return results.map((r) => ({ name: r.dimensions[0] || "(none)", visitors: num(r.metrics[0]), n: num(r.metrics[1]), rate: null }));
}

async function load(env: Env, site: string): Promise<TrafficView> {
  // A goal filter names a goal Plausible must know, so each part may fail on
  // its own; only the totals are required.
  const goalFilter = (goal: string) => [["is", "event:goal", [goal]]];
  const soft = async <T>(p: Promise<T[]>): Promise<T[]> => p.catch((e) => {
    logEvent("admin_plausible_part_failed", { error: String(e) });
    return [];
  });
  const [daily, totals, sources, pages, countries, goals, downloads, ctaPlacements] = await Promise.all([
    soft(query(env, site, { metrics: ["visitors", "pageviews"], date_range: "30d", dimensions: ["time:day"] })),
    query(env, site, { metrics: ["visitors", "visits", "pageviews", "bounce_rate", "visit_duration"], date_range: "30d" }),
    soft(breakdown(env, site, "visit:source", "visits", 10)),
    soft(breakdown(env, site, "event:page", "pageviews", 12)),
    soft(breakdown(env, site, "visit:country_name", "visits", 10)),
    soft(query(env, site, { metrics: ["visitors", "events", "conversion_rate"], date_range: "30d", dimensions: ["event:goal"] })),
    soft(breakdown(env, site, "event:props:platform", "events", 10, goalFilter("Download click"))),
    soft(breakdown(env, site, "event:props:placement", "events", 10, goalFilter("List-keeper CTA"))),
  ]);
  const t = totals[0]?.metrics ?? [];
  const goalRows = goals.map((r) => ({ name: r.dimensions[0], visitors: num(r.metrics[0]), n: num(r.metrics[1]), rate: r.metrics[2] ?? null }));
  return {
    site,
    days: daily.map((r) => ({ day: r.dimensions[0].slice(0, 10), visitors: num(r.metrics[0]), pageviews: num(r.metrics[1]) }))
      .sort((a, b) => a.day.localeCompare(b.day)),
    totals: { visitors: num(t[0]), visits: num(t[1]), pageviews: num(t[2]), bounceRate: num(t[3]), visitDuration: num(t[4]) },
    sources, pages, countries,
    goals: goalRows.sort((a, b) => b.visitors - a.visitors),
    missingGoals: CTA_GOALS.filter((g) => !goalRows.some((r) => r.name === g)),
    downloads, ctaPlacements,
    fetchedAt: Date.now(),
  };
}

/// Drops the cached answer, so the next page load asks Plausible again.
export async function forgetTraffic(env: Env): Promise<void> {
  await env.STATE.delete(CACHE_KEY);
}

export async function trafficView(env: Env): Promise<TrafficResult> {
  if (!env.PLAUSIBLE_API_KEY) return { state: "off" };
  const site = env.PLAUSIBLE_SITE_ID || "septena.app";
  const cached = await env.STATE.get(CACHE_KEY);
  if (cached) {
    try { return { state: "ok", view: JSON.parse(cached) as TrafficView }; } catch { /* reload */ }
  }
  try {
    const view = await load(env, site);
    await env.STATE.put(CACHE_KEY, JSON.stringify(view), { expirationTtl: CACHE_SECONDS });
    return { state: "ok", view };
  } catch (e) {
    logEvent("admin_plausible_failed", { error: String(e) });
    return { state: "error", reason: String(e instanceof Error ? e.message : e).slice(0, 120) };
  }
}
