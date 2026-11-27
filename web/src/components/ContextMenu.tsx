"use client";

import { Check } from "lucide-react";
import { useEffect } from "react";

export type ContextMenuEntry =
  | { kind: "divider" }
  | {
      kind: "item";
      label: string;
      shortcut?: string;
      /** Shows a check: the current choice of a menu of choices. */
      checked?: boolean;
      destructive?: boolean;
      onSelect: () => void;
    };

export interface ContextMenuState {
  x: number;
  y: number;
  items: ContextMenuEntry[];
}

export function ContextMenu({
  menu,
  onClose,
}: {
  menu: ContextMenuState | null;
  onClose: () => void;
}) {
  useEffect(() => {
    if (!menu) return;
    const handleClose = () => onClose();
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("click", handleClose);
    window.addEventListener("scroll", handleClose, true);
    window.addEventListener("keydown", handleKey);
    return () => {
      window.removeEventListener("click", handleClose);
      window.removeEventListener("scroll", handleClose, true);
      window.removeEventListener("keydown", handleKey);
    };
  }, [menu, onClose]);

  if (!menu) return null;

  const vw = typeof window !== "undefined" ? window.innerWidth : 1200;
  const vh = typeof window !== "undefined" ? window.innerHeight : 800;
  const left = Math.min(menu.x, Math.max(8, vw - 220));
  const top = Math.min(menu.y, Math.max(8, vh - menu.items.length * 32 - 20));

  return (
    <div
      style={{ left, top }}
      onClick={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.preventDefault()}
      className="fixed z-50 min-w-[196px] rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] p-1.5 shadow-xl"
    >
      {menu.items.map((entry, idx) =>
        entry.kind === "divider" ? (
          <div key={`div-${idx}`} className="my-1 border-t border-[var(--border-subtle)]" />
        ) : (
          <button
            key={`${entry.label}-${idx}`}
            type="button"
            role={entry.checked !== undefined ? "menuitemradio" : undefined}
            aria-checked={entry.checked}
            onClick={() => {
              onClose();
              entry.onSelect();
            }}
            className={`flex w-full items-center justify-between gap-4 rounded-lg px-2.5 py-1.5 text-left text-xs transition-colors ${
              entry.destructive
                ? "text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
                : "text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
            }`}
          >
            <span className="flex items-center gap-2">
              {entry.checked !== undefined && (
                <Check className={`h-3.5 w-3.5 ${entry.checked ? "" : "invisible"}`} aria-hidden="true" />
              )}
              {entry.label}
            </span>
            {entry.shortcut && (
              <span className="font-mono-tabular text-[10px] text-[var(--text-muted)]">
                {entry.shortcut}
              </span>
            )}
          </button>
        ),
      )}
    </div>
  );
}
