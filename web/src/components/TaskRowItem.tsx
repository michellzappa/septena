"use client";

import { useState } from "react";
import { Calendar, Check, Flag, Star, Trash2 } from "lucide-react";
import type { CoreMembership } from "@/lib/core";
import type { TaskRow } from "@/lib/types";

interface TaskRowItemProps {
  task: TaskRow;
  membership: CoreMembership;
  containerLabel?: string | null;
  hasPendingOp: boolean;
  expanded: boolean;
  onSelect: () => void;
  onToggleDone: () => void;
  onToggleToday: () => void;
  onUpdateFields: (fields: Record<string, unknown>) => void;
  onSetScheduled: (day: string | null) => void;
  onSetDeadline: (day: string | null) => void;
  onDelete: () => void;
}

export function TaskRowItem({
  task,
  membership,
  containerLabel,
  hasPendingOp,
  expanded,
  onSelect,
  onToggleDone,
  onToggleToday,
  onUpdateFields,
  onSetScheduled,
  onSetDeadline,
  onDelete,
}: TaskRowItemProps) {
  const [titleDraft, setTitleDraft] = useState(task.title);
  const [notesDraft, setNotesDraft] = useState(task.notes ?? "");

  const isDone = task.status === "done";
  const isToday = membership.isOnToday;

  const commitTitle = () => {
    const trimmed = titleDraft.trim();
    if (trimmed && trimmed !== task.title) {
      onUpdateFields({ title: trimmed });
    } else {
      setTitleDraft(task.title);
    }
  };

  const commitNotes = () => {
    const normalized = notesDraft.trim() ? notesDraft : null;
    if (normalized !== (task.notes ?? null)) {
      onUpdateFields({ notes: normalized });
    }
  };

  if (expanded) {
    return (
      <div className="my-1.5 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] p-3.5 shadow-sm">
        <div className="flex items-start gap-3">
          <button
            type="button"
            onClick={onToggleDone}
            aria-label={isDone ? "Mark open" : "Complete task"}
            className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-md border transition-colors ${
              isDone
                ? "border-[var(--accent)] bg-[var(--accent)] text-white"
                : "border-[var(--text-muted)]/50 hover:border-[var(--accent)]"
            }`}
          >
            {isDone && <Check className="h-3.5 w-3.5 stroke-[2.75]" />}
          </button>

          <div className="min-w-0 flex-1">
            <input
              type="text"
              value={titleDraft}
              onChange={(e) => setTitleDraft(e.target.value)}
              onBlur={commitTitle}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.currentTarget.blur();
                } else if (e.key === "Escape") {
                  onSelect();
                }
              }}
              className="w-full bg-transparent text-[15px] font-medium text-[var(--text-primary)] outline-none"
              placeholder="Task title"
            />
            <textarea
              value={notesDraft}
              onChange={(e) => setNotesDraft(e.target.value)}
              onBlur={commitNotes}
              rows={3}
              placeholder="Notes"
              className="mt-2 w-full resize-y bg-transparent text-sm leading-relaxed text-[var(--text-secondary)] outline-none placeholder:text-[var(--text-muted)]"
            />

            <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-[var(--border-subtle)] pt-3 text-xs">
              <button
                type="button"
                onClick={onToggleToday}
                className={`inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1 font-medium transition-colors ${
                  isToday
                    ? "bg-[var(--today-gold)]/20 text-[var(--text-primary)]"
                    : "bg-[var(--bg-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                }`}
              >
                <Star
                  className="h-3.5 w-3.5"
                  style={isToday ? { color: "var(--today-gold)", fill: "var(--today-gold)" } : undefined}
                />
                {isToday ? "Today" : "Move to Today"}
              </button>

              <label className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 text-[var(--text-secondary)]">
                <Calendar className="h-3.5 w-3.5" />
                <span>When</span>
                <input
                  type="date"
                  value={task.scheduled ?? ""}
                  onChange={(e) => onSetScheduled(e.target.value || null)}
                  className="font-mono-tabular bg-transparent text-[var(--text-primary)] outline-none"
                />
              </label>

              <label className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 text-[var(--text-secondary)]">
                <Flag className="h-3.5 w-3.5" />
                <span>Deadline</span>
                <input
                  type="date"
                  value={task.deadline ?? ""}
                  onChange={(e) => onSetDeadline(e.target.value || null)}
                  className="font-mono-tabular bg-transparent text-[var(--text-primary)] outline-none"
                />
              </label>

              <div className="ml-auto flex items-center gap-2">
                <button
                  type="button"
                  onClick={onDelete}
                  className="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
                >
                  <Trash2 className="h-3.5 w-3.5" />
                  Delete
                </button>
                <button
                  type="button"
                  onClick={onSelect}
                  className="rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 font-medium text-[var(--text-primary)]"
                >
                  Done
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div
      onClick={onSelect}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => {
        if (e.key === "Enter") onSelect();
      }}
      className="group flex w-full cursor-pointer items-center gap-3 rounded-lg px-2.5 py-2 text-left transition-colors hover:bg-[var(--bg-hover)]"
    >
      <button
        type="button"
        onClick={(e) => {
          e.stopPropagation();
          onToggleDone();
        }}
        aria-label={isDone ? "Mark open" : "Complete task"}
        className={`flex h-[18px] w-[18px] shrink-0 items-center justify-center rounded-[5px] border transition-colors ${
          isDone
            ? "border-[var(--accent)] bg-[var(--accent)] text-white"
            : "border-[var(--text-muted)]/55 hover:border-[var(--accent)]"
        }`}
      >
        {isDone && <Check className="h-3 w-3 stroke-[3]" />}
      </button>

      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span
            className={`truncate text-[15px] ${
              isDone ? "text-[var(--text-muted)] line-through" : "text-[var(--text-primary)]"
            }`}
          >
            {task.title}
          </span>
          {hasPendingOp && (
            <span
              title="Queued locally — waiting to push"
              className="inline-block h-1.5 w-1.5 shrink-0 rounded-full bg-amber-500"
            />
          )}
        </div>
        {(containerLabel || task.notes) && (
          <div className="mt-0.5 flex items-center gap-2 text-xs text-[var(--text-muted)]">
            {containerLabel && <span className="truncate">{containerLabel}</span>}
            {task.notes && <span className="truncate opacity-80">{task.notes}</span>}
          </div>
        )}
      </div>

      <div className="flex shrink-0 items-center gap-2">
        {task.deadline && (
          <span
            className={`font-mono-tabular inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-xs ${
              membership.deadlineRed
                ? "bg-[var(--overdue-red)]/10 font-medium text-[var(--overdue-red)]"
                : "text-[var(--text-muted)]"
            }`}
          >
            <Flag className="h-3 w-3" />
            {task.deadline}
          </span>
        )}
        {!isToday && task.scheduled && (
          <span className="font-mono-tabular text-xs text-[var(--text-muted)]">{task.scheduled}</span>
        )}
        {isToday && (
          <Star
            className="h-3.5 w-3.5 shrink-0"
            style={{ color: "var(--today-gold)", fill: "var(--today-gold)" }}
          />
        )}
      </div>
    </div>
  );
}
