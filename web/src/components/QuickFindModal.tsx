"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import {
  CheckCircle2,
  Circle,
  Folder,
  Search,
  Tag,
} from "lucide-react";
import { SIDEBAR_DESTINATIONS } from "@/lib/destinations";
import { SURFACES_CATALOG, registryText } from "@/lib/generated/registries";
import type { ActiveDestination, AreaRow, ProjectRow, SmartDestination, TagRow, TaskRow } from "@/lib/types";
import { RegistryIcon } from "./RegistryIcon";

export interface CommandBarItem {
  id: string;
  title: string;
  icon: string;
  shortcutKeys?: string[];
  keywords?: string[];
  contextual?: boolean;
  run: () => void;
}

interface QuickFindModalProps {
  open: boolean;
  onClose: () => void;
  tasks: TaskRow[];
  areas: AreaRow[];
  projects: ProjectRow[];
  tags: TagRow[];
  commands?: CommandBarItem[];
  language: string;
  onNavigate: (dest: ActiveDestination) => void;
  onSelectTask: (task: TaskRow) => void;
  onSelectTagFilter: (tagId: string) => void;
}

type ResultItem =
  | { kind: "command"; command: CommandBarItem }
  | { kind: "smart"; id: SmartDestination; icon: string; title: string; subtitle: string }
  | { kind: "area"; area: AreaRow }
  | { kind: "project"; project: ProjectRow }
  | { kind: "tag"; tag: TagRow }
  | { kind: "task"; task: TaskRow };

function scoreCommand(cmd: CommandBarItem, rawQuery: string, tokens: string[]): number {
  const title = cmd.title.toLowerCase();
  const body = (cmd.keywords ?? []).join(" ").toLowerCase();
  let total = 0;
  for (const tok of tokens) {
    const inTitle = title.includes(tok);
    const inBody = body.includes(tok);
    if (!inTitle && !inBody) return 0;
    if (inTitle) {
      total += 10;
      if (title.startsWith(tok)) total += 8;
      else if (title.includes(` ${tok}`)) total += 4;
    }
    if (inBody) total += 3;
  }
  if (title === rawQuery) total += 20;
  return total + (cmd.contextual ? 10 : 0);
}

export function QuickFindModal({
  open,
  onClose,
  tasks,
  areas,
  projects,
  tags,
  commands = [],
  language,
  onNavigate,
  onSelectTask,
  onSelectTagFilter,
}: QuickFindModalProps) {
  const [query, setQuery] = useState("");
  const [activeIndex, setActiveIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (open) {
      setQuery("");
      setActiveIndex(0);
      setTimeout(() => inputRef.current?.focus(), 0);
    }
  }, [open]);

  const results = useMemo(() => {
    const raw = query.trim();
    const commandsOnly = raw.startsWith(">");
    const q = (commandsOnly ? raw.slice(1).trim() : raw).toLowerCase();
    const tokens = q ? q.split(/\s+/).filter(Boolean) : [];

    const matchCommands = (): ResultItem[] => {
      if (!q) return commands.map((command) => ({ kind: "command", command }));
      return commands
        .map((command, idx) => ({ command, score: scoreCommand(command, q, tokens), idx }))
        .filter((x) => x.score > 0)
        .sort((a, b) => b.score - a.score || a.idx - b.idx)
        .map(({ command }) => ({ kind: "command", command }));
    };

    if (commandsOnly) {
      return matchCommands().slice(0, 40);
    }

    const out: ResultItem[] = [];

    if (!q) {
      const contextual = commands.filter((c) => c.contextual).slice(0, 6);
      const global = commands.filter((c) => !c.contextual).slice(0, 6);
      for (const command of contextual) out.push({ kind: "command", command });
      for (const d of SIDEBAR_DESTINATIONS) {
        const title = registryText(d.title, language);
        out.push({ kind: "smart", id: d.id, icon: d.icon, title, subtitle: "List" });
      }
      for (const command of global) out.push({ kind: "command", command });
      for (const a of areas) {
        if (!a.deletedAt) out.push({ kind: "area", area: a });
      }
      for (const p of projects) {
        if (!p.deletedAt && p.status === "active") out.push({ kind: "project", project: p });
      }
      return out.slice(0, 40);
    }

    out.push(...matchCommands());

    for (const d of SIDEBAR_DESTINATIONS) {
      const title = registryText(d.title, language);
      if (title.toLowerCase().includes(q)) {
        out.push({ kind: "smart", id: d.id, icon: d.icon, title, subtitle: "List" });
      }
    }
    for (const a of areas) {
      if (a.deletedAt) continue;
      if (a.title.toLowerCase().includes(q)) out.push({ kind: "area", area: a });
    }
    for (const p of projects) {
      if (p.deletedAt || p.status !== "active") continue;
      if (p.title.toLowerCase().includes(q)) out.push({ kind: "project", project: p });
    }
    for (const t of tags) {
      if (t.deletedAt) continue;
      if (t.name.toLowerCase().includes(q)) out.push({ kind: "tag", tag: t });
    }
    let count = 0;
    for (const task of tasks) {
      if (task.deletedAt || task.kind === "heading") continue;
      if (
        task.title.toLowerCase().includes(q) ||
        (task.notes && task.notes.toLowerCase().includes(q))
      ) {
        out.push({ kind: "task", task });
        if (++count >= 25) break;
      }
    }
    return out.slice(0, 40);
  }, [areas, commands, language, projects, query, tags, tasks]);

  useEffect(() => {
    setActiveIndex(0);
  }, [query]);

  useEffect(() => {
    const el = listRef.current?.querySelector<HTMLElement>(`[data-cmd-idx="${activeIndex}"]`);
    el?.scrollIntoView({ block: "nearest" });
  }, [activeIndex, open]);

  if (!open) return null;

  const activate = (item: ResultItem) => {
    if (item.kind === "command") {
      onClose();
      setTimeout(() => item.command.run(), 0);
      return;
    }
    if (item.kind === "smart") onNavigate({ kind: "smart", id: item.id });
    else if (item.kind === "area") onNavigate({ kind: "area", id: item.area.id });
    else if (item.kind === "project") onNavigate({ kind: "project", id: item.project.id });
    else if (item.kind === "tag") onSelectTagFilter(item.tag.id);
    else onSelectTask(item.task);
    onClose();
  };

  const placeholder = registryText(SURFACES_CATALOG.quickFind.commandPlaceholder, language);

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center bg-black/40 p-4 pt-[12vh]"
      onClick={onClose}
    >
      <div
        className="w-full max-w-lg overflow-hidden rounded-2xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-2.5 border-b border-[var(--border-subtle)] px-4 py-3">
          <Search className="h-4 w-4 text-[var(--text-muted)]" />
          <input
            ref={inputRef}
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "ArrowDown") {
                e.preventDefault();
                setActiveIndex((i) => Math.min(Math.max(0, results.length - 1), i + 1));
              } else if (e.key === "ArrowUp") {
                e.preventDefault();
                setActiveIndex((i) => Math.max(0, i - 1));
              } else if (e.key === "Enter" && results[activeIndex]) {
                e.preventDefault();
                activate(results[activeIndex]);
              } else if (e.key === "Escape") {
                e.preventDefault();
                onClose();
              }
            }}
            placeholder={placeholder}
            className="min-w-0 flex-1 bg-transparent text-sm text-[var(--text-primary)] outline-none placeholder:text-[var(--text-muted)]"
          />
          <kbd className="font-mono-tabular rounded bg-[var(--bg-hover)] px-1.5 py-0.5 text-[10px] text-[var(--text-muted)]">
            ESC
          </kbd>
        </div>

        <div ref={listRef} className="max-h-96 overflow-y-auto p-1.5">
          {results.length === 0 ? (
            <div className="py-10 text-center text-xs text-[var(--text-muted)]">No matches</div>
          ) : (
            results.map((item, idx) => {
              const selected = idx === activeIndex;
              let key = "";
              let label = "";
              let meta = "";
              let shortcutKeys: string[] | undefined;
              let icon = <Circle className="h-3.5 w-3.5 text-[var(--text-muted)]" />;

              if (item.kind === "command") {
                key = `cmd:${item.command.id}`;
                label = item.command.title;
                shortcutKeys = item.command.shortcutKeys;
                meta = shortcutKeys?.length ? "" : item.command.contextual ? "Task" : "Command";
                icon = <RegistryIcon token={item.command.icon} className="h-3.5 w-3.5 text-[var(--text-muted)]" />;
              } else if (item.kind === "smart") {
                key = `smart:${item.id}`;
                label = item.title;
                meta = item.subtitle;
                const tint =
                  item.id === "today"
                    ? "text-[var(--today-gold)]"
                    : item.id === "starred"
                      ? "text-amber-500"
                      : item.id === "review"
                        ? "text-[var(--accent)]"
                        : "text-[var(--text-muted)]";
                icon = <RegistryIcon token={item.icon} className={`h-3.5 w-3.5 ${tint}`} />;
              } else if (item.kind === "area") {
                key = `area:${item.area.id}`;
                label = `${item.area.emoji ? `${item.area.emoji} ` : ""}${item.area.title}`;
                meta = "Area";
                icon = <Folder className="h-3.5 w-3.5 text-[var(--text-muted)]" />;
              } else if (item.kind === "project") {
                key = `project:${item.project.id}`;
                label = item.project.title;
                meta = "Project";
              } else if (item.kind === "tag") {
                key = `tag:${item.tag.id}`;
                label = item.tag.name;
                meta = "Tag filter";
                icon = <Tag className="h-3.5 w-3.5 text-[var(--text-muted)]" />;
              } else {
                key = `task:${item.task.id}`;
                label = item.task.title;
                meta = item.task.status === "done" ? "Logbook" : item.task.scheduled ?? "Task";
                icon = item.task.status === "done"
                  ? <CheckCircle2 className="h-3.5 w-3.5 text-[var(--accent)]" />
                  : <Circle className="h-3.5 w-3.5 text-[var(--text-muted)]" />;
              }

              return (
                <button
                  key={key}
                  data-cmd-idx={idx}
                  type="button"
                  onMouseEnter={() => setActiveIndex(idx)}
                  onClick={() => activate(item)}
                  className={`flex w-full items-center gap-2.5 rounded-lg px-3 py-2 text-left text-sm transition-colors ${
                    selected
                      ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                      : "text-[var(--text-secondary)] hover:bg-[var(--bg-hover)]"
                  }`}
                >
                  <span className="shrink-0">{icon}</span>
                  <span className="min-w-0 flex-1 truncate">{label}</span>
                  {shortcutKeys && shortcutKeys.length > 0 ? (
                    <span className="flex shrink-0 items-center gap-0.5">
                      {shortcutKeys.map((k, kIdx) => (
                        <kbd
                          key={`${k}-${kIdx}`}
                          className="font-mono-tabular inline-flex min-w-[20px] items-center justify-center rounded border border-[var(--border-subtle)] bg-[var(--bg-hover)] px-1 py-0.5 text-[10px] font-medium text-[var(--text-muted)]"
                        >
                          {k}
                        </kbd>
                      ))}
                    </span>
                  ) : (
                    <span className="font-mono-tabular shrink-0 text-[11px] text-[var(--text-muted)]">{meta}</span>
                  )}
                </button>
              );
            })
          )}
        </div>
      </div>
    </div>
  );
}
