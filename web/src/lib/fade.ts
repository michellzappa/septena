// Task fade on web (docs/TASK_FADE_SPEC.md §4 and §5). The fade rule is in the
// shared core; this file adapts rows to it and holds the weekly sweep, as
// SeptenaCore/TaskFade.swift does.

import { localTodayYMD, type CoreFadeInput } from "./core/index.ts";
import { DOMAIN_RULES } from "./generated/registries.ts";
import type { EvaluatedConversation } from "./conversation.ts";
import type { ConvoRow, ProjectShareInfo, TaskRow } from "./types";
import { isWaitingTask } from "./waiting.ts";

export interface FadeClock {
  now: string;
  today: string;
  utcOffsetSeconds: number;
}

/** An agent added the task and the user has not accepted it (ADR 0039). */
export function isProposal(task: Pick<TaskRow, "source" | "acknowledgedAt">): boolean {
  return task.source === "mcp" && !task.acknowledgedAt;
}

export function fadeInput(
  task: TaskRow,
  convo: ConvoRow | null,
  conversation: EvaluatedConversation | null,
  clock: FadeClock,
  share?: ProjectShareInfo | null,
): CoreFadeInput {
  return {
    isOpen: task.status === "open",
    isHeading: task.kind === "heading",
    isDeleted: Boolean(task.deletedAt),
    isFaded: Boolean(task.fadedAt),
    deadline: task.deadline ?? null,
    scheduled: task.scheduled ?? null,
    hasRecurrence: Boolean(task.recurrenceUnit),
    isAgentTurn: Boolean(conversation?.state.isClaimed || conversation?.projection.badge === "working"),
    isAssignedToClaude: convo?.assignee === "claude",
    isAwaitingHuman: Boolean(conversation?.state.awaitsHuman || isWaitingTask(task, share)),
    showsAgentCue: isProposal(task),
    isProposal: isProposal(task),
    endState: convo?.endState ?? null,
    touchedAt: task.touchedAt ?? null,
    createdAt: task.createdAt ?? null,
    created: task.created ?? null,
    ...clock,
  };
}

// ---- Account settings ----

export interface FadeSettings {
  /** `tasksShowAging`: absent or null means on. */
  enabled: boolean;
  /** When the user last finished a sweep (ISO stamp). */
  sweptAt: string | null;
  /** The sweep day (`YYYY-MM-DD`) whose prompt the user dismissed. */
  dismissedOn: string | null;
}

export function fadeSettings(settings: Record<string, unknown>): FadeSettings {
  const text = (value: unknown) => (typeof value === "string" && value ? value : null);
  return {
    enabled: settings.tasksShowAging !== false,
    sweptAt: text(settings.fadeSweptAt),
    dismissedOn: text(settings.fadeSweepDismissedOn),
  };
}

// ---- Weekly sweep ----

/** The most recent sweep day (Sunday by default) on or before `now`. */
export function sweepAnchorDay(now: Date): string {
  const daysSince = (now.getDay() + 1 - DOMAIN_RULES.fadeSweepWeekday + 7) % 7;
  return localTodayYMD(new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysSince));
}

/** Whether a task faded since the last finished sweep. */
export function isInCurrentSweep(fadedAt: string | null | undefined, sweptAt: string | null): boolean {
  if (!fadedAt) return false;
  return !sweptAt || Date.parse(fadedAt) > Date.parse(sweptAt);
}

/**
 * Whether Today shows the weekly prompt: on the sweep day only, when the user
 * has not swept or dismissed it this week and a task faded since the last sweep.
 */
export function isSweepDue(
  now: Date,
  { sweptAt, dismissedOn }: Pick<FadeSettings, "sweptAt" | "dismissedOn">,
  fadedDates: Array<string | null | undefined>,
): boolean {
  const anchor = sweepAnchorDay(now);
  if (localTodayYMD(now) !== anchor) return false;
  if (sweptAt && localTodayYMD(new Date(sweptAt)) >= anchor) return false;
  if (dismissedOn && dismissedOn >= anchor) return false;
  return fadedDates.some((fadedAt) => isInCurrentSweep(fadedAt, sweptAt));
}
