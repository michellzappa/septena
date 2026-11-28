"use client";

import { useState } from "react";
import { addDays } from "@/lib/dateBoard";
import { registryText } from "@/lib/generated/registries";
import type { TaskRow } from "@/lib/types";
import { WAITING_ON_MAX, WAITING_SURFACE, waitingName } from "@/lib/waiting";
import { useEscapeToClose } from "@/lib/useEscapeToClose";

interface WaitingOnDialogProps {
  task: TaskRow;
  todayYMD: string;
  language: string;
  onClose: () => void;
  /** `checkBack` is the When date to set, or null for no date. */
  onSave: (name: string, checkBack: string | null) => Promise<void>;
}

/**
 * The Waiting On… sheet (REVIEW_SPEC §6): a name and a Check back day. The day
 * is the task's When date; it defaults to a week out, and No date clears it.
 * It mounts when it opens.
 */
export function WaitingOnDialog({ task, todayYMD, language, onClose, onSave }: WaitingOnDialogProps) {
  const text = (key: string) => registryText(key, language);
  const sheet = WAITING_SURFACE.sheet;
  useEscapeToClose(true, onClose);
  const alreadyWaiting = Boolean(waitingName(task));
  const defaultDay = alreadyWaiting
    ? (task.scheduled ?? null)
    : addDays(todayYMD, WAITING_SURFACE.defaultCheckBackDays);
  const [name, setName] = useState(waitingName(task) ?? "");
  const [noDate, setNoDate] = useState(defaultDay === null);
  const [day, setDay] = useState(defaultDay ?? addDays(todayYMD, WAITING_SURFACE.defaultCheckBackDays));
  const [busy, setBusy] = useState(false);

  const canSave = name.trim().length > 0 && (noDate || Boolean(day)) && !busy;

  const submit = async () => {
    if (!canSave) return;
    setBusy(true);
    try {
      await onSave(name.trim(), noDate ? null : day);
      onClose();
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <form
        className="w-full max-w-sm overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
        onSubmit={(e) => {
          e.preventDefault();
          void submit();
        }}
      >
        <div className="border-b border-[var(--border-subtle)] px-5 py-3.5">
          <h2 className="text-base font-semibold text-[var(--text-primary)]">{text(sheet.title)}</h2>
          <p className="mt-0.5 truncate text-xs text-[var(--text-muted)]">{task.title}</p>
        </div>

        <div className="space-y-3 px-5 py-4 text-sm">
          <input
            type="text"
            autoFocus
            value={name}
            maxLength={WAITING_ON_MAX}
            onChange={(e) => setName(e.target.value)}
            placeholder={text(sheet.placeholder)}
            className="w-full rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-canvas)] px-3 py-2 text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
          />

          <div className="flex items-center justify-between gap-3">
            <span className="text-[var(--text-secondary)]">{text(sheet.checkBack.title)}</span>
            <input
              type="date"
              value={noDate ? "" : day}
              disabled={noDate}
              min={todayYMD}
              onChange={(e) => setDay(e.target.value)}
              className="rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-canvas)] px-2 py-1 text-xs text-[var(--text-primary)] outline-none focus:border-[var(--accent)] disabled:opacity-40"
            />
          </div>

          <label className="flex cursor-pointer items-center gap-2 text-xs text-[var(--text-secondary)]">
            <input type="checkbox" checked={noDate} onChange={(e) => setNoDate(e.target.checked)} />
            {text(sheet.noCheckBack.title)}
          </label>
        </div>

        <div className="flex items-center justify-end gap-2 border-t border-[var(--border-subtle)] px-5 py-3 text-xs">
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg px-3 py-1.5 font-medium text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
          >
            {text("Cancel")}
          </button>
          <button
            type="submit"
            disabled={!canSave}
            className="rounded-lg bg-[var(--accent)] px-4 py-1.5 font-medium disabled:opacity-50"
            style={{ color: "var(--accent-check)" }}
          >
            {text(sheet.confirmTitle)}
          </button>
        </div>
      </form>
    </div>
  );
}
