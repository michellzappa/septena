import { rateLimited } from "./attest";
import type { CurrentUser, Env } from "./env";

type TicketStatus = "open" | "waiting_on_user" | "waiting_on_maintainer" | "closed";
type TicketCategory = "bug" | "account" | "data" | "idea" | "other";

interface TicketRow {
  id: string;
  created_at: string;
  updated_at: string;
  last_message_at: string;
  status: TicketStatus;
  category: TicketCategory;
  subject: string;
  app_version: string | null;
  build: string | null;
  platform: string | null;
  os_version: string | null;
  device_model: string | null;
  app_locale: string | null;
}

interface MessageRow {
  id: string;
  ticket_id: string;
  author_role: CurrentUser["role"];
  body: string;
  is_internal: number;
  created_at: string;
}

export async function listSupportTickets(env: Env, user: CurrentUser): Promise<Record<string, unknown>> {
  const where = canModerate(user) ? "" : "where user_hash = ?";
  const query = `
    select id, created_at, updated_at, last_message_at, status, category, subject,
           app_version, build, platform, os_version, device_model, app_locale
    from support_ticket
    ${where}
    order by last_message_at desc
    limit 100
  `;
  const stmt = env.DB.prepare(query);
  const result = canModerate(user)
    ? await stmt.all<TicketRow>()
    : await stmt.bind(user.userHash).all<TicketRow>();
  return { tickets: (result.results ?? []).map(ticketJSON) };
}

export async function getSupportTicket(
  env: Env,
  user: CurrentUser,
  ticketID: string,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  const ticket = await findTicket(env, user, ticketID);
  if (!ticket) return { ok: false, status: 404, error: "ticket_not_found" };

  const internalClause = canModerate(user) ? "" : "and is_internal = 0";
  const messages = await env.DB.prepare(`
    select id, ticket_id, author_role, body, is_internal, created_at
    from support_message
    where ticket_id = ? ${internalClause}
    order by created_at asc
  `).bind(ticketID).all<MessageRow>();

  return {
    ok: true,
    body: {
      ticket: ticketJSON(ticket),
      messages: (messages.results ?? []).map(messageJSON),
    },
  };
}

export async function createSupportTicket(
  env: Env,
  user: CurrentUser,
  input: unknown,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  if (await rateLimited(env, `support:create:${user.userHash}`, 5, 3600)) {
    return { ok: false, status: 429, error: "rate_limited" };
  }
  if (!isObject(input)) return { ok: false, status: 400, error: "bad_ticket" };
  const category = parseCategory(input.category);
  const subject = cleanString(input.subject);
  const body = cleanString(input.body);
  if (!category) return { ok: false, status: 400, error: "bad_category" };
  if (!subject || subject.length < 3 || subject.length > 140) {
    return { ok: false, status: 400, error: "bad_subject" };
  }
  if (!body || body.length > 4000) return { ok: false, status: 400, error: "bad_body" };

  const meta = isObject(input.metadata) ? input.metadata : {};
  const ticketID = crypto.randomUUID();
  const messageID = crypto.randomUUID();
  const nextStatus: TicketStatus = canModerate(user) ? "waiting_on_user" : "waiting_on_maintainer";
  await env.DB.batch([
    env.DB.prepare(`
      insert into support_ticket (
        id, user_hash, status, category, subject,
        app_version, build, platform, os_version, device_model, app_locale
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      ticketID,
      user.userHash,
      nextStatus,
      category,
      subject,
      shortString(meta.appVersion, 80),
      shortString(meta.build, 40),
      shortString(meta.platform, 40),
      shortString(meta.osVersion, 80),
      shortString(meta.deviceModel, 120),
      shortString(meta.appLocale, 40),
    ),
    env.DB.prepare(`
      insert into support_message (id, ticket_id, author_hash, author_role, body)
      values (?, ?, ?, ?, ?)
    `).bind(messageID, ticketID, user.userHash, user.role, body),
  ]);

  return await getSupportTicket(env, user, ticketID);
}

export async function postSupportMessage(
  env: Env,
  user: CurrentUser,
  ticketID: string,
  input: unknown,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  if (await rateLimited(env, `support:message:${user.userHash}`, 30, 3600)) {
    return { ok: false, status: 429, error: "rate_limited" };
  }
  const ticket = await findTicket(env, user, ticketID);
  if (!ticket) return { ok: false, status: 404, error: "ticket_not_found" };
  if (ticket.status === "closed" && !canModerate(user)) {
    return { ok: false, status: 409, error: "ticket_closed" };
  }
  if (!isObject(input)) return { ok: false, status: 400, error: "bad_message" };
  const body = cleanString(input.body);
  if (!body || body.length > 4000) return { ok: false, status: 400, error: "bad_body" };
  const isInternal = canModerate(user) && input.isInternal === true;
  const nextStatus: TicketStatus = canModerate(user) ? "waiting_on_user" : "waiting_on_maintainer";

  await env.DB.batch([
    env.DB.prepare(`
      insert into support_message (id, ticket_id, author_hash, author_role, body, is_internal)
      values (?, ?, ?, ?, ?, ?)
    `).bind(crypto.randomUUID(), ticketID, user.userHash, user.role, body, isInternal ? 1 : 0),
    env.DB.prepare(`
      update support_ticket
      set status = ?, updated_at = datetime('now'), last_message_at = datetime('now')
      where id = ?
    `).bind(nextStatus, ticketID),
  ]);

  return await getSupportTicket(env, user, ticketID);
}

async function findTicket(env: Env, user: CurrentUser, ticketID: string): Promise<TicketRow | null> {
  const ownerClause = canModerate(user) ? "" : "and user_hash = ?";
  const stmt = env.DB.prepare(`
    select id, created_at, updated_at, last_message_at, status, category, subject,
           app_version, build, platform, os_version, device_model, app_locale
    from support_ticket
    where id = ? ${ownerClause}
    limit 1
  `);
  return canModerate(user)
    ? await stmt.bind(ticketID).first<TicketRow>()
    : await stmt.bind(ticketID, user.userHash).first<TicketRow>();
}

function canModerate(user: CurrentUser): boolean {
  return user.role === "maintainer" || user.role === "moderator";
}

function ticketJSON(row: TicketRow): Record<string, unknown> {
  return {
    id: row.id,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    lastMessageAt: row.last_message_at,
    status: row.status,
    category: row.category,
    subject: row.subject,
    metadata: {
      appVersion: row.app_version,
      build: row.build,
      platform: row.platform,
      osVersion: row.os_version,
      deviceModel: row.device_model,
      appLocale: row.app_locale,
    },
  };
}

function messageJSON(row: MessageRow): Record<string, unknown> {
  return {
    id: row.id,
    ticketID: row.ticket_id,
    authorRole: row.author_role,
    body: row.body,
    isInternal: row.is_internal === 1,
    createdAt: row.created_at,
  };
}

function parseCategory(value: unknown): TicketCategory | null {
  if (value === "bug" || value === "account" || value === "data" || value === "idea" || value === "other") {
    return value;
  }
  return null;
}

function cleanString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "").trim();
  return trimmed.length ? trimmed : null;
}

function shortString(value: unknown, max: number): string | null {
  const cleaned = cleanString(value);
  if (!cleaned) return null;
  return cleaned.slice(0, max);
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
