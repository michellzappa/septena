// The sessions of one user (ADR 0040): one sign-in on one install, or one
// connected agent. The user's Durable Object is the only authority, so every
// read and write here is strongly consistent.
//
// A session (`sid`) is a chain of refresh tokens, stored hashed. A renewal
// mints a child. The parent stays valid until the child is USED, because a
// client that never got the reply still holds the parent. First use of the
// child, as a refresh token or through its access token, retires the parent.
// A retired token presented after the leeway means two holders: the whole
// session ends.

/// Two holders of one token that race (two processes of one app, two workers
/// of one connector) settle inside this window. After it, reuse is theft.
export const SESSION_LEEWAY_MS = 30_000;
/// A used access token may outlive its retired refresh token by its own hour.
/// Retired rows stay a little longer than that. The first row of a session
/// stays as long as the session: a token from before ADR 0040 carries no
/// session id, so its row is the only thing that tells reuse from noise.
const RETIRED_TTL_MS = 2 * 60 * 60 * 1000;
/// Longer than the 30 days an agent token from before ADR 0040 can live.
const ENDED_TTL_MS = 31 * 24 * 60 * 60 * 1000;
/// Unused children one parent may have (replies lost in a row).
const MAX_UNUSED_CHILDREN = 8;

/// Set by the Worker on a stream request (never by the client): the session
/// that opened it, so ending the session closes it.
export const SESSION_HEADER = "X-Septena-Session";

export interface SessionGrant {
  clientId: string;
  scope: string;
  timeZone?: string;
}

export type RenewResult =
  | { ok: true; grant: SessionGrant | null }
  | { ok: false; reason: "not_found" | "expired" | "reused" | "client_mismatch" };

type SessionRow = {
  hash: string;
  sid: string | null;
  parent: string | null;
  createdAt: number;
  expiresAt: number;
  usedAt: number | null;
  retiredAt: number | null;
  accessRevokedAt: number | null;
  grantJson: string | null;
};

const COLUMNS: Record<string, string> = {
  // The session's stable id. It survives renewal, so it names the device for
  // the sync slot. For an agent it is the token family.
  sid: "TEXT",
  parent: "TEXT",
  usedAt: "INTEGER",
  retiredAt: "INTEGER",
  accessRevokedAt: "INTEGER",
  // What an agent may do. Null = an app session.
  grantJson: "TEXT",
};

export class SessionBook {
  private sql: SqlStorage;

  constructor(sql: SqlStorage) {
    this.sql = sql;
  }

  migrate(): void {
    const have = new Set(this.sql.exec<{ name: string }>("PRAGMA table_info(sessions)").toArray().map((r) => r.name));
    for (const [name, type] of Object.entries(COLUMNS)) {
      if (!have.has(name)) this.sql.exec(`ALTER TABLE sessions ADD COLUMN ${name} ${type}`);
    }
    this.sql.exec("CREATE INDEX IF NOT EXISTS sessions_sid ON sessions(sid)");
    this.sql.exec("CREATE TABLE IF NOT EXISTS ended_sessions (sid TEXT PRIMARY KEY, at INTEGER NOT NULL)");
  }

  create(hash: string, expiresAt: number, sid: string, grant: SessionGrant | null = null, now = Date.now()): void {
    this.insert(hash, sid, null, expiresAt, grant ? JSON.stringify(grant) : null, now);
  }

  /// The session id of a refresh token from before ids rode in the token. A
  /// row from before session ids gets one now.
  idFor(hash: string): string | null {
    const row = this.row(hash);
    if (!row) return null;
    if (row.sid) return row.sid;
    const sid = crypto.randomUUID();
    this.sql.exec("UPDATE sessions SET sid = ? WHERE hash = ?", sid, hash);
    return sid;
  }

  /// Trades the refresh token `hash` for `newHash`. `sid` comes from the
  /// signed token, so a hash it does not know is a token it once issued.
  /// "reused" asks the caller to end the session.
  renew(hash: string, newHash: string, expiresAt: number, sid: string, clientId: string | null, now = Date.now()): RenewResult {
    const row = this.row(hash);
    if (!row || row.sid !== sid) return { ok: false, reason: this.exists(sid) ? "reused" : "not_found" };
    const grant = row.grantJson ? JSON.parse(row.grantJson) as SessionGrant : null;
    // An app token never renews an agent session, nor the reverse.
    if ((grant?.clientId ?? null) !== clientId) return { ok: false, reason: "client_mismatch" };
    if (row.retiredAt !== null && now - row.retiredAt > SESSION_LEEWAY_MS) return { ok: false, reason: "reused" };
    if (row.expiresAt < now) return { ok: false, reason: "expired" };
    if (row.usedAt === null) this.use(row, now);
    this.insert(newHash, sid, hash, expiresAt, row.grantJson, now);
    this.sql.exec(
      "UPDATE sessions SET retiredAt = ? WHERE hash IN (SELECT hash FROM sessions WHERE parent = ? AND usedAt IS NULL AND retiredAt IS NULL ORDER BY createdAt DESC, rowid DESC LIMIT -1 OFFSET ?)",
      now, hash, MAX_UNUSED_CHILDREN,
    );
    this.sql.exec("DELETE FROM sessions WHERE sid = ? AND parent IS NOT NULL AND retiredAt < ?", sid, now - RETIRED_TTL_MS);
    return { ok: true, grant };
  }

  /// Is the access token that came with refresh token `hash` still good? Its
  /// first use is the proof that the client got the reply. `hash` is null for
  /// an access token signed before this model (at most one hour).
  authorize(sid: string, hash: string | null, now = Date.now()): { grant: SessionGrant | null } | null {
    if (hash === null) {
      const live = this.sql.exec<{ grantJson: string | null }>(
        "SELECT grantJson FROM sessions WHERE sid = ? AND retiredAt IS NULL AND expiresAt >= ? LIMIT 1", sid, now,
      ).toArray()[0];
      return live && live.grantJson === null ? { grant: null } : null;
    }
    const row = this.row(hash);
    if (!row || row.sid !== sid || row.accessRevokedAt !== null || row.expiresAt < now) return null;
    if (row.usedAt === null) {
      // A sibling won and the leeway is over: this reply has no live holder.
      if (row.retiredAt !== null && now - row.retiredAt > SESSION_LEEWAY_MS) return null;
      this.use(row, now);
    }
    return { grant: row.grantJson ? JSON.parse(row.grantJson) as SessionGrant : null };
  }

  /// RFC 7009 on an access token: that token only.
  revokeAccess(sid: string, hash: string, now = Date.now()): boolean {
    const row = this.row(hash);
    if (!row || row.sid !== sid) return false;
    this.sql.exec("UPDATE sessions SET accessRevokedAt = ? WHERE hash = ?", now, hash);
    return true;
  }

  exists(sid: string): boolean {
    return this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM sessions WHERE sid = ?", sid).one().n > 0;
  }

  isAgent(sid: string): boolean {
    return this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM sessions WHERE sid = ? AND grantJson IS NOT NULL", sid).one().n > 0;
  }

  hasAppSession(now = Date.now()): boolean {
    return this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM sessions WHERE grantJson IS NULL AND retiredAt IS NULL AND expiresAt >= ?", now).one().n > 0;
  }

  hasEnded(sid: string): boolean {
    return this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM ended_sessions WHERE sid = ?", sid).one().n > 0;
  }

  /// Deletes the session and remembers that it ended. Returns its refresh hashes.
  end(sid: string, now = Date.now()): string[] {
    this.sql.exec("INSERT INTO ended_sessions (sid, at) VALUES (?, ?) ON CONFLICT(sid) DO UPDATE SET at = excluded.at", sid, now);
    const hashes = this.sql.exec<{ hash: string }>("SELECT hash FROM sessions WHERE sid = ?", sid).toArray().map((r) => r.hash);
    this.sql.exec("DELETE FROM sessions WHERE sid = ?", sid);
    return hashes;
  }

  purge(now: number): void {
    this.sql.exec("DELETE FROM sessions WHERE expiresAt < ? OR (parent IS NOT NULL AND retiredAt < ?)", now, now - RETIRED_TTL_MS);
    // A lone retired first row is no session.
    this.sql.exec("DELETE FROM sessions WHERE retiredAt IS NOT NULL AND sid NOT IN (SELECT sid FROM sessions WHERE retiredAt IS NULL AND sid IS NOT NULL)");
    this.sql.exec("DELETE FROM ended_sessions WHERE at < ?", now - ENDED_TTL_MS);
  }

  /// First use of a token: everything else in the session retires, except a
  /// sibling from the same parent that is already in use (the race above).
  private use(row: SessionRow, now: number): void {
    this.sql.exec("UPDATE sessions SET usedAt = ?, retiredAt = NULL WHERE hash = ?", now, row.hash);
    this.sql.exec(
      "UPDATE sessions SET retiredAt = ? WHERE sid = ? AND hash != ? AND retiredAt IS NULL AND (usedAt IS NULL OR parent IS NOT ?)",
      now, row.sid, row.hash, row.parent,
    );
  }

  private row(hash: string): SessionRow | null {
    return this.sql.exec<SessionRow>("SELECT * FROM sessions WHERE hash = ?", hash).toArray()[0] ?? null;
  }

  private insert(hash: string, sid: string, parent: string | null, expiresAt: number, grantJson: string | null, now: number): void {
    this.sql.exec(
      "INSERT INTO sessions (hash, sid, parent, createdAt, expiresAt, grantJson) VALUES (?, ?, ?, ?, ?, ?)",
      hash, sid, parent, now, expiresAt, grantJson,
    );
  }
}
