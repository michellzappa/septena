// registry/destinations.json as one widened shape, plus the groups of the
// Review list (docs/REVIEW_SPEC.md). No list names its groups by hand.

import { DESTINATIONS } from "./generated/registries.ts";
import type { CoreConversationState } from "./core/index.ts";
import type { SmartDestination, TaskRow } from "./types";

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
  supportsInlineCreate: boolean;
  dropBehavior: string;
  groups?: readonly DestinationGroup[];
  emptyState?: { title: string; detail: string };
}

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

export function destinationGroups(id: "review"): readonly DestinationGroup[] {
  return destinationInfo(id)?.groups ?? [];
}

type ReviewTask = Pick<TaskRow, "status" | "kind" | "deletedAt" | "fadedAt">;

/** Review groups that hold agent work in progress (ADR 0046): the core's agent stages of the same id. */
const IN_PROGRESS_GROUP_IDS = new Set(["working", "queued", "stopped"]);

/** Review groups that wait on the user. Only they count in the Review badge. */
export const BADGE_GROUP_IDS: ReadonlySet<string> = new Set(["questions", "finished"]);

/**
 * The Review group a task is in, or null. A faded task is in Faded only. What
 * waits on the user comes first, then agent work in progress by its stage.
 */
export function reviewGroupOf(
  task: ReviewTask,
  convoState: Pick<CoreConversationState, "reviewGroup" | "agentStage"> | null,
): string | null {
  if (task.status !== "open" || task.deletedAt || task.kind === "heading") return null;
  if (convoState?.reviewGroup) return convoState.reviewGroup;
  const stage = convoState?.agentStage;
  if (stage && IN_PROGRESS_GROUP_IDS.has(stage)) return stage;
  return task.fadedAt ? "faded" : null;
}

/** The title of an agent stage: its Review group, else the Review list it waits in. */
export function agentStageTitle(stage: string): string {
  const group = destinationGroups("review").find((g) => g.id === stage);
  return group?.title ?? destinationInfo("review")?.title ?? stage;
}
