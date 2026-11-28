"use client";

import { useEffect, useRef, useState } from "react";
import {
  AlignLeft,
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
  ListChecks,
  Maximize2,
  MessageSquare,
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
import { attributeLabel } from "@/lib/dateBoard";
import { ACTIONS_CATALOG, registryText } from "@/lib/generated/registries";
import {
  completedLocalDay,
  type CoreConversationState,
  type CoreMembership,
  type CoreProjection,
} from "@/lib/core";
import { agentStageTitle } from "@/lib/destinations";
import { COMPLETION_MOTION } from "@/lib/settle";
import { assigneeLabel, sharedWaitingTarget, sharingCopy, waitingLabel, waitingName } from "@/lib/waiting";
import type {
  AreaRow,
  AttachmentRow,
  ChangeEntry,
  ChecklistItemRow,
  ConvoRow,
  ProjectRow,
  ProjectShareInfo,
  TagRow,
  TaskRefRow,
  TaskRow,
  TurnRow,
} from "@/lib/types";
import { DateBoardButton } from "./DateBoard";
import { RegistryIcon } from "./RegistryIcon";

export interface TaskRowItemProps {
  task: TaskRow;
  membership: CoreMembership;
  opacity: number;
  containerLabel?: string | null;
  /** Opens the list that `containerLabel` names (the row's area or project). */
  onOpenContainer?: () => void;
  hasPendingOp: boolean;
  selected: boolean;
  multiSelected?: boolean;
  expanded: boolean;
  isDeletedView?: boolean;
  isFadedView?: boolean;
  /** True on off-Today lists (Projects, Areas, Anytime, etc.); false on Today (matching iOS TaskRow.showsTodayIndicator). */
  showsTodayIndicator?: boolean;
  /** True on Projects/Areas when faded tasks are shown inline. */
  showsFadedIndicator?: boolean;
  /** Shared project metadata for this task's project, if shared. */
  projectShare?: ProjectShareInfo | null;
  /** True inside a shared project so rows also show "You" for your own tasks. */
  showsOwnAssignee?: boolean;
  /** Assign To (PROJECT_SHARING_SPEC §8): memberId or null for nobody. */
  onAssignMember?: (memberId: string | null) => void;
  isColorfulAccent?: boolean;
  animateCompletion?: boolean;
  /** True while this completed/cancelled row lingers in place during the standard settle window. */
  isSettling?: boolean;
  /** True during the final fade-out beat of the settle window. */
  isFadingOut?: boolean;
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
  todayYMD: string;
  lang: string;
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
  /** Waiting On… (REVIEW_SPEC §6): opens the sheet. */
  onWaitingOn?: () => void;
  /** Got It Back: only on a waiting task. */
  onGotItBack?: () => void;
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

function formatShortDate(ymd: string | null | undefined, todayYMD: string): string | null {
  if (!ymd) return null;
  const clean = ymd.slice(0, 10);
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(clean);
  if (!m) return clean;
  const dt = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  const tm = /^(\d{4})-(\d{2})-(\d{2})$/.exec(todayYMD);
  if (tm) {
    const tdt = new Date(Number(tm[1]), Number(tm[2]) - 1, Number(tm[3]));
    const diff = Math.round(
      (Date.UTC(dt.getFullYear(), dt.getMonth(), dt.getDate()) -
        Date.UTC(tdt.getFullYear(), tdt.getMonth(), tdt.getDate())) /
        86_400_000,
    );
    if (diff === 0) return "Today";
    if (diff === 1) return "Tomorrow";
  }
  return dt.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

const REPEAT_UNITS: Record<string, string> = {
  day: "Daily",
  week: "Weekly",
  month: "Monthly",
  year: "Yearly",
};

/** The day the When board shows as chosen. The Today pin carries no date, so it is today. */
export function whenDay(task: TaskRow, todayYMD: string): string | null {
  return task.scheduled ?? (task.today ? todayYMD : null);
}

/** The When board's Repeat row: "Repeat…", or the rule when the task already repeats. */
export function repeatTitle(task: TaskRow, lang: string): string {
  const unit = task.recurrenceUnit ? REPEAT_UNITS[task.recurrenceUnit] : undefined;
  return unit
    ? `${attributeLabel("repeat", lang)}: ${unit}`
    : registryText(ACTIONS_CATALOG.actions["task.repeat"].title, lang);
}

export function openRepeatSelect(select: HTMLSelectElement | null | undefined) {
  if (!select) return;
  select.focus();
  try {
    select.showPicker?.();
  } catch {
    // The browser opens a menu only inside a user gesture. The focus stays on the control.
  }
}

/**
 * iOS TaskCheckbox (Task Row Language v2):
 * - Neutral gray 17px rounded-square stroke (no yellow Today box)
 * - Dashed border for unratified MCP triage-band proposals
 * - 7px haloed accent corner dot on committed tasks with unread agent context
 * - Centered inside a fixed 22px column so every row aligns with group header icons
 */
function TaskCheckboxControl({
  isDone,
  isCancelled,
  isProposal,
  hasCornerDot,
  justChecked,
  onToggle,
}: {
  isDone: boolean;
  isCancelled: boolean;
  isProposal: boolean;
  hasCornerDot: boolean;
  justChecked: boolean;
  onToggle: (e: React.MouseEvent) => void;
}) {
  return (
    <button
      type="button"
      onClick={onToggle}
      aria-label={isDone ? "Mark open" : "Complete task"}
      className="flex h-[22px] w-[22px] shrink-0 items-center justify-center"
    >
      <span
        className={`relative flex h-[17px] w-[17px] items-center justify-center rounded-[4.5px] border-[1.4px] transition-colors ${
          justChecked ? "animate-check-pop" : ""
        } ${
          isDone
            ? "border-[var(--accent)] bg-[var(--accent)]"
            : isCancelled
              ? "border-[var(--text-muted)]/40 bg-[var(--text-muted)]/20 text-[var(--text-muted)]"
              : isProposal
                ? "border-dashed border-[var(--checkbox-stroke)] hover:border-[var(--accent)]"
                : "border-[var(--checkbox-stroke)] hover:border-[var(--accent)]"
        }`}
        style={isDone ? { color: "var(--accent-check)" } : undefined}
      >
        {justChecked && (
          <span
            aria-hidden="true"
            className="animate-check-ring pointer-events-none absolute inset-[-1.4px] rounded-[4.5px] border-[1.5px] border-[var(--accent)]"
          />
        )}
        {isDone && <Check className={`h-[11px] w-[11px] stroke-[3] ${justChecked ? "animate-check-mark" : ""}`} />}
        {isCancelled && <X className="h-[11px] w-[11px] stroke-[2.5]" />}
        {hasCornerDot && (
          <span
            aria-hidden="true"
            className="pointer-events-none absolute -top-[3px] -right-[3px] h-[7px] w-[7px] rounded-full bg-[var(--accent)] ring-[1.5px] ring-[var(--bg-card)]"
          />
        )}
      </span>
    </button>
  );
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
  const repeatSelectRef = useRef<HTMLSelectElement | null>(null);

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

  const isDone = task.status === "done" || task.status === "checklistChecked";
  const isCancelled = task.status === "cancelled";
  const isToday = membership.isOnToday;
  const taskTagIds = Array.isArray(task.tags) ? task.tags : [];
  const editorWaitingLabel = waitingLabel(task, props.todayYMD, props.lang, props.projectShare);

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
  const isProposal = membership.inTriageBand && task.source === "mcp";
  const hasCornerDot =
    !isProposal && !isDone && !isCancelled && props.convoProjection?.badge != null;

  return (
    <div
      data-task-id={task.id}
      className={
        isPageMode
          ? "space-y-4"
          : "bg-[var(--bg-elevated)] px-3 py-3.5"
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
      <div className="flex items-start gap-2.5">
        <div className="mt-[1px]">
          <TaskCheckboxControl
            isDone={isDone}
            isCancelled={isCancelled}
            isProposal={isProposal}
            hasCornerDot={hasCornerDot}
            justChecked={justChecked}
            onToggle={() => {
              if (animateCompletion && !isDone) {
                setJustChecked(true);
                setTimeout(() => setJustChecked(false), 260);
              }
              props.onToggleDone();
            }}
          />
        </div>

        <div className="min-w-0 flex-1 space-y-3">
          {/* 1. Header */}
          <div className="flex items-center gap-1.5">
            <input
              type="text"
              value={titleDraft}
              onChange={(e) => setTitleDraft(e.target.value)}
              onBlur={commitTitle}
              onKeyDown={(e) => {
                if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
                  e.preventDefault();
                  commitTitle();
                  e.currentTarget.blur();
                  props.onCollapse?.();
                } else if (e.key === "Enter") {
                  e.currentTarget.blur();
                } else if (e.key === "Escape" && props.onCollapse) {
                  props.onCollapse();
                }
              }}
              className="min-w-0 flex-1 bg-transparent text-[15px] font-medium text-[var(--text-primary)] outline-none"
              placeholder="Task title"
            />
            <button
              type="button"
              onClick={props.onToggleStar}
              title={task.starred ? "Unstar (⌘⌥S)" : "Star (⌘⌥S)"}
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
            onKeyDown={(e) => {
              if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
                e.preventDefault();
                commitNotes();
                e.currentTarget.blur();
                props.onCollapse?.();
              } else if (e.key === "Escape" && props.onCollapse) {
                commitNotes();
                props.onCollapse();
              }
            }}
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

            <DateBoardButton
              attribute="when"
              value={whenDay(task, props.todayYMD)}
              today={props.todayYMD}
              lang={props.lang}
              startTime={task.startTime}
              durationMinutes={task.durationMinutes}
              repeatTitle={repeatTitle(task, props.lang)}
              onPick={props.onSetScheduled}
              onClear={() => props.onSetScheduled(null)}
              onTimeSlotChange={props.onSetTimeSlot}
              onRepeat={() => openRepeatSelect(repeatSelectRef.current)}
            />

            <DateBoardButton
              attribute="deadline"
              value={task.deadline ?? null}
              today={props.todayYMD}
              lang={props.lang}
              red={membership.deadlineRed}
              onPick={props.onSetDeadline}
              onClear={() => props.onSetDeadline(null)}
            />

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
                ref={repeatSelectRef}
                data-repeat-task={task.id}
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
                {Object.entries(REPEAT_UNITS).map(([unit, title]) => (
                  <option key={unit} value={unit}>
                    {title}
                  </option>
                ))}
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
                    {agentStageTitle(convoState.agentStage)}
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
                      if (!sendBackNote.trim()) return;
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
                      disabled={!sendBackNote.trim()}
                      className="rounded-md bg-[var(--accent)] px-2.5 py-1 font-medium disabled:opacity-50"
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
            {task.source === "mcp" && (
              <RegistryIcon
                token="task.added_by_agent"
                className="h-3.5 w-3.5 text-[var(--text-muted)]"
              />
            )}
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
            {!isDone && !isCancelled && props.onWaitingOn && (!editorWaitingLabel || Boolean(waitingName(task))) && (
              <button
                type="button"
                onClick={props.onWaitingOn}
                title={editorWaitingLabel ?? undefined}
                className="inline-flex max-w-[16rem] items-center gap-1 rounded-lg px-2 py-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
              >
                <RegistryIcon token="action.waiting" className="h-3.5 w-3.5 shrink-0" />
                <span className="truncate">
                  {editorWaitingLabel ?? registryText(ACTIONS_CATALOG.actions["task.waitingOn"].title, props.lang)}
                </span>
              </button>
            )}
            {!isDone && !isCancelled && editorWaitingLabel && props.onGotItBack && (
              <button
                type="button"
                onClick={props.onGotItBack}
                className="rounded-lg px-2 py-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]"
              >
                {registryText(ACTIONS_CATALOG.actions["task.gotItBack"].title, props.lang)}
              </button>
            )}
            {!isDone && !isCancelled && props.projectShare && props.onAssignMember && (
              <label className="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-[var(--text-muted)] hover:bg-[var(--bg-hover)] hover:text-[var(--text-primary)]">
                <RegistryIcon token="action.assign" className="h-3.5 w-3.5 shrink-0" />
                <select
                  aria-label="Assign To"
                  value={task.assignedTo ?? ""}
                  onChange={(e) => props.onAssignMember?.(e.target.value || null)}
                  className="bg-transparent text-xs text-inherit focus:outline-none"
                >
                  <option value="">{sharingCopy("nobody", props.lang)}</option>
                  {props.projectShare.members.map((m) => (
                    <option key={m.id} value={m.id}>
                      {m.id === props.projectShare?.me ? `${m.name} (${sharingCopy("you", props.lang)})` : m.name}
                    </option>
                  ))}
                </select>
              </label>
            )}

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
    showsTodayIndicator = true,
    showsFadedIndicator = false,
    todayYMD,
    isColorfulAccent = true,
    animateCompletion = true,
    isFadingOut = false,
    draggable = false,
    isDropTarget = false,
    checklistItems,
    allTags,
    attachments,
    convoProjection,
    convoState,
  } = props;

  const isDone = task.status === "done" || task.status === "checklistChecked";
  const [justChecked, setJustChecked] = useState(false);
  const prevIsDoneRef = useRef(isDone);

  useEffect(() => {
    const wasDone = prevIsDoneRef.current;
    prevIsDoneRef.current = isDone;
    if (!wasDone && isDone && animateCompletion) {
      setJustChecked(true);
      const timer = setTimeout(() => setJustChecked(false), COMPLETION_MOTION.pulseRingMs + 40);
      return () => clearTimeout(timer);
    }
    if (!isDone) setJustChecked(false);
  }, [animateCompletion, isDone]);

  if (expanded) {
    return <TaskDetailEditor props={props} />;
  }

  const isCancelled = task.status === "cancelled";
  const isInactive = isDone || isCancelled;
  const isToday = membership.isOnToday;
  const isProposal = membership.inTriageBand && task.source === "mcp";
  const hasCornerDot = !isProposal && !isInactive && convoProjection?.badge != null;
  const isAgentAuthored = task.source === "mcp";
  const hasNotes = Boolean(task.notes && task.notes.trim().length > 0);
  const tagMap = new Map(allTags.map((t) => [t.id, t]));
  const resolvedTags = (Array.isArray(task.tags) ? task.tags : [])
    .map((tid) => tagMap.get(tid))
    .filter((t): t is TagRow => Boolean(t));
  const checkedCount = checklistItems.filter((c) => c.checked).length;
  const todayColor = isColorfulAccent ? "var(--today-gold)" : "var(--accent)";
  const hasActiveReminder = Boolean(task.reminderAt && !task.reminderDismissedAt);
  const rowWaitingLabel = isDone || isCancelled ? null : waitingLabel(task, props.todayYMD, props.lang, props.projectShare);
  const waitingCoversAssignee = Boolean(rowWaitingLabel && !waitingName(task) && sharedWaitingTarget(task, props.projectShare));
  const rowAssigneeLabel = waitingCoversAssignee
    ? null
    : assigneeLabel(task, props.projectShare, Boolean(props.showsOwnAssignee), props.lang);
  const reminderPastDue =
    hasActiveReminder &&
    Number.isFinite(Date.parse(task.reminderSnoozedUntil || task.reminderAt!)) &&
    Date.parse(task.reminderSnoozedUntil || task.reminderAt!) <= Date.now();

  const showFadedPill = Boolean(
    showsFadedIndicator && task.fadedAt && !isDeletedView && !isInactive,
  );
  const showTodayPill = Boolean(
    !showFadedPill &&
      showsTodayIndicator &&
      isToday &&
      !isDeletedView &&
      !isInactive &&
      !task.fadedAt,
  );

  const deadlineYMD = task.deadline ? task.deadline.slice(0, 10) : null;
  const deadlineIsToday = deadlineYMD === todayYMD;
  const scheduledYMD = task.scheduled ? task.scheduled.slice(0, 10) : null;
  const showScheduledDate = Boolean(
    !isInactive &&
      !task.deadline &&
      scheduledYMD &&
      !(!showsTodayIndicator && scheduledYMD <= todayYMD) &&
      !(showTodayPill && scheduledYMD <= todayYMD),
  );
  const completedShort = formatShortDate(completedLocalDay(task.completedAt), todayYMD);

  return (
    <div
      className="septena-settle-row"
      data-fading-out={isFadingOut ? "true" : undefined}
    >
      <div className="septena-settle-row-inner">
        <div
          data-task-id={task.id}
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
          className={`group relative flex w-full cursor-pointer items-center gap-2.5 px-3 py-2.5 text-left transition-colors ${
            isDropTarget ? "border-t-2 border-[var(--accent)]" : ""
          } ${
            selected || multiSelected
              ? "bg-[var(--bg-selected)]"
              : "hover:bg-[var(--bg-hover)]"
          }`}
        >
          {!isDeletedView && (
            <TaskCheckboxControl
              isDone={isDone}
              isCancelled={isCancelled}
              isProposal={isProposal}
              hasCornerDot={hasCornerDot}
              justChecked={justChecked}
              onToggle={(e) => {
                e.stopPropagation();
                props.onToggleDone();
              }}
            />
          )}

      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5">
          <span
            className={`line-clamp-2 text-[15px] leading-[1.3] ${
              isInactive ? "text-[var(--text-muted)] line-through" : "text-[var(--text-primary)]"
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

        {containerLabel && (
          <div className="mt-0.5 truncate text-[12px] leading-tight text-[var(--text-muted)]">
            {props.onOpenContainer ? (
              // Its own target: a click opens the list, the rest of the row opens the task.
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  if (e.metaKey || e.ctrlKey || e.shiftKey) {
                    props.onRowClick(e);
                    return;
                  }
                  props.onOpenContainer!();
                }}
                onKeyDown={(e) => e.stopPropagation()}
                className="max-w-full truncate text-left hover:text-[var(--text-secondary)] hover:underline"
              >
                {containerLabel}
              </button>
            ) : (
              containerLabel
            )}
          </div>
        )}
      </div>

      {/* Trailing cluster — exact iOS left-to-right order (TaskComponents.swift):
          actions · status pill · date · time · checklist · tags · attachments · reminder · repeat · star · notes · agent provenance */}
      <div className="flex shrink-0 items-center gap-1.5 text-[11px] text-[var(--text-muted)]">
        {isDeletedView && props.onRestoreDeleted && (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              props.onRestoreDeleted!();
            }}
            className="inline-flex items-center gap-1 rounded-full bg-[var(--bg-pill)] px-2.5 py-0.5 text-[11px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-selected)]"
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
              className="rounded-full bg-[var(--bg-selected)] px-2.5 py-0.5 text-[11px] font-medium text-[var(--text-primary)]"
            >
              Keep
            </button>
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation();
                props.onDropFaded!();
              }}
              className="rounded-full bg-[var(--bg-pill)] px-2.5 py-0.5 text-[11px] text-[var(--text-secondary)]"
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
            className="rounded-full bg-emerald-600 px-2.5 py-0.5 text-[11px] font-medium text-white hover:opacity-90"
          >
            Accept
          </button>
        )}

        {showFadedPill && (
          <span className="inline-flex items-center gap-1 rounded-full bg-[var(--bg-pill)] px-2 py-0.5 text-[11px] font-medium text-[var(--text-secondary)]">
            <RegistryIcon token="list.faded" className="h-[11px] w-[11px] shrink-0" />
            <span>Faded</span>
          </span>
        )}

        {showTodayPill && (
          <span className="inline-flex items-center gap-1 rounded-full bg-[var(--bg-pill)] px-2 py-0.5 text-[11px] font-medium text-[var(--text-secondary)]">
            <RegistryIcon
              token="list.today"
              className="h-[11px] w-[11px] shrink-0"
              style={{ color: todayColor }}
            />
            <span>Today</span>
          </span>
        )}

        {rowWaitingLabel && !isDeletedView && (
          <span className="inline-flex min-w-0 items-center gap-1 rounded-full bg-[var(--bg-pill)] px-2 py-0.5 text-[11px] font-medium text-[var(--text-secondary)]">
            <RegistryIcon token="action.waiting" className="h-[11px] w-[11px] shrink-0" />
            <span className="truncate">{rowWaitingLabel}</span>
          </span>
        )}

        {rowAssigneeLabel && !isDeletedView && (
          <span className="inline-flex min-w-0 items-center gap-1 rounded-full bg-[var(--bg-pill)] px-2 py-0.5 text-[11px] font-medium text-[var(--text-secondary)]">
            <RegistryIcon token="action.assign" className="h-[11px] w-[11px] shrink-0" />
            <span className="truncate">{rowAssigneeLabel}</span>
          </span>
        )}

        {isDone && completedShort && (
          <span className="font-mono-tabular inline-flex items-center gap-0.5 text-[11px] text-[var(--text-muted)]">
            <Check className="h-3 w-3" />
            {completedShort}
          </span>
        )}

        {isCancelled && (
          <span className="font-mono-tabular text-[11px] text-[var(--text-muted)]">
            {task.dropReason === "faded" ? "Let go" : "Cancelled"}
            {completedShort ? ` · ${completedShort}` : ""}
          </span>
        )}

        {!isInactive && deadlineYMD && (
          deadlineIsToday ? (
            <span className="text-[11px] font-semibold text-[var(--overdue-red)]">Today</span>
          ) : membership.deadlineRed ? (
            <span className="text-[11px] font-semibold text-[var(--overdue-red)]">Overdue</span>
          ) : (
            <span className="font-mono-tabular inline-flex items-center gap-0.5 text-[11px] text-[var(--text-muted)]">
              <Flag className="h-[11px] w-[11px]" />
              {formatShortDate(deadlineYMD, todayYMD)}
            </span>
          )
        )}

        {showScheduledDate && (
          <span className="font-mono-tabular inline-flex items-center gap-0.5 text-[11px] text-[var(--text-muted)]">
            <Calendar className="h-[11px] w-[11px]" />
            {formatShortDate(scheduledYMD, todayYMD)}
          </span>
        )}

        {!isInactive && task.startTime && (
          <span className="font-mono-tabular inline-flex items-center gap-0.5 text-[11px] text-[var(--text-muted)]">
            <Clock className="h-[11px] w-[11px]" />
            {task.startTime}
          </span>
        )}

        {checklistItems.length > 0 && (
          <span className="font-mono-tabular inline-flex items-center gap-0.5 text-[11px] text-[var(--text-muted)]">
            <ListChecks className="h-[11px] w-[11px]" />
            {checkedCount}/{checklistItems.length}
          </span>
        )}

        {resolvedTags.slice(0, 2).map((t) => (
          <span
            key={t.id}
            className="max-w-[96px] truncate rounded-full border border-[var(--text-muted)]/30 px-1.5 py-[1px] text-[10.5px] leading-tight text-[var(--text-secondary)]"
          >
            {t.name}
          </span>
        ))}
        {resolvedTags.length > 2 && (
          <span className="font-mono-tabular text-[10.5px] text-[var(--text-muted)]">
            +{resolvedTags.length - 2}
          </span>
        )}

        {attachments.length > 0 && (
          <span className="font-mono-tabular inline-flex items-center gap-0.5 text-[11px] text-[var(--text-muted)]">
            <Paperclip className="h-[11px] w-[11px]" />
            {attachments.length}
          </span>
        )}

        {hasActiveReminder && (
          <Bell
            className={`h-[12px] w-[12px] shrink-0 ${
              reminderPastDue ? "text-[var(--overdue-red)]" : "text-[var(--text-muted)]"
            }`}
            aria-label="Reminder set"
          />
        )}

        {task.recurrenceUnit && (
          <Repeat
            className={`h-[12px] w-[12px] shrink-0 ${
              task.recurrencePaused ? "opacity-40" : "text-[var(--text-muted)]"
            }`}
            aria-label="Repeating task"
          />
        )}

        {task.starred && (
          <Star
            className="h-[12px] w-[12px] shrink-0"
            style={{ color: "var(--today-gold)", fill: "var(--today-gold)" }}
            aria-label="Starred"
          />
        )}

        {hasNotes && !isAgentAuthored && (
          <AlignLeft
            className="h-[12px] w-[12px] shrink-0 text-[var(--text-muted)]"
            aria-label="Has notes"
          />
        )}

        {isAgentAuthored && (
          <RegistryIcon
            token="task.added_by_agent"
            className="h-[12px] w-[12px] shrink-0 text-[var(--text-muted)]"
            aria-label={`Added by ${task.sourceClient || "agent"}`}
          />
        )}
          </div>
        </div>
      </div>
    </div>
  );
}
