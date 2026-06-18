import { rateLimited } from "./attest";
import type { CurrentUser, Env } from "./env";

// Feature-request roadmap board. Anyone (genuine app + iCloud) can submit and
// upvote; maintainers move status and lock threads. Authorship is NOT exposed —
// only counts and the author's role on comments — so the board stays anonymous.

type FeatureStatus =
  | "pending" | "approved" | "planned" | "in_progress" | "shipped" | "rejected" | "merged";

interface FeatureRow {
  id: string;
  title: string;
  detail: string | null;
  status: FeatureStatus;
  created_at: string;
  updated_at: string;
  maintainer_note: string | null;
  is_locked: number;
  vote_count: number;
  comment_count: number;
  has_voted: number;
}

interface CommentRow {
  id: string;
  author_role: CurrentUser["role"];
  body: string;
  created_at: string;
  is_pinned: number;
}

function canModerate(user: CurrentUser): boolean {
  return user.role === "maintainer" || user.role === "moderator";
}

// Dead states are hidden from regular users; maintainers see everything.
const VISIBLE_STATES = "('pending','approved','planned','in_progress','shipped')";

export async function listFeatures(env: Env, user: CurrentUser): Promise<Record<string, unknown>> {
  const statusFilter = canModerate(user) ? "" : `where f.status in ${VISIBLE_STATES}`;
  const rows = await env.DB.prepare(`
    select f.id, f.title, f.detail, f.status, f.created_at, f.updated_at,
           f.maintainer_note, f.is_locked,
           (select count(*) from feature_vote v where v.request_id = f.id) as vote_count,
           (select count(*) from feature_comment c where c.request_id = f.id and c.status = 'visible') as comment_count,
           (select count(*) from feature_vote v where v.request_id = f.id and v.user_hash = ?) as has_voted
    from feature_request f
    ${statusFilter}
    order by vote_count desc, f.created_at desc
    limit 200
  `).bind(user.userHash).all<FeatureRow>();
  return { features: (rows.results ?? []).map(featureJSON) };
}

export async function getFeature(
  env: Env,
  user: CurrentUser,
  id: string,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  const feature = await findFeature(env, user, id);
  if (!feature) return { ok: false, status: 404, error: "feature_not_found" };
  const comments = await env.DB.prepare(`
    select id, author_role, body, created_at, is_pinned
    from feature_comment
    where request_id = ? and status = 'visible'
    order by is_pinned desc, created_at asc
    limit 500
  `).bind(id).all<CommentRow>();
  return {
    ok: true,
    body: {
      feature: featureJSON(feature),
      comments: (comments.results ?? []).map(commentJSON),
    },
  };
}

export async function createFeature(
  env: Env,
  user: CurrentUser,
  input: unknown,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  if (await rateLimited(env, `feature:create:${user.userHash}`, 10, 3600)) {
    return { ok: false, status: 429, error: "rate_limited" };
  }
  if (!isObject(input)) return { ok: false, status: 400, error: "bad_request" };
  const title = cleanString(input.title);
  const detail = cleanString(input.detail);
  if (!title || title.length < 3 || title.length > 120) return { ok: false, status: 400, error: "bad_title" };
  if (detail && detail.length > 4000) return { ok: false, status: 400, error: "bad_detail" };

  const id = crypto.randomUUID();
  await env.DB.prepare(`
    insert into feature_request (id, author_hash, title, detail) values (?, ?, ?, ?)
  `).bind(id, user.userHash, title, detail).run();
  // Author implicitly upvotes their own request.
  await env.DB.prepare(`
    insert into feature_vote (request_id, user_hash) values (?, ?) on conflict do nothing
  `).bind(id, user.userHash).run();

  return await getFeature(env, user, id);
}

export async function setVote(
  env: Env,
  user: CurrentUser,
  id: string,
  voted: boolean,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  const feature = await findFeature(env, user, id);
  if (!feature) return { ok: false, status: 404, error: "feature_not_found" };
  if (voted) {
    await env.DB.prepare(`
      insert into feature_vote (request_id, user_hash) values (?, ?) on conflict do nothing
    `).bind(id, user.userHash).run();
  } else {
    await env.DB.prepare(`
      delete from feature_vote where request_id = ? and user_hash = ?
    `).bind(id, user.userHash).run();
  }
  return await getFeature(env, user, id);
}

export async function addComment(
  env: Env,
  user: CurrentUser,
  id: string,
  input: unknown,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  if (await rateLimited(env, `feature:comment:${user.userHash}`, 60, 3600)) {
    return { ok: false, status: 429, error: "rate_limited" };
  }
  const feature = await findFeature(env, user, id);
  if (!feature) return { ok: false, status: 404, error: "feature_not_found" };
  if (feature.is_locked === 1 && !canModerate(user)) {
    return { ok: false, status: 409, error: "thread_locked" };
  }
  if (!isObject(input)) return { ok: false, status: 400, error: "bad_request" };
  const body = cleanString(input.body);
  if (!body || body.length > 2000) return { ok: false, status: 400, error: "bad_body" };

  await env.DB.prepare(`
    insert into feature_comment (id, request_id, author_hash, author_role, body)
    values (?, ?, ?, ?, ?)
  `).bind(crypto.randomUUID(), id, user.userHash, user.role, body).run();
  await env.DB.prepare(`
    update feature_request set updated_at = datetime('now') where id = ?
  `).bind(id).run();

  return await getFeature(env, user, id);
}

export async function updateFeature(
  env: Env,
  user: CurrentUser,
  id: string,
  input: unknown,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  if (!canModerate(user)) return { ok: false, status: 403, error: "forbidden" };
  const feature = await findFeature(env, user, id);
  if (!feature) return { ok: false, status: 404, error: "feature_not_found" };
  if (!isObject(input)) return { ok: false, status: 400, error: "bad_request" };

  const sets: string[] = [];
  const binds: unknown[] = [];
  if (input.status !== undefined) {
    const status = parseStatus(input.status);
    if (!status) return { ok: false, status: 400, error: "bad_status" };
    sets.push("status = ?"); binds.push(status);
  }
  if (input.maintainerNote !== undefined) {
    const note = cleanString(input.maintainerNote);
    if (note && note.length > 2000) return { ok: false, status: 400, error: "bad_note" };
    sets.push("maintainer_note = ?"); binds.push(note);
  }
  if (input.isLocked !== undefined) {
    sets.push("is_locked = ?"); binds.push(input.isLocked === true ? 1 : 0);
  }
  if (!sets.length) return { ok: false, status: 400, error: "no_fields" };

  binds.push(id);
  await env.DB.prepare(`
    update feature_request set ${sets.join(", ")}, updated_at = datetime('now') where id = ?
  `).bind(...binds).run();

  return await getFeature(env, user, id);
}

async function findFeature(env: Env, user: CurrentUser, id: string): Promise<FeatureRow | null> {
  const statusFilter = canModerate(user) ? "" : `and f.status in ${VISIBLE_STATES}`;
  return await env.DB.prepare(`
    select f.id, f.title, f.detail, f.status, f.created_at, f.updated_at,
           f.maintainer_note, f.is_locked,
           (select count(*) from feature_vote v where v.request_id = f.id) as vote_count,
           (select count(*) from feature_comment c where c.request_id = f.id and c.status = 'visible') as comment_count,
           (select count(*) from feature_vote v where v.request_id = f.id and v.user_hash = ?) as has_voted
    from feature_request f
    where f.id = ? ${statusFilter}
    limit 1
  `).bind(user.userHash, id).first<FeatureRow>();
}

function featureJSON(row: FeatureRow): Record<string, unknown> {
  return {
    id: row.id,
    title: row.title,
    detail: row.detail,
    status: row.status,
    maintainerNote: row.maintainer_note,
    isLocked: row.is_locked === 1,
    voteCount: row.vote_count,
    commentCount: row.comment_count,
    hasVoted: row.has_voted > 0,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function commentJSON(row: CommentRow): Record<string, unknown> {
  return {
    id: row.id,
    authorRole: row.author_role,
    body: row.body,
    isPinned: row.is_pinned === 1,
    createdAt: row.created_at,
  };
}

function parseStatus(value: unknown): FeatureStatus | null {
  const all: FeatureStatus[] = ["pending", "approved", "planned", "in_progress", "shipped", "rejected", "merged"];
  return all.includes(value as FeatureStatus) ? (value as FeatureStatus) : null;
}

function cleanString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "").trim();
  return trimmed.length ? trimmed : null;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
