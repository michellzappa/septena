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
import { CoreInputError, doEndWins, findIssueRefs, parseRef, resolveDoSessions, taskRefId, type CoreDoSession, type CoreRef } from "../core/index.js";
import type { Op, OpResult, PullResult, PushResult, Turn } from "./ops.js";
import type { EntitlementRow } from "../entitlement/entitlement.js";
import type { IcalTask } from "../ical.js";
import { DOMAIN_RULES, ENTITY_LIMITS, TURN_FIELDS } from "../generated/registries.js";
import { MCP_REFRESH_TTL_S } from "../shadow/tokens.js";
import { logEvent, randomId } from "../util.js";
import {
  sendAgentQuestionPushes,
  type AgentQuestionPush,
  type PushPlatform,
  type PushTokenRow,
} from "../api/apns.js";
import {
  MAX_AGENT_WEBHOOKS,
  SSE_HEARTBEAT_MS,
  deliverWebhookEvent,
  formatSseEvent,
  formatSseKeepalive,
  formatSseReady,
  isWakeEventKind,
  type AgentWebhookTarget,
} from "../api/agentWake.js";
import { projectStoreFor } from "./ProjectStore.js";
import {
  SEED_FIELDS,
  SHARED_FIELDS,
  SHARED_PROJECT_ROW,
  ShareBook,
  newSharedRowId,
  sharedColumn,
  type ShareDelivery,
  type ShareFields,
  type ShareInfo,
  type ShareRow,
  type ShareValue,
  type SharedEntity,
} from "./shares.js";
import { SESSION_HEADER, SessionBook, type RenewResult, type SessionGrant } from "./sessions.js";

/// Task fields only the app writes (docs/TASK_FADE_SPEC.md §3): the fade
/// clock and its outcome. An agent cannot keep a task alive by touching it.
const APP_ONLY_TASK_FIELDS = ["touchedAt", "deferCount", "fadedAt", "dropReason", "effort"] as const;

/// Per changed field: [before, after]. `null` means absent / cleared.
export type ChangeDiff = Record<string, [unknown, unknown]>;

/// What the admin page knows about one account (ADR 0043): counts, dates and
/// plan rows, never content.
export interface AccountSummary {
  firstSeen: number | null;
  lastChangeAt: number | null;
  signedIn: boolean;
  openTasks: number;
  closedTasks: number;
  projects: number;
  areas: number;
  sharedProjects: number;
  files: number;
  fileBytes: number;
  devices: { client: string | null; version: string | null; firstSeen: number; lastSeen: number }[];
  agents: { client: string; since: number; lastUsed: number }[];
  agentChangesWeek: number;
  webhooks: number;
  failingWebhooks: number;
  entitlements: Pick<EntitlementRow, "id" | "source" | "productId" | "expiresAt" | "status" | "environment" | "signedAt">[];
}

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
  | "your_turn" | "held" | "budget" | "doing";

export type ClaimResult =
  | { ok: true; holder: string; claimUntil: string; renewed: boolean; runsSinceUser: number }
  | { ok: false; reason: ClaimRefusal; holder?: string; claimUntil?: string };

/// What the user does now (docs/DO_SPEC.md §7). A stale Do is still here.
export interface Doing {
  sessionId: string;
  taskId: string;
  title: string;
  startedAt: string;
  plannedMinutes: number | null;
  confirmedAt: string | null;
  staleAt: string;
  isStale: boolean;
}

/// One thing an agent may need to react to. A pointer, never content: the
/// agent reads the task itself, so text in a task can never arrive as an
/// order through this feed.
export interface AgentEvent {
  rev: number;
  kind: "assigned" | "user_turn" | "stopped" | "resumed" | "paused" | "unpaused" | "do_started" | "do_ended";
  taskId: string | null;
  at: string;
}

/// Public view of a per-user outbound agent wake webhook (never exposes `secret`).
export interface AgentWebhookPublic {
  id: string;
  url: string;
  enabled: boolean;
  createdAt: string;
  lastDeliveredAt: string | null;
  lastStatus: number | null;
  failureCount: number;
}

/// Returned once on creation so the caller can store the signing secret.
export interface AgentWebhookCreated extends AgentWebhookPublic {
  secret: string;
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
  human_only_do: "Only the user starts, changes or ends a Do.",
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
/// A device slot holder that has not synced this long loses the slot to the
/// next device that syncs, with no prompt (spec §6.4 finding 1).
export const DEVICE_SLOT_INACTIVE_MS = 14 * DAY_MS;
/// Minimum interval between manual device slot moves (`POST /v1/entitlement/device`)
/// on a capped plan (spec §6.4 finding 2).
export const DEVICE_SLOT_MOVE_COOLDOWN_MS = DAY_MS;
const TOMBSTONE_TTL_MS = DOMAIN_RULES.tombstoneTtlDays * DAY_MS;
const CLIENT_OP_TTL_MS = DOMAIN_RULES.clientOpTtlDays * DAY_MS;
/// A connection unused this long has an expired refresh token (src/shadow/tokens.ts).
const CONNECTION_TTL_MS = MCP_REFRESH_TTL_S * 1000;
/// How long the store remembers an item whose proposal the user turned down (#497).
const DISMISSED_REF_TTL_MS = 365 * DAY_MS;
const CHANGE_LOG_TTL_MS = DOMAIN_RULES.changeLogTtlDays * DAY_MS;
/// The most tasks a project may hold when it becomes shared.
const MAX_SHARE_TASKS = 5_000;
const SHARE_RETRY_MS = 30_000;
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

/// What a new task was made from (docs/TASK_REFERENCES_SPEC.md §6.2).
/// `fromKeys` are the keys of its `from` references, in normal form.
export interface Capture {
  taskId: string;
  fromKeys: string[];
  allowDuplicate: boolean;
  /// An agent's own suggestion, not a user's request or a person's capture.
  suggestion: boolean;
}

/// The task a capture met: the newest one made from one of its keys.
export interface CaptureHit {
  id: string;
  title: string;
  status: string;
  area: string | null;
  project: string | null;
  /// Open and not faded. Everything else is closed.
  active: boolean;
  keys: string[];
}

export type CaptureOutcome =
  | { existing: CaptureHit }
  | { existing: null; dismissed: string[] }
  | { existing: null; dismissed: null; results: OpResult[]; followUp: { id: string; title: string } | null };

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

const sessionTag = (sid: string) => `sid:${sid}`;

export class TaskStore extends DurableObject<Env> {
  private sql: SqlStorage;
  private sessions: SessionBook;
  private shares: ShareBook;
  private drainingShares = false;
  /// Shared projects this push asks to delete (`shareRefusal`).
  private doomedShares = new Set<string>();
  private sseSubscribers = new Set<{
    send: (chunk: string) => boolean;
    close: () => void;
    lastRev: number;
    sid: string | null;
  }>();
  private sseHeartbeatMs = SSE_HEARTBEAT_MS;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sessions = new SessionBook(this.sql);
    this.shares = new ShareBook(this.sql);
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
      CREATE TABLE IF NOT EXISTS dismissed_refs (key TEXT PRIMARY KEY, at TEXT NOT NULL);
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
      CREATE TABLE IF NOT EXISTS push_tokens (
        token TEXT PRIMARY KEY,
        deviceId TEXT,
        platform TEXT NOT NULL,
        sandbox INTEGER NOT NULL DEFAULT 0,
        updatedAt TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS push_tokens_device ON push_tokens(deviceId);
      CREATE TABLE IF NOT EXISTS agent_webhooks (
        id TEXT PRIMARY KEY,
        url TEXT NOT NULL,
        secret TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        createdAt TEXT NOT NULL,
        lastDeliveredAt TEXT,
        lastStatus INTEGER,
        failureCount INTEGER NOT NULL DEFAULT 0
      );
    `);
    this.sessions.migrate();
    this.shares.migrate();
    // The name the user gave an agent (pairing or Settings rename). Null =
    // the client's registered name.
    const connectionCols = this.sql.exec<{ name: string }>("PRAGMA table_info(connections)").toArray().map((r) => r.name);
    // The app version a device last sent (`X-Septena-Version`).
    const deviceCols = this.sql.exec<{ name: string }>("PRAGMA table_info(devices)").toArray().map((r) => r.name);
    if (!deviceCols.includes("version")) this.sql.exec("ALTER TABLE devices ADD COLUMN version TEXT");
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
    const agentQuestions: AgentQuestionPush[] = [];
    const prevRev = this.meta("rev");
    this.reason = reason;
    const sharing = this.shares.any();
    this.doomedShares = new Set(sharing
      ? ops.flatMap((op) => (op.op === "delete" && op.entity === "project" && this.shares.forProject(op.id) ? [op.id] : []))
      : []);
    let results: OpResult[];
    try {
      results = this.ctx.storage.transactionSync(() => ops.map((op) => {
        const seen = this.sql.exec<{ result: string }>("SELECT result FROM client_ops WHERE clientOpId = ?", op.clientOpId).toArray()[0];
        if (seen) return JSON.parse(seen.result) as OpResult;
        const result = this.apply(op, actor, purgedAttachmentIds, agentQuestions);
        this.sql.exec("INSERT INTO client_ops (clientOpId, result, at) VALUES (?, ?, ?)", op.clientOpId, JSON.stringify(result), Date.now());
        return result;
      }));
    } finally {
      this.reason = null;
      this.doomedShares.clear();
    }
    if (sharing) this.kickShares();
    const appliedThrough = this.meta("rev");
    if (results.some((r) => r.status === "applied")) {
      this.broadcast(appliedThrough);
      if (appliedThrough > prevRev && !isAgentActor(actor)) {
        const { events } = this.agentEvents(prevRev, 500);
        if (events.length > 0) this.dispatchAgentEvents(events);
      }
    }
    // During a Do the question is in the lists and counts. Its push is not sent
    // (docs/DO_SPEC.md §6).
    const doing = agentQuestions.length > 0 ? this.readDoing() : null;
    if (agentQuestions.length > 0 && (!doing || doing.isStale)) {
      const tokens = this.listPushTokens();
      if (tokens.length > 0) {
        const delivery = this.dispatchAgentQuestionPushes(agentQuestions, tokens);
        if (typeof this.ctx.waitUntil === "function") {
          this.ctx.waitUntil(delivery);
        } else {
          void delivery;
        }
      }
    }
    return { result: { appliedThrough, results }, purgedAttachmentIds };
  }

  private apply(
    op: Op,
    actor: string,
    purgedAttachmentIds: string[],
    agentQuestions: AgentQuestionPush[],
  ): OpResult {
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
    if (op.op === "appendTurn") return this.appendTurn(op.clientOpId, op.taskId, op.turn, actor, now, agentQuestions);

    const spec: EntitySpec = ENTITIES[op.entity];
    const row = this.sql.exec(`SELECT * FROM ${spec.table} WHERE id = ?`, op.id).toArray()[0];

    const sharing = this.shares.any();
    const shareRefusal = sharing ? this.shareRefusal(op, row as Record<string, unknown> | undefined) : null;
    if (shareRefusal) {
      // A new rev sends the row again, so the client that wrote it gets the
      // real state back.
      this.sql.exec(`UPDATE ${spec.table} SET rev = ? WHERE id = ?`, this.nextRev(), op.id);
      return { clientOpId: op.clientOpId, status: "rejected", reason: shareRefusal };
    }

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
        if (this.isTurnDown(row, actor)) this.rememberTurnDown(op.id, now);
        this.tombstoneConvo(op.id, now);
        purgedAttachmentIds.push(...this.tombstoneAttachments(op.id, now));
        this.tombstoneChecklistItems(op.id, now);
        this.tombstoneTaskRefs(op.id, now);
        this.tombstoneDoSessions(op.id, now);
      }
      if (op.entity === "taskRef" && !isAgentActor(actor)) {
        // A user's own removal wins over every automatic add (§6.6).
        this.sql.exec("INSERT OR REPLACE INTO task_ref_removals (taskId, key, at) VALUES (?, ?, ?)", gone.taskId, gone.key, now);
      }
      if (sharing) this.shareOut(op.entity, op.id, null);
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
    if (op.entity === "doSession") {
      const settled = this.settleDoFields(op.fields, row as Record<string, unknown> | undefined, now);
      names.splice(0, names.length, ...settled);
    }

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
      if (op.entity === "doSession") {
        const task = this.sql.exec<{ kind: string | null }>(
          "SELECT kind FROM tasks WHERE id = ? AND deletedAt IS NULL", op.fields.taskId as string,
        ).toArray()[0];
        if (!task || task.kind === "heading") return { clientOpId: op.clientOpId, status: "rejected", reason: "unknown_task" };
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
          this.sql.exec("DELETE FROM dismissed_refs WHERE key = ?", ref.key);
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
    if (op.entity === "task" && row && "status" in op.fields && op.fields.status !== row.status && !isAgentActor(actor)) {
      if (op.fields.status === "cancelled" && this.isTurnDown(row, actor)) this.rememberTurnDown(op.id, now);
      if (op.fields.status === "open") this.forgetTurnDown(op.id);
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
    if (op.entity === "doSession" || (op.entity === "task" && ("status" in op.fields || "fadedAt" in op.fields))) {
      this.resolveDo(actor, now, op.entity === "doSession" && !row ? op.id : null);
    }
    if (isAgentActor(actor) && op.entity === "convo" && op.fields.endState === "needs_verify") {
      // Handing off to Review puts the ball in the human's court, so the claim ends.
      this.writeConvoServerFields(op.id, { claimedBy: null, claimUntil: null }, "release", actor, now, true);
    }
    if (sharing) this.shareOut(op.entity, op.id, names);
    return { clientOpId: op.clientOpId, status: "applied", rev };
  }

  // ---- shared projects (docs/PROJECT_SHARING_SPEC.md, store/shares.ts) ----

  /// What a write may not do to a shared project: delete it (the app stops
  /// sharing or leaves), or, as a member, move its tasks somewhere private.
  /// A client that does not know sharing deletes a project by deleting its
  /// tasks first, so those deletes fail with it.
  private shareRefusal(op: Extract<Op, { op: "upsert" | "delete" }>, row: Record<string, unknown> | undefined): string | null {
    if (op.entity === "project") return op.op === "delete" && this.doomedShares.has(op.id) ? "shared_project" : null;
    if (op.entity !== "task" || !row || row.deletedAt) return null;
    const from = row.project as string | null;
    const moves = op.op === "upsert" && "project" in op.fields && ((op.fields.project as string | null) ?? null) !== from;
    if (from && this.doomedShares.has(from) && (op.op === "delete" || moves)) return "shared_project";
    if (moves && this.shares.shared("task", op.id) && this.shares.forProject(from)?.role !== "owner") return "shared_move_out";
    return null;
  }

  private rowOf(entity: SharedEntity, id: string): Record<string, unknown> | null {
    const raw = this.sql.exec(`SELECT * FROM ${ENTITIES[entity].table} WHERE id = ?`, id).toArray()[0];
    return raw ? (decodeRow(ENTITIES[entity], raw as Record<string, unknown>)) : null;
  }

  /// A local row's shared values. A heading or a task becomes its shared id.
  private outFields(entity: SharedEntity, row: Record<string, unknown>, names: readonly string[]): ShareFields {
    const out: ShareFields = {};
    for (const name of names) {
      let v = (row[name] ?? null) as ShareValue;
      if (name === "heading" && typeof v === "string") v = this.shares.shared("task", v)?.sharedId ?? null;
      if (name === "taskId" && typeof v === "string") v = this.shares.shared("task", v)?.sharedId ?? v;
      out[name] = v;
    }
    return out;
  }

  /// Queues one applied local write for the ProjectStore. `names`: the
  /// changed fields, or null for a delete.
  private shareOut(entity: string, id: string, names: string[] | null): void {
    if (entity === "project") {
      const share = this.shares.forProject(id);
      const fields = (names ?? []).filter((n) => SHARED_FIELDS.project.includes(n));
      if (share && fields.length) {
        this.shares.enqueue(share.id, "project", SHARED_PROJECT_ROW, false, this.outFields("project", this.rowOf("project", id)!, fields));
      }
    } else if (entity === "task") {
      this.shareOutTask(id, names);
    } else if (entity === "checklistItem") {
      this.shareOutItem(id, names);
    }
  }

  private shareOutTask(id: string, names: string[] | null): void {
    const mapping = this.shares.shared("task", id);
    if (names === null) {
      if (mapping) this.shares.enqueue(mapping.shareId, "task", mapping.sharedId, true, {});
      return;
    }
    const row = this.rowOf("task", id)!;
    const share = this.shares.forProject(row.project as string | null);
    if (mapping && mapping.shareId !== share?.id) this.shareMovedOut(id, mapping);
    if (!share) return;
    if (mapping && mapping.shareId === share.id) {
      const fields = names.filter((n) => SHARED_FIELDS.task.includes(n));
      if (fields.length) this.shares.enqueue(share.id, "task", mapping.sharedId, false, this.outFields("task", row, fields));
      return;
    }
    this.shareTaskIn(share.id, id, row);
  }

  /// The owner moved a task out: it leaves the project for everyone.
  private shareMovedOut(taskId: string, mapping: { shareId: string; sharedId: string }): void {
    for (const { id } of this.sql.exec<{ id: string }>("SELECT id FROM checklist_items WHERE taskId = ?", taskId).toArray()) {
      const item = this.shares.shared("checklistItem", id);
      if (!item) continue;
      this.shares.enqueue(item.shareId, "checklistItem", item.sharedId, true, {});
      this.shares.retire(item.shareId, "checklistItem", item.sharedId);
    }
    this.shares.enqueue(mapping.shareId, "task", mapping.sharedId, true, {});
    this.shares.retire(mapping.shareId, "task", mapping.sharedId);
  }

  /// A task that is new in a shared project. An agent's proposal stays
  /// private until the user accepts it.
  private shareTaskIn(shareId: string, id: string, row: Record<string, unknown>): void {
    if (row.source === "mcp" && !row.acknowledgedAt) return;
    const repeats = !!row.recurrenceUnit;
    let sharedId = newSharedRowId();
    if (repeats && typeof row.recurrenceSeriesID === "string" && typeof row.scheduled === "string" && id.startsWith("recur-")) {
      // Two members who complete one repeat make the same next occurrence.
      const series = `s-r-${row.recurrenceSeriesID}-${row.scheduled}`;
      if (/^[A-Za-z0-9._:-]{1,128}$/.test(series)) sharedId = series;
      const other = this.shares.localId(shareId, "task", sharedId);
      if (other && other !== id) {
        this.tombstoneReplica("task", id, new Date().toISOString());
        return;
      }
    }
    this.shares.map(shareId, "task", sharedId, id);
    this.shares.enqueue(shareId, "task", sharedId, false,
      this.outFields("task", row, repeats ? [...SHARED_FIELDS.task, ...SEED_FIELDS] : SHARED_FIELDS.task));
    for (const item of this.sql.exec<{ id: string }>("SELECT id FROM checklist_items WHERE taskId = ? AND deletedAt IS NULL", id).toArray()) {
      this.shareOutItem(item.id, []);
    }
  }

  private shareOutItem(id: string, names: string[] | null): void {
    const mapping = this.shares.shared("checklistItem", id);
    if (names === null) {
      if (mapping) this.shares.enqueue(mapping.shareId, "checklistItem", mapping.sharedId, true, {});
      return;
    }
    const row = this.rowOf("checklistItem", id);
    if (!row || row.deletedAt) return;
    if (mapping) {
      const fields = names.filter((n) => SHARED_FIELDS.checklistItem.includes(n));
      if (fields.length) {
        this.shares.enqueue(mapping.shareId, "checklistItem", mapping.sharedId, false, this.outFields("checklistItem", row, fields));
      }
      return;
    }
    const task = this.shares.shared("task", row.taskId as string);
    if (!task) return;
    const sharedId = newSharedRowId();
    this.shares.map(task.shareId, "checklistItem", sharedId, id);
    this.shares.enqueue(task.shareId, "checklistItem", sharedId, false, this.outFields("checklistItem", row, SHARED_FIELDS.checklistItem));
  }

  /// Turns a private project into the owner's replica of a shared one. Every
  /// row goes out through the same queue as a later edit.
  startShare(userId: string, projectId: string, info: ShareInfo): "ok" | "not_found" | "already_shared" | "too_large" {
    const result = this.ctx.storage.transactionSync(() => {
      const project = this.rowOf("project", projectId);
      if (!project || project.deletedAt) return "not_found" as const;
      if (this.shares.forProject(projectId)) return "already_shared" as const;
      const tasks = this.sql.exec<{ id: string }>(
        "SELECT id FROM tasks WHERE project = ? AND deletedAt IS NULL ORDER BY kind IS NULL OR kind != 'heading', rev", projectId,
      ).toArray();
      if (tasks.length > MAX_SHARE_TASKS) return "too_large" as const;
      this.shares.put({ id: info.id, userId, localProjectId: projectId, info });
      this.shares.map(info.id, "project", SHARED_PROJECT_ROW, projectId);
      this.shares.enqueue(info.id, "project", SHARED_PROJECT_ROW, false, this.outFields("project", project, SHARED_FIELDS.project));
      for (const { id } of tasks) this.shareTaskIn(info.id, id, this.rowOf("task", id)!);
      this.setProjectShare(projectId, info);
      return "ok" as const;
    });
    if (result === "ok") {
      this.broadcast(this.meta("rev"));
      this.kickShares();
    }
    return result;
  }

  /// The local project id a share request may name, checked before anything
  /// is created.
  canShare(projectId: string): "ok" | "not_found" | "already_shared" {
    const project = this.rowOf("project", projectId);
    if (!project || project.deletedAt) return "not_found";
    return this.shares.forProject(projectId) ? "already_shared" : "ok";
  }

  listShares(): { id: string; projectId: string; role: "owner" | "editor"; memberId: string; info: ShareInfo }[] {
    return this.shares.list().map((s) => ({ id: s.id, projectId: s.localProjectId, role: s.role, memberId: s.memberId, info: s.info }));
  }

  private setProjectShare(projectId: string, info: ShareInfo | null): void {
    const next = info ? JSON.stringify(info) : null;
    const row = this.sql.exec<{ share: string | null }>("SELECT share FROM projects WHERE id = ? AND deletedAt IS NULL", projectId).toArray()[0];
    if (!row || row.share === next) return;
    this.sql.exec("UPDATE projects SET share = ?, rev = ?, updatedAt = ? WHERE id = ?", next, this.nextRev(), new Date().toISOString(), projectId);
  }

  /// Sends queued writes to their ProjectStores. A failure is tried again by
  /// the alarm; nothing is lost in between.
  private kickShares(): void {
    if (this.drainingShares || !this.shares.pendingShares().length) return;
    this.ctx.waitUntil(this.drainShares());
  }

  async drainShares(): Promise<void> {
    if (this.drainingShares) return;
    this.drainingShares = true;
    let failed = false;
    try {
      for (const shareId of this.shares.pendingShares()) {
        const share = this.shares.get(shareId);
        if (!share) { this.shares.remove(shareId); continue; }
        try {
          for (let batch = this.shares.nextBatch(shareId); batch; batch = this.shares.nextBatch(shareId)) {
            const res = await projectStoreFor(this.env, shareId).push(share.userId, batch.ops);
            if (!res.ok) {
              // The membership ended. Its notice may still be on the way.
              await this.receiveShare({ shareId, userId: share.userId, state: "ended", keepCopy: share.role === "owner" });
              break;
            }
            this.shares.sent(shareId, batch.through);
          }
          for (let ids = this.shares.maskedRows(shareId); ids.length; ids = this.shares.maskedRows(shareId)) {
            const rows = await projectStoreFor(this.env, shareId).rows(share.userId, ids);
            if (!rows) {
              await this.receiveShare({ shareId, userId: share.userId, state: "ended", keepCopy: share.role === "owner" });
              break;
            }
            for (const { entity, id } of ids) {
              if (!rows.some((r) => r.entity === entity && r.id === id)) this.shares.took(shareId, entity, id, 0, false);
            }
            // Deliver them like any other rows. A write that came in
            // meanwhile masks its row again; it is sent first, next round.
            const before = this.meta("rev");
            const purged: string[] = [];
            this.ctx.storage.transactionSync(() => {
              for (const row of rows) this.applyShared(shareId, share.localProjectId, row, purged);
            });
            if (this.meta("rev") > before) this.broadcast(this.meta("rev"));
            this.purgeAttachments(share.userId, purged);
            if (this.shares.nextBatch(shareId)) break;
          }
        } catch (e) {
          failed = true;
          logEvent("share_push_failed", { shareId, error: String(e) });
        }
      }
    } finally {
      this.drainingShares = false;
    }
    if (failed) await this.ctx.storage.setAlarm(Date.now() + SHARE_RETRY_MS);
    else this.kickShares();
  }

  /// Takes a delivery from a ProjectStore. Only a ProjectStore calls it, and
  /// it only writes shared fields.
  async receiveShare(d: ShareDelivery): Promise<"ok" | "account_gone"> {
    if (this.deletedAt() > 0) return "account_gone";
    const purged: string[] = [];
    const before = this.meta("rev");
    this.ctx.storage.transactionSync(() => {
      if (d.state === "ended") this.endShare(d.shareId, d.keepCopy, purged);
      else this.applyDelivery(d, purged);
    });
    const rev = this.meta("rev");
    if (rev > before) this.broadcast(rev);
    this.purgeAttachments(d.userId, purged);
    return "ok";
  }

  private purgeAttachments(userId: string, ids: string[]): void {
    if (ids.length) this.ctx.waitUntil(this.env.ATTACHMENTS.delete(ids.map((id) => `u/${userId}/att/${id}`)));
  }

  private applyDelivery(d: Extract<ShareDelivery, { state: "live" }>, purged: string[]): void {
    let share = this.shares.get(d.shareId);
    if (!share) {
      // The first delivery is what makes the replica.
      const projectId = newSharedRowId();
      const now = new Date().toISOString();
      this.sql.exec(
        "INSERT INTO projects (id, title, status, created, rev, updatedAt) VALUES (?, '', 'active', ?, ?, ?)",
        projectId, now.slice(0, 10), this.nextRev(), now,
      );
      this.shares.put({ id: d.shareId, userId: d.userId, localProjectId: projectId, info: d.info });
      this.shares.map(d.shareId, "project", SHARED_PROJECT_ROW, projectId);
      share = this.shares.get(d.shareId)!;
    } else {
      this.shares.put({ id: d.shareId, userId: d.userId, localProjectId: share.localProjectId, info: d.info });
    }
    this.setProjectShare(share.localProjectId, d.info);
    for (const row of d.rows) this.applyShared(d.shareId, share.localProjectId, row, purged);
  }

  /// The local id of a shared row, reserved when the row is not here yet.
  private localFor(shareId: string, entity: SharedEntity, sharedId: string): string {
    const known = this.shares.localId(shareId, entity, sharedId);
    if (known) return known;
    // A row from an earlier membership is a tombstone under this id.
    const id = this.rowOf(entity, sharedId) ? newSharedRowId() : sharedId;
    this.shares.map(shareId, entity, sharedId, id);
    return id;
  }

  private applyShared(shareId: string, projectId: string, row: ShareRow, purged: string[]): void {
    const { entity } = row;
    if (row.rev < this.shares.revOf(shareId, entity, row.id)) return;
    const known = this.shares.localId(shareId, entity, row.id);
    if (row.deleted) {
      if (known) purged.push(...this.tombstoneReplica(entity, known, new Date().toISOString(), row.by));
      return;
    }
    const id = this.localFor(shareId, entity, row.id);
    // Moved out of the project here: the delete is on its way.
    if (ShareBook.isRetired(id)) return;
    const spec: EntitySpec = ENTITIES[entity];
    const before = this.rowOf(entity, id);
    if (before?.deletedAt) return;
    const pending = this.shares.pendingFields(shareId, entity, row.id);
    this.shares.took(shareId, entity, row.id, row.rev, Object.keys(row.fields).some((f) => pending.has(f)));
    const now = new Date().toISOString();
    const allowed = before ? SHARED_FIELDS[entity] : [...SHARED_FIELDS[entity], ...(entity === "task" ? SEED_FIELDS : [])];
    const next: Record<string, unknown> = {};
    for (const [name, value] of Object.entries(row.fields)) {
      if (!allowed.includes(name) || pending.has(name)) continue;
      let v: unknown = value;
      if (typeof v === "string" && (name === "heading" || name === "taskId")) v = this.localFor(shareId, "task", v);
      if (!before || JSON.stringify(before[name] ?? null) !== JSON.stringify(v ?? null)) next[name] = v;
    }
    if (!before) {
      if (typeof next.title !== "string") return;
      if (entity === "task") {
        // Not a proposal, not filed yet, and its fade clock starts today.
        Object.assign(next, { project: projectId, source: "app", acknowledgedAt: now, touchedAt: now, status: next.status ?? "open" });
      }
    }
    const names = Object.keys(next);
    if (!names.length) return;
    const rev = this.nextRev();
    const encode = (n: string) => encodeValue(sharedColumn(entity, n), next[n]);
    if (before) {
      this.sql.exec(
        `UPDATE ${spec.table} SET ${names.map((n) => `"${n}" = ?`).join(", ")}, rev = ?, updatedAt = ? WHERE id = ?`,
        ...names.map(encode), rev, now, id,
      );
    } else {
      for (const [n, c] of Object.entries(spec.columns)) if (!(n in next) && c.dflt !== undefined) { next[n] = c.kind === "bool" ? c.dflt === 1 : c.dflt; names.push(n); }
      this.sql.exec(
        `INSERT INTO ${spec.table} (${names.map((n) => `"${n}"`).join(", ")}, id, rev, updatedAt) VALUES (${names.map(() => "?").join(", ")}, ?, ?, ?)`,
        ...names.map(encode), id, rev, now,
      );
    }
    const actor = `member:${row.by}`;
    this.log(rev, entity, id, "upsert", names, null, actor, now, this.diffFor(before, next));
    // Another member closed the task: the Do of it here ends too (docs/DO_SPEC.md §2.1).
    if (entity === "task" && "status" in next) this.resolveDo(actor, now);
    if (entity === "project" && "notes" in next) {
      this.recordNoteRevision("project", id, (next.notes as string | null) ?? null, actor, now, (before?.noteRev as number | null) ?? 0, null);
    }
  }

  /// Deletes a replica row here without telling the project. Returns the
  /// attachments whose bytes to purge.
  private tombstoneReplica(entity: SharedEntity, id: string, now: string, by: string | null = null): string[] {
    const before = this.rowOf(entity, id);
    if (!before || before.deletedAt) return [];
    const rev = this.nextRev();
    this.sql.exec(`UPDATE ${ENTITIES[entity].table} SET deletedAt = ?, rev = ?, updatedAt = ? WHERE id = ?`, now, rev, now, id);
    this.log(rev, entity, id, "delete", null, null, by ? `member:${by}` : "system:share", now);
    if (entity !== "task") return [];
    this.tombstoneConvo(id, now);
    const purged = this.tombstoneAttachments(id, now);
    this.tombstoneChecklistItems(id, now);
    this.tombstoneTaskRefs(id, now);
    this.tombstoneDoSessions(id, now);
    return purged;
  }

  private endShare(shareId: string, keepCopy: boolean, purged: string[]): void {
    const share = this.shares.get(shareId);
    if (!share) return;
    const rows = this.shares.mapped(shareId);
    this.shares.remove(shareId);
    if (keepCopy) {
      this.setProjectShare(share.localProjectId, null);
      return;
    }
    const now = new Date().toISOString();
    for (const entity of ["checklistItem", "task", "project"] as const) {
      for (const r of rows) if (r.entity === entity) purged.push(...this.tombstoneReplica(entity, r.localId, now));
    }
  }

  /// The rules an agent write must pass, enforced here so no connector can
  /// skip them: the stop is the human's alone, a stopped task takes no agent
  /// writes at all, and an agent cannot mark an agent-worked task done —
  /// only the human accepts it after review (`human_accepts`).
  private agentRefusal(op: Op): string | null {
    if (op.op !== "appendTurn" && op.entity === "doSession") return "human_only_do";
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

  // ---- Do (docs/DO_SPEC.md, ADR 0041) ----

  /// A permanently deleted task takes its Do history with it.
  private tombstoneDoSessions(taskId: string, now: string): void {
    const ids = this.sql.exec<{ id: string }>(
      "SELECT id FROM do_sessions WHERE taskId = ? AND deletedAt IS NULL", taskId,
    ).toArray().map((r) => r.id);
    for (const id of ids) {
      const rev = this.nextRev();
      this.sql.exec("UPDATE do_sessions SET deletedAt = ?, rev = ?, updatedAt = ? WHERE id = ?", now, rev, now, id);
    }
  }

  /// Keeps §2.1 rules 2 and 4 on one push, in place, and returns the fields
  /// that are left to write. A closed row only takes an earlier end or a new
  /// note. A push that loses still moves the row's rev, so its device pulls
  /// what the store kept.
  private settleDoFields(fields: Record<string, unknown>, row: Record<string, unknown> | undefined, now: string): string[] {
    const startedAt = (row?.startedAt as string | undefined) ?? (fields.startedAt as string | undefined) ?? now;
    if (!row && typeof fields.startedAt === "string" && Date.parse(fields.startedAt) > Date.parse(now)) fields.startedAt = now;
    if (typeof fields.endedAt === "string" && Date.parse(fields.endedAt) < Date.parse(startedAt)) fields.endedAt = startedAt;
    const drop = (...keys: string[]) => { for (const k of keys) delete fields[k]; };
    const current = (row?.endedAt as string | null | undefined) ?? null;
    if (typeof fields.endedAt === "string" && doEndWins(current, fields.endedAt)) {
      fields.exit ??= "stopped";
      if (current) fields.lapsed ??= false;
    } else {
      drop("endedAt", "exit", "lapsed");
    }
    if (current) drop("plannedMinutes", "confirmedAt");
    return Object.keys(fields);
  }

  /// The rows the core needs: the open ones and every row that started after
  /// the oldest of them.
  private doRows(): { rows: CoreDoSession[]; taskIds: Map<string, string> } {
    const open = this.sql.exec<{ startedAt: string }>(
      "SELECT startedAt FROM do_sessions WHERE endedAt IS NULL AND deletedAt IS NULL",
    ).toArray();
    const taskIds = new Map<string, string>();
    if (open.length === 0) return { rows: [], taskIds };
    // Stamps keep their zone, so the instants are compared here, not in SQL.
    const oldest = Math.min(...open.map((r) => Date.parse(r.startedAt)));
    const rows = this.sql.exec<{
      id: string; taskId: string; startedAt: string; plannedMinutes: number | null; confirmedAt: string | null;
      endedAt: string | null; status: string | null; gone: number;
    }>(
      `SELECT s.id, s.taskId, s.startedAt, s.plannedMinutes, s.confirmedAt, s.endedAt, t.status,
              (t.id IS NULL OR t.deletedAt IS NOT NULL OR t.fadedAt IS NOT NULL) AS gone
       FROM do_sessions s LEFT JOIN tasks t ON t.id = s.taskId WHERE s.deletedAt IS NULL AND s.startedAt >= ?`,
      new Date(oldest - DAY_MS).toISOString().slice(0, 10),
    ).toArray().filter((r) => Date.parse(r.startedAt) >= oldest);
    for (const r of rows) taskIds.set(r.id, r.taskId);
    return {
      rows: rows.map((r) => ({
        id: r.id, startedAt: r.startedAt, plannedMinutes: r.plannedMinutes, confirmedAt: r.confirmedAt,
        endedAt: r.endedAt, taskStatus: r.gone ? null : r.status,
      })),
      taskIds,
    };
  }

  /// Ends every open Do that the rules end. `startedId` is a Do that this
  /// write started: when it stays open, a live agent claim on its task ends,
  /// because the user does that task now (§6).
  private resolveDo(actor: string, now: string, startedId: string | null = null): void {
    const { rows, taskIds } = this.doRows();
    if (rows.length === 0) return;
    const { ends, current } = resolveDoSessions(rows, now);
    for (const end of ends) {
      const fields = { endedAt: end.endedAt, exit: end.exit, lapsed: end.lapsed };
      const rev = this.nextRev();
      this.sql.exec(
        "UPDATE do_sessions SET endedAt = ?, exit = ?, lapsed = ?, rev = ?, updatedAt = ? WHERE id = ?",
        end.endedAt, end.exit, end.lapsed ? 1 : 0, rev, now, end.id,
      );
      this.log(rev, "doSession", end.id, "upsert", Object.keys(fields), null, actor, now, this.diffFor(null, fields));
    }
    if (!startedId || current?.id !== startedId) return;
    const taskId = taskIds.get(startedId)!;
    const claim = this.sql.exec<{ claimedBy: string | null; claimUntil: string | null }>(
      "SELECT claimedBy, claimUntil FROM convos WHERE id = ? AND deletedAt IS NULL", taskId,
    ).toArray()[0];
    if (!claim?.claimedBy || !claim.claimUntil || Date.parse(claim.claimUntil) <= Date.parse(now)) return;
    const reason = this.reason;
    this.reason = "The user does this task now.";
    try {
      this.writeConvoServerFields(taskId, { claimedBy: null, claimUntil: null }, "release", actor, now, true);
    } finally {
      this.reason = reason;
    }
  }

  /// The current Do, or null. `staleAt`, `startedAt` and the rest are stamps.
  readDoing(): Doing | null {
    const { rows, taskIds } = this.doRows();
    if (rows.length === 0) return null;
    const { current } = resolveDoSessions(rows, new Date().toISOString());
    if (!current) return null;
    const row = rows.find((r) => r.id === current.id)!;
    const taskId = taskIds.get(current.id)!;
    const title = this.sql.exec<{ title: string | null }>("SELECT title FROM tasks WHERE id = ?", taskId).toArray()[0]?.title ?? "";
    return {
      sessionId: current.id, taskId, title, startedAt: row.startedAt, plannedMinutes: row.plannedMinutes ?? null,
      confirmedAt: row.confirmedAt ?? null, staleAt: new Date(current.staleAtMs).toISOString(), isStale: current.isStale,
    };
  }

  /// One Do, open or closed, or null.
  readDoSession(id: string): Row | null {
    const raw = this.sql.exec("SELECT * FROM do_sessions WHERE id = ? AND deletedAt IS NULL", id).toArray()[0];
    return raw ? (decodeRow(ENTITIES.doSession, raw) as Row) : null;
  }

  /// The Do history of one task, newest first.
  readDoSessions(taskId: string): Row[] {
    return this.sql.exec("SELECT * FROM do_sessions WHERE taskId = ? AND deletedAt IS NULL", taskId).toArray()
      .map((r) => decodeRow(ENTITIES.doSession, r) as Row)
      .sort((a, b) => Date.parse(b.startedAt as string) - Date.parse(a.startedAt as string));
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

  private appendTurn(
    clientOpId: string,
    taskId: string,
    turn: Turn,
    actor: string,
    now: string,
    agentQuestions: AgentQuestionPush[],
  ): OpResult {
    const task = this.sql.exec<{ title: string | null; deletedAt: string | null }>(
      "SELECT title, deletedAt FROM tasks WHERE id = ?",
      taskId,
    ).toArray()[0];
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
      // The agent asked: the ball is in the human's court, so the claim ends
      // and we alert the user's Apple devices via APNs (F1b #213).
      this.writeConvoServerFields(taskId, { claimedBy: null, claimUntil: null }, "release", actor, now, true);
      agentQuestions.push({
        taskId,
        taskTitle: task.title ?? "",
        turnSeq: seq,
        step: turn.step,
        question: turn.question ?? null,
        note: turn.note ?? null,
        options: turn.options,
      });
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
      const doing = this.readDoing();
      if (doing && !doing.isStale && doing.taskId === taskId) return { ok: false, reason: "doing" };
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
        else if (r.entity === "doSession" && (diff.taskId || diff.endedAt)) {
          const row = this.sql.exec<{ taskId: string }>("SELECT taskId FROM do_sessions WHERE id = ?", r.id).toArray()[0];
          if (row) push(diff.endedAt ? "do_ended" : "do_started", row.taskId);
        }
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
    includeRefs = false, includeDoSessions = false,
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
      if (name === "doSession" && !includeDoSessions) continue;
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

  /// Open non-heading tasks whose last turn is an agent's question with
  /// options (`awaitsHuman`), newest question first. A stopped task is not in
  /// it: the user already said no.
  readOpenQuestions(limit: number): { rows: Row[]; turns: Record<string, Row>; total: number } {
    const n = Math.min(Math.max(limit, 1), 100);
    const raw = this.sql.exec(`
      SELECT t.id AS id FROM tasks t
      JOIN turns q ON q.taskId = t.id AND q.seq = (SELECT MAX(seq) FROM turns WHERE taskId = t.id)
      LEFT JOIN convos c ON c.id = t.id AND c.deletedAt IS NULL
      WHERE t.deletedAt IS NULL AND t.status = 'open' AND (t.kind IS NULL OR t.kind != 'heading')
        AND c.stoppedAt IS NULL
        AND q.role = 'provider' AND q.options IS NOT NULL AND q.options != '[]'
      ORDER BY q.rev DESC`).toArray();
    const rows: Row[] = [];
    const turns: Record<string, Row> = {};
    for (const { id } of raw.slice(0, n) as { id: string }[]) {
      const read = this.readTask(id);
      const last = read?.turns[read.turns.length - 1];
      if (!read || !last) continue;
      rows.push(read.task);
      turns[id] = last;
    }
    return { rows, turns, total: raw.length };
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

  // ---- capture (§6.2) ----

  /// Creates a task made from items outside Septena, unless an active task is
  /// made from one of them: then nothing is created and that task is the
  /// answer. An agent's suggestion from an item that the user turned down is
  /// not created either. When only closed tasks have a key, the new task gets a
  /// `follow_up` reference to the closed one. There is no await between the
  /// lookup and the insert, so two captures of one item can never both create.
  captureTask(ops: Op[], actor: string, capture: Capture): CaptureOutcome {
    const hit = this.captureHit(capture.fromKeys);
    if (hit?.active && !capture.allowDuplicate) {
      this.stampSeen(hit, actor);
      return { existing: hit };
    }
    if (capture.suggestion && !capture.allowDuplicate) {
      const dismissed = this.dismissedKeys(capture.fromKeys);
      if (dismissed.length > 0) return { existing: null, dismissed };
    }
    let followUpAt = -1;
    if (hit && !hit.active) {
      const key = `task:${hit.id}`;
      const refOps = ops.filter((op) => op.op === "upsert" && op.entity === "taskRef");
      if (!refOps.some((op) => op.op === "upsert" && op.fields.key === key)) {
        followUpAt = ops.length;
        ops = [...ops, {
          clientOpId: `${ops[0].clientOpId}-follow`, op: "upsert", entity: "taskRef", id: taskRefId(capture.taskId, key, 0),
          fields: { taskId: capture.taskId, key, role: "follow_up", position: (refOps.length + 1) * 1024, createdAt: new Date().toISOString() },
        }];
      }
    }
    const { results } = this.push(ops, actor).result;
    if (hit && this.liveTask(capture.taskId)) this.stampSeen(hit, actor);
    return {
      existing: null, dismissed: null, results,
      followUp: hit && results[followUpAt]?.status === "applied" ? { id: hit.id, title: hit.title } : null,
    };
  }

  /// The task made from one of these keys: an active one first, then the most
  /// recently touched. A deleted task is not a hit. Only a `from` reference
  /// counts, so a task that is about the item never blocks one made from it.
  private captureHit(keys: string[]): CaptureHit | null {
    if (keys.length === 0) return null;
    const from = `FROM task_refs r JOIN tasks t ON t.id = r.taskId
      WHERE r.key IN (${keys.map(() => "?").join(", ")}) AND r.role = 'from' AND r.deletedAt IS NULL
        AND t.deletedAt IS NULL AND (t.kind IS NULL OR t.kind != 'heading')`;
    const row = this.sql.exec<Record<string, string | null>>(
      `SELECT t.id, t.title, t.status, t.area, t.project, t.fadedAt ${from}
       ORDER BY (t.status = 'open' AND t.fadedAt IS NULL) DESC, COALESCE(t.touchedAt, t.createdAt) DESC, t.rev DESC LIMIT 1`,
      ...keys,
    ).toArray()[0];
    if (!row) return null;
    const matched = this.sql.exec<{ key: string }>(`SELECT r.key ${from} AND t.id = ?`, ...keys, row.id).toArray();
    return {
      id: row.id as string, title: row.title ?? "", status: row.status ?? "open", area: row.area, project: row.project,
      active: row.status === "open" && row.fadedAt === null, keys: matched.map((m) => m.key),
    };
  }

  /// True when a person removes an agent proposal they never accepted.
  private isTurnDown(row: Record<string, unknown>, actor: string): boolean {
    return !isAgentActor(actor) && row.source === "mcp" && !row.acknowledgedAt && row.status === "open";
  }

  /// Remembers the items a turned-down proposal was made from: the key and
  /// the time, nothing else.
  private rememberTurnDown(taskId: string, now: string): void {
    this.sql.exec(
      `INSERT OR REPLACE INTO dismissed_refs (key, at)
       SELECT key, ? FROM task_refs WHERE taskId = ? AND role = 'from' AND deletedAt IS NULL`,
      now, taskId,
    );
  }

  /// The user took the task back, so its items may be proposed again.
  private forgetTurnDown(taskId: string): void {
    this.sql.exec(
      "DELETE FROM dismissed_refs WHERE key IN (SELECT key FROM task_refs WHERE taskId = ? AND deletedAt IS NULL)", taskId,
    );
  }

  /// The keys of a capture that the user turned down. A thread key counts
  /// only alone: a new message in a thread is a new item.
  private dismissedKeys(keys: string[]): string[] {
    const items = keys.filter((k) => !k.startsWith("thread:"));
    return (items.length > 0 ? items : keys).filter((key) => this.isDismissed(key));
  }

  /// The user turned down a proposal made from this item. `key` is in normal form.
  isDismissed(key: string): boolean {
    return this.sql.exec("SELECT 1 FROM dismissed_refs WHERE key = ?", key).toArray().length > 0;
  }

  /// Stamps the references a capture met, with a "captured again" entry in
  /// the task's history. Not for an agent on a stopped task or while agents
  /// are paused (ADR 0008).
  private stampSeen(hit: CaptureHit, actor: string): void {
    if (isAgentActor(actor) && (this.readSetting("agentsPaused") === true || this.convoStopped(hit.id))) return;
    const now = new Date().toISOString();
    this.ctx.storage.transactionSync(() => {
      for (const key of hit.keys) {
        const ref = this.sql.exec<{ id: string; lastSeenAt: string | null }>(
          "SELECT id, lastSeenAt FROM task_refs WHERE taskId = ? AND key = ? AND deletedAt IS NULL", hit.id, key,
        ).one();
        const rev = this.nextRev();
        this.sql.exec("UPDATE task_refs SET lastSeenAt = ?, rev = ?, updatedAt = ? WHERE id = ?", now, rev, now, ref.id);
        this.log(rev, "task", hit.id, "capture", ["lastSeenAt"], null, actor, now, { lastSeenAt: [ref.lastSeenAt, now] });
      }
    });
    this.broadcast(this.meta("rev"));
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

  // ---- sessions (refresh tokens, stored hashed; src/store/sessions.ts) ----

  createSession(hash: string, expiresAt: number, sid: string, grant: SessionGrant | null = null): void {
    this.sessions.create(hash, expiresAt, sid, grant);
  }

  sessionIdFor(hash: string): string | null {
    return this.sessions.idFor(hash);
  }

  /// Trades a refresh token for its child. A reused token ends the session.
  renewSession(hash: string, newHash: string, expiresAt: number, sid: string, clientId: string | null = null, now = Date.now()): RenewResult {
    const res = this.ctx.storage.transactionSync(() => this.sessions.renew(hash, newHash, expiresAt, sid, clientId, now));
    if (!res.ok && res.reason === "reused") this.endSession(sid);
    return res;
  }

  /// The check behind every access token: is the session alive, and what may
  /// it do? Null = refuse.
  authorizeSession(sid: string, hash: string | null, now = Date.now()): { grant: SessionGrant | null } | null {
    return this.ctx.storage.transactionSync(() => this.sessions.authorize(sid, hash, now));
  }

  revokeSessionAccess(sid: string, hash: string): boolean {
    return this.sessions.revokeAccess(sid, hash);
  }

  /// May an agent token that KV holds (from before ADR 0040) still work? Not
  /// after its family ended, and not when the account was deleted since.
  legacyAgentAllowed(familyId: string, issuedAt: number): boolean {
    return issuedAt > this.meta("deletedAt") && !this.sessions.hasEnded(familyId);
  }

  /// Moves an agent's refresh token from KV into this store.
  adoptSession(hash: string, issuedAt: number, expiresAt: number, sid: string, grant: SessionGrant): void {
    if (this.legacyAgentAllowed(sid, issuedAt) && !this.sessions.exists(sid)) this.sessions.create(hash, expiresAt, sid, grant);
  }

  /// A pairing approved before an account deletion must not bring it back.
  hasAppSession(): boolean {
    return this.sessions.hasAppSession();
  }

  /// When the account in this store was last deleted (ms), or 0.
  deletedAt(): number {
    return this.meta("deletedAt");
  }

  /// True once an agent's session lives here instead of in KV.
  ownsMovedAgent(familyId: string): boolean {
    return this.sessions.isAgent(familyId);
  }

  ownsAgent(familyId: string): boolean {
    return this.sessions.isAgent(familyId)
      || this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM connections WHERE familyId = ?", familyId).one().n > 0;
  }

  /// Ends one connected agent. False when it is not in this store.
  endAgent(familyId: string): boolean {
    if (!this.ownsAgent(familyId)) return false;
    this.endSession(familyId);
    return true;
  }

  /// `recordConnection` for an agent whose session is here. A disconnect that
  /// lands in the middle of a renewal wins.
  noteAgent(familyId: string, clientId: string, clientName: string, scope: string, now = Date.now(), label: string | null = null): void {
    if (this.sessions.exists(familyId)) this.recordConnection(familyId, clientId, clientName, scope, now, label);
  }

  /// Sign-out with a refresh token. Any token the session ever issued ends it.
  revokeSession(hash: string, sid: string | null = null): void {
    const id = sid ?? this.sessions.idFor(hash);
    if (id) this.endSession(id);
  }

  /// Ends one session at once: its tokens, its device or agent row, its push
  /// tokens and its open sockets. Returns its refresh hashes.
  endSession(sid: string): string[] {
    const hashes = this.ctx.storage.transactionSync(() => {
      const ended = this.sessions.end(sid);
      this.sql.exec("DELETE FROM devices WHERE sid = ?", sid);
      this.sql.exec("DELETE FROM connections WHERE familyId = ?", sid);
      this.sql.exec("DELETE FROM push_tokens WHERE deviceId = ?", sid);
      return ended;
    });
    for (const sub of [...this.sseSubscribers]) if (sub.sid === sid) sub.close();
    for (const ws of this.ctx.getWebSockets(sessionTag(sid))) {
      try { ws.close(1008, "signed out"); } catch { /* already closed */ }
    }
    return hashes;
  }

  /// The rotation call of a Worker from before ADR 0040, for the seconds both
  /// versions run during a deploy. Remove after 2026-12.
  rotateSession(oldHash: string, newHash: string, expiresAt: number): string | null {
    const sid = this.sessions.idFor(oldHash);
    return sid && this.renewSession(oldHash, newHash, expiresAt, sid).ok ? sid : null;
  }

  // ---- Devices & Access (Settings ▸ Account ▸ Devices & Access) ----

  /// Signs one device out. Returns its refresh hashes; empty when the session
  /// is not in this store.
  revokeDevice(sid: string): string[] {
    return this.endSession(sid);
  }

  // ---- APNs push tokens (F1b #213, docs/TASK_FACTORY_SPEC.md §8) ----

  upsertPushToken(entry: {
    token: string;
    deviceId?: string | null;
    platform: PushPlatform;
    sandbox: boolean;
  }): PushTokenRow {
    const token = entry.token.trim().toLowerCase();
    const deviceId = entry.deviceId?.trim() || null;
    const platform: PushPlatform = entry.platform === "watchos" ? "watchos" : "ios";
    const sandbox = !!entry.sandbox;
    const now = new Date().toISOString();
    this.ctx.storage.transactionSync(() => {
      // If this device rotated its APNs token on the same platform, drop its
      // superseded token so one device does not receive duplicate alerts.
      if (deviceId) {
        this.sql.exec(
          "DELETE FROM push_tokens WHERE deviceId = ? AND platform = ? AND token != ?",
          deviceId, platform, token,
        );
      }
      this.sql.exec(
        `INSERT INTO push_tokens (token, deviceId, platform, sandbox, updatedAt)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(token) DO UPDATE SET
           deviceId = COALESCE(excluded.deviceId, push_tokens.deviceId),
           platform = excluded.platform,
           sandbox = excluded.sandbox,
           updatedAt = excluded.updatedAt`,
        token, deviceId, platform, sandbox ? 1 : 0, now,
      );
    });
    return { token, deviceId, platform, sandbox, updatedAt: now };
  }

  deletePushToken(token: string): boolean {
    const clean = token.trim().toLowerCase();
    return this.sql.exec("DELETE FROM push_tokens WHERE token = ?", clean).rowsWritten > 0;
  }

  listPushTokens(): PushTokenRow[] {
    return this.sql.exec<{
      token: string;
      deviceId: string | null;
      platform: string;
      sandbox: number;
      updatedAt: string;
    }>("SELECT token, deviceId, platform, sandbox, updatedAt FROM push_tokens ORDER BY updatedAt DESC")
      .toArray()
      .map((r) => ({
        token: r.token,
        deviceId: r.deviceId,
        platform: r.platform === "watchos" ? "watchos" : "ios",
        sandbox: r.sandbox !== 0,
        updatedAt: r.updatedAt,
      }));
  }

  prunePushTokens(tokens: string[]): number {
    if (tokens.length === 0) return 0;
    return this.ctx.storage.transactionSync(() => {
      let removed = 0;
      for (const t of tokens) {
        removed += this.sql.exec("DELETE FROM push_tokens WHERE token = ?", t.trim().toLowerCase()).rowsWritten;
      }
      return removed;
    });
  }

  private async dispatchAgentQuestionPushes(
    questions: AgentQuestionPush[],
    initialTokens: PushTokenRow[],
  ): Promise<void> {
    let activeTokens = initialTokens;
    for (const q of questions) {
      if (activeTokens.length === 0) break;
      try {
        const res = await sendAgentQuestionPushes(this.env, q, activeTokens);
        if (res.pruned.length > 0) {
          this.prunePushTokens(res.pruned);
          const dead = new Set(res.pruned);
          activeTokens = activeTokens.filter((t) => !dead.has(t.token));
        }
      } catch (err) {
        logEvent("apns_dispatch_error", {
          taskId: q.taskId,
          error: err instanceof Error ? err.message.slice(0, 120) : "unexpected",
        });
      }
    }
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
    const devices = this.deviceSummary(cap, now);
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

  // ---- device slot (docs/SYNC_SUBSCRIPTION_SPEC.md §3, §6.3–§6.4, ADR 0023) ----
  // A device is a session (`sid`). The slot holders are the `cap` live
  // sessions with the newest `slotAt` within the last 14 days. A device that
  // is allowed to sync refreshes its `slotAt`, so with no cap (Plus) the order
  // is "most recently used": a lapsed account keeps the device it used last.

  /// Records one sync call from `sid` and says whether it holds a slot.
  /// A device takes a free slot by itself — including when the previous holder
  /// has not synced for 14 days (spec §6.4 finding 1). It never pushes out an
  /// active holder (that is `claimDeviceSlot`), and an automatic take never
  /// counts against the 24-hour manual move cooldown.
  deviceAccess(sid: string, client: string | null, cap: number | null, now = Date.now(), version: string | null = null): { syncing: boolean } {
    return this.ctx.storage.transactionSync(() => {
      this.touchDevice(sid, client, now, version);
      const holders = cap === null ? null : this.slotHolders(cap, now);
      const syncing = holders === null || holders.includes(sid) || holders.length < cap!;
      if (syncing) this.sql.exec("UPDATE devices SET slotAt = ? WHERE sid = ?", this.nextSlotAt(now), sid);
      return { syncing };
    });
  }

  /// Moves a slot to `sid` ("sync this device instead"). With a cap of N the
  /// holder used least recently stops syncing; its local data stays.
  /// On a capped plan, manual moves are limited to one per 24 hours (spec §6.4
  /// finding 2). Re-claiming when already syncing or taking an open/expired
  /// slot does not count as a move.
  claimDeviceSlot(
    sid: string,
    client: string | null,
    cap: number | null = null,
    enforce = true,
    now = Date.now(),
  ): { ok: true; moved: boolean; wouldBlock?: boolean } | { ok: false; retryAfterMs: number } {
    return this.ctx.storage.transactionSync(() => {
      this.touchDevice(sid, client, now);
      if (cap !== null) {
        const holders = this.slotHolders(cap, now);
        if (holders.includes(sid) || holders.length < cap) {
          this.sql.exec("UPDATE devices SET slotAt = ? WHERE sid = ?", this.nextSlotAt(now), sid);
          return { ok: true, moved: false };
        }
        const lastMovedAt = this.meta("deviceSlotMovedAt");
        const elapsed = now - lastMovedAt;
        if (lastMovedAt > 0 && elapsed < DEVICE_SLOT_MOVE_COOLDOWN_MS) {
          const retryAfterMs = DEVICE_SLOT_MOVE_COOLDOWN_MS - elapsed;
          if (enforce) return { ok: false, retryAfterMs };
          this.sql.exec("UPDATE devices SET slotAt = ? WHERE sid = ?", this.nextSlotAt(now), sid);
          this.setMeta("deviceSlotMovedAt", now);
          return { ok: true, moved: true, wouldBlock: true };
        }
        this.sql.exec("UPDATE devices SET slotAt = ? WHERE sid = ?", this.nextSlotAt(now), sid);
        this.setMeta("deviceSlotMovedAt", now);
        return { ok: true, moved: true };
      }
      this.sql.exec("UPDATE devices SET slotAt = ? WHERE sid = ?", this.nextSlotAt(now), sid);
      return { ok: true, moved: false };
    });
  }

  /// The devices that synced, newest first, and which of them hold a slot.
  deviceSummary(cap: number | null, now = Date.now()): { client: string | null; sid: string; lastSeen: number; syncing: boolean }[] {
    const holders = cap === null ? null : new Set(this.slotHolders(cap, now));
    return this.sql.exec<{ sid: string; client: string | null; lastSeen: number }>(
      "SELECT d.sid, d.client, d.lastSeen FROM devices d WHERE EXISTS (SELECT 1 FROM sessions s WHERE s.sid = d.sid) ORDER BY d.lastSeen DESC",
    ).toArray().map((r) => ({ ...r, syncing: holders === null || holders.has(r.sid) }));
  }

  private touchDevice(sid: string, client: string | null, now: number, version: string | null = null): void {
    this.sql.exec(
      "INSERT INTO devices (sid, client, firstSeen, lastSeen, version) VALUES (?, ?, ?, ?, ?) ON CONFLICT(sid) DO UPDATE SET lastSeen = excluded.lastSeen, client = COALESCE(excluded.client, devices.client), version = COALESCE(excluded.version, devices.version)",
      sid, client, now, now, version,
    );
  }

  /// Strictly increasing, so two calls in the same millisecond still order.
  private nextSlotAt(now: number): number {
    const top = this.sql.exec<{ m: number | null }>("SELECT MAX(slotAt) AS m FROM devices").one().m;
    return top === null ? now : Math.max(now, top + 1);
  }

  private slotHolders(cap: number, now = Date.now()): string[] {
    if (cap <= 0) return [];
    const cutoff = now - DEVICE_SLOT_INACTIVE_MS;
    return this.sql.exec<{ sid: string }>(
      "SELECT d.sid FROM devices d WHERE d.slotAt IS NOT NULL AND d.slotAt > ? AND EXISTS (SELECT 1 FROM sessions s WHERE s.sid = d.sid) ORDER BY d.slotAt DESC LIMIT ?",
      cutoff,
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

  // ---- admin summary (ADR 0043, src/admin/accounts.ts) ----

  /// Counts, dates and plan rows for the admin page. Never content: no titles,
  /// no notes, no file names, and no name the user typed (an agent shows its
  /// client's registered name, not the user's label). Null = an empty store.
  accountSummary(now = Date.now()): AccountSummary | null {
    const count = (query: string, ...args: SqlStorageValue[]) => this.sql.exec<{ n: number }>(query, ...args).one().n;
    const tasks = "SELECT COUNT(*) AS n FROM tasks WHERE deletedAt IS NULL AND COALESCE(kind, '') != 'heading' AND status";
    const devices = this.sql.exec<{ client: string | null; version: string | null; firstSeen: number; lastSeen: number }>(
      "SELECT client, version, firstSeen, lastSeen FROM devices d WHERE EXISTS (SELECT 1 FROM sessions s WHERE s.sid = d.sid) ORDER BY lastSeen DESC",
    ).toArray().map((r) => ({ ...r }));
    const agents = this.sql.exec<{ client: string; since: number; lastUsed: number }>(
      "SELECT clientName AS client, createdAt AS since, lastUsed FROM connections WHERE lastUsed > ? ORDER BY lastUsed DESC", now - CONNECTION_TTL_MS,
    ).toArray().map((r) => ({ ...r }));
    const entitlements = this.entitlements().map((r) => ({
      id: r.id, source: r.source, productId: r.productId, expiresAt: r.expiresAt, status: r.status,
      environment: r.environment, signedAt: r.signedAt,
    }));
    const openTasks = count(`${tasks} = 'open'`);
    const closedTasks = count(`${tasks} != 'open'`);
    const signedIn = this.hasAppSession();
    if (!signedIn && openTasks + closedTasks === 0 && entitlements.length === 0) return null;
    const first = this.sql.exec<{ at: string | null }>("SELECT MIN(at) AS at FROM changes").one().at;
    const last = this.sql.exec<{ at: string }>("SELECT at FROM changes ORDER BY rev DESC LIMIT 1").toArray()[0]?.at ?? null;
    const starts = [first ? Date.parse(first) : 0, ...devices.map((d) => d.firstSeen), ...entitlements.filter((e) => e.source === "trial").map((e) => e.signedAt)]
      .filter((t) => t > 0);
    return {
      firstSeen: starts.length ? Math.min(...starts) : null,
      lastChangeAt: last ? Date.parse(last) : null,
      signedIn,
      openTasks,
      closedTasks,
      projects: count("SELECT COUNT(*) AS n FROM projects WHERE deletedAt IS NULL"),
      areas: count("SELECT COUNT(*) AS n FROM areas WHERE deletedAt IS NULL"),
      sharedProjects: this.shares.list().length,
      files: count("SELECT COUNT(*) AS n FROM attachments WHERE deletedAt IS NULL AND uploadedAt IS NOT NULL"),
      fileBytes: this.attachmentBytes(),
      devices,
      agents,
      agentChangesWeek: count("SELECT COUNT(*) AS n FROM changes WHERE actor LIKE 'mcp:%' AND at > ?", new Date(now - 7 * DAY_MS).toISOString()),
      webhooks: count("SELECT COUNT(*) AS n FROM agent_webhooks WHERE enabled = 1"),
      failingWebhooks: count("SELECT COUNT(*) AS n FROM agent_webhooks WHERE enabled = 1 AND failureCount > 0"),
      entitlements,
    };
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

  // ---- agent wake webhooks (docs/TASK_FACTORY_SPEC.md §8, issue #5) ----

  listAgentWebhooks(): AgentWebhookPublic[] {
    return this.sql.exec<{
      id: string; url: string; enabled: number; createdAt: string;
      lastDeliveredAt: string | null; lastStatus: number | null; failureCount: number;
    }>(
      "SELECT id, url, enabled, createdAt, lastDeliveredAt, lastStatus, failureCount FROM agent_webhooks ORDER BY createdAt DESC, id",
    ).toArray().map((r) => ({
      id: r.id,
      url: r.url,
      enabled: r.enabled !== 0,
      createdAt: r.createdAt,
      lastDeliveredAt: r.lastDeliveredAt,
      lastStatus: r.lastStatus,
      failureCount: r.failureCount,
    }));
  }

  createAgentWebhook(
    url: string,
    secret: string,
    enabled = true,
  ): { ok: true; webhook: AgentWebhookCreated } | { ok: false; reason: "limit_reached" } {
    return this.ctx.storage.transactionSync(() => {
      const count = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM agent_webhooks").one().n;
      if (count >= MAX_AGENT_WEBHOOKS) return { ok: false as const, reason: "limit_reached" as const };
      const id = `wh_${randomId(12)}`;
      const createdAt = new Date().toISOString();
      this.sql.exec(
        "INSERT INTO agent_webhooks (id, url, secret, enabled, createdAt, lastDeliveredAt, lastStatus, failureCount) VALUES (?, ?, ?, ?, ?, NULL, NULL, 0)",
        id, url, secret, enabled ? 1 : 0, createdAt,
      );
      return {
        ok: true as const,
        webhook: {
          id,
          url,
          secret,
          enabled,
          createdAt,
          lastDeliveredAt: null,
          lastStatus: null,
          failureCount: 0,
        },
      };
    });
  }

  deleteAgentWebhook(id: string): boolean {
    return this.sql.exec("DELETE FROM agent_webhooks WHERE id = ?", id).rowsWritten > 0;
  }

  private recordAgentWebhookDelivery(id: string, status: number, ok: boolean, deliveredAt: string): void {
    if (ok) {
      this.sql.exec(
        "UPDATE agent_webhooks SET lastDeliveredAt = ?, lastStatus = ?, failureCount = 0 WHERE id = ?",
        deliveredAt, status, id,
      );
    } else {
      this.sql.exec(
        "UPDATE agent_webhooks SET lastDeliveredAt = ?, lastStatus = ?, failureCount = failureCount + 1 WHERE id = ?",
        deliveredAt, status, id,
      );
    }
  }

  private dispatchAgentEvents(events: AgentEvent[]): void {
    // 1. Live SSE subscribers
    if (this.sseSubscribers.size > 0) {
      for (const sub of [...this.sseSubscribers]) {
        for (const ev of events) {
          if (ev.rev <= sub.lastRev) continue;
          sub.lastRev = ev.rev;
          if (!sub.send(formatSseEvent(ev))) break;
        }
      }
    }

    // 2. Live agent-events WebSocket subscribers
    const agentSockets = this.ctx.getWebSockets("agent-events");
    if (agentSockets.length > 0) {
      for (const ev of events) {
        const frame = JSON.stringify({ type: "event", event: ev });
        for (const ws of agentSockets) {
          try { ws.send(frame); } catch { /* dead socket; reaped by runtime */ }
        }
      }
    }

    // 3. Outbound signed webhooks for wake-worthy events (assigned, user_turn, resumed)
    const wakeEvents = events.filter((ev) => isWakeEventKind(ev.kind));
    if (wakeEvents.length === 0) return;
    const targets: AgentWebhookTarget[] = this.sql.exec<{ id: string; url: string; secret: string }>(
      "SELECT id, url, secret FROM agent_webhooks WHERE enabled = 1",
    ).toArray();
    if (targets.length === 0) return;

    const delivery = this.deliverAgentWebhooks(targets, wakeEvents).catch(() => {
      // Delivery errors are recorded per webhook; never break the main write.
    });
    if (typeof this.ctx.waitUntil === "function") {
      this.ctx.waitUntil(delivery);
    }
  }

  private async deliverAgentWebhooks(targets: AgentWebhookTarget[], events: AgentEvent[]): Promise<void> {
    await Promise.allSettled(
      targets.flatMap((target) =>
        events.map(async (ev) => {
          const res = await deliverWebhookEvent(target, ev);
          try {
            this.recordAgentWebhookDelivery(target.id, res.status, res.ok, res.deliveredAt);
          } catch {
            // Store may have been deleted while delivery was in flight.
          }
        }),
      ),
    );
  }

  /// Account deletion (§10). The Worker empties the user's R2 prefix.
  async deleteAccount(): Promise<void> {
    for (const sub of [...this.sseSubscribers]) sub.close();
    for (const ws of this.ctx.getWebSockets()) ws.close(1000, "account deleted");
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    // This instance may serve the next request: an empty store refuses every
    // token, a store without tables would answer 500 to the same request.
    this.migrate();
    this.setMeta("deletedAt", Date.now());
  }

  // ---- live nudge (§6.3) & agent event stream (docs/TASK_FACTORY_SPEC.md §8) ----

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    // The session may have ended between the Worker's check and this call.
    const sid = request.headers.get(SESSION_HEADER);
    if (sid && (this.sessions.hasEnded(sid) || (this.deletedAt() > 0 && !this.sessions.exists(sid) && !this.ownsAgent(sid)))) {
      return new Response("session ended", { status: 401 });
    }
    if (url.pathname.endsWith("/agent/events/stream")) {
      return this.handleAgentEventsStream(request, url);
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], sid ? [sessionTag(sid)] : []);
    pair[1].send(JSON.stringify({ rev: this.meta("rev") }));
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  private handleAgentEventsStream(request: Request, url: URL): Response {
    const rawCursor = url.searchParams.get("since") ?? request.headers.get("Last-Event-ID");
    let hasCursor = false;
    let cursor = 0;
    if (rawCursor !== null && rawCursor !== "") {
      if (!/^\d+$/.test(rawCursor)) {
        return new Response(JSON.stringify({ error: "invalid_request" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        });
      }
      cursor = Number(rawCursor);
      if (!Number.isSafeInteger(cursor) || cursor < 0) {
        return new Response(JSON.stringify({ error: "invalid_request" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        });
      }
      hasCursor = true;
    }

    const sid = request.headers.get(SESSION_HEADER);
    const head = this.meta("rev");
    const paused = this.readSetting("agentsPaused") === true;
    const replay: AgentEvent[] = [];
    if (hasCursor && cursor < head) {
      let c = cursor;
      for (let page = 0; page < 5 && c < head; page++) {
        const batch = this.agentEvents(c, 500);
        replay.push(...batch.events);
        if (batch.nextSince <= c) break;
        c = batch.nextSince;
      }
    }

    if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1], sid ? ["agent-events", sessionTag(sid)] : ["agent-events"]);
      pair[1].send(JSON.stringify({ type: "ready", head, paused }));
      for (const ev of replay) {
        pair[1].send(JSON.stringify({ type: "event", event: ev }));
      }
      return new Response(null, { status: 101, webSocket: pair[0] });
    }

    const encoder = new TextEncoder();
    const subscribers = this.sseSubscribers;
    const heartbeatMs = this.sseHeartbeatMs;
    const initialLastRev = replay.length > 0 ? replay[replay.length - 1].rev : (hasCursor ? cursor : head);
    let cleanupRef: (() => void) | null = null;

    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        let closed = false;
        let timer: ReturnType<typeof setInterval> | null = null;

        const detach = () => {
          if (closed) return;
          closed = true;
          if (timer !== null) {
            clearInterval(timer);
            timer = null;
          }
          subscribers.delete(sub);
        };
        cleanupRef = detach;

        const sub = {
          lastRev: initialLastRev,
          sid,
          send(chunk: string): boolean {
            if (closed) return false;
            try {
              controller.enqueue(encoder.encode(chunk));
              return true;
            } catch {
              detach();
              return false;
            }
          },
          close(): void {
            if (closed) return;
            detach();
            try { controller.close(); } catch { /* already closed */ }
          },
        };

        sub.send(formatSseReady(head, paused));
        for (const ev of replay) {
          if (!sub.send(formatSseEvent(ev))) return;
        }
        subscribers.add(sub);
        timer = setInterval(() => {
          sub.send(formatSseKeepalive());
        }, heartbeatMs);
        request.signal?.addEventListener("abort", () => sub.close(), { once: true });
      },
      cancel() {
        cleanupRef?.();
      },
    });

    return new Response(stream, {
      status: 200,
      headers: {
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-cache, no-transform",
        Connection: "keep-alive",
        "X-Accel-Buffering": "no",
      },
    });
  }

  override async webSocketMessage(): Promise<void> {
    // The socket carries nudges / events only; clients send nothing but pings.
  }

  override async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    try { ws.close(code, "closing"); } catch { /* already closed */ }
  }

  private broadcast(rev: number): void {
    const msg = JSON.stringify({ rev });
    const agentSockets = new Set(this.ctx.getWebSockets("agent-events"));
    for (const ws of this.ctx.getWebSockets()) {
      if (agentSockets.has(ws)) continue;
      try { ws.send(msg); } catch { /* dead socket; the runtime reaps it */ }
    }
  }

  // ---- daily housekeeping ----

  override async alarm(): Promise<void> {
    const now = Date.now();
    const tombstoneCutoff = new Date(now - TOMBSTONE_TTL_MS).toISOString();
    const revBefore = this.meta("rev");
    this.ctx.storage.transactionSync(() => {
      // A Do nobody ended (docs/DO_SPEC.md §2.2).
      this.resolveDo("system:housekeeping", new Date(now).toISOString());
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
      this.sql.exec("DELETE FROM dismissed_refs WHERE at < ?", new Date(now - DISMISSED_REF_TTL_MS).toISOString());
      this.sql.exec("DELETE FROM client_ops WHERE at < ?", now - CLIENT_OP_TTL_MS);
      this.sql.exec("DELETE FROM changes WHERE at < ?", new Date(now - CHANGE_LOG_TTL_MS).toISOString());
      this.sessions.purge(now);
      this.sql.exec("DELETE FROM devices WHERE sid NOT IN (SELECT sid FROM sessions WHERE sid IS NOT NULL)");
      this.sql.exec("DELETE FROM connections WHERE lastUsed < ?", now - CONNECTION_TTL_MS);
      // Day and month counters: two months covers the current month.
      this.sql.exec("DELETE FROM usage WHERE updatedAt < ?", now - 62 * DAY_MS);
    });
    if (this.meta("rev") > revBefore) this.broadcast(this.meta("rev"));
    await this.ctx.storage.setAlarm(now + DAY_MS);
    // A failed drain sets its own, earlier alarm.
    await this.drainShares();
  }
}
