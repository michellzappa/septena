import type { Context } from "hono";
import type { Env } from "../env.js";
import { logEvent, randomId } from "../util.js";
import { accountStoreFor } from "../store/AccountStore.js";
import { projectStoreFor } from "../store/ProjectStore.js";
import {
  MAX_AVATAR_PHOTO_BYTES,
  avatarPhotoKey,
  defaultAvatar,
  publicAvatar,
  sniffAvatarImage,
  zAvatarPatchBody,
  type Avatar,
  type StoredAvatar,
} from "../store/avatar.js";
import { storeFor } from "./session.js";

// The account and its avatar (#857, src/store/avatar.ts). Mounted under
// /v1/account behind requireUser. Every plan has an avatar, the free one too.
//
// The client crops the photo to a square of `surfaces.json` `avatar.photoSize`
// pixels before it uploads. The server checks the type and the size and keeps
// one object per account: a new photo, an emoji, initials or DELETE remove the
// one before. Reads go to the owner here and to the members of a shared
// project through `GET /v1/shares/:id/members/:member/avatar` (shares.ts).

type Ctx = Context<{ Bindings: Env; Variables: { userId: string } }>;

export { zAvatarPatchBody };

const noStore = { "Cache-Control": "no-store" };

function accounts(c: Ctx) {
  const store = accountStoreFor(c.env);
  if (!store) throw new Error("ACCOUNT_STORE is not bound");
  return store;
}

/// Shows the avatar in every shared project of the account. A failure leaves
/// the old avatar there until the next change; it never fails the write.
export async function spreadAvatar(env: Env, userId: string, avatar: Avatar): Promise<void> {
  try {
    const shares = await storeFor(env, userId).listShares();
    await Promise.all(shares.map((s) => projectStoreFor(env, s.id).setMemberAvatar(userId, avatar)));
  } catch (e) {
    logEvent("avatar_spread_failed", { userId, error: String(e) });
  }
}

/// Saves `next` and cleans up the photo it let go of.
async function save(c: Ctx, next: StoredAvatar): Promise<Response> {
  const userId = c.get("userId");
  const result = await accounts(c).setAvatar(userId, next);
  if (result.replacedPhotoKey) await c.env.ATTACHMENTS.delete(result.replacedPhotoKey);
  const avatar = publicAvatar(result.avatar);
  if (result.applied) c.executionCtx.waitUntil(spreadAvatar(c.env, userId, avatar));
  return c.json({ avatar, applied: result.applied }, 200, noStore);
}

export async function getAccount(c: Ctx) {
  const userId = c.get("userId");
  const avatar = publicAvatar(await accounts(c).getAvatar(userId));
  return c.json({ userId, avatar }, 200, noStore);
}

/// Initials or an emoji, from JSON. These also work offline: the client
/// keeps the edit and sends it later with the time it was made.
export async function patchAvatar(c: Ctx) {
  const parsed = zAvatarPatchBody.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "invalid_request", issues: parsed.error.issues.slice(0, 5) }, 400);
  const input = parsed.data;
  const current = await accounts(c).getAvatar(c.get("userId"));
  const initials = input.initials === undefined ? current.initials : input.initials || undefined;
  const next: StoredAvatar = {
    kind: input.kind,
    color: input.color ?? current.color,
    updatedAt: Math.min(input.updatedAt ?? Date.now(), Date.now()),
  };
  if (initials) next.initials = initials;
  if (input.kind === "emoji") next.emoji = input.emoji;
  return save(c, next);
}

/// A photo: the bytes are the body, JPEG, PNG or HEIC, up to 5 MB.
export async function putAvatarPhoto(c: Ctx) {
  const declared = c.req.header("Content-Length");
  if (declared !== undefined && Number(declared) > MAX_AVATAR_PHOTO_BYTES) {
    return c.json({ error: "too_large", max: MAX_AVATAR_PHOTO_BYTES }, 413);
  }
  const bytes = new Uint8Array(await c.req.arrayBuffer());
  if (bytes.byteLength > MAX_AVATAR_PHOTO_BYTES) return c.json({ error: "too_large", max: MAX_AVATAR_PHOTO_BYTES }, 413);
  if (bytes.byteLength === 0) return c.json({ error: "empty_body" }, 400);
  const contentType = sniffAvatarImage(bytes);
  if (!contentType) return c.json({ error: "unsupported_type", accepted: ["image/jpeg", "image/png", "image/heic"] }, 415);
  const userId = c.get("userId");
  const key = avatarPhotoKey(userId, `p${randomId(12)}`);
  await c.env.ATTACHMENTS.put(key, bytes, { httpMetadata: { contentType } });
  const current = await accounts(c).getAvatar(userId);
  const next: StoredAvatar = { kind: "photo", color: current.color, photoKey: key, updatedAt: Date.now() };
  if (current.initials) next.initials = current.initials;
  return save(c, next);
}

/// Back to initials. The photo object goes.
export async function deleteAvatar(c: Ctx) {
  const userId = c.get("userId");
  const current = await accounts(c).getAvatar(userId);
  const next: StoredAvatar = { ...defaultAvatar(userId), color: current.color, updatedAt: Date.now() };
  if (current.initials) next.initials = current.initials;
  return save(c, next);
}

/// Streams the photo of `userId`, or 404 when the avatar is not a photo.
export async function avatarPhotoResponse(env: Env, userId: string): Promise<Response> {
  const store = accountStoreFor(env);
  const avatar = store ? await store.getAvatar(userId) : null;
  const obj = avatar?.kind === "photo" && avatar.photoKey ? await env.ATTACHMENTS.get(avatar.photoKey) : null;
  if (!obj) return Response.json({ error: "not_found" }, { status: 404, headers: noStore });
  return new Response(obj.body, {
    headers: {
      "Content-Type": obj.httpMetadata?.contentType ?? "application/octet-stream",
      "Content-Length": String(obj.size),
      // The URL carries the photo id (`?v=`), so a new photo is a new URL.
      "Cache-Control": "private, max-age=86400",
    },
  });
}

export async function getOwnAvatarPhoto(c: Ctx) {
  return avatarPhotoResponse(c.env, c.get("userId"));
}
