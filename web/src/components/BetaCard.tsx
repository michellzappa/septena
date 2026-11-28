"use client";

// The beta welcome card (docs/BETA_ONBOARDING_SPEC.md §7, ADR 0064). The
// checklist is a normal project the server seeds in the tester's list, so the
// app keeps only this one-time card at the top of Today. Every word comes from
// GET /v1/beta; a non-tester or a failed read shows nothing. The dismiss write
// is optimistic: the card closes at once, a failed write reads the state again.

import { useCallback, useEffect, useState } from "react";
import { FlaskConical } from "lucide-react";
import type { SeptenaApiClient } from "@/lib/api/client";
import type { BetaMember } from "@/lib/types";

export interface BetaController {
  /** Null: not a tester, not read yet, or the read failed. */
  beta: BetaMember | null;
  /** Closes the card for good (POST /v1/beta/progress {dismissCard:true}). */
  dismissCard: () => void;
}

/** Reads GET /v1/beta while `enabled` (signed in). */
export function useBeta(api: SeptenaApiClient, enabled: boolean): BetaController {
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
  }, [enabled, reload]);

  const dismissCard = useCallback(() => {
    const now = Date.now();
    setBeta((prev) => (prev ? { ...prev, cardDismissedAt: now } : prev));
    api.postBetaProgress({ dismissCard: true }).catch(() => void reload());
  }, [api, reload]);

  return { beta, dismissCard };
}

interface BetaCardProps {
  beta: BetaMember;
  /** Opens the checklist project. Called only when the server sent a projectId. */
  onOpenProject: (projectId: string) => void;
  onDismiss: () => void;
}

/** Open goes to the checklist project and closes the card; with no project, Open only closes it. */
export function BetaCard({ beta, onOpenProject, onDismiss }: BetaCardProps) {
  const { copy, projectId } = beta;
  return (
    <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)]/90 px-4 py-2.5 text-xs">
      <div className="flex min-w-0 items-center gap-2.5">
        <FlaskConical className="h-4 w-4 shrink-0 text-[var(--text-muted)]" />
        <span className="text-[var(--text-secondary)]">
          <strong className="font-medium text-[var(--text-primary)]">{copy.cardTitle}</strong> {copy.cardBody}
        </span>
      </div>
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={() => {
            onDismiss();
            if (projectId) onOpenProject(projectId);
          }}
          className="rounded-md bg-[var(--bg-selected)] px-2.5 py-1 font-medium text-[var(--text-primary)]"
        >
          {copy.cardOpen}
        </button>
        <button
          type="button"
          onClick={onDismiss}
          className="text-[var(--text-muted)] hover:text-[var(--text-primary)]"
        >
          {copy.cardDismiss}
        </button>
      </div>
    </div>
  );
}
