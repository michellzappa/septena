// Support conversations (ADR 0054, docs/SUPPORT_SPEC.md §5). One object for
// every sender: support volume is small, and one writer makes `message_id`
// idempotency and the retry sweep simple. A conversation is the rows of one
// `reporter_ref` (`user:<id>` or `install:<sha256 of the support key>`).

import { DurableObject } from "cloudflare:workers";
import type { Env } from "../env.js";

export const SUPPORT_STORE_NAME = "support";
/** Rows older than this are deleted by the cron (spec §5, Retention). */
export const SUPPORT_RETENTION_MS = 365 * 86_400_000;

export type SupportDirection = "in" | "out";
export type SupportState = "pending" | "sent";

export interface SupportMessage {
  id: string;
  direction: SupportDirection;
  text: string;
  authorName: string | null;
  createdAt: number;
  readAt: number | null;
  state: SupportState;
}

/** What a pending row needs to be sent to Starlings again. */
export interface PendingMessage {
  id: string;
  reporterRef: string;
  text: string;
  email: string | null;
  name: string | null;
  diagnostics: string | null;
}

export interface InboundInput {
  id: string;
  reporterRef: string;
  text: string;
  email: string | null;
  name: string | null;
  diagnostics: string | null;
  now: number;
}

type Row = {
  id: string;
  reporter_ref: string;
  direction: SupportDirection;
  text: string;
  email: string | null;
  name: string | null;
  diagnostics: string | null;
  author_name: string | null;
  state: SupportState;
  created_at: number;
  read_at: number | null;
};

function toMessage(row: Row): SupportMessage {
  return {
    id: row.id,
    direction: row.direction,
    text: row.text,
    authorName: row.author_name,
    createdAt: row.created_at,
    readAt: row.read_at,
    state: row.state,
  };
}

export function supportStoreFor(env: Env): DurableObjectStub<SupportStore> | null {
  if (!env.SUPPORT_STORE) return null;
  return env.SUPPORT_STORE.get(env.SUPPORT_STORE.idFromName(SUPPORT_STORE_NAME));
}

export class SupportStore extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    ctx.blockConcurrencyWhile(async () => this.migrate());
  }

  private migrate(): void {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS support_messages (
        id           TEXT PRIMARY KEY,
        reporter_ref TEXT NOT NULL,
        direction    TEXT NOT NULL,
        text         TEXT NOT NULL,
        email        TEXT,
        name         TEXT,
        diagnostics  TEXT,
        author_name  TEXT,
        state        TEXT NOT NULL,
        created_at   INTEGER NOT NULL,
        read_at      INTEGER
      );
      CREATE INDEX IF NOT EXISTS support_messages_ref ON support_messages (reporter_ref, created_at);
      CREATE INDEX IF NOT EXISTS support_messages_state ON support_messages (state, created_at);
      CREATE TABLE IF NOT EXISTS support_aliases (
        from_ref TEXT PRIMARY KEY,
        to_ref   TEXT NOT NULL
      );
    `);
  }

  private row(id: string): Row | null {
    return this.sql.exec<Row>("SELECT * FROM support_messages WHERE id = ?", id).toArray()[0] ?? null;
  }

  /** Stores a sender's message. A repeated id returns the stored row and adds nothing. */
  addInbound(input: InboundInput): { message: SupportMessage; created: boolean } | { conflict: true } {
    const existing = this.row(input.id);
    // Another sender's id is a conflict, never a read of their message.
    if (existing) return existing.reporter_ref === input.reporterRef ? { message: toMessage(existing), created: false } : { conflict: true };
    this.sql.exec(
      `INSERT INTO support_messages (id, reporter_ref, direction, text, email, name, diagnostics, author_name, state, created_at, read_at)
       VALUES (?, ?, 'in', ?, ?, ?, ?, NULL, 'pending', ?, ?)`,
      input.id, input.reporterRef, input.text, input.email, input.name, input.diagnostics, input.now, input.now,
    );
    return { message: toMessage(this.row(input.id)!), created: true };
  }

  /** Counts the sender's messages since `since`, for the rate limit. */
  countInboundSince(reporterRef: string, since: number): number {
    const row = this.sql.exec<{ n: number }>(
      "SELECT COUNT(*) AS n FROM support_messages WHERE reporter_ref = ? AND direction = 'in' AND created_at >= ?",
      reporterRef, since,
    ).toArray()[0];
    return Number(row?.n ?? 0);
  }

  markSent(id: string): void {
    this.sql.exec("UPDATE support_messages SET state = 'sent' WHERE id = ? AND state = 'pending'", id);
  }

  /** The conversation, oldest first, and how many replies are unread. */
  conversation(reporterRef: string): { messages: SupportMessage[]; unread: number } {
    const rows = this.sql.exec<Row>(
      "SELECT * FROM support_messages WHERE reporter_ref = ? ORDER BY created_at ASC, id ASC",
      reporterRef,
    ).toArray();
    const messages = rows.map(toMessage);
    return { messages, unread: messages.filter((m) => m.direction === "out" && m.readAt === null).length };
  }

  markRead(reporterRef: string, now: number): void {
    this.sql.exec(
      "UPDATE support_messages SET read_at = ? WHERE reporter_ref = ? AND direction = 'out' AND read_at IS NULL",
      now, reporterRef,
    );
  }

  /**
   * Stores a member's reply. A repeated id adds nothing. Returns the address
   * to notify (the sender's latest email), or null when there is none or the
   * reply was a repeat.
   */
  addReply(input: { id: string; reporterRef: string; text: string; authorName: string; now: number }): { created: boolean; email: string | null } {
    if (this.row(input.id)) return { created: false, email: null };
    // Starlings keys its thread by the ref it was first sent: a reply to a
    // conversation that moved to an account lands on the account.
    const ref = this.resolve(input.reporterRef);
    this.sql.exec(
      `INSERT INTO support_messages (id, reporter_ref, direction, text, email, name, diagnostics, author_name, state, created_at, read_at)
       VALUES (?, ?, 'out', ?, NULL, NULL, NULL, ?, 'sent', ?, NULL)`,
      input.id, ref, input.text, input.authorName, input.now,
    );
    const latest = this.sql.exec<{ email: string | null }>(
      "SELECT email FROM support_messages WHERE reporter_ref = ? AND direction = 'in' AND email IS NOT NULL ORDER BY created_at DESC LIMIT 1",
      ref,
    ).toArray()[0];
    return { created: true, email: latest?.email ?? null };
  }

  /** Messages Starlings has not taken yet, oldest first. */
  pending(limit: number): PendingMessage[] {
    return this.sql.exec<Row>(
      "SELECT * FROM support_messages WHERE direction = 'in' AND state = 'pending' ORDER BY created_at ASC LIMIT ?",
      limit,
    ).toArray().map((row) => ({
      id: row.id, reporterRef: row.reporter_ref, text: row.text, email: row.email, name: row.name, diagnostics: row.diagnostics,
    }));
  }

  /** A signed-out conversation joins the account at sign-in (spec §5). */
  moveConversation(from: string, to: string): number {
    if (from === to) return 0;
    const moved = this.sql.exec("UPDATE support_messages SET reporter_ref = ? WHERE reporter_ref = ?", to, from).rowsWritten;
    if (moved > 0) {
      this.sql.exec("INSERT OR REPLACE INTO support_aliases (from_ref, to_ref) VALUES (?, ?)", from, to);
    }
    return moved;
  }

  private resolve(ref: string): string {
    return this.sql.exec<{ to_ref: string }>("SELECT to_ref FROM support_aliases WHERE from_ref = ?", ref).toArray()[0]?.to_ref ?? ref;
  }

  purgeBefore(cutoff: number): number {
    return this.sql.exec("DELETE FROM support_messages WHERE created_at < ?", cutoff).rowsWritten;
  }
}
