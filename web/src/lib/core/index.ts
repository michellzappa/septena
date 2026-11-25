// Browser & Node wrapper for the pinned shared Rust core WASM (ADR 0025, C2 #248).
// Every task rule and sync decision calls the core directly — never re-implemented in TypeScript.

import init, { coreVersion as wasmCoreVersion, initSync, invoke } from "./wasm/septena_core_wasm.js";
import type { OrdinalWeekday, TaskRow } from "../types";

let readyPromise: Promise<void> | null = null;
let ready = false;

export async function ensureCoreReady(): Promise<void> {
  if (ready) return;
  if (!readyPromise) {
    readyPromise = (async () => {
      if (typeof window !== "undefined") {
        await init();
      } else {
        const fs = await import("node:fs");
        const path = await import("node:path");
        const wasmPath = path.resolve(process.cwd(), "src/lib/core/wasm/septena_core_wasm_bg.wasm");
        const bytes = fs.readFileSync(wasmPath);
        initSync({ module: new WebAssembly.Module(bytes) });
      }
      ready = true;
    })();
  }
  await readyPromise;
}

export function isCoreReady(): boolean {
  return ready;
}

export function getCoreVersion(): string {
  if (!ready) return "uninitialized";
  return wasmCoreVersion();
}

export class CoreError extends Error {
  readonly fn: string;
  readonly reason: string;
  constructor(fn: string, reason: string) {
    super(`septena-core ${fn}: ${reason}`);
    this.fn = fn;
    this.reason = reason;
  }
}

export function callCore<T>(fn: string, input: unknown): T {
  if (!ready) throw new Error(`septena-core: call ensureCoreReady() before ${fn}`);
  const out = JSON.parse(invoke(fn, JSON.stringify(input))) as unknown;
  if (out !== null && typeof out === "object" && !Array.isArray(out)) {
    const obj = out as Record<string, unknown>;
    if (typeof obj.error === "string" && Object.keys(obj).length === 1) {
      throw new CoreError(fn, obj.error);
    }
  }
  return out as T;
}

function toCoreTask(task: TaskRow) {
  return {
    id: task.id,
    title: task.title,
    status: task.status,
    kind: task.kind ?? null,
    area: task.area ?? null,
    project: task.project ?? null,
    created: task.created ?? null,
    createdAt: task.createdAt ?? null,
    scheduled: task.scheduled ?? null,
    deadline: task.deadline ?? null,
    today: Boolean(task.today),
    todaySetOn: task.todaySetOn ?? null,
    source: task.source ?? null,
    acknowledgedAt: task.acknowledgedAt ?? null,
    starred: Boolean(task.starred),
    recurrenceUnit: task.recurrenceUnit ?? null,
    deletedAt: task.deletedAt ?? null,
    fadedAt: task.fadedAt ?? null,
    startTime: task.startTime ?? null,
    durationMinutes: task.durationMinutes ?? null,
    timeZone: task.timeZone ?? null,
    reminderAt: task.reminderAt ?? null,
    reminderSnoozedUntil: task.reminderSnoozedUntil ?? null,
    reminderDismissedAt: task.reminderDismissedAt ?? null,
    recurrenceAfterCompletion: task.recurrenceAfterCompletion ?? null,
    recurrenceAnchorDate: task.recurrenceAnchorDate ?? null,
  };
}

// ---- Views & dates ----

export interface CoreMembership {
  isUnfiled: boolean;
  isInboxMember: boolean;
  inTriageBand: boolean;
  isOnToday: boolean;
  inInbox: boolean;
  daysOnToday: number;
  matchesView: {
    today: boolean;
    inbox: boolean;
    upcoming: boolean;
    anytime: boolean;
  };
  dueState: "overdue" | "dueToday" | null;
  deadlineRed: boolean;
  upcomingDay: string | null;
  arrivedOnOwn: boolean;
}

export function taskViewMembership(task: TaskRow, today: string, now: string): CoreMembership {
  return callCore<CoreMembership>("taskViewMembership", {
    task: toCoreTask(task),
    today,
    now,
  });
}

export type CoreDateAction =
  | { type: "putOnToday"; mode?: "makeException" | "updateRule" }
  | { type: "scheduleFor"; day: string; mode?: "makeException" | "updateRule" }
  | { type: "removeFromToday" }
  | { type: "toggleToday"; mode?: "makeException" | "updateRule" }
  | { type: "clearWhenDate" }
  | { type: "clearWhen" }
  | { type: "setDeadline"; day: string | null }
  | { type: "setTimeSlot"; startTime: string | null; durationMinutes: number | null; timeZone: string | null }
  | { type: "fileFromTriage" };

export function applyDateAction(
  task: TaskRow,
  action: CoreDateAction,
  today: string,
  now: string,
): Record<string, unknown> {
  return callCore<Record<string, unknown>>("applyDateAction", {
    task: toCoreTask(task),
    action,
    today,
    now,
  });
}

export function normalizeTaskDates(task: TaskRow, today: string): Record<string, unknown> {
  return callCore<Record<string, unknown>>("normalizeTaskDates", {
    task: toCoreTask(task),
    today,
  });
}

export function nextOccurrenceDates(
  task: TaskRow,
  nextScheduled: string,
  now: string,
): Record<string, unknown> {
  return callCore<Record<string, unknown>>("nextOccurrenceDates", {
    task: toCoreTask(task),
    nextScheduled,
    now,
  });
}

// ---- Recurrence & reminders ----

export interface CoreRecurrenceRule {
  unit: string;
  interval: number;
  afterCompletion: boolean;
  weekdays?: number[] | null;
  monthDay?: number | null;
  ordinalWeekday?: OrdinalWeekday | null;
}

export function nextScheduledDate(input: {
  completedOn: string;
  scheduled?: string | null;
  logicalScheduled?: string | null;
  rule: CoreRecurrenceRule;
}): string | null {
  const { rule, ...days } = input;
  return callCore<string | null>("nextScheduledDate", { ...days, ...rule });
}

export function occurrenceId(sourceTaskID: string, scheduled: string): string {
  return callCore<string>("occurrenceId", { sourceTaskID, scheduled });
}

export function checklistOccurrenceId(
  newTaskID: string,
  index: number,
  sourceItemID: string,
): string {
  return callCore<string>("checklistOccurrenceId", { newTaskID, index, sourceItemID });
}

export function shiftReminderForRecurrence(input: {
  sourceReminderAt: string | null | undefined;
  sourceScheduled: string | null | undefined;
  nextScheduled: string | null | undefined;
}): string | null {
  return callCore<string | null>("shiftReminderForRecurrence", input);
}

export function shiftReminderOnReschedule(input: {
  reminderAt: string | null | undefined;
  oldScheduled: string | null | undefined;
  newScheduled: string | null | undefined;
}): string | null {
  return callCore<string | null>("shiftReminderOnReschedule", input);
}

export function shouldArmReminder(input: {
  status: string;
  isDeleted: boolean;
  isHeading: boolean;
  isUnratifiedProposal: boolean;
  reminderAt: string | null | undefined;
  reminderDismissedAt: string | null | undefined;
}): boolean {
  return callCore<boolean>("shouldArmReminder", input);
}

// ---- Task fade ----

export interface CoreFadeInput {
  isOpen: boolean;
  isHeading: boolean;
  isDeleted: boolean;
  isFaded: boolean;
  deadline?: string | null;
  scheduled?: string | null;
  hasRecurrence: boolean;
  isAgentTurn: boolean;
  isAssignedToClaude: boolean;
  isAwaitingHuman?: boolean;
  showsAgentCue?: boolean;
  touchedAt?: string | null;
  createdAt?: string | null;
  created?: string | null;
  now: string;
  today: string;
  utcOffsetSeconds?: number;
}

export function fadeFill(input: CoreFadeInput): number | null {
  return callCore<number | null>("fadeFill", input);
}

export function shouldFade(input: CoreFadeInput): boolean {
  return callCore<boolean>("shouldFade", input);
}

export function rowOpacity(fill: number | null): number {
  return callCore<number>("rowOpacity", { fill });
}

// ---- Conversations (Review & Agent stages) ----

export interface CoreConversation {
  confirmedIntent?: string | null;
  thread: Array<{
    seq: number;
    role: string;
    step?: string;
    provider?: string | null;
    options?: string[] | null;
    confidence?: number | null;
  }>;
  artifactExists?: boolean;
  handoffExists?: boolean;
  endState?: string | null;
  endStateNote?: string | null;
  assignee?: string | null;
  stoppedAt?: string | null;
  claimUntil?: string | null;
}

export interface CoreProjection {
  stage: string;
  badge: "needsYou" | "working" | "done" | "wontDo" | null;
  nextAction: string;
  pendingReasoning: boolean;
}

export type AgentStage = "queued" | "working" | "yourTurn" | "review" | "done" | null;

export interface CoreConversationState {
  isTerminal: boolean;
  needsHumanReview: boolean;
  hasOpenProviderQuestion: boolean;
  awaitsHuman: boolean;
  hasStarted: boolean;
  isClaimed: boolean;
  agentStage: AgentStage;
}

export function deriveConversation(conversation: CoreConversation, now: string): CoreProjection {
  return callCore<CoreProjection>("deriveConversation", { conversation, now });
}

export function conversationState(conversation: CoreConversation, now: string): CoreConversationState {
  return callCore<CoreConversationState>("conversationState", { conversation, now });
}

// ---- References ----

export interface CoreRef {
  key: string;
  kind: string;
  id: string;
  rawId: string;
  url: string | null;
}

export function parseRef(input: string): CoreRef {
  return callCore<CoreRef>("parseRef", { input });
}

export function normalizeRefKey(key: string): string {
  return callCore<string>("normalizeRefKey", { key });
}

export function findIssueRefs(text: string): CoreRef[] {
  return callCore<CoreRef[]>("findIssueRefs", { text });
}

export function taskRefId(taskId: string, key: string, deletedCount: number): string {
  return callCore<string>("taskRefId", { taskId, key, deletedCount });
}

// ---- Sync decisions ----

export type PullPageCheck =
  | { decision: "apply" }
  | { decision: "applyAndContinue"; nextCursor: number }
  | { decision: "reset" }
  | { decision: "fail"; reason: string };

export function checkPullPage(
  cursor: number,
  page: { resetRequired?: boolean; nextSince: number; hasMore: boolean },
  resetsSoFar: number,
): PullPageCheck {
  return callCore<PullPageCheck>("checkPullPage", {
    cursor,
    page: {
      resetRequired: Boolean(page.resetRequired),
      nextSince: page.nextSince,
      hasMore: page.hasMore,
    },
    resetsSoFar,
  });
}

export type PullRowPlan =
  | { plan: "turn"; taskId: string; seq: number; row: Record<string, unknown> }
  | { plan: "skip" }
  | { plan: "shadowOnly"; shadow: Record<string, unknown>; revision: number }
  | {
      plan: "tombstone";
      keepLocalRow: boolean;
      shadow: Record<string, unknown>;
      revision: number;
      updatedAt: string | null;
      deletedAt: string;
    }
  | {
      plan: "merge";
      fields: Record<string, unknown>;
      shadow: Record<string, unknown>;
      revision: number;
      updatedAt: string | null;
    };

export function planPullRow(input: {
  entity: string;
  row: Record<string, unknown>;
  current: Record<string, unknown> | null;
  pendingFields: string[];
  pendingDelete: boolean;
}): PullRowPlan {
  return callCore<PullRowPlan>("planPullRow", input);
}

export type PushOutcome =
  | { kind: "response"; resultIds: string[] }
  | { kind: "httpFailure"; status: number; body: string };

export type PushResponsePlan =
  | { plan: "applyResults" }
  | { plan: "fail"; reason: string }
  | { plan: "bisect"; splitAt: number }
  | { plan: "rejectOne"; clientOpId: string; reason: string }
  | { plan: "propagate"; status: number };

export function planPushResponse(sentIds: string[], outcome: PushOutcome): PushResponsePlan {
  return callCore<PushResponsePlan>("planPushResponse", { sentIds, outcome });
}

export function serverRejectionReason(status: number, body: string): string {
  return callCore<string>("serverRejectionReason", { status, body });
}

export function localTodayYMD(date = new Date()): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

export function localUtcOffsetSeconds(date = new Date()): number {
  return -date.getTimezoneOffset() * 60;
}
