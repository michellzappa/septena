"use client";

import { useEffect, useState } from "react";
import { SURFACES_CATALOG, registryText } from "@/lib/generated/registries";
import type { AccountSwitchSummary } from "@/lib/sync/accountSwitch";

// The question before a sign-in with another account replaces the tasks on
// this device (#575). Same choices as Apple's `SeptaskAccountSwitchPrompt`:
// Cancel (the default), Export a Backup First, Replace (destructive).

export type AccountSwitchChoice = "replace" | "exportFirst" | "cancel";

interface AccountSwitchDialogProps {
  summary: AccountSwitchSummary;
  language: string;
  onChoose: (choice: AccountSwitchChoice) => Promise<void>;
}

const ACCOUNT_SWITCH = SURFACES_CATALOG.accountSwitch;

function copy(id: string, lang: string, vars: Record<string, string | number> = {}): string {
  const label = ACCOUNT_SWITCH.copy.find((c) => c.id === id)?.label ?? id;
  return registryText(label, lang, vars);
}

export function AccountSwitchDialog({ summary, language, onChoose }: AccountSwitchDialogProps) {
  const [busy, setBusy] = useState(false);

  const choose = async (choice: AccountSwitchChoice) => {
    if (busy) return;
    setBusy(true);
    try {
      await onChoose(choice);
    } finally {
      setBusy(false);
    }
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        void choose("cancel");
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const lines = [
    copy("body", language),
    summary.tasks === 1
      ? copy("tasksOne", language, { count: 1 })
      : copy("tasksOther", language, { count: summary.tasks }),
  ];
  if (summary.unsent > 0) {
    lines.push(
      summary.unsent === 1
        ? copy("unsentOne", language, { count: 1 })
        : copy("unsentOther", language, { count: summary.unsent }),
    );
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/45 p-4">
      <div
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="account-switch-title"
        className="w-full max-w-md space-y-3 rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] p-5 text-xs shadow-2xl"
      >
        <h2 id="account-switch-title" className="text-sm font-semibold text-[var(--text-primary)]">
          {registryText(ACCOUNT_SWITCH.title, language)}
        </h2>
        {lines.map((line) => (
          <p key={line} className="leading-relaxed text-[var(--text-secondary)]">
            {line}
          </p>
        ))}
        <div className="flex flex-wrap items-center justify-end gap-2 pt-1">
          <button
            type="button"
            disabled={busy}
            onClick={() => void choose("replace")}
            className="rounded-lg bg-[var(--overdue-red)] px-3 py-1.5 font-medium text-white disabled:opacity-40"
          >
            {copy("replace", language)}
          </button>
          <button
            type="button"
            disabled={busy}
            onClick={() => void choose("exportFirst")}
            className="rounded-lg border border-[var(--border-subtle)] px-3 py-1.5 font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)] disabled:opacity-40"
          >
            {copy("export", language)}
          </button>
          <button
            type="button"
            autoFocus
            disabled={busy}
            onClick={() => void choose("cancel")}
            className="rounded-lg bg-[var(--bg-hover)] px-3 py-1.5 font-medium text-[var(--text-primary)] disabled:opacity-40"
          >
            {copy("cancel", language)}
          </button>
        </div>
      </div>
    </div>
  );
}
