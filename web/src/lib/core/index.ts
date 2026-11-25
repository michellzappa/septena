// Browser & Node wrapper for the pinned shared Rust core WASM (ADR 0025, C2 #248).
// Task list membership, date actions and sync decisions call the core directly
// and are never re-implemented in TypeScript.

import init, { coreVersion as wasmCoreVersion, initSync, invoke } from "./wasm/septena_core_wasm.js";
import type { TaskRow } from "../types";

let readyPromise: Promise<void> | null = null;
let ready = false;

export async function ensureCoreReady(): Promise<void> {
  if (ready) return;
  if (!readyPromise) {
    readyPromise = (async () => {
      if (typeof window !== "undefined") {
        await init();
      } else {
        // Node unit test environment: load from src/lib/core/wasm/
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
    task: {
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
    },
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
  | { type: "setDeadline"; day: string | null };

export function applyDateAction(
  task: TaskRow,
  action: CoreDateAction,
  today: string,
  now: string,
): Record<string, unknown> {
  return callCore<Record<string, unknown>>("applyDateAction", {
    task: {
      id: task.id,
      title: task.title,
      status: task.status,
      kind: task.kind ?? null,
      area: task.area ?? null,
      project: task.project ?? null,
      scheduled: task.scheduled ?? null,
      deadline: task.deadline ?? null,
      today: Boolean(task.today),
      todaySetOn: task.todaySetOn ?? null,
      recurrenceUnit: task.recurrenceUnit ?? null,
      deletedAt: task.deletedAt ?? null,
      fadedAt: task.fadedAt ?? null,
    },
    action,
    today,
    now,
  });
}

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
  | { plan: "turn" }
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

export function localTodayYMD(date = new Date()): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}
