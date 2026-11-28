"use client";

import { useEffect, useState } from "react";
import { Check, ChevronRight } from "lucide-react";

export type ContextMenuEntry =
  | { kind: "divider" }
  | {
      kind: "item";
      label: string;
      shortcut?: string;
      checked?: boolean;
      destructive?: boolean;
      onSelect: () => void;
    }
  | {
      kind: "submenu";
      label: string;
      items: ContextMenuEntry[];
    };

export interface ContextMenuState {
  x: number;
  y: number;
  items: ContextMenuEntry[];
  trigger?: HTMLElement;
}

export function ContextMenu({
  menu,
  onClose,
}: {
  menu: ContextMenuState | null;
  onClose: () => void;
}) {
  const [openSubmenuIdx, setOpenSubmenuIdx] = useState<number | null>(null);

  useEffect(() => {
    setOpenSubmenuIdx(null);
  }, [menu]);

  useEffect(() => {
    if (!menu) return;
    const handleClose = () => onClose();
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        onClose();
        menu.trigger?.focus();
      }
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
  const flipSubmenuLeft = left + 400 > vw;

  const renderEntry = (entry: ContextMenuEntry, idx: number, inSubmenu = false) => {
    if (entry.kind === "divider") {
      return <div key={`div-${idx}`} className="my-1 border-t border-[var(--border-subtle)]" />;
    }
    if (entry.kind === "submenu") {
      const isOpen = openSubmenuIdx === idx;
      return (
        <div
          key={`sub-${entry.label}-${idx}`}
          className="relative"
          onMouseEnter={() => setOpenSubmenuIdx(idx)}
        >
          <button
            type="button"
            onClick={() => setOpenSubmenuIdx((prev) => (prev === idx ? null : idx))}
            className={`flex w-full items-center justify-between gap-4 rounded-lg px-2.5 py-1.5 text-left text-xs transition-colors ${
              isOpen
                ? "bg-[var(--bg-hover)] text-[var(--text-primary)]"
                : "text-[var(--text-primary)] hover:bg-[var(--bg-hover)]"
            }`}
          >
            <span>{entry.label}</span>
            <ChevronRight className="h-3.5 w-3.5 shrink-0 text-[var(--text-muted)]" />
          </button>
          {isOpen && (
            <div
              className={`absolute top-0 z-50 min-w-[176px] rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] p-1.5 shadow-xl ${
                flipSubmenuLeft ? "right-full mr-1" : "left-full ml-1"
              }`}
            >
              {entry.items.map((child, childIdx) => renderEntry(child, childIdx, true))}
            </div>
          )}
        </div>
      );
    }
    return (
      <button
        key={`${entry.label}-${idx}`}
        type="button"
        autoFocus={Boolean(menu.trigger) && !inSubmenu && idx === 0}
        onMouseEnter={() => {
          if (!inSubmenu) setOpenSubmenuIdx(null);
        }}
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
        <span className="truncate">{entry.label}</span>
        {entry.checked ? (
          <Check className="h-3.5 w-3.5 shrink-0 text-[var(--accent)]" />
        ) : entry.shortcut ? (
          <span className="font-mono-tabular text-[10px] text-[var(--text-muted)]">
            {entry.shortcut}
          </span>
        ) : null}
      </button>
    );
  };

  return (
    <div
      style={{ left, top }}
      onClick={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.preventDefault()}
      className="fixed z-50 min-w-[196px] rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] p-1.5 shadow-xl"
    >
      {menu.items.map((entry, idx) => renderEntry(entry, idx))}
    </div>
  );
}
