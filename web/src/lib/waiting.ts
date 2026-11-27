// Waiting: work handed to a person (ADR 0053, docs/REVIEW_SPEC.md §6). Two
// synced task fields: `waitingOn` (the name) and `waitingSince` (the day the
// wait began). The task's When date is the day to chase.

import { SURFACES_CATALOG, registryText } from "./generated/registries.ts";
import type { ProjectRow, ProjectShareInfo, TaskRow } from "./types";

export const WAITING_SURFACE = SURFACES_CATALOG.waiting;
export const SHARING_SURFACE = SURFACES_CATALOG.sharing;

const WAITING_DAYS_PHRASE = SURFACES_CATALOG.prompts.countPhrases.find((p) => p.id === "waitingDays")!;

export function sharingCopy(id: string, lang: string): string {
  const entry = SHARING_SURFACE.copy.find((c) => c.id === id);
  return entry ? registryText(entry.label, lang) : id;
}

export function projectShareOf(project: ProjectRow | null | undefined): ProjectShareInfo | null {
  const raw = project?.share;
  if (!raw || typeof raw !== "object" || typeof raw.id !== "string" || typeof raw.me !== "string" || !Array.isArray(raw.members)) {
    return null;
  }
  return raw;
}

/** True when this shared task is assigned to another member (`assignedTo != share.me`). */
export function isAssignedToOther(
  task: Pick<TaskRow, "assignedTo">,
  share?: ProjectShareInfo | null,
): boolean {
  if (!share) return false;
  const assigned = typeof task.assignedTo === "string" ? task.assignedTo.trim() : "";
  return Boolean(assigned && assigned !== share.me);
}

/** Shared-project Waiting target (ADR 0053, #672): non-nil only when this user assigned the task to another member. */
export function sharedWaitingTarget(
  task: Pick<TaskRow, "assignedTo" | "assignedBy" | "assignedAt">,
  share?: ProjectShareInfo | null,
): { name: string; since: string | null } | null {
  if (!share) return null;
  const assignedTo = typeof task.assignedTo === "string" ? task.assignedTo.trim() : "";
  const assignedBy = typeof task.assignedBy === "string" ? task.assignedBy.trim() : "";
  if (!assignedTo || !assignedBy || assignedTo === share.me || assignedBy !== share.me) return null;
  const member = share.members.find((m) => m.id === assignedTo);
  return {
    name: member?.name || assignedTo,
    since: typeof task.assignedAt === "string" && task.assignedAt ? task.assignedAt : null,
  };
}

/** The longest name `waitingOn` holds (registry/entities.json, task.waitingOn max). */
export const WAITING_ON_MAX = 80;

/** The manual `waitingOn` name, or null when not set. A blank name is no wait. */
export function waitingName(task: Pick<TaskRow, "waitingOn">): string | null {
  const name = typeof task.waitingOn === "string" ? task.waitingOn.trim() : "";
  return name ? name : null;
}

/** True when the task waits on a person: manual `waitingOn` or shared assignment by this user. */
export function isWaitingTask(
  task: Pick<TaskRow, "waitingOn" | "assignedTo" | "assignedBy" | "assignedAt">,
  share?: ProjectShareInfo | null,
): boolean {
  return Boolean(waitingName(task) || sharedWaitingTarget(task, share));
}

/** Effective wait start day (`YYYY-MM-DD`). */
export function effectiveWaitingSince(
  task: Pick<TaskRow, "waitingOn" | "waitingSince" | "assignedTo" | "assignedBy" | "assignedAt">,
  share?: ProjectShareInfo | null,
): string | null {
  if (waitingName(task)) {
    return typeof task.waitingSince === "string" && task.waitingSince ? task.waitingSince : null;
  }
  return sharedWaitingTarget(task, share)?.since ?? null;
}

/** Whole days from `since` to `today` (both YYYY-MM-DD), never below 0. Null without a start day. */
export function waitingDays(task: Pick<TaskRow, "waitingSince"> | string | null | undefined, today: string): number | null {
  const since = typeof task === "string"
    ? task
    : (task && typeof task === "object" && typeof task.waitingSince === "string" ? task.waitingSince : "");
  const a = Date.parse(`${since}T00:00:00Z`);
  const b = Date.parse(`${today}T00:00:00Z`);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return null;
  return Math.max(0, Math.round((b - a) / 86_400_000));
}

/** "Waiting on Anna · 5 days". The day count shows from the first full day. */
export function waitingLabel(
  task: Pick<TaskRow, "waitingOn" | "waitingSince" | "assignedTo" | "assignedBy" | "assignedAt">,
  today: string,
  lang: string,
  share?: ProjectShareInfo | null,
): string | null {
  const manual = waitingName(task);
  const shared = manual ? null : sharedWaitingTarget(task, share);
  const name = manual ?? shared?.name ?? null;
  if (!name) return null;
  const label = registryText(WAITING_SURFACE.label.format, lang, { name });
  const since = manual ? task.waitingSince : shared?.since;
  const days = waitingDays(since, today);
  if (!days) return label;
  return `${label} · ${registryText(WAITING_DAYS_PHRASE.label.other, lang, { count: days })}`;
}

/** Assignee pill label: shows "You" inside a shared project (`includeSelf`), hides own outside. */
export function assigneeLabel(
  task: Pick<TaskRow, "assignedTo">,
  share: ProjectShareInfo | null | undefined,
  includeSelf: boolean,
  lang: string,
): string | null {
  if (!share) return null;
  const assigned = typeof task.assignedTo === "string" ? task.assignedTo.trim() : "";
  if (!assigned) return null;
  if (assigned === share.me) return includeSelf ? sharingCopy("you", lang) : null;
  return share.members.find((m) => m.id === assigned)?.name ?? null;
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

/** Review ▸ Waiting order: oldest wait first. A wait with no start day goes last. */
export function compareWaiting(
  a: Pick<TaskRow, "waitingOn" | "waitingSince" | "assignedTo" | "assignedBy" | "assignedAt">,
  b: Pick<TaskRow, "waitingOn" | "waitingSince" | "assignedTo" | "assignedBy" | "assignedAt">,
  shareA?: ProjectShareInfo | null,
  shareB?: ProjectShareInfo | null,
): number {
  const sa = effectiveWaitingSince(a, shareA) ?? "9999-12-31";
  const sb = effectiveWaitingSince(b, shareB) ?? "9999-12-31";
  return sa.localeCompare(sb);
}
