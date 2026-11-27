import type { Env } from "../env.js";

// The website's signups (septena-site `signups` table), read only.

export interface SignupRow {
  email: string;
  list: string;
  platforms: string;
  tools: string;
  agents: string;
  source: string;
  created_at: string;
}

const COLS = "email, list, platforms, tools, agents, source, created_at";

export interface SignupView {
  byList: { name: string; n: number }[];
  byPlatform: { name: string; n: number }[];
  byTool: { name: string; n: number }[];
  byWeek: { name: string; n: number }[];
  /// Signups per day for the last 60 days (days with none are left out).
  byDay: { name: string; n: number }[];
  /// The page that sent the signup.
  bySource: { name: string; n: number }[];
  /// Distinct email addresses on any list.
  people: number;
  total: number;
  latest: SignupRow[];
}

async function rows<T>(db: D1Database, query: string, ...args: unknown[]): Promise<T[]> {
  return (await db.prepare(query).bind(...args).all<T>()).results;
}

/// Null when the database is not bound or does not answer: the page says so
/// and shows the rest.
export async function signupView(env: Env): Promise<SignupView | null> {
  const db = env.SIGNUPS;
  if (!db) return null;
  const each = (column: "platforms" | "tools") =>
    rows<{ name: string; n: number }>(db, `SELECT j.value AS name, COUNT(DISTINCT s.email) AS n FROM signups s, json_each(s.${column}) j GROUP BY j.value ORDER BY n DESC, name`);
  try {
    const [byList, byPlatform, byTool, byWeek, byDay, bySource, totals, latest] = await Promise.all([
      rows<{ name: string; n: number }>(db, "SELECT list AS name, COUNT(*) AS n FROM signups GROUP BY list ORDER BY n DESC, name"),
      each("platforms"),
      each("tools"),
      rows<{ name: string; n: number }>(db, "SELECT date(created_at, 'weekday 0', '-6 days') AS name, COUNT(*) AS n FROM signups GROUP BY name ORDER BY name DESC LIMIT 12"),
      rows<{ name: string; n: number }>(db, "SELECT date(created_at) AS name, COUNT(*) AS n FROM signups WHERE created_at >= date('now', '-60 days') GROUP BY name ORDER BY name"),
      rows<{ name: string; n: number }>(db, "SELECT CASE WHEN source = '' THEN 'unknown' ELSE source END AS name, COUNT(*) AS n FROM signups GROUP BY name ORDER BY n DESC, name LIMIT 15"),
      rows<{ total: number; people: number }>(db, "SELECT COUNT(*) AS total, COUNT(DISTINCT lower(email)) AS people FROM signups"),
      rows<SignupRow>(db, `SELECT ${COLS} FROM signups ORDER BY created_at DESC LIMIT 50`),
    ]);
    return { byList, byPlatform, byTool, byWeek, byDay, bySource, total: totals[0]?.total ?? 0, people: totals[0]?.people ?? 0, latest };
  } catch {
    return null;
  }
}

/// All signups and the ones of the last 7 days, for the daily snapshot.
export async function signupTotals(env: Env, now = Date.now()): Promise<{ total: number; week: number } | null> {
  if (!env.SIGNUPS) return null;
  try {
    const since = new Date(now - 7 * 86_400_000).toISOString();
    const r = await rows<{ total: number; week: number }>(env.SIGNUPS,
      "SELECT COUNT(*) AS total, COALESCE(SUM(CASE WHEN created_at >= ? THEN 1 ELSE 0 END), 0) AS week FROM signups", since);
    return r[0] ?? { total: 0, week: 0 };
  } catch {
    return null;
  }
}

export async function signupsByEmail(env: Env, email: string): Promise<SignupRow[]> {
  if (!env.SIGNUPS) return [];
  return rows<SignupRow>(env.SIGNUPS, `SELECT ${COLS} FROM signups WHERE lower(email) = ? ORDER BY list`, email.trim().toLowerCase());
}

/// A cell a spreadsheet must not read as a formula.
const cell = (v: string) => `"${(/^[=+\-@\t\r]/.test(v) ? `'${v}` : v).replace(/"/g, '""')}"`;

export async function signupsCsv(env: Env): Promise<string | null> {
  if (!env.SIGNUPS) return null;
  const all = await rows<SignupRow>(env.SIGNUPS, `SELECT ${COLS} FROM signups ORDER BY created_at`);
  const cols = COLS.split(", ") as (keyof SignupRow)[];
  return [cols.join(","), ...all.map((r) => cols.map((k) => cell(String(r[k] ?? ""))).join(","))].join("\r\n") + "\r\n";
}
