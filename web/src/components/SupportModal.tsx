"use client";

// Contact Support (ADR 0054, docs/SUPPORT_SPEC.md §4): the conversation, then
// the form. The same fields, order and words as the Apple and Android
// screens; copy comes from the registry (`surfaces.json` `support`).

import { useCallback, useEffect, useState } from "react";
import { ExternalLink, X } from "lucide-react";
import { HELP_URL, SURFACES_CATALOG, registryText } from "@/lib/generated/registries";
import { ApiError, type SeptenaApiClient, type SupportDiagnostics, type SupportMessage } from "@/lib/api/client";

const SUPPORT = SURFACES_CATALOG.support;
/** Matches the backend's limit (`MESSAGE_MAX_CHARS`). */
export const SUPPORT_MESSAGE_MAX_CHARS = 4000;
const KEY_STORAGE = "septena.support.key";

function copy(id: string, lang: string): string {
  const label = SUPPORT.copy.find((c) => c.id === id)?.label ?? id;
  return registryText(label, lang);
}

/** 32 random bytes, base64url, made once per browser. The backend keeps only its hash. */
export function supportKey(): string {
  try {
    const stored = window.localStorage.getItem(KEY_STORAGE);
    if (stored && /^[A-Za-z0-9_-]{43}$/.test(stored)) return stored;
  } catch {
    // Storage blocked: a fresh key for this page still sends.
  }
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const key = btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  try {
    window.localStorage.setItem(KEY_STORAGE, key);
  } catch {
    // Not kept: the next page load makes another key.
  }
  return key;
}

function diagnostics(signedIn: boolean): SupportDiagnostics {
  const ua = typeof navigator !== "undefined" ? navigator.userAgent : "";
  const os = /\(([^)]+)\)/.exec(ua)?.[1] ?? "";
  return {
    platform: "web",
    osVersion: os ? os.slice(0, 40) : undefined,
    deviceModel: ua ? ua.slice(0, 60) : undefined,
    signedIn,
  };
}

type SendState = { kind: "idle" } | { kind: "sending" } | { kind: "sent" } | { kind: "failed"; reason: string };

interface SupportModalProps {
  open: boolean;
  language: string;
  api: SeptenaApiClient;
  onClose: () => void;
  /** The unread count after a read, for the dot on the Settings row. */
  onUnreadChange: (unread: number) => void;
  /** Text to put in the message field when the form opens (the Beta screen's
   *  "Send a note" passes "Beta: {item}"). Without it the field keeps its text. */
  initialText?: string | null;
}

export function SupportModal({ open, language, api, onClose, onUnreadChange, initialText }: SupportModalProps) {
  const [messages, setMessages] = useState<SupportMessage[]>([]);
  const [text, setText] = useState("");
  const [email, setEmail] = useState("");
  const [includeDiagnostics, setIncludeDiagnostics] = useState(false);
  const [state, setState] = useState<SendState>({ kind: "idle" });
  const signedIn = api.isAuthenticated;
  const needsEmail = !signedIn;

  useEffect(() => {
    if (open && initialText) {
      setText(`${initialText}\n\n`);
      setState({ kind: "idle" });
    }
  }, [initialText, open]);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    void (async () => {
      try {
        const key = supportKey();
        const conversation = await api.supportConversation(key);
        if (cancelled) return;
        setMessages(conversation.messages);
        if (conversation.unread > 0) {
          await api.markSupportRead(key);
          onUnreadChange(0);
        }
      } catch {
        // The form still works; the next open reads again.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [api, onUnreadChange, open]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        onClose();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose, open]);

  const canSend =
    state.kind !== "sending" && text.trim().length > 0 && (!needsEmail || email.trim().length > 0);

  const send = useCallback(async () => {
    if (!canSend) return;
    setState({ kind: "sending" });
    try {
      const stored = await api.sendSupportMessage(
        {
          message_id: crypto.randomUUID(),
          text: text.trim().slice(0, SUPPORT_MESSAGE_MAX_CHARS),
          ...(needsEmail ? { email: email.trim() } : {}),
          ...(includeDiagnostics ? { diagnostics: diagnostics(signedIn) } : {}),
        },
        supportKey(),
      );
      setMessages((list) => (list.some((m) => m.id === stored.id) ? list : [...list, stored]));
      setText("");
      setState({ kind: "sent" });
    } catch (error) {
      const code = error instanceof ApiError ? error.code : "";
      const status = error instanceof ApiError ? error.status : 0;
      const reason =
        code === "email_required"
          ? copy("emailRequired", language)
          : status === 429
            ? copy("tooManyMessages", language)
            : copy("sendFailed", language);
      setState({ kind: "failed", reason });
    }
  }, [api, canSend, email, includeDiagnostics, language, needsEmail, signedIn, text]);

  if (!open) return null;

  const title = registryText(SUPPORT.title, language);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div
        role="dialog"
        aria-modal="true"
        aria-label={title}
        className="flex max-h-[86vh] w-full max-w-lg flex-col overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-[var(--border-subtle)] px-5 py-3.5">
          <h2 className="text-base font-semibold text-[var(--text-primary)]">{title}</h2>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
            aria-label={copy("closeTitle", language)}
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="flex-1 space-y-4 overflow-y-auto p-5 text-sm">
          <section className="space-y-3 rounded-xl border border-[var(--border-subtle)] p-4">
            {messages.length === 0 ? (
              <p className="text-[var(--text-muted)]">{copy("noMessages", language)}</p>
            ) : (
              messages.map((m) => (
                <div key={m.id} className="space-y-1">
                  <div className="flex items-baseline justify-between gap-3 text-xs">
                    <span
                      className={
                        m.direction === "out" ? "font-medium text-[var(--text-primary)]" : "font-medium text-[var(--text-muted)]"
                      }
                    >
                      {m.direction === "out"
                        ? m.authorName
                          ? `${copy("fromSeptena", language)} · ${m.authorName}`
                          : copy("fromSeptena", language)
                        : copy("fromYou", language)}
                    </span>
                    <span className="font-mono-tabular text-[11px] text-[var(--text-muted)]">
                      {new Date(m.createdAt).toLocaleString(language, {
                        month: "short",
                        day: "numeric",
                        hour: "numeric",
                        minute: "2-digit",
                      })}
                    </span>
                  </div>
                  <p className="whitespace-pre-wrap text-[var(--text-primary)]">{m.text}</p>
                </div>
              ))
            )}
          </section>

          <section className="space-y-1">
            <a
              href={HELP_URL}
              target="_blank"
              rel="noreferrer"
              className="flex w-full items-center gap-2 rounded-lg px-1 py-1 text-[var(--accent)] hover:underline"
            >
              <span>{copy("helpLink", language)}</span>
              <ExternalLink className="h-3.5 w-3.5" />
            </a>
            <p className="px-1 text-xs text-[var(--text-muted)]">{copy("helpHint", language)}</p>
          </section>

          <section className="space-y-2">
            <label className="block space-y-1">
              <span className="text-xs font-medium text-[var(--text-muted)]">{copy("messageLabel", language)}</span>
              <textarea
                value={text}
                maxLength={SUPPORT_MESSAGE_MAX_CHARS}
                rows={5}
                placeholder={copy("messagePlaceholder", language)}
                onChange={(e) => {
                  setText(e.target.value);
                  if (state.kind !== "sending") setState({ kind: "idle" });
                }}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                    e.preventDefault();
                    void send();
                  }
                }}
                className="w-full resize-y rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-base)] px-3 py-2 text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </label>
            {needsEmail && (
              <label className="block space-y-1">
                <span className="text-xs font-medium text-[var(--text-muted)]">{copy("emailFieldLabel", language)}</span>
                <input
                  type="email"
                  autoComplete="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="w-full rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-base)] px-3 py-2 text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                />
                <span className="block text-xs text-[var(--text-muted)]">{copy("emailDetail", language)}</span>
              </label>
            )}
          </section>

          <section className="space-y-1">
            <label className="flex items-center gap-2 text-[var(--text-primary)]">
              <input
                type="checkbox"
                checked={includeDiagnostics}
                onChange={(e) => setIncludeDiagnostics(e.target.checked)}
              />
              <span>{copy("diagnosticsLabel", language)}</span>
            </label>
            <p className="text-xs text-[var(--text-muted)]">{copy("diagnosticsDetail", language)}</p>
          </section>

          <section className="space-y-2">
            <button
              type="button"
              disabled={!canSend}
              onClick={() => void send()}
              className="rounded-lg bg-[var(--accent)] px-4 py-2 font-medium text-white disabled:opacity-50"
            >
              {state.kind === "sending" ? copy("sending", language) : copy("send", language)}
            </button>
            {state.kind === "sent" && <p className="text-xs text-[var(--text-muted)]">{copy("sent", language)}</p>}
            {state.kind === "failed" && (
              <div className="space-y-1">
                <p className="text-xs text-[var(--overdue-red)]">{state.reason}</p>
                <button
                  type="button"
                  disabled={!canSend}
                  onClick={() => void send()}
                  className="text-xs text-[var(--accent)] hover:underline disabled:opacity-50"
                >
                  {copy("sendAgain", language)}
                </button>
              </div>
            )}
          </section>
        </div>
      </div>
    </div>
  );
}
