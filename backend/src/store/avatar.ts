import { z } from "zod";
import { DESIGN_TOKENS, SURFACES_CATALOG } from "../generated/registries.js";

// The account's avatar (#857): a photo, one emoji, or initials on a color.
// AccountStore keeps one row per account. Without a row the avatar is
// initials on a color derived from the user id, so an account that never
// edits it still has one stable color on every device.
//
// The R2 key of a photo (`photoKey`) names the user id, so it stays on the
// server. Clients and other members see `photoId`, the last part of the key,
// which also changes with every new photo.

export const AVATAR_KINDS = ["initials", "emoji", "photo"] as const;
export type AvatarKind = (typeof AVATAR_KINDS)[number];

export const AVATAR_COLOR_IDS: readonly string[] = DESIGN_TOKENS.avatarColors.map((c) => c.id);
export const MAX_AVATAR_PHOTO_BYTES: number = SURFACES_CATALOG.avatar.maxPhotoBytes;
export const MAX_AVATAR_INITIALS: number = SURFACES_CATALOG.avatar.maxInitials;

/// What the server stores.
export interface StoredAvatar {
  kind: AvatarKind;
  color: string;
  initials?: string;
  emoji?: string;
  photoKey?: string;
  updatedAt: number;
}

/// What the owner and the members of a shared project see.
export interface Avatar {
  kind: AvatarKind;
  color: string;
  initials?: string;
  emoji?: string;
  photoId?: string;
  /// 0 for the default avatar, which nobody set.
  updatedAt: number;
}

export function avatarPhotoKey(userId: string, id: string): string {
  return `u/${userId}/avatar/${id}`;
}

/// The color an account has until it picks one: a stable hash of the id.
export function defaultAvatarColor(userId: string): string {
  let h = 2166136261;
  for (let i = 0; i < userId.length; i++) {
    h ^= userId.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return AVATAR_COLOR_IDS[(h >>> 0) % AVATAR_COLOR_IDS.length];
}

export function defaultAvatar(userId: string): StoredAvatar {
  return { kind: "initials", color: defaultAvatarColor(userId), updatedAt: 0 };
}

export function publicAvatar(a: StoredAvatar): Avatar {
  const out: Avatar = { kind: a.kind, color: a.color, updatedAt: a.updatedAt };
  if (a.initials) out.initials = a.initials;
  if (a.kind === "emoji" && a.emoji) out.emoji = a.emoji;
  if (a.kind === "photo" && a.photoKey) out.photoId = a.photoKey.slice(a.photoKey.lastIndexOf("/") + 1);
  return out;
}

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const graphemes = (s: string) => [...segmenter.segment(s)].length;
const EMOJI_RE = /\p{Extended_Pictographic}|\p{Regional_Indicator}|⃣/u;

/// Exactly one emoji: one grapheme that is a pictograph, a flag or a keycap.
export function isOneEmoji(s: string): boolean {
  return s.length <= 64 && graphemes(s) === 1 && EMOJI_RE.test(s);
}

/// One to three letters or digits, in any script.
export function isInitials(s: string): boolean {
  return /^[\p{L}\p{M}\p{N}]+$/u.test(s) && graphemes(s) <= MAX_AVATAR_INITIALS;
}

const zColor = z.string().refine((c) => AVATAR_COLOR_IDS.includes(c), "not an avatar color");
/// "" clears the initials a person typed: the clients then derive them from the name.
const zInitials = z.string().trim().refine((s) => s === "" || isInitials(s), "one to three letters");

/// `PATCH /v1/account/avatar`. A photo comes through `PUT` only. `updatedAt`
/// is when the person made the change on their device: an edit made offline
/// that arrives after a newer one changes nothing.
export const zAvatarPatchBody = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("initials"), color: zColor.optional(), initials: zInitials.optional(), updatedAt: z.number().int().positive().optional() }).strict(),
  z.object({ kind: z.literal("emoji"), emoji: z.string().refine(isOneEmoji, "one emoji"), color: zColor.optional(), initials: zInitials.optional(), updatedAt: z.number().int().positive().optional() }).strict(),
]);
export type AvatarPatch = z.infer<typeof zAvatarPatchBody>;

/// The image type from the first bytes, or null. JPEG, PNG and HEIC only.
export function sniffAvatarImage(bytes: Uint8Array): "image/jpeg" | "image/png" | "image/heic" | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length >= 8 && png.every((b, i) => bytes[i] === b)) return "image/png";
  if (bytes.length >= 12) {
    const box = String.fromCharCode(...bytes.slice(4, 8));
    const brand = String.fromCharCode(...bytes.slice(8, 12));
    if (box === "ftyp" && ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].includes(brand)) return "image/heic";
  }
  return null;
}
