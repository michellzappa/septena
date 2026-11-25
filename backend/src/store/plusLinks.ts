import { randomId } from "../util.js";

// Plus links (ADR 0043): mz gives Plus to people with a link. The link is a
// secret, stored hashed. A signed-in account claims it once; the claim writes
// the `grant:<link id>` entitlement row in that account's own store
// (src/api/plusLinks.ts). The two controls copy the list-sharing links people
// know: close (nobody new) and revoke (everyone who used it loses it).

export const PLUS_LINK_MAX_USES = 500;
export const PLUS_LINK_MAX_MONTHS = 60;

export interface PlusLinkInput {
  label: string;
  /// How long Plus lasts from the claim; null = no end.
  months: number | null;
  maxUses: number;
}

export interface PlusLink extends PlusLinkInput {
  id: string;
  useCount: number;
  createdAt: number;
  closedAt: number | null;
  revokedAt: number | null;
}

export interface PlusLinkUse {
  linkId: string;
  userId: string;
  at: number;
  expiresAt: number | null;
  revokedAt: number | null;
}

export type PlusLinkClaim =
  | { ok: true; linkId: string; label: string; expiresAt: number | null }
  | { ok: false };

/// The entitlement row a claim writes: one per link and account.
export const plusLinkGrantId = (linkId: string) => `grant:${linkId}`;

export function addMonths(at: number, months: number): number {
  const d = new Date(at);
  const day = d.getUTCDate();
  d.setUTCMonth(d.getUTCMonth() + months, 1);
  const last = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
  d.setUTCDate(Math.min(day, last));
  return d.getTime();
}

const LINK_COLS = "id, label, months, maxUses, useCount, createdAt, closedAt, revokedAt";
const USE_COLS = "linkId, userId, at, expiresAt, revokedAt";

export class PlusLinks {
  private sql: SqlStorage;

  constructor(sql: SqlStorage) {
    this.sql = sql;
  }

  migrate(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS plus_links (
        id TEXT PRIMARY KEY, tokenHash TEXT NOT NULL UNIQUE, label TEXT NOT NULL,
        months INTEGER, maxUses INTEGER NOT NULL, useCount INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL, closedAt INTEGER, revokedAt INTEGER
      );
      CREATE TABLE IF NOT EXISTS plus_link_uses (
        linkId TEXT NOT NULL, userId TEXT NOT NULL, at INTEGER NOT NULL,
        expiresAt INTEGER, revokedAt INTEGER,
        PRIMARY KEY (linkId, userId)
      );
      CREATE INDEX IF NOT EXISTS plus_link_uses_user ON plus_link_uses(userId);
    `);
  }

  private row(column: "id" | "tokenHash", value: string): PlusLink | null {
    const r = this.sql.exec(`SELECT ${LINK_COLS} FROM plus_links WHERE ${column} = ?`, value).toArray()[0];
    return r ? { ...r } as unknown as PlusLink : null;
  }

  private use(linkId: string, userId: string): PlusLinkUse | null {
    const r = this.sql.exec(`SELECT ${USE_COLS} FROM plus_link_uses WHERE linkId = ? AND userId = ?`, linkId, userId).toArray()[0];
    return r ? { ...r } as unknown as PlusLinkUse : null;
  }

  create(tokenHash: string, input: PlusLinkInput, now: number): PlusLink {
    // Lowercase: the id is part of the grant's entitlement row id.
    const id = `link-${randomId(12).toLowerCase().replace(/[^a-z0-9]/g, "0")}`;
    this.sql.exec(
      "INSERT INTO plus_links (id, tokenHash, label, months, maxUses, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
      id, tokenHash, input.label, input.months, input.maxUses, now,
    );
    return this.row("id", id)!;
  }

  list(): PlusLink[] {
    return this.sql.exec(`SELECT ${LINK_COLS} FROM plus_links ORDER BY createdAt DESC, id`).toArray()
      .map((r) => ({ ...r }) as unknown as PlusLink);
  }

  uses(): PlusLinkUse[] {
    return this.sql.exec(`SELECT ${USE_COLS} FROM plus_link_uses ORDER BY at`).toArray()
      .map((r) => ({ ...r }) as unknown as PlusLinkUse);
  }

  /// The link behind a token while a new account may still claim it.
  open(tokenHash: string): PlusLink | null {
    const link = this.row("tokenHash", tokenHash);
    return link && link.closedAt === null && link.revokedAt === null && link.useCount < link.maxUses ? link : null;
  }

  /// Claiming again with the same account answers the same grant, so a lost
  /// reply repeats safely and never takes a second use.
  claim(tokenHash: string, userId: string, now: number): PlusLinkClaim {
    const link = this.row("tokenHash", tokenHash);
    if (!link || link.revokedAt !== null) return { ok: false };
    const had = this.use(link.id, userId);
    if (had) {
      return had.revokedAt === null
        ? { ok: true, linkId: link.id, label: link.label, expiresAt: had.expiresAt }
        : { ok: false };
    }
    if (!this.open(tokenHash)) return { ok: false };
    const expiresAt = link.months === null ? null : addMonths(now, link.months);
    this.sql.exec("INSERT INTO plus_link_uses (linkId, userId, at, expiresAt) VALUES (?, ?, ?, ?)", link.id, userId, now, expiresAt);
    this.sql.exec("UPDATE plus_links SET useCount = useCount + 1 WHERE id = ?", link.id);
    return { ok: true, linkId: link.id, label: link.label, expiresAt };
  }

  /// False when the claim was revoked while its grant was on the way.
  isLive(linkId: string, userId: string): boolean {
    const link = this.row("id", linkId);
    const use = this.use(linkId, userId);
    return link !== null && link.revokedAt === null && use !== null && use.revokedAt === null;
  }

  close(id: string, now: number): boolean {
    if (!this.row("id", id)) return false;
    this.sql.exec("UPDATE plus_links SET closedAt = COALESCE(closedAt, ?) WHERE id = ?", now, id);
    return true;
  }

  /// Ends the link for everyone, or for one account. Returns the accounts
  /// whose grant row must go; repeating it returns them again. Null when there
  /// is no such link or use.
  revoke(id: string, userId: string | null, now: number): string[] | null {
    if (!this.row("id", id)) return null;
    if (userId !== null) {
      if (!this.use(id, userId)) return null;
      this.sql.exec("UPDATE plus_link_uses SET revokedAt = COALESCE(revokedAt, ?) WHERE linkId = ? AND userId = ?", now, id, userId);
      return [userId];
    }
    this.sql.exec("UPDATE plus_links SET revokedAt = COALESCE(revokedAt, ?), closedAt = COALESCE(closedAt, ?) WHERE id = ?", now, now, id);
    this.sql.exec("UPDATE plus_link_uses SET revokedAt = COALESCE(revokedAt, ?) WHERE linkId = ?", now, id);
    return this.sql.exec<{ userId: string }>("SELECT userId FROM plus_link_uses WHERE linkId = ?", id).toArray().map((r) => r.userId);
  }

  /// Account deletion. The link keeps its count, so a deleted account does not
  /// free a use.
  forgetUser(userId: string): void {
    this.sql.exec("DELETE FROM plus_link_uses WHERE userId = ?", userId);
  }
}
