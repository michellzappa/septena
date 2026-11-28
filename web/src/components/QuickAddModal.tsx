"use client";

import { useEffect, useRef, useState } from "react";
import { Folder, Link2, Star, Sun, X } from "lucide-react";
import type { AreaRow, ProjectRow, TaskAddedVia } from "@/lib/types";
import { DateBoardButton } from "./DateBoard";

export interface QuickAddInitial {
  /** How the sheet was reached, recorded on the new task (ADR 0064). Default "quick_add". */
  addedVia?: Extract<TaskAddedVia, "quick_add" | "share">;
  title?: string;
  notes?: string;
  referenceUrl?: string;
  today?: boolean;
  area?: string | null;
  project?: string | null;
}

interface QuickAddModalProps {
  open: boolean;
  initial?: QuickAddInitial | null;
  areas: AreaRow[];
  projects: ProjectRow[];
  todayYMD: string;
  lang: string;
  onClose: () => void;
  onCreate: (input: {
    title: string;
    notes?: string;
    today: boolean;
    starred: boolean;
    scheduled: string | null;
    deadline: string | null;
    area: string | null;
    project: string | null;
    referenceUrl?: string;
  }) => Promise<void>;
}

export function QuickAddModal({
  open,
  initial,
  areas,
  projects,
  todayYMD,
  lang,
  onClose,
  onCreate,
}: QuickAddModalProps) {
  const [title, setTitle] = useState("");
  const [notes, setNotes] = useState("");
  const [today, setToday] = useState(false);
  const [starred, setStarred] = useState(false);
  const [scheduled, setScheduled] = useState("");
  const [deadline, setDeadline] = useState("");
  const [moveValue, setMoveValue] = useState("inbox");
  const [referenceUrl, setReferenceUrl] = useState("");
  const [saving, setSaving] = useState(false);
  const titleRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (!open) return;
    setTitle(initial?.title ?? "");
    setNotes(initial?.notes ?? "");
    setToday(Boolean(initial?.today));
    setStarred(false);
    setScheduled("");
    setDeadline("");
    setReferenceUrl(initial?.referenceUrl ?? "");
    if (initial?.project) setMoveValue(`project:${initial.project}`);
    else if (initial?.area) setMoveValue(`area:${initial.area}`);
    else setMoveValue("inbox");
    setTimeout(() => titleRef.current?.focus(), 0);
  }, [initial, open]);

  if (!open) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const trimmed = title.trim();
    if (!trimmed || saving) return;
    setSaving(true);
    try {
      let area: string | null = null;
      let project: string | null = null;
      if (moveValue.startsWith("area:")) area = moveValue.slice(5);
      else if (moveValue.startsWith("project:")) {
        project = moveValue.slice(8);
        const p = projects.find((x) => x.id === project);
        area = p?.area ?? null;
      }
      await onCreate({
        title: trimmed,
        notes: notes.trim() || undefined,
        today,
        starred,
        scheduled: scheduled || null,
        deadline: deadline || null,
        area,
        project,
        referenceUrl: referenceUrl.trim() || undefined,
      });
      onClose();
    } finally {
      setSaving(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center bg-black/40 p-4 pt-[10vh]"
      onClick={onClose}
    >
      <form
        onSubmit={(e) => void handleSubmit(e)}
        onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            e.preventDefault();
            onClose();
          } else if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
            e.preventDefault();
            void handleSubmit(e);
          }
        }}
        className="w-full max-w-lg overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
      >
        <div className="flex items-center justify-between border-b border-[var(--border-subtle)] px-4 py-3">
          <span className="text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
            Quick Add
          </span>
          <button
            type="button"
            onClick={onClose}
            className="rounded-md p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
            aria-label="Close quick add"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="space-y-3 p-4">
          <input
            ref={titleRef}
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="New task title"
            className="w-full bg-transparent text-base font-medium text-[var(--text-primary)] outline-none placeholder:text-[var(--text-muted)]"
          />

          <textarea
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            rows={3}
            placeholder="Notes"
            className="w-full resize-none bg-transparent text-sm leading-relaxed text-[var(--text-secondary)] outline-none placeholder:text-[var(--text-muted)]"
          />

          {referenceUrl !== "" && (
            <div className="flex items-center gap-2 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1.5 text-xs text-[var(--text-secondary)]">
              <Link2 className="h-3.5 w-3.5 shrink-0 text-[var(--text-muted)]" />
              <input
                type="text"
                value={referenceUrl}
                onChange={(e) => setReferenceUrl(e.target.value)}
                placeholder="Reference link"
                className="min-w-0 flex-1 bg-transparent text-[var(--text-primary)] outline-none"
              />
              <button
                type="button"
                onClick={() => setReferenceUrl("")}
                className="text-[var(--text-muted)] hover:text-[var(--text-primary)]"
              >
                <X className="h-3 w-3" />
              </button>
            </div>
          )}

          <div className="flex flex-wrap items-center gap-2 border-t border-[var(--border-subtle)] pt-3 text-xs">
            <button
              type="button"
              onClick={() => {
                setToday((v) => !v);
                setScheduled("");
              }}
              className={`inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 font-medium transition-colors ${
                today
                  ? "bg-[var(--today-gold)]/20 text-[var(--text-primary)]"
                  : "bg-[var(--bg-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              }`}
            >
              <Sun
                className="h-3.5 w-3.5"
                style={today ? { color: "var(--today-gold)" } : undefined}
              />
              Today
            </button>

            <DateBoardButton
              attribute="when"
              className="px-2.5 py-1.5"
              value={scheduled || (today ? todayYMD : null)}
              today={todayYMD}
              lang={lang}
              onPick={(day) => {
                // Today is the pin, and the pin and a date are exclusive (TASK_DATES_SPEC I1).
                setToday(day === todayYMD);
                setScheduled(day === todayYMD ? "" : day);
              }}
              onClear={() => {
                setToday(false);
                setScheduled("");
              }}
            />

            <DateBoardButton
              attribute="deadline"
              className="px-2.5 py-1.5"
              value={deadline || null}
              today={todayYMD}
              lang={lang}
              onPick={setDeadline}
              onClear={() => setDeadline("")}
            />

            <label className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1.5 text-[var(--text-secondary)]">
              <Folder className="h-3.5 w-3.5" />
              <select
                value={moveValue}
                onChange={(e) => setMoveValue(e.target.value)}
                className="bg-transparent text-[var(--text-primary)] outline-none"
              >
                <option value="inbox">Inbox (top of Today)</option>
                {areas.map((a) => (
                  <option key={a.id} value={`area:${a.id}`}>
                    {a.emoji ? `${a.emoji} ` : ""}{a.title}
                  </option>
                ))}
                {projects.map((p) => (
                  <option key={p.id} value={`project:${p.id}`}>
                    ○ {p.title}
                  </option>
                ))}
              </select>
            </label>

            <button
              type="button"
              onClick={() => setStarred((v) => !v)}
              className={`inline-flex items-center gap-1 rounded-lg px-2 py-1.5 transition-colors ${
                starred
                  ? "bg-amber-500/15 text-amber-600 dark:text-amber-400"
                  : "bg-[var(--bg-hover)] text-[var(--text-secondary)]"
              }`}
              title="Star"
            >
              <Star
                className="h-3.5 w-3.5"
                style={starred ? { color: "#f59e0b", fill: "#f59e0b" } : undefined}
              />
            </button>
          </div>
        </div>

        <div className="flex items-center justify-between border-t border-[var(--border-subtle)] px-4 py-3 text-xs">
          <span className="text-[var(--text-muted)]">
            {moveValue === "inbox" && !today && !scheduled
              ? "Lands in Inbox at the top of Today"
              : "Press ⌘Return to add"}
          </span>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg bg-[var(--bg-hover)] px-3 py-1.5 font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!title.trim() || saving}
              className="rounded-lg bg-[var(--accent)] px-3.5 py-1.5 font-medium disabled:opacity-40"
              style={{ color: "var(--accent-check)" }}
            >
              Add
            </button>
          </div>
        </div>
      </form>
    </div>
  );
}
