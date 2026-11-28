import type { Env } from "../env.js";
import { logEvent } from "../util.js";
import { accountStoreFor, type AccountIndexRow } from "../store/AccountStore.js";
import { deviceVersion, isActivated, lastSeen, marketingVersion, overview, planView, platformName } from "./accounts.js";
import { signupTotals } from "./signups.js";
import { SETTINGS_REGISTRY } from "../generated/registries.js";

// Growth for the admin page (ADR 0059). Two kinds of history:
// - Series that the data can rebuild (accounts and signups by the day they
//   started) come from the rows themselves, so they reach back to day one.
// - Counts that only exist "now" (active, paid, trial) are kept as one
//   snapshot per UTC day in AccountStore `metric_days`, written by the cron.
// Counts only: nothing here reads or keeps content (ADR 0043).

const DAY_MS = 86_400_000;
export const SERIES_DAYS = 30;

export const dayKey = (ms: number) => new Date(ms).toISOString().slice(0, 10);

export type Snapshot = ReturnType<typeof overview> & { signups: number; signupsWeek: number } & Record<string, number>;

/// Writes today's snapshot. Runs from the hourly cron after the sweep.
export async function recordMetrics(env: Env, now = Date.now()): Promise<void> {
  const accounts = accountStoreFor(env);
  if (!accounts) return;
  const [rows, signups] = await Promise.all([accounts.listAccounts(), signupTotals(env, now)]);
  const snapshot: Snapshot = {
    ...overview(rows, now), signups: signups?.total ?? 0, signupsWeek: signups?.week ?? 0,
    ...appearanceSnapshot(appearanceMix(rows, now)),
  };
  await accounts.saveMetricDay(dayKey(now), snapshot);
  logEvent("admin_metrics", { day: dayKey(now), accounts: snapshot.accounts });
}

export interface MetricDay { day: string; data: Record<string, number> }

/// The last `days` UTC day keys, oldest first, today last.
export function lastDays(days: number, now = Date.now()): string[] {
  return Array.from({ length: days }, (_, i) => dayKey(now - (days - 1 - i) * DAY_MS));
}

/// A count per day, from timestamps: how many started that day.
export function perDay(times: number[], days: string[]): number[] {
  const index = new Map(days.map((d, i) => [d, i]));
  const out = days.map(() => 0);
  for (const t of times) {
    const i = index.get(dayKey(t));
    if (i !== undefined) out[i] += 1;
  }
  return out;
}

/// A running total per day: everything that started on or before the day.
export function cumulative(times: number[], days: string[]): number[] {
  const sorted = [...times].sort((a, b) => a - b);
  let i = 0;
  return days.map((d) => {
    const end = Date.parse(`${d}T00:00:00Z`) + DAY_MS;
    while (i < sorted.length && sorted[i] < end) i += 1;
    return i;
  });
}

/// One snapshot field per day; a day with no snapshot is null.
export function snapshotSeries(history: MetricDay[], field: string, days: string[]): (number | null)[] {
  const byDay = new Map(history.map((h) => [h.day, h.data[field]]));
  return days.map((d) => (typeof byDay.get(d) === "number" ? (byDay.get(d) as number) : null));
}

/// The change against the value `back` days before the last one, or null when
/// there is no value that far back.
export function change(series: (number | null)[], back = 7): { abs: number; pct: number | null } | null {
  const now = series[series.length - 1];
  const then = series[series.length - 1 - back];
  if (now === null || now === undefined || then === null || then === undefined) return null;
  return { abs: now - then, pct: then === 0 ? null : (now - then) / then };
}

/// The sum of the last `n` values against the `n` values before them.
export function windowChange(series: number[], n = 7): { now: number; before: number; pct: number | null } {
  const now = series.slice(-n).reduce((a, b) => a + b, 0);
  const before = series.slice(-2 * n, -n).reduce((a, b) => a + b, 0);
  return { now, before, pct: before === 0 ? null : (now - before) / before };
}

// ---- cohorts, clients, agents ----

export interface Cohort { week: string; size: number; activated: number; activeWeek: number; twoDevices: number; plan: number }

/// Accounts by the week (Monday, UTC) they started, newest first.
export function weeklyCohorts(rows: AccountIndexRow[], weeks = 8, now = Date.now()): Cohort[] {
  const monday = (ms: number) => {
    const d = new Date(ms);
    d.setUTCHours(0, 0, 0, 0);
    d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
    return dayKey(d.getTime());
  };
  const out = new Map<string, Cohort>();
  for (let i = 0; i < weeks; i += 1) {
    const w = monday(now - i * 7 * DAY_MS);
    out.set(w, { week: w, size: 0, activated: 0, activeWeek: 0, twoDevices: 0, plan: 0 });
  }
  for (const r of rows) {
    const c = out.get(monday(r.createdAt));
    if (!c) continue;
    c.size += 1;
    if (isActivated(r.summary)) c.activated += 1;
    if (now - (lastSeen(r.summary) ?? 0) < 7 * DAY_MS) c.activeWeek += 1;
    if ((r.summary?.devices.length ?? 0) >= 2) c.twoDevices += 1;
    if (planView(r.summary, now).word === "paid") c.plan += 1;
  }
  return [...out.values()];
}

export interface Tally { name: string; n: number }

const tally = (names: string[]): Tally[] => {
  const m = new Map<string, number>();
  for (const n of names) m.set(n, (m.get(n) ?? 0) + 1);
  return [...m.entries()].map(([name, n]) => ({ name, n })).sort((a, b) => b.n - a.n || a.name.localeCompare(b.name));
};

/// Devices seen in the last 30 days: by platform, and by platform and
/// version (marketing version; the builds are counted inside it).
export function clientMix(rows: AccountIndexRow[], now = Date.now()) {
  const devices = rows.flatMap((r) => r.summary?.devices ?? []).filter((d) => now - d.lastSeen < 30 * DAY_MS);
  const release = (d: { client: string | null; version: string | null }) => {
    const v = deviceVersion(d);
    return v ? `${platformName(d.client)} ${marketingVersion(v)}` : `${platformName(d.client)}, older build`;
  };
  return {
    platforms: tally(devices.map((d) => platformName(d.client))),
    versions: tally(devices.map(release)).slice(0, 12),
    builds: tally(devices.flatMap((d) => {
      const v = deviceVersion(d);
      return v ? [`${platformName(d.client)} ${v}`] : [];
    })),
  };
}

export interface Release { name: string; devices: number; firstSeen: number; lastSeen: number }

/// Each platform and version that a device ran in the last 90 days: how many
/// devices ran it and when the first one did. Newest release first.
export function releaseAdoption(rows: AccountIndexRow[]): Release[] {
  const m = new Map<string, Release>();
  for (const v of rows.flatMap((r) => r.summary?.versions ?? [])) {
    const name = `${platformName(v.client)} ${marketingVersion(v.version)}`;
    const r = m.get(name) ?? { name, devices: 0, firstSeen: v.firstSeen, lastSeen: v.lastSeen };
    r.devices += 1;
    r.firstSeen = Math.min(r.firstSeen, v.firstSeen);
    r.lastSeen = Math.max(r.lastSeen, v.lastSeen);
    m.set(name, r);
  }
  return [...m.values()].sort((a, b) => b.firstSeen - a.firstSeen);
}

/// Accounts per agent client (an account counts once per client).
export function agentMix(rows: AccountIndexRow[]): Tally[] {
  return tally(rows.flatMap((r) => [...new Set((r.summary?.agents ?? []).map((a) => a.client))]));
}

/// Sign-in providers per account.
export function providerMix(rows: AccountIndexRow[]): Tally[] {
  return tally(rows.flatMap((r) => (r.providers.length ? r.providers : ["not seen yet"])));
}

// ---- appearance (#859) ----

export interface AppearanceMix {
  /// Active signed-in accounts with an appearance in their summary.
  accounts: number;
  accentColor: Tally[];
  canvasTexture: Tally[];
  /// Intensity and motion count only the accounts with a texture on.
  textureIntensity: Tally[];
  textureMotion: Tally[];
}

/// The intensity bucket: the registry default, below it, above it, or "other".
export function intensityBucket(v: number | "other"): string {
  const d = SETTINGS_REGISTRY.keys.textureIntensity.default;
  if (v === "other") return "other";
  return v === d ? "default" : v < d ? "lower" : "higher";
}

/// The appearance choices of the accounts seen in the last 30 days. An
/// account with no appearance in its summary (not signed in, or a summary
/// from before #859) is not counted. Counts only (ADR 0043).
export function appearanceMix(rows: AccountIndexRow[], now = Date.now()): AppearanceMix {
  const looks = rows
    .filter((r) => now - (lastSeen(r.summary) ?? 0) < 30 * DAY_MS)
    .flatMap((r) => (r.summary?.appearance ? [r.summary.appearance] : []));
  const textured = looks.filter((a) => a.canvasTexture !== "none");
  return {
    accounts: looks.length,
    accentColor: tally(looks.map((a) => a.accentColor)),
    canvasTexture: tally(looks.map((a) => a.canvasTexture)),
    textureIntensity: tally(textured.map((a) => intensityBucket(a.textureIntensity))),
    textureMotion: tally(textured.map((a) => a.textureMotion)),
  };
}

/// The mix as flat snapshot fields: `appearance.accounts` and
/// `appearance.<setting>.<value>`.
export function appearanceSnapshot(mix: AppearanceMix): Record<string, number> {
  const out: Record<string, number> = { "appearance.accounts": mix.accounts };
  for (const key of ["accentColor", "canvasTexture", "textureIntensity", "textureMotion"] as const) {
    for (const t of mix[key]) out[`appearance.${key}.${t.name}`] = t.n;
  }
  return out;
}
