"use client";

import { useEffect, useRef, useState } from "react";
import {
  Bell,
  Calendar,
  Check,
  CheckSquare,
  Clock,
  CopyPlus,
  ExternalLink,
  Flag,
  Folder,
  History,
  Link2,
  Maximize2,
  MessageSquare,
  MessageSquareText,
  Paperclip,
  Pause,
  Play,
  Plus,
  Repeat,
  RotateCcw,
  Send,
  Share2,
  Square,
  Star,
  Sun,
  Tag,
  Trash2,
  Upload,
  X,
} from "lucide-react";
import type { CoreConversationState, CoreMembership, CoreProjection } from "@/lib/core";
import type {
  AreaRow,
  AttachmentRow,
  ChangeEntry,
  ChecklistItemRow,
  ConvoRow,
  ProjectRow,
  TagRow,
  TaskRefRow,
  TaskRow,
  TurnRow,
} from "@/lib/types";

export interface TaskRowItemProps {
  task: TaskRow;
  membership: CoreMembership;
  opacity: number;
  containerLabel?: string | null;
  hasPendingOp: boolean;
  selected: boolean;
  multiSelected?: boolean;
  expanded: boolean;
  isDeletedView?: boolean;
  isFadedView?: boolean;
  isColorfulAccent?: boolean;
  animateCompletion?: boolean;
  draggable?: boolean;
  isDropTarget?: boolean;
  checklistItems: ChecklistItemRow[];
  allTags: TagRow[];
  taskRefs: TaskRefRow[];
  attachments: AttachmentRow[];
  convo: ConvoRow | null;
  turns: TurnRow[];
  convoProjection: CoreProjection | null;
  convoState: CoreConversationState | null;
  areas: AreaRow[];
  projects: ProjectRow[];
  onRowClick: (e: React.MouseEvent) => void;
  onContextMenu?: (e: React.MouseEvent) => void;
  onDragStart?: (e: React.DragEvent) => void;
  onDragOver?: (e: React.DragEvent) => void;
  onDragLeave?: () => void;
  onDrop?: (e: React.DragEvent) => void;
  onOpenTaskPage?: () => void;
  onCollapse?: () => void;
  onToggleDone: () => void;
  onToggleToday: () => void;
  onToggleStar: () => void;
  onDuplicate: () => void;
  onShare: () => void;
  onUpdateFields: (fields: Record<string, unknown>) => void;
  onSetScheduled: (day: string | null) => void;
  onSetDeadline: (day: string | null) => void;
  onSetTimeSlot: (startTime: string | null, durationMinutes: number | null) => void;
  onSetReminder: (reminderAt: string | null) => void;
  onSetRecurrence: (rule: {
    unit: "day" | "week" | "month" | "year" | null;
    interval?: number;
    afterCompletion?: boolean;
    paused?: boolean;
  }) => void;
  onMoveTask: (target: { area: string | null; project: string | null }) => void;
  onAddChecklistItem: (title: string) => void;
  onToggleChecklistItem: (item: ChecklistItemRow) => void;
  onDeleteChecklistItem: (item: ChecklistItemRow) => void;
  onToggleTag: (tagId: string) => void;
  onCreateAndToggleTag: (name: string) => void;
  onAddReference: (input: string) => Promise<void>;
  onRemoveReference: (ref: TaskRefRow) => void;
  onUploadAttachment: (file: File) => Promise<void>;
  onDownloadAttachment: (att: AttachmentRow) => void;
  onDeleteAttachment: (att: AttachmentRow) => void;
  onAssignToAgent: (assignee: "claude" | "me") => void;
  onAnswerQuestion: (inReplyTo: number, chosen: string) => void;
  onSendReply: (note: string) => void;
  onAcceptReview: () => void;
  onSendBackReview: (note: string) => void;
  onStopAgent: () => void;
  onResumeAgent: () => void;
  onLoadHistory: () => Promise<ChangeEntry[]>;
  onKeepFaded?: () => void;
  onDropFaded?: () => void;
  onRestoreDeleted?: () => void;
  onCancelTask: () => void;
  onDelete: () => void;
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function isoToLocalDatetimeInput(iso: string | null | undefined): string {
  if (!iso) return "";
  const dt = new Date(iso);
  if (Number.isNaN(dt.getTime())) return "";
  const pad = (v: number) => String(v).padStart(2, "0");
  return `${dt.getFullYear()}-${pad(dt.getMonth() + 1)}-${pad(dt.getDate())}T${pad(dt.getHours())}:${pad(dt.getMinutes())}`;
}

export function TaskDetailEditor({
  props,
  isPageMode = false,
}: {
  props: TaskRowItemProps;
  isPageMode?: boolean;
}) {
  const {
    task,
    membership,
    isColorfulAccent = true,
    animateCompletion = true,
    checklistItems,
    allTags,
    taskRefs,
    attachments,
    convo,
    turns,
    convoState,
    areas,
    projects,
  } = props;

  const [titleDraft, setTitleDraft] = useState(task.title);
  const [notesDraft, setNotesDraft] = useState(task.notes ?? "");
  const [newCheckItem, setNewCheckItem] = useState("");
  const [newTagName, setNewTagName] = useState("");
  const [newRefInput, setNewRefInput] = useState("");
  const [refError, setRefError] = useState<string | null>(null);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [uploading, setUploading] = useState(false);
  const [replyDraft, setReplyDraft] = useState("");
  const [sendBackOpen, setSendBackOpen] = useState(false);
  const [sendBackNote, setSendBackNote] = useState("");
  const [showHistory, setShowHistory] = useState(isPageMode);
  const [historyRows, setHistoryRows] = useState<ChangeEntry[] | null>(null);
  const [justChecked, setJustChecked] = useState(false);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    setTitleDraft(task.title);
    setNotesDraft(task.notes ?? "");
    setHistoryRows(null);
    setUploadError(null);
  }, [task.id, task.title, task.notes]);

  useEffect(() => {
    if (isPageMode && showHistory && historyRows === null) {
      void props.onLoadHistory().then(setHistoryRows);
    }
  }, [historyRows, isPageMode, props, showHistory]);

  const isDone = task.status === "done";
  const isCancelled = task.status === "cancelled";
  const isToday = membership.isOnToday;
  const taskTagIds = Array.isArray(task.tags) ? task.tags : [];

  const commitTitle = () => {
    const trimmed = titleDraft.trim();
    if (trimmed && trimmed !== task.title) props.onUpdateFields({ title: trimmed });
    else setTitleDraft(task.title);
  };

  const commitNotes = () => {
    const normalized = notesDraft.trim() ? notesDraft : null;
    if (normalized !== (task.notes ?? null)) props.onUpdateFields({ notes: normalized });
  };

  const moveValue = task.project
    ? `project:${task.project}`
    : task.area
      ? `area:${task.area}`
      : "inbox";

  const openQuestionTurn = convoState?.hasOpenProviderQuestion
    ? [...turns].reverse().find((t) => t.role === "provider" && Array.isArray(t.options) && t.options.length > 0)
    : null;

  const handleFiles = async (files: FileList | null) => {
    if (!files || files.length === 0) return;
    setUploadError(null);
    setUploading(true);
    try {
      for (const file of Array.from(files)) {
        await props.onUploadAttachment(file);
      }
    } catch (err) {
      setUploadError(err instanceof Error ? err.message : "Upload failed");
    } finally {
      setUploading(false);
    }
  };

  const todayColor = isColorfulAccent ? "var(--today-gold)" : "var(--accent)";

  return (
    <div
      className={
        isPageMode
          ? "space-y-4"
          : "my-2 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-elevated)] p-4 shadow-sm"
      }
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes("Files")) {
          e.preventDefault();
        }
      }}
      onDrop={(e) => {
        if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
          e.preventDefault();
          void handleFiles(e.dataTransfer.files);
        }
      }}
    >
      <div className="flex items-start gap-3">
        <button
          type="button"
          onClick={() => {
            if (animateCompletion && !isDone) {
              setJustChecked(true);
              setTimeout(() => setJustChecked(false), 260);
            }
            props.onToggleDone();
          }}
          aria-label={isDone ? "Mark open" : "Complete task"}
          className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-md border transition-colors ${
            justChecked ? "animate-check-pop" : ""
          } ${
            isDone
              ? "border-[var(--accent)] bg-[var(--accent)]"
              : "border-[var(--text-muted)]/50 hover:border-[var(--accent)]"
          }`}
          style={isDone ? { color: "var(--accent-check)" } : undefined}
        >
          {isDone && <Check className="h-3.5 w-3.5 stroke-[2.75]" />}
        </button>

        <div className="min-w-0 flex-1 space-y-3">
          {/* 1. Header */}
          <div className="flex items-center gap-1.5">
            <input
              type="text"
              value={titleDraft}
              onChange={(e) => setTitleDraft(e.target.value)}
              onBlur={commitTitle}
              onKeyDown={(e) => {
                if (e.key === "Enter") e.currentTarget.blur();
                else if (e.key === "Escape" && props.onCollapse) props.onCollapse();
              }}
              className="min-w-0 flex-1 bg-transparent text-[15px] font-medium text-[var(--text-primary)] outline-none"
              placeholder="Task title"
            />
            <button
              type="button"
              onClick={props.onToggleStar}
              title={task.starred ? "Unfavorite (⌘⌥S)" : "Favorite (⌘⌥S)"}
              className="rounded-md p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)]"
            >
              <Star
                className="h-4 w-4"
                style={task.starred ? { color: "#f59e0b", fill: "#f59e0b" } : undefined}
              />
            </button>
            {!isPageMode && props.onOpenTaskPage && (
              <button
                type="button"
                onClick={props.onOpenTaskPage}
                title="Open Task Page (⌘⌥I)"
                className="rounded-md p-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
              >
                <Maximize2 className="h-3.5 w-3.5" />
              </button>
            )}
          </div>

          {/* 2. Notes */}
          <textarea
            value={notesDraft}
            onChange={(e) => setNotesDraft(e.target.value)}
            onBlur={commitNotes}
            rows={isPageMode ? 4 : 3}
            placeholder="Notes"
            className="w-full resize-y bg-transparent text-sm leading-relaxed text-[var(--text-secondary)] outline-none placeholder:text-[var(--text-muted)]"
          />

          {/* 3. Attributes */}
          <div className="flex flex-wrap items-center gap-2 border-t border-[var(--border-subtle)] pt-3 text-xs">
            <button
              type="button"
              onClick={props.onToggleToday}
              className={`inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1 font-medium transition-colors ${
                isToday
                  ? "bg-[var(--bg-selected)] text-[var(--text-primary)]"
                  : "bg-[var(--bg-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              }`}
            >
              <Sun className="h-3.5 w-3.5" style={isToday ? { color: todayColor } : undefined} />
              {isToday ? "Today" : "Move to Today"}
            </button>

            <label className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 text-[var(--text-secondary)]">
              <Calendar className="h-3.5 w-3.5" />
              <span>When</span>
              <input
                type="date"
                value={task.scheduled ?? ""}
                onChange={(e) => props.onSetScheduled(e.target.value || null)}
                className="font-mono-tabular bg-transparent text-[var(--text-primary)] outline-none"
              />
            </label>

            <label className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 text-[var(--text-secondary)]">
              <Flag className="h-3.5 w-3.5" />
              <span>Deadline</span>
              <input
                type="date"
                value={task.deadline ?? ""}
                onChange={(e) => props.onSetDeadline(e.target.value || null)}
                className="font-mono-tabular bg-transparent text-[var(--text-primary)] outline-none"
              />
            </label>

            <label className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 text-[var(--text-secondary)]">
              <Clock className="h-3.5 w-3.5" />
              <input
                type="time"
                value={task.startTime ?? ""}
                onChange={(e) =>
                  props.onSetTimeSlot(
                    e.target.value || null,
                    task.durationMinutes ?? (e.target.value ? 30 : null),
                  )
                }
                className="font-mono-tabular bg-transparent text-[var(--text-primary)] outline-none"
              />
            </label>

            <label className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 text-[var(--text-secondary)]">
              <Bell className="h-3.5 w-3.5" />
              <span>Remind</span>
              <input
                type="datetime-local"
                value={isoToLocalDatetimeInput(task.reminderAt)}
                onChange={(e) => {
                  const val = e.target.value;
                  props.onSetReminder(val ? new Date(val).toISOString() : null);
                }}
                className="font-mono-tabular bg-transparent text-[var(--text-primary)] outline-none"
              />
              {task.reminderAt && (
                <button
                  type="button"
                  onClick={(e) => {
                    e.preventDefault();
                    props.onSetReminder(null);
                  }}
                  className="text-[var(--text-muted)] hover:text-[var(--text-primary)]"
                  title="Clear reminder"
                >
                  <X className="h-3 w-3" />
                </button>
              )}
            </label>

            <label className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 text-[var(--text-secondary)]">
              <Repeat className="h-3.5 w-3.5" />
              <select
                value={task.recurrenceUnit ?? ""}
                onChange={(e) => {
                  const v = e.target.value;
                  props.onSetRecurrence({
                    unit: v ? (v as "day" | "week" | "month" | "year") : null,
                    interval: task.recurrenceInterval ?? 1,
                    afterCompletion: Boolean(task.recurrenceAfterCompletion),
                    paused: Boolean(task.recurrencePaused),
                  });
                }}
                className="bg-transparent text-[var(--text-primary)] outline-none"
              >
                <option value="">No repeat</option>
                <option value="day">Daily</option>
                <option value="week">Weekly</option>
                <option value="month">Monthly</option>
                <option value="year">Yearly</option>
              </select>
            </label>

            {task.recurrenceUnit && (
              <button
                type="button"
                onClick={() =>
                  props.onSetRecurrence({
                    unit: task.recurrenceUnit as "day" | "week" | "month" | "year",
                    interval: task.recurrenceInterval ?? 1,
                    afterCompletion: Boolean(task.recurrenceAfterCompletion),
                    paused: !task.recurrencePaused,
                  })
                }
                className="inline-flex items-center gap-1 rounded-lg bg-[var(--bg-hover)] px-2 py-1 text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
              >
                {task.recurrencePaused ? <Play className="h-3 w-3" /> : <Pause className="h-3 w-3" />}
                {task.recurrencePaused ? "Paused" : "Active"}
              </button>
            )}

            <label className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 text-[var(--text-secondary)]">
              <Folder className="h-3.5 w-3.5" />
              <select
                value={moveValue}
                onChange={(e) => {
                  const v = e.target.value;
                  if (v === "inbox") props.onMoveTask({ area: null, project: null });
                  else if (v.startsWith("area:")) props.onMoveTask({ area: v.slice(5), project: null });
                  else if (v.startsWith("project:")) {
                    const pId = v.slice(8);
                    const proj = projects.find((p) => p.id === pId);
                    props.onMoveTask({ area: proj?.area ?? null, project: pId });
                  }
                }}
                className="bg-transparent text-[var(--text-primary)] outline-none"
              >
                <option value="inbox">Inbox (unfiled)</option>
                {areas.map((a) => (
                  <option key={a.id} value={`area:${a.id}`}>
                    {a.emoji ? `${a.emoji} ` : ""}{a.title}
                  </option>
                ))}
                {projects.map((p) => (
                  <option key={p.id} value={`project:${p.id}`}>
                    ○ {p.title}
                  </option>
                ))}
              </select>
            </label>
          </div>

          {/* Tags */}
          <div className="flex flex-wrap items-center gap-1.5 border-t border-[var(--border-subtle)] pt-2.5 text-xs">
            <Tag className="h-3.5 w-3.5 text-[var(--text-muted)]" />
            {allTags.map((t) => {
              const active = taskTagIds.includes(t.id);
              return (
                <button
                  key={t.id}
                  type="button"
                  onClick={() => props.onToggleTag(t.id)}
                  className={`rounded-full px-2 py-0.5 transition-colors ${
                    active
                      ? "bg-[var(--bg-selected)] font-medium text-[var(--text-primary)]"
                      : "bg-[var(--bg-hover)] text-[var(--text-muted)] hover:text-[var(--text-primary)]"
                  }`}
                >
                  {t.name}
                </button>
              );
            })}
            <form
              onSubmit={(e) => {
                e.preventDefault();
                if (!newTagName.trim()) return;
                props.onCreateAndToggleTag(newTagName);
                setNewTagName("");
              }}
              className="inline-flex"
            >
              <input
                type="text"
                value={newTagName}
                onChange={(e) => setNewTagName(e.target.value)}
                placeholder="+ tag"
                className="w-20 bg-transparent px-1 text-xs text-[var(--text-primary)] outline-none placeholder:text-[var(--text-muted)]"
              />
            </form>
          </div>

          {/* 4. Checklist */}
          <div className="space-y-1.5 border-t border-[var(--border-subtle)] pt-2.5">
            {checklistItems.map((item) => (
              <div key={item.id} className="group flex items-center gap-2 text-sm">
                <button
                  type="button"
                  onClick={() => props.onToggleChecklistItem(item)}
                  className="text-[var(--text-muted)] hover:text-[var(--accent)]"
                >
                  {item.checked ? (
                    <CheckSquare className="h-4 w-4 text-[var(--accent)]" />
                  ) : (
                    <Square className="h-4 w-4" />
                  )}
                </button>
                <span
                  className={`min-w-0 flex-1 ${
                    item.checked ? "text-[var(--text-muted)] line-through" : "text-[var(--text-primary)]"
                  }`}
                >
                  {item.title}
                </span>
                <button
                  type="button"
                  onClick={() => props.onDeleteChecklistItem(item)}
                  className="opacity-0 text-[var(--text-muted)] hover:text-[var(--overdue-red)] group-hover:opacity-100"
                  aria-label="Remove checklist item"
                >
                  <X className="h-3.5 w-3.5" />
                </button>
              </div>
            ))}
            <form
              onSubmit={(e) => {
                e.preventDefault();
                if (!newCheckItem.trim()) return;
                props.onAddChecklistItem(newCheckItem);
                setNewCheckItem("");
              }}
              className="flex items-center gap-2"
            >
              <Plus className="h-3.5 w-3.5 text-[var(--text-muted)]" />
              <input
                type="text"
                value={newCheckItem}
                onChange={(e) => setNewCheckItem(e.target.value)}
                placeholder="Add checklist item…"
                className="min-w-0 flex-1 bg-transparent text-xs text-[var(--text-primary)] outline-none placeholder:text-[var(--text-muted)]"
              />
            </form>
          </div>

          {/* 5. Attachments (upload + download + delete) */}
          <div className="space-y-1.5 border-t border-[var(--border-subtle)] pt-2.5 text-xs">
            <div className="flex flex-wrap items-center gap-1.5">
              <Paperclip className="h-3.5 w-3.5 text-[var(--text-muted)]" />
              {attachments.map((att) => (
                <span
                  key={att.id}
                  className="inline-flex items-center gap-1 rounded-md bg-[var(--bg-hover)] px-2 py-1 text-[var(--text-secondary)]"
                >
                  <button
                    type="button"
                    onClick={() => props.onDownloadAttachment(att)}
                    className="inline-flex items-center gap-1.5 hover:text-[var(--accent)]"
                  >
                    <span className="max-w-[180px] truncate">{att.filename}</span>
                    <span className="font-mono-tabular text-[10px] text-[var(--text-muted)]">
                      {formatBytes(att.byteCount)}
                    </span>
                  </button>
                  <button
                    type="button"
                    onClick={() => props.onDeleteAttachment(att)}
                    className="ml-0.5 text-[var(--text-muted)] hover:text-[var(--overdue-red)]"
                    aria-label={`Delete ${att.filename}`}
                  >
                    <X className="h-3 w-3" />
                  </button>
                </span>
              ))}
              <input
                ref={fileInputRef}
                type="file"
                multiple
                onChange={(e) => {
                  void handleFiles(e.target.files);
                  e.target.value = "";
                }}
                className="hidden"
              />
              <button
                type="button"
                disabled={uploading}
                onClick={() => fileInputRef.current?.click()}
                className="inline-flex items-center gap-1 rounded-md bg-[var(--bg-hover)] px-2 py-1 text-[var(--text-secondary)] hover:text-[var(--text-primary)] disabled:opacity-40"
              >
                <Upload className="h-3 w-3" />
                {uploading ? "Uploading…" : "Attach file"}
              </button>
            </div>
            {uploadError && <p className="text-[11px] text-[var(--overdue-red)]">{uploadError}</p>}
          </div>

          {/* 6. References (shared Rust WASM core parseRef) */}
          <div className="space-y-1.5 border-t border-[var(--border-subtle)] pt-2.5 text-xs">
            <div className="flex flex-wrap items-center gap-1.5">
              <Link2 className="h-3.5 w-3.5 text-[var(--text-muted)]" />
              {taskRefs.map((ref) => {
                const href = ref.snapshot?.url ?? (ref.key.startsWith("url:") ? ref.key.slice(4) : null);
                const label = ref.snapshot?.title || ref.key;
                return (
                  <span
                    key={ref.id}
                    className="inline-flex items-center gap-1 rounded-md bg-[var(--bg-hover)] px-2 py-0.5 text-[var(--text-secondary)]"
                  >
                    {href ? (
                      <a
                        href={href}
                        target="_blank"
                        rel="noreferrer"
                        className="inline-flex items-center gap-1 hover:text-[var(--accent)] hover:underline"
                      >
                        <span className="max-w-[220px] truncate">{label}</span>
                        <ExternalLink className="h-3 w-3" />
                      </a>
                    ) : (
                      <span className="font-mono-tabular max-w-[220px] truncate">{label}</span>
                    )}
                    <button
                      type="button"
                      onClick={() => props.onRemoveReference(ref)}
                      className="ml-0.5 text-[var(--text-muted)] hover:text-[var(--overdue-red)]"
                      aria-label="Remove reference"
                    >
                      <X className="h-3 w-3" />
                    </button>
                  </span>
                );
              })}
              <form
                onSubmit={async (e) => {
                  e.preventDefault();
                  if (!newRefInput.trim()) return;
                  setRefError(null);
                  try {
                    await props.onAddReference(newRefInput);
                    setNewRefInput("");
                  } catch (err) {
                    setRefError(err instanceof Error ? err.message : "Invalid reference");
                  }
                }}
                className="inline-flex flex-1"
              >
                <input
                  type="text"
                  value={newRefInput}
                  onChange={(e) => setNewRefInput(e.target.value)}
                  placeholder="+ Paste a link or GitHub issue (owner/repo#123)…"
                  className="min-w-[180px] flex-1 bg-transparent px-1 text-xs text-[var(--text-primary)] outline-none placeholder:text-[var(--text-muted)]"
                />
              </form>
            </div>
            {refError && <p className="text-[11px] text-[var(--overdue-red)]">{refError}</p>}
          </div>

          {/* 7. Conversation / Discuss */}
          <div className="space-y-2.5 rounded-xl border border-[var(--border-subtle)] bg-[var(--bg-sidebar)] p-3 text-xs">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className="inline-flex items-center gap-1.5 font-medium text-[var(--text-primary)]">
                <MessageSquare className="h-3.5 w-3.5 text-[var(--accent)]" />
                Discuss
                {convoState?.agentStage && (
                  <span className="rounded bg-[var(--bg-selected)] px-1.5 py-0.5 text-[10px] font-medium">
                    {convoState.agentStage}
                  </span>
                )}
              </span>
              <div className="flex items-center gap-1.5">
                <button
                  type="button"
                  onClick={() => props.onAssignToAgent(convo?.assignee === "claude" ? "me" : "claude")}
                  className={`rounded-md px-2 py-1 font-medium ${
                    convo?.assignee === "claude"
                      ? "bg-[var(--accent)]"
                      : "bg-[var(--bg-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                  }`}
                  style={convo?.assignee === "claude" ? { color: "var(--accent-check)" } : undefined}
                >
                  {convo?.assignee === "claude" ? "Assigned to Claude" : "Assign to Claude"}
                </button>
                {convo?.assignee === "claude" &&
                  (convo.stoppedAt ? (
                    <button
                      type="button"
                      onClick={props.onResumeAgent}
                      className="rounded-md bg-emerald-500/15 px-2 py-1 font-medium text-emerald-600 dark:text-emerald-400"
                    >
                      Resume
                    </button>
                  ) : (
                    <button
                      type="button"
                      onClick={props.onStopAgent}
                      className="rounded-md bg-amber-500/15 px-2 py-1 font-medium text-amber-600 dark:text-amber-400"
                    >
                      Stop
                    </button>
                  ))}
              </div>
            </div>

            {convoState?.needsHumanReview && (
              <div className="rounded-lg border border-amber-500/30 bg-amber-500/10 p-2.5">
                <p className="text-[10px] font-semibold tracking-wide text-amber-700 uppercase dark:text-amber-300">
                  Review requested
                </p>
                <p className="mt-0.5 whitespace-pre-wrap text-[var(--text-primary)]">
                  {convo?.endStateNote || "Ready for review"}
                </p>
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  <button
                    type="button"
                    onClick={props.onAcceptReview}
                    className="rounded-md bg-emerald-600 px-2.5 py-1 font-medium text-white hover:opacity-90"
                  >
                    Accept
                  </button>
                  <button
                    type="button"
                    onClick={() => setSendBackOpen((v) => !v)}
                    className="rounded-md bg-[var(--bg-elevated)] px-2.5 py-1 font-medium text-[var(--text-primary)]"
                  >
                    Send back…
                  </button>
                </div>
                {sendBackOpen && (
                  <form
                    onSubmit={(e) => {
                      e.preventDefault();
                      props.onSendBackReview(sendBackNote);
                      setSendBackNote("");
                      setSendBackOpen(false);
                    }}
                    className="mt-2 flex gap-1.5"
                  >
                    <input
                      type="text"
                      value={sendBackNote}
                      onChange={(e) => setSendBackNote(e.target.value)}
                      placeholder="What needs another pass?"
                      className="min-w-0 flex-1 rounded-md border border-[var(--border-subtle)] bg-[var(--bg-elevated)] px-2 py-1 text-xs outline-none"
                    />
                    <button
                      type="submit"
                      className="rounded-md bg-[var(--accent)] px-2.5 py-1 font-medium"
                      style={{ color: "var(--accent-check)" }}
                    >
                      Send back
                    </button>
                  </form>
                )}
              </div>
            )}

            {convo?.artifact && (
              <div className="rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-elevated)] p-2.5">
                <p className="font-medium text-[var(--text-primary)]">{convo.artifact.title}</p>
                <p className="mt-1 whitespace-pre-wrap text-[var(--text-secondary)]">
                  {convo.artifact.body}
                </p>
              </div>
            )}

            {convo?.handoff && (
              <div className="flex items-center justify-between gap-2 rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-elevated)] p-2.5">
                <span className="text-[var(--text-secondary)]">{convo.handoff.instruction}</span>
                {convo.handoff.actionType === "open_url" && convo.handoff.payload && (
                  <a
                    href={convo.handoff.payload}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex shrink-0 items-center gap-1 rounded-md bg-[var(--accent)] px-2 py-1 font-medium"
                    style={{ color: "var(--accent-check)" }}
                  >
                    Open <ExternalLink className="h-3 w-3" />
                  </a>
                )}
              </div>
            )}

            {turns.length > 0 && (
              <div className="max-h-56 space-y-2 overflow-y-auto pr-1">
                {turns.map((turn) => {
                  const isUser = turn.role === "user";
                  const showOptions =
                    openQuestionTurn?.seq === turn.seq && Array.isArray(turn.options) && turn.options.length > 0;
                  return (
                    <div
                      key={turn.id}
                      className={`rounded-lg px-2.5 py-2 ${
                        isUser
                          ? "ml-6 bg-[var(--bg-selected)] text-[var(--text-primary)]"
                          : "mr-4 border border-[var(--border-subtle)] bg-[var(--bg-elevated)] text-[var(--text-secondary)]"
                      }`}
                    >
                      <div className="mb-0.5 flex items-center justify-between text-[10px] text-[var(--text-muted)]">
                        <span className="font-medium">{isUser ? "You" : (turn.provider || "Claude")}</span>
                        <span className="font-mono-tabular">#{turn.seq}</span>
                      </div>
                      {turn.question && <p className="font-medium text-[var(--text-primary)]">{turn.question}</p>}
                      {turn.chosen && <p className="font-medium">{turn.chosen}</p>}
                      {turn.otherText && <p className="whitespace-pre-wrap">{turn.otherText}</p>}
                      {turn.note && <p className="mt-0.5 whitespace-pre-wrap">{turn.note}</p>}
                      {showOptions && (
                        <div className="mt-2 flex flex-wrap gap-1.5">
                          {turn.options!.map((opt) => (
                            <button
                              key={opt}
                              type="button"
                              onClick={() => props.onAnswerQuestion(turn.seq, opt)}
                              className="rounded-full border border-[var(--accent)]/40 bg-[var(--bg-selected)] px-2.5 py-1 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--accent)] hover:text-white"
                            >
                              {opt}
                            </button>
                          ))}
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            )}

            <form
              onSubmit={(e) => {
                e.preventDefault();
                if (!replyDraft.trim()) return;
                props.onSendReply(replyDraft.trim());
                setReplyDraft("");
              }}
              className="flex items-center gap-1.5"
            >
              <input
                type="text"
                value={replyDraft}
                onChange={(e) => setReplyDraft(e.target.value)}
                placeholder="Write a note or reply in this thread…"
                className="min-w-0 flex-1 rounded-lg border border-[var(--border-subtle)] bg-[var(--bg-elevated)] px-2.5 py-1.5 text-xs text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
              <button
                type="submit"
                disabled={!replyDraft.trim()}
                className="inline-flex items-center gap-1 rounded-lg bg-[var(--accent)] px-2.5 py-1.5 text-xs font-medium disabled:opacity-40"
                style={{ color: "var(--accent-check)" }}
              >
                <Send className="h-3 w-3" />
              </button>
            </form>
          </div>

          {/* 8. Provenance */}
          <div className="flex items-center gap-1.5 text-[11px] text-[var(--text-muted)]">
            {task.source === "mcp" && <MessageSquareText className="h-3.5 w-3.5 text-[var(--accent)]" />}
            <span>
              Added by{" "}
              <strong className="font-medium text-[var(--text-secondary)]">
                {task.source === "mcp" ? (task.sourceClient || "Claude") : "You"}
              </strong>
              {task.createdAt ? ` · ${new Date(task.createdAt).toLocaleDateString()}` : ""}
            </span>
          </div>

          {/* 9. History */}
          {showHistory && (
            <div className="rounded-lg border border-[var(--border-subtle)] p-2.5 text-[11px] text-[var(--text-muted)]">
              {historyRows === null ? (
                <span>Loading history…</span>
              ) : historyRows.length === 0 ? (
                <span>No recorded history.</span>
              ) : (
                <div className="max-h-36 space-y-1 overflow-y-auto">
                  {historyRows.map((h) => (
                    <div key={h.rev} className="font-mono-tabular flex justify-between gap-2">
                      <span className="truncate">{h.actor} · {h.op ?? "edit"}</span>
                      <span className="shrink-0">{new Date(h.at).toLocaleString()}</span>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {/* Footer actions */}
          <div className="flex flex-wrap items-center gap-1.5 border-t border-[var(--border-subtle)] pt-2.5 text-xs">
            <button
              type="button"
              onClick={async () => {
                const next = !showHistory;
                setShowHistory(next);
                if (next && historyRows === null) {
                  setHistoryRows(await props.onLoadHistory());
                }
              }}
              className="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
            >
              <History className="h-3.5 w-3.5" />
              History
            </button>
            <button
              type="button"
              onClick={props.onDuplicate}
              className="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
            >
              <CopyPlus className="h-3.5 w-3.5" />
              Duplicate
            </button>
            <button
              type="button"
              onClick={props.onShare}
              className="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
            >
              <Share2 className="h-3.5 w-3.5" />
              Share
            </button>

            <div className="ml-auto flex items-center gap-1.5">
              {!isCancelled && !isDone && (
                <button
                  type="button"
                  onClick={props.onCancelTask}
                  className="rounded-lg px-2 py-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
                >
                  Cancel task
                </button>
              )}
              <button
                type="button"
                onClick={props.onDelete}
                className="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-[var(--overdue-red)] hover:bg-[var(--overdue-red)]/10"
              >
                <Trash2 className="h-3.5 w-3.5" />
                Delete
              </button>
              {!isPageMode && props.onCollapse && (
                <button
                  type="button"
                  onClick={props.onCollapse}
                  className="rounded-lg bg-[var(--bg-hover)] px-2.5 py-1 font-medium text-[var(--text-primary)]"
                >
                  Done
                </button>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

export function TaskRowItem(props: TaskRowItemProps) {
  const {
    task,
    membership,
    opacity,
    containerLabel,
    hasPendingOp,
    selected,
    multiSelected = false,
    expanded,
    isDeletedView,
    isFadedView,
    isColorfulAccent = true,
    animateCompletion = true,
    draggable = false,
    isDropTarget = false,
    checklistItems,
    allTags,
    taskRefs,
    attachments,
    convoProjection,
    convoState,
  } = props;

  const [justChecked, setJustChecked] = useState(false);

  if (expanded) {
    return <TaskDetailEditor props={props} />;
  }

  const isDone = task.status === "done";
  const isCancelled = task.status === "cancelled";
  const isToday = membership.isOnToday;
  const tagMap = new Map(allTags.map((t) => [t.id, t]));
  const taskTagIds = Array.isArray(task.tags) ? task.tags : [];
  const checkedCount = checklistItems.filter((c) => c.checked).length;
  const todayColor = isColorfulAccent ? "var(--today-gold)" : "var(--accent)";
  const hasActiveReminder = Boolean(task.reminderAt && !task.reminderDismissedAt);

  return (
    <div
      draggable={draggable && !isDeletedView}
      onDragStart={props.onDragStart}
      onDragOver={props.onDragOver}
      onDragLeave={props.onDragLeave}
      onDrop={props.onDrop}
      onClick={props.onRowClick}
      onContextMenu={props.onContextMenu}
      role="button"
      tabIndex={0}
      style={{ opacity }}
      onKeyDown={(e) => {
        if (e.key === "Enter") {
          props.onRowClick(e as unknown as React.MouseEvent);
        }
      }}
      className={`group relative flex w-full cursor-pointer items-center gap-3 rounded-lg px-2.5 py-2 text-left transition-colors ${
        isDropTarget ? "border-t-2 border-[var(--accent)]" : ""
      } ${
        selected || multiSelected
          ? "bg-[var(--bg-selected)]"
          : "hover:bg-[var(--bg-hover)]"
      }`}
    >
      {!isDeletedView && (
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            if (animateCompletion && !isDone) {
              setJustChecked(true);
              setTimeout(() => setJustChecked(false), 260);
            }
            props.onToggleDone();
          }}
          aria-label={isDone ? "Mark open" : "Complete task"}
          className={`flex h-[18px] w-[18px] shrink-0 items-center justify-center rounded-[5px] border transition-colors ${
            justChecked ? "animate-check-pop" : ""
          } ${
            isDone
              ? "border-[var(--accent)] bg-[var(--accent)]"
              : isCancelled
                ? "border-[var(--text-muted)]/40 bg-[var(--text-muted)]/20 text-[var(--text-muted)]"
                : "border-[var(--text-muted)]/55 hover:border-[var(--accent)]"
          }`}
          style={isDone ? { color: "var(--accent-check)" } : undefined}
        >
          {isDone && <Check className="h-3 w-3 stroke-[3]" />}
          {isCancelled && <X className="h-3 w-3" />}
        </button>
      )}

      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span
            className={`truncate text-[15px] ${
              isDone || isCancelled ? "text-[var(--text-muted)] line-through" : "text-[var(--text-primary)]"
            }`}
          >
            {task.title}
          </span>
          {convoProjection?.badge === "needsYou" && (
            <span className="inline-flex shrink-0 items-center gap-1 rounded-full bg-amber-500/15 px-1.5 py-0.5 text-[10px] font-medium text-amber-600 dark:text-amber-400">
              <span className="h-1.5 w-1.5 rounded-full bg-[var(--convo-needs-you)]" />
              {convoState?.needsHumanReview ? "Review" : "Your turn"}
            </span>
          )}
          {convoProjection?.badge === "working" && (
            <span className="inline-flex shrink-0 items-center gap-1 rounded-full bg-blue-500/15 px-1.5 py-0.5 text-[10px] font-medium text-blue-600 dark:text-blue-400">
              <span className="h-1.5 w-1.5 rounded-full bg-[var(--convo-working)]" />
              Working
            </span>
          )}
          {hasPendingOp && (
            <span
              title="Queued locally — waiting to push"
              className="inline-block h-1.5 w-1.5 shrink-0 rounded-full bg-amber-500"
            />
          )}
        </div>

        {(containerLabel ||
          task.notes ||
          checklistItems.length > 0 ||
          taskTagIds.length > 0 ||
          taskRefs.length > 0 ||
          attachments.length > 0 ||
          hasActiveReminder ||
          task.source === "mcp") && (
          <div className="mt-0.5 flex flex-wrap items-center gap-2 text-xs text-[var(--text-muted)]">
            {containerLabel && <span className="truncate">{containerLabel}</span>}
            {task.source === "mcp" && (
              <span
                className={`inline-flex items-center gap-1 text-[11px] ${
                  !task.acknowledgedAt ? "text-[var(--accent)]" : "text-[var(--text-muted)]"
                }`}
              >
                <MessageSquareText className="h-3 w-3" />
                {task.sourceClient || "Claude"}
              </span>
            )}
            {checklistItems.length > 0 && (
              <span className="font-mono-tabular inline-flex items-center gap-1">
                <CheckSquare className="h-3 w-3" />
                {checkedCount}/{checklistItems.length}
              </span>
            )}
            {taskRefs.length > 0 && (
              <span className="font-mono-tabular inline-flex items-center gap-0.5">
                <Link2 className="h-3 w-3" />
                {taskRefs.length}
              </span>
            )}
            {attachments.length > 0 && (
              <span className="font-mono-tabular inline-flex items-center gap-0.5">
                <Paperclip className="h-3 w-3" />
                {attachments.length}
              </span>
            )}
            {hasActiveReminder && (
              <span className="inline-flex items-center gap-0.5" title="Reminder set">
                <Bell className="h-3 w-3" />
              </span>
            )}
            {taskTagIds.slice(0, 3).map((tid) => {
              const t = tagMap.get(tid);
              if (!t) return null;
              return (
                <span key={tid} className="rounded bg-[var(--bg-hover)] px-1.5 py-0 text-[11px]">
                  {t.name}
                </span>
              );
            })}
            {task.notes && <span className="max-w-[260px] truncate opacity-80">{task.notes}</span>}
          </div>
        )}
      </div>

      <div className="flex shrink-0 items-center gap-2">
        {isDeletedView && props.onRestoreDeleted && (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              props.onRestoreDeleted!();
            }}
            className="inline-flex items-center gap-1 rounded-md bg-[var(--bg-hover)] px-2 py-1 text-xs font-medium text-[var(--text-primary)] hover:bg-[var(--bg-selected)]"
          >
            <RotateCcw className="h-3 w-3" />
            Restore
          </button>
        )}

        {isFadedView && props.onKeepFaded && props.onDropFaded && (
          <div className="flex items-center gap-1">
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation();
                props.onKeepFaded!();
              }}
              className="rounded-md bg-[var(--bg-selected)] px-2 py-1 text-xs font-medium text-[var(--text-primary)]"
            >
              Keep
            </button>
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation();
                props.onDropFaded!();
              }}
              className="rounded-md bg-[var(--bg-hover)] px-2 py-1 text-xs text-[var(--text-secondary)]"
            >
              Let go
            </button>
          </div>
        )}

        {!isDeletedView && !isFadedView && convoState?.needsHumanReview && (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              props.onAcceptReview();
            }}
            className="rounded-md bg-emerald-600 px-2 py-0.5 text-xs font-medium text-white hover:opacity-90"
          >
            Accept
          </button>
        )}

        {task.startTime && (
          <span className="font-mono-tabular text-xs text-[var(--text-muted)]">{task.startTime}</span>
        )}
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
        {task.recurrenceUnit && (
          <Repeat
            className={`h-3.5 w-3.5 ${task.recurrencePaused ? "opacity-40" : "text-[var(--text-muted)]"}`}
          />
        )}
        {task.starred && (
          <Star className="h-3.5 w-3.5 shrink-0" style={{ color: "#f59e0b", fill: "#f59e0b" }} />
        )}
        {isToday && (
          <Sun className="h-3.5 w-3.5 shrink-0" style={{ color: todayColor }} />
        )}
      </div>
    </div>
  );
}
