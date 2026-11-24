// Recurrence for the Worker. The date arithmetic and the occurrence id are
// the shared core's (`core/crates/septena-core/src/recurrence.rs`, ADR 0025
// C3 #249), the same code the apps run, verified by
// `registry/conformance/recurrence.json`. Both surfaces derive the next
// occurrence's id from (source task id + next date), so a phone completion
// and a chat completion of one task converge on one row only while they share
// this code. Never re-implement it here.

import { checklistOccurrenceId, nextScheduledDate as coreNextScheduledDate, occurrenceId } from "./core/index.js";

export interface OrdinalWeekday {
  /** 1..4 for 1st..4th, or -1 for last occurrence in the month. */
  ordinal: number;
  /** 1 = Sunday .. 7 = Saturday (matches Swift Calendar.component(.weekday)). */
  weekday: number;
}

export interface RecurrenceRule {
  unit: string; // "day" | "week" | "month" | "year"
  interval: number; // 1+
  afterCompletion: boolean;
  /** Specific weekdays (1 = Sun .. 7 = Sat) for fixed weekly rules. */
  weekdays?: number[] | null;
  /** Specific day of month (1..31, or -1 for last day) for fixed monthly/yearly rules. */
  monthDay?: number | null;
  /** Specific ordinal weekday (e.g. last Friday) for fixed monthly/yearly rules. */
  ordinalWeekday?: OrdinalWeekday | null;
}

/**
 * The next occurrence date (`YYYY-MM-DD`) of a repeating task completed on
 * `completedOn`, or null when the rule cannot produce one. A fixed rule
 * advances from `logicalScheduled ?? scheduled` until it passes the
 * completion date.
 */
export function nextScheduledDate(input: {
  completedOn: string;
  scheduled?: string | null;
  /** The series' logical slot (`recurrenceAnchorDate`) when this occurrence
   *  was moved as a one-off exception. */
  logicalScheduled?: string | null;
  rule: RecurrenceRule;
}): string | null {
  return coreNextScheduledDate(input);
}

/** Deterministic record name for a generated occurrence (`recur-` + 16 hex). */
export function occurrenceID(sourceTaskID: string, scheduled: string): string {
  return occurrenceId(sourceTaskID, scheduled);
}

/** Deterministic ID for a checklist item copied onto a recurring occurrence (`chk-` + 16 hex). */
export function checklistOccurrenceID(newTaskID: string, index: number, sourceItemID: string): string {
  return checklistOccurrenceId(newTaskID, index, sourceItemID);
}
