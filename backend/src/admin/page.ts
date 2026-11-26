import { escapeHtml as esc } from "../util.js";
import type { AccountIndexRow } from "../store/AccountStore.js";
import type { PlusLink, PlusLinkUse } from "../store/plusLinks.js";
import { deviceLabel, lastSeen, overview, planView } from "./accounts.js";
import type { SignupRow, SignupView } from "./signups.js";
import {
  SERIES_DAYS, agentMix, change, clientMix, cumulative, lastDays, perDay, providerMix, snapshotSeries, weeklyCohorts, windowChange,
  type MetricDay, type Tally,
} from "./metrics.js";
import type { Row as TrafficRow, TrafficResult } from "./plausible.js";
import type { MacRelease } from "./releases.js";

// The admin page as one HTML document: no script, no external file. Every
// value goes through `esc`.

export const PAGE_HEADERS = {
  "Content-Type": "text/html; charset=utf-8",
  "Cache-Control": "no-store",
  "Referrer-Policy": "same-origin",
  "X-Robots-Tag": "noindex, nofollow",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
};

export interface AdminView {
  admin: string;
  accounts: AccountIndexRow[];
  links: PlusLink[];
  uses: PlusLinkUse[];
  signups: SignupView | null;
  query: string;
  emailSignups: SignupRow[];
  emailUserId: string | null;
  /// Daily snapshots, oldest first (ADR 0050).
  history: MetricDay[];
  traffic: TrafficResult;
  releases: MacRelease[] | null;
  newUrl?: string;
  error?: string;
  now: number;
}

const CSS = `
  :root { color-scheme: light dark; --bg: #fafafa; --card: #fff; --line: #e5e5e5; --text: #1a1a1a; --dim: #6b6b6b; --ok: #1d7a3d; --warn: #a15c00; }
  @media (prefers-color-scheme: dark) { :root { --bg: #0a0a0a; --card: #161616; --line: #2a2a2a; --text: #f5f5f5; --dim: #999; --ok: #57c77d; --warn: #e0a04a; } }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.45 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
  main { max-width: 1180px; margin: 0 auto; padding: 24px 16px 64px; }
  h1 { font-size: 20px; margin: 0; } h2 { font-size: 16px; margin: 32px 0 10px; }
  header, .bar { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; justify-content: space-between; }
  .dim { color: var(--dim); } .ok { color: var(--ok); } .warn { color: var(--warn); }
  .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 8px; margin-top: 16px; }
  .tile, .box { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; }
  .tile b { display: block; font-size: 20px; font-variant-numeric: tabular-nums; }
  .scroll { overflow-x: auto; background: var(--card); border: 1px solid var(--line); border-radius: 10px; }
  table { border-collapse: collapse; width: 100%; } th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
  tr:last-child td { border-bottom: 0; } th { font-weight: 600; color: var(--dim); white-space: nowrap; }
  td.n { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  code { font: 12px ui-monospace, Menlo, monospace; overflow-wrap: anywhere; }
  form { display: inline-flex; flex-wrap: wrap; gap: 8px; align-items: end; margin: 0; }
  label { display: grid; gap: 3px; font-size: 12px; color: var(--dim); }
  input, select, button { font: inherit; padding: 6px 9px; border: 1px solid var(--line); border-radius: 7px; background: var(--card); color: var(--text); }
  button { cursor: pointer; } summary { cursor: pointer; }
  .box { margin: 12px 0; } .cols { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; }
  nav { display: flex; flex-wrap: wrap; gap: 4px 14px; margin-top: 10px; font-size: 13px; } a { color: inherit; }
  .kpis { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 8px; margin-top: 16px; }
  .kpi { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; display: grid; gap: 2px; }
  .kpi b { font-size: 24px; font-variant-numeric: tabular-nums; } .kpi svg { width: 100%; height: 30px; color: var(--dim); }
  .delta { font-size: 12px; font-variant-numeric: tabular-nums; } .up { color: var(--ok); } .down { color: var(--warn); }
  .funnel td.bar { width: 45%; } .meter { height: 8px; border-radius: 4px; background: var(--dim); opacity: .55; min-width: 2px; }
  .chart { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; }
  .chart svg { width: 100%; height: 90px; color: var(--dim); display: block; }
  .chart rect:hover { opacity: .7; }
  .grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px; }
`;

const when = (ms: number | null, now: number): string => {
  if (ms === null || ms === 0) return "never";
  const days = Math.floor((now - ms) / 86_400_000);
  return days <= 0 ? "today" : days === 1 ? "yesterday" : days < 60 ? `${days} days ago` : new Date(ms).toISOString().slice(0, 10);
};
const day = (ms: number | null) => (ms === null ? "no end" : new Date(ms).toISOString().slice(0, 10));
const size = (bytes: number) => bytes >= 1024 ** 3 ? `${(bytes / 1024 ** 3).toFixed(1)} GB`
  : bytes >= 1024 ** 2 ? `${(bytes / 1024 ** 2).toFixed(1)} MB` : `${Math.ceil(bytes / 1024)} KB`;
const short = (userId: string) => userId.slice(0, 10);
const tile = (n: number | string, label: string) => `<div class="tile"><b>${esc(String(n))}</b><span class="dim">${esc(label)}</span></div>`;
const table = (head: string[], rows: string[], empty: string) =>
  rows.length ? `<div class="scroll"><table><thead><tr>${head.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead><tbody>${rows.join("")}</tbody></table></div>`
    : `<p class="dim">${esc(empty)}</p>`;

const lasts = (selected: string) =>
  `<select name="months">${[["1", "1 month"], ["3", "3 months"], ["6", "6 months"], ["12", "12 months"], ["24", "24 months"], ["forever", "no end"]]
    .map(([v, t]) => `<option value="${v}"${v === selected ? " selected" : ""}>${t}</option>`).join("")}</select>`;
const planSelect = (selected: "plus" | "pro") =>
  `<select name="plan">${(["plus", "pro"] as const).map((p) => `<option value="${p}"${p === selected ? " selected" : ""}>${PLAN[p]}</option>`).join("")}</select>`;
const PLAN = { plus: "Plus", pro: "Pro" };

function matches(r: AccountIndexRow, v: AdminView): boolean {
  if (!v.query) return true;
  if (v.query.includes("@")) return r.userId === v.emailUserId;
  const q = v.query.toLowerCase();
  return r.userId.toLowerCase().startsWith(q)
    || planView(r.summary, v.now).word === q
    || planView(r.summary, v.now).plan === q
    || r.providers.includes(q)
    || r.plusLinks.some((l) => l.label.toLowerCase().includes(q));
}

function accountRow(r: AccountIndexRow, now: number): string {
  const s = r.summary;
  const plan = planView(s, now);
  const seen = lastSeen(s);
  const devices = (s?.devices ?? []).map((d) => `<div>${esc(deviceLabel(d))} <span class="dim">${esc(when(d.lastSeen, now))}</span></div>`).join("");
  const agents = (s?.agents ?? []).map((a) => `<div>${esc(a.client)} <span class="dim">${esc(when(a.lastUsed, now))}</span></div>`).join("");
  const hooks = s && s.webhooks > 0 ? `<div class="${s.failingWebhooks ? "warn" : "dim"}">${s.webhooks} webhooks, ${s.failingWebhooks} failing</div>` : "";
  const give = `<details><summary class="dim">Give a plan</summary><form method="post" action="/admin/accounts/${esc(r.userId)}/plan">${planSelect("pro")}${lasts("forever")}<button>Give</button></form>${
    plan.adminGrant ? ` <form method="post" action="/admin/accounts/${esc(r.userId)}/plan/end"><button>Take back</button></form>` : ""}</details>`;
  const planText = `${plan.plan ? `${PLAN[plan.plan]}, ` : ""}${plan.word}${plan.period ? `, ${plan.period}` : ""}`;
  const until = plan.word === "paid" || plan.word === "granted" || plan.word === "trial" ? `<div class="dim">${plan.until === null ? "no end" : `until ${day(plan.until)}`}</div>` : "";
  return `<tr>
    <td><details><summary><code>${esc(short(r.userId))}</code></summary><code>${esc(r.userId)}</code></details>${r.plusLinks.map((l) => `<div class="dim">${esc(l.label)}</div>`).join("")}</td>
    <td>${esc(r.providers.join(", ") || "not seen yet")}</td>
    <td><span class="${plan.word === "paid" ? "ok" : plan.word === "lapsed" ? "warn" : ""}">${esc(planText)}</span>${until}${give}</td>
    <td>${esc(when(r.createdAt, now))}</td>
    <td>${esc(when(seen, now))}<div class="dim">${s?.signedIn ? "signed in" : "signed out"}</div></td>
    <td class="n">${s ? `${s.openTasks}<div class="dim">${s.closedTasks} closed</div>` : ""}</td>
    <td class="n">${s ? `${s.files}<div class="dim">${esc(size(s.fileBytes))}</div>` : ""}</td>
    <td>${devices}</td>
    <td>${agents}${hooks}${s?.agentChangesWeek ? `<div class="dim">${s.agentChangesWeek} changes this week</div>` : ""}</td>
    <td class="dim">${r.refreshedAt ? esc(when(r.refreshedAt, now)) : "waiting"}</td>
  </tr>`;
}

function linkRow(l: PlusLink, uses: PlusLinkUse[]): string {
  const state = l.revokedAt ? "revoked" : l.closedAt ? "closed" : l.useCount >= l.maxUses ? "used up" : "open";
  const people = uses.filter((u) => u.linkId === l.id).map((u) => `<div><code>${esc(short(u.userId))}</code> <span class="dim">${u.revokedAt ? "revoked" : esc(day(u.expiresAt))}</span>
    ${u.revokedAt ? "" : `<form method="post" action="/admin/links/${esc(l.id)}/revoke"><input type="hidden" name="who" value="${esc(u.userId)}"><button>Take back</button></form>`}</div>`).join("");
  const close = state === "open" ? `<form method="post" action="/admin/links/${esc(l.id)}/close"><button>Close</button></form> ` : "";
  const revoke = l.revokedAt ? "" : `<details><summary>Take back from everyone</summary><form method="post" action="/admin/links/${esc(l.id)}/revoke"><input type="hidden" name="who" value="all"><button>Yes, end the plan for all ${l.useCount}</button></form></details>`;
  return `<tr><td>${esc(l.label)}</td><td>${PLAN[l.plan]}</td><td>${l.months === null ? "no end" : `${l.months} months`}</td><td class="n">${l.useCount} of ${l.maxUses}</td>
    <td><span class="${state === "open" ? "ok" : "dim"}">${state}</span></td><td>${day(l.createdAt)}</td><td>${people}</td><td>${close}${revoke}</td></tr>`;
}

const counts = (title: string, rows: { name: string; n: number }[]) =>
  `<div><b>${esc(title)}</b>${rows.map((r) => `<div>${esc(String(r.name))} <span class="dim">${r.n}</span></div>`).join("") || '<div class="dim">none</div>'}</div>`;

const signupTable = (rows: SignupRow[]) => table(["Email", "List", "Screens", "Task apps", "AI", "Page", "Date"], rows.map((r) =>
  `<tr>${[r.email, r.list, r.platforms, r.tools, r.agents, r.source, r.created_at.slice(0, 10)].map((x) => `<td>${esc(x.replace(/[[\]"]/g, ""))}</td>`).join("")}</tr>`), "No signups.");


// ---- growth (ADR 0050) ----

const fmt = (n: number) => n >= 10_000 ? `${(n / 1000).toFixed(n >= 100_000 ? 0 : 1)}k` : n.toLocaleString("en-US");
const pct = (x: number | null, digits = 0) => (x === null || !Number.isFinite(x) ? "n/a" : `${(x * 100).toFixed(digits)}%`);
const ratio = (a: number, b: number) => (b === 0 ? null : a / b);

/// A single-series line. Hover a point for its day and value (SVG title, no script).
function sparkline(values: (number | null)[], days: string[]): string {
  const pts = values.map((v, i) => [i, v] as const).filter((p): p is readonly [number, number] => p[1] !== null);
  if (pts.length < 2) return `<svg viewBox="0 0 100 30" aria-hidden="true"></svg>`;
  const max = Math.max(...pts.map((p) => p[1])), min = Math.min(...pts.map((p) => p[1]));
  const x = (i: number) => (i / Math.max(1, values.length - 1)) * 100;
  const y = (v: number) => (max === min ? 15 : 27 - ((v - min) / (max - min)) * 24);
  const line = pts.map(([i, v]) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`).join(" ");
  const dots = pts.map(([i, v]) => `<circle cx="${x(i).toFixed(2)}" cy="${y(v).toFixed(2)}" r="2.2" fill="transparent"><title>${esc(days[i])}: ${v}</title></circle>`).join("");
  return `<svg viewBox="0 0 100 30" preserveAspectRatio="none" role="img" aria-label="last ${values.length} days"><polyline points="${line}" fill="none" stroke="currentColor" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round"/>${dots}</svg>`;
}

/// Daily bars, one series. Hover a bar for its day and value.
function bars(values: number[], days: string[], unit: string): string {
  const max = Math.max(1, ...values);
  const w = 100 / values.length;
  const rects = values.map((v, i) => {
    const h = (v / max) * 86;
    return `<rect x="${(i * w + 0.3).toFixed(2)}" y="${(88 - h).toFixed(2)}" width="${(w - 0.6).toFixed(2)}" height="${Math.max(h, v ? 1 : 0).toFixed(2)}" rx="0.6" fill="currentColor"><title>${esc(days[i])}: ${v} ${esc(unit)}</title></rect>`;
  }).join("");
  return `<svg viewBox="0 0 100 90" preserveAspectRatio="none" role="img" aria-label="${esc(unit)} per day">${rects}<line x1="0" x2="100" y1="88.5" y2="88.5" stroke="currentColor" stroke-width="0.4" opacity=".5"/></svg>
    <div class="bar dim" style="font-size:12px"><span>${esc(days[0] ?? "")}</span><span>max ${max}</span><span>${esc(days[days.length - 1] ?? "")}</span></div>`;
}

const deltaText = (abs: number | null, rel: number | null, label: string) => {
  if (abs === null) return `<span class="delta dim">no ${esc(label)} yet</span>`;
  const cls = abs > 0 ? "up" : abs < 0 ? "down" : "dim";
  return `<span class="delta ${cls}">${abs > 0 ? "+" : ""}${fmt(abs)}${rel === null ? "" : ` (${rel > 0 ? "+" : ""}${pct(rel)})`} ${esc(label)}</span>`;
};

/// A headline number with its change against 7 days before and a 30-day line.
function kpi(label: string, value: number | string, series: (number | null)[], days: string[], delta?: { abs: number | null; rel: number | null; label: string }) {
  const c = delta ?? (() => { const d = change(series); return { abs: d?.abs ?? null, rel: d?.pct ?? null, label: "vs 7 days ago" }; })();
  return `<div class="kpi"><span class="dim">${esc(label)}</span><b>${esc(typeof value === "number" ? fmt(value) : value)}</b>${deltaText(c.abs, c.rel, c.label)}${sparkline(series, days)}</div>`;
}

function funnel(title: string, steps: { name: string; n: number; note?: string }[]): string {
  const top = Math.max(1, steps[0]?.n ?? 0);
  const rows = steps.map((s, i) => {
    const prev = i === 0 ? null : steps[i - 1].n;
    return `<tr><td>${esc(s.name)}${s.note ? `<div class="dim">${esc(s.note)}</div>` : ""}</td><td class="n">${fmt(s.n)}</td>
      <td class="n dim">${prev === null ? "" : pct(ratio(s.n, prev))}</td>
      <td class="bar"><div class="meter" style="width:${Math.min(100, (s.n / top) * 100).toFixed(1)}%"></div></td></tr>`;
  });
  return `<div><b>${esc(title)}</b>${table(["Step", "Count", "Of step before", ""], rows, "No data.").replace('class="scroll"', 'class="scroll funnel"')}</div>`;
}

const tallyList = (title: string, rows: (Tally | TrafficRow)[], unit = "") =>
  `<div><b>${esc(title)}</b>${rows.slice(0, 12).map((r) => `<div>${esc(String(r.name))} <span class="dim">${fmt("visitors" in r ? r.visitors : r.n)}${unit}</span></div>`).join("") || '<div class="dim">none</div>'}</div>`;

const duration = (s: number) => (s >= 60 ? `${Math.floor(s / 60)}m ${Math.round(s % 60)}s` : `${Math.round(s)}s`);

function websiteSection(t: TrafficResult, signupsByDay: Map<string, number>): string {
  if (t.state === "off") {
    return `<p class="warn">Plausible is not connected. Make a Stats API key in Plausible (Account settings ▸ API keys) and store it with <code>wrangler secret put PLAUSIBLE_API_KEY</code>.</p>`;
  }
  if (t.state === "error") return `<p class="warn">Plausible does not answer (${esc(t.reason)}). The rest of the page is current.</p>`;
  const v = t.view;
  const days = v.days.map((d) => d.day);
  const visitors = v.days.map((d) => d.visitors);
  const w = windowChange(visitors);
  const signups = days.map((d) => signupsByDay.get(d) ?? 0);
  const goal = (name: string) => v.goals.find((g) => g.name === name);
  const goalRows = v.goals.map((g) => `<tr><td>${esc(g.name)}</td><td class="n">${fmt(g.visitors)}</td><td class="n">${fmt(g.n)}</td><td class="n">${g.rate === null ? "n/a" : `${g.rate.toFixed(2)}%`}</td></tr>`);
  return `<div class="kpis">
    ${kpi("Visitors, 7 days", w.now, visitors, days, { abs: w.now - w.before, rel: w.pct, label: "vs the 7 days before" })}
    <div class="kpi"><span class="dim">Visitors, 30 days</span><b>${fmt(v.totals.visitors)}</b><span class="delta dim">${fmt(v.totals.pageviews)} pageviews, ${fmt(v.totals.visits)} visits</span></div>
    <div class="kpi"><span class="dim">Bounce rate</span><b>${Math.round(v.totals.bounceRate)}%</b><span class="delta dim">visit ${duration(v.totals.visitDuration)} on average</span></div>
    <div class="kpi"><span class="dim">Signup rate, 30 days</span><b>${goal("Signup")?.rate === undefined || goal("Signup")?.rate === null ? "n/a" : `${goal("Signup")!.rate!.toFixed(2)}%`}</b><span class="delta dim">of visitors leave an email</span></div>
    <div class="kpi"><span class="dim">Download clicks, 30 days</span><b>${fmt(goal("Download click")?.n ?? 0)}</b><span class="delta dim">${fmt(goal("Download click")?.visitors ?? 0)} visitors</span></div>
  </div>
  <div class="grid2" style="margin-top:12px">
    <div class="chart"><b>Visitors per day</b>${bars(visitors, days, "visitors")}</div>
    <div class="chart"><b>Signups per day</b>${bars(signups, days, "signups")}</div>
  </div>
  <h3>Calls to action, 30 days</h3>
  ${table(["Goal", "Visitors", "Events", "Conversion"], goalRows, "No goals counted.")}
  ${v.missingGoals.length ? `<p class="warn">Plausible has no goal for: ${esc(v.missingGoals.join(", "))}. Add each as a custom-event goal in the site settings, or it is not counted.</p>` : ""}
  <div class="box cols">${tallyList("Sources", v.sources)}${tallyList("Pages", v.pages)}${tallyList("Countries", v.countries)}${tallyList("Download clicks by platform", v.downloads)}${tallyList("List-keeper CTA by placement", v.ctaPlacements)}</div>
  <p class="dim">From Plausible, ${esc(v.site)}, ${esc(when(v.fetchedAt, Date.now()))}; cached for 10 minutes. <a href="https://plausible.io/${esc(v.site)}">Open Plausible</a></p>`;
}

function growthSection(v: AdminView): string {
  const days = lastDays(SERIES_DAYS, v.now);
  const o = overview(v.accounts, v.now);
  const created = v.accounts.map((r) => r.createdAt);
  const totalAccounts = cumulative(created, days);
  const newPerDay = perDay(created, days);
  const newWin = windowChange(perDay(created, lastDays(14, v.now)));
  const snap = (field: string) => {
    const s = snapshotSeries(v.history, field, days);
    s[s.length - 1] = (o as Record<string, number>)[field] ?? s[s.length - 1];
    return s;
  };
  const byDay = new Map((v.signups?.byDay ?? []).map((d) => [d.name, d.n]));
  const signupDays = days.map((d) => byDay.get(d) ?? 0);
  const total = v.signups?.total ?? 0;
  let left = total - signupDays.reduce((a, b) => a + b, 0);
  const signupTotal = signupDays.map((n) => (left += n));
  const signupWin = windowChange(signups14(byDay, v.now));
  const traffic = v.traffic.state === "ok" ? v.traffic.view : null;
  const stick = ratio(o.activeToday, o.activeThisMonth);
  return `<div class="kpis">
    ${kpi("Accounts", o.accounts, totalAccounts, days)}
    ${kpi("New accounts, 7 days", newWin.now, newPerDay, days, { abs: newWin.now - newWin.before, rel: newWin.pct, label: "vs the 7 days before" })}
    ${kpi("Active, 7 days (WAU)", o.activeThisWeek, snap("activeThisWeek"), days)}
    ${kpi("Active, 30 days (MAU)", o.activeThisMonth, snap("activeThisMonth"), days)}
    ${kpi("Activated", o.activated, snap("activated"), days)}
    ${kpi("Paying", o.paid, snap("paid"), days)}
    ${kpi("Website signups", total, signupTotal, days)}
    ${kpi("Signups, 7 days", signupWin.now, signupDays, days, { abs: signupWin.now - signupWin.before, rel: signupWin.pct, label: "vs the 7 days before" })}
  </div>
  <div class="tiles">
    ${tile(o.activeToday, "active today (DAU)")}${tile(pct(stick), "DAU / MAU")}${tile(pct(ratio(o.activated, o.accounts)), "activated")}
    ${tile(pct(ratio(o.activeThisMonth, o.accounts)), "of accounts active in 30 days")}${tile(pct(ratio(o.trialsConverted, o.trialsStarted)), "trial to paid")}
    ${tile(o.withAgent, "with an agent")}${tile(o.agentChangesWeek, "agent changes, 7 days")}${tile(o.twoDevices, "with 2+ devices")}
  </div>
  <p class="dim">Accounts and signups reach back to the first day. Active, activated and paying are kept once a day since ${esc(v.history[0]?.day ?? "today")}, so their change shows after a week. Activated: completed at least one task.</p>
  <div class="grid2" style="margin-top:12px">
    ${funnel("Website, last 30 days", traffic ? [
      { name: "Visitors", n: traffic.totals.visitors },
      { name: "Left an email", n: traffic.goals.find((g) => g.name === "Signup")?.visitors ?? 0, note: "Plausible goal Signup" },
      { name: "Clicked a download", n: traffic.goals.find((g) => g.name === "Download click")?.visitors ?? 0 },
    ] : [{ name: "Visitors", n: 0, note: "Plausible is not connected" }])}
    ${funnel("Product, every account", [
      { name: "Accounts", n: o.accounts },
      { name: "Activated", n: o.activated, note: "completed a task" },
      { name: "Two or more devices", n: o.twoDevices },
      { name: "Connected an agent", n: o.withAgent },
      { name: "Started a trial", n: o.trialsStarted },
      { name: "Paying now", n: o.paid },
    ])}
  </div>`;
}

const signups14 = (byDay: Map<string, number>, now: number) => lastDays(14, now).map((d) => byDay.get(d) ?? 0);

function retentionSection(v: AdminView): string {
  const rows = weeklyCohorts(v.accounts, 8, v.now).map((c) => `<tr><td>${esc(c.week)}</td><td class="n">${c.size}</td>
    <td class="n">${pct(ratio(c.activated, c.size))}</td><td class="n">${pct(ratio(c.activeWeek, c.size))}</td>
    <td class="n">${pct(ratio(c.twoDevices, c.size))}</td><td class="n">${pct(ratio(c.plan, c.size))}</td></tr>`);
  return `${table(["Week started", "Accounts", "Activated", "Active this week", "2+ devices", "Paying"], rows, "No accounts yet.")}
  <p class="dim">Each row is the accounts that started that week (Monday, UTC), as they are now.</p>`;
}

function clientsSection(v: AdminView): string {
  const mix = clientMix(v.accounts, v.now);
  const mac = v.releases === null ? `<div><b>Mac downloads</b><div class="warn">GitHub does not answer</div></div>`
    : `<div><b>Mac downloads</b>${v.releases.map((r) => `<div>${esc(r.tag)} <span class="dim">${fmt(r.installs)} downloads, ${fmt(r.appcast)} update checks</span></div>`).join("") || '<div class="dim">no releases</div>'}
      <div class="dim">${fmt(v.releases.reduce((n, r) => n + r.installs, 0))} in all</div></div>`;
  return `<div class="box cols">${tallyList("Devices, 30 days", mix.platforms)}${tallyList("Versions, 30 days", mix.versions)}${tallyList("Agents", agentMix(v.accounts), " accounts")}${tallyList("Sign-in", providerMix(v.accounts), " accounts")}${mac}</div>
  <p class="dim">App Store and Google Play installs, revenue and renewals are not here yet (docs/ADMIN_CONSOLE_SPEC.md).</p>`;
}

export function renderAdmin(v: AdminView): string {
  const o = overview(v.accounts, v.now);
  const shown = v.accounts.filter((r) => matches(r, v));
  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Septena admin</title><style>${CSS}</style></head>
<body><main>
<header><h1>Septena admin</h1><span class="dim">${esc(v.admin)}</span>
  <form method="post" action="/admin/refresh"><button>Refresh counts</button></form></header>
<nav><a href="#growth">Growth</a><a href="#website">Website</a><a href="#retention">Retention</a><a href="#clients">Clients</a><a href="#plans">Plans</a><a href="#links">Plan links</a><a href="#accounts">Accounts</a><a href="#signups">Signups</a></nav>
${v.error ? `<div class="box warn">${esc(v.error)}</div>` : ""}
${v.newUrl ? `<div class="box"><b>New plan link</b><p><code>${esc(v.newUrl)}</code></p><span class="dim">Copy it now. Only a hash is stored, so this page cannot show it again.</span></div>` : ""}

<h2 id="growth">Growth</h2>
${growthSection(v)}

<h2 id="website">Website</h2>
${websiteSection(v.traffic, new Map((v.signups?.byDay ?? []).map((d) => [d.name, d.n])))}

<h2 id="retention">Retention by week</h2>
${retentionSection(v)}

<h2 id="clients">Clients and agents</h2>
${clientsSection(v)}

<h2 id="plans">Plans and usage</h2>
<div class="tiles">
  ${tile(o.paid, `paid (${o.paidYear} year, ${o.paidMonth} month)`)}${tile(o.granted, `granted (${o.pro} Pro)`)}${tile(o.onTrial, "on trial")}${tile(o.trialsConverted, `bought, of ${o.trialsStarted} trials`)}${tile(o.lapsed, "lapsed")}
  ${tile(o.openTasks, "open tasks")}${tile(o.closedTasks, "closed tasks")}${tile(o.files, `files (${size(o.fileBytes)})`)}
</div>
<p class="dim">Counts refresh hourly, each account at most a day old. Revenue and renewals are in App Store Connect.</p>

<h2 id="links">Plan links</h2>
<form method="post" action="/admin/links">
  <label>Label<input name="label" maxlength="60" required placeholder="Anna, press"></label>
  <label>Plan${planSelect("plus")}</label>
  <label>Lasts${lasts("12")}</label>
  <label>People<input name="maxUses" type="number" min="1" max="500" value="1" required></label>
  <button>Make a link</button>
</form>
<p class="dim">Close stops new people and keeps the plan for those who have it. Take back ends it.</p>
${table(["Label", "Plan", "Lasts", "Used", "State", "Made", "Accounts", ""], v.links.map((l) => linkRow(l, v.uses)), "No links yet.")}

<h2 id="accounts">Accounts</h2>
<form method="post" action="/admin/search"><label>Account id, link label, plan, sign-in or email<input name="q" value="${esc(v.query)}" maxlength="200"></label><button>Search</button></form>
${v.query ? ` <a href="/admin">Show all</a>` : ""}
<p class="dim">${shown.length} of ${v.accounts.length}. An account has no email unless its owner signed in with one.</p>
${table(["Account", "Sign-in", "Plan", "Since", "Last seen", "Tasks", "Files", "Devices", "Agents", "Counted"], shown.map((r) => accountRow(r, v.now)), v.query ? "No account matches." : "No accounts counted yet. Press Refresh counts.")}
${v.query.includes("@") ? `<h2>Signups with this email</h2>${signupTable(v.emailSignups)}` : ""}

<h2 id="signups">Website signups</h2>
${v.signups ? `<div class="box cols">${counts("List", v.signups.byList)}${counts("Screens", v.signups.byPlatform)}${counts("Task apps", v.signups.byTool)}${counts("Week of", v.signups.byWeek)}${counts("Page", v.signups.bySource)}</div>
<p class="dim">${v.signups.total} signups from ${v.signups.people} people.</p>
<p><a href="/admin/signups.csv">Download all as CSV</a></p>${signupTable(v.signups.latest)}` : `<p class="warn">The signup database does not answer.</p>`}
</main></body></html>`;
}
