import { rateLimited } from "./attest";
import type { Env } from "./env";
import { json, publicJson, readJson } from "./http";

type TelemetryEvent =
  | "app_open"
  | "screen_view"
  | "analytics_consent_changed"
  | "section_inventory"
  | "section_enabled_changed"
  | "section_used";
type TelemetryPlatform = "iOS" | "macOS" | "Catalyst" | "Unknown";
type TelemetryLevel = "none" | "minimal" | "balanced" | "full";

interface TelemetryBody {
  installId?: unknown;
  event?: unknown;
  screen?: unknown;
  section?: unknown;
  enabled?: unknown;
  sections?: unknown;
  analyticsEnabled?: unknown;
  level?: unknown;
  version?: unknown;
  build?: unknown;
  platform?: unknown;
}

interface TelemetrySection {
  section: string;
  enabled: boolean;
}

interface WeeklyDiagnosticsBody {
  schema?: unknown;
  install_id?: unknown;
  batch_id?: unknown;
  period?: unknown;
  app?: unknown;
  features?: unknown;
}

interface WeeklyDiagnosticsApp {
  version: string;
  build: string;
  platform: WeeklyDiagnosticsPlatform;
  osMajor: number;
  architecture: WeeklyDiagnosticsArchitecture;
}

interface WeeklyDiagnosticsFeatures {
  claude_connected: boolean;
  calendar_access: boolean;
  reminders_access: boolean;
  reminders_auto_import: boolean;
}

type WeeklyDiagnosticsPlatform = "macos" | "ios" | "catalyst" | "unknown";
type WeeklyDiagnosticsArchitecture = "arm64" | "x86_64" | "unknown";

const allowedKeys = new Set([
  "installId",
  "event",
  "screen",
  "section",
  "enabled",
  "sections",
  "analyticsEnabled",
  "level",
  "version",
  "build",
  "platform",
]);

const events = new Set<TelemetryEvent>([
  "app_open",
  "screen_view",
  "analytics_consent_changed",
  "section_inventory",
  "section_enabled_changed",
  "section_used",
]);

const platforms = new Set<TelemetryPlatform>([
  "iOS",
  "macOS",
  "Catalyst",
  "Unknown",
]);

const levels = new Set<TelemetryLevel>([
  "none",
  "minimal",
  "balanced",
  "full",
]);

export async function ingestTelemetry(env: Env, req: Request): Promise<Response> {
  const ip = req.headers.get("CF-Connecting-IP") ?? "unknown";
  if (await rateLimited(env, `telemetry-ip:${ip}`, 240, 60)) {
    return json({ error: "rate_limited" }, 429);
  }

  const body = await readJson<TelemetryBody>(req, 4096);
  if (body.error) return body.error;
  const data = body.data ?? {};

  const unknown = Object.keys(data).filter((key) => !allowedKeys.has(key));
  if (unknown.length > 0) return json({ error: "unknown_fields" }, 400);

  const installId = cleanInstallId(data.installId);
  const event = cleanEvent(data.event);
  const analyticsEnabled = typeof data.analyticsEnabled === "boolean" ? data.analyticsEnabled : null;
  const level = cleanLevel(data.level);
  const platform = cleanPlatform(data.platform);
  const version = cleanShortToken(data.version, 32);
  const build = cleanShortToken(data.build, 32);
  const screen = cleanScreen(data.screen);
  const section = cleanSection(data.section);
  const enabled = typeof data.enabled === "boolean" ? data.enabled : null;
  const sections = cleanSections(data.sections);

  // Anonymized opt-out: the app sends a single identity-free ping when the user
  // turns analytics Off — only the event and the `none` level, no install id,
  // platform, version, or build. Record it as an aggregate count so opt-outs
  // stay knowable without a final identifying ping.
  if (event === "analytics_consent_changed" && installId === null) {
    if (analyticsEnabled !== false || level !== "none") {
      return json({ error: "invalid_payload" }, 400);
    }
    if (platform || version || build || screen || section || enabled !== null || sections) {
      return json({ error: "unexpected_fields" }, 400);
    }
    await incrementAnonOptOut(env);
    return json({ ok: true });
  }

  if (!installId || !event || analyticsEnabled === null || !platform) {
    return json({ error: "invalid_payload" }, 400);
  }
  if (event === "screen_view") {
    if (!screen) return json({ error: "missing_screen" }, 400);
    if (section || enabled !== null || sections) return json({ error: "unexpected_fields" }, 400);
  } else if (event === "section_enabled_changed") {
    if (!section || enabled === null) return json({ error: "missing_section_state" }, 400);
    if (screen || sections) return json({ error: "unexpected_fields" }, 400);
  } else if (event === "section_used") {
    if (!section) return json({ error: "missing_section" }, 400);
    if (screen || enabled !== null || sections) return json({ error: "unexpected_fields" }, 400);
  } else if (event === "section_inventory") {
    if (!sections) return json({ error: "missing_sections" }, 400);
    if (screen || section || enabled !== null) return json({ error: "unexpected_fields" }, 400);
  } else {
    if (screen || section || enabled !== null || sections) return json({ error: "unexpected_fields" }, 400);
  }

  const installHash = await hmacInstallHash(env, installId);
  if (await rateLimited(env, `telemetry-install:${installHash}`, 120, 60)) {
    return json({ error: "rate_limited" }, 429);
  }

  await upsertInstall(env, {
    installHash,
    analyticsEnabled,
    level,
    platform,
    version,
    build,
  });

  if ((event === "section_inventory" || event === "section_enabled_changed" || event === "section_used") && !analyticsEnabled) {
    // Opt-out upserts the install row, but stores no section state or usage.
    return json({ ok: true });
  }

  if (event === "analytics_consent_changed") {
    await env.DB.prepare(`
      insert into telemetry_consent_event
        (id, install_hash, enabled, platform, app_version, build, level)
      values (?, ?, ?, ?, ?, ?, ?)
    `).bind(
      crypto.randomUUID(),
      installHash,
      analyticsEnabled ? 1 : 0,
      platform,
      version,
      build,
      level,
    ).run();
    if (!analyticsEnabled) {
      await deletePerInstallSectionTelemetry(env, installHash);
    }
  }

  if (analyticsEnabled && event === "section_inventory" && sections) {
    for (const s of sections) {
      await upsertSectionState(env, {
        installHash,
        section: s.section,
        enabled: s.enabled,
        platform,
        version,
      });
    }
  }

  if (analyticsEnabled && event === "section_enabled_changed" && section && enabled !== null) {
    await upsertSectionState(env, {
      installHash,
      section,
      enabled,
      platform,
      version,
    });
    await env.DB.prepare(`
      insert into telemetry_section_change_event
        (id, install_hash, section, enabled, platform, app_version, build)
      values (?, ?, ?, ?, ?, ?, ?)
    `).bind(
      crypto.randomUUID(),
      installHash,
      section,
      enabled ? 1 : 0,
      platform,
      version,
      build,
    ).run();
  }

  if (analyticsEnabled && event === "section_used" && section) {
    await incrementSectionRollup(env, {
      section,
      platform,
      version,
    });
  }

  // Opt-out means no usage telemetry. The install row above is operational
  // privacy state so aggregate opt-out counts stay knowable.
  if (analyticsEnabled && (event === "app_open" || event === "screen_view")) {
    await incrementRollup(env, {
      event,
      screen: event === "screen_view" ? screen : null,
      platform,
      version,
    });
  }

  return json({ ok: true });
}

/** Ingests the separate, opt-in, once-per-week Septask diagnostics snapshot. */
export async function ingestWeeklyDiagnostics(env: Env, req: Request): Promise<Response> {
  const ip = req.headers.get("CF-Connecting-IP") ?? "unknown";
  if (await rateLimited(env, `weekly-diagnostics-ip:${ip}`, 30, 3600)) {
    return json({ error: "rate_limited" }, 429);
  }

  const body = await readJson<WeeklyDiagnosticsBody>(req, 4096);
  if (body.error) return body.error;
  const data = body.data ?? {};
  const allowed = new Set(["schema", "install_id", "batch_id", "period", "app", "features"]);
  if (Object.keys(data).some((key) => !allowed.has(key))) {
    return json({ error: "unknown_fields" }, 400);
  }

  if (data.schema !== 1) return json({ error: "unsupported_schema" }, 400);
  const installID = cleanInstallId(data.install_id);
  const batchID = cleanShortToken(data.batch_id, 64);
  const period = cleanWeeklyPeriod(data.period);
  const app = cleanWeeklyApp(data.app);
  const features = cleanWeeklyFeatures(data.features);
  if (!installID || !batchID || !period || !app || !features) {
    return json({ error: "invalid_payload" }, 400);
  }

  const installHash = await hmacInstallHash(env, installID);
  if (await rateLimited(env, `weekly-diagnostics-install:${installHash}`, 4, 3600)) {
    return json({ error: "rate_limited" }, 429);
  }

  await env.DB.prepare(`
    insert into telemetry_weekly_batch
      (install_hash, batch_id, period, platform, app_version, build, os_major, architecture, features_json)
    values (?, ?, ?, ?, ?, ?, ?, ?, ?)
    on conflict(install_hash, period) do update set
      batch_id = excluded.batch_id,
      platform = excluded.platform,
      app_version = excluded.app_version,
      build = excluded.build,
      os_major = excluded.os_major,
      architecture = excluded.architecture,
      features_json = excluded.features_json,
      received_at = datetime('now')
  `).bind(
    installHash,
    batchID,
    period,
    app.platform,
    app.version,
    app.build,
    app.osMajor,
    app.architecture,
    JSON.stringify(features),
  ).run();

  return json({ ok: true });
}

/** Public aggregate with a minimum group size to avoid small-cohort disclosure. */
export async function weeklyDiagnosticsPulse(env: Env): Promise<Response> {
  const minimumGroupSize = 5;
  const result = await env.DB.prepare(`
    select period, count(*) as reporting_installs
    from telemetry_weekly_batch
    where received_at >= datetime('now', '-56 days')
    group by period
    order by period desc
    limit 8
  `).all<{ period: string; reporting_installs: number }>();

  const weeklyActive = (result.results ?? [])
    .filter((row) => row.reporting_installs >= minimumGroupSize)
    .map((row) => ({ period: row.period, reporting_installs: row.reporting_installs }));

  const latestRow = weeklyActive[0];
  if (!latestRow) {
    return publicJson({ minimum_group_size: minimumGroupSize, weekly_active: [], latest: null });
  }

  const latest = await env.DB.prepare(`
    select app_version, features_json
    from telemetry_weekly_batch
    where period = ?
  `).bind(latestRow.period).all<{ app_version: string; features_json: string }>();

  const versions = new Map<string, number>();
  const featureTotals = new Map<string, number>();
  for (const row of latest.results ?? []) {
    versions.set(row.app_version, (versions.get(row.app_version) ?? 0) + 1);
    const features = safeWeeklyFeatures(row.features_json);
    if (!features) continue;
    for (const [name, enabled] of Object.entries(features)) {
      if (enabled) featureTotals.set(name, (featureTotals.get(name) ?? 0) + 1);
    }
  }

  return publicJson({
    minimum_group_size: minimumGroupSize,
    weekly_active: weeklyActive,
    latest: {
      period: latestRow.period,
      reporting_installs: latestRow.reporting_installs,
      versions: [...versions.entries()]
        .filter(([, installs]) => installs >= minimumGroupSize)
        .map(([name, installs]) => ({ name, installs }))
        .sort((a, b) => b.installs - a.installs || a.name.localeCompare(b.name)),
      features: [...featureTotals.entries()]
        .map(([name, enabled]) => ({
          name,
          adoption_percent: Math.round((enabled / latestRow.reporting_installs) * 100),
        }))
        .sort((a, b) => b.adoption_percent - a.adoption_percent || a.name.localeCompare(b.name)),
    },
  });
}

async function upsertSectionState(
  env: Env,
  args: {
    installHash: string;
    section: string;
    enabled: boolean;
    platform: TelemetryPlatform;
    version: string | null;
  },
): Promise<void> {
  await env.DB.prepare(`
    insert into telemetry_section_state
      (install_hash, section, enabled, platform, app_version, first_seen_at, last_seen_at)
    values (?, ?, ?, ?, ?, datetime('now'), datetime('now'))
    on conflict(install_hash, section) do update set
      enabled = excluded.enabled,
      platform = excluded.platform,
      app_version = excluded.app_version,
      last_seen_at = datetime('now')
  `).bind(
    args.installHash,
    args.section,
    args.enabled ? 1 : 0,
    args.platform,
    args.version ?? "",
  ).run();
}

async function deletePerInstallSectionTelemetry(env: Env, installHash: string): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("delete from telemetry_section_state where install_hash = ?").bind(installHash),
    env.DB.prepare("delete from telemetry_section_change_event where install_hash = ?").bind(installHash),
  ]);
}

async function incrementSectionRollup(
  env: Env,
  args: {
    section: string;
    platform: TelemetryPlatform;
    version: string | null;
  },
): Promise<void> {
  await env.DB.prepare(`
    insert into telemetry_section_daily_rollup
      (day, section, platform, app_version, count)
    values (date('now'), ?, ?, ?, 1)
    on conflict(day, section, platform, app_version) do update set
      count = count + 1
  `).bind(
    args.section,
    args.platform,
    args.version ?? "",
  ).run();
}

async function upsertInstall(
  env: Env,
  args: {
    installHash: string;
    analyticsEnabled: boolean;
    level: TelemetryLevel | null;
    platform: TelemetryPlatform;
    version: string | null;
    build: string | null;
  },
): Promise<void> {
  await env.DB.prepare(`
    insert into telemetry_install
      (install_hash, analytics_enabled, level, platform, app_version, build, first_seen_at, last_seen_at, last_consent_at)
    values
      (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'), datetime('now'))
    on conflict(install_hash) do update set
      analytics_enabled = excluded.analytics_enabled,
      level = coalesce(excluded.level, telemetry_install.level),
      platform = excluded.platform,
      app_version = excluded.app_version,
      build = excluded.build,
      last_seen_at = datetime('now'),
      last_consent_at = case
        when telemetry_install.analytics_enabled != excluded.analytics_enabled then datetime('now')
        else telemetry_install.last_consent_at
      end
  `).bind(
    args.installHash,
    args.analyticsEnabled ? 1 : 0,
    args.level,
    args.platform,
    args.version,
    args.build,
  ).run();
}

async function incrementAnonOptOut(env: Env): Promise<void> {
  await env.DB.prepare(`
    insert into telemetry_anon_optout_daily (day, count)
    values (date('now'), 1)
    on conflict(day) do update set count = count + 1
  `).run();
}

async function incrementRollup(
  env: Env,
  args: {
    event: Exclude<TelemetryEvent, "analytics_consent_changed">;
    screen: string | null;
    platform: TelemetryPlatform;
    version: string | null;
  },
): Promise<void> {
  const day = new Date().toISOString().slice(0, 10);
  await env.DB.prepare(`
    insert into telemetry_daily_rollup
      (day, event, screen, platform, app_version, count)
    values (?, ?, ?, ?, ?, 1)
    on conflict(day, event, screen, platform, app_version) do update set
      count = count + 1
  `).bind(day, args.event, args.screen ?? "", args.platform, args.version ?? "").run();
}

function cleanInstallId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const s = value.trim();
  return /^[A-Za-z0-9_-]{16,96}$/.test(s) ? s : null;
}

function cleanEvent(value: unknown): TelemetryEvent | null {
  if (typeof value !== "string") return null;
  return events.has(value as TelemetryEvent) ? value as TelemetryEvent : null;
}

function cleanPlatform(value: unknown): TelemetryPlatform | null {
  if (typeof value !== "string") return null;
  return platforms.has(value as TelemetryPlatform) ? value as TelemetryPlatform : null;
}

function cleanLevel(value: unknown): TelemetryLevel | null {
  if (typeof value !== "string") return null;
  return levels.has(value as TelemetryLevel) ? value as TelemetryLevel : null;
}

function cleanShortToken(value: unknown, max: number): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") return null;
  const s = value.trim();
  if (s.length === 0) return null;
  return /^[A-Za-z0-9._-]+$/.test(s) && s.length <= max ? s : null;
}

function cleanScreen(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") return null;
  const s = value.trim().toLowerCase();
  return /^[a-z0-9._-]{1,48}$/.test(s) ? s : null;
}

function cleanSection(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") return null;
  const s = value.trim().toLowerCase();
  return /^[a-z0-9._-]{1,48}$/.test(s) ? s : null;
}

function cleanSections(value: unknown): TelemetrySection[] | null {
  if (value === undefined || value === null) return null;
  if (!Array.isArray(value) || value.length === 0 || value.length > 64) return null;
  const out: TelemetrySection[] = [];
  const seen = new Set<string>();
  for (const item of value) {
    if (!item || typeof item !== "object" || Array.isArray(item)) return null;
    const obj = item as { section?: unknown; enabled?: unknown };
    const keys = Object.keys(obj);
    if (keys.some((key) => key !== "section" && key !== "enabled")) return null;
    const section = cleanSection(obj.section);
    if (!section || seen.has(section) || typeof obj.enabled !== "boolean") return null;
    seen.add(section);
    out.push({ section, enabled: obj.enabled });
  }
  return out;
}

function cleanWeeklyPeriod(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const period = value.trim();
  return /^\d{4}-W(?:0[1-9]|[1-4]\d|5[0-3])$/.test(period) ? period : null;
}

function cleanWeeklyApp(value: unknown): WeeklyDiagnosticsApp | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const app = value as Record<string, unknown>;
  const allowed = new Set(["version", "build", "platform", "osMajor", "architecture"]);
  if (Object.keys(app).some((key) => !allowed.has(key))) return null;

  const version = cleanShortToken(app.version, 32);
  const build = cleanShortToken(app.build, 32);
  const platform = cleanWeeklyPlatform(app.platform);
  const architecture = cleanWeeklyArchitecture(app.architecture);
  const osMajor = app.osMajor;
  if (!version || !build || !platform || !architecture || typeof osMajor !== "number" || !Number.isInteger(osMajor) || osMajor < 1 || osMajor > 99) {
    return null;
  }
  return { version, build, platform, osMajor, architecture };
}

function cleanWeeklyPlatform(value: unknown): WeeklyDiagnosticsPlatform | null {
  if (typeof value !== "string") return null;
  return new Set<WeeklyDiagnosticsPlatform>(["macos", "ios", "catalyst", "unknown"]).has(value as WeeklyDiagnosticsPlatform)
    ? value as WeeklyDiagnosticsPlatform
    : null;
}

function cleanWeeklyArchitecture(value: unknown): WeeklyDiagnosticsArchitecture | null {
  if (typeof value !== "string") return null;
  return new Set<WeeklyDiagnosticsArchitecture>(["arm64", "x86_64", "unknown"]).has(value as WeeklyDiagnosticsArchitecture)
    ? value as WeeklyDiagnosticsArchitecture
    : null;
}

function cleanWeeklyFeatures(value: unknown): WeeklyDiagnosticsFeatures | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const features = value as Record<string, unknown>;
  const allowed = new Set([
    "claude_connected",
    "calendar_access",
    "reminders_access",
    "reminders_auto_import",
  ]);
  if (Object.keys(features).some((key) => !allowed.has(key))) return null;
  if (Object.keys(features).length !== allowed.size) return null;
  if (Object.values(features).some((enabled) => typeof enabled !== "boolean")) return null;
  return features as unknown as WeeklyDiagnosticsFeatures;
}

function safeWeeklyFeatures(value: string): WeeklyDiagnosticsFeatures | null {
  try {
    return cleanWeeklyFeatures(JSON.parse(value));
  } catch {
    return null;
  }
}

async function hmacInstallHash(env: Env, installId: string): Promise<string> {
  const salt = env.TELEMETRY_HASH_SALT ?? env.USER_HASH_SALT;
  if (!salt || salt.startsWith("REPLACE_")) throw new Error("TELEMETRY_HASH_SALT is not configured");
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(salt),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(installId)));
  return b64url(sig);
}

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
