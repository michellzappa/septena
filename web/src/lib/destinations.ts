// registry/destinations.json as one widened shape, plus the groups of the
// Review list (docs/REVIEW_SPEC.md). No list names its groups by hand.

import { DESTINATIONS } from "./generated/registries.ts";
import type { CoreConversationState } from "./core/index.ts";
import type { ActiveDestination, ProjectShareInfo, SmartDestination, TaskRow } from "./types";
import { isWaitingTask } from "./waiting.ts";

export interface DestinationGroup {
  id: string;
  title: string;
  icon: string;
}

export interface DestinationInfo {
  id: string;
  title: string;
  icon: string;
  visibility: string;
  sidebarOrder?: number;
  sidebarSection?: "top" | "bottom";
  /** False: the list stays in its registry section; a stored placement is ignored. */
  canMoveSection?: boolean;
  /** Magic Plus drops create a task in this list (Apple allowsInlineCreate). Not the add field. */
  supportsInlineCreate: boolean;
  /**
   * Where a new task from this list goes (iOS triggerInlineNewTask): "here" makes it in this
   * list, "tomorrow" makes it here scheduled tomorrow, "today" opens Today and makes it there.
   */
  newTaskTarget: NewTaskTarget;
  /** True: the list keeps a manual order, so it takes a Sort By (docs/LIST_SORT_SPEC.md §1). */
  supportsManualOrder?: boolean;
  dropBehavior: string;
  groups?: readonly DestinationGroup[];
  emptyState?: { title: string; detail: string };
}

export type NewTaskTarget = "here" | "tomorrow" | "today";

export type SidebarDestination = DestinationInfo & { id: SmartDestination };

const ALL: readonly DestinationInfo[] = DESTINATIONS;

/** Destinations that live inside another list: no sidebar or Quick Find row. */
const NESTED_VISIBILITIES = new Set(["todayBand", "logbookTab", "reviewGroup"]);

/** The sidebar lists, in their registry order. */
export const SIDEBAR_DESTINATIONS: readonly SidebarDestination[] = ALL.filter(
  (d): d is SidebarDestination => !NESTED_VISIBILITIES.has(d.visibility),
).sort((a, b) => (a.sidebarOrder ?? 99) - (b.sidebarOrder ?? 99));

export function destinationInfo(id: string): DestinationInfo | undefined {
  return ALL.find((d) => d.id === id);
}

/**
 * The registry newTaskTarget of the open list. An area or project page makes the task in place;
 * a smart list reads destinations.json. An unknown list falls back to "here".
 */
export function newTaskTargetOf(destination: ActiveDestination): NewTaskTarget {
  if (destination.kind !== "smart") return "here";
  return destinationInfo(destination.id)?.newTaskTarget ?? "here";
}

export function destinationGroups(id: "review"): readonly DestinationGroup[] {
  return destinationInfo(id)?.groups ?? [];
}

type ReviewTask = Pick<TaskRow, "status" | "kind" | "deletedAt" | "fadedAt" | "waitingOn" | "assignedTo" | "assignedBy" | "assignedAt">;

/** Review groups that hold agent work in progress (ADR 0046): the core's agent stages of the same id. */
const IN_PROGRESS_GROUP_IDS = new Set(["working", "queued", "stopped"]);

/** Review groups that wait on the user. Only they count in the Review badge. Waiting does not. */
export const BADGE_GROUP_IDS: ReadonlySet<string> = new Set(["questions", "finished"]);

/**
 * The Review group a task is in, or null. A faded task is in Faded only. What
 * waits on the user comes first, then work handed to a person (Waiting,
 * REVIEW_SPEC §6), then agent work in progress by its stage.
 */
export function reviewGroupOf(
  task: ReviewTask,
  convoState: Pick<CoreConversationState, "reviewGroup" | "agentStage"> | null,
  share?: ProjectShareInfo | null,
): string | null {
  if (task.status !== "open" || task.deletedAt || task.kind === "heading") return null;
  if (convoState?.reviewGroup) return convoState.reviewGroup;
  if (isWaitingTask(task, share)) return "waiting";
  const stage = convoState?.agentStage;
  if (stage && IN_PROGRESS_GROUP_IDS.has(stage)) return stage;
  return task.fadedAt ? "faded" : null;
}

/** The title of an agent stage: its Review group, else the Review list it waits in. */
export function agentStageTitle(stage: string): string {
  const group = destinationGroups("review").find((g) => g.id === stage);
  return group?.title ?? destinationInfo("review")?.title ?? stage;
}
