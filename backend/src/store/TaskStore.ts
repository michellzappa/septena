import { DurableObject } from "cloudflare:workers";
import type { Env } from "../env.js";
import {
  ENTITIES,
  ENTITY_NAMES,
  MAX_CHECKLIST_ITEMS_PER_TASK,
  MAX_REFS_PER_TASK,
  MAX_TAGS_PER_TASK,
  MAX_USER_ATTACHMENT_BYTES,
  addMissingColumnsSQL,
  createTableSQL,
  decodeRow,
  encodeValue,
  snapshotFits,
  type EntityName,
  type EntitySpec,
  type RefSnapshot,
} from "./columns.js";
import { CoreInputError, findIssueRefs, parseRef, taskRefId, type CoreRef } from "../core/index.js";
import type { Op, OpResult, PullResult, PushResult, Turn } from "./ops.js";
import type { EntitlementRow } from "../entitlement/entitlement.js";
import type { IcalTask } from "../ical.js";
import { DOMAIN_RULES, ENTITY_LIMITS, TURN_FIELDS } from "../generated/registries.js";
import { MCP_REFRESH_TTL_S } from "../shadow/tokens.js";
import { logEvent } from "../util.js";

/// Task fields only the app writes (docs/TASK_FADE_SPEC.md §3): the fade
/// clock and its outcome. An agent cannot keep a task alive by touching it.
const APP_ONLY_TASK_FIELDS = ["touchedAt", "deferCount", "fadedAt", "dropReason", "effort"] as const;

/// Per changed field: [before, after]. `null` means absent / cleared.
export type ChangeDiff = Record<string, [unknown, unknown]>;

/// `GET /v1/access`: every place the account is signed in.
export interface AccessSummary {
  devices: { sid: string; client: string | null; firstSeen: number; lastSeen: number; current: boolean; syncing: boolean }[];
  /// The agents: one row per connected app (an MCP token family). `name` is
  /// the name the user gave it, else the name the client registered with.
  connections: { id: string; name: string; clientName: string; scope: string; createdAt: number; lastUsed: number }[];
  /// The agent count (every row in `connections`) and the plan's limit on it
  /// (`connectedAgents`, null = no cap). The limit is log-only: nothing blocks.
  agents: { count: number; limit: number | null };
}

export interface ChangeEntry {
  rev: number;
  entity: string;
  id: string;
  op: string;
  fields: string[] | null;
  diff: ChangeDiff | null;
  actor: string;
  at: string;
  /// Why the writer made this change, when it said (agent writes).
  reason: string | null;
}

/// Why a claim was refused. Every value is a rule the agent must respect,
/// not a transient error to retry.
export type ClaimRefusal =
  | "not_found" | "closed" | "terminal" | "stopped" | "paused"
  | "your_turn" | "held" | "budget";

export type ClaimResult =
  | { ok: true; holder: string; claimUntil: string; renewed: boolean; runsSinceUser: number }
  | { ok: false; reason: ClaimRefusal; holder?: string; claimUntil?: string };

/// One thing an agent may need to react to. A pointer, never content: the
/// agent reads the task itself, so text in a task can never arrive as an
/// order through this feed.
export interface AgentEvent {
  rev: number;
  kind: "assigned" | "user_turn" | "stopped" | "resumed" | "paused" | "unpaused";
  taskId: string | null;
  at: string;
}

/// Agent writers (the MCP connector) carry an `mcp:` actor. Everything else
/// (`app:<client>`) is the human.
export const isAgentActor = (actor: string) => actor.startsWith("mcp:");

/// Guidance attached to agent write refusals, so any connector or runner knows
/// the rule instead of retrying (ADR 0008).
export const AGENT_WRITE_RULES: Record<string, string> = {
  stopped: "The user stopped agent work on this task. Do not write to it; only the user can resume it.",
  stale:
    "The notes changed since you read them. Read `current`, then write again on top of it with its noteRev as baseNoteRev.",
  brief_is_users:
    "The text above `## Log` is the user's brief. Append a dated entry under `## Log`, or propose a new brief for the user to accept.",
  paused: "The user paused all agents. Do not write; only the user can unpause.",
  "retired:context": "Project context is retired (ADR 0012). Write the project's notes instead.",
  human_accepts:
    "Only the user marks an agent-worked task done. Call tasks_set_endstate with endState \"needs_verify\" and a note describing what to check.",
};

/// Lease bounds for a claim. An agent that stops writing loses the task when
/// the lease ends; the maximum keeps a crashed run from holding it for long.
export const CLAIM_TTL_DEFAULT_MS = DOMAIN_RULES.claimTtlDefaultSeconds * 1000;
export const CLAIM_TTL_MAX_MS = DOMAIN_RULES.claimTtlMaxSeconds * 1000;
/// Fresh claims allowed between two human turns on one task.
export const AGENT_RUN_BUDGET = DOMAIN_RULES.agentRunBudget;

const LOG_TEXT_MAX = 4_000;

// ---- notes (ADR 0012, docs/PROJECT_NOTES_SPEC.md §3–§4) ----

/// The containers whose notes are agent context, and the column that holds
/// them. An area's notes keep their old wire name.
export const NOTE_FIELD = { project: "notes", area: "context" } as const;
export type NoteContainer = keyof typeof NOTE_FIELD;
const isNoteContainer = (e: string): e is NoteContainer => e in NOTE_FIELD;

export interface NoteRevision {
  rev: number;
  actor: string;
  at: string;
  reason: string | null;
  /// Full text of this version (null = cleared). Omitted unless asked for.
  body?: string | null;
}

/// Notes split at the first line that is exactly `## Log`. Everything above
/// is the user's brief; everything below is the agent log. No such line
/// means the whole note is brief.
export function splitNotes(body: string | null | undefined): { brief: string; log: string | null } {
  if (!body) return { brief: "", log: null };
  const m = /^## Log[ \t]*$/m.exec(body);
  if (!m) return { brief: body, log: null };
  return { brief: body.slice(0, m.index), log: body.slice(m.index + m[0].length) };
}

/// The retired project `context` appended to the brief, above `## Log`.
function mergeContextIntoNotes(notes: string | null, context: string, day: string): string {
  const block = `## Context (merged ${day})\n\n${context.trim()}\n`;
  const { brief, log } = splitNotes(notes);
  const top = brief.trim() ? `${brief.trimEnd()}\n\n${block}` : block;
  return log === null ? top : `${top}\n## Log${log}`;
}

/// True when an agent may change notes from `before` to `after`: the brief
/// stays as it is (unless it was empty), and the log only grows at its end.
export function agentMayWriteNotes(before: string | null, after: string | null): boolean {
  const old = splitNotes(before);
  const next = splitNotes(after);
  if (old.brief.trim() !== "" && next.brief.trim() !== old.brief.trim()) return false;
  const oldLog = (old.log ?? "").trimEnd();
  return (next.log ?? "").startsWith(oldLog);
}

/// Long text (notes, artifacts) is cut in the log; the row itself keeps it.
function clipForLog(v: unknown): unknown {
  if (typeof v === "string" && v.length > LOG_TEXT_MAX) return `${v.slice(0, LOG_TEXT_MAX)}…`;
  if (v !== null && typeof v === "object") {
    const s = JSON.stringify(v);
    if (s.length > LOG_TEXT_MAX) return `${s.slice(0, LOG_TEXT_MAX)}…`;
  }
  return v;
}

// TaskStore — one Durable Object per user, the single writer for that user's
// task data (docs/SEPTASK_BACKEND.md in the app repo, §4–§6).
//
// The DO serializes every call, so `rev` is a total order with no gaps visible
// to a reader: a pull never sees rev N+1 committed before rev N. Conflicts are
// field-level last-writer-wins by arrival order, because an upsert writes only
// the fields the push carried. A deleted row stays deleted (§6.4).

const DAY_MS = 24 * 60 * 60 * 1000;
const TOMBSTONE_TTL_MS = DOMAIN_RULES.tombstoneTtlDays * DAY_MS;
const CLIENT_OP_TTL_MS = DOMAIN_RULES.clientOpTtlDays * DAY_MS;
/// A connection unused this long has an expired refresh token (src/shadow/tokens.ts).
const CONNECTION_TTL_MS = MCP_REFRESH_TTL_S * 1000;
const CHANGE_LOG_TTL_MS = DOMAIN_RULES.changeLogTtlDays * DAY_MS;
const MAX_PULL = ENTITY_LIMITS.maxPull;
const PAIR_FAIL_WINDOW_MS = 10 * 60 * 1000;

/// The turns table's columns, in the registry's order (`registry/entities.json` `turnFields`).
const TURN_COLUMNS = TURN_FIELDS;

/// A decoded row as it crosses the RPC boundary: JSON values only.
export type Json = string | number | boolean | null | Json[] | { [key: string]: Json };
export type Row = { [key: string]: Json };

/// A turns row as the wire carries it: nulls dropped, options parsed. Shared
/// by pull and the MCP preview's reads.
function decodeTurnRow(raw: Record<string, unknown>): Record<string, unknown> {
  const row: Record<string, unknown> = { ...raw };
  for (const [k, v] of Object.entries(row)) if (v === null) delete row[k];
  if (typeof row.options === "string") row.options = JSON.parse(row.options);
  return row;
}

/// One task's references and end state, as a list row shows them.
export type TaskLinkRow = {
  id: string;
  endState: string | null;
  refCount: number;
  /// The newest `issue` reference: the last one added.
  issue: { key: string; snapshot: RefSnapshot | null } | null;
};

/// A task that points at a key (`findByRef`).
export type RefHit = {
  id: string;
  title: string;
  status: string;
  area: string | null;
  project: string | null;
  faded: boolean;
  role: string;
};

/// An open task with a conversation, as the agent queue reads it.
export type ConvoCandidate = {
  id: string; title: string | null; confirmedIntent: string | null;
  assignee: string | null; endState: string | null;
  stoppedAt: string | null; claimedBy: string | null; claimUntil: string | null;
  lastProviderConfidence: number | null; awaitsHuman: number | null;
};

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
    this.migrateTables();
    // The change log gained per-field before/after values after it shipped.
    const changeCols = new Set(
      this.sql.exec<{ name: string }>("PRAGMA table_info(changes)").toArray().map((r) => r.name),
    );
    if (!changeCols.has("diff")) this.sql.exec("ALTER TABLE changes ADD COLUMN diff TEXT");
    if (!changeCols.has("reason")) this.sql.exec("ALTER TABLE changes ADD COLUMN reason TEXT");
    if (this.meta("notesV1") === 0) this.ctx.storage.transactionSync(() => this.migrateNotesV1());
    if (this.meta("issueRefsV1") === 0) {
      // A store must open even when this fails. The next start tries again.
      try {
        this.ctx.storage.transactionSync(() => {
          this.backfillIssueRefs();
          this.setMeta("issueRefsV1", 1);
        });
      } catch (e) {
        logEvent("issue_refs_backfill_failed", { error: e instanceof CoreInputError ? e.message : "unexpected" });
      }
    }
  }

  /// One time (docs/TASK_REFERENCES_SPEC.md §6.6, ADR 0033): every task whose
  /// conversation text names a GitHub issue or pull request gets one `about`
  /// reference to it. The search order is the app's `TaskConvo.linkedIssue`:
  /// artifact refs, body and title, the handoff payload, the end-state note,
  /// then the newest provider turn (note, then question). It runs again
  /// without effect. Returns how many references it added.
  backfillIssueRefs(): number {
    const now = new Date().toISOString();
    const tasks = this.sql.exec<{ id: string; artifact: string | null; handoff: string | null; endStateNote: string | null }>(`
      SELECT t.id AS id, c.artifact AS artifact, c.handoff AS handoff, c.endStateNote AS endStateNote
      FROM tasks t LEFT JOIN convos c ON c.id = t.id AND c.deletedAt IS NULL
      WHERE t.deletedAt IS NULL
        AND (c.artifact LIKE '%github.com%' OR c.handoff LIKE '%github.com%' OR c.endStateNote LIKE '%github.com%'
             OR EXISTS (SELECT 1 FROM turns WHERE taskId = t.id AND role = 'provider'
                          AND (note LIKE '%github.com%' OR question LIKE '%github.com%')))
      ORDER BY t.rev
    `).toArray();
    let added = 0;
    for (const t of tasks) {
      const artifact = t.artifact ? (JSON.parse(t.artifact) as { title?: string; body?: string; refs?: string[] }) : null;
      const handoff = t.handoff ? (JSON.parse(t.handoff) as { payload?: string }) : null;
      const texts: (string | null | undefined)[] = [
        ...(artifact?.refs ?? []), artifact?.body, artifact?.title, handoff?.payload, t.endStateNote,
      ];
      const turns = this.sql.exec<{ note: string | null; question: string | null }>(
        "SELECT note, question FROM turns WHERE taskId = ? AND role = 'provider' ORDER BY seq DESC", t.id,
      ).toArray();
      for (const turn of turns) texts.push(turn.note, turn.question);
      for (const text of texts) {
        const [ref] = text ? findIssueRefs(text) : [];
        if (!ref) continue;
        if (this.addIssueRef(t.id, ref, "system:migration", now)) added++;
        break;
      }
    }
    return added;
  }

  /// One time (ADR 0012): give every existing note a first revision, then
  /// merge each project's retired `context` into its notes, above `## Log`.
  private migrateNotesV1(): void {
    const now = new Date().toISOString();
    for (const container of Object.keys(NOTE_FIELD) as NoteContainer[]) {
      const field = NOTE_FIELD[container];
      const table = ENTITIES[container].table;
      const rows = this.sql.exec<{ id: string; body: string | null }>(
        `SELECT id, "${field}" AS body FROM ${table} WHERE deletedAt IS NULL AND "${field}" IS NOT NULL AND "${field}" != '' AND COALESCE(noteRev, 0) = 0`,
      ).toArray();
      for (const r of rows) this.recordNoteRevision(container, r.id, r.body, "system:migration", now, 0, "first revision");
    }
    const merges = this.sql.exec<{ id: string; notes: string | null; context: string; noteRev: number | null }>(
      "SELECT id, notes, context, noteRev FROM projects WHERE deletedAt IS NULL AND context IS NOT NULL AND TRIM(context) != ''",
    ).toArray();
    const reason = "merge project context into notes";
    for (const r of merges) {
      const notes = mergeContextIntoNotes(r.notes, r.context, now.slice(0, 10));
      const rev = this.nextRev();
      this.sql.exec("UPDATE projects SET notes = ?, context = NULL, rev = ?, updatedAt = ? WHERE id = ?", notes, rev, now, r.id);
      const prevReason = this.reason;
      this.reason = reason;
      this.log(rev, "project", r.id, "upsert", ["notes", "context"], null, "system:migration", now,
        this.diffFor({ notes: r.notes, context: r.context }, { notes, context: null }));
      this.reason = prevReason;
      this.recordNoteRevision("project", r.id, notes, "system:migration", now, r.noteRev ?? 0, reason);
    }
    this.setMeta("notesV1", 1);
  }

  /// Writes one notes revision and bumps the row's `noteRev`. Returns it.
  private recordNoteRevision(
    container: NoteContainer, id: string, body: string | null, actor: string, at: string,
    prevNoteRev: number, reason: string | null,
  ): number {
    const noteRev = prevNoteRev + 1;
    this.sql.exec(`UPDATE ${ENTITIES[container].table} SET noteRev = ? WHERE id = ?`, noteRev, id);
    this.sql.exec(
      "INSERT INTO note_revisions (container, id, rev, body, actor, at, reason) VALUES (?, ?, ?, ?, ?, ?, ?)",
      container, id, noteRev, body, actor, at, reason,
    );
    return noteRev;
  }

  /// The notes refusal for an agent upsert on a project or area, or null.
  private agentNotesRefusal(
    op: Extract<Op, { op: "upsert" }>, container: NoteContainer, row: Record<string, unknown> | undefined,
  ): { reason: string; current?: { notes: string | null; noteRev: number } } | null {
    const field = NOTE_FIELD[container];
    if (!(field in op.fields)) return null;
    if (this.readSetting("agentsPaused") === true) return { reason: "paused" };
    if (!row) return null; // A new container has nothing to overwrite.
    const before = (row[field] as string | null) ?? null;
    const noteRev = (row.noteRev as number | null) ?? 0;
    if (op.baseNoteRev !== noteRev) return { reason: "stale", current: { notes: before, noteRev } };
    if (!agentMayWriteNotes(before, (op.fields[field] as string | null) ?? null)) return { reason: "brief_is_users" };
    return null;
  }

  private migrateTables(): void {
    for (const name of ENTITY_NAMES) {
      const spec = ENTITIES[name];
      this.sql.exec(createTableSQL(spec));
      const existing = new Set(
        this.sql.exec<{ name: string }>(`PRAGMA table_info(${spec.table})`).toArray().map((r) => r.name),
      );
      for (const stmt of addMissingColumnsSQL(spec, existing)) this.sql.exec(stmt);
    }
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
      CREATE INDEX IF NOT EXISTS changes_row ON changes(entity, id, rev);
      CREATE TABLE IF NOT EXISTS client_ops (
        clientOpId TEXT PRIMARY KEY, result TEXT NOT NULL, at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sessions (
        hash TEXT PRIMARY KEY, createdAt INTEGER NOT NULL, expiresAt INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS note_revisions (
        container TEXT NOT NULL, id TEXT NOT NULL, rev INTEGER NOT NULL,
        body TEXT, actor TEXT NOT NULL, at TEXT NOT NULL, reason TEXT,
        PRIMARY KEY (container, id, rev)
      );
      CREATE TABLE IF NOT EXISTS entitlements (
        id TEXT PRIMARY KEY, source TEXT NOT NULL, productId TEXT, expiresAt INTEGER,
        originalTransactionId TEXT, status TEXT NOT NULL, environment TEXT, note TEXT,
        signedAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS task_ref_removals (
        taskId TEXT NOT NULL, key TEXT NOT NULL, at TEXT NOT NULL,
        PRIMARY KEY (taskId, key)
      );
      CREATE TABLE IF NOT EXISTS ical_feed (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        token TEXT NOT NULL,
        tokenHash TEXT NOT NULL,
        scope TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS checklist_items_task ON checklist_items(taskId);
      CREATE INDEX IF NOT EXISTS task_refs_task ON task_refs(taskId);
      CREATE INDEX IF NOT EXISTS task_refs_key ON task_refs(key);
      CREATE INDEX IF NOT EXISTS tags_name_ci ON tags(lower(name));
      CREATE TABLE IF NOT EXISTS devices (
        sid TEXT PRIMARY KEY, client TEXT, firstSeen INTEGER NOT NULL,
        lastSeen INTEGER NOT NULL, slotAt INTEGER
      );
      CREATE TABLE IF NOT EXISTS usage (
        key TEXT PRIMARY KEY, count INTEGER NOT NULL, updatedAt INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS connections (
        familyId TEXT PRIMARY KEY, clientId TEXT NOT NULL, clientName TEXT NOT NULL,
        scope TEXT NOT NULL, createdAt INTEGER NOT NULL, lastUsed INTEGER NOT NULL
      );
    `);
    // A session's stable id (one per sign-in on one install). It survives
    // refresh-token rotation, so it names the device for the sync slot.
    const sessionCols = this.sql.exec<{ name: string }>("PRAGMA table_info(sessions)").toArray().map((r) => r.name);
    if (!sessionCols.includes("sid")) this.sql.exec("ALTER TABLE sessions ADD COLUMN sid TEXT");
    // The name the user gave an agent (pairing or Settings rename). Null =
    // the client's registered name.
    const connectionCols = this.sql.exec<{ name: string }>("PRAGMA table_info(connections)").toArray().map((r) => r.name);
    if (!connectionCols.includes("label")) this.sql.exec("ALTER TABLE connections ADD COLUMN label TEXT");
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

  /// The writer's stated reason for the push in progress (push sets it).
  private reason: string | null = null;

  private log(
    rev: number, entity: string, id: string, op: string, fields: string[] | null,
    clientOpId: string | null, actor: string, at: string, diff: ChangeDiff | null = null,
  ): void {
    this.sql.exec(
      "INSERT INTO changes (rev, entity, id, op, fields, clientOpId, actor, at, diff, reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      rev, entity, id, op, fields ? JSON.stringify(fields) : null, clientOpId, actor, at,
      diff && Object.keys(diff).length ? JSON.stringify(diff) : null, this.reason,
    );
  }

  /// Before/after per field for the change log. `before` is the decoded row
  /// (or null for an insert), `after` the pushed values. Only fields whose
  /// value actually changed are kept; long text is cut to keep the log small.
  private diffFor(before: Record<string, unknown> | null, after: Record<string, unknown>): ChangeDiff {
    const out: ChangeDiff = {};
    for (const [name, next] of Object.entries(after)) {
      const prev = before ? (before[name] ?? null) : null;
      if (JSON.stringify(prev) === JSON.stringify(next ?? null)) continue;
      out[name] = [clipForLog(prev), clipForLog(next ?? null)];
    }
    return out;
  }

  /// History of one row (newest first), or of the whole store when `id` is
  /// omitted. Paged by rev: pass the smallest rev seen as `before`.
  /// `since` (ISO) is the plan's history window: older rows stay stored but
  /// are not shown.
  history(entity: string | null, id: string | null, before: number | null, limit: number, since: string | null = null): ChangeEntry[] {
    const { where, args } = this.historyWhere(entity, id, since);
    if (before !== null) { where.push("rev < ?"); args.push(before); }
    const sql = `SELECT rev, entity, id, op, fields, diff, actor, at, reason FROM changes${where.length ? ` WHERE ${where.join(" AND ")}` : ""} ORDER BY rev DESC LIMIT ?`;
    return this.sql.exec<{ rev: number; entity: string; id: string; op: string; fields: string | null; diff: string | null; actor: string; at: string; reason: string | null }>(sql, ...args, limit)
      .toArray()
      .map((r) => ({
        rev: r.rev, entity: r.entity, id: r.id, op: r.op, actor: r.actor, at: r.at, reason: r.reason,
        fields: r.fields ? (JSON.parse(r.fields) as string[]) : null,
        diff: r.diff ? (JSON.parse(r.diff) as ChangeDiff) : null,
      }));
  }

  /// How many changes the history window hides (for the "older changes"
  /// upsell, spec §3.2).
  historyHidden(entity: string | null, id: string | null, since: string): number {
    const { where, args } = this.historyWhere(entity, id, null);
    where.push("at < ?"); args.push(since);
    return this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM changes WHERE ${where.join(" AND ")}`, ...args).one().n;
  }

  private historyWhere(entity: string | null, id: string | null, since: string | null): { where: string[]; args: (string | number)[] } {
    const where: string[] = [];
    const args: (string | number)[] = [];
    if (entity) { where.push("entity = ?"); args.push(entity); }
    if (id) {
      // Turns are logged as `taskId:seq`; a task's history includes them.
      where.push("(id = ? OR id LIKE ?)"); args.push(id, `${id}:%`);
    }
    if (since !== null) { where.push("at >= ?"); args.push(since); }
    return { where, args };
  }

  // ---- push ----

  push(ops: Op[], actor: string, reason: string | null = null): PushOutcome {
    const purgedAttachmentIds: string[] = [];
    this.reason = reason;
    let results: OpResult[];
    try {
      results = this.ctx.storage.transactionSync(() => ops.map((op) => {
        const seen = this.sql.exec<{ result: string }>("SELECT result FROM client_ops WHERE clientOpId = ?", op.clientOpId).toArray()[0];
        if (seen) return JSON.parse(seen.result) as OpResult;
        const result = this.apply(op, actor, purgedAttachmentIds);
        this.sql.exec("INSERT INTO client_ops (clientOpId, result, at) VALUES (?, ?, ?)", op.clientOpId, JSON.stringify(result), Date.now());
        return result;
      }));
    } finally {
      this.reason = null;
    }
    const appliedThrough = this.meta("rev");
    if (results.some((r) => r.status === "applied")) this.broadcast(appliedThrough);
    return { result: { appliedThrough, results }, purgedAttachmentIds };
  }

  private apply(op: Op, actor: string, purgedAttachmentIds: string[]): OpResult {
    const now = new Date().toISOString();
    if (isAgentActor(actor)) {
      const refusal = this.agentRefusal(op);
      if (refusal) {
        const rule = AGENT_WRITE_RULES[refusal];
        return rule
          ? { clientOpId: op.clientOpId, status: "rejected", reason: refusal, rule }
          : { clientOpId: op.clientOpId, status: "rejected", reason: refusal };
      }
    }
    if (op.op === "appendTurn") return this.appendTurn(op.clientOpId, op.taskId, op.turn, actor, now);

    const spec: EntitySpec = ENTITIES[op.entity];
    const row = this.sql.exec(`SELECT * FROM ${spec.table} WHERE id = ?`, op.id).toArray()[0];

    if (op.op === "delete") {
      if (!row || row.deletedAt) return { clientOpId: op.clientOpId, status: "noop" };
      const rev = this.nextRev();
      this.sql.exec(`UPDATE ${spec.table} SET deletedAt = ?, rev = ?, updatedAt = ? WHERE id = ?`, now, rev, now, op.id);
      // The deleted row's last values, so the log can show (and a later
      // tool can restore) what was removed.
      const gone = decodeRow(spec, row as Record<string, unknown>);
      const snapshot: ChangeDiff = {};
      for (const name of Object.keys(spec.columns)) {
        if (gone[name] !== null && gone[name] !== undefined && gone[name] !== false) snapshot[name] = [clipForLog(gone[name]), null];
      }
      this.log(rev, op.entity, op.id, "delete", null, op.clientOpId, actor, now, snapshot);
      if (op.entity === "attachment") purgedAttachmentIds.push(op.id);
      if (op.entity === "task") {
        this.tombstoneConvo(op.id, now);
        purgedAttachmentIds.push(...this.tombstoneAttachments(op.id, now));
        this.tombstoneChecklistItems(op.id, now);
        this.tombstoneTaskRefs(op.id, now);
      }
      if (op.entity === "taskRef" && !isAgentActor(actor)) {
        // A user's own removal wins over every automatic add (§6.6).
        this.sql.exec("INSERT OR REPLACE INTO task_ref_removals (taskId, key, at) VALUES (?, ?, ?)", gone.taskId, gone.key, now);
      }
      return { clientOpId: op.clientOpId, status: "applied", rev };
    }

    const noteContainer = isNoteContainer(op.entity) ? op.entity : null;
    if (noteContainer && isAgentActor(actor) && !row?.deletedAt) {
      const refusal = this.agentNotesRefusal(op, noteContainer, row as Record<string, unknown> | undefined);
      if (refusal) {
        return {
          clientOpId: op.clientOpId, status: "rejected", reason: refusal.reason, rule: AGENT_WRITE_RULES[refusal.reason],
          ...(refusal.current ? { current: refusal.current } : {}),
        };
      }
    }

    if (op.entity === "taskRef" && row && !row.deletedAt) this.dropSameRefIdentity(op, row as Record<string, unknown>);
    const names = Object.keys(op.fields);
    // Columns only the store writes, set when the row is inserted.
    let owned: Record<string, unknown> = {};
    if (row?.deletedAt) {
      const rev = this.nextRev();
      this.log(rev, op.entity, op.id, "dropped", names, op.clientOpId, actor, now, this.diffFor(null, op.fields));
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
      if (op.entity === "checklistItem") {
        const taskId = op.fields.taskId as string;
        if (!this.liveTask(taskId)) return { clientOpId: op.clientOpId, status: "rejected", reason: "unknown_task" };
        const count = this.sql.exec<{ n: number }>(
          "SELECT COUNT(*) AS n FROM checklist_items WHERE taskId = ? AND deletedAt IS NULL",
          taskId,
        ).one().n;
        if (count >= MAX_CHECKLIST_ITEMS_PER_TASK) {
          return { clientOpId: op.clientOpId, status: "rejected", reason: "checklist_limit_exceeded" };
        }
      }
      if (op.entity === "taskRef") {
        const taskId = op.fields.taskId as string;
        const ref = this.parseKey(op.fields.key as string);
        if (!ref) return { clientOpId: op.clientOpId, status: "rejected", reason: "invalid_key" };
        if (!this.liveTask(taskId)) return { clientOpId: op.clientOpId, status: "rejected", reason: "unknown_task" };
        if (this.hasLiveRef(taskId, ref.key)) return { clientOpId: op.clientOpId, status: "rejected", reason: "duplicate_ref" };
        if (this.liveRefCount(taskId) >= MAX_REFS_PER_TASK) {
          return { clientOpId: op.clientOpId, status: "rejected", reason: "ref_limit_exceeded" };
        }
        op.fields.key = ref.key;
        owned = { kind: ref.kind, createdBy: actor, ...(op.fields.createdAt ? {} : { createdAt: now }) };
        if (!isAgentActor(actor)) {
          this.sql.exec("DELETE FROM task_ref_removals WHERE taskId = ? AND key = ?", taskId, ref.key);
        }
      }
    } else {
      const locked = spec.updatable ? names.filter((f) => !spec.updatable!.includes(f)) : [];
      if (locked.length) return { clientOpId: op.clientOpId, status: "rejected", reason: `immutable:${locked.join(",")}` };
      const cleared = spec.requiredOnInsert.filter((f) => op.fields[f] === null);
      if (cleared.length) return { clientOpId: op.clientOpId, status: "rejected", reason: `required:${cleared.join(",")}` };
    }

    if (op.entity === "task" && Array.isArray(op.fields.tags)) {
      const seen = new Set<string>();
      const deduped: string[] = [];
      for (const id of op.fields.tags as string[]) {
        if (!seen.has(id)) {
          seen.add(id);
          deduped.push(id);
        }
      }
      if (deduped.length > MAX_TAGS_PER_TASK) {
        return { clientOpId: op.clientOpId, status: "rejected", reason: "tag_limit_exceeded" };
      }
      op.fields.tags = deduped;
    }
    if (op.entity === "tag" && typeof op.fields.name === "string") {
      const trimmed = op.fields.name.trim();
      op.fields.name = trimmed;
      const conflict = this.sql.exec<{ id: string }>(
        "SELECT id FROM tags WHERE lower(name) = lower(?) AND deletedAt IS NULL AND id != ?",
        trimmed, op.id,
      ).toArray()[0];
      if (conflict) {
        return { clientOpId: op.clientOpId, status: "rejected", reason: "duplicate_tag_name" };
      }
    }

    // `endStateAt` (server-owned) records when `endState` last changed, so
    // Review can show how long a hand-off has waited.
    if (op.entity === "convo" && "endState" in op.fields) {
      const previous = (row?.endState as string | null | undefined) ?? null;
      if (((op.fields.endState as string | null | undefined) ?? null) !== previous) {
        op.fields.endStateAt = now;
        names.push("endStateAt");
      }
    }

    const rev = this.nextRev();
    const cols = Object.entries(spec.columns);
    if (!row) {
      const inserted: Record<string, unknown> = { ...op.fields, ...owned };
      const insertCols = cols.filter(([n, c]) => inserted[n] !== undefined || c.dflt !== undefined);
      const values = insertCols.map(([n, c]) => (inserted[n] !== undefined ? encodeValue(c, inserted[n]) : c.dflt ?? null));
      const colList = insertCols.map(([n]) => `"${n}"`).concat(["id", "rev", "updatedAt"]).join(", ");
      const marks = insertCols.map(() => "?").concat(["?", "?", "?"]).join(", ");
      this.sql.exec(`INSERT INTO ${spec.table} (${colList}) VALUES (${marks})`, ...values, op.id, rev, now);
    } else {
      const sets = names.map((n) => `"${n}" = ?`).concat(["rev = ?", "updatedAt = ?"]).join(", ");
      const values = names.map((n) => encodeValue(spec.columns[n], op.fields[n]));
      this.sql.exec(`UPDATE ${spec.table} SET ${sets} WHERE id = ?`, ...values, rev, now, op.id);
    }
    const before = row ? decodeRow(spec, row as Record<string, unknown>) : null;
    this.log(rev, op.entity, op.id, "upsert", names, op.clientOpId, actor, now, this.diffFor(before, op.fields));
    if (noteContainer) {
      const field = NOTE_FIELD[noteContainer];
      const next = (op.fields[field] as string | null | undefined) ?? null;
      if (field in op.fields && next !== ((before?.[field] as string | null | undefined) ?? null)) {
        this.recordNoteRevision(noteContainer, op.id, next, actor, now, (row?.noteRev as number | null) ?? 0, this.reason);
      }
    }
    if (isAgentActor(actor) && op.entity === "convo") {
      const { artifact, handoff, endStateNote } = op.fields as {
        artifact?: { title?: string; body?: string; refs?: string[] } | null;
        handoff?: { instruction?: string; payload?: string } | null;
        endStateNote?: string | null;
      };
      this.addWrittenIssueRefs(op.id, [
        ...(artifact?.refs ?? []), artifact?.body, artifact?.title, handoff?.payload, handoff?.instruction, endStateNote,
      ], actor, now);
    }
    if (isAgentActor(actor) && op.entity === "convo" && op.fields.endState === "needs_verify") {
      // Handing off to Review puts the ball in the human's court, so the claim ends.
      this.writeConvoServerFields(op.id, { claimedBy: null, claimUntil: null }, "release", actor, now, true);
    }
    return { clientOpId: op.clientOpId, status: "applied", rev };
  }

  /// The rules an agent write must pass, enforced here so no connector can
  /// skip them: the stop is the human's alone, a stopped task takes no agent
  /// writes at all, and an agent cannot mark an agent-worked task done —
  /// only the human accepts it after review (`human_accepts`).
  private agentRefusal(op: Op): string | null {
    if (op.op === "upsert" && op.entity === "convo" && "stoppedAt" in op.fields) return "human_only:stoppedAt";
    if (op.op === "upsert" && op.entity === "setting" && op.id === "agentsPaused") return "human_only:agentsPaused";
    if (op.op === "upsert" && op.entity === "project" && "context" in op.fields) return "retired:context";
    if (op.op === "upsert" && op.entity === "task") {
      const appOnly = APP_ONLY_TASK_FIELDS.find((f) => f in op.fields);
      if (appOnly) return `app_only:${appOnly}`;
    }
    const taskId = op.op === "appendTurn" ? op.taskId
      : (op.entity === "task" || op.entity === "convo") ? op.id
      : op.entity === "attachment" && op.op === "upsert" ? (op.fields.taskId as string | undefined) ?? null
      : op.entity === "checklistItem" ? this.checklistItemTaskId(op)
      : op.entity === "taskRef" ? this.taskRefTaskId(op)
      : null;
    if (taskId && this.convoStopped(taskId)) return "stopped";
    if (op.op !== "appendTurn" && op.entity === "taskRef" && this.readSetting("agentsPaused") === true) return "paused";
    if (op.op === "upsert" && op.entity === "task" && op.fields.status === "done" && this.convoRequiresHumanAccept(op.id)) {
      return "human_accepts";
    }
    return null;
  }

  private convoStopped(taskId: string): boolean {
    return this.sql.exec("SELECT 1 FROM convos WHERE id = ? AND deletedAt IS NULL AND stoppedAt IS NOT NULL", taskId).toArray().length > 0;
  }

  /// True when an agent must hand the task to Review (`needs_verify`) rather
  /// than closing it directly: assigned to an agent (`claude`), already waiting
  /// in Review (`needs_verify`), or currently held under a live agent claim.
  private convoRequiresHumanAccept(taskId: string): boolean {
    const row = this.sql.exec<{
      assignee: string | null; endState: string | null; claimedBy: string | null; claimUntil: string | null;
    }>(
      "SELECT assignee, endState, claimedBy, claimUntil FROM convos WHERE id = ? AND deletedAt IS NULL",
      taskId,
    ).toArray()[0];
    if (!row) return false;
    if (row.assignee === "claude" || row.endState === "needs_verify") return true;
    return !!row.claimedBy && !!row.claimUntil && Date.parse(row.claimUntil) > Date.now();
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

  /// A permanently deleted task takes its checklist items with it.
  private tombstoneChecklistItems(taskId: string, now: string): void {
    const ids = this.sql.exec<{ id: string }>(
      "SELECT id FROM checklist_items WHERE taskId = ? AND deletedAt IS NULL",
      taskId,
    ).toArray().map((r) => r.id);
    for (const id of ids) {
      const rev = this.nextRev();
      this.sql.exec("UPDATE checklist_items SET deletedAt = ?, rev = ?, updatedAt = ? WHERE id = ?", now, rev, now, id);
    }
  }

  private checklistItemTaskId(op: Op): string | null {
    if (op.op === "upsert" && typeof op.fields.taskId === "string") return op.fields.taskId;
    if (op.op === "upsert" || op.op === "delete") {
      const row = this.sql.exec<{ taskId: string }>(
        "SELECT taskId FROM checklist_items WHERE id = ?",
        op.id,
      ).toArray()[0];
      return row?.taskId ?? null;
    }
    return null;
  }

  // ---- task references (docs/TASK_REFERENCES_SPEC.md, ADR 0031) ----

  /// A permanently deleted task takes its references with it.
  private tombstoneTaskRefs(taskId: string, now: string): void {
    const ids = this.sql.exec<{ id: string }>(
      "SELECT id FROM task_refs WHERE taskId = ? AND deletedAt IS NULL", taskId,
    ).toArray().map((r) => r.id);
    for (const id of ids) {
      const rev = this.nextRev();
      this.sql.exec("UPDATE task_refs SET deletedAt = ?, rev = ?, updatedAt = ? WHERE id = ?", now, rev, now, id);
    }
  }

  /// The task of a reference op. The stored row decides, never the push.
  private taskRefTaskId(op: Extract<Op, { op: "upsert" | "delete" }>): string | null {
    const row = this.sql.exec<{ taskId: string }>("SELECT taskId FROM task_refs WHERE id = ?", op.id).toArray()[0];
    if (row) return row.taskId;
    return op.op === "upsert" && typeof op.fields.taskId === "string" ? op.fields.taskId : null;
  }

  /// The core's parse of a key, or null when it is not valid.
  private parseKey(key: string): CoreRef | null {
    try {
      return parseRef(key);
    } catch (e) {
      if (e instanceof CoreInputError) return null;
      throw e;
    }
  }

  private hasLiveRef(taskId: string, key: string): boolean {
    return this.sql.exec("SELECT 1 FROM task_refs WHERE taskId = ? AND key = ? AND deletedAt IS NULL", taskId, key).toArray().length > 0;
  }

  private liveRefCount(taskId: string): number {
    return this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM task_refs WHERE taskId = ? AND deletedAt IS NULL", taskId).one().n;
  }

  /// Two offline devices that add one reference mint one id (§4), so the
  /// second insert arrives as an update of the same task and key. Its
  /// identity fields say nothing new; the rest is an ordinary update.
  private dropSameRefIdentity(op: Extract<Op, { op: "upsert" }>, row: Record<string, unknown>): void {
    const { taskId, key } = op.fields;
    if (taskId !== row.taskId || typeof key !== "string" || this.parseKey(key)?.key !== row.key) return;
    const { taskId: _t, key: _k, createdAt: _c, ...rest } = op.fields;
    op.fields = rest;
  }

  /// The id of the next reference of this task to this key. Purged
  /// tombstones lower the count, so an id in use moves on to the next one.
  newRefId(taskId: string, key: string): string {
    let n = this.sql.exec<{ n: number }>(
      "SELECT COUNT(*) AS n FROM task_refs WHERE taskId = ? AND key = ? AND deletedAt IS NOT NULL", taskId, key,
    ).one().n;
    for (;;) {
      const id = taskRefId(taskId, key, n++);
      if (this.sql.exec("SELECT 1 FROM task_refs WHERE id = ?", id).toArray().length === 0) return id;
    }
  }

  /// Adds the `issue` references an agent wrote as URLs into a conversation
  /// (§6.6), up to the limit. The first link in the text is added last, so it
  /// is the task's newest issue, as the text parser had it.
  private addWrittenIssueRefs(taskId: string, texts: (string | null | undefined)[], actor: string, now: string): void {
    const refs = new Map<string, CoreRef>();
    for (const text of texts) {
      if (!text) continue;
      for (const ref of findIssueRefs(text)) if (!refs.has(ref.key)) refs.set(ref.key, ref);
    }
    if (refs.size === 0 || this.readSetting("agentsPaused") === true || !this.liveTask(taskId)) return;
    const room = Math.max(0, MAX_REFS_PER_TASK - this.liveRefCount(taskId));
    const fresh = [...refs.values()].filter((r) => this.mayAddIssueRef(taskId, r.key)).slice(0, room);
    for (const ref of fresh.reverse()) this.addIssueRef(taskId, ref, actor, now);
  }

  /// False when the task has the key, or a user removed it.
  private mayAddIssueRef(taskId: string, key: string): boolean {
    return !this.hasLiveRef(taskId, key)
      && this.sql.exec("SELECT 1 FROM task_ref_removals WHERE taskId = ? AND key = ?", taskId, key).toArray().length === 0;
  }

  /// One `about` reference to an issue, as its own rev. False when the task
  /// may not get it.
  private addIssueRef(taskId: string, ref: CoreRef, actor: string, now: string): boolean {
    if (!this.mayAddIssueRef(taskId, ref.key) || this.liveRefCount(taskId) >= MAX_REFS_PER_TASK) return false;
    const snapshot: RefSnapshot = {
      ...(ref.url ? { url: ref.url } : {}),
      ...(ref.rawId !== ref.id ? { rawId: ref.rawId } : {}),
    };
    const top = this.sql.exec<{ m: number | null }>(
      "SELECT MAX(position) AS m FROM task_refs WHERE taskId = ? AND deletedAt IS NULL", taskId,
    ).one().m ?? 0;
    const fields: Record<string, unknown> = {
      taskId, key: ref.key, kind: ref.kind, role: "about",
      snapshot: Object.keys(snapshot).length > 0 && snapshotFits(snapshot) ? snapshot : null,
      position: top + 1024, createdBy: actor, createdAt: now,
    };
    const id = this.newRefId(taskId, ref.key);
    const rev = this.nextRev();
    const names = Object.keys(fields);
    this.sql.exec(
      `INSERT INTO task_refs (${names.map((n) => `"${n}"`).join(", ")}, id, rev, updatedAt) VALUES (${names.map(() => "?").join(", ")}, ?, ?, ?)`,
      ...names.map((n) => encodeValue(ENTITIES.taskRef.columns[n as keyof typeof ENTITIES.taskRef.columns], fields[n])), id, rev, now,
    );
    this.log(rev, "taskRef", id, "upsert", names, null, actor, now, this.diffFor(null, fields));
    return true;
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
    if (isAgentActor(actor)) this.addWrittenIssueRefs(taskId, [turn.note, turn.question], actor, now);
    if (!isAgentActor(actor) && turn.role === "user") {
      // The human spoke: the run budget starts over.
      this.writeConvoServerFields(taskId, { runsSinceUser: 0 }, "budget", actor, now, true);
    } else if (isAgentActor(actor) && turn.role === "provider" && turn.options?.length) {
      // The agent asked: the ball is in the human's court, so the claim ends.
      this.writeConvoServerFields(taskId, { claimedBy: null, claimUntil: null }, "release", actor, now, true);
    }
    return { clientOpId, status: "applied", rev, seq };
  }

  // ---- agent claims (docs/TASK_FACTORY_SPEC.md §5) ----

  /// Writes server-owned convo columns as their own rev, creating the convo
  /// row when the task has none. `onlyIfChanged` skips a write that would
  /// change nothing, so a quiet rule never bumps the rev.
  private writeConvoServerFields(
    taskId: string, fields: Record<string, string | number | null>, op: string,
    actor: string, now: string, onlyIfChanged = false,
  ): number | null {
    const raw = this.sql.exec("SELECT * FROM convos WHERE id = ?", taskId).toArray()[0] as Record<string, unknown> | undefined;
    if (raw?.deletedAt) return null;
    if (onlyIfChanged && Object.entries(fields).every(([k, v]) => (raw?.[k] ?? null) === v)) return null;
    if (onlyIfChanged && !raw) return null;
    const rev = this.nextRev();
    const names = Object.keys(fields);
    if (raw) {
      const sets = names.map((n) => `"${n}" = ?`).concat(["rev = ?", "updatedAt = ?"]).join(", ");
      this.sql.exec(`UPDATE convos SET ${sets} WHERE id = ?`, ...Object.values(fields), rev, now, taskId);
    } else {
      const cols = names.map((n) => `"${n}"`).concat(["id", "rev", "updatedAt"]).join(", ");
      const marks = names.map(() => "?").concat(["?", "?", "?"]).join(", ");
      this.sql.exec(`INSERT INTO convos (${cols}) VALUES (${marks})`, ...Object.values(fields), taskId, rev, now);
    }
    const before: Record<string, unknown> = {};
    for (const n of names) before[n] = raw?.[n] ?? null;
    this.log(rev, "convo", taskId, op, names, null, actor, now, this.diffFor(before, fields));
    return rev;
  }

  /// Takes or renews the claim on a task for `holder`. The DO serializes
  /// calls, so two agents can never both win. Refuses, with the rule that
  /// stopped it, when agents are paused, the human stopped the task, a
  /// question waits for the human, another holder's lease is live, or the
  /// run budget since the last human turn is spent.
  claim(taskId: string, holder: string, ttlMs: number, actor: string, reason: string | null): ClaimResult {
    const result = this.ctx.storage.transactionSync((): ClaimResult => {
      if (this.readSetting("agentsPaused") === true) return { ok: false, reason: "paused" };
      const task = this.sql.exec<{ status: string; deletedAt: string | null }>("SELECT status, deletedAt FROM tasks WHERE id = ?", taskId).toArray()[0];
      if (!task || task.deletedAt) return { ok: false, reason: "not_found" };
      if (task.status !== "open") return { ok: false, reason: "closed" };
      const convo = this.sql.exec<{
        endState: string | null; stoppedAt: string | null; claimedBy: string | null;
        claimUntil: string | null; runsSinceUser: number | null;
      }>("SELECT endState, stoppedAt, claimedBy, claimUntil, runsSinceUser FROM convos WHERE id = ? AND deletedAt IS NULL", taskId).toArray()[0];
      if (convo?.stoppedAt) return { ok: false, reason: "stopped" };
      if (convo?.endState && convo.endState !== "open") return { ok: false, reason: "terminal" };
      if (this.awaitsHuman(taskId)) return { ok: false, reason: "your_turn" };
      const nowMs = Date.now();
      const live = !!convo?.claimedBy && !!convo.claimUntil && Date.parse(convo.claimUntil) > nowMs;
      if (live && convo!.claimedBy !== holder) {
        return { ok: false, reason: "held", holder: convo!.claimedBy!, claimUntil: convo!.claimUntil! };
      }
      const renewed = live;
      const runs = (convo?.runsSinceUser ?? 0) + (renewed ? 0 : 1);
      if (!renewed && runs > AGENT_RUN_BUDGET) return { ok: false, reason: "budget" };
      const claimUntil = new Date(nowMs + Math.min(Math.max(ttlMs, 60_000), CLAIM_TTL_MAX_MS)).toISOString();
      this.reason = reason;
      try {
        this.writeConvoServerFields(taskId, { claimedBy: holder, claimUntil, runsSinceUser: runs }, renewed ? "renew" : "claim", actor, new Date(nowMs).toISOString());
      } finally {
        this.reason = null;
      }
      return { ok: true, holder, claimUntil, renewed, runsSinceUser: runs };
    });
    if (result.ok) this.broadcast(this.meta("rev"));
    return result;
  }

  /// Ends `holder`'s claim. A lease that already ran out, or one held by
  /// someone else, is left as it is. Returns whether a claim was cleared.
  release(taskId: string, holder: string, actor: string, reason: string | null): boolean {
    const rev = this.ctx.storage.transactionSync(() => {
      const convo = this.sql.exec<{ claimedBy: string | null }>("SELECT claimedBy FROM convos WHERE id = ? AND deletedAt IS NULL", taskId).toArray()[0];
      if (!convo || convo.claimedBy !== holder) return null;
      this.reason = reason;
      try {
        return this.writeConvoServerFields(taskId, { claimedBy: null, claimUntil: null }, "release", actor, new Date().toISOString());
      } finally {
        this.reason = null;
      }
    });
    if (rev !== null) this.broadcast(rev);
    return rev !== null;
  }

  /// The last turn is the agent's question and no human turn followed it.
  private awaitsHuman(taskId: string): boolean {
    const last = this.sql.exec<{ role: string; options: string | null }>(
      "SELECT role, options FROM turns WHERE taskId = ? ORDER BY seq DESC LIMIT 1", taskId,
    ).toArray()[0];
    if (!last || last.role !== "provider" || !last.options) return false;
    const opts = JSON.parse(last.options) as unknown;
    return Array.isArray(opts) && opts.length > 0;
  }

  /// The newest rev: the cursor for an agent that starts listening now.
  head(): number {
    return this.meta("rev");
  }

  /// What changed since `since` that an agent may need to act on, oldest
  /// first, as pointers. `nextSince` is the cursor for the next call.
  agentEvents(since: number, limit: number): { events: AgentEvent[]; nextSince: number } {
    const n = Math.min(Math.max(limit, 1), 500);
    const events: AgentEvent[] = [];
    let cursor = since;
    // Scan in pages so a long run of agent-only writes cannot starve the feed.
    for (let page = 0; page < 10 && events.length < n; page++) {
      const rows = this.sql.exec<{ rev: number; entity: string; id: string; op: string; diff: string | null; actor: string; at: string }>(
        "SELECT rev, entity, id, op, diff, actor, at FROM changes WHERE rev > ? ORDER BY rev LIMIT 500", cursor,
      ).toArray();
      if (!rows.length) break;
      for (const r of rows) {
        cursor = r.rev;
        if (isAgentActor(r.actor)) continue;
        const diff = r.diff ? (JSON.parse(r.diff) as ChangeDiff) : {};
        const push = (kind: AgentEvent["kind"], taskId: string | null) => events.push({ rev: r.rev, kind, taskId, at: r.at });
        if (r.entity === "turn" && r.op === "append") {
          // The app also writes on-device provider turns; only the human's count.
          const [taskId, seq] = r.id.split(":");
          const turn = this.sql.exec<{ role: string }>("SELECT role FROM turns WHERE taskId = ? AND seq = ?", taskId, Number(seq)).toArray()[0];
          if (turn?.role === "user") push("user_turn", taskId);
        }
        else if (r.entity === "convo" && diff.assignee?.[1] === "claude") push("assigned", r.id);
        else if (r.entity === "convo" && diff.stoppedAt) push(diff.stoppedAt[1] ? "stopped" : "resumed", r.id);
        else if (r.entity === "setting" && r.id === "agentsPaused" && diff.value) push(diff.value[1] === true ? "paused" : "unpaused", null);
        if (events.length >= n) break;
      }
    }
    return { events, nextSince: events.length >= n ? cursor : Math.max(cursor, this.meta("rev")) };
  }

  // ---- pull ----

  /// `includeSettings`: the client syncs the `setting` entity. Clients built
  /// before it existed decode pulled entities strictly and would fail on it,
  /// so they get no setting rows (their cursor still moves past them).
  /// The other flags do the same for entities that came later.
  pull(
    since: number, limit: number, includeSettings = false, includeChecklists = false, includeTags = false,
    includeRefs = false,
  ): PullResult {
    const n = Math.min(Math.max(limit, 1), MAX_PULL);
    if (since > 0 && since < this.meta("purgedThrough")) {
      return { resetRequired: true, changes: [], nextSince: 0, hasMore: true };
    }
    // Each table is already ordered by rev, so merging their first n rows and
    // keeping the global first n is exact.
    const merged: Array<{ rev: number; entity: EntityName | "turn"; row: Record<string, unknown> }> = [];
    for (const name of ENTITY_NAMES) {
      if (name === "setting" && !includeSettings) continue;
      if (name === "checklistItem" && !includeChecklists) continue;
      if (name === "tag" && !includeTags) continue;
      if (name === "taskRef" && !includeRefs) continue;
      const spec: EntitySpec = ENTITIES[name];
      for (const raw of this.sql.exec(`SELECT * FROM ${spec.table} WHERE rev > ? ORDER BY rev LIMIT ?`, since, n)) {
        merged.push({ rev: raw.rev as number, entity: name, row: decodeRow(spec, raw) });
      }
    }
    for (const raw of this.sql.exec(`SELECT * FROM turns WHERE rev > ? ORDER BY rev LIMIT ?`, since, n)) {
      merged.push({ rev: raw.rev as number, entity: "turn", row: decodeTurnRow(raw) });
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

  // ---- reads for the MCP preview (src/shadow/) ----
  //
  // SQL queries that return decoded rows (the same shape a pull carries), so
  // a tool call never pulls the whole store. Live rows only: tombstones are
  // never returned. Formatting into tool output happens in the Worker.

  /// Open tasks (every one: the view filters need the whole open set), or
  /// done tasks newest first, capped. Headings are never tasks and are left
  /// out. `total` counts every matching row, not only the returned ones.
  readTasks(status: "open" | "done", limit: number): { rows: Row[]; total: number } {
    const spec: EntitySpec = ENTITIES.task;
    const where = "deletedAt IS NULL AND status = ? AND (kind IS NULL OR kind != 'heading')";
    const total = this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM tasks WHERE ${where}`, status).one().n;
    const order = status === "done"
      ? "ORDER BY completedAt IS NULL, completedAt DESC, rev DESC LIMIT ?"
      : "ORDER BY scheduled IS NULL, scheduled, position IS NULL, position, rev";
    const args: unknown[] = status === "done" ? [status, Math.min(Math.max(limit, 1), 500)] : [status];
    const rows = this.sql.exec(`SELECT * FROM tasks WHERE ${where} ${order}`, ...args).toArray().map((r) => decodeRow(spec, r) as Row);
    return { rows, total };
  }

  /// Open non-heading tasks awaiting human review (`convos.endState = 'needs_verify'`),
  /// newest hand-off first. Mirrors `TaskConvo.needsHumanReview` in SeptenaCore.
  readReviewTasks(limit: number): { rows: Row[]; notes: Record<string, string | null>; ats: Record<string, string | null>; total: number } {
    const spec: EntitySpec = ENTITIES.task;
    const n = Math.min(Math.max(limit, 1), 500);
    const where =
      "t.deletedAt IS NULL AND t.status = 'open' AND (t.kind IS NULL OR t.kind != 'heading') " +
      "AND c.deletedAt IS NULL AND c.endState = 'needs_verify'";
    const total = this.sql.exec<{ n: number }>(
      `SELECT COUNT(*) AS n FROM tasks t JOIN convos c ON c.id = t.id WHERE ${where}`,
    ).one().n;
    const raw = this.sql.exec(
      `SELECT t.*, c.endStateNote AS _reviewNote, c.endStateAt AS _reviewAt FROM tasks t JOIN convos c ON c.id = t.id WHERE ${where} ORDER BY c.updatedAt DESC, c.rev DESC LIMIT ?`,
      n,
    ).toArray();
    const ats: Record<string, string | null> = {};
    const notes: Record<string, string | null> = {};
    const rows: Row[] = raw.map((r) => {
      const id = r.id as string;
      notes[id] = (r._reviewNote as string | null | undefined) ?? null;
      ats[id] = (r._reviewAt as string | null | undefined) ?? null;
      return decodeRow(spec, r) as Row;
    });
    return { rows, notes, ats, total };
  }

  /// One live task with its conversation row and turns (oldest first).
  readTask(id: string): { task: Row; convo: Row | null; turns: Row[] } | null {
    const raw = this.sql.exec("SELECT * FROM tasks WHERE id = ? AND deletedAt IS NULL", id).toArray()[0];
    if (!raw) return null;
    const convoRaw = this.sql.exec("SELECT * FROM convos WHERE id = ? AND deletedAt IS NULL", id).toArray()[0];
    const turns = this.sql.exec("SELECT * FROM turns WHERE taskId = ? ORDER BY seq", id).toArray().map((r) => decodeTurnRow(r) as Row);
    return {
      task: decodeRow(ENTITIES.task, raw) as Row,
      convo: convoRaw ? (decodeRow(ENTITIES.convo, convoRaw) as Row) : null,
      turns,
    };
  }

  readChecklistItems(taskId: string): Row[] {
    return this.sql.exec(
      "SELECT * FROM checklist_items WHERE taskId = ? AND deletedAt IS NULL ORDER BY position IS NULL, position, createdAt, id",
      taskId,
    ).toArray().map((r) => decodeRow(ENTITIES.checklistItem, r) as Row);
  }

  readChecklistItem(id: string): Row | null {
    const raw = this.sql.exec(
      "SELECT * FROM checklist_items WHERE id = ? AND deletedAt IS NULL",
      id,
    ).toArray()[0];
    return raw ? (decodeRow(ENTITIES.checklistItem, raw) as Row) : null;
  }

  readChecklistCounts(): Record<string, { total: number; done: number }> {
    const rows = this.sql.exec<{ taskId: string; total: number; done: number }>(
      "SELECT taskId, COUNT(*) AS total, SUM(CASE WHEN checked = 1 THEN 1 ELSE 0 END) AS done FROM checklist_items WHERE deletedAt IS NULL GROUP BY taskId",
    ).toArray();
    const out: Record<string, { total: number; done: number }> = {};
    for (const r of rows) out[r.taskId] = { total: r.total, done: r.done ?? 0 };
    return out;
  }

  readTags(): Row[] {
    return this.sql.exec(
      "SELECT * FROM tags WHERE deletedAt IS NULL ORDER BY position IS NULL, position, lower(name), id",
    ).toArray().map((r) => decodeRow(ENTITIES.tag, r) as Row);
  }

  readTagByName(name: string): Row | null {
    const raw = this.sql.exec(
      "SELECT * FROM tags WHERE lower(name) = lower(?) AND deletedAt IS NULL",
      name.trim(),
    ).toArray()[0];
    return raw ? (decodeRow(ENTITIES.tag, raw) as Row) : null;
  }

  readAreas(limit: number): Row[] {
    return this.sql.exec(
      "SELECT * FROM areas WHERE deletedAt IS NULL ORDER BY position IS NULL, position, title LIMIT ?",
      Math.min(Math.max(limit, 1), 500),
    ).toArray().map((r) => decodeRow(ENTITIES.area, r) as Row);
  }

  readProjects(status: "active" | "done" | "cancelled" | "all", limit: number): Row[] {
    const n = Math.min(Math.max(limit, 1), 500);
    const order = "ORDER BY position IS NULL, position, title LIMIT ?";
    const rows = status === "all"
      ? this.sql.exec(`SELECT * FROM projects WHERE deletedAt IS NULL ${order}`, n)
      : this.sql.exec(`SELECT * FROM projects WHERE deletedAt IS NULL AND status = ? ${order}`, status, n);
    return rows.toArray().map((r) => decodeRow(ENTITIES.project, r) as Row);
  }

  /// Open tasks that have a conversation, with what the pending-reasoning
  /// rule needs: the convo fields and the confidence of the last provider
  /// turn. The rule itself runs in the Worker (tools/taskShared.ts).
  readConvoCandidates(): ConvoCandidate[] {
    return this.sql.exec<ConvoCandidate>(`
      SELECT t.id AS id, t.title AS title, c.confirmedIntent AS confirmedIntent,
             c.assignee AS assignee, c.endState AS endState,
             c.stoppedAt AS stoppedAt, c.claimedBy AS claimedBy, c.claimUntil AS claimUntil,
             (SELECT confidence FROM turns WHERE taskId = t.id AND role = 'provider' ORDER BY seq DESC LIMIT 1)
               AS lastProviderConfidence,
             (SELECT CASE WHEN role = 'provider' AND options IS NOT NULL AND options != '[]' THEN 1 ELSE 0 END
                FROM turns WHERE taskId = t.id ORDER BY seq DESC LIMIT 1) AS awaitsHuman
      FROM tasks t LEFT JOIN convos c ON c.id = t.id AND c.deletedAt IS NULL
      WHERE t.deletedAt IS NULL AND t.status = 'open'
        AND (c.id IS NOT NULL OR EXISTS (SELECT 1 FROM turns WHERE taskId = t.id))
      ORDER BY t.rev
    `).toArray();
  }

  /// Per task, what its list row says about references and its conversation:
  /// the reference count, the newest `issue` reference and the end state.
  /// Rows that would say nothing are left out.
  readTaskLinks(): TaskLinkRow[] {
    const out = new Map<string, TaskLinkRow>();
    const row = (id: string): TaskLinkRow => {
      let r = out.get(id);
      if (!r) out.set(id, r = { id, endState: null, refCount: 0, issue: null });
      return r;
    };
    for (const c of this.sql.exec<{ id: string; endState: string }>(
      "SELECT id, endState FROM convos WHERE deletedAt IS NULL AND endState IS NOT NULL AND endState != 'open'",
    )) row(c.id).endState = c.endState;
    for (const c of this.sql.exec<{ taskId: string; n: number }>(
      "SELECT taskId, COUNT(*) AS n FROM task_refs WHERE deletedAt IS NULL GROUP BY taskId",
    )) row(c.taskId).refCount = c.n;
    // rowid is the insert order. A later row replaces an earlier one.
    for (const r of this.sql.exec<{ taskId: string; key: string; snapshot: string | null }>(
      "SELECT taskId, key, snapshot FROM task_refs WHERE deletedAt IS NULL AND kind = 'issue' ORDER BY rowid",
    )) row(r.taskId).issue = { key: r.key, snapshot: r.snapshot ? (JSON.parse(r.snapshot) as RefSnapshot) : null };
    return [...out.values()];
  }

  /// A task's references, in order.
  readTaskRefs(taskId: string): Row[] {
    return this.sql.exec(
      "SELECT * FROM task_refs WHERE taskId = ? AND deletedAt IS NULL ORDER BY position IS NULL, position, rowid", taskId,
    ).toArray().map((r) => decodeRow(ENTITIES.taskRef, r) as Row);
  }

  /// The tasks that point at a key, active first, then the newest write
  /// first. `key` is in normal form.
  findByRef(key: string, limit: number): { tasks: RefHit[]; total: number } {
    const from = `FROM task_refs r JOIN tasks t ON t.id = r.taskId
      WHERE r.key = ? AND r.deletedAt IS NULL AND t.deletedAt IS NULL AND (t.kind IS NULL OR t.kind != 'heading')`;
    const total = this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n ${from}`, key).one().n;
    const tasks = this.sql.exec<Record<string, string | null>>(
      `SELECT t.id, t.title, t.status, t.area, t.project, t.fadedAt, r.role ${from}
       ORDER BY (t.status = 'open' AND t.fadedAt IS NULL) DESC, t.rev DESC LIMIT ?`,
      key, Math.min(Math.max(limit, 1), 200),
    ).toArray().map((r) => ({
      id: r.id as string, title: r.title ?? "", status: r.status ?? "open", area: r.area, project: r.project,
      faded: r.fadedAt !== null, role: r.role ?? "about",
    }));
    return { tasks, total };
  }

  /// The lowest order key across live tasks, or null when there is none:
  /// the app's `TaskOrder.extremeKey(highest: false)`. A row's key is its
  /// `position` once it has one (0 is the app's "never dragged" value),
  /// else its `createdAt` in seconds since 2001-01-01 (the app's
  /// `timeIntervalSinceReferenceDate`). The MCP connector subtracts the app's
  /// gap from it to put a row at the top of its list.
  readOrderTop(): number | null {
    return this.sql.exec<{ m: number | null }>(`
      SELECT MIN(k) AS m FROM (
        SELECT CASE
          WHEN position IS NOT NULL AND position != 0 THEN position
          WHEN createdAt IS NOT NULL THEN (julianday(createdAt) - 2440587.5) * 86400.0 - 978307200
        END AS k
        FROM tasks WHERE deletedAt IS NULL
      )
    `).one().m;
  }

  /// One synced setting's value (columns.ts `SETTING_VALUES`), or null when
  /// it was never set.
  /// One container's notes and their revision, or null when it is missing.
  readNote(container: NoteContainer, id: string): { notes: string | null; noteRev: number } | null {
    const field = NOTE_FIELD[container];
    const row = this.sql.exec<{ body: string | null; noteRev: number | null }>(
      `SELECT "${field}" AS body, noteRev FROM ${ENTITIES[container].table} WHERE id = ? AND deletedAt IS NULL`, id,
    ).toArray()[0];
    return row ? { notes: row.body, noteRev: row.noteRev ?? 0 } : null;
  }

  /// One project or area row, decoded, or null when missing or deleted.
  readContainer(container: NoteContainer, id: string): Row | null {
    const spec = ENTITIES[container];
    const raw = this.sql.exec(`SELECT * FROM ${spec.table} WHERE id = ? AND deletedAt IS NULL`, id).toArray()[0];
    return raw ? (decodeRow(spec, raw as Record<string, unknown>) as Row) : null;
  }

  /// Open tasks filed directly in a project or an area (headings excluded),
  /// in list order.
  readContainerTasks(container: NoteContainer, id: string, limit: number): Row[] {
    const raws = this.sql.exec(
      `SELECT * FROM tasks WHERE "${container}" = ? AND deletedAt IS NULL AND status = 'open' AND COALESCE(kind, '') != 'heading' ORDER BY position LIMIT ?`,
      id, limit,
    ).toArray();
    return raws.map((r) => decodeRow(ENTITIES.task, r as Record<string, unknown>) as Row);
  }

  /// A note's revisions, newest first. Paged by rev: pass the smallest rev
  /// seen as `before`. Bodies only when asked for (they can be long).
  noteRevisions(container: NoteContainer, id: string, before: number | null, limit: number, includeBody: boolean): NoteRevision[] {
    const rows = this.sql.exec<{ rev: number; body: string | null; actor: string; at: string; reason: string | null }>(
      `SELECT rev, body, actor, at, reason FROM note_revisions WHERE container = ? AND id = ?${before !== null ? " AND rev < ?" : ""} ORDER BY rev DESC LIMIT ?`,
      ...(before !== null ? [container, id, before, limit] : [container, id, limit]),
    ).toArray();
    return rows.map((r) => ({
      rev: r.rev, actor: r.actor, at: r.at, reason: r.reason, ...(includeBody ? { body: r.body } : {}),
    }));
  }

  readSetting(key: string): Json {
    const raw = this.sql.exec("SELECT * FROM settings WHERE id = ? AND deletedAt IS NULL", key).toArray()[0];
    if (!raw) return null;
    return (decodeRow(ENTITIES.setting, raw).value ?? null) as Json;
  }

  // ---- pairing rate limit (src/shadow/oauth.ts) ----
  //
  // Wrong pairing codes this user entered in the current window. Kept in the
  // user's own object so the count is exact and needs no KV.

  pairFailures(): number {
    if (Date.now() - this.meta("pairFailWindow") > PAIR_FAIL_WINDOW_MS) return 0;
    return this.meta("pairFailCount");
  }

  notePairFailure(): number {
    const now = Date.now();
    const fresh = now - this.meta("pairFailWindow") > PAIR_FAIL_WINDOW_MS;
    const count = fresh ? 1 : this.meta("pairFailCount") + 1;
    if (fresh) this.setMeta("pairFailWindow", now);
    this.setMeta("pairFailCount", count);
    return count;
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

  /// Bytes stored in R2 for live attachments (the plan's attachment quota).
  attachmentBytes(): number {
    return this.sql.exec<{ n: number | null }>(
      "SELECT SUM(byteCount) AS n FROM attachments WHERE deletedAt IS NULL AND uploadedAt IS NOT NULL",
    ).one().n ?? 0;
  }

  downloadInfo(id: string): { contentType: string; filename: string } | null {
    const row = this.sql.exec<{ contentType: string; filename: string }>(
      "SELECT contentType, filename FROM attachments WHERE id = ? AND deletedAt IS NULL AND uploadedAt IS NOT NULL", id,
    ).toArray()[0];
    return row ?? null;
  }

  // ---- sessions (refresh tokens, stored hashed) ----

  createSession(hash: string, expiresAt: number, sid: string): void {
    this.sql.exec("INSERT INTO sessions (hash, createdAt, expiresAt, sid) VALUES (?, ?, ?, ?)", hash, Date.now(), expiresAt, sid);
  }

  /// Single-use rotation: the old refresh token dies whether or not the new
  /// one is ever used. Returns the session id the new token carries (kept
  /// across rotations; a session from before session ids gets one now), or
  /// null when the old token is unknown or expired.
  rotateSession(oldHash: string, newHash: string, expiresAt: number): string | null {
    return this.ctx.storage.transactionSync(() => {
      const row = this.sql.exec<{ expiresAt: number; sid: string | null }>("SELECT expiresAt, sid FROM sessions WHERE hash = ?", oldHash).toArray()[0];
      this.sql.exec("DELETE FROM sessions WHERE hash = ?", oldHash);
      if (!row || row.expiresAt < Date.now()) return null;
      const sid = row.sid ?? crypto.randomUUID();
      this.sql.exec("INSERT INTO sessions (hash, createdAt, expiresAt, sid) VALUES (?, ?, ?, ?)", newHash, Date.now(), expiresAt, sid);
      return sid;
    });
  }

  revokeSession(hash: string): void {
    this.sql.exec("DELETE FROM sessions WHERE hash = ?", hash);
  }

  // ---- Devices & Access (Settings ▸ Account ▸ Devices & Access) ----

  /// Signs one device out: drops every refresh token of session `sid` and
  /// its device row. Returns the refresh hashes so the caller can drop their
  /// KV index. Its access token lives out its hour (it is stateless).
  revokeDevice(sid: string): string[] {
    return this.ctx.storage.transactionSync(() => {
      const hashes = this.sql.exec<{ hash: string }>("SELECT hash FROM sessions WHERE sid = ?", sid).toArray().map((r) => r.hash);
      this.sql.exec("DELETE FROM sessions WHERE sid = ?", sid);
      this.sql.exec("DELETE FROM devices WHERE sid = ?", sid);
      return hashes;
    });
  }

  /// Notes an MCP token family (a connected app such as Claude). Called on
  /// every issue and refresh rotation, so `lastUsed` moves about hourly.
  /// `label` is the name the user gave the agent at pairing; a refresh passes
  /// none and keeps the stored one.
  recordConnection(familyId: string, clientId: string, clientName: string, scope: string, now = Date.now(), label: string | null = null): void {
    this.sql.exec(
      "INSERT INTO connections (familyId, clientId, clientName, scope, createdAt, lastUsed, label) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(familyId) DO UPDATE SET lastUsed = excluded.lastUsed, scope = excluded.scope, clientName = excluded.clientName, label = COALESCE(excluded.label, connections.label)",
      familyId, clientId, clientName, scope, now, now, label,
    );
  }

  /// True when the row existed.
  forgetConnection(familyId: string): boolean {
    const had = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM connections WHERE familyId = ?", familyId).one().n > 0;
    this.sql.exec("DELETE FROM connections WHERE familyId = ?", familyId);
    return had;
  }

  /// Renames an agent. Null or blank goes back to the client's registered
  /// name. False when the row is not in this store.
  renameConnection(familyId: string, label: string | null): boolean {
    const clean = label?.trim() || null;
    const had = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM connections WHERE familyId = ?", familyId).one().n > 0;
    if (had) this.sql.exec("UPDATE connections SET label = ? WHERE familyId = ?", clean, familyId);
    return had;
  }

  /// The agent's display name: the user's name for it, else the client's.
  connectionName(familyId: string): string | null {
    const row = this.sql.exec<{ name: string | null }>(
      "SELECT COALESCE(label, clientName) AS name FROM connections WHERE familyId = ?", familyId,
    ).toArray()[0];
    return row?.name ?? null;
  }

  /// The other token families of one registered client. A client that pairs
  /// again is the same agent, so the new family replaces these.
  otherFamiliesOfClient(clientId: string, keepFamilyId: string): string[] {
    return this.sql.exec<{ familyId: string }>(
      "SELECT familyId FROM connections WHERE clientId = ? AND familyId != ?", clientId, keepFamilyId,
    ).toArray().map((r) => r.familyId);
  }

  /// The agent count: connections used within their refresh lifetime.
  connectedAgentCount(now = Date.now()): number {
    return this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM connections WHERE lastUsed > ?", now - CONNECTION_TTL_MS).one().n;
  }

  /// Every place this account is signed in: app sessions (devices) and MCP
  /// connections (agents). A connection unused for its refresh lifetime has
  /// expired and is left out.
  accessSummary(currentSid: string | null, cap: number | null, now = Date.now(), agentLimit: number | null = null): AccessSummary {
    const devices = this.deviceSummary(cap);
    const firstSeen = new Map(this.sql.exec<{ sid: string; firstSeen: number }>("SELECT sid, firstSeen FROM devices").toArray().map((r) => [r.sid, r.firstSeen]));
    const connections = this.sql.exec<{ familyId: string; name: string; clientName: string; scope: string; createdAt: number; lastUsed: number }>(
      "SELECT familyId, COALESCE(label, clientName) AS name, clientName, scope, createdAt, lastUsed FROM connections WHERE lastUsed > ? ORDER BY lastUsed DESC", now - CONNECTION_TTL_MS,
    ).toArray();
    return {
      devices: devices.map((d) => ({
        sid: d.sid, client: d.client, firstSeen: firstSeen.get(d.sid) ?? d.lastSeen, lastSeen: d.lastSeen,
        current: d.sid === currentSid, syncing: d.syncing,
      })),
      connections: connections.map((r) => ({ id: r.familyId, name: r.name, clientName: r.clientName, scope: r.scope, createdAt: r.createdAt, lastUsed: r.lastUsed })),
      agents: { count: connections.length, limit: agentLimit },
    };
  }

  // ---- device slot (docs/SYNC_SUBSCRIPTION_SPEC.md §3, ADR 0023) ----
  // A device is a session (`sid`). The slot holders are the `cap` live
  // sessions with the newest `slotAt`. A device that is allowed to sync
  // refreshes its `slotAt`, so with no cap (Plus) the order is "most recently
  // used": a lapsed account keeps the device it used last.

  /// Records one sync call from `sid` and says whether it holds a slot.
  /// A device takes a free slot by itself; it never pushes out a holder
  /// (that is `claimDeviceSlot`).
  deviceAccess(sid: string, client: string | null, cap: number | null): { syncing: boolean } {
    return this.ctx.storage.transactionSync(() => {
      const now = Date.now();
      this.touchDevice(sid, client, now);
      const holders = cap === null ? null : this.slotHolders(cap);
      const syncing = holders === null || holders.includes(sid) || holders.length < cap!;
      if (syncing) this.sql.exec("UPDATE devices SET slotAt = ? WHERE sid = ?", this.nextSlotAt(now), sid);
      return { syncing };
    });
  }

  /// Moves a slot to `sid` ("sync this device instead"). With a cap of N the
  /// holder used least recently stops syncing; its local data stays.
  claimDeviceSlot(sid: string, client: string | null): void {
    const now = Date.now();
    this.ctx.storage.transactionSync(() => {
      this.touchDevice(sid, client, now);
      this.sql.exec("UPDATE devices SET slotAt = ? WHERE sid = ?", this.nextSlotAt(now), sid);
    });
  }

  /// The devices that synced, newest first, and which of them hold a slot.
  deviceSummary(cap: number | null): { client: string | null; sid: string; lastSeen: number; syncing: boolean }[] {
    const holders = cap === null ? null : new Set(this.slotHolders(cap));
    return this.sql.exec<{ sid: string; client: string | null; lastSeen: number }>(
      "SELECT d.sid, d.client, d.lastSeen FROM devices d WHERE EXISTS (SELECT 1 FROM sessions s WHERE s.sid = d.sid) ORDER BY d.lastSeen DESC",
    ).toArray().map((r) => ({ ...r, syncing: holders === null || holders.has(r.sid) }));
  }

  private touchDevice(sid: string, client: string | null, now: number): void {
    this.sql.exec(
      "INSERT INTO devices (sid, client, firstSeen, lastSeen) VALUES (?, ?, ?, ?) ON CONFLICT(sid) DO UPDATE SET lastSeen = excluded.lastSeen, client = COALESCE(excluded.client, devices.client)",
      sid, client, now, now,
    );
  }

  /// Strictly increasing, so two calls in the same millisecond still order.
  private nextSlotAt(now: number): number {
    const top = this.sql.exec<{ m: number | null }>("SELECT MAX(slotAt) AS m FROM devices").one().m;
    return top === null ? now : Math.max(now, top + 1);
  }

  private slotHolders(cap: number): string[] {
    if (cap <= 0) return [];
    return this.sql.exec<{ sid: string }>(
      "SELECT d.sid FROM devices d WHERE d.slotAt IS NOT NULL AND EXISTS (SELECT 1 FROM sessions s WHERE s.sid = d.sid) ORDER BY d.slotAt DESC LIMIT ?",
      cap,
    ).toArray().map((r) => r.sid);
  }

  // ---- usage counters (connector writes per day, agent runs per month) ----

  addUsage(key: string, n = 1): number {
    const now = Date.now();
    this.sql.exec(
      "INSERT INTO usage (key, count, updatedAt) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET count = usage.count + excluded.count, updatedAt = excluded.updatedAt",
      key, n, now,
    );
    return this.usageCounts([key])[key];
  }

  usageCounts(keys: string[]): Record<string, number> {
    const out: Record<string, number> = {};
    for (const k of keys) {
      out[k] = this.sql.exec<{ count: number }>("SELECT count FROM usage WHERE key = ?", k).toArray()[0]?.count ?? 0;
    }
    return out;
  }

  /// What a plan check needs, in one call: the entitlement rows and the
  /// asked-for usage counters.
  planSnapshot(usageKeys: string[]): { entitlements: EntitlementRow[]; usage: Record<string, number> } {
    return { entitlements: this.entitlements(), usage: this.usageCounts(usageKeys) };
  }

  // ---- sync entitlement (docs/SYNC_SUBSCRIPTION_SPEC.md §6) ----

  entitlements(): EntitlementRow[] {
    return this.sql.exec<Record<string, SqlStorageValue>>("SELECT * FROM entitlements ORDER BY id").toArray()
      .map((r) => ({ ...r }) as unknown as EntitlementRow);
  }

  /// Writes one row unless a newer Apple payload already wrote it. `origin`
  /// "app" (a transaction the app posted) never moves a grace or billing-retry
  /// row to expired: the transaction alone cannot see grace or retry, only
  /// Apple's notifications can. Returns whether the row was written.
  putEntitlement(row: Omit<EntitlementRow, "updatedAt">, origin: "app" | "webhook" | "admin"): boolean {
    return this.ctx.storage.transactionSync(() => {
      const cur = this.sql.exec<{ status: string; signedAt: number }>(
        "SELECT status, signedAt FROM entitlements WHERE id = ?", row.id,
      ).toArray()[0];
      if (cur && origin !== "admin") {
        if (cur.signedAt > row.signedAt) return false;
        if (origin === "app" && row.status === "expired" && (cur.status === "grace" || cur.status === "billing_retry")) {
          return false;
        }
      }
      this.sql.exec(
        `INSERT INTO entitlements (id, source, productId, expiresAt, originalTransactionId, status, environment, note, signedAt, updatedAt)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET source = excluded.source, productId = excluded.productId,
           expiresAt = excluded.expiresAt, originalTransactionId = excluded.originalTransactionId,
           status = excluded.status, environment = excluded.environment, note = excluded.note,
           signedAt = excluded.signedAt, updatedAt = excluded.updatedAt`,
        row.id, row.source, row.productId, row.expiresAt, row.originalTransactionId, row.status,
        row.environment, row.note, row.signedAt, Date.now(),
      );
      return true;
    });
  }

  /// Starts the reverse trial if this account never had one (spec §3).
  /// Idempotent: the row stays after it expires, so a second sign-in never
  /// starts a second trial. Returns whether a trial started.
  startTrialOnce(row: Omit<EntitlementRow, "updatedAt">): boolean {
    return this.sql.exec(
      `INSERT OR IGNORE INTO entitlements (id, source, productId, expiresAt, originalTransactionId, status, environment, note, signedAt, updatedAt)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      row.id, row.source, row.productId, row.expiresAt, row.originalTransactionId, row.status,
      row.environment, row.note, row.signedAt, Date.now(),
    ).rowsWritten > 0;
  }

  deleteEntitlement(id: string): boolean {
    return this.sql.exec("DELETE FROM entitlements WHERE id = ?", id).rowsWritten > 0;
  }

  // ---- private read-only iCal feed (docs/TASK_TIMES_AND_ICAL_SPEC.md §3, #166) ----

  getIcalFeed(): { token: string; tokenHash: string; scope: "all" | "timed"; createdAt: string; updatedAt: string } | null {
    const row = this.sql.exec<{
      token: string; tokenHash: string; scope: string; createdAt: string; updatedAt: string;
    }>("SELECT token, tokenHash, scope, createdAt, updatedAt FROM ical_feed WHERE id = 1").toArray()[0];
    if (!row) return null;
    return {
      token: row.token,
      tokenHash: row.tokenHash,
      scope: row.scope === "timed" ? "timed" : "all",
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    };
  }

  setIcalFeed(
    token: string,
    tokenHash: string,
    scope: "all" | "timed",
  ): {
    prevTokenHash: string | null;
    feed: { token: string; tokenHash: string; scope: "all" | "timed"; createdAt: string; updatedAt: string };
  } {
    const now = new Date().toISOString();
    return this.ctx.storage.transactionSync(() => {
      const prev = this.sql.exec<{ tokenHash: string }>(
        "SELECT tokenHash FROM ical_feed WHERE id = 1",
      ).toArray()[0];
      this.sql.exec(
        `INSERT INTO ical_feed (id, token, tokenHash, scope, createdAt, updatedAt)
         VALUES (1, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET token = excluded.token, tokenHash = excluded.tokenHash,
           scope = excluded.scope, createdAt = excluded.createdAt, updatedAt = excluded.updatedAt`,
        token, tokenHash, scope, now, now,
      );
      return {
        prevTokenHash: prev?.tokenHash ?? null,
        feed: { token, tokenHash, scope, createdAt: now, updatedAt: now },
      };
    });
  }

  setIcalScope(
    scope: "all" | "timed",
  ): { token: string; tokenHash: string; scope: "all" | "timed"; createdAt: string; updatedAt: string } | null {
    const now = new Date().toISOString();
    return this.ctx.storage.transactionSync(() => {
      const cur = this.getIcalFeed();
      if (!cur) return null;
      this.sql.exec("UPDATE ical_feed SET scope = ?, updatedAt = ? WHERE id = 1", scope, now);
      return { ...cur, scope, updatedAt: now };
    });
  }

  deleteIcalFeed(): { prevTokenHash: string | null } {
    return this.ctx.storage.transactionSync(() => {
      const prev = this.sql.exec<{ tokenHash: string }>(
        "SELECT tokenHash FROM ical_feed WHERE id = 1",
      ).toArray()[0];
      this.sql.exec("DELETE FROM ical_feed WHERE id = 1");
      return { prevTokenHash: prev?.tokenHash ?? null };
    });
  }

  readIcalSnapshot(tokenHash: string): {
    rev: number;
    scope: "all" | "timed";
    homeTimezone: string | null;
    tasks: IcalTask[];
  } | null {
    const row = this.sql.exec<{ tokenHash: string; scope: string }>(
      "SELECT tokenHash, scope FROM ical_feed WHERE id = 1",
    ).toArray()[0];
    if (!row || row.tokenHash !== tokenHash) return null;
    const tzRaw = this.readSetting("homeTimezone");
    const homeTimezone = typeof tzRaw === "string" && tzRaw.trim() ? tzRaw.trim() : null;
    const tasks = this.sql.exec<{
      id: string;
      title: string | null;
      notes: string | null;
      status: string | null;
      kind: string | null;
      scheduled: string | null;
      startTime: string | null;
      durationMinutes: number | null;
      timeZone: string | null;
      deadline: string | null;
      rev: number | null;
    }>(
      `SELECT id, title, notes, status, kind, scheduled, startTime, durationMinutes, timeZone, deadline, rev
       FROM tasks
       WHERE deletedAt IS NULL AND status = 'open' AND (kind IS NULL OR kind != 'heading')
         AND (scheduled IS NOT NULL OR deadline IS NOT NULL)
       ORDER BY scheduled IS NULL, scheduled, startTime IS NULL, startTime, deadline IS NULL, deadline, id`,
    ).toArray().map((r): IcalTask => ({
      id: r.id,
      title: r.title,
      notes: r.notes,
      status: r.status,
      kind: r.kind,
      scheduled: r.scheduled,
      startTime: r.startTime,
      durationMinutes: r.durationMinutes,
      timeZone: r.timeZone,
      deadline: r.deadline,
      rev: r.rev,
    }));
    return {
      rev: this.meta("rev"),
      scope: row.scope === "timed" ? "timed" : "all",
      homeTimezone,
      tasks,
    };
  }

  // ---- account move: copy (docs/CLOUDFLARE_ACCOUNT_MOVE.md, ADR 0018) ----
  // Cloudflare cannot move Durable Object data between accounts. These
  // methods copy every table row for row, so rev, ids and the change log keep
  // their values and client cursors stay valid. Admin routes only.

  /// The store's own tables. Names come from sqlite_master, never from input.
  private copyTables(): string[] {
    return this.sql.exec<{ name: string }>(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' ORDER BY name",
    ).toArray().map((r) => r.name);
  }

  /// Row count per table. The move compares this before and after the copy.
  copySnapshot(): Record<string, number> {
    const out: Record<string, number> = {};
    for (const t of this.copyTables()) {
      out[t] = this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM "${t}"`).one().n;
    }
    return out;
  }

  /// One page of rows in rowid order. `after` is the last rowid of the
  /// previous page (0 for the first). Fails on a BLOB value: no table stores
  /// one, and silently dropping bytes would corrupt the copy.
  copyExport(table: string, after: number, limit: number): { rows: Record<string, unknown>[]; next: number | null } {
    if (!this.copyTables().includes(table)) throw new Error(`unknown table ${table}`);
    const n = Math.max(1, Math.min(limit, 1000));
    const raw = this.sql.exec<Record<string, SqlStorageValue>>(
      `SELECT rowid AS _rowid, * FROM "${table}" WHERE rowid > ? ORDER BY rowid LIMIT ?`, after, n,
    ).toArray();
    let last = after;
    const rows = raw.map((r) => {
      const { _rowid, ...row } = r;
      last = Number(_rowid);
      for (const [k, v] of Object.entries(row)) {
        if (v !== null && typeof v === "object") throw new Error(`binary value in ${table}.${k}`);
      }
      return row;
    });
    return { rows, next: raw.length === n ? last : null };
  }

  /// Starts an import. Refuses a store that already holds data, so an import
  /// can never overwrite a live account.
  copyImportBegin(): { ok: true } | { ok: false; reason: "not_empty" } {
    for (const t of this.copyTables()) {
      if (t === "meta") continue;
      if (this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM "${t}"`).one().n > 0) return { ok: false, reason: "not_empty" };
    }
    if (this.meta("rev") !== 0) return { ok: false, reason: "not_empty" };
    this.setMeta("copyImporting", 1);
    return { ok: true };
  }

  /// Writes one page of rows. Column names must exist in the table.
  copyImport(table: string, rows: Record<string, unknown>[]): number {
    if (this.meta("copyImporting") !== 1) throw new Error("import not started");
    if (!this.copyTables().includes(table)) throw new Error(`unknown table ${table}`);
    const cols = new Set(
      this.sql.exec<{ name: string }>(`PRAGMA table_info("${table}")`).toArray().map((r) => r.name),
    );
    this.ctx.storage.transactionSync(() => {
      for (const row of rows) {
        const keys = Object.keys(row);
        if (keys.length === 0) throw new Error("empty row");
        for (const k of keys) if (!cols.has(k)) throw new Error(`unknown column ${table}.${k}`);
        const values = keys.map((k) => {
          const v = row[k];
          if (v === null || typeof v === "string" || typeof v === "number") return v;
          throw new Error(`unsupported value in ${table}.${k}`);
        });
        this.sql.exec(
          `INSERT OR REPLACE INTO "${table}" (${keys.map((k) => `"${k}"`).join(", ")}) VALUES (${keys.map(() => "?").join(", ")})`,
          ...values,
        );
      }
    });
    return rows.length;
  }

  /// Ends the import. The copied meta table brings the rev counter with it.
  copyImportEnd(): Record<string, number> {
    this.sql.exec("DELETE FROM meta WHERE key = 'copyImporting'");
    return this.copySnapshot();
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
      this.sql.exec("DELETE FROM task_ref_removals WHERE taskId NOT IN (SELECT id FROM tasks)");
      // Notes history lives as long as its container, then goes with it.
      for (const c of Object.keys(NOTE_FIELD) as NoteContainer[]) {
        this.sql.exec(`DELETE FROM note_revisions WHERE container = ? AND id NOT IN (SELECT id FROM ${ENTITIES[c].table})`, c);
      }
      this.setMeta("purgedThrough", purged);
      this.sql.exec("DELETE FROM client_ops WHERE at < ?", now - CLIENT_OP_TTL_MS);
      this.sql.exec("DELETE FROM changes WHERE at < ?", new Date(now - CHANGE_LOG_TTL_MS).toISOString());
      this.sql.exec("DELETE FROM sessions WHERE expiresAt < ?", now);
      this.sql.exec("DELETE FROM devices WHERE sid NOT IN (SELECT sid FROM sessions WHERE sid IS NOT NULL)");
      this.sql.exec("DELETE FROM connections WHERE lastUsed < ?", now - CONNECTION_TTL_MS);
      // Day and month counters: two months covers the current month.
      this.sql.exec("DELETE FROM usage WHERE updatedAt < ?", now - 62 * DAY_MS);
    });
    await this.ctx.storage.setAlarm(now + DAY_MS);
  }
}
