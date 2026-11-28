"use client";

import { useMemo, useState } from "react";
import { Check, Inbox } from "lucide-react";
import { useEscapeToClose } from "@/lib/useEscapeToClose";

export interface MovePickerTarget {
  /** Null is the "no container" row (No Area). */
  id: string | null;
  title: string;
  emoji?: string | null;
}

interface MovePickerDialogProps {
  title: string;
  subtitle?: string;
  targets: MovePickerTarget[];
  currentId: string | null;
  searchPlaceholder: string;
  onPick: (id: string | null) => void;
  onClose: () => void;
}

/**
 * The Move… picker: a type-to-filter list of destinations. Project ▸ Move…
 * (`project.move`) opens it with No Area and the areas, like the Move sheet on
 * the other platforms. Arrows move the selection, Return picks, Escape closes.
 * It mounts when it opens.
 */
export function MovePickerDialog({
  title,
  subtitle,
  targets,
  currentId,
  searchPlaceholder,
  onPick,
  onClose,
}: MovePickerDialogProps) {
  const [query, setQuery] = useState("");
  const rows = useMemo(() => {
    const q = query.trim().toLowerCase();
    return q ? targets.filter((t) => t.title.toLowerCase().includes(q)) : targets;
  }, [targets, query]);
  const currentIndex = rows.findIndex((t) => t.id === currentId);
  const [active, setActive] = useState(currentIndex >= 0 ? currentIndex : 0);
  const activeIndex = Math.min(active, Math.max(rows.length - 1, 0));
  useEscapeToClose(true, onClose);

  const choose = (target: MovePickerTarget | undefined) => {
    if (!target) return;
    if (target.id !== currentId) onPick(target.id);
    onClose();
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div
        role="dialog"
        aria-label={title}
        className="w-full max-w-sm overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          if (e.key === "ArrowDown") {
            e.preventDefault();
            setActive(Math.min(activeIndex + 1, rows.length - 1));
          } else if (e.key === "ArrowUp") {
            e.preventDefault();
            setActive(Math.max(activeIndex - 1, 0));
          } else if (e.key === "Enter") {
            e.preventDefault();
            choose(rows[activeIndex]);
          }
        }}
      >
        <div className="border-b border-[var(--border-subtle)] px-5 py-3.5">
          <h2 className="text-base font-semibold text-[var(--text-primary)]">{title}</h2>
          {subtitle && <p className="mt-0.5 truncate text-xs text-[var(--text-muted)]">{subtitle}</p>}
          <input
            type="text"
            autoFocus
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setActive(0);
            }}
            placeholder={searchPlaceholder}
            className="mt-3 w-full rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-canvas)] px-3 py-2 text-sm text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
          />
        </div>
        <ul className="max-h-80 overflow-y-auto py-1.5 text-sm">
          {rows.map((target, idx) => (
            <li key={target.id ?? "none"}>
              <button
                type="button"
                onMouseEnter={() => setActive(idx)}
                onClick={() => choose(target)}
                className={`flex w-full items-center gap-2.5 px-5 py-2 text-left text-[var(--text-primary)] ${
                  idx === activeIndex ? "bg-[var(--bg-hover)]" : ""
                }`}
              >
                <span className="flex w-5 justify-center text-[var(--text-muted)]">
                  {target.id === null ? <Inbox className="h-3.5 w-3.5" /> : (target.emoji || "•")}
                </span>
                <span className={`flex-1 truncate ${target.id === currentId ? "font-semibold" : ""}`}>
                  {target.title}
                </span>
                {target.id === currentId && <Check className="h-3.5 w-3.5 text-[var(--accent)]" />}
              </button>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
