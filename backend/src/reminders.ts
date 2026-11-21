// Timed task reminder rules — LOCKSTEP with `TaskReminderRules` in
// `SeptenaCore/DateParser.swift` and verified by
// `registry/conformance/reminders.json` (docs/TIMED_REMINDERS_SPEC.md).

const FLOATING_RE = /^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d$/;
const FIXED_RE = /^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

export type ReminderMode = "floating" | "fixed";

export function isValidReminderAt(value: string, mode?: ReminderMode | null): boolean {
  if (mode === "fixed") return FIXED_RE.test(value);
  if (mode === "floating") return FLOATING_RE.test(value);
  return FLOATING_RE.test(value) || FIXED_RE.test(value);
}

function parseYMDToUTC(ymd: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(ymd);
  if (!m) return null;
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return Date.UTC(y, mo - 1, d);
}

function formatUTCAsYMD(ms: number): string {
  const dt = new Date(ms);
  const y = String(dt.getUTCFullYear()).padStart(4, "0");
  const m = String(dt.getUTCMonth() + 1).padStart(2, "0");
  const d = String(dt.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

const DAY_MS = 86_400_000;

/**
 * Computes the reminder timestamp for a newly spawned recurring occurrence,
 * preserving the source reminder's time-of-day (and any whole-day offset
 * relative to `sourceScheduled`).
 */
export function shiftReminderForRecurrence(input: {
  sourceReminderAt: string | null | undefined;
  sourceScheduled: string | null | undefined;
  nextScheduled: string | null | undefined;
}): string | null {
  const src = input.sourceReminderAt;
  const nextDay = input.nextScheduled;
  if (!src || !nextDay) return null;
  const tIndex = src.indexOf("T");
  if (tIndex !== 10) return null;

  const remDayStr = src.slice(0, 10);
  const timeSuffix = src.slice(10); // e.g. "T09:30" or "T14:00:00Z"
  const nextMs = parseYMDToUTC(nextDay);
  if (nextMs === null) return null;

  let offsetDays = 0;
  if (input.sourceScheduled) {
    const remMs = parseYMDToUTC(remDayStr);
    const schedMs = parseYMDToUTC(input.sourceScheduled);
    if (remMs !== null && schedMs !== null) {
      offsetDays = Math.round((remMs - schedMs) / DAY_MS);
    }
  }

  return `${formatUTCAsYMD(nextMs + offsetDays * DAY_MS)}${timeSuffix}`;
}

/**
 * When a task's `scheduled` date moves, shift a reminder that fell on the
 * SAME calendar day as `oldScheduled` onto `newScheduled`, keeping its time.
 * Reminders on a different day (or when `newScheduled` is cleared) stay put.
 */
export function shiftReminderOnReschedule(input: {
  reminderAt: string | null | undefined;
  oldScheduled: string | null | undefined;
  newScheduled: string | null | undefined;
}): string | null {
  const rem = input.reminderAt ?? null;
  if (!rem) return null;
  if (!input.oldScheduled || !input.newScheduled) return rem;
  if (rem.length < 11 || rem[10] !== "T") return rem;
  const remDay = rem.slice(0, 10);
  const oldDay = input.oldScheduled.slice(0, 10);
  const newDay = input.newScheduled.slice(0, 10);
  if (remDay !== oldDay) return rem;
  return `${newDay}${rem.slice(10)}`;
}

/**
 * Whether a device should arm a local OS notification for a task reminder.
 * Unacknowledged agent proposals NEVER arm alerts (ADR 0008).
 */
export function shouldArmReminder(input: {
  status: string;
  isDeleted: boolean;
  isHeading: boolean;
  isUnratifiedProposal: boolean;
  reminderAt: string | null | undefined;
  reminderDismissedAt: string | null | undefined;
}): boolean {
  if (input.status !== "open") return false;
  if (input.isDeleted || input.isHeading) return false;
  if (input.isUnratifiedProposal) return false;
  if (!input.reminderAt || input.reminderAt.length === 0) return false;
  if (input.reminderDismissedAt) return false;
  return true;
}
