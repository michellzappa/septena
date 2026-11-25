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
    const [byList, byPlatform, byTool, byWeek, latest] = await Promise.all([
      rows<{ name: string; n: number }>(db, "SELECT list AS name, COUNT(*) AS n FROM signups GROUP BY list ORDER BY n DESC, name"),
      each("platforms"),
      each("tools"),
      rows<{ name: string; n: number }>(db, "SELECT date(created_at, 'weekday 0', '-6 days') AS name, COUNT(*) AS n FROM signups GROUP BY name ORDER BY name DESC LIMIT 12"),
      rows<SignupRow>(db, `SELECT ${COLS} FROM signups ORDER BY created_at DESC LIMIT 50`),
    ]);
    return { byList, byPlatform, byTool, byWeek, latest };
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
