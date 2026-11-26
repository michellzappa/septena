import type { CoreRecurrenceRule } from "./core";
import type { TaskRow } from "./types";

export type RescheduleMode = "makeException" | "updateRule";

/**
 * True when rescheduling [task] to [targetDay] (`YYYY-MM-DD`) triggers the
 * fixed-repeat prompt (`rescheduleFixedRepeat`, TASK_DATES_SPEC §4, #573).
 */
export function needsFixedRepeatPrompt(task: TaskRow, targetDay: string | null): boolean {
  if (!targetDay) return false;
  if (!task.recurrenceUnit || task.recurrenceAfterCompletion) return false;
  return targetDay !== (task.scheduled ?? null);
}

export interface FixedSeriesRebaseUpdate {
  task: TaskRow;
  seriesID: string;
  nextDay: string;
}

/**
 * Computes deterministic sibling-occurrence rebase updates for a fixed repeating
 * series after "Update Schedule" moves [source] to [newAnchor] (#573, matching
 * Apple `TasksBackend.rebaseFixedSeries`).
 */
export function planFixedSeriesRebase(
  source: TaskRow,
  allTasks: TaskRow[],
  newAnchor: string,
  nextDate: (input: {
    completedOn: string;
    scheduled: string;
    logicalScheduled: string;
    rule: CoreRecurrenceRule;
  }) => string | null,
): FixedSeriesRebaseUpdate[] {
  if (!source.recurrenceUnit || source.recurrenceAfterCompletion) return [];
  const rule: CoreRecurrenceRule = {
    unit: source.recurrenceUnit,
    interval: Math.max(1, source.recurrenceInterval ?? 1),
    afterCompletion: false,
    weekdays: source.recurrenceWeekdays ?? null,
    monthDay: source.recurrenceMonthDay ?? null,
    ordinalWeekday: source.recurrenceOrdinalWeekday ?? null,
  };
  const seriesID = source.recurrenceSeriesID ?? source.id;
  const openSiblings = allTasks
    .filter(
      (t) =>
        t.id !== source.id &&
        !t.deletedAt &&
        t.status === "open" &&
        (t.recurrenceSeriesID ?? t.id) === seriesID,
    )
    .sort((a, b) => {
      const ka = a.recurrenceAnchorDate ?? a.scheduled ?? "9999-12-31";
      const kb = b.recurrenceAnchorDate ?? b.scheduled ?? "9999-12-31";
      return ka !== kb ? ka.localeCompare(kb) : a.id.localeCompare(b.id);
    });

  const updates: FixedSeriesRebaseUpdate[] = [];
  let cursor = newAnchor;
  for (const sibling of openSiblings) {
    const next = nextDate({
      completedOn: cursor,
      scheduled: cursor,
      logicalScheduled: cursor,
      rule,
    });
    if (!next) break;
    cursor = next;
    updates.push({ task: sibling, seriesID, nextDay: cursor });
  }
  return updates;
}
