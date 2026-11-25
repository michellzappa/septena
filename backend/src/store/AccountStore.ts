import { DurableObject } from "cloudflare:workers";
import type { Env } from "../env.js";
import { randomId } from "../util.js";

// AccountStore — global Durable Object (SQLite) holding the identity table
// (ADR 0016, issue #168). Maps `provider:subject` (e.g. `apple:<sub>`,
// `email:<normalized>`) to the account's `userId` (`u_…`).
//
// Existing Apple accounts keep their derived `u_` id (`userIdForAppleSub`);
// `/v1/auth/apple` records `apple:<sub>` here on sign-in. Accounts created
// from non-Apple providers get a random `u_` id minted by `newUserId()`.
// Deleting an account wipes all of its rows here (`deleteIdentitiesForUser`).

/// Canonical backend user id shape — shared with the `/v1/admin/*` validators.
export const USER_ID_RE = /^u_[A-Za-z0-9_-]{20,64}$/;

const PROVIDER_RE = /^[a-z][a-z0-9_-]{0,31}$/;

/// Single global instance name for the identity table DO.
export const GLOBAL_ACCOUNT_STORE_NAME = "global";

export type IdentityProvider = "apple" | "email" | (string & {});

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

export function identityKey(provider: string, subject: string): string {
  const p = normalizeProvider(provider);
  const s = normalizeSubject(p, subject);
  return `${p}:${s}`;
}

/// Returns the global `AccountStore` stub, or null when the binding is absent
/// (e.g. in unit tests that exercise unrelated routes without binding it).
export function accountStoreFor(env: Env): DurableObjectStub<AccountStore> | null {
  if (!env.ACCOUNT_STORE) return null;
  return env.ACCOUNT_STORE.get(env.ACCOUNT_STORE.idFromName(GLOBAL_ACCOUNT_STORE_NAME));
}

export class AccountStore extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    ctx.blockConcurrencyWhile(async () => {
      this.migrate();
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
    `);
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
  resolveIdentity(provider: string, subject: string): IdentityRow | null {
    return this.selectByKey(identityKey(provider, subject));
  }

  /// Resolves `provider:subject` to its `userId`, inserting a row on first
  /// sign-in. Pass `preferredUserId` when an existing deterministic id must be
  /// preserved (Apple's derived `u_` id); omit it for non-Apple providers so a
  /// fresh random `u_` id is minted on creation.
  resolveOrCreateIdentity(
    provider: string,
    subject: string,
    preferredUserId?: string,
    now = Date.now(),
  ): ResolveIdentityResult {
    const p = normalizeProvider(provider);
    const s = normalizeSubject(p, subject);
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
  linkIdentity(provider: string, subject: string, userId: string, now = Date.now()): LinkIdentityResult {
    if (!USER_ID_RE.test(userId)) {
      throw new Error("invalid userId");
    }
    const p = normalizeProvider(provider);
    const s = normalizeSubject(p, subject);
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

  /// Removes every identity row for `userId` (called by `DELETE /v1/account`).
  deleteIdentitiesForUser(userId: string): number {
    return this.sql.exec("DELETE FROM identities WHERE userId = ?", userId).rowsWritten;
  }
}
