"use client";

import { useEffect } from "react";
import { X } from "lucide-react";
import { TaskDetailEditor, type TaskRowItemProps } from "./TaskRowItem";

interface TaskPageDrawerProps {
  open: boolean;
  itemProps: TaskRowItemProps | null;
  onClose: () => void;
}

/**
 * Dedicated slide-over Task Page inspector (ADR 0029, Cmd/Ctrl+Opt+I),
 * presenting all canonical taskPage blocks in registry order alongside the list.
 */
export function TaskPageDrawer({ open, itemProps, onClose }: TaskPageDrawerProps) {
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

  if (!open || !itemProps) return null;

  return (
    <div className="fixed inset-0 z-40 flex justify-end bg-black/25" onClick={onClose}>
      <aside
        className="flex h-full w-full max-w-lg flex-col border-l border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-[var(--border-subtle)] px-5 py-3.5">
          <div className="flex items-center gap-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
            <span>Task</span>
            {itemProps.containerLabel && (
              <>
                <span>·</span>
                <span className="truncate font-normal normal-case text-[var(--text-secondary)]">
                  {itemProps.containerLabel}
                </span>
              </>
            )}
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
            aria-label="Close task page"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-5">
          <TaskDetailEditor props={itemProps} isPageMode />
        </div>
      </aside>
    </div>
  );
}
