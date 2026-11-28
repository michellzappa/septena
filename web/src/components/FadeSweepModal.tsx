"use client";

import { useState } from "react";
import { CheckCircle2 } from "lucide-react";
import { ACTIONS_CATALOG, DOMAIN_RULES, SURFACES_CATALOG, registryText } from "@/lib/generated/registries";
import type { AreaRow, ProjectRow, TaskRow } from "@/lib/types";

interface FadeSweepModalProps {
  tasks: TaskRow[];
  areas: AreaRow[];
  projects: ProjectRow[];
  language: string;
  onClose: () => void;
  onKeep: (task: TaskRow) => Promise<void>;
  onLetRestGo: (tasks: TaskRow[]) => Promise<void>;
  /** The user answered the whole sheet: the sweep is done until the next one. */
  onSwept: () => Promise<void>;
}

function inactiveDays(task: TaskRow): number {
  const ref = task.touchedAt || task.createdAt || (task.created ? `${task.created}T00:00:00Z` : null);
  if (!ref) return DOMAIN_RULES.fadeWindowDays;
  const ms = Date.now() - Date.parse(ref);
  if (!Number.isFinite(ms) || ms < 0) return DOMAIN_RULES.fadeWindowDays;
  return Math.max(DOMAIN_RULES.fadeWindowDays, Math.floor(ms / (24 * 60 * 60 * 1000)));
}

/** The keep-or-let-go sheet (docs/TASK_FADE_SPEC.md §5). It mounts when it opens. */
export function FadeSweepModal({
  tasks,
  areas,
  projects,
  language,
  onClose,
  onKeep,
  onLetRestGo,
  onSwept,
}: FadeSweepModalProps) {
  const [remaining, setRemaining] = useState<TaskRow[]>(tasks);
  const [keptCount, setKeptCount] = useState(0);
  // Rows dropped by Let the rest go. Non-zero shows the permission line (#711).
  const [letGoCount, setLetGoCount] = useState(0);
  const [busy, setBusy] = useState(false);

  const text = (key: string, vars?: Record<string, string | number>) => registryText(key, language, vars);
  const areaById = new Map(areas.map((a) => [a.id, a]));
  const projectById = new Map(projects.map((p) => [p.id, p]));

  const reasonFor = (task: TaskRow): string => {
    const days = inactiveDays(task);
    const listName = task.project
      ? projectById.get(task.project)?.title
      : task.area
        ? areaById.get(task.area)?.title
        : null;
    return [
      text("{days} days without activity", { days }),
      text(task.scheduled ? "Past date" : "No date"),
      listName ?? text("Inbox"),
    ].join(" · ");
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
      const count = remaining.length;
      await onLetRestGo(remaining);
      await onSwept();
      setLetGoCount(count);
      setRemaining([]);
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
            {text("Faded Tasks")}
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg px-2 py-1 text-xs font-medium text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
          >
            {text("Not now")}
          </button>
        </div>

        <div className="flex-1 overflow-y-auto">
          {remaining.length === 0 ? (
            <div className="flex flex-col items-center justify-center gap-2 px-6 py-14 text-center">
              <CheckCircle2 className="h-8 w-8 text-[var(--text-muted)]" />
              <p className="text-sm font-medium text-[var(--text-primary)]">
                {letGoCount > 0
                  ? text(SURFACES_CATALOG.fadeSweep.letGoTitle)
                  : text(keptCount > 0 ? "You kept everything." : "No faded tasks to check.")}
              </p>
              {keptCount > 0 && letGoCount === 0 && (
                <p className="text-xs text-[var(--text-muted)]">
                  {text("Kept tasks are back in their lists.")}
                </p>
              )}
            </div>
          ) : (
            <div>
              <p className="border-b border-[var(--border-subtle)] px-5 py-3 text-xs text-[var(--text-secondary)]">
                {text("Choose Keep for anything you still need. The rest move to your Logbook as let go, never deleted.")}
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
                      {text(ACTIONS_CATALOG.actions["task.keepFaded"].title)}
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
                ? text("1 task remaining")
                : text("{count} tasks remaining", { count: remaining.length })
              : ""}
          </span>
          {remaining.length === 0 ? (
            <button
              type="button"
              onClick={() => void onSwept().then(onClose)}
              className="rounded-lg bg-[var(--accent)] px-4 py-1.5 font-medium"
              style={{ color: "var(--accent-check)" }}
            >
              {text("Done")}
            </button>
          ) : (
            <button
              type="button"
              disabled={busy}
              onClick={() => void handleLetRestGo()}
              className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--accent)] px-4 py-1.5 font-medium disabled:opacity-50"
              style={{ color: "var(--accent-check)" }}
            >
              {text("Let the rest go")}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
