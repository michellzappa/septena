import type { Env } from "./env";
import { json } from "./http";

interface InstallSummary {
  installs: number;
  opted_in: number;
  opted_out: number;
  first_seen: string | null;
  last_seen: string | null;
}

interface DimensionRow {
  label: string;
  installs: number;
  opted_in: number;
  opted_out: number;
}

interface RollupRow {
  day: string;
  event: string;
  screen: string;
  platform: string;
  app_version: string;
  count: number;
}

interface ConsentRow {
  day: string;
  enabled: number;
  changes: number;
}

interface SectionStateRow {
  section: string;
  installs: number;
  enabled: number;
  disabled: number;
}

interface SectionChangeRow {
  day: string;
  section: string;
  enabled: number;
  changes: number;
}

interface SectionUsageRow {
  section: string;
  views: number;
}

const sessionCookie = "septena_admin";

export async function telemetryAdmin(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  const token = url.searchParams.get("token");
  if (token && authorizedByToken(req, env, token)) {
    url.searchParams.delete("token");
    return new Response(null, {
      status: 302,
      headers: {
        "location": url.toString(),
        "set-cookie": `${sessionCookie}=${encodeURIComponent(token)}; Path=/admin; HttpOnly; Secure; SameSite=Strict; Max-Age=2592000`,
        "cache-control": "no-store",
      },
    });
  }

  const auth = authorizeAdmin(req, env);
  if (!auth.ok) {
    return adminUnauthorized(auth.reason);
  }

  const data = await loadTelemetryAdminData(env);
  return html(renderTelemetryDashboard(data, auth.label), 200);
}

function authorizeAdmin(req: Request, env: Env): { ok: true; label: string } | { ok: false; reason: string } {
  const token = bearerToken(req) ?? cookieToken(req);
  if (token && authorizedByToken(req, env, token)) {
    return { ok: true, label: "Admin token" };
  }

  const email = req.headers.get("CF-Access-Authenticated-User-Email")?.trim().toLowerCase() ?? "";
  const accessJwt = req.headers.get("CF-Access-Jwt-Assertion");
  const allowedEmails = (env.ADMIN_EMAILS ?? "")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  if (email && accessJwt && allowedEmails.includes(email)) {
    return { ok: true, label: email };
  }
  if (!env.ADMIN_DASHBOARD_TOKEN && allowedEmails.length === 0) {
    return { ok: false, reason: "Admin access is not configured." };
  }
  return { ok: false, reason: "Sign in through Cloudflare Access or use an admin dashboard token." };
}

function authorizedByToken(req: Request, env: Env, token: string): boolean {
  if (!env.ADMIN_DASHBOARD_TOKEN) return false;
  return timingSafeEqual(token, env.ADMIN_DASHBOARD_TOKEN);
}

function bearerToken(req: Request): string | null {
  const auth = req.headers.get("Authorization") ?? "";
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || null;
}

function cookieToken(req: Request): string | null {
  const cookie = req.headers.get("Cookie") ?? "";
  for (const part of cookie.split(";")) {
    const [key, ...value] = part.trim().split("=");
    if (key === sessionCookie) return decodeURIComponent(value.join("="));
  }
  return null;
}

function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const aa = enc.encode(a);
  const bb = enc.encode(b);
  const len = Math.max(aa.length, bb.length);
  let diff = aa.length ^ bb.length;
  for (let i = 0; i < len; i++) {
    diff |= (aa[i] ?? 0) ^ (bb[i] ?? 0);
  }
  return diff === 0;
}

async function loadTelemetryAdminData(env: Env): Promise<{
  summary: InstallSummary;
  anonOptOut: { total: number; recent: number };
  byPlatform: DimensionRow[];
  byVersion: DimensionRow[];
  daily: RollupRow[];
  topScreens: RollupRow[];
  consent: ConsentRow[];
  sectionState: SectionStateRow[];
  sectionChanges: SectionChangeRow[];
  sectionUsage: SectionUsageRow[];
}> {
  const summary = await env.DB.prepare(`
    select
      count(*) as installs,
      coalesce(sum(case when analytics_enabled = 1 then 1 else 0 end), 0) as opted_in,
      coalesce(sum(case when analytics_enabled = 0 then 1 else 0 end), 0) as opted_out,
      min(first_seen_at) as first_seen,
      max(last_seen_at) as last_seen
    from telemetry_install
  `).first<InstallSummary>() ?? { installs: 0, opted_in: 0, opted_out: 0, first_seen: null, last_seen: null };

  const byPlatform = await env.DB.prepare(`
    select
      platform as label,
      count(*) as installs,
      coalesce(sum(case when analytics_enabled = 1 then 1 else 0 end), 0) as opted_in,
      coalesce(sum(case when analytics_enabled = 0 then 1 else 0 end), 0) as opted_out
    from telemetry_install
    group by platform
    order by installs desc, platform asc
  `).all<DimensionRow>();

  const byVersion = await env.DB.prepare(`
    select
      coalesce(nullif(app_version, ''), 'unknown') as label,
      count(*) as installs,
      coalesce(sum(case when analytics_enabled = 1 then 1 else 0 end), 0) as opted_in,
      coalesce(sum(case when analytics_enabled = 0 then 1 else 0 end), 0) as opted_out
    from telemetry_install
    group by label
    order by installs desc, label desc
    limit 12
  `).all<DimensionRow>();

  const daily = await env.DB.prepare(`
    select day, event, screen, platform, app_version, sum(count) as count
    from telemetry_daily_rollup
    where day >= date('now', '-29 days')
    group by day, event, screen, platform, app_version
    order by day desc, event asc, count desc
    limit 120
  `).all<RollupRow>();

  const topScreens = await env.DB.prepare(`
    select
      max(day) as day,
      event,
      screen,
      '' as platform,
      '' as app_version,
      sum(count) as count
    from telemetry_daily_rollup
    where event = 'screen_view' and day >= date('now', '-29 days') and screen != ''
    group by event, screen
    order by count desc, screen asc
    limit 20
  `).all<RollupRow>();

  const consent = await env.DB.prepare(`
    select date(created_at) as day, enabled, count(*) as changes
    from telemetry_consent_event
    where created_at >= datetime('now', '-30 days')
    group by day, enabled
    order by day desc, enabled desc
    limit 60
  `).all<ConsentRow>();

  const sectionState = await env.DB.prepare(`
    select
      s.section,
      count(*) as installs,
      coalesce(sum(case when s.enabled = 1 then 1 else 0 end), 0) as enabled,
      coalesce(sum(case when s.enabled = 0 then 1 else 0 end), 0) as disabled
    from telemetry_section_state s
    join telemetry_install i on i.install_hash = s.install_hash
    where i.analytics_enabled = 1
    group by s.section
    order by enabled desc, installs desc, s.section asc
    limit 40
  `).all<SectionStateRow>();

  const sectionChanges = await env.DB.prepare(`
    select date(created_at) as day, section, enabled, count(*) as changes
    from telemetry_section_change_event
    where created_at >= datetime('now', '-30 days')
    group by day, section, enabled
    order by day desc, changes desc, section asc
    limit 80
  `).all<SectionChangeRow>();

  const sectionUsage = await env.DB.prepare(`
    select section, sum(count) as views
    from telemetry_section_daily_rollup
    where day >= date('now', '-30 days')
    group by section
    order by views desc, section asc
    limit 40
  `).all<SectionUsageRow>();

  // Anonymized opt-outs land in their own counter, not telemetry_install (they
  // carry no install identity), so the per-install opted_out metric above never
  // sees them. Surface them separately.
  const anonOptOut = await env.DB.prepare(`
    select
      coalesce(sum(count), 0) as total,
      coalesce(sum(case when day >= date('now', '-29 days') then count else 0 end), 0) as recent
    from telemetry_anon_optout_daily
  `).first<{ total: number; recent: number }>() ?? { total: 0, recent: 0 };

  return {
    summary,
    anonOptOut,
    byPlatform: byPlatform.results ?? [],
    byVersion: byVersion.results ?? [],
    daily: daily.results ?? [],
    topScreens: topScreens.results ?? [],
    consent: consent.results ?? [],
    sectionState: sectionState.results ?? [],
    sectionChanges: sectionChanges.results ?? [],
    sectionUsage: sectionUsage.results ?? [],
  };
}

function renderTelemetryDashboard(data: Awaited<ReturnType<typeof loadTelemetryAdminData>>, actor: string): string {
  const optOutRate = data.summary.installs > 0
    ? `${Math.round((data.summary.opted_out / data.summary.installs) * 1000) / 10}%`
    : "0%";
  const appOpens30 = data.daily
    .filter((row) => row.event === "app_open")
    .reduce((sum, row) => sum + Number(row.count ?? 0), 0);
  const screenViews30 = data.daily
    .filter((row) => row.event === "screen_view")
    .reduce((sum, row) => sum + Number(row.count ?? 0), 0);

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Septena Telemetry</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #f7f7f5;
      --fg: #1d1d1f;
      --muted: #6e6e73;
      --line: #d7d7d2;
      --panel: #ffffff;
      --accent: #336bd1;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #111113;
        --fg: #f5f5f7;
        --muted: #a1a1a6;
        --line: #303034;
        --panel: #1b1b1f;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--fg);
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    main { max-width: 1180px; margin: 0 auto; padding: 32px 20px 56px; }
    header { display: flex; justify-content: space-between; gap: 24px; align-items: end; margin-bottom: 24px; }
    h1 { font-size: 28px; margin: 0 0 4px; letter-spacing: 0; }
    h2 { font-size: 16px; margin: 0 0 12px; letter-spacing: 0; }
    p { margin: 0; color: var(--muted); }
    .grid { display: grid; gap: 14px; }
    .metrics { grid-template-columns: repeat(6, minmax(0, 1fr)); margin-bottom: 18px; }
    .two { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
      overflow: hidden;
    }
    .metric .label { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .04em; }
    .metric .value { font-size: 28px; font-weight: 650; margin-top: 6px; }
    .metric .sub { color: var(--muted); margin-top: 2px; }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 9px 0; border-bottom: 1px solid var(--line); text-align: left; white-space: nowrap; }
    th { color: var(--muted); font-size: 12px; font-weight: 600; }
    td.num, th.num { text-align: right; }
    tr:last-child td { border-bottom: 0; }
    .bar {
      display: inline-block;
      height: 8px;
      min-width: 2px;
      background: var(--accent);
      border-radius: 999px;
      vertical-align: middle;
      margin-right: 8px;
    }
    .stack { display: grid; gap: 14px; }
    .foot { margin-top: 20px; font-size: 12px; }
    @media (max-width: 820px) {
      header { display: block; }
      .metrics, .two { grid-template-columns: 1fr; }
      main { padding: 20px 12px 36px; }
      .panel { padding: 14px; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Septena Telemetry</h1>
        <p>Private aggregate readout. No logged user data, notes, tasks, food, symptoms, or profile fields.</p>
      </div>
      <p>Signed in as ${escapeHtml(actor)}</p>
    </header>

    <section class="grid metrics">
      ${metric("Installs", data.summary.installs, "anonymous installs")}
      ${metric("Opted In", data.summary.opted_in, "usage events enabled")}
      ${metric("Opted Out", data.summary.opted_out, `${optOutRate} opt-out rate`)}
      ${metric("Anon Opt-Outs", data.anonOptOut.recent, "identity-free pings, 30d")}
      ${metric("App Opens", appOpens30, "last 30 days")}
      ${metric("Screen Views", screenViews30, "last 30 days")}
    </section>

    <section class="grid two">
      ${dimensionPanel("Installs By Platform", data.byPlatform)}
      ${dimensionPanel("Installs By Version", data.byVersion)}
    </section>

    <section class="grid two" style="margin-top:14px">
      ${sectionStatePanel(data.sectionState)}
      ${sectionUsagePanel(data.sectionUsage)}
    </section>

    <div style="margin-top:14px">
      ${topScreensPanel(data.topScreens)}
    </div>

    <section class="grid two" style="margin-top:14px">
      ${sectionChangesPanel(data.sectionChanges)}
      ${consentPanel(data.consent)}
    </section>

    <section class="panel" style="margin-top:14px">
      <h2>Recent Rollups</h2>
      <table>
        <thead><tr><th>Day</th><th>Event</th><th>Screen</th><th>Platform</th><th>Version</th><th class="num">Count</th></tr></thead>
        <tbody>
          ${data.daily.map((row) => `<tr><td>${escapeHtml(row.day)}</td><td>${escapeHtml(row.event)}</td><td>${escapeHtml(row.screen || "-")}</td><td>${escapeHtml(row.platform)}</td><td>${escapeHtml(row.app_version || "-")}</td><td class="num">${number(row.count)}</td></tr>`).join("") || emptyRow(6)}
        </tbody>
      </table>
    </section>

    <p class="foot">First seen: ${escapeHtml(data.summary.first_seen ?? "-")} · Last seen: ${escapeHtml(data.summary.last_seen ?? "-")}</p>
  </main>
</body>
</html>`;
}

function metric(label: string, value: number | string, sub: string): string {
  return `<div class="panel metric"><div class="label">${escapeHtml(label)}</div><div class="value">${number(value)}</div><div class="sub">${escapeHtml(sub)}</div></div>`;
}

function dimensionPanel(title: string, rows: DimensionRow[]): string {
  return `<section class="panel">
    <h2>${escapeHtml(title)}</h2>
    <table>
      <thead><tr><th>Segment</th><th class="num">Installs</th><th class="num">In</th><th class="num">Out</th></tr></thead>
      <tbody>
        ${rows.map((row) => `<tr><td>${escapeHtml(row.label || "unknown")}</td><td class="num">${number(row.installs)}</td><td class="num">${number(row.opted_in)}</td><td class="num">${number(row.opted_out)}</td></tr>`).join("") || emptyRow(4)}
      </tbody>
    </table>
  </section>`;
}

function topScreensPanel(rows: RollupRow[]): string {
  const max = Math.max(1, ...rows.map((row) => Number(row.count ?? 0)));
  return `<section class="panel">
    <h2>Top Screens, Last 30 Days</h2>
    <table>
      <thead><tr><th>Screen</th><th class="num">Views</th></tr></thead>
      <tbody>
        ${rows.map((row) => {
          const width = Math.max(2, Math.round((Number(row.count ?? 0) / max) * 120));
          return `<tr><td><span class="bar" style="width:${width}px"></span>${escapeHtml(row.screen)}</td><td class="num">${number(row.count)}</td></tr>`;
        }).join("") || emptyRow(2)}
      </tbody>
    </table>
  </section>`;
}

function sectionUsagePanel(rows: SectionUsageRow[]): string {
  const max = Math.max(1, ...rows.map((row) => Number(row.views ?? 0)));
  return `<section class="panel">
    <h2>Section Usage, Last 30 Days</h2>
    <table>
      <thead><tr><th>Section</th><th class="num">Opens</th></tr></thead>
      <tbody>
        ${rows.map((row) => {
          const width = Math.max(2, Math.round((Number(row.views ?? 0) / max) * 120));
          return `<tr><td><span class="bar" style="width:${width}px"></span>${escapeHtml(row.section)}</td><td class="num">${number(row.views)}</td></tr>`;
        }).join("") || emptyRow(2)}
      </tbody>
    </table>
  </section>`;
}

function sectionStatePanel(rows: SectionStateRow[]): string {
  const max = Math.max(1, ...rows.map((row) => Number(row.enabled ?? 0)));
  return `<section class="panel">
    <h2>Sections Installed / Enabled</h2>
    <table>
      <thead><tr><th>Section</th><th class="num">Enabled</th><th class="num">Disabled</th><th class="num">Known</th></tr></thead>
      <tbody>
        ${rows.map((row) => {
          const width = Math.max(2, Math.round((Number(row.enabled ?? 0) / max) * 120));
          return `<tr><td><span class="bar" style="width:${width}px"></span>${escapeHtml(row.section)}</td><td class="num">${number(row.enabled)}</td><td class="num">${number(row.disabled)}</td><td class="num">${number(row.installs)}</td></tr>`;
        }).join("") || emptyRow(4)}
      </tbody>
    </table>
  </section>`;
}

function sectionChangesPanel(rows: SectionChangeRow[]): string {
  return `<section class="panel">
    <h2>Section Changes, Last 30 Days</h2>
    <table>
      <thead><tr><th>Day</th><th>Section</th><th>State</th><th class="num">Changes</th></tr></thead>
      <tbody>
        ${rows.map((row) => `<tr><td>${escapeHtml(row.day)}</td><td>${escapeHtml(row.section)}</td><td>${row.enabled ? "Enabled" : "Disabled"}</td><td class="num">${number(row.changes)}</td></tr>`).join("") || emptyRow(4)}
      </tbody>
    </table>
  </section>`;
}

function consentPanel(rows: ConsentRow[]): string {
  return `<section class="panel">
    <h2>Consent Changes, Last 30 Days</h2>
    <table>
      <thead><tr><th>Day</th><th>State</th><th class="num">Changes</th></tr></thead>
      <tbody>
        ${rows.map((row) => `<tr><td>${escapeHtml(row.day)}</td><td>${row.enabled ? "Opted in" : "Opted out"}</td><td class="num">${number(row.changes)}</td></tr>`).join("") || emptyRow(3)}
      </tbody>
    </table>
  </section>`;
}

function emptyRow(cols: number): string {
  return `<tr><td colspan="${cols}">No data yet.</td></tr>`;
}

function adminUnauthorized(reason: string): Response {
  return html(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Septena Admin</title>
  <style>
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f7f7f5; color: #1d1d1f; }
    main { width: min(440px, calc(100vw - 32px)); background: white; border: 1px solid #d7d7d2; border-radius: 8px; padding: 20px; }
    h1 { margin: 0 0 8px; font-size: 20px; }
    p { margin: 0; color: #6e6e73; }
  </style>
</head>
<body>
  <main>
    <h1>Admin Access Required</h1>
    <p>${escapeHtml(reason)}</p>
  </main>
</body>
</html>`, 401);
}

function html(body: string, status: number): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-robots-tag": "noindex, nofollow",
    },
  });
}

function number(value: number | string): string {
  if (typeof value === "number") return new Intl.NumberFormat("en-US").format(value);
  return value;
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
