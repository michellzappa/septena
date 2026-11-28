"use client";

import { X } from "lucide-react";
import { ACTIONS_CATALOG, registryText } from "@/lib/generated/registries";
import type { SmartDestination } from "@/lib/types";
import { useEscapeToClose } from "@/lib/useEscapeToClose";

interface KeyboardShortcutsModalProps {
  open: boolean;
  language: string;
  orderedDestinations: Array<{ id: SmartDestination; title: string }>;
  onClose: () => void;
}

interface ShortcutSpec {
  key: string;
  modifiers: readonly string[];
  excludePlatforms?: readonly string[];
  alternates?: readonly ShortcutSpec[];
}

export function formatShortcutKeycaps(sc: ShortcutSpec, isMac: boolean): string[] {
  const caps: string[] = [];
  for (const mod of sc.modifiers) {
    if (mod === "ctrl") caps.push(isMac ? "⌃" : "Ctrl");
    else if (mod === "alt") caps.push(isMac ? "⌥" : "Alt");
    else if (mod === "shift") caps.push(isMac ? "⇧" : "Shift");
    else if (mod === "primary") caps.push(isMac ? "⌘" : "Ctrl");
  }
  const k = sc.key.toLowerCase();
  if (k === "delete") caps.push("⌫");
  else if (k === "return") caps.push("↩");
  else if (k === "space") caps.push("Space");
  else caps.push(sc.key.length === 1 ? sc.key.toUpperCase() : sc.key);
  return caps;
}

export function KeyboardShortcutsModal({
  open,
  language,
  orderedDestinations,
  onClose,
}: KeyboardShortcutsModalProps) {
  useEscapeToClose(open, onClose);

  if (!open) return null;

  const isMac =
    typeof navigator !== "undefined" && /Mac|iPhone|iPad/i.test(navigator.platform || navigator.userAgent);
  const primaryCap = isMac ? "⌘" : "Ctrl";
  const actionsMap = ACTIONS_CATALOG.actions as Record<
    string,
    {
      title: string;
      desktopTitle?: string;
      shortcut?: ShortcutSpec;
      availability?: { platforms?: readonly string[] };
    }
  >;

  const renderGroup = (
    title: string,
    rows: Array<{ label: string; keys: string[] }>,
  ) => (
    <section key={title}>
      <h3 className="mb-2 text-xs font-semibold tracking-wide text-[var(--text-muted)] uppercase">
        {title}
      </h3>
      <div className="divide-y divide-[var(--border-subtle)] rounded-xl border border-[var(--border-subtle)]">
        {rows.map((row) => (
          <div key={`${row.label}-${row.keys.join("")}`} className="flex items-center justify-between gap-4 px-3.5 py-2 text-xs">
            <span className="text-[var(--text-primary)]">{row.label}</span>
            <span className="flex items-center gap-1">
              {row.keys.map((k, idx) => (
                <kbd
                  key={`${k}-${idx}`}
                  className="font-mono-tabular inline-flex min-w-[22px] items-center justify-center rounded-md border border-[var(--border-subtle)] bg-[var(--bg-hover)] px-1.5 py-0.5 text-[11px] font-medium text-[var(--text-secondary)]"
                >
                  {k}
                </kbd>
              ))}
            </span>
          </div>
        ))}
      </div>
    </section>
  );

  const navRows = orderedDestinations.slice(0, 9).map((d, idx) => ({
    label: registryText(d.title, language),
    keys: [isMac ? "⌥" : "Alt", String(idx + 1)],
  }));

  const sheetGroups = ACTIONS_CATALOG.shortcutsSheet.map((grp) => {
    const rows: Array<{ label: string; keys: string[] }> = [];
    if (grp.id === "taskList") {
      rows.push(
        { label: "Move selection", keys: ["↑", "↓"] },
        { label: "Open / edit", keys: ["↩"] },
        { label: "Select multiple", keys: [primaryCap, "Click"] },
        { label: "Select range", keys: ["⇧", "Click"] },
        { label: "Select all", keys: [primaryCap, "A"] },
        { label: "Undo / Redo", keys: [primaryCap, "Z"] },
        { label: "Clear selection / close", keys: ["Esc"] },
      );
    }
    for (const id of grp.actionIds) {
      const def = actionsMap[id];
      if (!def?.shortcut) continue;
      if (def.shortcut.excludePlatforms?.includes("web")) continue;
      if (def.availability?.platforms && !def.availability.platforms.includes("web")) continue;
      if (id === "task.moveSuggested") continue;
      const label = registryText(def.desktopTitle ?? def.title, language);
      rows.push({
        label,
        keys: formatShortcutKeycaps(def.shortcut, isMac),
      });
      for (const alt of def.shortcut.alternates ?? []) {
        if (alt.excludePlatforms?.includes("web")) continue;
        rows.push({
          label,
          keys: formatShortcutKeycaps(alt, isMac),
        });
      }
    }
    return { title: grp.title, rows };
  });

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      onClick={onClose}
    >
      <div
        className="flex max-h-[82vh] w-full max-w-lg flex-col overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-[var(--border-subtle)] px-5 py-3.5">
          <h2 className="text-base font-semibold text-[var(--text-primary)]">
            {registryText("Keyboard Shortcuts", language)}
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
            aria-label="Close keyboard shortcuts"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
        <div className="flex-1 space-y-5 overflow-y-auto p-5">
          {renderGroup("Navigation", navRows)}
          {sheetGroups.map((g) => renderGroup(g.title, g.rows))}
        </div>
      </div>
    </div>
  );
}
