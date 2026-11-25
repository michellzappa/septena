import { DurableObject } from "cloudflare:workers";
import type { Env } from "../env.js";
import { logEvent, randomId, sha256Base64Url } from "../util.js";
import { storeFor } from "../api/session.js";
import { ENTITY_LIMITS } from "../generated/registries.js";
import { mergeNotes } from "./mergeText.js";
import {
  INVITE_TTL_MS,
  MAX_MEMBERS,
  MAX_OPEN_INVITES,
  MAX_SHARED_ROWS,
  SHARE_BATCH,
  SHARED_PROJECT_ROW,
  acceptedFields,
  isSharedEntity,
  newMemberId,
  type ShareDelivery,
  type ShareEnded,
  type ShareFields,
  type ShareInfo,
  type ShareMember,
  type ShareOp,
  type SharePushResult,
  type ShareRow,
  type ShareRowsResult,
  type SharedEntity,
} from "./shares.js";

// ProjectStore — one Durable Object per shared project (ADR 0004, ADR 0042).
//
// The authority for the project's shared fields, its members and its invites.
// Every method that acts for a person takes the caller's `userId`, which the
// Worker took from a verified session, and checks membership here. Changes
// are last-writer-wins per field, in the order they arrive. Notes are merged
// instead: two members who write at once both keep their words. Each member's
// TaskStore gets the current state of every row it has not seen.
//
// A store that was never created holds no tables, so a made-up id costs no
// storage.

const RETRY_MS = 30_000;
const APPLIED_OP_TTL_MS = 30 * 24 * 60 * 60 * 1000;
/// How long a project that ended for everyone keeps its rows.
const CLOSED_TTL_MS = 24 * 60 * 60 * 1000;

export interface InviteView {
  id: string;
  createdAt: number;
  expiresAt: number;
}

export type JoinResult =
  | { ok: true; shareId: string; title: string; memberId: string }
  | { ok: false; reason: "invalid" | "full" };

type MemberRow = {
  userId: string; memberId: string; name: string; role: "owner" | "editor"; joinedAt: number;
  endedAt: number | null; keepCopy: number; deliveredRev: number; deliveredInfo: number; delivered: number;
};

export class ProjectStore extends DurableObject<Env> {
  private sql: SqlStorage;
  private delivering: Promise<void> | null = null;
  private again = false;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
  }

  private exists(): boolean {
    return this.sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'members'").toArray().length > 0;
  }

  private migrate(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS members (
        userId TEXT PRIMARY KEY, memberId TEXT NOT NULL, name TEXT NOT NULL, role TEXT NOT NULL,
        joinedAt INTEGER NOT NULL, endedAt INTEGER, keepCopy INTEGER NOT NULL DEFAULT 0,
        deliveredRev INTEGER NOT NULL DEFAULT 0, deliveredInfo INTEGER NOT NULL DEFAULT 0,
        delivered INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS invites (
        id TEXT PRIMARY KEY, hash TEXT NOT NULL UNIQUE, createdAt INTEGER NOT NULL, expiresAt INTEGER NOT NULL,
        usedBy TEXT
      );
      CREATE TABLE IF NOT EXISTS rows (
        entity TEXT NOT NULL, id TEXT NOT NULL, fields TEXT NOT NULL, rev INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0, byMember TEXT NOT NULL, updatedAt INTEGER NOT NULL,
        PRIMARY KEY (entity, id)
      );
      CREATE INDEX IF NOT EXISTS rows_rev ON rows(rev);
      CREATE TABLE IF NOT EXISTS applied_ops (opId TEXT PRIMARY KEY, at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS applied_ops_at ON applied_ops(at);
    `);
  }

  private meta(key: string): number {
    return Number(this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0]?.value ?? 0);
  }

  private bump(key: string): number {
    const n = this.meta(key) + 1;
    this.sql.exec("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, String(n));
    return n;
  }

  private metaText(key: string): string {
    return this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0]?.value ?? "";
  }

  private member(userId: string): MemberRow | null {
    if (!this.exists()) return null;
    return this.sql.exec<MemberRow>("SELECT * FROM members WHERE userId = ? AND endedAt IS NULL", userId).toArray()[0] ?? null;
  }

  private owner(userId: string): MemberRow | null {
    const m = this.member(userId);
    return m?.role === "owner" ? m : null;
  }

  private members(): ShareMember[] {
    return this.sql.exec<{ memberId: string; name: string; role: "owner" | "editor" }>(
      "SELECT memberId, name, role FROM members WHERE endedAt IS NULL ORDER BY joinedAt, memberId",
    ).toArray().map((m) => ({ id: m.memberId, name: m.name, role: m.role }));
  }

  private infoFor(m: MemberRow): ShareInfo {
    return { id: this.metaText("id"), role: m.role, me: m.memberId, members: this.members() };
  }

  private title(): string {
    const row = this.sql.exec<{ fields: string }>(
      "SELECT fields FROM rows WHERE entity = 'project' AND id = ?", SHARED_PROJECT_ROW,
    ).toArray()[0];
    const title = row ? (JSON.parse(row.fields) as ShareFields).title : null;
    return typeof title === "string" ? title : "";
  }

  // ---- lifecycle ----

  /// Creates the store for its owner. The owner's TaskStore then sends the
  /// rows like any other write.
  create(shareId: string, userId: string, name: string): ShareInfo {
    return this.ctx.storage.transactionSync(() => {
      if (this.exists()) {
        const m = this.owner(userId);
        if (!m) throw new Error("share exists");
        return this.infoFor(m);
      }
      this.migrate();
      this.sql.exec("INSERT INTO meta (key, value) VALUES ('id', ?)", shareId);
      this.bump("info");
      this.sql.exec(
        "INSERT INTO members (userId, memberId, name, role, joinedAt) VALUES (?, ?, ?, 'owner', ?)",
        userId, newMemberId(), name, Date.now(),
      );
      return this.infoFor(this.owner(userId)!);
    });
  }

  /// Members and open invites, as the caller may see them.
  details(userId: string): { info: ShareInfo; invites: InviteView[] } | null {
    const m = this.member(userId);
    if (!m) return null;
    const invites = m.role === "owner"
      ? this.sql.exec<{ id: string; createdAt: number; expiresAt: number }>(
        "SELECT id, createdAt, expiresAt FROM invites WHERE usedBy IS NULL AND expiresAt > ? ORDER BY createdAt", Date.now(),
      ).toArray()
      : [];
    return { info: this.infoFor(m), invites };
  }

  // ---- invites ----

  /// The token is shown once; only its hash is kept. One person, 7 days.
  async invite(userId: string): Promise<{ ok: true; invite: InviteView; token: string } | { ok: false; reason: "not_owner" | "full" }> {
    const secret = randomId(24);
    const token = `${this.exists() ? this.metaText("id") : ""}.${secret}`;
    const hash = await sha256Base64Url(token);
    return this.ctx.storage.transactionSync(() => {
      if (!this.owner(userId)) return { ok: false as const, reason: "not_owner" as const };
      const now = Date.now();
      this.sql.exec("DELETE FROM invites WHERE expiresAt < ?", now);
      const open = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM invites WHERE usedBy IS NULL").one().n;
      if (open >= MAX_OPEN_INVITES || this.members().length >= MAX_MEMBERS) return { ok: false as const, reason: "full" as const };
      const invite = { id: randomId(9), createdAt: now, expiresAt: now + INVITE_TTL_MS };
      this.sql.exec(
        "INSERT INTO invites (id, hash, createdAt, expiresAt) VALUES (?, ?, ?, ?)", invite.id, hash, invite.createdAt, invite.expiresAt,
      );
      return { ok: true as const, invite, token };
    });
  }

  revokeInvite(userId: string, inviteId: string): boolean {
    if (!this.owner(userId)) return false;
    return this.sql.exec("DELETE FROM invites WHERE id = ? AND usedBy IS NULL", inviteId).rowsWritten > 0;
  }

  private openInvite(hash: string): { id: string; usedBy: string | null } | null {
    if (!this.exists()) return null;
    return this.sql.exec<{ id: string; usedBy: string | null }>(
      "SELECT id, usedBy FROM invites WHERE hash = ? AND expiresAt > ?", hash, Date.now(),
    ).toArray()[0] ?? null;
  }

  /// What the join page and the app show before someone accepts.
  async preview(token: string): Promise<{ title: string; from: string; members: number } | null> {
    const invite = this.openInvite(await sha256Base64Url(token));
    if (!invite || invite.usedBy) return null;
    const members = this.members();
    return { title: this.title(), from: members.find((m) => m.role === "owner")?.name ?? "", members: members.length };
  }

  /// Uses the invite. A retry by the same account gets the same answer.
  async join(token: string, userId: string, name: string): Promise<JoinResult> {
    const hash = await sha256Base64Url(token);
    const result = this.ctx.storage.transactionSync((): JoinResult => {
      const invite = this.openInvite(hash);
      if (!invite || (invite.usedBy !== null && invite.usedBy !== userId)) return { ok: false, reason: "invalid" };
      const already = this.member(userId);
      const done = (memberId: string): JoinResult => ({ ok: true, shareId: this.metaText("id"), title: this.title(), memberId });
      // A member who opens an invite leaves it for the person it was meant for.
      if (already) return done(already.memberId);
      // Someone who was removed cannot come back on the invite they used.
      if (invite.usedBy === userId) return { ok: false, reason: "invalid" };
      if (this.members().length >= MAX_MEMBERS) return { ok: false, reason: "full" };
      const before = this.sql.exec<{ memberId: string }>("SELECT memberId FROM members WHERE userId = ?", userId).toArray()[0];
      const memberId = before?.memberId ?? newMemberId();
      this.sql.exec(
        "INSERT OR REPLACE INTO members (userId, memberId, name, role, joinedAt) VALUES (?, ?, ?, 'editor', ?)",
        userId, memberId, name, Date.now(),
      );
      this.sql.exec("UPDATE invites SET usedBy = ? WHERE id = ?", userId, invite.id);
      this.bump("info");
      return done(memberId);
    });
    if (result.ok) await this.deliver();
    return result;
  }

  // ---- members ----

  /// Ends one membership. The owner removes anyone else; anyone else only
  /// themself.
  async endMembership(userId: string, memberId: string): Promise<boolean> {
    const ended = this.ctx.storage.transactionSync(() => {
      const caller = this.member(userId);
      if (!caller) return false;
      const target = this.sql.exec<MemberRow>("SELECT * FROM members WHERE memberId = ? AND endedAt IS NULL", memberId).toArray()[0];
      if (!target || target.role === "owner") return false;
      if (caller.role !== "owner" && caller.memberId !== memberId) return false;
      this.end(target.userId, false);
      return true;
    });
    if (ended) await this.deliver();
    return ended;
  }

  /// The owner stops sharing. Members lose the project; the owner keeps it.
  async close(userId: string): Promise<boolean> {
    const closed = this.ctx.storage.transactionSync(() => {
      const caller = this.owner(userId);
      if (!caller) return false;
      for (const m of this.sql.exec<MemberRow>("SELECT * FROM members WHERE endedAt IS NULL").toArray()) {
        this.end(m.userId, m.role === "owner");
      }
      this.sql.exec("DELETE FROM invites");
      return true;
    });
    if (closed) await this.deliver();
    return closed;
  }

  /// The account is gone. Its own copy goes with it. When it owned the
  /// project, every other member keeps a private copy.
  async accountDeleted(userId: string): Promise<void> {
    if (this.endAccount(userId)) await this.deliver();
  }

  private endAccount(userId: string): boolean {
    return this.ctx.storage.transactionSync(() => {
      const caller = this.member(userId);
      if (!caller) return false;
      if (caller.role === "owner") {
        for (const m of this.sql.exec<MemberRow>("SELECT * FROM members WHERE endedAt IS NULL").toArray()) this.end(m.userId, true);
        this.sql.exec("DELETE FROM invites");
      } else {
        this.end(userId, false);
      }
      this.sql.exec("UPDATE members SET delivered = 1 WHERE userId = ?", userId);
      return true;
    });
  }

  private end(userId: string, keepCopy: boolean): void {
    this.sql.exec("UPDATE members SET endedAt = ?, keepCopy = ?, delivered = 0 WHERE userId = ?", Date.now(), keepCopy ? 1 : 0, userId);
    this.bump("info");
  }

  // ---- rows ----

  /// Applies one member's changes, in order, and tells everyone.
  async push(userId: string, ops: ShareOp[]): Promise<SharePushResult> {
    const ok = this.ctx.storage.transactionSync(() => {
      const m = this.member(userId);
      if (!m) return false;
      for (const op of ops) this.apply(op, m);
      return true;
    });
    if (!ok) return this.notMember(userId);
    this.ctx.waitUntil(this.deliver());
    return { ok: true };
  }

  private notMember(userId: string): ShareEnded {
    const ended = this.exists()
      ? this.sql.exec<{ keepCopy: number }>("SELECT keepCopy FROM members WHERE userId = ?", userId).toArray()[0]
      : undefined;
    return { ok: false, reason: "not_member", keepCopy: ended ? ended.keepCopy === 1 : true };
  }

  /// The current state of some rows (TaskStore fetches what it masked).
  rows(userId: string, ids: { entity: SharedEntity; id: string }[]): ShareRowsResult {
    if (!this.member(userId)) return this.notMember(userId);
    const rows = ids.slice(0, SHARE_BATCH).flatMap(({ entity, id }) =>
      this.sql.exec<{ fields: string; rev: number; deleted: number; byMember: string }>(
        "SELECT fields, rev, deleted, byMember FROM rows WHERE entity = ? AND id = ?", entity, id,
      ).toArray().map((r) => ({
        entity, id, deleted: r.deleted === 1, fields: JSON.parse(r.fields) as ShareFields, by: r.byMember, rev: r.rev,
      })));
    return { ok: true, rows };
  }

  private isGone(entity: SharedEntity, id: string): boolean {
    return this.sql.exec("SELECT 1 FROM rows WHERE entity = ? AND id = ? AND deleted = 1", entity, id).toArray().length > 0;
  }

  private apply(op: ShareOp, m: MemberRow): void {
    if (!isSharedEntity(op.entity)) return;
    if (this.sql.exec("SELECT 1 FROM applied_ops WHERE opId = ?", op.opId).toArray().length) return;
    const now = Date.now();
    this.sql.exec("INSERT INTO applied_ops (opId, at) VALUES (?, ?)", op.opId, now);
    if (op.entity === "project" && (op.id !== SHARED_PROJECT_ROW || op.deleted)) return;
    const row = this.sql.exec<{ fields: string; deleted: number }>(
      "SELECT fields, deleted FROM rows WHERE entity = ? AND id = ?", op.entity, op.id,
    ).toArray()[0];
    // A deleted row stays deleted, as in TaskStore.
    if (row?.deleted) return;
    if (!row && op.deleted) return;
    if (op.entity === "checklistItem" && !op.deleted && typeof op.fields.taskId === "string" && this.isGone("task", op.fields.taskId)) return;
    if (!row && this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM rows WHERE deleted = 0").one().n >= MAX_SHARED_ROWS) {
      logEvent("share_rows_full", { shareId: this.metaText("id") });
      return;
    }
    const accepted = acceptedFields(op.entity);
    const fields: ShareFields = row ? (JSON.parse(row.fields) as ShareFields) : {};
    const stored = (fields.notes ?? null) as string | null;
    for (const [k, v] of Object.entries(op.fields)) if (accepted.includes(k)) fields[k] = v;
    if (row && op.baseNotes !== undefined && "notes" in op.fields && accepted.includes("notes")) {
      fields.notes = mergeNotes(op.baseNotes, stored, (op.fields.notes ?? null) as string | null, ENTITY_LIMITS.notesMax);
    }
    const rev = this.bump("rev");
    this.sql.exec(
      `INSERT INTO rows (entity, id, fields, rev, deleted, byMember, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(entity, id) DO UPDATE SET fields = excluded.fields, rev = excluded.rev, deleted = excluded.deleted,
         byMember = excluded.byMember, updatedAt = excluded.updatedAt`,
      op.entity, op.id, op.deleted ? "{}" : JSON.stringify(fields), rev, op.deleted ? 1 : 0, m.memberId, now,
    );
    // A deleted task takes its checklist with it, so nobody who joins later
    // gets items of no task.
    if (op.entity !== "task" || !op.deleted) return;
    for (const item of this.sql.exec<{ id: string }>(
      "SELECT id FROM rows WHERE entity = 'checklistItem' AND deleted = 0 AND json_extract(fields, '$.taskId') = ?", op.id,
    ).toArray()) {
      this.sql.exec(
        "UPDATE rows SET fields = '{}', deleted = 1, rev = ?, byMember = ?, updatedAt = ? WHERE entity = 'checklistItem' AND id = ?",
        this.bump("rev"), m.memberId, now, item.id,
      );
    }
  }

  // ---- delivery ----

  /// Brings every member's store up to date. One run at a time; a change that
  /// lands during a run starts another. A member that cannot be reached is
  /// tried again by the alarm.
  async deliver(): Promise<void> {
    if (this.delivering) {
      this.again = true;
      return this.delivering;
    }
    this.delivering = (async () => {
      try {
        do {
          this.again = false;
          await this.deliverOnce();
        } while (this.again);
      } finally {
        this.delivering = null;
      }
    })();
    return this.delivering;
  }

  private async deliverOnce(): Promise<void> {
    if (!this.exists()) return;
    // The alarm first: an object that stops during the run starts it again.
    await this.ctx.storage.setAlarm(Date.now() + RETRY_MS);
    this.sql.exec("DELETE FROM applied_ops WHERE at < ?", Date.now() - APPLIED_OP_TTL_MS);
    const users = this.sql.exec<{ userId: string }>("SELECT userId FROM members WHERE endedAt IS NULL OR delivered = 0").toArray();
    const outcomes = await Promise.all(users.map(({ userId }) => this.deliverTo(userId)));
    if (outcomes.includes(false) || this.again) return;
    // Nobody is left and everyone knows: the alarm removes what is stored.
    if (this.over()) await this.ctx.storage.setAlarm(Date.now() + CLOSED_TTL_MS);
    else await this.ctx.storage.deleteAlarm();
  }

  private over(): boolean {
    return this.sql.exec("SELECT 1 FROM members WHERE endedAt IS NULL OR delivered = 0 LIMIT 1").toArray().length === 0;
  }

  private async deliverTo(userId: string): Promise<boolean> {
    try {
      for (;;) {
        const m = this.sql.exec<MemberRow>("SELECT * FROM members WHERE userId = ?", userId).toArray()[0];
        if (!m) return true;
        const shareId = this.metaText("id");
        if (m.endedAt !== null) {
          if (m.delivered) return true;
          const done: ShareDelivery = { shareId, userId, state: "ended", keepCopy: m.keepCopy === 1 };
          await storeFor(this.env, userId).receiveShare(done);
          this.sql.exec("UPDATE members SET delivered = 1 WHERE userId = ? AND endedAt IS NOT NULL", userId);
          return true;
        }
        const info = this.meta("info");
        const page = this.sql.exec<{ entity: SharedEntity; id: string; fields: string; rev: number; deleted: number; byMember: string }>(
          "SELECT entity, id, fields, rev, deleted, byMember FROM rows WHERE rev > ? ORDER BY rev LIMIT ?", m.deliveredRev, SHARE_BATCH,
        ).toArray();
        if (!page.length && m.deliveredInfo === info) return true;
        const extra: typeof page = [];
        // The first delivery always names the project, whatever changed last.
        if (m.deliveredRev === 0 && !page.some((r) => r.entity === "project")) {
          extra.push(...this.sql.exec<(typeof page)[number]>(
            "SELECT entity, id, fields, rev, deleted, byMember FROM rows WHERE entity = 'project'",
          ).toArray());
        }
        const rows: ShareRow[] = [...extra, ...page].map((r) => ({
          entity: r.entity, id: r.id, deleted: r.deleted === 1, fields: JSON.parse(r.fields) as ShareFields, by: r.byMember, rev: r.rev,
        }));
        const outcome = await storeFor(this.env, userId).receiveShare({ shareId, userId, state: "live", info: this.infoFor(m), rows });
        if (outcome === "account_gone") {
          // Not `accountDeleted`: that waits for the run we are in.
          if (this.endAccount(userId)) this.again = true;
          return true;
        }
        this.sql.exec(
          "UPDATE members SET deliveredRev = ?, deliveredInfo = ? WHERE userId = ? AND memberId = ? AND joinedAt = ?",
          page.length ? page[page.length - 1].rev : m.deliveredRev, info, userId, m.memberId, m.joinedAt,
        );
      }
    } catch (e) {
      logEvent("share_delivery_failed", { shareId: this.metaText("id"), error: String(e) });
      return false;
    }
  }

  override async alarm(): Promise<void> {
    if (!this.exists()) return;
    const ended = this.sql.exec<{ at: number | null }>("SELECT MAX(endedAt) AS at FROM members").one().at ?? 0;
    if (this.over() && Date.now() - ended >= CLOSED_TTL_MS) {
      await this.ctx.storage.deleteAll();
      return;
    }
    await this.deliver();
  }
}

type Remote<M extends keyof ProjectStore> = {
  [K in M]: ProjectStore[K] extends (...args: infer A) => infer R ? (...args: A) => Promise<Awaited<R>> : never;
};
/// The calls other objects make. Named here because the stub's own type is
/// too deep for the compiler on recursive JSON values.
export type ProjectRpc = Remote<
  "create" | "details" | "invite" | "revokeInvite" | "preview" | "join" | "endMembership" | "close" | "accountDeleted" | "push" | "rows"
>;

export function projectStoreFor(env: Env, shareId: string): ProjectRpc {
  if (!env.PROJECT_STORE) throw new Error("PROJECT_STORE is not bound");
  return env.PROJECT_STORE.get(env.PROJECT_STORE.idFromName(shareId)) as unknown as ProjectRpc;
}
