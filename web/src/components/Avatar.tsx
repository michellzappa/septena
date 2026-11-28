"use client";

import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Check } from "lucide-react";
import type { SeptenaApiClient } from "@/lib/api/client";
import { registryText } from "@/lib/generated/registries";
import {
  AVATAR_COLORS,
  AVATAR_SURFACE,
  avatarColor,
  AccountAvatarStore,
  avatarCopy,
  avatarFill,
  avatarInitials,
  cleanInitials,
  isOneEmoji,
  lastEmoji,
  type AccountAvatarState,
  type AvatarKind,
} from "@/lib/avatar";
import type { Avatar as AvatarModel, ProjectShareInfo, ShareMember } from "@/lib/types";
import { useEscapeToClose } from "@/lib/useEscapeToClose";

// The avatar (#857): initials in white on the palette color, one emoji on the
// color, or a photo in a circle (initials on the color while it loads or
// fails). No avatar or an unknown color draws the default color (Persimmon).

interface AvatarViewProps {
  avatar: AvatarModel | null | undefined;
  name: string;
  isDark: boolean;
  /** Diameter in px. */
  size: number;
  /** The resolved photo URL, or null while it loads or when there is none. */
  photoUrl?: string | null;
  /** Initials when the name is empty. */
  fallbackInitials?: string;
  className?: string;
}

export function AvatarView({ avatar, name, isDark, size, photoUrl, fallbackInitials, className = "" }: AvatarViewProps) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [photoUrl]);
  const { fill, ink } = avatarFill(avatar?.color, isDark);
  const showPhoto = avatar?.kind === "photo" && photoUrl && !failed;
  const showEmoji = avatar?.kind === "emoji" && avatar.emoji;
  const style: React.CSSProperties = { width: size, height: size, fontSize: Math.round(size * (showEmoji ? 0.55 : 0.38)) };
  style.backgroundColor = fill;
  style.color = ink;
  return (
    <span
      aria-hidden
      style={style}
      className={`relative inline-flex shrink-0 select-none items-center justify-center overflow-hidden rounded-full font-semibold leading-none ${className}`}
    >
      {showPhoto ? (
        <img src={photoUrl} alt="" className="h-full w-full object-cover" onError={() => setFailed(true)} />
      ) : showEmoji ? (
        <span>{avatar.emoji}</span>
      ) : (
        <span>{avatarInitials(avatar, name, fallbackInitials)}</span>
      )}
    </span>
  );
}

/** Resolves an authenticated photo to an object URL (cached by photo id in the client). */
function usePhotoUrl(load: (() => Promise<string>) | null, key: string | null): string | null {
  const [url, setUrl] = useState<{ key: string; url: string } | null>(null);
  useEffect(() => {
    if (!load || !key) return;
    let cancelled = false;
    load()
      .then((u) => !cancelled && setUrl({ key, url: u }))
      .catch(() => {});
    return () => {
      cancelled = true;
    };
    // `load` is rebuilt every render; the key names the photo.
  }, [key]);
  return url && url.key === key ? url.url : null;
}

/** A shared-project member. */
export function MemberAvatar({
  api,
  share,
  member,
  isDark,
  size,
}: {
  api: SeptenaApiClient;
  share: ProjectShareInfo;
  member: ShareMember;
  isDark: boolean;
  size: number;
}) {
  const avatar = member.avatar ?? null;
  const photoId = avatar?.kind === "photo" ? (avatar.photoId ?? null) : null;
  const key = photoId ? `${share.id}/${member.id}:${photoId}` : null;
  const url = usePhotoUrl(photoId ? () => api.memberAvatarPhotoUrl(share.id, member.id, photoId) : null, key);
  return <AvatarView avatar={avatar} name={member.name} isDark={isDark} size={size} photoUrl={url} />;
}

// MARK: - The account avatar

export interface AccountAvatarController {
  store: AccountAvatarStore;
  state: AccountAvatarState;
}

/**
 * The account avatar store for the app's lifetime. It flushes a pending edit
 * on load, after sign-in and when the browser comes back online.
 */
export function useAccountAvatar(api: SeptenaApiClient, signedIn: boolean): AccountAvatarController {
  const storeRef = useRef<AccountAvatarStore | null>(null);
  if (!storeRef.current) storeRef.current = new AccountAvatarStore(api);
  const store = storeRef.current;
  const state = useSyncExternalStore(
    useCallback((fn: () => void) => store.subscribe(fn), [store]),
    () => store.getState(),
    () => store.getState(),
  );
  useEffect(() => {
    if (!signedIn) return;
    void store.refresh();
    const online = () => void store.flush();
    const visible = () => {
      if (document.visibilityState === "visible") void store.flush();
    };
    window.addEventListener("online", online);
    document.addEventListener("visibilitychange", visible);
    return () => {
      window.removeEventListener("online", online);
      document.removeEventListener("visibilitychange", visible);
    };
  }, [signedIn, store]);
  return { store, state };
}

/** The account's own avatar: a pending photo draws before it uploads. */
export function AccountAvatar({
  api,
  state,
  name,
  isDark,
  size,
  className,
}: {
  api: SeptenaApiClient;
  state: AccountAvatarState;
  name: string;
  isDark: boolean;
  size: number;
  className?: string;
}) {
  const avatar = state.pendingPhotoUrl ? { ...(state.avatar ?? { color: "", updatedAt: 0 }), kind: "photo" } : state.avatar;
  const photoId = !state.pendingPhotoUrl && avatar?.kind === "photo" ? (avatar.photoId ?? null) : null;
  const remote = usePhotoUrl(photoId ? () => api.accountAvatarPhotoUrl(photoId) : null, photoId);
  return (
    <AvatarView
      avatar={avatar}
      name={name}
      isDark={isDark}
      size={size}
      photoUrl={state.pendingPhotoUrl ?? remote}
      fallbackInitials="S"
      className={className}
    />
  );
}

// MARK: - The editor

const VIEW = 240;

interface CropState {
  img: HTMLImageElement;
  url: string;
  /** Zoom on top of the scale that covers the circle. 1 to 4. */
  zoom: number;
  /** The image center's offset from the view center, in view px. */
  x: number;
  y: number;
}

function coverScale(img: HTMLImageElement): number {
  return VIEW / Math.min(img.naturalWidth, img.naturalHeight);
}

/** Keeps the circle covered: the image edge never moves inside the view. */
function clampCrop(c: CropState): CropState {
  const s = coverScale(c.img) * c.zoom;
  const maxX = Math.max(0, (c.img.naturalWidth * s - VIEW) / 2);
  const maxY = Math.max(0, (c.img.naturalHeight * s - VIEW) / 2);
  return { ...c, x: Math.min(maxX, Math.max(-maxX, c.x)), y: Math.min(maxY, Math.max(-maxY, c.y)) };
}

function drawCrop(ctx: CanvasRenderingContext2D, c: CropState, out: number): void {
  const k = out / VIEW;
  const s = coverScale(c.img) * c.zoom * k;
  const w = c.img.naturalWidth * s;
  const h = c.img.naturalHeight * s;
  ctx.drawImage(c.img, out / 2 + c.x * k - w / 2, out / 2 + c.y * k - h / 2, w, h);
}

function exportCrop(c: CropState): Promise<Blob | null> {
  const size = AVATAR_SURFACE.photoSize;
  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext("2d");
  if (!ctx) return Promise.resolve(null);
  ctx.fillStyle = "#ffffff";
  ctx.fillRect(0, 0, size, size);
  drawCrop(ctx, c, size);
  return new Promise((resolve) => canvas.toBlob((b) => resolve(b), "image/jpeg", 0.85));
}

function CropView({ crop, onChange }: { crop: CropState; onChange: (c: CropState) => void }) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const drag = useRef<{ px: number; py: number; x: number; y: number } | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = VIEW * dpr;
    canvas.height = VIEW * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, VIEW, VIEW);
    drawCrop(ctx, crop, VIEW);
    // The circle mask: dim everything outside the circle.
    ctx.fillStyle = "rgba(0, 0, 0, 0.55)";
    ctx.beginPath();
    ctx.rect(0, 0, VIEW, VIEW);
    ctx.arc(VIEW / 2, VIEW / 2, VIEW / 2 - 1, 0, Math.PI * 2, true);
    ctx.fill("evenodd");
  }, [crop]);

  // A non-passive wheel listener, so the page does not scroll while zooming.
  const cropRef = useRef(crop);
  cropRef.current = crop;
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const wheel = (e: WheelEvent) => {
      e.preventDefault();
      const c = cropRef.current;
      const zoom = Math.min(4, Math.max(1, c.zoom * Math.exp(-e.deltaY / 400)));
      onChange(clampCrop({ ...c, zoom }));
    };
    canvas.addEventListener("wheel", wheel, { passive: false });
    return () => canvas.removeEventListener("wheel", wheel);
  }, [onChange]);

  return (
    <canvas
      ref={canvasRef}
      style={{ width: VIEW, height: VIEW, touchAction: "none" }}
      className="cursor-grab rounded-xl bg-black active:cursor-grabbing"
      onPointerDown={(e) => {
        e.currentTarget.setPointerCapture(e.pointerId);
        drag.current = { px: e.clientX, py: e.clientY, x: crop.x, y: crop.y };
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d) return;
        onChange(clampCrop({ ...crop, x: d.x + e.clientX - d.px, y: d.y + e.clientY - d.py }));
      }}
      onPointerUp={() => {
        drag.current = null;
      }}
      onPointerCancel={() => {
        drag.current = null;
      }}
    />
  );
}

interface AvatarEditorProps {
  api: SeptenaApiClient;
  controller: AccountAvatarController;
  name: string;
  isDark: boolean;
  lang: string;
  onClose: () => void;
}

/** One dialog with Photo, Emoji and Initials (surfaces.json `avatar`). It mounts when it opens. */
export function AvatarEditor({ api, controller, name, isDark, lang, onClose }: AvatarEditorProps) {
  const { store, state } = controller;
  const current = state.avatar;
  const t = (id: string) => avatarCopy(id, lang);
  const startKind: AvatarKind =
    state.pendingPhotoUrl || current?.kind === "photo" ? "photo" : current?.kind === "emoji" ? "emoji" : "initials";
  const [kind, setKind] = useState<AvatarKind>(startKind);
  useEscapeToClose(true, onClose);
  const [color, setColor] = useState<string>(
    avatarColor(current?.color).id,
  );
  const [emoji, setEmoji] = useState(current?.emoji ?? "");
  const [initials, setInitials] = useState(current?.initials ?? "");
  const [crop, setCrop] = useState<CropState | null>(null);
  const [photo, setPhoto] = useState<{ blob: Blob; url: string } | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const fileRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => () => {
    if (crop) URL.revokeObjectURL(crop.url);
  }, [crop]);
  useEffect(() => () => {
    if (photo) URL.revokeObjectURL(photo.url);
  }, [photo]);

  const hasPhoto = Boolean(state.pendingPhotoUrl || current?.kind === "photo");
  const preview: AvatarModel =
    kind === "photo"
      ? { kind: "photo", color, initials: initials || undefined, photoId: current?.photoId, updatedAt: 0 }
      : kind === "emoji"
        ? { kind: isOneEmoji(emoji) ? "emoji" : "initials", color, emoji, initials: initials || undefined, updatedAt: 0 }
        : { kind: "initials", color, initials: initials || undefined, updatedAt: 0 };

  const canSave =
    !busy &&
    !crop &&
    (kind === "photo" ? Boolean(photo) || hasPhoto : kind === "emoji" ? isOneEmoji(emoji) : true);

  const pickFile = (file: File | undefined) => {
    setProblem(null);
    if (!file) return;
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => setCrop({ img, url, zoom: 1, x: 0, y: 0 });
    img.onerror = () => {
      URL.revokeObjectURL(url);
      setProblem(t("photoFailed"));
    };
    img.src = url;
  };

  const confirmCrop = async () => {
    if (!crop) return;
    const blob = await exportCrop(crop);
    if (!blob) {
      setProblem(t("photoFailed"));
      return;
    }
    if (blob.size > AVATAR_SURFACE.maxPhotoBytes) {
      setProblem(t("photoTooLarge"));
      return;
    }
    setPhoto({ blob, url: URL.createObjectURL(blob) });
    setCrop(null);
  };

  const save = async () => {
    if (!canSave) return;
    setBusy(true);
    try {
      if (kind === "photo" && photo) {
        await store.savePhoto(photo.blob);
        const p = store.getState().photoProblem;
        // Offline: the photo waits and the dialog closes; the account row says so.
        if (p === "photoTooLarge" || p === "photoFailed") {
          setProblem(t(p));
          return;
        }
      } else if (kind === "photo") {
        // The photo stays as it is.
      } else if (kind === "emoji") {
        void store.saveEdit({ kind: "emoji", emoji, color, initials });
      } else {
        void store.saveEdit({ kind: "initials", color, initials });
      }
      onClose();
    } finally {
      setBusy(false);
    }
  };

  const segment = (k: AvatarKind) => {
    const active = kind === k;
    return (
      <button
        key={k}
        type="button"
        role="tab"
        aria-selected={active}
        onClick={() => setKind(k)}
        className={`flex-1 rounded-md px-3 py-1 text-xs font-medium transition-colors ${
          active ? "bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-sm" : "text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
        }`}
      >
        {t(k)}
      </button>
    );
  };

  const colorRow = (
    <div>
      <p className="mb-2 text-xs font-medium text-[var(--text-primary)]">{t("color")}</p>
      <div className="flex flex-wrap gap-2">
        {AVATAR_COLORS.map((c) => {
          const selected = color === c.id;
          return (
            <button
              key={c.id}
              type="button"
              aria-label={c.name}
              aria-pressed={selected}
              title={c.name}
              onClick={() => setColor(c.id)}
              className={`flex h-8 w-8 items-center justify-center rounded-full border-2 transition-colors ${
                selected ? "border-[var(--accent)]" : "border-transparent"
              }`}
            >
              <span
                className="flex h-6 w-6 items-center justify-center rounded-full"
                style={isDark ? { backgroundColor: c.dark, color: c.inkDark } : { backgroundColor: c.light, color: c.inkLight }}
              >
                {selected && <Check className="h-3.5 w-3.5" />}
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );

  const fieldClass =
    "mt-1.5 w-full rounded-lg border border-[var(--border-subtle)] bg-transparent px-3 py-1.5 text-sm text-[var(--text-primary)] outline-none focus:border-[var(--accent)]";

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div
        role="dialog"
        aria-modal="true"
        aria-label={registryTitle(lang)}
        className="w-full max-w-sm overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="border-b border-[var(--border-subtle)] px-4 py-3 text-center text-sm font-semibold text-[var(--text-primary)]">
          {registryTitle(lang)}
        </div>
        <div className="space-y-4 p-4">
          <div className="flex justify-center">
            {kind === "photo" && photo ? (
              <AvatarView avatar={preview} name={name} isDark={isDark} size={72} photoUrl={photo.url} fallbackInitials="S" />
            ) : kind === "photo" ? (
              <AccountAvatar api={api} state={state} name={name} isDark={isDark} size={72} />
            ) : (
              <AvatarView avatar={preview} name={name} isDark={isDark} size={72} fallbackInitials="S" />
            )}
          </div>

          <div role="tablist" className="flex gap-1 rounded-lg bg-[var(--bg-pill)] p-0.5">
            {AVATAR_SURFACE.kinds.map(segment)}
          </div>

          {kind === "photo" && (
            <div className="space-y-3">
              <input
                ref={fileRef}
                type="file"
                accept="image/jpeg,image/png,image/heic"
                className="hidden"
                onChange={(e) => {
                  pickFile(e.target.files?.[0]);
                  e.target.value = "";
                }}
              />
              {crop ? (
                <div className="flex flex-col items-center gap-2">
                  <CropView crop={crop} onChange={setCrop} />
                  <input
                    type="range"
                    min={1}
                    max={4}
                    step={0.01}
                    value={crop.zoom}
                    aria-label={t("cropHint")}
                    onChange={(e) => setCrop(clampCrop({ ...crop, zoom: Number(e.target.value) }))}
                    className="w-[240px] accent-[var(--accent)]"
                  />
                  <p className="text-center text-[11px] text-[var(--text-muted)]">{t("cropHint")}</p>
                  <button
                    type="button"
                    onClick={() => void confirmCrop()}
                    className="rounded-lg bg-[var(--accent)] px-3 py-1.5 text-xs font-medium text-white"
                  >
                    {t("usePhoto")}
                  </button>
                </div>
              ) : (
                <div className="flex flex-wrap justify-center gap-2">
                  <button
                    type="button"
                    onClick={() => fileRef.current?.click()}
                    className="rounded-lg border border-[var(--border-subtle)] px-3 py-1.5 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                  >
                    {t("choosePhoto")}
                  </button>
                  {hasPhoto && !photo && (
                    <button
                      type="button"
                      disabled={busy}
                      onClick={async () => {
                        setBusy(true);
                        await store.removePhoto();
                        setBusy(false);
                        if (store.getState().photoProblem === "photoFailed") setProblem(t("photoFailed"));
                        else setKind("initials");
                      }}
                      className="rounded-lg border border-[var(--overdue-red)]/35 px-3 py-1.5 text-xs font-medium text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10 disabled:opacity-40"
                    >
                      {t("removePhoto")}
                    </button>
                  )}
                </div>
              )}
              {state.photoProblem === "photoPending" && !photo && (
                <p className="text-center text-[11px] text-[var(--text-muted)]">{t("photoPending")}</p>
              )}
            </div>
          )}

          {kind === "emoji" && (
            <div className="space-y-4">
              <div>
                <input
                  type="text"
                  value={emoji}
                  aria-label={t("emoji")}
                  placeholder={t("emojiHint")}
                  onChange={(e) => setEmoji(lastEmoji(e.target.value))}
                  className={`${fieldClass} text-center text-2xl`}
                />
                <p className="mt-1 text-[11px] text-[var(--text-muted)]">{t("emojiHint")}</p>
              </div>
              {colorRow}
            </div>
          )}

          {kind === "initials" && (
            <div className="space-y-4">
              <input
                type="text"
                value={initials}
                aria-label={t("initials")}
                placeholder={t("initialsHint")}
                onChange={(e) => setInitials(cleanInitials(e.target.value))}
                className={`${fieldClass} uppercase`}
              />
              {colorRow}
            </div>
          )}

          {problem && <p className="text-center text-[11px] text-[var(--overdue-red)]">{problem}</p>}
        </div>
        <div className="flex justify-end gap-2 border-t border-[var(--border-subtle)] px-4 py-3">
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg bg-[var(--bg-hover)] px-3 py-1.5 text-xs font-medium text-[var(--text-primary)]"
          >
            {t("cancel")}
          </button>
          <button
            type="button"
            disabled={!canSave}
            onClick={() => void save()}
            className="rounded-lg bg-[var(--accent)] px-3 py-1.5 text-xs font-medium text-white disabled:opacity-40"
          >
            {t("save")}
          </button>
        </div>
      </div>
    </div>
  );
}

function registryTitle(lang: string): string {
  return registryText(AVATAR_SURFACE.title, lang);
}
