// The shared Rust core in the Worker (ADR 0025, C3 #249).
//
// `./wasm/` is the `septena-core-wasm-web` package of the pinned core release
// (`scripts/core-pin.sh` writes it; `./wasm/VERSION` names the release). Task
// rules the core holds are called here and never re-implemented in
// TypeScript. Every call goes through the core's one JSON entry point,
// `invoke`, with the same camelCase shapes as `registry/conformance/*.json`.
//
// The Worker entry (`src/index.ts`) compiles the module at bundle time and
// calls `initCore` once per isolate: Workers refuse to compile WASM from bytes
// at run time. Under Node (backend/test) the first call loads the file
// itself.

import { initSync, invoke } from "./wasm/septena_core_wasm.js";

let ready = false;

/// Instantiate the core. Idempotent.
export function initCore(module: WebAssembly.Module): void {
  if (ready) return;
  initSync({ module });
  ready = true;
}

function ensureReady(): void {
  if (ready) return;
  // Node only (tests): read the .wasm next to this file.
  const proc = (globalThis as { process?: { getBuiltinModule?: (id: string) => unknown } }).process;
  const fs = proc?.getBuiltinModule?.("node:fs") as { readFileSync(p: URL): Uint8Array<ArrayBuffer> } | undefined;
  if (!fs) throw new Error("septena-core: initCore was not called");
  const bytes = fs.readFileSync(new URL("./wasm/septena_core_wasm_bg.wasm", import.meta.url));
  initCore(new WebAssembly.Module(bytes));
}

/// The core refused an input. `reason` is the core's text. It never holds the
/// input, so it is safe to log.
export class CoreInputError extends Error {
  readonly reason: string;
  constructor(fn: string, reason: string) {
    super(`septena-core ${fn}: ${reason}`);
    this.reason = reason;
  }
}

/// Calls one core function. A core error comes back as `{"error": …}`; it
/// is thrown here, so a bad input fails the request instead of turning into
/// a silent default.
export function callCore<T>(fn: string, input: unknown): T {
  ensureReady();
  const out = JSON.parse(invoke(fn, JSON.stringify(input))) as unknown;
  if (out !== null && typeof out === "object" && !Array.isArray(out)) {
    const o = out as Record<string, unknown>;
    if (typeof o.error === "string" && Object.keys(o).length === 1) {
      throw new CoreInputError(fn, o.error);
    }
  }
  return out as T;
}

// ---- Typed calls ----

/// The task fields the core reads (`TaskSnapshot`). Absent = none.
export interface CoreTask {
  id?: string;
  title?: string;
  status: string;
  kind?: string | null;
  area?: string | null;
  project?: string | null;
  created?: string | null;
  createdAt?: string | null;
  scheduled?: string | null;
  deadline?: string | null;
  today?: boolean;
  todaySetOn?: string | null;
  source?: string | null;
  acknowledgedAt?: string | null;
  starred?: boolean;
  recurrenceUnit?: string | null;
  deletedAt?: string | null;
  fadedAt?: string | null;
  startTime?: string | null;
  durationMinutes?: number | null;
  timeZone?: string | null;
  reminderAt?: string | null;
  reminderSnoozedUntil?: string | null;
  reminderDismissedAt?: string | null;
  recurrenceAfterCompletion?: boolean | null;
  recurrenceAnchorDate?: string | null;
}

export interface CoreMembership {
  isUnfiled: boolean;
  isInboxMember: boolean;
  inTriageBand: boolean;
  isOnToday: boolean;
  inInbox: boolean;
  daysOnToday: number;
  matchesView: { today: boolean; inbox: boolean; upcoming: boolean; anytime: boolean };
  dueState: "overdue" | "dueToday" | null;
  deadlineRed: boolean;
  upcomingDay: string | null;
  arrivedOnOwn: boolean;
}

/// Which lists a task belongs to on `today` (`YYYY-MM-DD`) at `now` (ISO).
export function taskViewMembership(task: CoreTask, today: string, now: string): CoreMembership {
  return callCore("taskViewMembership", { task, today, now });
}

export interface CoreRecurrenceRule {
  unit: string;
  interval: number;
  afterCompletion: boolean;
  weekdays?: number[] | null;
  monthDay?: number | null;
  ordinalWeekday?: { ordinal: number; weekday: number } | null;
}

export function nextScheduledDate(input: {
  completedOn: string;
  scheduled?: string | null;
  logicalScheduled?: string | null;
  rule: CoreRecurrenceRule;
}): string | null {
  const { rule, ...days } = input;
  return callCore("nextScheduledDate", { ...days, ...rule });
}

export function occurrenceId(sourceTaskID: string, scheduled: string): string {
  return callCore("occurrenceId", { sourceTaskID, scheduled });
}

export function checklistOccurrenceId(newTaskID: string, index: number, sourceItemID: string): string {
  return callCore("checklistOccurrenceId", { newTaskID, index, sourceItemID });
}

export function shiftReminderForRecurrence(input: {
  sourceReminderAt: string | null | undefined;
  sourceScheduled: string | null | undefined;
  nextScheduled: string | null | undefined;
}): string | null {
  return callCore("shiftReminderForRecurrence", input);
}

export function shiftReminderOnReschedule(input: {
  reminderAt: string | null | undefined;
  oldScheduled: string | null | undefined;
  newScheduled: string | null | undefined;
}): string | null {
  return callCore("shiftReminderOnReschedule", input);
}

export function shouldArmReminder(input: {
  status: string;
  isDeleted: boolean;
  isHeading: boolean;
  isUnratifiedProposal: boolean;
  reminderAt: string | null | undefined;
  reminderDismissedAt: string | null | undefined;
}): boolean {
  return callCore("shouldArmReminder", input);
}

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

/// Fade progress in 0…1, or null (spec `docs/TASK_FADE_SPEC.md` §4).
export function fadeFill(input: CoreFadeInput): number | null {
  return callCore("fadeFill", input);
}

/// A date action of `docs/TASK_DATES_SPEC.md` §4, in the core's JSON shape.
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

/// The date fields one action changes, by column name. Empty when the
/// action changes nothing (a heading, a deleted row, or no difference).
export function applyDateAction(
  task: CoreTask, action: CoreDateAction, today: string, now: string,
): Record<string, unknown> {
  return callCore("applyDateAction", { task, action, today, now });
}

/// The fields a row needs to meet the date invariants (I1–I7).
export function normalizeTaskDates(task: CoreTask, today: string): Record<string, unknown> {
  return callCore("normalizeTaskDates", { task, today });
}

/// A10: the date fields of the next occurrence of a repeating task, due on
/// `nextScheduled`, as columns (every date field, nulls included).
export function nextOccurrenceDates(task: CoreTask, nextScheduled: string, now: string): Record<string, unknown> {
  return callCore("nextOccurrenceDates", { task, nextScheduled, now });
}

/// A task's conversation as the core reads it (`TaskConversation`).
export interface CoreConversation {
  confirmedIntent?: string | null;
  thread: Array<{ seq: number; role: string; options?: string[] | null; confidence?: number | null }>;
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
  badge: string | null;
  nextAction: string;
  pendingReasoning: boolean;
}

/// The stage, badge, next action and pending-reasoning flag of a
/// conversation (`convo.rs`, vectors `convo-derived.json`).
export function deriveConversation(conversation: CoreConversation, now: string): CoreProjection {
  return callCore("deriveConversation", { conversation, now });
}

/// A parsed reference (`refs.rs`, vectors `refs.json`).
export interface CoreRef {
  key: string;
  kind: string;
  id: string;
  /// The id before normalisation (`snapshot.rawId`).
  rawId: string;
  /// The web address of the item, when the input was one.
  url: string | null;
}

/// Parses a key, a web URL or a `message://` link. Throws `CoreInputError`.
export function parseRef(input: string): CoreRef {
  return callCore("parseRef", { input });
}

/// Every GitHub issue or pull request URL in a text, in order, one per key.
export function findIssueRefs(text: string): CoreRef[] {
  return callCore("findIssueRefs", { text });
}

/// The id of a `taskRef` row. `deletedCount`: the deleted rows with the same
/// task and key.
export function taskRefId(taskId: string, key: string, deletedCount: number): string {
  return callCore("taskRefId", { taskId, key, deletedCount });
}
