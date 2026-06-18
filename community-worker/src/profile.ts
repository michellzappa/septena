import type { CurrentUser, Env } from "./env";

export interface ProfileRow {
  username: string | null;
  display_name: string | null;
  avatar_key: string | null;
  bio: string | null;
  is_public: number;
  updated_at: string;
}

export async function profileResponse(env: Env, user: CurrentUser): Promise<Record<string, unknown>> {
  const profile = await ensureProfile(env, user.userHash);
  return {
    user: {
      role: user.role,
      isBanned: user.isBanned,
      userHash: user.userHash,
    },
    profile: publicProfile(profile),
  };
}

export async function updateProfile(
  env: Env,
  user: CurrentUser,
  input: unknown,
): Promise<{ ok: true; body: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  if (!isObject(input)) return { ok: false, status: 400, error: "bad_profile" };
  const username = optionalString(input.username);
  const displayName = optionalString(input.displayName);
  const bio = optionalString(input.bio);
  const isPublic = typeof input.isPublic === "boolean" ? input.isPublic : false;

  const normalizedUsername = username === null ? null : normalizeUsername(username);
  if (normalizedUsername !== null && !/^[a-z0-9_]{2,24}$/.test(normalizedUsername)) {
    return { ok: false, status: 400, error: "bad_username" };
  }
  if (displayName !== null && displayName.length > 80) return { ok: false, status: 400, error: "display_name_too_long" };
  if (bio !== null && bio.length > 280) return { ok: false, status: 400, error: "bio_too_long" };

  try {
    await env.DB.prepare(`
      insert into user_profile (user_hash, username, display_name, bio, is_public, updated_at)
      values (?, ?, ?, ?, ?, datetime('now'))
      on conflict(user_hash) do update set
        username = excluded.username,
        display_name = excluded.display_name,
        bio = excluded.bio,
        is_public = excluded.is_public,
        updated_at = datetime('now')
    `).bind(user.userHash, normalizedUsername, displayName, bio, isPublic ? 1 : 0).run();
  } catch (error) {
    const message = String((error as Error).message ?? error);
    if (message.toLowerCase().includes("unique")) return { ok: false, status: 409, error: "username_taken" };
    throw error;
  }

  return { ok: true, body: await profileResponse(env, user) };
}

async function ensureProfile(env: Env, userHash: string): Promise<ProfileRow> {
  await env.DB.prepare(`
    insert into user_profile (user_hash) values (?)
    on conflict(user_hash) do nothing
  `).bind(userHash).run();
  const row = await env.DB.prepare(`
    select username, display_name, avatar_key, bio, is_public, updated_at
    from user_profile
    where user_hash = ?
  `).bind(userHash).first<ProfileRow>();
  return row ?? {
    username: null,
    display_name: null,
    avatar_key: null,
    bio: null,
    is_public: 0,
    updated_at: new Date().toISOString(),
  };
}

function publicProfile(row: ProfileRow): Record<string, unknown> {
  return {
    username: row.username,
    displayName: row.display_name,
    avatarKey: row.avatar_key,
    bio: row.bio,
    isPublic: row.is_public === 1,
    updatedAt: row.updated_at,
  };
}

function normalizeUsername(value: string): string {
  return value.trim().toLowerCase();
}

function optionalString(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length ? trimmed : null;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
