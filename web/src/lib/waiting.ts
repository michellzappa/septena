// Waiting: work handed to a person (ADR 0053, docs/REVIEW_SPEC.md §6). Two
// synced task fields: `waitingOn` (the name) and `waitingSince` (the day the
// wait began). The task's When date is the day to chase.

import { SURFACES_CATALOG, registryText } from "./generated/registries.ts";
import type { TaskRow } from "./types";

export const WAITING_SURFACE = SURFACES_CATALOG.waiting;

const WAITING_DAYS_PHRASE = SURFACES_CATALOG.prompts.countPhrases.find((p) => p.id === "waitingDays")!;

/** The longest name `waitingOn` holds (registry/entities.json, task.waitingOn max). */
export const WAITING_ON_MAX = 80;

/** The name the task waits on, or null when it does not wait. A blank name is no wait. */
export function waitingName(task: Pick<TaskRow, "waitingOn">): string | null {
  const name = typeof task.waitingOn === "string" ? task.waitingOn.trim() : "";
  return name ? name : null;
}

/** Whole days from `waitingSince` to `today` (both YYYY-MM-DD), never below 0. Null without a start day. */
export function waitingDays(task: Pick<TaskRow, "waitingSince">, today: string): number | null {
  const since = typeof task.waitingSince === "string" ? task.waitingSince : "";
  const a = Date.parse(`${since}T00:00:00Z`);
  const b = Date.parse(`${today}T00:00:00Z`);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return null;
  return Math.max(0, Math.round((b - a) / 86_400_000));
}

/** "Waiting on Anna · 5 days". The day count shows from the first full day. */
export function waitingLabel(task: Pick<TaskRow, "waitingOn" | "waitingSince">, today: string, lang: string): string | null {
  const name = waitingName(task);
  if (!name) return null;
  const label = registryText(WAITING_SURFACE.label.format, lang, { name });
  const days = waitingDays(task, today);
  if (!days) return label;
  return `${label} · ${registryText(WAITING_DAYS_PHRASE.label.other, lang, { count: days })}`;
}

/**
 * The fields a wait on `name` writes. The wait starts today when the task had
 * none; a changed name keeps the start day. Setting a wait ends a fade (the
 * store does the same).
 */
export function setWaitingFields(task: Pick<TaskRow, "waitingOn" | "waitingSince">, name: string, today: string): Record<string, unknown> {
  const who = name.trim().slice(0, WAITING_ON_MAX);
  if (!who) return clearWaitingFields();
  const keepSince = waitingName(task) && typeof task.waitingSince === "string" && task.waitingSince;
  return { waitingOn: who, waitingSince: keepSince ? task.waitingSince : today, fadedAt: null };
}

/** Got It Back: the wait ends; the task stays open in its list. */
export function clearWaitingFields(): Record<string, unknown> {
  return { waitingOn: null, waitingSince: null };
}

/** Review ▸ Waiting order: oldest `waitingSince` first. A wait with no start day goes last. */
export function compareWaiting(a: Pick<TaskRow, "waitingSince">, b: Pick<TaskRow, "waitingSince">): number {
  const ka = typeof a.waitingSince === "string" && a.waitingSince ? a.waitingSince : "9999-12-31";
  const kb = typeof b.waitingSince === "string" && b.waitingSince ? b.waitingSince : "9999-12-31";
  return ka.localeCompare(kb);
}
