import type { AreaRow, ProjectRow } from "./types";

/**
 * Mirrors Apple `TaskStructureOrder.positionOrdered`:
 * - Incoming fallback order is case-insensitive alphabetical by title/name.
 * - Positioned items (`position != null && position !== 0`) sort ascending.
 * - Unpositioned items (`position == null || position === 0`) sink to the
 *   bottom in alphabetical order, never ahead of explicitly positioned items.
 */
export function orderByPosition<
  T extends { position?: number | null; title?: string; name?: string },
>(items: readonly T[]): T[] {
  const label = (x: T) => x.title ?? x.name ?? "";
  const alpha = [...items].sort((a, b) =>
    label(a).localeCompare(label(b), undefined, { sensitivity: "base" }),
  );
  const hasExplicitPosition = alpha.some(
    (x) => typeof x.position === "number" && Number.isFinite(x.position) && x.position !== 0,
  );
  if (!hasExplicitPosition) return alpha;

  const key = (x: T) =>
    typeof x.position === "number" && Number.isFinite(x.position) && x.position !== 0
      ? x.position
      : Number.MAX_SAFE_INTEGER;

  return alpha
    .map((item, idx) => ({ item, idx, pos: key(item) }))
    .sort((a, b) => (a.pos !== b.pos ? a.pos - b.pos : a.idx - b.idx))
    .map((entry) => entry.item);
}

/**
 * Position to write when appending a newly created Area or Project:
 * - If every existing item in the group already has an explicit positive position,
 *   return `max + 1` so the new item appends cleanly at the bottom.
 * - Otherwise return `0` (matching Apple's default unset position) so unpositioned
 *   groups stay alphabetically sorted and the new item never jumps ahead of `0` rows.
 */
export function nextStructurePosition(
  existing: readonly { position?: number | null }[],
): number {
  if (existing.length === 0) return 0;
  let maxPos = 0;
  for (const item of existing) {
    const pos = item.position;
    if (typeof pos !== "number" || !Number.isFinite(pos) || pos <= 0) {
      return 0;
    }
    const whole = Math.ceil(pos);
    if (whole > maxPos) maxPos = whole;
  }
  return maxPos + 1;
}

export type TaskListGroup<T> =
  | { key: string; kind: "project"; projectId: string; title: string; items: T[] }
  | { key: string; kind: "area"; areaId: string; emoji: string | null; title: string; items: T[] };

/**
 * Groups tasks by Area & Project in exact sidebar order — 1:1 with Apple
 * (`SeptaskKitTaskList.groupedByList` / `TaskListOrder.byList`) and Android
 * (`TaskHomeViewModel.groupByAreaAndProject`):
 *
 * 1. Unfiled tasks (headerless) first.
 * 2. Each Area in sidebar order:
 *    a. Direct tasks in that Area (`!project && area === area.id`).
 *    b. Each Project in that Area (`project.area === area.id`) in sidebar order.
 * 3. Standalone Projects (`!project.area` or area missing) in sidebar order.
 */
export function groupTasksByList<
  T extends { task: { area?: string | null; project?: string | null } },
>(
  items: readonly T[],
  orderedAreas: readonly AreaRow[],
  orderedProjects: readonly ProjectRow[],
): { ungrouped: T[]; groups: Array<TaskListGroup<T>> } {
  const areaIds = new Set(orderedAreas.map((a) => a.id));
  const projectIds = new Set(orderedProjects.map((p) => p.id));

  const byProject = new Map<string, T[]>();
  const byArea = new Map<string, T[]>();
  const ungrouped: T[] = [];

  for (const item of items) {
    const t = item.task;
    if (t.project && projectIds.has(t.project)) {
      const list = byProject.get(t.project) ?? [];
      list.push(item);
      byProject.set(t.project, list);
    } else if (t.area && areaIds.has(t.area)) {
      const list = byArea.get(t.area) ?? [];
      list.push(item);
      byArea.set(t.area, list);
    } else {
      ungrouped.push(item);
    }
  }

  const groups: Array<TaskListGroup<T>> = [];
  const pushProject = (project: ProjectRow) => {
    const projectItems = byProject.get(project.id);
    if (!projectItems || projectItems.length === 0) return;
    groups.push({
      key: `p:${project.id}`,
      kind: "project",
      projectId: project.id,
      title: project.title,
      items: projectItems,
    });
  };

  for (const area of orderedAreas) {
    const direct = byArea.get(area.id);
    if (direct && direct.length > 0) {
      groups.push({
        key: `a:${area.id}`,
        kind: "area",
        areaId: area.id,
        emoji: area.emoji ?? null,
        title: area.title,
        items: direct,
      });
    }
    for (const project of orderedProjects) {
      if (project.area === area.id) pushProject(project);
    }
  }

  for (const project of orderedProjects) {
    if (!project.area || !areaIds.has(project.area)) {
      pushProject(project);
    }
  }

  return { ungrouped, groups };
}

/**
 * Manual reorder by drag: move `sourceId` to the slot `targetId` holds and return the new
 * order, or null when the drop means nothing (same row, or either id missing). Task rows and
 * project headings share it; the caller writes the order with `engine.reorderTasks`, which
 * gives every id a position of (index + 1) * 1000, so no write is ever 0 (the unset value).
 */
export function moveIdToTarget(ids: readonly string[], sourceId: string, targetId: string): string[] | null {
  if (sourceId === targetId) return null;
  const fromIdx = ids.indexOf(sourceId);
  const toIdx = ids.indexOf(targetId);
  if (fromIdx < 0 || toIdx < 0) return null;
  const next = [...ids];
  const [moved] = next.splice(fromIdx, 1);
  next.splice(toIdx, 0, moved);
  return next;
}

/** Apple `TaskOrder.gap`: the step between manual positions at a list edge. */
export const TASK_ORDER_GAP = 1024;

/**
 * Apple `TaskOrder.between(above: nil, below:)`: the position for one task placed above
 * `below` (the first task of a group), or at the start of an empty group. Never 0, the
 * "never dragged" value: a result of 0 moves half a step, which stays above `below`.
 */
export function positionAbove(below: number | null | undefined): number {
  if (typeof below !== "number" || !Number.isFinite(below)) return TASK_ORDER_GAP;
  const slot = below - TASK_ORDER_GAP;
  return slot === 0 ? slot - TASK_ORDER_GAP / 2 : slot;
}
