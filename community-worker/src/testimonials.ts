import { rateLimited } from "./attest";
import type { CurrentUser, Env } from "./env";

// Testimonials — one short quote (+ optional 1–5 rating) per user. Editable, but
// any edit returns it to 'pending' so nothing unmoderated reaches the website.
// Author identity rides the is_public profile gate, like the roadmap.

interface TestimonialRow {
  id: string;
  body: string;
  rating: number | null;
  status: string;
  is_featured: number;
  created_at: string;
  updated_at: string;
  author_username: string | null;
  author_display_name: string | null;
}

function canModerate(user: CurrentUser): boolean {
  return user.role === "maintainer" || user.role === "moderator";
}

function authorJSON(username: string | null, displayName: string | null): Record<string, unknown> | null {
  if (!username && !displayName) return null;
  return { username, displayName };
}

function testimonialJSON(row: TestimonialRow): Record<string, unknown> {
  return {
    id: row.id,
    body: row.body,
    rating: row.rating,
    status: row.status,
    isFeatured: row.is_featured === 1,
    author: authorJSON(row.author_username, row.author_display_name),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

const SELECT_COLS = `
  t.id, t.body, t.rating, t.status, t.is_featured, t.created_at, t.updated_at,
  ap.username as author_username, ap.display_name as author_display_name
`;
const JOIN_AUTHOR = `left join user_profile ap on ap.user_hash = t.user_hash and ap.is_public = 1`;

/// The caller's own testimonial (any status), or null.
export async function getMyTestimonial(env: Env, user: CurrentUser): Promise<Record<string, unknown>> {
  const row = await env.DB.prepare(`
    select ${SELECT_COLS} from testimonial t ${JOIN_AUTHOR} where t.user_hash = ? limit 1
  `).bind(user.userHash).first<TestimonialRow>();
  return { testimonial: row ? testimonialJSON(row) : null };
}

export async function putMyTestimonial(
  env: Env,
  user: CurrentUser,
  input: unknown,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  if (await rateLimited(env, `testimonial:put:${user.userHash}`, 20, 3600)) {
    return { ok: false, status: 429, error: "rate_limited" };
  }
  if (!isObject(input)) return { ok: false, status: 400, error: "bad_request" };
  const body = cleanString(input.body);
  if (!body || body.length < 10 || body.length > 500) return { ok: false, status: 400, error: "bad_body" };
  let rating: number | null = null;
  if (input.rating !== undefined && input.rating !== null) {
    const n = Number(input.rating);
    if (!Number.isInteger(n) || n < 1 || n > 5) return { ok: false, status: 400, error: "bad_rating" };
    rating = n;
  }

  // Upsert keyed on user_hash → one per user. Any write (re)sets status to
  // pending so edited content is re-reviewed before it can show publicly.
  await env.DB.prepare(`
    insert into testimonial (id, user_hash, body, rating, status, updated_at)
    values (?, ?, ?, ?, 'pending', datetime('now'))
    on conflict(user_hash) do update set
      body = excluded.body,
      rating = excluded.rating,
      status = 'pending',
      is_featured = 0,
      updated_at = datetime('now')
  `).bind(crypto.randomUUID(), user.userHash, body, rating).run();

  return { ok: true, body: await getMyTestimonial(env, user) };
}

export async function deleteMyTestimonial(env: Env, user: CurrentUser): Promise<Record<string, unknown>> {
  await env.DB.prepare(`delete from testimonial where user_hash = ?`).bind(user.userHash).run();
  return { testimonial: null };
}

/// Authed list: approved testimonials for everyone; maintainers see all states.
export async function listTestimonials(env: Env, user: CurrentUser): Promise<Record<string, unknown>> {
  const statusFilter = canModerate(user) ? "" : `where t.status = 'approved'`;
  const rows = await env.DB.prepare(`
    select ${SELECT_COLS} from testimonial t ${JOIN_AUTHOR}
    ${statusFilter}
    order by t.is_featured desc, t.updated_at desc
    limit 200
  `).all<TestimonialRow>();
  return { testimonials: (rows.results ?? []).map(testimonialJSON) };
}

/// Public website list — approved only, featured first, no auth.
export async function listPublicTestimonials(env: Env): Promise<Record<string, unknown>> {
  const rows = await env.DB.prepare(`
    select ${SELECT_COLS} from testimonial t ${JOIN_AUTHOR}
    where t.status = 'approved'
    order by t.is_featured desc, t.updated_at desc
    limit 200
  `).all<TestimonialRow>();
  return { testimonials: (rows.results ?? []).map(testimonialJSON) };
}

export async function moderateTestimonial(
  env: Env,
  user: CurrentUser,
  id: string,
  input: unknown,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  if (!canModerate(user)) return { ok: false, status: 403, error: "forbidden" };
  if (!isObject(input)) return { ok: false, status: 400, error: "bad_request" };
  const exists = await env.DB.prepare(`select id from testimonial where id = ?`).bind(id).first<{ id: string }>();
  if (!exists) return { ok: false, status: 404, error: "testimonial_not_found" };

  const sets: string[] = [];
  const binds: unknown[] = [];
  if (input.status !== undefined) {
    const status = input.status;
    if (status !== "pending" && status !== "approved" && status !== "hidden") {
      return { ok: false, status: 400, error: "bad_status" };
    }
    sets.push("status = ?"); binds.push(status);
  }
  if (input.isFeatured !== undefined) {
    sets.push("is_featured = ?"); binds.push(input.isFeatured === true ? 1 : 0);
  }
  if (!sets.length) return { ok: false, status: 400, error: "no_fields" };

  binds.push(id);
  await env.DB.prepare(`
    update testimonial set ${sets.join(", ")}, updated_at = datetime('now') where id = ?
  `).bind(...binds).run();

  return { ok: true, body: await listTestimonials(env, user) };
}

function cleanString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "").trim();
  return trimmed.length ? trimmed : null;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
