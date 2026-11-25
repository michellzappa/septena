import { randomId } from "../util.js";
import { ENTITIES } from "./columns.js";

// Shared projects (docs/PROJECT_SHARING_SPEC.md, ADR 0004, ADR 0042).
//
// A ProjectStore Durable Object is the authority for one shared project. Each
// member's TaskStore keeps a replica of its rows in its own tables, so every
// read (pull, MCP, REST, widgets, the calendar feed) works as it does for a
// private project. Shared fields cross between the two; personal fields never
// leave the member's store.
//
// Ids: two stores can hold the same short id. The ProjectStore knows a row by
// its shared id, which is globally unique, and each TaskStore maps it to a
// local id. The member who made the row keeps the id it had; every other
// member's replica uses the shared id.

export type SharedEntity = "task" | "project" | "checklistItem";
export const SHARED_ENTITIES: readonly SharedEntity[] = ["task", "project", "checklistItem"];
export const isSharedEntity = (e: string): e is SharedEntity => (SHARED_ENTITIES as readonly string[]).includes(e);

/// The project's own row has one fixed shared id.
export const SHARED_PROJECT_ROW = "project";

/// The fields that every member sees. Anything not listed is personal:
/// Today, When, reminders, tags, star, area, fade, references, files and the
/// conversation with an agent.
export const SHARED_FIELDS: Record<SharedEntity, readonly string[]> = {
  task: [
    "title", "status", "kind", "heading", "created", "deadline", "completedAt", "notes", "position",
    "recurrenceUnit", "recurrenceInterval", "recurrenceAfterCompletion", "recurrencePaused",
    "recurrenceSeriesID", "recurrenceAnchorDate", "recurrenceWeekdays", "recurrenceMonthDay",
    "recurrenceOrdinalWeekday", "createdAt", "dropReason", "assignedTo",
  ],
  project: ["title", "status", "created", "completedAt", "notes"],
  checklistItem: ["taskId", "title", "checked", "checkedAt", "position", "createdAt"],
};

/// A repeating task starts on the same day for every member. After that each
/// member's When is their own.
export const SEED_FIELDS = ["scheduled", "startTime", "durationMinutes", "timeZone"] as const;

/// Every field the ProjectStore accepts for an entity. A write that names
/// anything else is cut to this list (fail closed).
export const acceptedFields = (entity: SharedEntity): readonly string[] =>
  entity === "task" ? [...SHARED_FIELDS.task, ...SEED_FIELDS] : SHARED_FIELDS[entity];

const RETIRED = "retired:";

export const MAX_MEMBERS = 10;
export const MAX_OPEN_INVITES = 20;
export const MAX_SHARED_ROWS = 10_000;
export const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
export const SHARE_BATCH = 200;
export const SHARE_ID_RE = /^sp_[A-Za-z0-9_-]{32}$/;
export const MEMBER_ID_RE = /^m_[A-Za-z0-9_-]{16}$/;

export const newShareId = () => `sp_${randomId(24)}`;
export const newMemberId = () => `m_${randomId(12)}`;
export const newSharedRowId = () => `s-${randomId(16)}`;

export type ShareValue = string | number | boolean | null | ShareValue[] | { [key: string]: ShareValue };
export type ShareFields = { [key: string]: ShareValue };

export interface ShareMember {
  id: string;
  name: string;
  role: "owner" | "editor";
}

/// What the project row carries in its `share` column, so every client can
/// show the members from its own cache.
export interface ShareInfo {
  id: string;
  role: "owner" | "editor";
  /// This account's member id.
  me: string;
  members: ShareMember[];
}

/// One change a member's store sends to the ProjectStore.
export interface ShareOp {
  opId: string;
  entity: SharedEntity;
  id: string;
  deleted: boolean;
  fields: ShareFields;
}

export interface ShareRow {
  entity: SharedEntity;
  id: string;
  deleted: boolean;
  fields: ShareFields;
  /// The member who wrote last.
  by: string;
  rev: number;
}

/// What the ProjectStore sends to a member's store.
export type ShareDelivery =
  | { shareId: string; userId: string; state: "live"; info: ShareInfo; rows: ShareRow[] }
  /// The member left, was removed, or the owner stopped sharing.
  | { shareId: string; userId: string; state: "ended"; keepCopy: boolean };

export type SharePushResult = { ok: true } | { ok: false; reason: "not_member" };

export const sharedColumn = (entity: SharedEntity, name: string) =>
  (ENTITIES[entity].columns as Record<string, import("./columns.js").Column>)[name];

/// The member's-store side: which rows are replicas, and what still has to go
/// out.
export class ShareBook {
  private sql: SqlStorage;

  constructor(sql: SqlStorage) {
    this.sql = sql;
  }

  migrate(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS shares (
        id TEXT PRIMARY KEY, userId TEXT NOT NULL, localProjectId TEXT NOT NULL UNIQUE,
        memberId TEXT NOT NULL, role TEXT NOT NULL, info TEXT NOT NULL, joinedAt INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS share_ids (
        shareId TEXT NOT NULL, entity TEXT NOT NULL, sharedId TEXT NOT NULL, localId TEXT NOT NULL,
        rev INTEGER NOT NULL DEFAULT 0, masked INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (shareId, entity, sharedId)
      );
      CREATE UNIQUE INDEX IF NOT EXISTS share_ids_local ON share_ids(entity, localId);
      CREATE TABLE IF NOT EXISTS share_outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, shareId TEXT NOT NULL, opId TEXT NOT NULL,
        entity TEXT NOT NULL, sharedId TEXT NOT NULL, deleted INTEGER NOT NULL, fields TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS share_outbox_row ON share_outbox(shareId, entity, sharedId);
    `);
  }

  any(): boolean {
    return this.sql.exec("SELECT 1 FROM shares LIMIT 1").toArray().length > 0;
  }

  list(): { id: string; localProjectId: string; role: "owner" | "editor"; memberId: string; info: ShareInfo }[] {
    return this.sql.exec<{ id: string; localProjectId: string; role: "owner" | "editor"; memberId: string; info: string }>(
      "SELECT id, localProjectId, role, memberId, info FROM shares ORDER BY joinedAt",
    ).toArray().map((r) => ({ ...r, info: JSON.parse(r.info) as ShareInfo }));
  }

  get(shareId: string): { id: string; userId: string; localProjectId: string; role: "owner" | "editor"; memberId: string } | null {
    return this.sql.exec<{ id: string; userId: string; localProjectId: string; role: "owner" | "editor"; memberId: string }>(
      "SELECT id, userId, localProjectId, role, memberId FROM shares WHERE id = ?", shareId,
    ).toArray()[0] ?? null;
  }

  forProject(localProjectId: string | null | undefined): { id: string; role: "owner" | "editor" } | null {
    if (!localProjectId) return null;
    return this.sql.exec<{ id: string; role: "owner" | "editor" }>(
      "SELECT id, role FROM shares WHERE localProjectId = ?", localProjectId,
    ).toArray()[0] ?? null;
  }

  put(row: { id: string; userId: string; localProjectId: string; info: ShareInfo }): void {
    this.sql.exec(
      `INSERT INTO shares (id, userId, localProjectId, memberId, role, info, joinedAt) VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET memberId = excluded.memberId, role = excluded.role, info = excluded.info`,
      row.id, row.userId, row.localProjectId, row.info.me, row.info.role, JSON.stringify(row.info), Date.now(),
    );
  }

  /// Forgets a share. The rows themselves are the caller's business.
  remove(shareId: string): void {
    this.sql.exec("DELETE FROM shares WHERE id = ?", shareId);
    this.sql.exec("DELETE FROM share_ids WHERE shareId = ?", shareId);
    this.sql.exec("DELETE FROM share_outbox WHERE shareId = ?", shareId);
  }

  localId(shareId: string, entity: SharedEntity, sharedId: string): string | null {
    return this.sql.exec<{ localId: string }>(
      "SELECT localId FROM share_ids WHERE shareId = ? AND entity = ? AND sharedId = ?", shareId, entity, sharedId,
    ).toArray()[0]?.localId ?? null;
  }

  shared(entity: SharedEntity, localId: string): { shareId: string; sharedId: string } | null {
    return this.sql.exec<{ shareId: string; sharedId: string }>(
      "SELECT shareId, sharedId FROM share_ids WHERE entity = ? AND localId = ?", entity, localId,
    ).toArray()[0] ?? null;
  }

  map(shareId: string, entity: SharedEntity, sharedId: string, localId: string): void {
    this.sql.exec("INSERT INTO share_ids (shareId, entity, sharedId, localId) VALUES (?, ?, ?, ?)", shareId, entity, sharedId, localId);
  }

  /// The local row left the project. The shared id stays known, so a late
  /// delivery cannot bring the row back.
  retire(shareId: string, entity: SharedEntity, sharedId: string): void {
    this.sql.exec(
      "UPDATE share_ids SET localId = ?, masked = 0 WHERE shareId = ? AND entity = ? AND sharedId = ?",
      `${RETIRED}${shareId}:${sharedId}`, shareId, entity, sharedId,
    );
  }

  static isRetired(localId: string): boolean {
    return localId.startsWith(RETIRED);
  }

  mapped(shareId: string): { entity: SharedEntity; sharedId: string; localId: string }[] {
    return this.sql.exec<{ entity: SharedEntity; sharedId: string; localId: string }>(
      "SELECT entity, sharedId, localId FROM share_ids WHERE shareId = ?", shareId,
    ).toArray();
  }

  enqueue(shareId: string, entity: SharedEntity, sharedId: string, deleted: boolean, fields: ShareFields): void {
    this.sql.exec(
      "INSERT INTO share_outbox (shareId, opId, entity, sharedId, deleted, fields) VALUES (?, ?, ?, ?, ?, ?)",
      shareId, randomId(12), entity, sharedId, deleted ? 1 : 0, JSON.stringify(fields),
    );
  }

  /// Fields of this row that have not reached the ProjectStore yet. A
  /// delivery must not overwrite them: their own echo comes later.
  pendingFields(shareId: string, entity: SharedEntity, sharedId: string): Set<string> {
    const out = new Set<string>();
    for (const r of this.sql.exec<{ fields: string }>(
      "SELECT fields FROM share_outbox WHERE shareId = ? AND entity = ? AND sharedId = ?", shareId, entity, sharedId,
    )) for (const f of Object.keys(JSON.parse(r.fields) as ShareFields)) out.add(f);
    return out;
  }

  pendingShares(): string[] {
    return this.sql.exec<{ shareId: string }>(
      "SELECT shareId FROM share_outbox UNION SELECT shareId FROM share_ids WHERE masked = 1",
    ).toArray().map((r) => r.shareId);
  }

  /// The project revision this row last took in full.
  revOf(shareId: string, entity: SharedEntity, sharedId: string): number {
    return this.sql.exec<{ rev: number }>(
      "SELECT rev FROM share_ids WHERE shareId = ? AND entity = ? AND sharedId = ?", shareId, entity, sharedId,
    ).toArray()[0]?.rev ?? 0;
  }

  /// Records a delivery. A masked one left out fields that a pending write
  /// covers, so the row is fetched again once that write is sent: the project
  /// may already have had it, and then no later delivery carries the winner.
  took(shareId: string, entity: SharedEntity, sharedId: string, rev: number, masked: boolean): void {
    this.sql.exec(
      "UPDATE share_ids SET rev = ?, masked = ? WHERE shareId = ? AND entity = ? AND sharedId = ?",
      masked ? this.revOf(shareId, entity, sharedId) : rev, masked ? 1 : 0, shareId, entity, sharedId,
    );
  }

  maskedRows(shareId: string): { entity: SharedEntity; id: string }[] {
    return this.sql.exec<{ entity: SharedEntity; id: string }>(
      "SELECT entity, sharedId AS id FROM share_ids WHERE shareId = ? AND masked = 1 LIMIT ?", shareId, SHARE_BATCH,
    ).toArray();
  }

  nextBatch(shareId: string): { through: number; ops: ShareOp[] } | null {
    const rows = this.sql.exec<{ seq: number; opId: string; entity: SharedEntity; sharedId: string; deleted: number; fields: string }>(
      "SELECT seq, opId, entity, sharedId, deleted, fields FROM share_outbox WHERE shareId = ? ORDER BY seq LIMIT ?", shareId, SHARE_BATCH,
    ).toArray();
    if (!rows.length) return null;
    return {
      through: rows[rows.length - 1].seq,
      ops: rows.map((r) => ({
        opId: r.opId, entity: r.entity, id: r.sharedId, deleted: r.deleted === 1, fields: JSON.parse(r.fields) as ShareFields,
      })),
    };
  }

  sent(shareId: string, through: number): void {
    this.sql.exec("DELETE FROM share_outbox WHERE shareId = ? AND seq <= ?", shareId, through);
  }
}
