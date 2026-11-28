import { DESIGN_TOKENS, SURFACES_CATALOG, registryText } from "./generated/registries";
import type { Avatar } from "./types";
import type { AvatarPatch, SeptenaApiClient } from "./api/client";

// The editable avatar (#857). The model helpers and the account avatar store:
// the last GET /v1/account in localStorage, an initials/emoji edit made
// offline (sent later with the time it was made), and a cropped photo that
// waits for the network. backend/src/store/avatar.ts is the wire.

export const AVATAR_SURFACE = SURFACES_CATALOG.avatar;
export const AVATAR_COLORS = DESIGN_TOKENS.avatarColors;
export type AvatarKind = (typeof AVATAR_SURFACE.kinds)[number];

/** One line of `surfaces.json` `avatar.copy`, localized. */
export function avatarCopy(id: string, lang: string): string {
  const entry = AVATAR_SURFACE.copy.find((c) => c.id === id);
  return entry ? registryText(entry.label, lang) : id;
}

/** The fill for a palette id, or null (neutral fill) for an unknown id. */
export function avatarFill(color: string | undefined, isDark: boolean): string | null {
  const c = AVATAR_COLORS.find((x) => x.id === color);
  return c ? (isDark ? c.dark : c.light) : null;
}

/** Lenient decode: anything without a string kind and color is no avatar. */
export function normalizeAvatar(raw: unknown): Avatar | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  if (typeof o.kind !== "string" || typeof o.color !== "string") return null;
  const out: Avatar = { kind: o.kind, color: o.color, updatedAt: typeof o.updatedAt === "number" ? o.updatedAt : 0 };
  if (typeof o.initials === "string" && o.initials) out.initials = o.initials;
  if (typeof o.emoji === "string" && o.emoji) out.emoji = o.emoji;
  if (typeof o.photoId === "string" && o.photoId) out.photoId = o.photoId;
  return out;
}

/** Initials from a name: the first letter of the first two words. */
export function nameInitials(name: string, fallback = "S"): string {
  return (name.trim() || fallback)
    .split(/\s+/)
    .slice(0, 2)
    .map((part) => [...part][0]?.toUpperCase() ?? "")
    .join("");
}

/** The letters an avatar shows: typed initials, else derived from the name. */
export function avatarInitials(avatar: Avatar | null | undefined, name: string, fallback?: string): string {
  return avatar?.initials || nameInitials(name, fallback);
}

const segmenter = typeof Intl !== "undefined" && "Segmenter" in Intl ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
const graphemes = (s: string) => (segmenter ? [...segmenter.segment(s)].map((g) => g.segment) : [...s]);
const EMOJI_RE = /\p{Extended_Pictographic}|\p{Regional_Indicator}|⃣/u;

/** Exactly one emoji grapheme (the server's isOneEmoji). */
export function isOneEmoji(s: string): boolean {
  return s.length <= 64 && graphemes(s).length === 1 && EMOJI_RE.test(s);
}

/** The last emoji grapheme typed into the field, or "" when there is none. */
export function lastEmoji(s: string): string {
  const all = graphemes(s).filter(isOneEmoji);
  return all[all.length - 1] ?? "";
}

/** Letters and digits only, uppercased, at most `maxInitials` graphemes. */
export function cleanInitials(s: string): string {
  const letters = graphemes(s.toUpperCase()).filter((g) => /^[\p{L}\p{M}\p{N}]+$/u.test(g));
  return letters.slice(0, AVATAR_SURFACE.maxInitials).join("");
}

// MARK: - The account avatar store

const CACHE_KEY = "septena.avatar.account.v1";
const PENDING_KEY = "septena.avatar.pendingEdit.v1";
const PENDING_PHOTO_KEY = "septena.avatar.pendingPhoto.v1";

type PhotoProblem = "photoPending" | "photoFailed" | "photoTooLarge";

export interface AccountAvatarState {
  avatar: Avatar | null;
  /** A cropped photo that waits to upload, as a data URL. The avatar draws it meanwhile. */
  pendingPhotoUrl: string | null;
  /** A copy id from `avatar.copy` that explains the photo state, or null. */
  photoProblem: PhotoProblem | null;
}

interface PendingEdit {
  userId: string | null;
  patch: AvatarPatch & { updatedAt: number };
}

interface PendingPhoto {
  userId: string | null;
  dataUrl: string;
  createdAt: number;
}

function readJson<T>(key: string): T | null {
  try {
    const raw = window.localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : null;
  } catch {
    return null;
  }
}

function writeJson(key: string, value: unknown): void {
  try {
    if (value == null) window.localStorage.removeItem(key);
    else window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Storage full or blocked: the edit still shows for this page load.
  }
}

function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

async function dataUrlToBlob(dataUrl: string): Promise<Blob> {
  return (await fetch(dataUrl)).blob();
}

const isOffline = () => typeof navigator !== "undefined" && navigator.onLine === false;

function isNetworkError(err: unknown): boolean {
  // fetch rejects with a TypeError when the request never reached the server.
  return err instanceof TypeError || isOffline();
}

export class AccountAvatarStore {
  private state: AccountAvatarState = { avatar: null, pendingPhotoUrl: null, photoProblem: null };
  private listeners = new Set<() => void>();
  private flushing: Promise<void> | null = null;

  constructor(private readonly api: SeptenaApiClient) {
    if (typeof window === "undefined") return;
    const cached = readJson<{ userId: string | null; avatar: unknown }>(CACHE_KEY);
    const pending = readJson<PendingEdit>(PENDING_KEY);
    const photo = readJson<PendingPhoto>(PENDING_PHOTO_KEY);
    let avatar = normalizeAvatar(cached?.avatar);
    if (pending) avatar = this.applyLocal(avatar, pending.patch);
    this.state = {
      avatar,
      pendingPhotoUrl: photo?.dataUrl ?? null,
      photoProblem: photo ? "photoPending" : null,
    };
  }

  getState(): AccountAvatarState {
    return this.state;
  }

  subscribe(fn: () => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private set(next: Partial<AccountAvatarState>): void {
    this.state = { ...this.state, ...next };
    for (const fn of this.listeners) fn();
  }

  private adopt(avatar: Avatar): void {
    writeJson(CACHE_KEY, { userId: this.api.currentUserId, avatar });
    this.set({ avatar });
  }

  private applyLocal(current: Avatar | null, patch: AvatarPatch & { updatedAt: number }): Avatar {
    const next: Avatar = {
      kind: patch.kind,
      color: patch.color ?? current?.color ?? "",
      updatedAt: patch.updatedAt,
    };
    const initials = patch.initials === undefined ? current?.initials : patch.initials || undefined;
    if (initials) next.initials = initials;
    if (patch.kind === "emoji") next.emoji = patch.emoji;
    return next;
  }

  /** Drops what belongs to another account (an account switch on this browser). */
  private dropForeign(): void {
    const me = this.api.currentUserId;
    if (!me) return;
    const cached = readJson<{ userId: string | null }>(CACHE_KEY);
    const pending = readJson<PendingEdit>(PENDING_KEY);
    const photo = readJson<PendingPhoto>(PENDING_PHOTO_KEY);
    if (cached && cached.userId && cached.userId !== me) {
      writeJson(CACHE_KEY, null);
      this.set({ avatar: null });
    }
    if (pending && pending.userId && pending.userId !== me) writeJson(PENDING_KEY, null);
    if (photo && photo.userId && photo.userId !== me) {
      writeJson(PENDING_PHOTO_KEY, null);
      this.set({ pendingPhotoUrl: null, photoProblem: null });
    }
  }

  /** Initials or an emoji: shows at once, then PATCH when online. */
  async saveEdit(patch: AvatarPatch): Promise<void> {
    const stamped = { ...patch, updatedAt: Date.now() } as AvatarPatch & { updatedAt: number };
    writeJson(PENDING_KEY, { userId: this.api.currentUserId, patch: stamped } satisfies PendingEdit);
    // A newer edit replaces a photo that has not uploaded yet.
    writeJson(PENDING_PHOTO_KEY, null);
    this.set({ avatar: this.applyLocal(this.state.avatar, stamped), pendingPhotoUrl: null, photoProblem: null });
    await this.flush();
  }

  /** A cropped JPEG: uploads now when online, else waits for the network. */
  async savePhoto(jpeg: Blob): Promise<void> {
    if (jpeg.size > AVATAR_SURFACE.maxPhotoBytes) {
      this.set({ photoProblem: "photoTooLarge" });
      return;
    }
    const dataUrl = await blobToDataUrl(jpeg);
    writeJson(PENDING_PHOTO_KEY, { userId: this.api.currentUserId, dataUrl, createdAt: Date.now() } satisfies PendingPhoto);
    this.set({ pendingPhotoUrl: dataUrl, photoProblem: "photoPending" });
    await this.flush();
  }

  /** Back to initials. Needs the network. */
  async removePhoto(): Promise<void> {
    writeJson(PENDING_PHOTO_KEY, null);
    this.set({ pendingPhotoUrl: null, photoProblem: null });
    try {
      this.adopt(await this.api.deleteAvatar());
    } catch {
      this.set({ photoProblem: "photoFailed" });
    }
  }

  /** Sends the pending edit, then the pending photo. Runs one at a time. */
  flush(): Promise<void> {
    if (this.flushing) return this.flushing;
    this.flushing = this.doFlush().finally(() => {
      this.flushing = null;
    });
    return this.flushing;
  }

  private async doFlush(): Promise<void> {
    if (typeof window === "undefined" || !this.api.isAuthenticated || isOffline()) return;
    this.dropForeign();
    const pending = readJson<PendingEdit>(PENDING_KEY);
    if (pending) {
      try {
        const { avatar } = await this.api.patchAvatar(pending.patch);
        // A newer local edit made during the call stays pending.
        if (readJson<PendingEdit>(PENDING_KEY)?.patch.updatedAt === pending.patch.updatedAt) {
          writeJson(PENDING_KEY, null);
          this.adopt(avatar);
        }
      } catch (err) {
        if (isNetworkError(err)) return;
        // The server refused the edit: drop it and show what the server has.
        writeJson(PENDING_KEY, null);
        await this.refreshFromServer();
      }
    }
    const photo = readJson<PendingPhoto>(PENDING_PHOTO_KEY);
    if (photo) {
      try {
        const { avatar } = await this.api.putAvatarPhoto(await dataUrlToBlob(photo.dataUrl));
        if (readJson<PendingPhoto>(PENDING_PHOTO_KEY)?.createdAt === photo.createdAt) {
          writeJson(PENDING_PHOTO_KEY, null);
          this.set({ pendingPhotoUrl: null, photoProblem: null });
        }
        this.adopt(avatar);
      } catch (err) {
        if (isNetworkError(err)) {
          this.set({ photoProblem: "photoPending" });
          return;
        }
        const status = (err as { status?: number }).status;
        writeJson(PENDING_PHOTO_KEY, null);
        this.set({ pendingPhotoUrl: null, photoProblem: status === 413 ? "photoTooLarge" : "photoFailed" });
      }
    }
  }

  private async refreshFromServer(): Promise<void> {
    try {
      const { avatar } = await this.api.getAccount();
      this.adopt(avatar);
    } catch {
      // Offline or signed out: keep the cached avatar.
    }
  }

  /** Flushes, then reads GET /v1/account unless an edit still waits. */
  async refresh(): Promise<void> {
    await this.flush();
    if (!this.api.isAuthenticated || isOffline()) return;
    if (readJson(PENDING_KEY) || readJson(PENDING_PHOTO_KEY)) return;
    await this.refreshFromServer();
  }

  /** Sign-out: the cache and anything pending go. */
  clear(): void {
    writeJson(CACHE_KEY, null);
    writeJson(PENDING_KEY, null);
    writeJson(PENDING_PHOTO_KEY, null);
    this.set({ avatar: null, pendingPhotoUrl: null, photoProblem: null });
  }
}
