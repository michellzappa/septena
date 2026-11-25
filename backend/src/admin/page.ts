import { escapeHtml as esc } from "../util.js";
import type { AccountIndexRow } from "../store/AccountStore.js";
import type { PlusLink, PlusLinkUse } from "../store/plusLinks.js";
import { deviceLabel, lastSeen, overview, planView } from "./accounts.js";
import type { SignupRow, SignupView } from "./signups.js";

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

function matches(r: AccountIndexRow, v: AdminView): boolean {
  if (!v.query) return true;
  if (v.query.includes("@")) return r.userId === v.emailUserId;
  const q = v.query.toLowerCase();
  return r.userId.toLowerCase().startsWith(q)
    || planView(r.summary, v.now).word === q
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
  const planText = `${plan.word}${plan.period ? `, ${plan.period}` : ""}`;
  const until = plan.word === "paid" || plan.word === "granted" || plan.word === "trial" ? `<div class="dim">${plan.until === null ? "no end" : `until ${day(plan.until)}`}</div>` : "";
  return `<tr>
    <td><details><summary><code>${esc(short(r.userId))}</code></summary><code>${esc(r.userId)}</code></details>${r.plusLinks.map((l) => `<div class="dim">${esc(l.label)}</div>`).join("")}</td>
    <td>${esc(r.providers.join(", ") || "not seen yet")}</td>
    <td><span class="${plan.word === "paid" ? "ok" : plan.word === "lapsed" ? "warn" : ""}">${esc(planText)}</span>${until}</td>
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
  const revoke = l.revokedAt ? "" : `<details><summary>Take back from everyone</summary><form method="post" action="/admin/links/${esc(l.id)}/revoke"><input type="hidden" name="who" value="all"><button>Yes, end Plus for all ${l.useCount}</button></form></details>`;
  return `<tr><td>${esc(l.label)}</td><td>${l.months === null ? "no end" : `${l.months} months`}</td><td class="n">${l.useCount} of ${l.maxUses}</td>
    <td><span class="${state === "open" ? "ok" : "dim"}">${state}</span></td><td>${day(l.createdAt)}</td><td>${people}</td><td>${close}${revoke}</td></tr>`;
}

const counts = (title: string, rows: { name: string; n: number }[]) =>
  `<div><b>${esc(title)}</b>${rows.map((r) => `<div>${esc(String(r.name))} <span class="dim">${r.n}</span></div>`).join("") || '<div class="dim">none</div>'}</div>`;

const signupTable = (rows: SignupRow[]) => table(["Email", "List", "Screens", "Task apps", "AI", "Page", "Date"], rows.map((r) =>
  `<tr>${[r.email, r.list, r.platforms, r.tools, r.agents, r.source, r.created_at.slice(0, 10)].map((x) => `<td>${esc(x.replace(/[[\]"]/g, ""))}</td>`).join("")}</tr>`), "No signups.");

export function renderAdmin(v: AdminView): string {
  const o = overview(v.accounts, v.now);
  const shown = v.accounts.filter((r) => matches(r, v));
  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Septena admin</title><style>${CSS}</style></head>
<body><main>
<header><h1>Septena admin</h1><span class="dim">${esc(v.admin)}</span>
  <form method="post" action="/admin/refresh"><button>Refresh counts</button></form></header>
${v.error ? `<div class="box warn">${esc(v.error)}</div>` : ""}
${v.newUrl ? `<div class="box"><b>New Plus link</b><p><code>${esc(v.newUrl)}</code></p><span class="dim">Copy it now. Only a hash is stored, so this page cannot show it again.</span></div>` : ""}

<div class="tiles">
  ${tile(o.accounts, "accounts")}${tile(o.newThisWeek, "new this week")}${tile(o.activeThisWeek, "active this week")}${tile(o.twoDevices, "with 2+ devices")}
  ${tile(o.withAgent, "with an agent")}${tile(o.agentChangesWeek, "agent changes this week")}
  ${tile(o.paid, `paid (${o.paidYear} year, ${o.paidMonth} month)`)}${tile(o.granted, "granted")}${tile(o.onTrial, "on trial")}${tile(o.trialsConverted, `bought, of ${o.trialsStarted} trials`)}${tile(o.lapsed, "lapsed")}
  ${tile(o.openTasks, "open tasks")}${tile(o.closedTasks, "closed tasks")}${tile(o.files, `files (${size(o.fileBytes)})`)}
</div>
<p class="dim">Counts refresh daily. Revenue and renewals are in App Store Connect.</p>

<h2>Plus links</h2>
<form method="post" action="/admin/links">
  <label>Label<input name="label" maxlength="60" required placeholder="Anna, press"></label>
  <label>Plus lasts<select name="months"><option value="1">1 month</option><option value="3">3 months</option><option value="6">6 months</option><option value="12" selected>12 months</option><option value="24">24 months</option><option value="forever">no end</option></select></label>
  <label>People<input name="maxUses" type="number" min="1" max="500" value="1" required></label>
  <button>Make a link</button>
</form>
<p class="dim">Close stops new people and keeps Plus for those who have it. Take back ends their Plus.</p>
${table(["Label", "Lasts", "Used", "State", "Made", "Accounts", ""], v.links.map((l) => linkRow(l, v.uses)), "No links yet.")}

<h2>Accounts</h2>
<form method="post" action="/admin/search"><label>Account id, link label, plan, sign-in or email<input name="q" value="${esc(v.query)}" maxlength="200"></label><button>Search</button></form>
${v.query ? ` <a href="/admin">Show all</a>` : ""}
<p class="dim">${shown.length} of ${v.accounts.length}. An account has no email unless its owner signed in with one.</p>
${table(["Account", "Sign-in", "Plan", "Since", "Last seen", "Tasks", "Files", "Devices", "Agents", "Counted"], shown.map((r) => accountRow(r, v.now)), v.query ? "No account matches." : "No accounts counted yet. Press Refresh counts.")}
${v.query.includes("@") ? `<h2>Signups with this email</h2>${signupTable(v.emailSignups)}` : ""}

<h2>Website signups</h2>
${v.signups ? `<div class="box cols">${counts("List", v.signups.byList)}${counts("Screens", v.signups.byPlatform)}${counts("Task apps", v.signups.byTool)}${counts("Week of", v.signups.byWeek)}</div>
<p><a href="/admin/signups.csv">Download all as CSV</a></p>${signupTable(v.signups.latest)}` : `<p class="warn">The signup database does not answer.</p>`}
</main></body></html>`;
}
