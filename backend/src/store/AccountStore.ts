import { DurableObject } from "cloudflare:workers";
import type { Env } from "../env.js";
import { randomId, sha256Base64Url } from "../util.js";
import type { AccountSummary } from "./TaskStore.js";
import { PlusLinks, type PlusLink, type PlusLinkClaim, type PlusLinkInput, type PlusLinkUse } from "./plusLinks.js";

// AccountStore — global Durable Object (SQLite) holding the identity table
// (ADR 0016, issue #168). Maps `provider:subject` (e.g. `apple:<sub>`,
// `email:<normalized>`) to the account's `userId` (`u_…`).
//
// Existing Apple accounts keep their derived `u_` id (`userIdForAppleSub`);
// `/v1/auth/apple` records `apple:<sub>` here on sign-in. Accounts created
// from non-Apple providers get a random `u_` id minted by `newUserId()`.
// Deleting an account wipes all of its rows here (`deleteIdentitiesForUser`).
//
// It also holds what the admin page reads (ADR 0043, src/admin/): the index of
// accounts with a daily summary of counts, and the Plus links.

/// Canonical backend user id shape — shared with the `/v1/admin/*` validators.
export const USER_ID_RE = /^u_[A-Za-z0-9_-]{20,64}$/;

const PROVIDER_RE = /^[a-z][a-z0-9_-]{0,31}$/;

/// Single global instance name for the identity table DO.
export const GLOBAL_ACCOUNT_STORE_NAME = "global";

export type IdentityProvider = "apple" | "email" | (string & {});

/// The subject as stored. An id from a sign-in provider (Apple, and any added
/// later) is opaque, so a hash finds the account as well as the id does and
/// the id itself is never kept. An email address stays readable: ADR 0016
/// sends codes and recovery mail to it.
export async function storedSubject(provider: string, subject: string): Promise<string> {
  const p = normalizeProvider(provider);
  const s = normalizeSubject(p, subject);
  return p === "email" ? s : `h_${await sha256Base64Url(`${p}:${s}`)}`;
}

/// One account on the admin page.
export interface AccountIndexRow {
  userId: string;
  createdAt: number;
  refreshedAt: number;
  providers: string[];
  summary: AccountSummary | null;
  plusLinks: { id: string; label: string }[];
}

export interface IdentityRow {
  key: string;
  provider: string;
  subject: string;
  userId: string;
  createdAt: number;
  updatedAt: number;
}

export interface ResolveIdentityResult {
  userId: string;
  created: boolean;
  row: IdentityRow;
}

export type LinkIdentityResult =
  | { ok: true; created: boolean; row: IdentityRow }
  | { ok: false; reason: "already_linked" };

/// Email sign-in codes (ADR 0016 decision 2, issue #169).
export const EMAIL_CODE_TTL_MS = 10 * 60 * 1000;
export const EMAIL_CODE_WINDOW_MS = 10 * 60 * 1000;
export const EMAIL_CODE_MAX_SENDS = 3;
export const EMAIL_CODE_MAX_ATTEMPTS = 5;

export type IssueEmailCodeResult =
  | { ok: true; expiresAt: number }
  | { ok: false; reason: "locked" | "rate_limited"; retryAfterMs: number };

export type CheckEmailCodeResult =
  | { status: "ok" }
  | { status: "invalid"; attemptsLeft: number }
  | { status: "expired" }
  | { status: "locked" };

/// Mints a random `u_` user id for a new account from a non-Apple provider.
/// 32 random bytes base64url-encoded = 43 chars, matching `USER_ID_RE`.
export function newUserId(): string {
  return `u_${randomId(32)}`;
}

export function normalizeProvider(provider: string): string {
  const normalized = provider.trim().toLowerCase();
  if (!PROVIDER_RE.test(normalized)) {
    throw new Error(`invalid identity provider: ${provider}`);
  }
  return normalized;
}

export function normalizeSubject(provider: string, subject: string): string {
  const trimmed = subject.trim();
  if (!trimmed) throw new Error("empty identity subject");
  return provider === "email" ? trimmed.toLowerCase() : trimmed;
}

/// Returns the global `AccountStore` stub, or null when the binding is absent
/// (e.g. in unit tests that exercise unrelated routes without binding it).
export function accountStoreFor(env: Env): DurableObjectStub<AccountStore> | null {
  if (!env.ACCOUNT_STORE) return null;
  return env.ACCOUNT_STORE.get(env.ACCOUNT_STORE.idFromName(GLOBAL_ACCOUNT_STORE_NAME));
}

export class AccountStore extends DurableObject<Env> {
  private sql: SqlStorage;
  private links: PlusLinks;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.links = new PlusLinks(this.sql);
    ctx.blockConcurrencyWhile(async () => {
      this.migrate();
      await this.hashSubjects();
    });
  }

  private migrate(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS identities (
        key       TEXT PRIMARY KEY,
        provider  TEXT NOT NULL,
        subject   TEXT NOT NULL,
        userId    TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_identities_userId ON identities(userId);
      CREATE TABLE IF NOT EXISTS account_index (
        userId      TEXT PRIMARY KEY,
        createdAt   INTEGER NOT NULL,
        refreshedAt INTEGER NOT NULL DEFAULT 0,
        summary     TEXT
      );
      CREATE TABLE IF NOT EXISTS store_meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS email_codes (
        email       TEXT PRIMARY KEY,
        codeHash    TEXT NOT NULL,
        expiresAt   INTEGER NOT NULL,
        attempts    INTEGER NOT NULL DEFAULT 0,
        sends       INTEGER NOT NULL DEFAULT 0,
        windowStart INTEGER NOT NULL,
        lockedUntil INTEGER NOT NULL DEFAULT 0
      );
    `);
    this.links.migrate();
  }

  /// Rows written before subjects were hashed (2026-11-24 to 25).
  private async hashSubjects(): Promise<void> {
    const raw = this.sql.exec<{ key: string; provider: string; subject: string }>(
      "SELECT key, provider, subject FROM identities WHERE provider != 'email' AND subject NOT LIKE 'h\\_%' ESCAPE '\\'",
    ).toArray();
    for (const r of raw) {
      const subject = await storedSubject(r.provider, r.subject);
      this.sql.exec("UPDATE identities SET key = ?, subject = ? WHERE key = ?", `${r.provider}:${subject}`, subject, r.key);
    }
  }

  private selectByKey(key: string): IdentityRow | null {
    const rows = this.sql.exec(
      "SELECT key, provider, subject, userId, createdAt, updatedAt FROM identities WHERE key = ?",
      key,
    ).toArray();
    if (!rows.length) return null;
    const r = rows[0];
    return {
      key: String(r.key),
      provider: String(r.provider),
      subject: String(r.subject),
      userId: String(r.userId),
      createdAt: Number(r.createdAt),
      updatedAt: Number(r.updatedAt),
    };
  }

  /// Read-only lookup for `provider:subject`.
  async resolveIdentity(provider: string, subject: string): Promise<IdentityRow | null> {
    return this.selectByKey(`${normalizeProvider(provider)}:${await storedSubject(provider, subject)}`);
  }

  /// Resolves `provider:subject` to its `userId`, inserting a row on first
  /// sign-in. Pass `preferredUserId` when an existing deterministic id must be
  /// preserved (Apple's derived `u_` id); omit it for non-Apple providers so a
  /// fresh random `u_` id is minted on creation.
  async resolveOrCreateIdentity(
    provider: string,
    subject: string,
    preferredUserId?: string,
    now = Date.now(),
  ): Promise<ResolveIdentityResult> {
    const p = normalizeProvider(provider);
    const s = await storedSubject(p, subject);
    const key = `${p}:${s}`;
    if (preferredUserId !== undefined && !USER_ID_RE.test(preferredUserId)) {
      throw new Error("invalid userId");
    }

    return this.ctx.storage.transactionSync(() => {
      const existing = this.selectByKey(key);
      if (existing) {
        this.sql.exec("UPDATE identities SET updatedAt = ? WHERE key = ?", now, key);
        const row: IdentityRow = { ...existing, updatedAt: now };
        return { userId: existing.userId, created: false, row };
      }

      const userId = preferredUserId ?? newUserId();
      this.sql.exec(
        "INSERT INTO identities (key, provider, subject, userId, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
        key,
        p,
        s,
        userId,
        now,
        now,
      );
      const row: IdentityRow = { key, provider: p, subject: s, userId, createdAt: now, updatedAt: now };
      return { userId, created: true, row };
    });
  }

  /// Attaches `provider:subject` to an existing signed-in `userId` (e.g.
  /// adding an email recovery identity to an Apple account). Refuses if the
  /// identity already belongs to a different account.
  async linkIdentity(provider: string, subject: string, userId: string, now = Date.now()): Promise<LinkIdentityResult> {
    if (!USER_ID_RE.test(userId)) {
      throw new Error("invalid userId");
    }
    const p = normalizeProvider(provider);
    const s = await storedSubject(p, subject);
    const key = `${p}:${s}`;

    return this.ctx.storage.transactionSync(() => {
      const existing = this.selectByKey(key);
      if (existing) {
        if (existing.userId !== userId) {
          return { ok: false as const, reason: "already_linked" as const };
        }
        this.sql.exec("UPDATE identities SET updatedAt = ? WHERE key = ?", now, key);
        return { ok: true as const, created: false, row: { ...existing, updatedAt: now } };
      }

      this.sql.exec(
        "INSERT INTO identities (key, provider, subject, userId, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
        key,
        p,
        s,
        userId,
        now,
        now,
      );
      const row: IdentityRow = { key, provider: p, subject: s, userId, createdAt: now, updatedAt: now };
      return { ok: true as const, created: true, row };
    });
  }

  /// Stores a new sign-in code for `email` (ADR 0016, issue #169), replacing
  /// any earlier one. Refuses while the address is locked after too many wrong
  /// codes, or when it has had `EMAIL_CODE_MAX_SENDS` codes in this window.
  issueEmailCode(email: string, codeHash: string, now = Date.now()): IssueEmailCodeResult {
    const e = normalizeSubject("email", email);
    return this.ctx.storage.transactionSync(() => {
      const row = this.sql.exec<{ sends: number; windowStart: number; lockedUntil: number }>(
        "SELECT sends, windowStart, lockedUntil FROM email_codes WHERE email = ?", e,
      ).toArray()[0];
      if (row && row.lockedUntil > now) {
        return { ok: false as const, reason: "locked" as const, retryAfterMs: row.lockedUntil - now };
      }
      const inWindow = row && now - row.windowStart < EMAIL_CODE_WINDOW_MS;
      const sends = inWindow ? row.sends : 0;
      const windowStart = inWindow ? row.windowStart : now;
      if (sends >= EMAIL_CODE_MAX_SENDS) {
        return { ok: false as const, reason: "rate_limited" as const, retryAfterMs: windowStart + EMAIL_CODE_WINDOW_MS - now };
      }
      this.sql.exec(
        `INSERT INTO email_codes (email, codeHash, expiresAt, attempts, sends, windowStart, lockedUntil)
         VALUES (?, ?, ?, 0, ?, ?, 0)
         ON CONFLICT(email) DO UPDATE SET codeHash = excluded.codeHash, expiresAt = excluded.expiresAt,
           attempts = 0, sends = excluded.sends, windowStart = excluded.windowStart, lockedUntil = 0`,
        e, codeHash, now + EMAIL_CODE_TTL_MS, sends + 1, windowStart,
      );
      return { ok: true as const, expiresAt: now + EMAIL_CODE_TTL_MS };
    });
  }

  /// Checks a code. A right code is spent at once. Five wrong codes lock the
  /// address until the send window ends, and a new code does not unlock it.
  checkEmailCode(email: string, codeHash: string, now = Date.now()): CheckEmailCodeResult {
    const e = normalizeSubject("email", email);
    return this.ctx.storage.transactionSync(() => {
      const row = this.sql.exec<{ codeHash: string; expiresAt: number; attempts: number; windowStart: number; lockedUntil: number }>(
        "SELECT codeHash, expiresAt, attempts, windowStart, lockedUntil FROM email_codes WHERE email = ?", e,
      ).toArray()[0];
      if (!row) return { status: "expired" as const };
      if (row.lockedUntil > now) return { status: "locked" as const };
      if (row.expiresAt <= now || row.codeHash === "") return { status: "expired" as const };
      if (row.codeHash === codeHash) {
        // Keep the row for its send count; blank the code so it cannot be used twice.
        this.sql.exec("UPDATE email_codes SET codeHash = '', attempts = 0 WHERE email = ?", e);
        return { status: "ok" as const };
      }
      const attempts = row.attempts + 1;
      if (attempts >= EMAIL_CODE_MAX_ATTEMPTS) {
        const lockedUntil = Math.max(row.windowStart + EMAIL_CODE_WINDOW_MS, now + EMAIL_CODE_TTL_MS);
        this.sql.exec("UPDATE email_codes SET codeHash = '', attempts = ?, lockedUntil = ? WHERE email = ?", attempts, lockedUntil, e);
        return { status: "locked" as const };
      }
      this.sql.exec("UPDATE email_codes SET attempts = ? WHERE email = ?", attempts, e);
      return { status: "invalid" as const, attemptsLeft: EMAIL_CODE_MAX_ATTEMPTS - attempts };
    });
  }

  /// All identities currently mapped to `userId`.
  listIdentitiesForUser(userId: string): IdentityRow[] {
    return this.sql.exec(
      "SELECT key, provider, subject, userId, createdAt, updatedAt FROM identities WHERE userId = ? ORDER BY createdAt ASC, key ASC",
      userId,
    ).toArray().map((r) => ({
      key: String(r.key),
      provider: String(r.provider),
      subject: String(r.subject),
      userId: String(r.userId),
      createdAt: Number(r.createdAt),
      updatedAt: Number(r.updatedAt),
    }));
  }

  /// Removes everything this store holds about `userId` (called by `DELETE
  /// /v1/account`). Returns how many identity rows went.
  deleteIdentitiesForUser(userId: string): number {
    return this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM account_index WHERE userId = ?", userId);
      this.links.forgetUser(userId);
      this.sql.exec(
        "DELETE FROM email_codes WHERE email IN (SELECT subject FROM identities WHERE userId = ? AND provider = 'email')",
        userId,
      );
      return this.sql.exec("DELETE FROM identities WHERE userId = ?", userId).rowsWritten;
    });
  }

  // ---- account index (ADR 0043, src/admin/accounts.ts) ----

  /// True until the accounts from before the identity table are in the index.
  needsSeed(): boolean {
    return this.sql.exec("SELECT 1 FROM store_meta WHERE key = 'accountsSeeded'").toArray().length === 0;
  }

  seedAccounts(userIds: string[], now = Date.now()): void {
    this.ctx.storage.transactionSync(() => {
      for (const id of userIds) {
        if (USER_ID_RE.test(id)) this.sql.exec("INSERT OR IGNORE INTO account_index (userId, createdAt) VALUES (?, ?)", id, now);
      }
      this.sql.exec("INSERT OR REPLACE INTO store_meta (key, value) VALUES ('accountsSeeded', ?)", now);
    });
  }

  /// The accounts whose summary is older than `before`, oldest first.
  accountsToRefresh(before: number, limit: number): string[] {
    this.sql.exec(
      "INSERT OR IGNORE INTO account_index (userId, createdAt) SELECT userId, MIN(createdAt) FROM identities GROUP BY userId",
    );
    return this.sql.exec<{ userId: string }>(
      "SELECT userId FROM account_index WHERE refreshedAt < ? ORDER BY refreshedAt, userId LIMIT ?", before, limit,
    ).toArray().map((r) => r.userId);
  }

  /// An update only: an account deleted while its summary was on the way stays
  /// deleted. A null summary is an empty store; without an identity it is not
  /// an account (any more).
  saveSummaries(rows: { userId: string; summary: AccountSummary | null }[], now = Date.now()): void {
    this.ctx.storage.transactionSync(() => {
      for (const { userId, summary } of rows) {
        this.sql.exec(
          "UPDATE account_index SET summary = ?, refreshedAt = ? WHERE userId = ?",
          summary === null ? null : JSON.stringify(summary), now, userId,
        );
        if (summary === null) {
          this.sql.exec("DELETE FROM account_index WHERE userId = ? AND userId NOT IN (SELECT userId FROM identities)", userId);
        }
      }
    });
  }

  hasAccount(userId: string): boolean {
    return this.sql.exec("SELECT 1 FROM account_index WHERE userId = ?", userId).toArray().length > 0;
  }

  listAccounts(): AccountIndexRow[] {
    const providers = new Map<string, Set<string>>();
    for (const r of this.sql.exec<{ userId: string; provider: string }>("SELECT userId, provider FROM identities ORDER BY createdAt").toArray()) {
      providers.set(r.userId, (providers.get(r.userId) ?? new Set()).add(r.provider));
    }
    const labels = new Map(this.links.list().map((l) => [l.id, l.label]));
    const links = new Map<string, { id: string; label: string }[]>();
    for (const u of this.links.uses()) {
      if (u.revokedAt !== null) continue;
      links.set(u.userId, [...(links.get(u.userId) ?? []), { id: u.linkId, label: labels.get(u.linkId) ?? u.linkId }]);
    }
    return this.sql.exec<{ userId: string; createdAt: number; refreshedAt: number; summary: string | null }>(
      "SELECT userId, createdAt, refreshedAt, summary FROM account_index ORDER BY createdAt DESC, userId",
    ).toArray().map((r) => {
      const summary = r.summary === null ? null : JSON.parse(r.summary) as AccountSummary;
      return {
        userId: r.userId,
        createdAt: summary?.firstSeen ? Math.min(r.createdAt, summary.firstSeen) : r.createdAt,
        refreshedAt: r.refreshedAt,
        providers: [...(providers.get(r.userId) ?? [])],
        summary,
        plusLinks: links.get(r.userId) ?? [],
      };
    });
  }

  // ---- Plus links (src/store/plusLinks.ts) ----

  createPlusLink(tokenHash: string, input: PlusLinkInput, now = Date.now()): PlusLink {
    return this.links.create(tokenHash, input, now);
  }

  listPlusLinks(): { links: PlusLink[]; uses: PlusLinkUse[] } {
    return { links: this.links.list(), uses: this.links.uses() };
  }

  openPlusLink(tokenHash: string): PlusLink | null {
    return this.links.open(tokenHash);
  }

  claimPlusLink(tokenHash: string, userId: string, now = Date.now()): PlusLinkClaim {
    return this.ctx.storage.transactionSync(() => this.links.claim(tokenHash, userId, now));
  }

  plusLinkIsLive(linkId: string, userId: string): boolean {
    return this.links.isLive(linkId, userId);
  }

  closePlusLink(id: string, now = Date.now()): boolean {
    return this.links.close(id, now);
  }

  revokePlusLink(id: string, userId: string | null, now = Date.now()): string[] | null {
    return this.ctx.storage.transactionSync(() => this.links.revoke(id, userId, now));
  }
}
