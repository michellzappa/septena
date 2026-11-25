"use client";

import { useEffect, useState } from "react";
import { CheckCircle2, X } from "lucide-react";
import type { AreaRow, ProjectRow, TaskRow } from "@/lib/types";

interface FadeSweepModalProps {
  open: boolean;
  tasks: TaskRow[];
  areas: AreaRow[];
  projects: ProjectRow[];
  onClose: () => void;
  onKeep: (task: TaskRow) => Promise<void>;
  onLetRestGo: (tasks: TaskRow[]) => Promise<void>;
}

function inactiveDays(task: TaskRow): number {
  const ref = task.touchedAt || task.createdAt || (task.created ? `${task.created}T00:00:00Z` : null);
  if (!ref) return 14;
  const ms = Date.now() - Date.parse(ref);
  if (!Number.isFinite(ms) || ms < 0) return 14;
  return Math.max(14, Math.floor(ms / (24 * 60 * 60 * 1000)));
}

export function FadeSweepModal({
  open,
  tasks,
  areas,
  projects,
  onClose,
  onKeep,
  onLetRestGo,
}: FadeSweepModalProps) {
  const [remaining, setRemaining] = useState<TaskRow[]>([]);
  const [keptCount, setKeptCount] = useState(0);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (open) {
      setRemaining(tasks);
      setKeptCount(0);
    }
  }, [open, tasks]);

  if (!open) return null;

  const areaById = new Map(areas.map((a) => [a.id, a]));
  const projectById = new Map(projects.map((p) => [p.id, p]));

  const reasonFor = (task: TaskRow): string => {
    const days = inactiveDays(task);
    const listName = task.project
      ? projectById.get(task.project)?.title
      : task.area
        ? areaById.get(task.area)?.title
        : null;
    return listName
      ? `${days} days without activity · ${listName}`
      : `${days} days without activity`;
  };

  const handleKeep = async (task: TaskRow) => {
    await onKeep(task);
    setRemaining((prev) => prev.filter((t) => t.id !== task.id));
    setKeptCount((c) => c + 1);
  };

  const handleLetRestGo = async () => {
    if (busy || remaining.length === 0) return;
    setBusy(true);
    try {
      await onLetRestGo(remaining);
      onClose();
    } finally {
      setBusy(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      onClick={onClose}
    >
      <div
        className="flex max-h-[80vh] w-full max-w-lg flex-col overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-[var(--border-subtle)] px-5 py-3.5">
          <h2 className="text-base font-semibold text-[var(--text-primary)]">
            Review faded tasks
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg px-2 py-1 text-xs font-medium text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
          >
            Not now
          </button>
        </div>

        <div className="flex-1 overflow-y-auto">
          {remaining.length === 0 ? (
            <div className="flex flex-col items-center justify-center gap-2 px-6 py-14 text-center">
              <CheckCircle2 className="h-8 w-8 text-[var(--text-muted)]" />
              <p className="text-sm font-medium text-[var(--text-primary)]">
                {keptCount > 0 ? "You kept everything." : "No faded tasks to check."}
              </p>
              {keptCount > 0 && (
                <p className="text-xs text-[var(--text-muted)]">
                  Kept tasks are back in their lists.
                </p>
              )}
            </div>
          ) : (
            <div>
              <p className="border-b border-[var(--border-subtle)] px-5 py-3 text-xs text-[var(--text-secondary)]">
                Choose Keep for anything you still need. The rest move to your Logbook as let go, never deleted.
              </p>
              <div className="divide-y divide-[var(--border-subtle)]">
                {remaining.map((task) => (
                  <div key={task.id} className="flex items-center gap-3 px-5 py-3">
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm font-medium text-[var(--text-primary)]">
                        {task.title}
                      </p>
                      <p className="truncate text-xs text-[var(--text-muted)]">
                        {reasonFor(task)}
                      </p>
                    </div>
                    <button
                      type="button"
                      onClick={() => void handleKeep(task)}
                      className="shrink-0 rounded-lg border border-[var(--border-subtle)] px-3 py-1 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
                    >
                      Keep
                    </button>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        <div className="flex items-center justify-between border-t border-[var(--border-subtle)] px-5 py-3 text-xs">
          <span className="text-[var(--text-muted)]">
            {remaining.length > 0
              ? remaining.length === 1
                ? "1 task remaining"
                : `${remaining.length} tasks remaining`
              : ""}
          </span>
          {remaining.length === 0 ? (
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg bg-[var(--accent)] px-4 py-1.5 font-medium"
              style={{ color: "var(--accent-check)" }}
            >
              Done
            </button>
          ) : (
            <button
              type="button"
              disabled={busy}
              onClick={() => void handleLetRestGo()}
              className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--accent)] px-4 py-1.5 font-medium disabled:opacity-50"
              style={{ color: "var(--accent-check)" }}
            >
              Let the rest go
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
