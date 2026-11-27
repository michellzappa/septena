import { callCore, nextOccurrenceDates, type CoreTask } from "../core/index.js";
import { isValidTz } from "../tz.js";

type Task = Record<string, unknown>;
interface Window {
  create: string[];
  expireBefore: string | null;
  hasMore: boolean;
}

const templateFields = [
  "title", "area", "project", "heading", "notes", "tags", "starred", "source", "sourceClient",
  "recurrenceUnit", "recurrenceInterval", "recurrenceAfterCompletion", "recurrenceWeekdays",
  "recurrenceMonthDay", "recurrenceOrdinalWeekday", "recurrenceMissed", "recurrenceMissedFrom",
] as const;

export function scheduledSlot(task: Task): string {
  return String(task.recurrenceAnchorDate ?? task.scheduled ?? "");
}

export function advancesBySchedule(task: Record<string, unknown>): boolean {
  return task.recurrenceAfterCompletion !== true &&
    (task.recurrenceMissed === "startFresh" || task.recurrenceMissed === "keepEach");
}

export function repeatWindow(task: Task, now: Date): Window {
  const zone = typeof task.timeZone === "string" && isValidTz(task.timeZone) ? task.timeZone : "UTC";
  const clock = new Intl.DateTimeFormat("sv-SE", {
    timeZone: zone, dateStyle: "short", timeStyle: "short", hourCycle: "h23",
  }).formatToParts(now);
  const part = (kind: Intl.DateTimeFormatPartTypes) => clock.find((item) => item.type === kind)?.value;
  return callCore<Window>("recurrenceWindow", {
    mode: task.recurrenceMissed,
    lastSlot: scheduledSlot(task),
    today: `${part("year")}-${part("month")}-${part("day")}`,
    localTime: `${part("hour")}:${part("minute")}`,
    startTime: task.startTime,
    rule: {
      unit: task.recurrenceUnit,
      interval: task.recurrenceInterval ?? 1,
      afterCompletion: false,
      weekdays: task.recurrenceWeekdays,
      monthDay: task.recurrenceMonthDay,
      ordinalWeekday: task.recurrenceOrdinalWeekday,
    },
  });
}

export function repeatOccurrence(task: Task, seriesId: string, scheduled: string, now: string): Record<string, unknown> {
  const fields = Object.fromEntries(templateFields
    .filter((key) => key in task)
    .map((key) => [key, task[key]]));
  return {
    ...fields,
    ...nextOccurrenceDates(task as unknown as CoreTask, scheduled, now),
    status: "open",
    scheduled: scheduled,
    recurrenceAnchorDate: scheduled,
    recurrenceSeriesID: seriesId,
    created: scheduled,
    createdAt: now,
    touchedAt: now,
    recurrencePaused: false,
  };
}
