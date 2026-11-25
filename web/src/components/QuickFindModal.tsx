"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Calendar, CheckCircle2, Circle, Folder, Layers, Repeat, Search, Sparkles, Star, Tag } from "lucide-react";
import type { ActiveDestination, AreaRow, ProjectRow, SmartDestination, TagRow, TaskRow } from "@/lib/types";

interface QuickFindModalProps {
  open: boolean;
  onClose: () => void;
  tasks: TaskRow[];
  areas: AreaRow[];
  projects: ProjectRow[];
  tags: TagRow[];
  onNavigate: (dest: ActiveDestination) => void;
  onSelectTask: (task: TaskRow) => void;
  onSelectTagFilter: (tagId: string) => void;
}

type ResultItem =
  | { kind: "smart"; id: SmartDestination; title: string; subtitle: string }
  | { kind: "area"; area: AreaRow }
  | { kind: "project"; project: ProjectRow }
  | { kind: "tag"; tag: TagRow }
  | { kind: "task"; task: TaskRow };

const SMART_TARGETS: Array<{ id: SmartDestination; title: string }> = [
  { id: "today", title: "Today" },
  { id: "review", title: "Review" },
  { id: "agent", title: "Agent" },
  { id: "upcoming", title: "Upcoming" },
  { id: "repeating", title: "Repeating" },
  { id: "anytime", title: "Anytime" },
  { id: "starred", title: "Favorites" },
  { id: "logbook", title: "Logbook" },
  { id: "faded", title: "Faded" },
];

export function QuickFindModal({
  open,
  onClose,
  tasks,
  areas,
  projects,
  tags,
  onNavigate,
  onSelectTask,
  onSelectTagFilter,
}: QuickFindModalProps) {
  const [query, setQuery] = useState("");
  const [activeIndex, setActiveIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (open) {
      setQuery("");
      setActiveIndex(0);
      setTimeout(() => inputRef.current?.focus(), 0);
    }
  }, [open]);

  const results = useMemo(() => {
    const q = query.trim().toLowerCase();
    const out: ResultItem[] = [];

    for (const s of SMART_TARGETS) {
      if (!q || s.title.toLowerCase().includes(q)) {
        out.push({ kind: "smart", id: s.id, title: s.title, subtitle: "List" });
      }
    }
    for (const a of areas) {
      if (a.deletedAt) continue;
      if (!q || a.title.toLowerCase().includes(q)) out.push({ kind: "area", area: a });
    }
    for (const p of projects) {
      if (p.deletedAt || p.status !== "active") continue;
      if (!q || p.title.toLowerCase().includes(q)) out.push({ kind: "project", project: p });
    }
    for (const t of tags) {
      if (t.deletedAt) continue;
      if (q && t.name.toLowerCase().includes(q)) out.push({ kind: "tag", tag: t });
    }
    if (q) {
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
    }
    return out.slice(0, 30);
  }, [areas, projects, query, tags, tasks]);

  useEffect(() => {
    setActiveIndex(0);
  }, [query]);

  if (!open) return null;

  const activate = (item: ResultItem) => {
    if (item.kind === "smart") onNavigate({ kind: "smart", id: item.id });
    else if (item.kind === "area") onNavigate({ kind: "area", id: item.area.id });
    else if (item.kind === "project") onNavigate({ kind: "project", id: item.project.id });
    else if (item.kind === "tag") onSelectTagFilter(item.tag.id);
    else onSelectTask(item.task);
    onClose();
  };

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
                setActiveIndex((i) => Math.min(results.length - 1, i + 1));
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
            placeholder="Quick Find lists, projects, tags, and tasks…"
            className="min-w-0 flex-1 bg-transparent text-sm text-[var(--text-primary)] outline-none placeholder:text-[var(--text-muted)]"
          />
          <kbd className="font-mono-tabular rounded bg-[var(--bg-hover)] px-1.5 py-0.5 text-[10px] text-[var(--text-muted)]">
            ESC
          </kbd>
        </div>

        <div className="max-h-80 overflow-y-auto p-1.5">
          {results.length === 0 ? (
            <div className="py-10 text-center text-xs text-[var(--text-muted)]">No matches</div>
          ) : (
            results.map((item, idx) => {
              const selected = idx === activeIndex;
              let key = "";
              let label = "";
              let meta = "";
              let icon = <Circle className="h-3.5 w-3.5 text-[var(--text-muted)]" />;

              if (item.kind === "smart") {
                key = `smart:${item.id}`;
                label = item.title;
                meta = item.subtitle;
                if (item.id === "today") icon = <Star className="h-3.5 w-3.5 text-[var(--today-gold)]" />;
                else if (item.id === "upcoming") icon = <Calendar className="h-3.5 w-3.5 text-[var(--text-muted)]" />;
                else if (item.id === "repeating") icon = <Repeat className="h-3.5 w-3.5 text-[var(--text-muted)]" />;
                else if (item.id === "agent" || item.id === "review") icon = <Sparkles className="h-3.5 w-3.5 text-[var(--accent)]" />;
                else if (item.id === "logbook") icon = <CheckCircle2 className="h-3.5 w-3.5 text-[var(--text-muted)]" />;
                else icon = <Layers className="h-3.5 w-3.5 text-[var(--text-muted)]" />;
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
                  <span className="font-mono-tabular shrink-0 text-[11px] text-[var(--text-muted)]">{meta}</span>
                </button>
              );
            })
          )}
        </div>
      </div>
    </div>
  );
}
