import { randomId } from "../util.js";

// The beta by invite code (ADR 0064, docs/BETA_ONBOARDING_SPEC.md). mz makes
// named codes on the admin page. A person joins on septena.app/beta with their
// email and a code; src/api/beta.ts adds them to TestFlight and writes the
// tester row here. Each tester owns one personal plan link (a Pro plan link,
// ADR 0043, one use). The thank-you follows the email: a sign-in with that
// verified email claims the link for that account, and so does a web claim
// of the link. The link's one use makes the first claim win.

export const BETA_CODE_RE = /^[A-Z0-9]{8,32}$/;
export const BETA_CODE_MAX_USES = 1000;

/// Upper case, letters and digits only. A code is an invitation, not a
/// credential: it is stored readable so the admin page can show it.
export const normalizeBetaCode = (raw: string): string => raw.trim().toUpperCase().replace(/[^A-Z0-9]/g, "");

export interface BetaCodeInput {
  code: string;
  label: string;
  maxUses: number;
  endsAt: number | null;
}

export interface BetaCode extends BetaCodeInput {
  id: string;
  useCount: number;
  createdAt: number;
  closedAt: number | null;
}

export interface BetaTester {
  email: string;
  codeId: string;
  joinedAt: number;
  ascState: "invited" | "failed";
  ascTesterId: string | null;
  planLinkId: string | null;
  planLinkHash: string | null;
  grantedUserId: string | null;
  grantedAt: number | null;
  welcomeSentAt: number | null;
  checkinSentAt: number | null;
  /// The seeded "Septena beta" project (BETA_ONBOARDING_SPEC §7). Set once,
  /// when seeding starts: a deleted project never comes back.
  seededAt: number | null;
  seedProjectId: string | null;
  /// JSON: beta item id to the seeded task id.
  seedTaskIds: string | null;
  cardDismissedAt: number | null;
  /// JSON `BetaUsage`: what the account did, measured from its own data.
  usage: string | null;
  usageAt: number | null;
  /// The day-7 question (Sean Ellis): only a hash of the answer link token.
  questionSentAt: number | null;
  answerTokenHash: string | null;
  answer: BetaAnswer | null;
  answeredAt: number | null;
}

export const BETA_ANSWERS = ["very", "somewhat", "not"] as const;
export type BetaAnswer = (typeof BETA_ANSWERS)[number];

/// What a tester did, measured from the account's own rows (TaskStore
/// `betaUsage`), never what they wrote. Times are ms; null = not yet.
export interface BetaUsage {
  did: Record<string, number | null>;
  ticked: Record<string, boolean>;
  /// Active days (distinct UTC days with a change by the user) in weeks 1, 2
  /// and 4 after the join.
  activeDays: { w1: number; w2: number; w4: number };
  /// The third active day of week 1, null when there were fewer.
  week1ThirdDayAt: number | null;
  /// Completed agent loops (claim or work, a question answered, the hand-off accepted).
  loops: { total: number; week: number };
  /// The last 7 days.
  week: { added: number; done: number; movedToday: number };
  firstTaskAt: number | null;
  firstDoneAt: number | null;
}

/// The earlier time of two, null when both are null.
const earliest = (a: number | null | undefined, b: number | null | undefined): number | null =>
  a == null ? (b ?? null) : b == null ? a : Math.min(a, b);

/// A new measurement over the stored one: a first time never moves later and
/// never goes away (a deleted device or agent still counts), the rest is the
/// new reading.
export function mergeUsage(old: BetaUsage | null, next: BetaUsage): BetaUsage {
  if (!old) return next;
  const did: Record<string, number | null> = {};
  for (const id of new Set([...Object.keys(old.did), ...Object.keys(next.did)])) did[id] = earliest(old.did[id], next.did[id]);
  return {
    ...next,
    did,
    activeDays: {
      w1: Math.max(old.activeDays.w1, next.activeDays.w1),
      w2: Math.max(old.activeDays.w2, next.activeDays.w2),
      w4: Math.max(old.activeDays.w4, next.activeDays.w4),
    },
    week1ThirdDayAt: earliest(old.week1ThirdDayAt, next.week1ThirdDayAt),
    loops: { total: Math.max(old.loops.total, next.loops.total), week: next.loops.week },
    firstTaskAt: earliest(old.firstTaskAt, next.firstTaskAt),
    firstDoneAt: earliest(old.firstDoneAt, next.firstDoneAt),
  };
}

export const parseUsage = (raw: string | null): BetaUsage | null => {
  if (!raw) return null;
  try { return JSON.parse(raw) as BetaUsage; } catch { return null; }
};

export type BetaJoinStart =
  | { ok: true; state: "new"; codeId: string; codeLabel: string }
  | { ok: true; state: "already_joined"; tester: BetaTester }
  | { ok: false };

const CODE_COLS = "id, code, label, maxUses, useCount, endsAt, createdAt, closedAt";
const TESTER_COLS = "email, codeId, joinedAt, ascState, ascTesterId, planLinkId, planLinkHash, grantedUserId, grantedAt, welcomeSentAt, checkinSentAt, "
  + "seededAt, seedProjectId, seedTaskIds, cardDismissedAt, usage, usageAt, questionSentAt, answerTokenHash, answer, answeredAt";

/// Columns added after the table shipped (`migrate`).
const ADDED_TESTER_COLS: [string, string][] = [
  ["seededAt", "INTEGER"], ["seedProjectId", "TEXT"], ["seedTaskIds", "TEXT"], ["cardDismissedAt", "INTEGER"],
  ["usage", "TEXT"], ["usageAt", "INTEGER"], ["questionSentAt", "INTEGER"], ["answerTokenHash", "TEXT"],
  ["answer", "TEXT"], ["answeredAt", "INTEGER"],
];

export class BetaInvites {
  private sql: SqlStorage;

  constructor(sql: SqlStorage) {
    this.sql = sql;
  }

  migrate(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS beta_codes (
        id TEXT PRIMARY KEY, code TEXT NOT NULL UNIQUE, label TEXT NOT NULL,
        maxUses INTEGER NOT NULL, useCount INTEGER NOT NULL DEFAULT 0,
        endsAt INTEGER, createdAt INTEGER NOT NULL, closedAt INTEGER
      );
      CREATE TABLE IF NOT EXISTS beta_testers (
        email TEXT PRIMARY KEY, codeId TEXT NOT NULL, joinedAt INTEGER NOT NULL,
        ascState TEXT NOT NULL, ascTesterId TEXT,
        planLinkId TEXT, planLinkHash TEXT,
        grantedUserId TEXT, grantedAt INTEGER,
        welcomeSentAt INTEGER, checkinSentAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS beta_testers_link ON beta_testers(planLinkId);
      CREATE TABLE IF NOT EXISTS beta_settings (key TEXT PRIMARY KEY, value INTEGER);
      CREATE TABLE IF NOT EXISTS beta_progress (
        userId TEXT NOT NULL, key TEXT NOT NULL, at INTEGER NOT NULL,
        PRIMARY KEY (userId, key)
      );
      CREATE INDEX IF NOT EXISTS beta_testers_user ON beta_testers(grantedUserId);
    `);
    const have = new Set(this.sql.exec<{ name: string }>("PRAGMA table_info(beta_testers)").toArray().map((r) => r.name));
    for (const [name, type] of ADDED_TESTER_COLS) if (!have.has(name)) this.sql.exec(`ALTER TABLE beta_testers ADD COLUMN ${name} ${type}`);
    this.sql.exec("CREATE INDEX IF NOT EXISTS beta_testers_answer ON beta_testers(answerTokenHash)");
    // The in-app checklist screen is gone (the seeded project replaced it).
    // Its one value that still matters, the closed welcome card, moves to
    // the tester row; the ticks and "I used it" go.
    if (!have.has("cardDismissedAt")) {
      this.sql.exec(`UPDATE beta_testers SET cardDismissedAt = (SELECT at FROM beta_progress p WHERE p.userId = beta_testers.grantedUserId AND p.key = '_card')
        WHERE grantedUserId IS NOT NULL`);
    }
    this.sql.exec("DELETE FROM beta_progress");
  }

  private codeRow(column: "id" | "code", value: string): BetaCode | null {
    const r = this.sql.exec(`SELECT ${CODE_COLS} FROM beta_codes WHERE ${column} = ?`, value).toArray()[0];
    return r ? { ...r } as unknown as BetaCode : null;
  }

  tester(email: string): BetaTester | null {
    const r = this.sql.exec(`SELECT ${TESTER_COLS} FROM beta_testers WHERE email = ?`, email).toArray()[0];
    return r ? { ...r } as unknown as BetaTester : null;
  }

  testerForLink(linkId: string): BetaTester | null {
    const r = this.sql.exec(`SELECT ${TESTER_COLS} FROM beta_testers WHERE planLinkId = ?`, linkId).toArray()[0];
    return r ? { ...r } as unknown as BetaTester : null;
  }

  /// Null when the code text is taken.
  createCode(input: BetaCodeInput, now: number): BetaCode | null {
    if (this.codeRow("code", input.code)) return null;
    const id = `beta-${randomId(10).toLowerCase().replace(/[^a-z0-9]/g, "0")}`;
    this.sql.exec(
      "INSERT INTO beta_codes (id, code, label, maxUses, endsAt, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
      id, input.code, input.label, input.maxUses, input.endsAt, now,
    );
    return this.codeRow("id", id);
  }

  listCodes(): BetaCode[] {
    return this.sql.exec(`SELECT ${CODE_COLS} FROM beta_codes ORDER BY createdAt DESC, id`).toArray()
      .map((r) => ({ ...r }) as unknown as BetaCode);
  }

  /// Per code: joined, and joined with the grant on an account.
  codeCounts(): Map<string, { joined: number; granted: number }> {
    const out = new Map<string, { joined: number; granted: number }>();
    for (const r of this.sql.exec<{ codeId: string; joined: number; granted: number }>(
      "SELECT codeId, COUNT(*) AS joined, COUNT(grantedUserId) AS granted FROM beta_testers WHERE ascState = 'invited' GROUP BY codeId",
    ).toArray()) out.set(r.codeId, { joined: r.joined, granted: r.granted });
    return out;
  }

  closeCode(id: string, now: number): boolean {
    if (!this.codeRow("id", id)) return false;
    this.sql.exec("UPDATE beta_codes SET closedAt = COALESCE(closedAt, ?) WHERE id = ?", now, id);
    return true;
  }

  private live(code: BetaCode | null, now: number): code is BetaCode {
    return code !== null && code.closedAt === null && (code.endsAt === null || code.endsAt > now) && code.useCount < code.maxUses;
  }

  /// The first half of a join. A tester who already joined comes back as
  /// such, with any code, so a second visit resends the invite instead of
  /// failing. A new email needs a live code; it uses the code only when the
  /// invite went through (`finishJoin`).
  startJoin(email: string, rawCode: string, now: number): BetaJoinStart {
    const had = this.tester(email);
    if (had && had.ascState === "invited") return { ok: true, state: "already_joined", tester: had };
    const code = this.codeRow("code", normalizeBetaCode(rawCode));
    if (!this.live(code, now)) return { ok: false };
    return { ok: true, state: "new", codeId: code.id, codeLabel: code.label };
  }

  /// Writes the tester. `invited` takes one use of the code; `failed` keeps
  /// the row so a retry can find it, and takes no use.
  finishJoin(email: string, codeId: string, ascState: "invited" | "failed", ascTesterId: string | null, now: number): BetaTester {
    const had = this.tester(email);
    if (!had) {
      this.sql.exec(
        "INSERT INTO beta_testers (email, codeId, joinedAt, ascState, ascTesterId) VALUES (?, ?, ?, ?, ?)",
        email, codeId, now, ascState, ascTesterId,
      );
    } else {
      this.sql.exec("UPDATE beta_testers SET codeId = ?, joinedAt = ?, ascState = ?, ascTesterId = COALESCE(?, ascTesterId) WHERE email = ?",
        codeId, now, ascState, ascTesterId, email);
    }
    if (ascState === "invited" && had?.ascState !== "invited") {
      this.sql.exec("UPDATE beta_codes SET useCount = useCount + 1 WHERE id = ?", codeId);
    }
    return this.tester(email)!;
  }

  setPlanLink(email: string, linkId: string, linkHash: string): void {
    this.sql.exec("UPDATE beta_testers SET planLinkId = ?, planLinkHash = ? WHERE email = ? AND planLinkId IS NULL", linkId, linkHash, email);
  }

  /// The first account wins. Later calls keep the first.
  noteGranted(email: string, userId: string, now: number): void {
    this.sql.exec("UPDATE beta_testers SET grantedUserId = ?, grantedAt = ? WHERE email = ? AND grantedUserId IS NULL", userId, now, email);
  }

  noteWelcome(email: string, now: number): void {
    this.sql.exec("UPDATE beta_testers SET welcomeSentAt = ? WHERE email = ?", now, email);
  }

  /// Testers whose check-in is due: invited, joined before `joinedBefore`,
  /// no check-in yet. Marks them sent in the same step, so two sweeps never
  /// send twice.
  takeCheckinsDue(joinedBefore: number, now: number, limit = 50): BetaTester[] {
    const due = this.sql.exec(
      `SELECT ${TESTER_COLS} FROM beta_testers WHERE ascState = 'invited' AND checkinSentAt IS NULL AND joinedAt < ? ORDER BY joinedAt LIMIT ?`,
      joinedBefore, limit,
    ).toArray().map((r) => ({ ...r }) as unknown as BetaTester);
    for (const t of due) this.sql.exec("UPDATE beta_testers SET checkinSentAt = ? WHERE email = ?", now, t.email);
    return due;
  }

  /// Every invited tester (the launch mail and the launch end date).
  invited(): BetaTester[] {
    return this.sql.exec(`SELECT ${TESTER_COLS} FROM beta_testers WHERE ascState = 'invited' ORDER BY joinedAt`).toArray()
      .map((r) => ({ ...r }) as unknown as BetaTester);
  }

  planLinkIds(): string[] {
    return this.sql.exec<{ planLinkId: string }>("SELECT planLinkId FROM beta_testers WHERE planLinkId IS NOT NULL").toArray().map((r) => r.planLinkId);
  }

  launchAt(): number | null {
    const r = this.sql.exec<{ value: number | null }>("SELECT value FROM beta_settings WHERE key = 'launchAt'").toArray()[0];
    return r?.value ?? null;
  }

  setLaunchAt(at: number): void {
    this.sql.exec("INSERT INTO beta_settings (key, value) VALUES ('launchAt', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", at);
  }

  /// The tester whose Pro is on this account: what makes an account a beta
  /// account in the app.
  testerForUser(userId: string): BetaTester | null {
    const r = this.sql.exec(`SELECT ${TESTER_COLS} FROM beta_testers WHERE grantedUserId = ?`, userId).toArray()[0];
    return r ? { ...r } as unknown as BetaTester : null;
  }

  /// Starts seeding the account's beta project, once: answers the tester
  /// when this call took the seed, null when the account is not a tester's
  /// or was seeded before (even when that project was deleted since).
  takeSeed(userId: string, now: number): BetaTester | null {
    const t = this.testerForUser(userId);
    if (!t || t.seededAt !== null) return null;
    this.sql.exec("UPDATE beta_testers SET seededAt = ? WHERE email = ? AND seededAt IS NULL", now, t.email);
    return this.tester(t.email);
  }

  finishSeed(email: string, projectId: string, taskIds: Record<string, string>): void {
    this.sql.exec("UPDATE beta_testers SET seedProjectId = ?, seedTaskIds = ? WHERE email = ?", projectId, JSON.stringify(taskIds), email);
  }

  /// The seed failed before it wrote anything: a later call tries again.
  dropSeed(email: string): void {
    this.sql.exec("UPDATE beta_testers SET seededAt = NULL WHERE email = ? AND seedProjectId IS NULL", email);
  }

  /// Granted testers whose seed never ran (granted before seeding shipped,
  /// or a seed that failed).
  unseeded(limit: number): BetaTester[] {
    return this.sql.exec(`SELECT ${TESTER_COLS} FROM beta_testers WHERE grantedUserId IS NOT NULL AND seededAt IS NULL ORDER BY grantedAt LIMIT ?`, limit)
      .toArray().map((r) => ({ ...r }) as unknown as BetaTester);
  }

  dismissCard(userId: string, now: number): boolean {
    return this.sql.exec("UPDATE beta_testers SET cardDismissedAt = COALESCE(cardDismissedAt, ?) WHERE grantedUserId = ?", now, userId).rowsWritten > 0;
  }

  saveUsage(email: string, next: BetaUsage, now: number): BetaUsage {
    const merged = mergeUsage(parseUsage(this.tester(email)?.usage ?? null), next);
    this.sql.exec("UPDATE beta_testers SET usage = ?, usageAt = ? WHERE email = ?", JSON.stringify(merged), now, email);
    return merged;
  }

  /// Granted testers whose usage is oldest (the hourly refresh).
  staleUsage(before: number, limit: number): BetaTester[] {
    return this.sql.exec(
      `SELECT ${TESTER_COLS} FROM beta_testers WHERE grantedUserId IS NOT NULL AND COALESCE(usageAt, 0) < ? ORDER BY COALESCE(usageAt, 0) LIMIT ?`,
      before, limit,
    ).toArray().map((r) => ({ ...r }) as unknown as BetaTester);
  }

  /// Testers whose day-7 question is due: invited, joined before
  /// `joinedBefore`, not asked yet.
  questionsDue(joinedBefore: number, limit = 50): BetaTester[] {
    return this.sql.exec(
      `SELECT ${TESTER_COLS} FROM beta_testers WHERE ascState = 'invited' AND questionSentAt IS NULL AND joinedAt < ? ORDER BY joinedAt LIMIT ?`,
      joinedBefore, limit,
    ).toArray().map((r) => ({ ...r }) as unknown as BetaTester);
  }

  /// Marks the question sent with its link's token hash. False when another
  /// sweep took it first.
  takeQuestion(email: string, tokenHash: string, now: number): boolean {
    return this.sql.exec(
      "UPDATE beta_testers SET questionSentAt = ?, answerTokenHash = ? WHERE email = ? AND questionSentAt IS NULL", now, tokenHash, email,
    ).rowsWritten > 0;
  }

  /// Records an answer; a later one replaces it. False for an unknown token.
  answer(tokenHash: string, answer: BetaAnswer, now: number): boolean {
    return this.sql.exec("UPDATE beta_testers SET answer = ?, answeredAt = ? WHERE answerTokenHash = ?", answer, now, tokenHash).rowsWritten > 0;
  }

  hasAnswerToken(tokenHash: string): boolean {
    return this.sql.exec("SELECT 1 FROM beta_testers WHERE answerTokenHash = ?", tokenHash).toArray().length > 0;
  }

  /// Account deletion: the grant, the seed and what the account did go
  /// with the account; the tester and their day-7 answer stay.
  forgetUser(userId: string): void {
    this.sql.exec(`UPDATE beta_testers SET grantedUserId = NULL, grantedAt = NULL, seededAt = NULL, seedProjectId = NULL,
      seedTaskIds = NULL, cardDismissedAt = NULL, usage = NULL, usageAt = NULL WHERE grantedUserId = ?`, userId);
  }
}
