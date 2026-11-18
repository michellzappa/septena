import { DurableObject } from "cloudflare:workers";
import type { Env } from "../env.js";
import {
  ENTITIES,
  ENTITY_NAMES,
  MAX_USER_ATTACHMENT_BYTES,
  createTableSQL,
  decodeRow,
  encodeValue,
  type EntityName,
  type EntitySpec,
} from "./columns.js";
import type { Op, OpResult, PullResult, PushResult, Turn } from "./ops.js";

// TaskStore — one Durable Object per user, the single writer for that user's
// task data (docs/SEPTASK_BACKEND.md in the app repo, §4–§6).
//
// The DO serializes every call, so `rev` is a total order with no gaps visible
// to a reader: a pull never sees rev N+1 committed before rev N. Conflicts are
// field-level last-writer-wins by arrival order, because an upsert writes only
// the fields the push carried. A deleted row stays deleted (§6.4).

const DAY_MS = 24 * 60 * 60 * 1000;
const TOMBSTONE_TTL_MS = 90 * DAY_MS;
const CLIENT_OP_TTL_MS = 30 * DAY_MS;
const CHANGE_LOG_TTL_MS = 365 * DAY_MS;
const MAX_PULL = 1_000;

const TURN_COLUMNS = [
  "role", "step", "provider", "confidence", "question", "options",
  "chosen", "otherText", "inReplyTo", "note", "ts",
] as const;

export interface PushOutcome {
  result: PushResult;
  /// Attachments this push deleted. The Worker removes their bytes from R2.
  purgedAttachmentIds: string[];
}

export class TaskStore extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    ctx.blockConcurrencyWhile(async () => {
      this.migrate();
      if ((await ctx.storage.getAlarm()) === null) {
        await ctx.storage.setAlarm(Date.now() + DAY_MS);
      }
    });
    // Keep-alive pings are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  private migrate(): void {
    for (const name of ENTITY_NAMES) this.sql.exec(createTableSQL(ENTITIES[name]));
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS turns (
        taskId TEXT NOT NULL, seq INTEGER NOT NULL,
        role TEXT NOT NULL, step TEXT NOT NULL, provider TEXT, confidence REAL,
        question TEXT, options TEXT, chosen TEXT, otherText TEXT,
        inReplyTo INTEGER, note TEXT, ts TEXT NOT NULL,
        rev INTEGER NOT NULL, updatedAt TEXT NOT NULL,
        PRIMARY KEY (taskId, seq)
      );
      CREATE INDEX IF NOT EXISTS turns_rev ON turns(rev);
      CREATE TABLE IF NOT EXISTS changes (
        rev INTEGER PRIMARY KEY, entity TEXT NOT NULL, id TEXT NOT NULL,
        op TEXT NOT NULL, fields TEXT, clientOpId TEXT, actor TEXT NOT NULL, at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS client_ops (
        clientOpId TEXT PRIMARY KEY, result TEXT NOT NULL, at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sessions (
        hash TEXT PRIMARY KEY, createdAt INTEGER NOT NULL, expiresAt INTEGER NOT NULL
      );
    `);
  }

  // ---- rev counter ----

  private meta(key: string): number {
    const row = this.sql.exec<{ value: number }>("SELECT value FROM meta WHERE key = ?", key).toArray()[0];
    return row?.value ?? 0;
  }

  private setMeta(key: string, value: number): void {
    this.sql.exec("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value);
  }

  private nextRev(): number {
    const rev = this.meta("rev") + 1;
    this.setMeta("rev", rev);
    return rev;
  }

  private log(rev: number, entity: string, id: string, op: string, fields: string[] | null, clientOpId: string | null, actor: string, at: string): void {
    this.sql.exec(
      "INSERT INTO changes (rev, entity, id, op, fields, clientOpId, actor, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      rev, entity, id, op, fields ? JSON.stringify(fields) : null, clientOpId, actor, at,
    );
  }

  // ---- push ----

  push(ops: Op[], actor: string): PushOutcome {
    const purgedAttachmentIds: string[] = [];
    const results = this.ctx.storage.transactionSync(() => ops.map((op) => {
      const seen = this.sql.exec<{ result: string }>("SELECT result FROM client_ops WHERE clientOpId = ?", op.clientOpId).toArray()[0];
      if (seen) return JSON.parse(seen.result) as OpResult;
      const result = this.apply(op, actor, purgedAttachmentIds);
      this.sql.exec("INSERT INTO client_ops (clientOpId, result, at) VALUES (?, ?, ?)", op.clientOpId, JSON.stringify(result), Date.now());
      return result;
    }));
    const appliedThrough = this.meta("rev");
    if (results.some((r) => r.status === "applied")) this.broadcast(appliedThrough);
    return { result: { appliedThrough, results }, purgedAttachmentIds };
  }

  private apply(op: Op, actor: string, purgedAttachmentIds: string[]): OpResult {
    const now = new Date().toISOString();
    if (op.op === "appendTurn") return this.appendTurn(op.clientOpId, op.taskId, op.turn, actor, now);

    const spec: EntitySpec = ENTITIES[op.entity];
    const row = this.sql.exec(`SELECT * FROM ${spec.table} WHERE id = ?`, op.id).toArray()[0];

    if (op.op === "delete") {
      if (!row || row.deletedAt) return { clientOpId: op.clientOpId, status: "noop" };
      const rev = this.nextRev();
      this.sql.exec(`UPDATE ${spec.table} SET deletedAt = ?, rev = ?, updatedAt = ? WHERE id = ?`, now, rev, now, op.id);
      this.log(rev, op.entity, op.id, "delete", null, op.clientOpId, actor, now);
      if (op.entity === "attachment") purgedAttachmentIds.push(op.id);
      if (op.entity === "task") {
        this.tombstoneConvo(op.id, now);
        purgedAttachmentIds.push(...this.tombstoneAttachments(op.id, now));
      }
      return { clientOpId: op.clientOpId, status: "applied", rev };
    }

    const names = Object.keys(op.fields);
    if (row?.deletedAt) {
      const rev = this.nextRev();
      this.log(rev, op.entity, op.id, "dropped", names, op.clientOpId, actor, now);
      return { clientOpId: op.clientOpId, status: "dropped", rev, reason: "deleted" };
    }
    if (names.length === 0) return { clientOpId: op.clientOpId, status: "noop" };

    if (!row) {
      const missing = spec.requiredOnInsert.filter((f) => op.fields[f] === undefined || op.fields[f] === null);
      if (missing.length) return { clientOpId: op.clientOpId, status: "rejected", reason: `missing_required:${missing.join(",")}` };
      if (op.entity === "convo" && !this.liveTask(op.id)) return { clientOpId: op.clientOpId, status: "rejected", reason: "unknown_task" };
      if (op.entity === "attachment") {
        const quota = this.checkQuota(op.id, op.fields.byteCount as number);
        if (quota) return { clientOpId: op.clientOpId, status: "rejected", reason: quota };
      }
    } else {
      const locked = spec.updatable ? names.filter((f) => !spec.updatable!.includes(f)) : [];
      if (locked.length) return { clientOpId: op.clientOpId, status: "rejected", reason: `immutable:${locked.join(",")}` };
      const cleared = spec.requiredOnInsert.filter((f) => op.fields[f] === null);
      if (cleared.length) return { clientOpId: op.clientOpId, status: "rejected", reason: `required:${cleared.join(",")}` };
    }

    const rev = this.nextRev();
    const cols = Object.entries(spec.columns);
    if (!row) {
      const insertCols = cols.filter(([n, c]) => op.fields[n] !== undefined || c.dflt !== undefined);
      const values = insertCols.map(([n, c]) => (op.fields[n] !== undefined ? encodeValue(c, op.fields[n]) : c.dflt ?? null));
      const colList = insertCols.map(([n]) => `"${n}"`).concat(["id", "rev", "updatedAt"]).join(", ");
      const marks = insertCols.map(() => "?").concat(["?", "?", "?"]).join(", ");
      this.sql.exec(`INSERT INTO ${spec.table} (${colList}) VALUES (${marks})`, ...values, op.id, rev, now);
    } else {
      const sets = names.map((n) => `"${n}" = ?`).concat(["rev = ?", "updatedAt = ?"]).join(", ");
      const values = names.map((n) => encodeValue(spec.columns[n], op.fields[n]));
      this.sql.exec(`UPDATE ${spec.table} SET ${sets} WHERE id = ?`, ...values, rev, now, op.id);
    }
    this.log(rev, op.entity, op.id, "upsert", names, op.clientOpId, actor, now);
    return { clientOpId: op.clientOpId, status: "applied", rev };
  }

  private liveTask(id: string): boolean {
    return this.sql.exec("SELECT 1 FROM tasks WHERE id = ? AND deletedAt IS NULL", id).toArray().length > 0;
  }

  private tombstoneConvo(taskId: string, now: string): void {
    const live = this.sql.exec("SELECT 1 FROM convos WHERE id = ? AND deletedAt IS NULL", taskId).toArray().length > 0;
    if (!live) return;
    const rev = this.nextRev();
    this.sql.exec("UPDATE convos SET deletedAt = ?, rev = ?, updatedAt = ? WHERE id = ?", now, rev, now, taskId);
  }

  /// A deleted task takes its attachments with it, so their bytes stop
  /// counting against the quota. Returns the ids whose bytes to purge.
  private tombstoneAttachments(taskId: string, now: string): string[] {
    const ids = this.sql.exec<{ id: string }>("SELECT id FROM attachments WHERE taskId = ? AND deletedAt IS NULL", taskId).toArray().map((r) => r.id);
    for (const id of ids) {
      const rev = this.nextRev();
      this.sql.exec("UPDATE attachments SET deletedAt = ?, rev = ?, updatedAt = ? WHERE id = ?", now, rev, now, id);
    }
    return ids;
  }

  /// Returns a rejection reason, or null when the new attachment fits.
  private checkQuota(id: string, byteCount: number): string | null {
    const used = this.sql.exec<{ total: number | null }>(
      "SELECT SUM(byteCount) AS total FROM attachments WHERE deletedAt IS NULL AND id != ?", id,
    ).one().total ?? 0;
    return used + byteCount > MAX_USER_ATTACHMENT_BYTES ? "quota_exceeded" : null;
  }

  private appendTurn(clientOpId: string, taskId: string, turn: Turn, actor: string, now: string): OpResult {
    const task = this.sql.exec<{ deletedAt: string | null }>("SELECT deletedAt FROM tasks WHERE id = ?", taskId).toArray()[0];
    if (!task) return { clientOpId, status: "rejected", reason: "unknown_task" };
    if (task.deletedAt) {
      const rev = this.nextRev();
      this.log(rev, "turn", taskId, "dropped", null, clientOpId, actor, now);
      return { clientOpId, status: "dropped", rev, reason: "deleted" };
    }
    const seq = (this.sql.exec<{ m: number | null }>("SELECT MAX(seq) AS m FROM turns WHERE taskId = ?", taskId).one().m ?? 0) + 1;
    const rev = this.nextRev();
    const values = TURN_COLUMNS.map((c) => {
      const v = turn[c];
      if (v === undefined) return null;
      return c === "options" && v !== null ? JSON.stringify(v) : (v as string | number | null);
    });
    this.sql.exec(
      `INSERT INTO turns (taskId, seq, ${TURN_COLUMNS.join(", ")}, rev, updatedAt) VALUES (?, ?, ${TURN_COLUMNS.map(() => "?").join(", ")}, ?, ?)`,
      taskId, seq, ...values, rev, now,
    );
    this.log(rev, "turn", `${taskId}:${seq}`, "append", null, clientOpId, actor, now);
    return { clientOpId, status: "applied", rev, seq };
  }

  // ---- pull ----

  pull(since: number, limit: number): PullResult {
    const n = Math.min(Math.max(limit, 1), MAX_PULL);
    if (since > 0 && since < this.meta("purgedThrough")) {
      return { resetRequired: true, changes: [], nextSince: 0, hasMore: true };
    }
    // Each table is already ordered by rev, so merging their first n rows and
    // keeping the global first n is exact.
    const merged: Array<{ rev: number; entity: EntityName | "turn"; row: Record<string, unknown> }> = [];
    for (const name of ENTITY_NAMES) {
      const spec: EntitySpec = ENTITIES[name];
      for (const raw of this.sql.exec(`SELECT * FROM ${spec.table} WHERE rev > ? ORDER BY rev LIMIT ?`, since, n)) {
        merged.push({ rev: raw.rev as number, entity: name, row: decodeRow(spec, raw) });
      }
    }
    for (const raw of this.sql.exec(`SELECT * FROM turns WHERE rev > ? ORDER BY rev LIMIT ?`, since, n)) {
      const row: Record<string, unknown> = { ...raw };
      for (const [k, v] of Object.entries(row)) if (v === null) delete row[k];
      if (typeof row.options === "string") row.options = JSON.parse(row.options);
      merged.push({ rev: raw.rev as number, entity: "turn", row });
    }
    merged.sort((a, b) => a.rev - b.rev);
    const page = merged.slice(0, n);
    const head = this.meta("rev");
    const nextSince = page.length ? page[page.length - 1].rev : Math.max(since, head);
    return {
      changes: page.map(({ entity, row }) => ({ entity, row })),
      nextSince,
      hasMore: merged.length > n,
    };
  }

  // ---- attachments ----

  /// Checks an upload against the attachment's metadata row. Returns null when
  /// the bytes may be stored, else an error code for the Worker to map.
  checkUpload(id: string, contentLength: number): "not_found" | "size_mismatch" | null {
    const row = this.sql.exec<{ byteCount: number }>(
      "SELECT byteCount FROM attachments WHERE id = ? AND deletedAt IS NULL", id,
    ).toArray()[0];
    if (!row) return "not_found";
    if (row.byteCount !== contentLength) return "size_mismatch";
    return null;
  }

  finishUpload(id: string, actor: string): number | null {
    const now = new Date().toISOString();
    const live = this.sql.exec("SELECT 1 FROM attachments WHERE id = ? AND deletedAt IS NULL", id).toArray().length > 0;
    if (!live) return null;
    const rev = this.ctx.storage.transactionSync(() => {
      const rev = this.nextRev();
      this.sql.exec("UPDATE attachments SET uploadedAt = ?, rev = ?, updatedAt = ? WHERE id = ?", now, rev, now, id);
      this.log(rev, "attachment", id, "upload", ["uploadedAt"], null, actor, now);
      return rev;
    });
    this.broadcast(rev);
    return rev;
  }

  downloadInfo(id: string): { contentType: string; filename: string } | null {
    const row = this.sql.exec<{ contentType: string; filename: string }>(
      "SELECT contentType, filename FROM attachments WHERE id = ? AND deletedAt IS NULL AND uploadedAt IS NOT NULL", id,
    ).toArray()[0];
    return row ?? null;
  }

  // ---- sessions (refresh tokens, stored hashed) ----

  createSession(hash: string, expiresAt: number): void {
    this.sql.exec("INSERT INTO sessions (hash, createdAt, expiresAt) VALUES (?, ?, ?)", hash, Date.now(), expiresAt);
  }

  /// Single-use rotation: the old refresh token dies whether or not the new
  /// one is ever used.
  rotateSession(oldHash: string, newHash: string, expiresAt: number): boolean {
    return this.ctx.storage.transactionSync(() => {
      const row = this.sql.exec<{ expiresAt: number }>("SELECT expiresAt FROM sessions WHERE hash = ?", oldHash).toArray()[0];
      this.sql.exec("DELETE FROM sessions WHERE hash = ?", oldHash);
      if (!row || row.expiresAt < Date.now()) return false;
      this.sql.exec("INSERT INTO sessions (hash, createdAt, expiresAt) VALUES (?, ?, ?)", newHash, Date.now(), expiresAt);
      return true;
    });
  }

  revokeSession(hash: string): void {
    this.sql.exec("DELETE FROM sessions WHERE hash = ?", hash);
  }

  /// Account deletion (§10). The Worker empties the user's R2 prefix.
  async deleteAccount(): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) ws.close(1000, "account deleted");
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }

  // ---- live nudge (§6.3) ----

  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") return new Response("expected websocket", { status: 426 });
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    pair[1].send(JSON.stringify({ rev: this.meta("rev") }));
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  override async webSocketMessage(): Promise<void> {
    // The socket carries nudges only; clients send nothing but pings.
  }

  override async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    try { ws.close(code, "closing"); } catch { /* already closed */ }
  }

  private broadcast(rev: number): void {
    const msg = JSON.stringify({ rev });
    for (const ws of this.ctx.getWebSockets()) {
      try { ws.send(msg); } catch { /* dead socket; the runtime reaps it */ }
    }
  }

  // ---- daily housekeeping ----

  override async alarm(): Promise<void> {
    const now = Date.now();
    const tombstoneCutoff = new Date(now - TOMBSTONE_TTL_MS).toISOString();
    this.ctx.storage.transactionSync(() => {
      let purged = this.meta("purgedThrough");
      for (const name of ENTITY_NAMES) {
        const table = ENTITIES[name].table;
        const m = this.sql.exec<{ m: number | null }>(`SELECT MAX(rev) AS m FROM ${table} WHERE deletedAt IS NOT NULL AND deletedAt < ?`, tombstoneCutoff).one().m;
        if (m !== null) purged = Math.max(purged, m);
        this.sql.exec(`DELETE FROM ${table} WHERE deletedAt IS NOT NULL AND deletedAt < ?`, tombstoneCutoff);
      }
      this.sql.exec("DELETE FROM turns WHERE taskId NOT IN (SELECT id FROM tasks)");
      this.setMeta("purgedThrough", purged);
      this.sql.exec("DELETE FROM client_ops WHERE at < ?", now - CLIENT_OP_TTL_MS);
      this.sql.exec("DELETE FROM changes WHERE at < ?", new Date(now - CHANGE_LOG_TTL_MS).toISOString());
      this.sql.exec("DELETE FROM sessions WHERE expiresAt < ?", now);
    });
    await this.ctx.storage.setAlarm(now + DAY_MS);
  }
}
