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
  author_username: string | null;
  author_display_name: string | null;
  author_supporter_tier: string | null;
  author_role: CurrentUser["role"] | null;
}

interface CommentRow {
  id: string;
  parent_id: string | null;
  author_role: CurrentUser["role"];
  body: string;
  created_at: string;
  is_pinned: number;
  status: string;
  author_username: string | null;
  author_display_name: string | null;
  author_supporter_tier: string | null;
}

// Author identity is exposed ONLY for users who opted their profile public
// (the join below is gated on is_public = 1, so non-public authors yield nulls).
// `role` + `supporterTier` ride along so callers can show one consistent member
// badge (maintainer / supporter) beside the name — they're moot without a name,
// so they only travel when there is one.
function authorJSON(
  username: string | null,
  displayName: string | null,
  role: string | null,
  supporterTier: string | null,
): Record<string, unknown> | null {
  if (!username && !displayName) return null;
  return { username, displayName, role: role ?? "user", supporterTier: supporterTier ?? null };
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
           ap.username as author_username, ap.display_name as author_display_name,
           ap.supporter_tier as author_supporter_tier, ai.role as author_role,
           (select count(*) from feature_vote v where v.request_id = f.id) as vote_count,
           (select count(*) from feature_comment c where c.request_id = f.id and c.status = 'visible') as comment_count,
           (select count(*) from feature_vote v where v.request_id = f.id and v.user_hash = ?) as has_voted
    from feature_request f
    left join user_profile ap on ap.user_hash = f.author_hash and ap.is_public = 1
    left join user_identity ai on ai.user_hash = f.author_hash
    ${statusFilter}
    order by vote_count desc, f.created_at desc
    limit 200
  `).bind(user.userHash).all<FeatureRow>();
  return { features: (rows.results ?? []).map(featureJSON) };
}

// Public, unauthenticated board for the website. No iCloud/App Attest identity,
// so there's no per-user `hasVoted` and no comments — read-only counts only.
// Only the moderated states are exposed (raw 'pending' submissions stay private,
// matching what regular users see in-app). Authorship still rides the is_public
// gate, so non-public authors yield nulls exactly as the authed board does.
const PUBLIC_STATES = "('approved','planned','in_progress','shipped')";

export async function listPublicFeatures(env: Env): Promise<Record<string, unknown>> {
  const rows = await env.DB.prepare(`
    select f.id, f.title, f.detail, f.status, f.created_at, f.updated_at,
           f.maintainer_note, f.is_locked,
           ap.username as author_username, ap.display_name as author_display_name,
           ap.supporter_tier as author_supporter_tier, ai.role as author_role,
           (select count(*) from feature_vote v where v.request_id = f.id) as vote_count,
           (select count(*) from feature_comment c where c.request_id = f.id and c.status = 'visible') as comment_count,
           0 as has_voted
    from feature_request f
    left join user_profile ap on ap.user_hash = f.author_hash and ap.is_public = 1
    left join user_identity ai on ai.user_hash = f.author_hash
    where f.status in ${PUBLIC_STATES}
    order by vote_count desc, f.created_at desc
    limit 200
  `).all<FeatureRow>();
  return { features: (rows.results ?? []).map(featureJSON) };
}

export async function getFeature(
  env: Env,
  user: CurrentUser,
  id: string,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  const feature = await findFeature(env, user, id);
  if (!feature) return { ok: false, status: 404, error: "feature_not_found" };
  // Maintainers also see hidden comments (to moderate); deleted are gone for all.
  const commentStates = canModerate(user) ? "('visible','hidden')" : "('visible')";
  const comments = await env.DB.prepare(`
    select c.id, c.parent_id, c.author_role, c.body, c.created_at, c.is_pinned, c.status,
           ap.username as author_username, ap.display_name as author_display_name,
           ap.supporter_tier as author_supporter_tier
    from feature_comment c
    left join user_profile ap on ap.user_hash = c.author_hash and ap.is_public = 1
    where c.request_id = ? and c.status in ${commentStates}
    order by c.is_pinned desc, c.created_at asc
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

  // Optional reply target. Threads are kept one level deep: replying to a reply
  // attaches to its top-level parent so the UI never has to recurse.
  let parentId: string | null = null;
  const requestedParent = typeof input.parentId === "string" ? input.parentId : null;
  if (requestedParent) {
    const parent = await env.DB.prepare(`
      select id, parent_id from feature_comment
      where id = ? and request_id = ? and status = 'visible'
    `).bind(requestedParent, id).first<{ id: string; parent_id: string | null }>();
    if (!parent) return { ok: false, status: 400, error: "bad_parent" };
    parentId = parent.parent_id ?? parent.id;
  }

  await env.DB.prepare(`
    insert into feature_comment (id, request_id, parent_id, author_hash, author_role, body)
    values (?, ?, ?, ?, ?, ?)
  `).bind(crypto.randomUUID(), id, parentId, user.userHash, user.role, body).run();
  await env.DB.prepare(`
    update feature_request set updated_at = datetime('now') where id = ?
  `).bind(id).run();

  return await getFeature(env, user, id);
}

export async function moderateComment(
  env: Env,
  user: CurrentUser,
  featureId: string,
  commentId: string,
  input: unknown,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  if (!canModerate(user)) return { ok: false, status: 403, error: "forbidden" };
  if (!isObject(input)) return { ok: false, status: 400, error: "bad_request" };
  const exists = await env.DB.prepare(`
    select id from feature_comment where id = ? and request_id = ?
  `).bind(commentId, featureId).first<{ id: string }>();
  if (!exists) return { ok: false, status: 404, error: "comment_not_found" };

  const sets: string[] = [];
  const binds: unknown[] = [];
  if (input.status !== undefined) {
    const status = input.status;
    if (status !== "visible" && status !== "hidden" && status !== "deleted") {
      return { ok: false, status: 400, error: "bad_status" };
    }
    sets.push("status = ?"); binds.push(status);
  }
  if (input.isPinned !== undefined) {
    sets.push("is_pinned = ?"); binds.push(input.isPinned === true ? 1 : 0);
  }
  if (!sets.length) return { ok: false, status: 400, error: "no_fields" };

  binds.push(commentId);
  await env.DB.prepare(`
    update feature_comment set ${sets.join(", ")} where id = ?
  `).bind(...binds).run();

  return await getFeature(env, user, featureId);
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
           ap.username as author_username, ap.display_name as author_display_name,
           ap.supporter_tier as author_supporter_tier, ai.role as author_role,
           (select count(*) from feature_vote v where v.request_id = f.id) as vote_count,
           (select count(*) from feature_comment c where c.request_id = f.id and c.status = 'visible') as comment_count,
           (select count(*) from feature_vote v where v.request_id = f.id and v.user_hash = ?) as has_voted
    from feature_request f
    left join user_profile ap on ap.user_hash = f.author_hash and ap.is_public = 1
    left join user_identity ai on ai.user_hash = f.author_hash
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
    author: authorJSON(row.author_username, row.author_display_name, row.author_role, row.author_supporter_tier),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function commentJSON(row: CommentRow): Record<string, unknown> {
  return {
    id: row.id,
    parentId: row.parent_id,
    authorRole: row.author_role,
    author: authorJSON(row.author_username, row.author_display_name, row.author_role, row.author_supporter_tier),
    body: row.body,
    isPinned: row.is_pinned === 1,
    status: row.status,
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
