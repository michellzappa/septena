"use client";

// The beta checklist (docs/BETA_ONBOARDING_SPEC.md §7): the Beta screen, the
// state behind the Settings row and the Today card. Every word comes from
// GET /v1/beta; a non-tester or a failed read shows nothing. Writes are
// optimistic: the screen changes at once, a failed write reads the state again.

import { useCallback, useEffect, useState } from "react";
import { Check, X } from "lucide-react";
import type { SeptenaApiClient } from "@/lib/api/client";
import type { BetaMember, BetaProgress } from "@/lib/types";

/** Fills `{name}` placeholders in a copy line from GET /v1/beta. */
export function fillBeta(text: string, vars: Record<string, string | number>): string {
  return text.replace(/\{([a-zA-Z][a-zA-Z0-9]*)\}/g, (m, name: string) => (name in vars ? String(vars[name]) : m));
}

/** "{tried} of {total} tried" for the Settings row. */
export function betaSummary(beta: BetaMember): string {
  const tried = beta.items.filter((i) => beta.tried[i.id] != null).length;
  return fillBeta(beta.copy.settingsSummary, { tried, total: beta.items.length });
}

export interface BetaController {
  /** Null: not a tester, not read yet, or the read failed. */
  beta: BetaMember | null;
  write: (body: BetaProgress) => void;
}

/** Reads GET /v1/beta while `enabled` (signed in) and on every `refreshKey` change. */
export function useBeta(api: SeptenaApiClient, enabled: boolean, refreshKey: unknown): BetaController {
  const [beta, setBeta] = useState<BetaMember | null>(null);

  const reload = useCallback(async () => {
    try {
      const state = await api.getBeta();
      setBeta(state.member ? state : null);
    } catch {
      setBeta(null);
    }
  }, [api]);

  useEffect(() => {
    if (!enabled) {
      setBeta(null);
      return;
    }
    void reload();
  }, [enabled, refreshKey, reload]);

  const write = useCallback(
    (body: BetaProgress) => {
      const now = Date.now();
      setBeta((prev) => {
        if (!prev) return prev;
        if ("item" in body) {
          const tried = { ...prev.tried };
          if (body.tried) tried[body.item] = now;
          else delete tried[body.item];
          return { ...prev, tried };
        }
        if ("ack" in body) return { ...prev, ackAt: now };
        return { ...prev, cardDismissedAt: now };
      });
      api.postBetaProgress(body).catch(() => void reload());
    },
    [api, reload],
  );

  return { beta, write };
}

interface BetaModalProps {
  open: boolean;
  language: string;
  beta: BetaMember | null;
  onClose: () => void;
  onWrite: (body: BetaProgress) => void;
  /** Opens Contact Support with this text in the message field. */
  onSendNote: (subject: string) => void;
}

export function BetaModal({ open, language, beta, onClose, onWrite, onSendNote }: BetaModalProps) {
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

  if (!open || !beta) return null;
  const { copy } = beta;
  const ackDate =
    beta.ackAt != null ? new Date(beta.ackAt).toLocaleDateString(language, { dateStyle: "medium" }) : null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div
        role="dialog"
        aria-modal="true"
        aria-label={copy.title}
        className="flex max-h-[86vh] w-full max-w-lg flex-col overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-[var(--border-subtle)] px-5 py-3.5">
          <h2 className="text-base font-semibold text-[var(--text-primary)]">{copy.title}</h2>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
            aria-label={copy.title}
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="flex-1 space-y-4 overflow-y-auto p-5 text-sm">
          <p className="font-medium text-[var(--text-primary)]">{copy.deal}</p>
          <p className="text-[var(--text-secondary)]">{copy.intro}</p>

          <section className="divide-y divide-[var(--border-subtle)] rounded-xl border border-[var(--border-subtle)] px-3.5">
            {beta.items.map((item) => {
              const tried = beta.tried[item.id] != null;
              return (
                <div key={item.id} className="space-y-1.5 py-3">
                  <p className="text-xs font-medium text-[var(--text-primary)]">{item.title}</p>
                  <p className="text-[11px] text-[var(--text-muted)]">{item.try}</p>
                  <div className="flex items-center justify-between gap-3 pt-0.5">
                    <label className="flex cursor-pointer items-center gap-2 text-xs text-[var(--text-primary)]">
                      <input
                        type="checkbox"
                        checked={tried}
                        onChange={(e) => onWrite({ item: item.id, tried: e.target.checked })}
                      />
                      <span>{copy.tried}</span>
                    </label>
                    <button
                      type="button"
                      onClick={() => onSendNote(fillBeta(copy.noteSubject, { item: item.title }))}
                      className="text-xs text-[var(--accent)] hover:underline"
                    >
                      {copy.note}
                    </button>
                  </div>
                </div>
              );
            })}
          </section>

          <section className="space-y-1.5">
            <button
              type="button"
              onClick={() => onWrite({ ack: true })}
              className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--accent)] px-4 py-2 text-xs font-medium"
              style={{ color: "var(--accent-check)" }}
            >
              <Check className="h-3.5 w-3.5" />
              {copy.ack}
            </button>
            {ackDate && <p className="text-xs text-[var(--text-muted)]">{fillBeta(copy.ackDone, { date: ackDate })}</p>}
          </section>
        </div>
      </div>
    </div>
  );
}
